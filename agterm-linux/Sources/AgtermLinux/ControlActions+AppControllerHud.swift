import CGtk
import Foundation
import agtermCore

/// Linux host for `session.hud.*`. Validation, error text and response shape stay in
/// `ControlDispatcher+Hud`; this layer supplies the three things agtermCore cannot resolve — the staged
/// helper's path, the terminal font's cell size, and the pane's live geometry — plus the body file the
/// helper reads. Mirrors `agterm/Control/ControlServer+Hud.swift`.
extension AppController {
    func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            guard let command = Self.hudHelperCommand() else {
                return err("hud helper is not bundled in this build")
            }
            let file = Self.hudBodyFile(for: id)
            // measured ONCE and threaded through, so the sizing and the header describe the same panel.
            let metrics = hudPaneMetrics()
            // open FIRST, write second: replacing a live HUD tears its surface down, and that teardown
            // deletes the body file at this same per-session path.
            guard store.openHud(id, command: command, spec: spec, file: file,
                                size: HudLayout.panelSize(for: spec, pane: metrics)) else {
                return err("overlay already open")
            }
            guard writeHudBody(session, pane: metrics) else {
                store.closeHud(id)
                return err(OverlayHudError.writeFailed)
            }
            reconcile()
            return ok(id)
        }
    }

    /// Rewrites the live HUD's body and re-sizes the panel in place, repainting with no re-spawn. A failed
    /// write rolls the store back: the panel still paints the old message, and `tree` must not claim the new.
    func updateHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id), session.hudActive,
                  let previous = session.hudSpec, let previousSize = session.overlaySizePercent,
                  let previousHeight = session.hudHeightPercent else {
                return err(OverlayHudError.noHud)
            }
            let metrics = hudPaneMetrics()
            store.updateHud(id, spec: spec, size: HudLayout.panelSize(for: spec, pane: metrics))
            guard writeHudBody(session, pane: metrics) else {
                store.updateHud(id, spec: previous,
                                size: HudPanelSize(widthPercent: previousSize, heightPercent: previousHeight))
                return err(OverlayHudError.writeFailed)
            }
            resizeFloatingOverlayFrame(for: id)
            return ok(id)
        }
    }

    func closeHud(_ target: String?, window: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard store.closeHud(id) else { return err(OverlayHudError.noHud) }
            reconcile()
            return ok(id)
        }
    }

    /// The pane the panel is laid out over: the deck overlay, which is also what sizes the floating frame,
    /// so the percentage the store resolved and the widget's own size cannot disagree.
    ///
    /// Padding is reported as ZERO rather than guessed. macOS reads its bundled `window-padding-x/y`;
    /// Linux ships neither, so the value is libghostty's own default and this layer does not know it.
    /// `PaneMetrics` documents zero as the honest answer, and the grid it yields is a column or two wide —
    /// inside the divergence the estimated cell already carries.
    func hudPaneMetrics() -> PaneMetrics {
        let cell = Self.hudCellSize(family: linuxSettingsStore().load().fontFamily,
                                    size: hudBaseFontSize(),
                                    context: gtk_widget_get_pango_context(W(window)))
        var paneWidth = 0.0
        var paneHeight = 0.0
        if let overlay = deckOverlay {
            paneWidth = Double(gtk_widget_get_width(W(overlay)))
            paneHeight = Double(gtk_widget_get_height(W(overlay)))
        }
        return PaneMetrics(cellWidth: cell.width, cellHeight: cell.height,
                           paneWidth: paneWidth, paneHeight: paneHeight)
    }

    private func hudBaseFontSize() -> Double {
        let settings = linuxSettingsStore().load()
        return store.selectedSessionID.flatMap { store.session(withID: $0)?.fontSize }
            ?? settings.fontSize ?? DashboardLayout.ghosttyDefaultFontSize
    }

    /// One cell of `family` at `size`, measured through Pango: the digit advance (every glyph advances the
    /// same in a monospaced face) and ascent + descent for the line box. libghostty rasterizes the terminal
    /// with its own font stack, so this is an ESTIMATE that may round differently from the cell it actually
    /// renders — the same divergence macOS accepts, bounded by `HudLayout`'s size clamp. An unresolvable
    /// family falls back to the generic `monospace`, never to a guessed ratio.
    static func hudCellSize(family: String?, size: Double,
                            context: OpaquePointer?) -> (width: Double, height: Double) {
        guard let context, let desc = pango_font_description_new() else { return (1, 1) }
        defer { pango_font_description_free(desc) }
        (family ?? "monospace").withCString { pango_font_description_set_family(desc, $0) }
        pango_font_description_set_size(desc, gint(size * Double(PANGO_SCALE)))
        guard let metrics = pango_context_get_metrics(context, desc, nil) else { return (1, 1) }
        defer { pango_font_metrics_unref(metrics) }
        let width = Double(pango_font_metrics_get_approximate_digit_width(metrics)) / Double(PANGO_SCALE)
        let height = Double(pango_font_metrics_get_ascent(metrics)
            + pango_font_metrics_get_descent(metrics)) / Double(PANGO_SCALE)
        return (width: max(width, 1), height: max(height, 1))
    }

    /// The staged painter, run through `/bin/sh` so a copy that dropped the executable bit still starts and
    /// shell-escaped because the overlay wrapper `eval`s this line. nil when no build staged it.
    static func hudHelperCommand() -> String? {
        for path in hudHelperCandidates() where FileManager.default.isReadableFile(atPath: path) {
            return "/bin/sh " + ShellEscape.path(path)
        }
        return nil
    }

    /// The dist tarball ships the helper under `<bundle>/share/agterm/hud`; a dev run falls back to the
    /// repository copy, which is the same file the shared `HudHelperTests` exercise.
    nonisolated static func hudHelperCandidates() -> [String] {
        var roots: [String] = []
        if let override = ProcessInfo.processInfo.environment["AGTERM_HUD_RESOURCES"], !override.isEmpty {
            roots.append(override)
        }
        if let arg0 = CommandLine.arguments.first, !arg0.isEmpty {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let raw = URL(fileURLWithPath: arg0)
            let executable = raw.path.hasPrefix("/") ? raw : cwd.appendingPathComponent(arg0)
            let bundle = executable.resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent()
            roots.append(bundle.appendingPathComponent("share/agterm/hud", isDirectory: true).path)
        }
        let cwd = FileManager.default.currentDirectoryPath as NSString
        roots.append(cwd.appendingPathComponent("agterm/Resources/hud"))
        roots.append(cwd.appendingPathComponent("../agterm/Resources/hud"))
        return roots.map { ($0 as NSString).appendingPathComponent("hud.sh") }
    }

    /// One body file per session, so an update rewrites the path the running helper already opened and a
    /// replacement reuses it instead of leaking a temp file per open.
    nonisolated static func hudBodyFile(for sessionID: UUID) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("agterm-hud-\(sessionID.uuidString).txt")
    }

    /// Writes the live HUD's body ATOMICALLY: the helper re-reads it every tick with no locking, so a
    /// partial write would paint half a message. Every state the header carries is read off the session, so
    /// the grid is the one the panel ACTUALLY took.
    func writeHudBody(_ session: Session, pane: PaneMetrics) -> Bool {
        guard let path = session.hudFile, let spec = session.hudSpec,
              let size = session.overlaySizePercent,
              let height = session.hudHeightPercent else { return false }
        let grid = HudLayout.paintGrid(for: spec,
                                       size: HudPanelSize(widthPercent: size, heightPercent: height),
                                       pane: pane)
        let rendered = HudLayout.renderedBody(for: spec, grid: grid,
                                              ownerPid: ProcessInfo.processInfo.processIdentifier)
        return (try? Data(rendered.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}
