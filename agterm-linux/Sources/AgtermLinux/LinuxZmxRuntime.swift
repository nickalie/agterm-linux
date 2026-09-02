import Foundation
import agtermCore

/// The process-wide Live-sessions state, assembled once before the window library reads its inventory.
///
/// The launch decision is FROZEN here: a Settings change never mutates it, so every later pane, the reap
/// and a window reopened hours in all follow the policy this launch started under.
@MainActor
final class LinuxZmxRuntime {
    let launchDecision: RestoreLaunchDecision
    let client: LinuxZmxClient
    let foreground: LinuxZmxForegroundResolver
    /// The daemons the launch reap saw alive. A SCHEDULING hint only: nil means the listing failed, and a
    /// name that died between the list and the attach merely spawns unpaced.
    var runningNames: Set<String>?

    var requestedMode: RestoreMode { launchDecision.requested }
    var activeMode: RestoreMode { launchDecision.active }
    var liveUnavailableReason: String? { launchDecision.liveUnavailableReason }
    /// Rerun and live both capture at quit: live's capture is the fallback for a daemon that did not
    /// survive, which is what makes a reboot come back with the command rather than a bare shell.
    var capturesForegroundOnExit: Bool { activeMode == .rerun || activeMode == .live }

    init(settings: AppSettings) {
        launchDecision = settings.effectiveRestoreMode.launchDecision(
            liveUnavailableReason: LinuxZmxLaunch.liveUnavailableReason())
        let client = LinuxZmxClient(
            executablePath: LinuxZmxLaunch.executablePath(),
            socketDirectory: ZmxSupport.socketDirectory(forStateDirectory: linuxStateDirectory().path))
        self.client = client
        foreground = LinuxZmxForegroundResolver(leaderProvider: { [client] timeout in
            MainActor.assumeIsolated { client.sessionLeaderPIDs(timeout: timeout) }
        })
    }

    /// The window library wired to this runtime: a closed pane's daemon dies with it, the launch
    /// inventory drives the reap, and a dropped pane leaves the spawn queue.
    func makeLibrary(directory: URL) -> WindowLibrary {
        WindowLibrary(
            directory: directory,
            paneFinalizer: { [client, foreground] identities in
                _ = client.kill(paneIdentities: identities)
                foreground.noteLifecycleChange()
            },
            launchInventorySink: { [weak self] identities in
                guard let self else { return }
                runningNames = client.reap(knownPaneIdentities: identities,
                                           launchDecision: launchDecision).runningNames
                foreground.noteLifecycleChange()
            },
            launchPaneDrop: { identities in
                for identity in identities { gSpawnPacer.discard(identity) }
            })
    }
}

@MainActor var gZmx: LinuxZmxRuntime!
