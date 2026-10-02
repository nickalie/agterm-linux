import Foundation
import agtermCore

/// Attaches remote panes again after their ssh lost the connection, as `ControlServer+RemoteReconnect` does on
/// macOS. `RemoteReconnectBook` owns the schedule; the probes run on the remote tick, each on a thread of its
/// own, since the GLib loop drains no Swift Concurrency executor.
@MainActor
extension LinuxPresentationService {
    nonisolated static let reconnectProbeDeadline: TimeInterval = 10

    func waitToReconnect(_ surface: GhosttySurface, cover: Bool) {
        attach()
        guard let session = heldSession(surface.sessionID), let host = session.remoteHost,
              let pane = session.surface === surface ? session.paneIdentity
                  : session.splitSurface === surface ? session.splitPaneIdentity : nil else { return }
        RemoteReconnectBook.shared.wait(pane: pane, session: session.id, host: host, cover: cover, now: clock())
        startRemoteTick()
    }

    func tickReconnects() {
        let book = RemoteReconnectBook.shared
        for pane in book.due(now: clock()) {
            guard let entry = book.entries[pane], waitingSurface(pane, in: entry.session) != nil,
                  let argv = try? RemoteSession.probeCommand(host: entry.host) else {
                book.cancel(pane: pane)
                continue
            }
            probe(argv) { [weak self] answered in self?.probeFinished(pane, answered: answered) }
        }
    }

    private func probeFinished(_ pane: UUID, answered: Bool) {
        let book = RemoteReconnectBook.shared
        guard let entry = book.finished(pane: pane, ok: answered, now: clock()),
              let surface = waitingSurface(pane, in: entry.session) else { return }
        // a row hidden for undo keeps waiting; finalizing its close lets the next due probe drop it
        guard let store = store(forSession: entry.session), reattach(surface, entry.cover) else {
            book.wait(pane: pane, session: entry.session, host: entry.host, cover: entry.cover, now: clock())
            return
        }
        store.remotePaneResumed(pane, forSession: entry.session)
    }

    /// runProbe is the default `probe`: one ssh round trip on a worker thread, answered on the GTK thread.
    static func runProbe(_ argv: [String], done: @escaping @MainActor (Bool) -> Void) {
        let box = ProbeCompletion(done)
        let deadline = reconnectProbeDeadline
        Thread.detachNewThread {
            let answered = LinuxRemoteCommandRunner.run(argv, deadline: deadline).status == 0
            runOnMain { MainActor.assumeIsolated { box.done(answered) } }
        }
    }

    /// The surface still holding `pane`, nil once the pane or its row is gone. A row closed within its undo
    /// window still holds it.
    private func waitingSurface(_ pane: UUID, in sessionID: UUID) -> GhosttySurface? {
        guard let session = heldSession(sessionID) else { return nil }
        let surface = session.paneIdentity == pane ? session.surface
            : session.splitPaneIdentity == pane ? session.splitSurface : nil
        return surface as? GhosttySurface
    }

    private func heldSession(_ id: UUID) -> Session? {
        guard let store = library?.store(holdingSession: id) else { return nil }
        return store.session(withID: id) ?? store.pendingCloseSession(withID: id)
    }
}

/// Carries a probe's completion across its worker thread; only the GTK thread calls it.
final class ProbeCompletion: @unchecked Sendable {
    let done: @MainActor (Bool) -> Void
    init(_ done: @escaping @MainActor (Bool) -> Void) { self.done = done }
}

@MainActor
extension GhosttySurface {
    /// The attach wrapper's lost-connection report. Only the pane's current attachment is believed, and only an
    /// origin that reported a role before will report one after the attach, so only it is covered. A reconnect
    /// that lost the link before its first report inherits that from the attach it replaced.
    func linkLost(_ notice: RemoteLinkNotice) {
        guard let pane = leadPaneIdentity, ZmxLeadBook.shared.states[pane]?.attachment.nonce == notice.nonce else { return }
        let cover = ZmxLeadBook.shared.role(pane: pane) != nil || ZmxLeadBook.shared.reattaching(pane: pane)
        // stopped like an attach on its exit prompt: no client is left to report a role
        exitHeld()
        gPresentation.waitToReconnect(self, cover: cover)
    }

    /// The press on a pane waiting to reconnect: app shortcuts run, Ctrl+Shift chords stay Ghostty's own binds
    /// as Command chords do on macOS, and any other press retries at once. Nil when the pane is not waiting.
    func reconnectKeyGate(keyval: UInt32, keycode: UInt32, state: UInt32, event: OpaquePointer?) -> Bool? {
        guard let pane = leadPaneIdentity, RemoteReconnectBook.shared.waiting(pane: pane) else { return nil }
        if controller?.handleKey(keyval: keyval, keycode: keycode, state: state, sessionID: sessionID,
                                 origin: self, context: shortcutKeyContext(event: event, keycode: keycode)) == true {
            return true
        }
        switch ReconnectKey.classify(state: state, modifier: ModifierKeyMods.modifierBit(forKeyval: keyval) != nil) {
        case .terminal: return nil
        case .swallow: return true
        case .retry:
            // owned until released, so its repeats never reach the fresh surface, which may be covered
            gKeyPressOwnership.claim(keycode, now: ProcessInfo.processInfo.systemUptime)
            RemoteReconnectBook.shared.retryNow(pane: pane, now: Date())
            return true
        }
    }
}

/// What a press that no app shortcut took does to a pane waiting to reconnect.
enum ReconnectKey: Equatable {
    case terminal, swallow, retry

    static func classify(state: UInt32, modifier: Bool) -> ReconnectKey {
        let chord = PaneLeadKey.controlMask | PaneLeadKey.shiftMask
        if state & chord == chord { return .terminal }
        return modifier ? .swallow : .retry
    }
}
