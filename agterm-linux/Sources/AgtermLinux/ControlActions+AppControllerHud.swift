import CGtk
import Foundation
import agtermCore

/// Linux host for `session.hud.*`. Validation, error text and response shape stay in
/// `ControlDispatcher+Hud`; this layer supplies the three things agtermCore cannot resolve — the staged
/// helper's path, the terminal font's cell size, and the pane's live geometry — plus the body file the
/// helper reads. Mirrors `agterm/Control/ControlServer+Hud.swift`.
extension AppController {
    func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        openHud(target, window: window, spec: spec, placement: ControlHudPlacement())
    }

    func updateHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        updateHud(target, window: window, spec: spec, placement: ControlHudPlacement())
    }

    func openHud(_ target: String?, window: String?, spec: HudSpec,
                 placement: ControlHudPlacement) -> ControlResponse {
        openHud(target, spec: spec, placement: placement, fallbackToSession: false)
    }

    /// A custom command's failure panel: an `--error-pane` that is hidden or gone falls back to the whole
    /// session rather than dropping the panel.
    func openCommandFailureHud(_ sessionID: UUID, spec: HudSpec, pane: OverlayPane?) -> ControlResponse {
        openHud(sessionID.uuidString, spec: spec, placement: ControlHudPlacement(pane: pane), fallbackToSession: true)
    }

    private func openHud(_ target: String?, spec: HudSpec, placement: ControlHudPlacement,
                         fallbackToSession: Bool) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            guard let command = Self.hudHelperCommand() else {
                return err("hud helper is not bundled in this build")
            }
            let paneIdentity: UUID?
            let pane: OverlayPane?
            switch LinuxPanePlacement.resolve(placement.pane, paneID: placement.paneID, in: session,
                                              requireVisible: true,
                                              invalidPaneError: "hud pane must be left or right") {
            case .resolved(let identity, let target): (paneIdentity, pane) = (identity, target)
            case .rejected(let response):
                guard fallbackToSession else { return response }
                FileHandle.standardError.write(Data(
                    "agterm: failure panel for \"\(spec.message)\" falls back to the whole session: \(response.error ?? "unknown placement error")\n".utf8))
                (paneIdentity, pane) = (nil, nil)
            }
            let file = Self.hudBodyFile(for: id)
            // resolved before measuring and stored only by the open: a replaced HUD's teardown clears the
            // session's stored size, so reading it here would measure the predecessor's font.
            let fontSize = spec.fontSize ?? session.fontSize ?? hudBaseFontSize()
            // measured ONCE and threaded through, so the sizing and the header describe the same panel.
            let metrics = hudPaneMetrics(for: session, pane: pane, fontSize: fontSize)
            // open FIRST, write second: replacing a live HUD tears its surface down, and that teardown
            // deletes the body file at this same per-session path.
            guard store.openHud(id, command: command, spec: spec, file: file,
                                size: HudLayout.panelSize(for: spec, pane: metrics),
                                paneIdentity: paneIdentity, fontSize: fontSize) else {
                return err("overlay already open")
            }
            guard writeHudBody(session, pane: metrics) else {
                store.closeHud(id)
                return err(OverlayHudError.writeFailed)
            }
            watchHudGeometry(session)
            armHudAutoHide(session, spec: spec)
            reconcile()
            return ok(id)
        }
    }

    /// Rewrites the live HUD's body and re-sizes the panel in place, repainting with no re-spawn. A failed
    /// write rolls the store back: the panel still paints the old message, and `tree` must not claim the new.
    func updateHud(_ target: String?, window: String?, spec: HudSpec,
                   placement: ControlHudPlacement) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id), session.hudActive,
                  let previous = session.hudSpec, let previousSize = session.overlaySizePercent,
                  let previousHeight = session.hudHeightPercent else {
                return err(OverlayHudError.noHud)
            }
            let paneIdentity: UUID?
            let pane: OverlayPane?
            switch LinuxPanePlacement.resolve(placement.pane, paneID: placement.paneID, in: session,
                                              requireVisible: false,
                                              invalidPaneError: "hud pane must be left or right") {
            case .resolved(let identity, let target): (paneIdentity, pane) = (identity, target)
            case .rejected(let response): return response
            }
            let previousPaneIdentity = session.hudPaneIdentity
            let metrics = hudPaneMetrics(for: session, pane: pane, fontSize: liveHudFontSize(session))
            store.updateHud(id, spec: spec, size: HudLayout.panelSize(for: spec, pane: metrics),
                            paneIdentity: paneIdentity)
            guard writeHudBody(session, pane: metrics) else {
                // the panel still paints the old message, so it keeps the deadline that came with it
                store.updateHud(id, spec: previous,
                                size: HudPanelSize(widthPercent: previousSize, heightPercent: previousHeight),
                                paneIdentity: previousPaneIdentity)
                return err(OverlayHudError.writeFailed)
            }
            armHudAutoHide(session, spec: spec)
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

    /// Arms `spec`'s auto-hide and publishes the panel with the deadline it now has; a spec with no
    /// auto-hide only cancels. Expiry closes through the store of whichever window holds the session then,
    /// and never grabs focus: the user may be typing elsewhere by now.
    func armHudAutoHide(_ session: Session, spec: HudSpec) {
        let deadline = gHudAutoHide.arm(session, spec: spec) { id in
            guard let owner = gWindows.values.first(where: { $0.store.session(withID: id) != nil }),
                  owner.store.closeHud(id) else { return }
            owner.reconcile(focusActive: false)
        }
        store.publishHud(forSession: session.id, expiresAt: deadline, now: gHudAutoHide.now())
    }

    /// Coalesces the panel's size changes into one body rewrite per main-loop turn, so the header's grid
    /// follows the frame: upstream's `watchHudGeometry`. `GhosttySurface.resize` of a pane in the session and
    /// `session.overlay.resize` call it; `discardHudBody` clears it with the rest of the HUD state.
    func watchHudGeometry(_ session: Session) {
        let id = session.id
        session.onHudGeometryChange = { [weak self] in
            guard let self, gHudAutoHide.geometryPending.insert(id).inserted else { return }
            MainTimer.schedule(after: 0) { [weak self] in
                guard let self else { return }
                gHudAutoHide.geometryPending.remove(id)
                // the window may have closed in between; its GTK tree is gone even while the controller lives
                guard gWindows[self.windowID] === self, let session = self.store.session(withID: id),
                      session.hudActive else { return }
                self.resizeFloatingOverlayFrame(for: id)
                _ = self.writeHudBody(session, pane: self.hudPaneMetrics(for: session, pane: session.hudTargetPane,
                                                                         fontSize: self.liveHudFontSize(session)))
            }
        }
    }

    /// The size the live HUD's surface was created at, which every later measurement uses.
    func liveHudFontSize(_ session: Session) -> Double {
        session.hudFontSize ?? session.fontSize ?? hudBaseFontSize()
    }

    /// The area the panel is laid out over: one pane's live bounds when the caller scoped the HUD, else the
    /// deck overlay, which is also what sizes the floating frame, so the percentage the store resolved and
    /// the widget's own size cannot disagree. The cell is measured at `fontSize`, the HUD surface's own.
    ///
    /// Padding is reported as ZERO rather than guessed. macOS reads its bundled `window-padding-x/y`;
    /// Linux ships neither, so the value is libghostty's own default and this layer does not know it.
    /// `PaneMetrics` documents zero as the honest answer, and the grid it yields is a column or two wide —
    /// inside the divergence the estimated cell already carries.
    func hudPaneMetrics(for session: Session? = nil, pane: OverlayPane? = nil, fontSize: Double) -> PaneMetrics {
        let cell = Self.hudCellSize(family: linuxSettingsStore().load().fontFamily, size: fontSize,
                                    context: gtk_widget_get_pango_context(W(window)))
        var area = (width: 0.0, height: 0.0)
        if let session, let pane, let bounds = paneBoundsInDeck(session: session.id, pane: pane) {
            area = (bounds.width, bounds.height)
        } else if let overlay = deckOverlay {
            area = (Double(gtk_widget_get_width(W(overlay))), Double(gtk_widget_get_height(W(overlay))))
        }
        return PaneMetrics(cellWidth: cell.width, cellHeight: cell.height,
                           paneWidth: area.width, paneHeight: area.height)
    }

    /// The HUD surface's creation size while `surface` is a live HUD's painter, else nil. Every config
    /// re-apply restores it, because the panel's grid was measured at it.
    func hudCreationFontSize(of surface: GhosttySurface) -> Double? {
        guard surface.role == .overlay, let session = store.session(withID: surface.sessionID),
              session.hudActive, overlaySurfaces[session.id] === surface else { return nil }
        return session.hudFontSize
    }

    /// A pane's allocation in the deck overlay's own coordinates, which is what `GtkOverlay` margins are
    /// measured in. Nil until the widget has been laid out, where the caller falls back to the whole deck.
    func paneBoundsInDeck(session id: UUID, pane: OverlayPane) -> HudPaneFrame? {
        guard let overlay = deckOverlay else { return nil }
        guard let surface = pane == .left ? surfaces[id] : splitSurfaces[id] else { return nil }
        var rect = graphene_rect_t()
        guard gtk_widget_compute_bounds(W(surface.glArea), W(overlay), &rect) != 0 else { return nil }
        guard rect.size.width > 0, rect.size.height > 0 else { return nil }
        return HudPaneFrame(x: Double(rect.origin.x), y: Double(rect.origin.y),
                            width: Double(rect.size.width), height: Double(rect.size.height))
    }

    /// The configured size a HUD inherits when neither the caller nor the session's zoom names one.
    private func hudBaseFontSize() -> Double {
        linuxSettingsStore().load().fontSize ?? DashboardLayout.ghosttyDefaultFontSize
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
