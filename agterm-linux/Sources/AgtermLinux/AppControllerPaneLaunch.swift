import Foundation
import agtermCore

/// What a primary or split pane spawns with. `command` and `initialInput` are mutually exclusive except on
/// a zmx-backed pane, whose command is the attach client and whose input is a fresh session's creation
/// command.
struct LinuxPaneLaunch {
    let command: String?
    let initialInput: String?
    let waitAfterCommand: Bool
    let environment: [String: String]
    let backedByZmx: Bool
    /// Whether this pane starts a program and so belongs in the launch spawn queue.
    let paces: Bool
}

@MainActor
extension AppController {
    /// The launch policy this process froze before the first surface. Settings changes never move it, so a
    /// window opened hours later spawns under the same mode as the first.
    var restoreEnabled: Bool { gZmx.activeMode == .rerun }

    /// Resolves one pane's spawn. A live pane is wrapped in its own daemon and everything it would have
    /// replayed rides inside the attach; every other mode keeps `CommandRestore.restorePlan`.
    func paneLaunch(for session: Session, pane: StatusPane) -> LinuxPaneLaunch {
        let base = sessionEnv(for: session, pane: pane)
        let identity = pane == .right ? session.splitPaneIdentity : session.paneIdentity
        let configuration = LinuxZmxLaunch.wrapsLocally(mode: gZmx.activeMode, session: session)
            ? LinuxZmxLaunch.configuration(paneIdentity: identity,
                                           pane: pane == .right ? "split" : "primary", environment: base)
            : nil
        let disposition = LinuxZmxLaunch.disposition(requested: gZmx.requestedMode,
                                                     active: gZmx.activeMode, configuration: configuration)
        switch disposition {
        case .wrapped(let configuration):
            gZmx.foreground.noteLifecycleChange()
            let paces = pacesWrapped(session: session, pane: pane, configuration: configuration)
            guard let seed = LinuxZmxLaunch.surfaceSeed(disposition: disposition, session: session,
                                                        pane: pane, denylist: restoreDenylist()) else {
                return plainLaunch(session: session, pane: pane, environment: base)
            }
            return LinuxPaneLaunch(command: seed.command, initialInput: seed.initialInput,
                                   waitAfterCommand: false, environment: configuration.environment,
                                   backedByZmx: true, paces: paces)
        case .fallback:
            // live was requested and is unavailable: neither pending slot is read, so both stay armed for
            // the next launch and the durable command is held back like a restored rerun-off pane
            let plan = CommandRestore.restorePlan(.init(
                wasRestored: session.wasRestored, restoreEnabled: false, hadForeground: false,
                foregroundInput: nil, initialCommand: durableCommand(session: session, pane: pane),
                restoreOverride: nil, requestedWait: requestedWait(session: session, pane: pane)))
            return LinuxPaneLaunch(command: plan.command, initialInput: plan.initialInput,
                                   waitAfterCommand: plan.waitAfterCommand, environment: base,
                                   backedByZmx: false, paces: false)
        case .ordinary:
            return plainLaunch(session: session, pane: pane, environment: base)
        }
    }

    private func plainLaunch(session: Session, pane: StatusPane,
                             environment: [String: String]) -> LinuxPaneLaunch {
        let capture = session.takePendingForegroundCommand(pane: pane)
        let plan = CommandRestore.restorePlan(.init(
            wasRestored: session.wasRestored,
            restoreEnabled: restoreEnabled,
            hadForeground: capture != nil,
            foregroundInput: consumeRestoreInput(capture),
            initialCommand: durableCommand(session: session, pane: pane),
            restoreOverride: session.takePendingRestoreOverride(pane: pane),
            requestedWait: requestedWait(session: session, pane: pane)))
        let paces = session.wasRestored && (plan.command != nil || plan.initialInput != nil)
        return LinuxPaneLaunch(command: plan.command, initialInput: plan.initialInput,
                               waitAfterCommand: plan.waitAfterCommand, environment: environment,
                               backedByZmx: false, paces: paces)
    }

    /// A wrapped pane only paces when its attach will actually start something: an observed daemon is
    /// reattached to and runs nothing. The pending `session.restore` pin is deliberately absent —
    /// `surfaceSeed` never reads it.
    private func pacesWrapped(session: Session, pane: StatusPane,
                              configuration: ZmxSupport.Configuration) -> Bool {
        guard session.wasRestored else { return false }
        if gZmx.runningNames?.contains(configuration.daemonName) == true { return false }
        if let capture = peekCapture(session: session, pane: pane) {
            return CommandRestore.shouldRestore(argv: capture, denylist: restoreDenylist())
        }
        return durableCommand(session: session, pane: pane) != nil
    }

    func restoreDenylist() -> Set<String> {
        let path = ConfigPaths.restoreDenylistPath(configDirectory: configDirectory())
        return (try? String(contentsOf: path, encoding: .utf8)).map(CommandRestore.parseDenylist)
            ?? ["tmux", "screen", "zellij"]
    }

    private func peekCapture(session: Session, pane: StatusPane) -> [String]? {
        switch pane {
        case .left: session.pendingForegroundCommand
        case .right: session.pendingSplitForegroundCommand
        case .scratch: nil
        }
    }

    private func durableCommand(session: Session, pane: StatusPane) -> String? {
        switch pane {
        case .left: session.initialCommand
        case .right: session.splitInitialCommand
        case .scratch: nil
        }
    }

    private func requestedWait(session: Session, pane: StatusPane) -> Bool {
        switch pane {
        case .left: session.commandWait
        case .right: session.splitCommandWait
        case .scratch: false
        }
    }
}
