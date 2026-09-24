import Foundation
import agtermCore

/// `session.overlay.open|close|resize|result` on GTK. While a viewer presents the session, an open is
/// handed to it as a job and the slot is only reserved here; `control-api.md`'s Remote sessions section owns
/// that contract.
@MainActor
extension AppController {
    func openSessionOverlay(_ target: String?, window: String?,
                            options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let response = gPresentation.openRemoteOverlay(in: store, sessionID: id, options: options) { return response }
            if store.session(withID: id)?.remoteOverlays.slot(options.pane) != nil {
                return err(options.pane == nil ? "overlay already open" : PaneOverlayError.alreadyOpen)
            }
            if let pane = options.pane {
                if let failure = store.openPaneOverlay(id, pane: pane, command: options.command,
                                                       cwd: options.cwd, wait: options.wait,
                                                       backgroundColor: options.backgroundColor) {
                    return paneOverlayFailure(failure, target: target)
                }
            } else {
                guard store.openOverlay(id, command: options.command, cwd: options.cwd, wait: options.wait,
                                        sizePercent: options.sizePercent,
                                        backgroundColor: options.backgroundColor) else {
                    return err("overlay already open")
                }
            }
            if options.follow { selectSession(id, userInitiated: false) }
            reconcile()
            return ok(id)
        }
    }

    private func paneOverlayFailure(_ failure: PaneOverlayOpenFailure, target: String?) -> ControlResponse {
        switch failure {
        case .unknownSession: return err("no such session: \(target ?? "active")")
        case .alreadyOpen: return err(PaneOverlayError.alreadyOpen)
        case .paneNotVisible: return err(PaneOverlayError.paneNotVisible)
        }
    }

    func closeSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            // a remote job first: a HUD opened here during its run shares the slot and must not absorb the close
            guard store.closeRemoteOverlay(id, pane: pane)
                    || pane.map({ store.closePaneOverlay(id, pane: $0) }) ?? store.closeOverlay(id) else {
                return err("no overlay")
            }
            reconcile()
            return ok(id)
        }
    }

    func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let resized = store.resizeRemoteOverlay(id, sizePercent: sizePercent) {
                return resized ? ok(id) : err(OverlayResultError.viewerGone)
            }
            guard store.resizeOverlay(id, sizePercent: sizePercent) else { return err("no overlay") }
            reconcile()
            // the surface stays mounted, so only the frame re-flows: a program never re-spawns and the HUD
            // helper repaints in place off the body file `writeHudBody` rewrote.
            resizeFloatingOverlayFrame(for: id)
            store.session(withID: id)?.onHudGeometryChange?()
            if store.session(withID: id)?.hudActive == true { store.publishHudResize(forSession: id, now: gHudAutoHide.now()) }
            return ok(id)
        }
    }

    func sessionOverlayResult(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            if let slot = session.remoteOverlays.slot(pane), !slot.ended { return err(OverlayResultError.stillRunning) }
            let (running, exitCode) = pane.map { (session.paneOverlay($0) != nil, session.paneOverlayExitCode($0)) }
                ?? (session.programOverlayActive, session.overlayExitCode)
            if running { return err(OverlayResultError.stillRunning) }
            if exitCode == nil, let failure = session.remoteOverlays.failure(pane) {
                return err(OverlayResultError.ended(failure))
            }
            // a HUD opened after a program clears its result, so one recorded here is a remote job's that ended
            // under a HUD; the painter itself never reports a status
            if exitCode == nil, pane == nil, session.hudActive { return err(OverlayHudError.noResult) }
            guard let code = exitCode else { return err(OverlayResultError.noResult) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, exitCode: code))
        }
    }
}
