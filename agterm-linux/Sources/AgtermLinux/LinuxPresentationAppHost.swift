import Foundation
import agtermCore

/// This app's remote presentation, both roles. The control server serves its streams unless a test injects
/// its own service.
@MainActor let gPresentation = LinuxPresentationService(host: LinuxPresentationAppHost())

/// The GTK windows behind `LinuxPresentationService`: every effect lands in the window holding the session
/// at the time it arrives.
@MainActor
final class LinuxPresentationAppHost: LinuxPresentationHost {
    /// Windows with a sidebar rebuild already queued, so a burst of frames costs one rebuild.
    private var pendingSidebars: Set<UUID> = []

    var library: WindowLibrary? { gLibrary }

    private func controller(for store: AppStore) -> AppController? {
        gLibrary?.windowID(for: store).flatMap { gWindows[$0] }
    }

    func sessionEnvironment(for session: Session, in store: AppStore) -> [String: String] {
        controller(for: store)?.sessionEnv(for: session) ?? [:]
    }

    func openMirroredHud(_ spec: HudSpec, pane: OverlayPane?, sessionID: UUID) -> ControlResponse {
        guard let store = gLibrary?.store(forSession: sessionID), let controller = controller(for: store) else {
            return ControlResponse(ok: false, error: "no such session")
        }
        // a pane the origin placed its panel over may not be laid out here, so this falls back to session-wide
        return controller.openCommandFailureHud(sessionID, spec: spec, pane: pane)
    }

    func updateMirroredHud(_ spec: HudSpec, pane: OverlayPane?, sessionID: UUID) -> ControlResponse {
        guard let store = gLibrary?.store(forSession: sessionID), let controller = controller(for: store) else {
            return ControlResponse(ok: false, error: "no such session")
        }
        return controller.updateHud(sessionID.uuidString, window: nil, spec: spec,
                                    placement: ControlHudPlacement(pane: pane))
    }

    func guiTargetShown(_ sessionID: UUID, in store: AppStore) -> Bool {
        guard let controller = controller(for: store) else { return false }
        return store.selectedSessionID == sessionID && controller.terminalZoom.target == nil
            && !controller.dashboard.isOpen
    }

    func openTakenBackGuiAsk(_ ask: PendingAsk, session: Session, in store: AppStore) -> Bool {
        guard let controller = controller(for: store) else { return false }
        return controller.openTakenBackGuiAsk(ask)
    }

    func deliverMirroredNotification(_ notify: PresentationNotify, sessionID: UUID, in store: AppStore) {
        // `.mirrored`, so this app's own hub never relays it onward
        controller(for: store)?.deliverNotification(sessionID, title: notify.title, body: notify.body, origin: .mirrored)
    }

    func swapRemotePanes(_ sessionID: UUID, in store: AppStore) -> Bool {
        controller(for: store)?.swapPanes(sessionID) == nil
    }

    func closeRemovedRemotePane(_ local: UUID, sessionID: UUID, in store: AppStore) {
        controller(for: store)?.closeRemovedRemotePane(local, sessionID: sessionID)
    }

    func presentationChanged(_ sessionID: UUID, in store: AppStore, _ change: LinuxPresentationChange) {
        guard let controller = controller(for: store) else { return }
        switch change {
        case .sidebar: scheduleSidebarRebuild(controller)
        case .title: if store.selectedSessionID == sessionID { controller.updateTitle() }
        case .asks: controller.syncSessionAsks()
        case .deck: controller.reconcile(focusActive: false)
        }
    }

    /// Frames arrive on their own schedule, so the rebuild waits out an inline rename like every deferred one.
    private func scheduleSidebarRebuild(_ controller: AppController, after delay: TimeInterval = 0.01) {
        let id = controller.windowID
        guard pendingSidebars.insert(id).inserted else { return }
        MainTimer.schedule(after: delay) { [weak self, weak controller] in
            self?.pendingSidebars.remove(id)
            guard let controller, gWindows[id] === controller else { return }
            guard !controller.sidebarInteractionInProgress else {
                self?.scheduleSidebarRebuild(controller, after: AppController.sidebarInteractionRetryInterval)
                return
            }
            controller.rebuildSidebar()
        }
    }
}

@MainActor
extension AppController {
    /// Moves a taken-back GUI ask into this window's modal slot, as a local GUI open does. False when a pick
    /// or another GUI ask holds the slot.
    func openTakenBackGuiAsk(_ ask: PendingAsk) -> Bool {
        guard pickController.openAsk(ask) else { return false }
        askWidgets.navigations[ask.id] = AskNavigation(buttons: ask.buttons, defaultID: ask.defaultID,
                                                       destructiveID: ask.destructiveID)
        closePalette()
        showGuiAsk(ask)
        return true
    }

    /// Records a notification for `id` and raises its banner: the `notify` command's delivery, and a
    /// mirrored one's.
    @discardableResult
    func deliverNotification(_ id: UUID, title: String, body: String, origin: NotificationOrigin) -> String {
        let delivery = store.recordTerminalNotification(TerminalNotificationRecord(sessionID: id, windowID: windowID,
                                                                                   pane: .main, title: title,
                                                                                   body: body, firingIsFocused: false,
                                                                                   appActive: false), origin: origin)
        let bannerTitle = delivery?.title ?? title
        rebuildSidebar()
        if NotificationManager.bannersEnabled {
            NotificationManager.send(title: bannerTitle, body: body,
                                     target: TerminalNotification.identity(windowID: windowID, sessionID: id, pane: .main))
        }
        return bannerTitle
    }

    /// Closes a replica its origin removed, once the store allows it. The last realized replica keeps its
    /// terminal until its ssh exits.
    func closeRemovedRemotePane(_ local: UUID, sessionID id: UUID) {
        guard store.canCloseRemovedRemotePane(local, forSession: id), let session = store.session(withID: id) else { return }
        let split = session.splitPaneIdentity == local
        let surface = split ? splitSurfaces[id] : surfaces[id]
        if split, surface == nil {
            store.closeSplit(id)
            reconcile(focusActive: false)
            return
        }
        let survivor = split ? surfaces[id] : splitSurfaces[id]
        guard let surface, survivor?.isRealized == true || store.remotePaneIsHeld(local, forSession: id),
              surface.claimProcessExit() else { return }
        if split {
            closeSplitPane(id)
        } else {
            closePrimaryPane(id)
        }
    }
}

@MainActor
extension GhosttySurface {
    /// The command exited and `waitAfterCommand` holds the surface on its exit prompt: the pane lead forgets
    /// the pane, a replica overlay records its end, and a replica pane is checked against the origin's layout.
    func exitHeld() {
        leadExitHeld()
        guard let controller, let session = controller.store.session(withID: sessionID) else { return }
        if role == .overlay {
            let pane = session.paneOverlayRole(of: self)
            guard pane != nil || session.overlaySurface === self else { return }
            controller.store.replicaOverlayHeld(forSession: sessionID, pane: pane)
            controller.reconcile(focusActive: false)
            return
        }
        let local = session.surface === self ? session.paneIdentity
            : session.splitSurface === self ? session.splitPaneIdentity : nil
        guard let local, session.remotePresentation != nil else { return }
        gPresentation.remotePaneHeld(local, forSession: sessionID)
    }
}
