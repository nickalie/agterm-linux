import Foundation
import Glibc
import agtermCore

/// Runs an ssh invocation, blocking the CALLING thread.
///
/// The deadline is the caller's, not ssh's: `ConnectTimeout` ends at the handshake and cannot bound a
/// remote command that never returns.
///
/// Blocking rather than async, unlike the macOS sibling: GLib drains no Swift Concurrency executor, so the
/// control server gives this a worker thread of its own instead (see `agterm-linux/docs/main-loop.md`).
enum LinuxRemoteCommandRunner {
    /// Grace between SIGTERM and SIGKILL, and for the output to close after exit, matching the zmx client's.
    private static let terminationGrace: TimeInterval = 0.25

    /// Never call this on the GTK thread; it holds it for the whole deadline.
    static func run(_ argv: [String], deadline: TimeInterval) -> RemoteCommandResult {
        guard let executable = argv.first else {
            return RemoteCommandResult(status: -1, stdout: "", stderr: "no command to run")
        }
        // env resolves `ssh` through PATH, so a user who put their own ahead of /usr/bin keeps it
        do {
            let output = try LinuxProcessCapture.run("/usr/bin/env", arguments: ["env"] + argv,
                                                     environment: ProcessInfo.processInfo.environment,
                                                     timeout: deadline, grace: terminationGrace)
            return RemoteCommandResult(status: output.status, stdout: output.stdout, stderr: output.stderr)
        } catch .launch(let detail) {
            return RemoteCommandResult(status: -1, stdout: "", stderr: "could not run \(executable): \(detail)")
        } catch .timedOut {
            return RemoteCommandResult(status: -1, stdout: "", stderr: "the remote did not answer in time")
        } catch {
            // stdout stays empty: the caller prefers a remote error parsed from it, and a partial one must not
            // replace this diagnostic
            return RemoteCommandResult(status: -1, stdout: "", stderr: "the remote command output did not close in time")
        }
    }
}
