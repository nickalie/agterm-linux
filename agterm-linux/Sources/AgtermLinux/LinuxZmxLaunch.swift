import Foundation
import Glibc
import agtermCore

/// Where the Linux host gets the inputs `ZmxSupport` decides a wrapped pane from: the bundled zmx, the
/// account's login shell, the resolved ghostty resources, and the state directory the socket namespace
/// hashes. Everything past that is host-free.
enum LinuxZmxLaunch {
    typealias Disposition = ZmxSupport.LaunchDisposition

    struct SurfaceSeed: Equatable {
        let command: String
        let initialInput: String?
    }

    /// Whether this pane may be wrapped in a LOCAL daemon. A remote session never is: its pane is an ssh
    /// client, and a wrapper would keep that connection alive inside a surviving daemon after the window
    /// closed, with nothing in the UI showing it.
    @MainActor
    static func wrapsLocally(mode: RestoreMode, session: Session) -> Bool {
        mode == .live && session.remoteHost == nil
    }

    /// The staged binary, or the dev override. `AGTERM_ZMX` is what `scripts/stage-linux.sh` exports from
    /// the launcher; a source build points at the vendored copy through the same variable.
    static func executablePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["AGTERM_ZMX"], !override.isEmpty { return override }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        return executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libexec/zmx").path
    }

    /// Why Live sessions cannot run here, or nil when it can. Settings shows this beside the picker.
    static func liveUnavailableReason(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        passwordDatabaseShell: String? = passwordDatabaseLoginShell()
    ) -> String? {
        switch configurationResult(paneIdentity: UUID(), baseEnvironment: [:], environment: environment,
                                   passwordDatabaseShell: passwordDatabaseShell) {
        case .success: return nil
        case .failure(let reason): return reason.message
        }
    }

    @MainActor
    static func configuration(paneIdentity: UUID?, pane: String,
                              environment base: [String: String]) -> ZmxSupport.Configuration? {
        guard let paneIdentity else {
            FileHandle.standardError.write(Data("agterm: no pane identity for the \(pane) pane; not wrapping\n".utf8))
            return nil
        }
        switch configurationResult(paneIdentity: paneIdentity, baseEnvironment: base) {
        case .success(let configuration): return configuration
        case .failure(let reason):
            FileHandle.standardError.write(Data("agterm: zmx unavailable for the \(pane) pane: \(reason.message)\n".utf8))
            return nil
        }
    }

    static func disposition(requested: RestoreMode, active: RestoreMode,
                            configuration: ZmxSupport.Configuration?) -> Disposition {
        ZmxSupport.launchDisposition(requested: requested, active: active, configuration: configuration)
    }

    /// What a wrapped pane spawns with. The attach client is the command; a replayed or created program
    /// rides inside it, and only a FRESH primary pane types its creation command as input.
    @MainActor
    static func surfaceSeed(disposition: Disposition, session: Session, pane: StatusPane,
                            denylist: Set<String>) -> SurfaceSeed? {
        guard case .wrapped(let configuration) = disposition else { return nil }
        let replay = session.takePendingForegroundCommand(pane: pane)
        let creationCommand: String? = if session.wasRestored, replay == nil {
            switch pane {
            case .left: session.initialCommand
            case .right: session.splitInitialCommand
            case .scratch: nil
            }
        } else { nil }
        let initialInput = pane == .left && !session.wasRestored
            ? session.initialCommand.map { $0 + "\n" }
            : nil
        return SurfaceSeed(
            command: ZmxSupport.attachCommand(configuration, replaying: replay,
                                              creationCommand: creationCommand, denylist: denylist),
            initialInput: initialInput
        )
    }

    /// The account's shell from the password database, not `$SHELL`: sshd and a desktop session both set
    /// the latter from the former, but a user who exported another one still logs in through this.
    static func passwordDatabaseLoginShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let value = String(cString: shell)
        return value.isEmpty ? nil : value
    }

    private static func configurationResult(
        paneIdentity: UUID, baseEnvironment: [String: String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        passwordDatabaseShell: String? = passwordDatabaseLoginShell()
    ) -> Result<ZmxSupport.Configuration, ZmxSupport.Rejection> {
        // the same variable `GhosttyApp.setGhosttyResourcesEnv` exported, so the zsh integration zmx needs
        // is the one this process actually resolved
        let resources = environment["GHOSTTY_RESOURCES_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        return ZmxSupport.configuration(for: .init(
            zmxExecutablePath: executablePath(environment: environment),
            passwordDatabaseShell: passwordDatabaseShell,
            resourcesDirectory: resources,
            stateDirectory: linuxStateDirectory().path,
            paneIdentity: paneIdentity,
            baseEnvironment: baseEnvironment,
            inheritedZdotdir: environment["ZDOTDIR"]
        ))
    }
}
