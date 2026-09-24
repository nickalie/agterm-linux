import Foundation
import agtermCore

// MARK: - Viewer: mirroring an attached session's origin

extension LinuxPresentationService {
    /// Opens `session`'s presentation stream to its origin. A session that is not attached, or whose stream
    /// is already up, is left alone; a failure here never touches the terminal attach.
    func startRemotePresentation(for session: Session) {
        let id = session.id
        guard remoteClients[id] == nil, let host = session.remoteHost,
              let binding = session.remotePresentation?.binding,
              let argv = try? RemoteSession.presentCommand(host: host, session: binding.remoteSessionID) else { return }
        // an attach reaches here without a control request walking the windows, and soft close and undo
        // follow the row only through the hook this installs
        attach()
        let client = RemotePresentationClient(argv: argv, presentationVersion: binding.presentationVersion,
                                              transport: transport, effects: remoteEffects(for: id), now: clock)
        remoteClients[id] = client
        client.start()
        startRemoteTick()
    }

    func stopRemotePresentation(_ id: UUID) {
        remoteClients.removeValue(forKey: id)?.stop()
    }

    func stopRemotePresentations() {
        for client in remoteClients.values { client.stop() }
        remoteClients.removeAll()
        remoteTick?.cancel()
        remoteTick = nil
    }

    /// A soft close hides the row while its panes live on for undo, and undo or a restored workspace brings
    /// it back without passing through the attach, so the client follows the row and not the attach.
    func remoteRowVisibilityChanged(_ session: Session, shown: Bool) {
        if shown {
            startRemotePresentation(for: session)
        } else {
            stopRemotePresentation(session.id)
        }
    }

    /// Reconnects due clients and drops quiet links, once a second while any client runs.
    func tickRemoteClients() {
        for client in remoteClients.values { client.tick() }
    }

    private func startRemoteTick() {
        guard remoteTick?.isRunning != true else { return }
        remoteTick = LinuxRepeatingTimer(interval: 1) { [weak self] in
            guard let self, !self.remoteClients.isEmpty else {
                self?.remoteTick = nil
                return false
            }
            self.tickRemoteClients()
            return true
        }
    }

    private func remoteEffects(for id: UUID) -> RemotePresentationEffects {
        RemotePresentationEffects(
            status: { [weak self] status in
                self?.store(forSession: id)?.applyRemoteStatus(status, forSession: id)
                self?.changed(id, .sidebar)
            },
            snapshotStatus: { [weak self] status in
                self?.store(forSession: id)?.applyRemoteSnapshotStatus(status, forSession: id)
                self?.changed(id, .sidebar)
            },
            hud: { [weak self] hud in self?.showRemoteHud(hud, forSession: id) },
            notify: { [weak self] notify in
                guard let self, let store = store(forSession: id) else { return }
                host.deliverMirroredNotification(notify, sessionID: id, in: store)
            },
            connection: { [weak self] connection in
                self?.store(forSession: id)?.setRemoteConnection(connection, forSession: id)
                self?.changed(id, .sidebar)
                self?.changed(id, .title)
                self?.changed(id, .asks)
                self?.changed(id, .deck)
            },
            context: { [weak self] context in
                self?.store(forSession: id)?.applyRemoteContext(context, forSession: id)
                self?.changed(id, .title)
            },
            mode: { [weak self] mode in self?.store(forSession: id)?.setRemoteMode(mode, forSession: id) },
            askRequest: { [weak self] ask in self?.showReplicaAsk(ask, forSession: id) ?? false },
            askDismiss: { [weak self] ref in
                self?.store(forSession: id)?.dismissReplicaAsk(ref, forSession: id)
                self?.changed(id, .asks)
            },
            overlayRequest: { [weak self] overlay in self?.showReplicaOverlay(overlay, forSession: id) ?? false },
            overlayClose: { [weak self] change in
                self?.store(forSession: id)?.closeReplicaOverlay(change.job, forSession: id)
                self?.changed(id, .deck)
            },
            overlayResize: { [weak self] change in
                self?.store(forSession: id)?.resizeReplicaOverlay(change, forSession: id)
                self?.changed(id, .deck)
            },
            layout: { [weak self] layout in self?.applyRemoteLayout(layout, forSession: id) },
            warn: { reason in
                FileHandle.standardError.write(Data("agterm: presentation stream for \(id.uuidString): \(reason)\n".utf8))
            })
    }

    /// Shows an ask `id`'s origin handed over. A GUI one keeps the local rule of refusing a target that is not
    /// on screen; a terminal one, like a local terminal ask, waits hidden until its session is shown.
    private func showReplicaAsk(_ ask: PresentationAsk, forSession id: UUID) -> Bool {
        guard let store = store(forSession: id) else { return false }
        if ask.style == .gui, !host.guiTargetShown(id, in: store) { return false }
        let shown = store.presentReplicaAsk(ask, forSession: id) { [weak self] body in self?.remoteClients[id]?.answer(body) }
        if shown { changed(id, .asks) }
        return shown
    }

    /// Shows an overlay `id`'s origin handed over, running the job's helper on the origin over ssh.
    private func showReplicaOverlay(_ overlay: PresentationOverlay, forSession id: UUID) -> Bool {
        guard let store = store(forSession: id), let host = store.session(withID: id)?.remoteHost,
              let argv = try? RemoteSession.runJobCommand(host: host, job: overlay.job) else { return false }
        let shown = store.presentReplicaOverlay(overlay, command: CommandRestore.shellQuotedLine(argv),
                                                forSession: id) { [weak self] job in
            self?.remoteClients[id]?.answer(.overlayClosed(PresentationOverlayChange(job: job)))
        }
        if shown { changed(id, .deck) }
        return shown
    }

    /// Shows, updates or removes the HUD mirrored from `id`'s origin; `nil` removes it. Only a panel the
    /// bridge opened is ever replaced or closed: one this machine's own caller opened, or a program overlay
    /// in the slot, simply keeps it.
    func showRemoteHud(_ hud: PresentationHud?, forSession id: UUID) {
        guard let store = store(forSession: id), let session = store.session(withID: id),
              session.remotePresentation != nil else { return }
        // zero remaining means the origin's panel is already due down; showing it would outlive it
        guard let hud, hud.remaining != 0 else {
            if store.closeBridgedHud(forSession: id) { changed(id, .deck) }
            return
        }
        // this machine counts down what is left of the origin's interval, not the configured one again
        let spec = HudSpec(message: hud.spec.message, detail: hud.spec.detail, spinner: hud.spec.spinner,
                           backgroundColor: hud.spec.backgroundColor, textColor: hud.spec.textColor,
                           sizePercent: hud.spec.sizePercent, position: hud.spec.position,
                           hideAfter: hud.remaining, markdown: hud.spec.markdown, fontSize: hud.spec.fontSize)
        // resolved the same way for an open and an update, so an update never moves a session-wide panel
        // onto a pane the deck does not lay out
        let pane = store.localPane(hud.pane, in: session).flatMap { session.rendersPane($0) ? $0 : nil }
        let bridged = session.hudActive && session.remotePresentation?.hudBridged == true
        guard bridged || !session.hudActive else { return }
        let response = bridged
            ? host.updateMirroredHud(spec, pane: pane, sessionID: id)
            : host.openMirroredHud(spec, pane: pane, sessionID: id)
        guard response.ok else { return }
        store.markHudBridged(forSession: id)
    }

    /// Follows the origin's split for an existing realized pair of replicas. A swap goes through the host
    /// first, since the widgets move with the model; the store then finds the primary already in place.
    func applyRemoteLayout(_ layout: PresentationLayout, forSession id: UUID) {
        guard let store = store(forSession: id), let session = store.session(withID: id) else { return }
        if layout.isValid, let binding = session.remotePresentation?.binding, session.hasSplit,
           let split = session.splitPaneIdentity,
           session.surface?.isRealized == true, session.splitSurface?.isRealized == true,
           Set(layout.panes.compactMap(binding.localPane(forRemote:))) == [session.paneIdentity, split],
           layout.panes.count == 2, binding.localPane(forRemote: layout.primary) == split,
           !host.swapRemotePanes(id, in: store) {
            return
        }
        for local in store.applyRemoteLayout(layout, forSession: id) {
            host.closeRemovedRemotePane(local, sessionID: id, in: store)
        }
        changed(id, .deck)
    }

    /// A replica's ssh exited and the pane holds its exit line; a removal the origin already confirmed
    /// closes it now.
    func remotePaneHeld(_ local: UUID, forSession id: UUID) {
        guard let store = store(forSession: id) else { return }
        store.remotePaneHeld(local, forSession: id)
        host.closeRemovedRemotePane(local, sessionID: id, in: store)
    }
}
