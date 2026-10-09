import CGtk
import Foundation
import Glibc
import agtermCore

/// `session.restart`: ends a live pane's daemon and builds the pane a new surface whose daemon runs the
/// caller's line, or the pane's foreground program again, as upstream's `ControlServer+Restart` does. The GTK control path is synchronous, so each
/// wait spins the main loop instead of suspending. `.claude/rules/control-api.md` owns the contract.
@MainActor
extension AppController {
    private static let restartWait: TimeInterval = 10

    private struct RestartTarget {
        let session: Session
        let surface: GhosttySurface
        let identity: UUID
        let daemon: String
        let pane: StatusPane
    }

    func restartSessionPaneSync(_ target: String?, window: String?,
                                options: ControlSessionRestartOptions) -> ControlResponse {
        let resolved: RestartTarget
        switch resolveRestartTarget(target, options: options) {
        case .failure(let response): return response
        case .success(let value): resolved = value
        }
        let (session, old, client) = (resolved.session, resolved.surface, gZmx.client)
        let lead = ZmxLeadAttachment(claim: false)
        guard let zmx = LinuxZmxLaunch.configuration(paneIdentity: resolved.identity,
                                                     pane: resolved.pane == .right ? "split" : "primary",
                                                     environment: old.env, lead: lead) else {
            return err("live sessions are unavailable for this pane")
        }
        // a pane just created reads as backed before zmx has finished creating its daemon
        guard let oldPid = shell(daemon: resolved.daemon, otherThan: nil, within: 5) else {
            return err("the pane's shell is not running")
        }
        // a session waiting out its undo window is not in the open store: killing its shell would leave undo
        // a dead pane to restore
        guard paneSurface(of: session, resolved.pane) === old, store.session(withID: session.id) != nil else {
            return err("the pane changed before the restart; nothing was started")
        }
        var replay: RestartReplay.Launch?
        if options.command == nil {
            switch replayLaunch(of: old, leader: oldPid) {
            case .failure(let refusal): return err(refusal.message)
            case .success(let launch): replay = launch
            }
        }
        // read before the kill: without it the restart could not tell when the old program is gone
        guard let program = client.foregroundJob(ofShell: oldPid) else {
            return err("the process table cannot be read, so the old program could not be tracked; nothing was changed")
        }
        switch client.killConfirmed(name: resolved.daemon) {
        case .killed: break
        case .staleSocket: return err("\(resolved.daemon) did not confirm the kill; nothing was started")
        case .failed(let reason): return err("could not end the pane's shell: \(reason); nothing was started")
        }
        // claimed before the main loop runs again: the dead client's exit would close the pane
        _ = old.claimProcessExit()
        // the dying client reports `unowned`, which would reattach to a daemon that is gone
        ZmxLeadBook.shared.forget(pane: resolved.identity)
        // the new shell starts only once the old program is gone, so it cannot meet a held port or lock
        guard programEnded(program) else {
            closeEndedPane(old, session: session, identity: resolved.identity)
            return err("the old shell ended (pid \(oldPid)) but its program is still running; "
                + "nothing was started and the pane was closed")
        }
        guard let role = session.paneRole(forIdentity: resolved.identity),
              paneSurface(of: session, role == .right ? .right : .left) === old,
              store.session(withID: session.id) != nil else {
            closeEndedPane(old, session: session, identity: resolved.identity)
            return err("the old shell ended (pid \(oldPid)) and the pane changed during the restart; nothing was started")
        }
        let pane: StatusPane = role == .right ? .right : .left
        store.clearPaneOwnedState(session.id, pane: pane)
        let cwd = session.cwd(for: pane == .right ? .right : .left)
        let launch = PaneReattach(
            // the denylist was applied before the kill: a rejection here would start a plain shell instead
            command: ZmxSupport.attachCommand(zmx, replaying: replay?.argv, creationCommand: options.command, denylist: []),
            wait: false, environment: zmx.environment,
            workingDirectory: replay?.workingDirectory ?? (FileManager.default.fileExists(atPath: cwd) ? cwd : old.cwd))
        guard let fresh = replacePane(old, launch: launch, lead: lead, cover: false) else {
            closeEndedPane(old, session: session, identity: resolved.identity)
            return err("the old shell ended (pid \(oldPid)) and the pane could not be rebuilt; it was closed")
        }
        guard spin(until: { fresh.isRealized }, within: 2) else {
            closeEndedPane(fresh, session: session, identity: resolved.identity)
            return err("the old shell ended (pid \(oldPid)) and the new terminal could not be created; the pane was closed")
        }
        guard let newPid = shell(daemon: resolved.daemon, otherThan: oldPid, within: Self.restartWait) else {
            return err("the old shell ended (pid \(oldPid)) and no new one was observed")
        }
        let receipt = ControlRestartReceipt(paneID: resolved.identity.uuidString, oldPid: oldPid, newPid: newPid,
                                            replayedArgv: replay?.argv)
        let replayed = replay.map { "; replay requested: \(CommandRestore.shellQuotedLine($0.argv))" } ?? ""
        return ControlResponse(ok: true, result: ControlResult(
            id: session.id.uuidString, text: "restarted \(pane.rawValue) pane: shell \(oldPid) -> \(newPid)\(replayed)",
            pane: pane.rawValue, restart: receipt))
    }

    /// The pane's foreground program and the directory it runs in, read from a fresh leader listing.
    private func replayLaunch(of surface: GhosttySurface, leader: pid_t) -> Result<RestartReplay.Launch, RestartReplay.Refusal> {
        let observed = surface.observedForeground(zmxSnapshot: gZmx.foreground.freshSnapshot(timeout: 1))
        let directory = observed.flatMap { Self.workingDirectory(of: $0.pid) }
        let shell = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
        return RestartReplay.resolve(
            .init(foreground: observed?.foreground, isDaemonLeader: observed?.pid == leader, workingDirectory: directory),
            shell: shell, denylist: restoreDenylist())
    }

    /// The process's working directory through `/proc/<pid>/cwd`, nil when unreadable or not a directory.
    nonisolated static func workingDirectory(of pid: Int32) -> String? {
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/cwd") else {
            return nil
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? path : nil
    }

    private func resolveRestartTarget(_ target: String?, options: ControlSessionRestartOptions)
        -> ResolveResponse<RestartTarget> {
        let id: UUID
        switch resolveSessionResponse(target) {
        case .failure(let response): return .failure(response)
        case .success(let resolved): id = resolved
        }
        guard let session = store.session(withID: id) else { return .failure(err("no such session: \(target ?? "active")")) }
        if let host = session.remoteHost {
            return .failure(err("session.restart needs a local pane; this session runs on \(host)"))
        }
        // a token that resolves to nothing is refused even beside `--pane`: the role may by now name a
        // different terminal than the one the caller meant to end
        if let token = options.paneID, session.paneRole(forToken: token) == nil {
            return .failure(err("unknown pane id: \(token)"))
        }
        let pane: StatusPane
        switch session.paneAddress(token: options.paneID, pane: options.pane) {
        case .unknownToken(let token): return .failure(err("unknown pane id: \(token)"))
        case .pane(.scratch), .pane(nil): return .failure(err("session.restart does not address the scratch pane"))
        case .pane(let resolved?): pane = resolved
        }
        if pane == .right, splitSurfaces[id] == nil { return .failure(err("session has no split pane")) }
        guard let surface = paneSurface(of: session, pane), let identity = UUID(uuidString: surface.paneToken) else {
            return .failure(err("session not realized"))
        }
        guard surface.backedByZmx, gZmx.client.isAvailable else {
            return .failure(err("session.restart needs Live sessions mode; this pane has no live shell to replace"))
        }
        return .success(RestartTarget(session: session, surface: surface, identity: identity,
                                      daemon: ZmxSupport.daemonName(for: identity), pane: pane))
    }

    private func paneSurface(of session: Session, _ pane: StatusPane) -> GhosttySurface? {
        pane == .right ? splitSurfaces[session.id] : surfaces[session.id]
    }

    /// closeEndedPane runs the exit transition the restart claimed, for a restart that stops after its kill:
    /// the pane has no shell, and with its exit claimed nothing else would ever close it. A session
    /// soft-closed meanwhile sits in a pending close, where undo would restore that dead pane, so the close is
    /// made final instead.
    private func closeEndedPane(_ surface: GhosttySurface, session: Session, identity: UUID) {
        guard store.session(withID: session.id) != nil else {
            _ = library.store(holdingSession: session.id)?.finalizePendingClose(ofSession: session.id)
            return
        }
        if splitSurfaces[session.id] === surface {
            closeSplitPane(session.id, alreadyFinalized: identity)
        } else {
            closePrimaryPane(session.id, alreadyFinalized: identity)
        }
    }

    /// programEnded gives the old foreground program a second to act on the hangup the kill sent it, then
    /// kills it: a restart replaces the program, so one that ignores a hangup cannot stay. False when it
    /// outlives the kill too, as a program this user cannot signal does.
    private func programEnded(_ job: [ProcessRecord]) -> Bool {
        let client = gZmx.client
        if spin(until: { !client.isRunning(job) }, within: 1) { return true }
        client.forceEnd(job)
        return spin(until: { !client.isRunning(job) }, within: 0.5)
    }

    /// shell returns the leader pid `zmx list` reports for `daemon` once it differs from `otherThan`, nil
    /// when none shows up in time.
    private func shell(daemon: String, otherThan: pid_t?, within wait: TimeInterval) -> pid_t? {
        var found: pid_t?
        _ = spin(until: {
            guard let pid = gZmx.client.sessionLeaderPIDs(timeout: 1)?[daemon], pid != otherThan else { return false }
            found = pid
            return true
        }, within: wait)
        return found
    }

    /// spin runs the main loop until `done` holds or `wait` elapses, checking every 100 ms.
    private func spin(until done: () -> Bool, within wait: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(wait)
        while true {
            while g_main_context_iteration(nil, 0) != 0 {}
            if done() { return true }
            if Date() >= deadline { return false }
            usleep(100_000)
        }
    }
}
