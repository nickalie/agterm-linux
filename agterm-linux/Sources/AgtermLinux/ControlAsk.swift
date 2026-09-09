import CGtk
import Foundation
import agtermCore

/// Linux host for `ask.*`. Validation, navigation, the registry and the retained results are host-free;
/// this layer owns the two GTK presentations and the input arbitration between a dialog and its terminal.
///
/// The two styles differ in ownership, as upstream's do. A `terminal` ask belongs to its session: it draws
/// inside the deck, optionally clipped to one pane, and several sessions can hold one at a time. A `gui`
/// ask belongs to the window and shares the modal slot with `pick`; GTK gives it a real transient modal
/// window rather than a drawn panel, which is what a native question dialog is on this desktop.
@MainActor
extension AppController {
    func openAsk(_ ask: PendingAsk, target: String?, window: String?,
                 placement: ControlAskPlacement, follow: Bool) -> ControlResponse {
        if ask.style == .terminal {
            switch resolveSessionResponse(target) {
            case .failure(let response): return response
            case .success(let id): return presentTerminalAsk(ask, sessionID: id, placement: placement, follow: follow)
            }
        }
        if target != nil {
            switch resolveSessionResponse(target) {
            case .failure(let response): return response
            case .success(let id): return presentGuiAsk(ask, sessionID: id, placement: placement, follow: follow)
            }
        }
        return presentGuiAsk(ask, sessionID: nil, placement: placement, follow: follow)
    }

    private func presentTerminalAsk(_ ask: PendingAsk, sessionID: UUID,
                                    placement: ControlAskPlacement, follow: Bool) -> ControlResponse {
        guard let session = store.session(withID: sessionID) else { return err("no such session") }
        let identity: UUID?
        let pane: OverlayPane?
        switch LinuxPanePlacement.resolve(placement.pane, paneID: placement.paneID, in: session,
                                          requireVisible: true,
                                          invalidPaneError: "ask pane must be left or right") {
        case .resolved(let resolved, let target): (identity, pane) = (resolved, target)
        case .rejected(let response): return response
        }
        guard session.openAsk(ask, paneIdentity: identity) else { return err("ask already pending") }
        AskRegistry.shared.register(id: ask.id, owner: .session(sessionID, window: windowID))
        askWidgets.navigations[ask.id] = AskNavigation(buttons: ask.buttons, defaultID: ask.defaultID,
                                               destructiveID: ask.destructiveID)
        if follow { gtk_window_present(WIN(windowPointer)) }
        syncSessionAsks()
        return ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: pane?.rawValue))
    }

    private func presentGuiAsk(_ ask: PendingAsk, sessionID: UUID?,
                               placement: ControlAskPlacement, follow: Bool) -> ControlResponse {
        var anchor: AskAnchor?
        if let sessionID {
            guard let session = store.session(withID: sessionID) else { return err("no such session") }
            guard store.selectedSessionID == sessionID, !dashboard.isOpen, terminalZoom.target == nil else {
                return err("session not visible")
            }
            switch LinuxPanePlacement.resolve(placement.pane, paneID: placement.paneID, in: session,
                                              requireVisible: true,
                                              invalidPaneError: "ask pane must be left or right") {
            case .resolved(let identity, let pane):
                anchor = AskAnchor(sessionID: sessionID, pane: pane, paneIdentity: identity)
            case .rejected(let response): return response
            }
        }
        let pending = PendingAsk(id: ask.id, title: ask.title, message: ask.message, buttons: ask.buttons,
                                 defaultID: ask.defaultID, destructiveID: ask.destructiveID,
                                 style: ask.style, align: ask.align, width: ask.width, anchor: anchor)
        guard pickController.openAsk(pending) else {
            return err(pickController.pendingAsk != nil ? "ask already pending" : "pick already pending")
        }
        AskRegistry.shared.register(id: ask.id, owner: .window(windowID))
        askWidgets.navigations[ask.id] = AskNavigation(buttons: ask.buttons, defaultID: ask.defaultID,
                                               destructiveID: ask.destructiveID)
        if follow { gtk_window_present(WIN(windowPointer)) }
        closePalette()
        showGuiAsk(pending)
        return ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: anchor?.pane?.rawValue))
    }

    func askResult(_ target: String, window: String?) -> ControlResponse {
        withAskResult(target, window: window) { ControlResponse(ok: true, result: ControlResult(ask: $0)) }
    }

    func cancelAsk(_ target: String, window: String?) -> ControlResponse {
        withAskResult(target, window: window) { result in
            guard result.result == .pending else { return ControlResponse(ok: true) }
            switch AskRegistry.shared.owner(for: target) {
            case .window(let owner):
                guard let controller = gWindows[owner] else { return err("unknown ask: \(target)") }
                if controller.pickController.pendingAsk?.id == target { controller.cancelGuiAsk() }
            case .session(let sessionID, let owner):
                gWindows[owner]?.resolveSessionAsk(sessionID, id: target, ControlAskResult(result: .cancelled))
            case nil: return err("unknown ask: \(target)")
            }
            return ControlResponse(ok: true)
        }
    }

    private func withAskResult(_ id: String, window: String?,
                               _ body: (ControlAskResult) -> ControlResponse) -> ControlResponse {
        guard let retained = AskRegistry.shared.result(for: id) else { return err("unknown ask: \(id)") }
        guard window != nil else { return body(retained.result) }
        guard retained.windowID == windowID else { return err("unknown ask: \(id)") }
        return body(retained.result)
    }
}
