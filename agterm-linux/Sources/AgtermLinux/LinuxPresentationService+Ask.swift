import Foundation
import agtermCore

// MARK: - Origin: asks handed to a presenter

extension LinuxPresentationService {
    /// Hands a session-associated ask to the viewer presenting that session, nil when none does. Visibility
    /// here is irrelevant, since nothing is drawn here; the pane only has to exist, and the viewer refuses one
    /// it cannot show. `follow` raises nothing for the same reason.
    func presentAskRemotely(_ ask: PendingAsk, in store: AppStore, sessionID: UUID,
                            placement: ControlAskPlacement, windowID: UUID) -> ControlResponse? {
        attach()
        guard hub.hasPresenter(session: sessionID), let session = store.session(withID: sessionID) else { return nil }
        switch LinuxPanePlacement.resolve(placement.pane, paneID: placement.paneID, in: session,
                                          requireVisible: false, invalidPaneError: "ask pane must be left or right") {
        case .resolved(let identity, let pane):
            guard let opened = store.presentAskRemotely(ask, in: session, paneIdentity: identity, window: windowID) else {
                return nil
            }
            guard opened else { return ControlResponse(ok: false, error: "ask already pending") }
            return ControlResponse(ok: true, result: ControlResult(id: ask.id, pane: pane?.rawValue))
        case .rejected(let response):
            return response
        }
    }

    /// Takes back the ask a viewer was presenting for `sessionID`, after the viewer went away or refused it.
    /// A terminal ask is drawn here from now on; a GUI one moves into its window's slot when its target is
    /// shown and the slot is free, and otherwise ends cancelled with `presentation-lost`.
    func takeBackRemoteAsk(forSession sessionID: UUID) {
        guard let store = store(forSession: sessionID) else { return }
        defer { host.presentationChanged(sessionID, in: store, .asks) }
        guard let ask = store.takeBackRemoteAsk(forSession: sessionID) else { return }
        guard let session = store.session(withID: sessionID), guiAskFits(session, in: store) else {
            store.failHandback(forSession: sessionID)
            return
        }
        let anchor = AskAnchor(sessionID: sessionID, pane: session.askTargetPane, paneIdentity: session.askPaneIdentity)
        let local = PendingAsk(id: ask.id, title: ask.title, message: ask.message, buttons: ask.buttons,
                               defaultID: ask.defaultID, destructiveID: ask.destructiveID, style: ask.style,
                               align: ask.align, width: ask.width, anchor: anchor)
        guard let windowID = library?.windowID(for: store), host.openTakenBackGuiAsk(local, session: session, in: store) else {
            store.failHandback(forSession: sessionID)
            return
        }
        session.releaseAsk()
        AskRegistry.shared.reassign(id: ask.id, to: .window(windowID))
    }

    /// Whether a GUI ask anchored to `session` could be shown now: the rule a local open applies.
    private func guiAskFits(_ session: Session, in store: AppStore) -> Bool {
        guard host.guiTargetShown(session.id, in: store) else { return false }
        guard session.askPaneIdentity != nil else { return true }
        guard let pane = session.askTargetPane else { return false }
        return session.rendersPane(pane)
    }

    /// Applies what a session's presenter sent about work it was handed.
    func receivePresenterFrame(_ body: PresentationFrame.Body, forSession sessionID: UUID) {
        guard let store = store(forSession: sessionID) else { return }
        switch body {
        case .askResolve(let answer):
            if store.resolveRemoteAsk(answer, forSession: sessionID) { host.presentationChanged(sessionID, in: store, .asks) }
        case .askRejected(let ref) where store.isPresentingRemotely(ref, forSession: sessionID):
            takeBackRemoteAsk(forSession: sessionID)
        case .overlayRejected(let change):
            store.rejectRemoteOverlay(change.job, forSession: sessionID)
        case .overlayClosed(let change):
            store.remoteOverlaySurfaceClosed(change.job, forSession: sessionID)
        default:
            break
        }
    }
}
