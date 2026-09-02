import CGtk
import Foundation
import agtermCore

/// The `ControlActions` arms that READ a live `GhosttySurface` — cursor position, overlay selection and
/// buffer, session buffer. Split out of `ControlActions+AppController.swift` for the lint size limit, the
/// same family split the `window.*` arms take.
extension AppController {
    /// The addressed surface's zero-based cursor column. Takes `surface.zoom`'s target vocabulary, `quick`
    /// included, so both `surface.*` commands address the same set; unlike zoom it neither selects nor
    /// realizes the target, an unrealized one being reported rather than waited for.
    func readSurfaceCursor(_ target: String?, window: String?) -> ControlResponse {
        let raw = target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "active"
        let resolved: TerminalZoomTarget?
        if raw == "active" {
            // a live zoom IS the active surface, the same precedence `surface.zoom active` applies.
            resolved = terminalZoom.target ?? resolveZoomTarget()
        } else if raw == "quick" {
            resolved = .quick
        } else if let surfaceID = TerminalSurfaceID(rawValue: raw) {
            resolved = .session(surfaceID.sessionID, surfaceID.surface)
        } else {
            return err("invalid surface: \(raw)")
        }
        guard let resolved else { return err("no active surface") }
        // the validity gate `surface.zoom` applies, so an explicit id cannot reach an occupant the tree
        // refuses to address: a HUD fills the overlay slot while `.overlay` reads unavailable.
        guard isZoomTargetValid(resolved), let surface = surface(for: resolved) else {
            return err("surface not available: \(resolved.controlID)")
        }
        guard surface.isRealized else { return err("surface not realized") }
        guard let column = surface.readCursorColumn() else { return err("failed to read cursor position") }
        return ControlResponse(ok: true,
                               result: ControlResult(id: resolved.controlID, cursor: ControlCursor(column: column)))
    }

    /// The surface `session.overlay.copy`/`.text` address: the pane's own overlay with `pane`, else the
    /// session-wide slot. Shared by both so `no overlay` and `overlay not realized` cannot come to mean
    /// different things on one command than the other. A HUD is refused ahead of everything, the slot being
    /// occupied saying nothing about whether agterm or a caller's program painted it.
    private func overlayReadSurface(_ id: UUID, pane: OverlayPane?) -> ResolveResponse<GhosttySurface> {
        guard let session = store.session(withID: id) else { return .failure(err("no such session")) }
        let occupied: Bool
        let surface: GhosttySurface?
        if let pane {
            occupied = session.paneOverlay(pane) != nil
            surface = paneOverlaySurfaces[id]?[pane]
        } else {
            if session.hudActive { return .failure(err(OverlayHudError.noRead)) }
            occupied = session.overlayActive
            surface = overlaySurfaces[id]
        }
        guard occupied else { return .failure(err("no overlay")) }
        guard let surface, surface.isRealized else { return .failure(err("overlay not realized")) }
        return .success(surface)
    }

    /// The OVERLAY's own selection, which `session.copy` cannot reach: that one addresses the pane the
    /// overlay covers, so a selection made in the overlay reads as `no selection` there.
    func copySessionOverlaySelection(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            switch overlayReadSurface(id, pane: pane) {
            case .failure(let response): return response
            case .success(let surface):
                guard let text = surface.readSelection() else { return err("no selection") }
                return ControlResponse(ok: true, result: ControlResult(text: text))
            }
        }
    }

    /// The OVERLAY's terminal buffer, `session.text`'s counterpart for the covering surface. What comes back
    /// is a TUI's DRAWN screen, wrapped as rendered, not the output it would have printed.
    func readSessionOverlayText(_ target: String?, window: String?,
                                options: ControlSessionOverlayTextOptions) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            switch overlayReadSurface(id, pane: options.pane) {
            case .failure(let response): return response
            case .success(let surface):
                guard let text = surface.readScreenText(all: options.all, lines: options.lines) else {
                    return err("failed to read surface buffer")
                }
                return ControlResponse(ok: true, result: ControlResult(text: text))
            }
        }
    }

    func readSessionText(_ target: String?, window: String?, options: ControlSessionTextOptions) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            let surface: GhosttySurface?
            switch options.pane {
            case nil: surface = onScreenSurface(for: id)
            case "left": surface = surfaces[id]
            case "right": surface = splitSurfaces[id]
            case "scratch": surface = scratchSurfaces[id]
            default: surface = nil
            }
            guard let text = surface?.readScreenText(all: options.all, lines: options.lines) else {
                return err("session not realized")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: text))
        }
    }
}
