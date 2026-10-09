import Foundation
import agtermCore

@MainActor
extension GhosttySurface {
    /// `paneForeground`, with the pid whose argv it read.
    func observedForeground(zmxSnapshot: LinuxZmxForegroundResolver.Snapshot? = nil)
        -> (pid: Int32, foreground: CommandRestore.PaneForeground)? {
        guard let pid = foregroundPID(zmxSnapshot: zmxSnapshot),
              let data = try? Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/cmdline")),
              let argv = CommandRestore.parseProcCmdline(data) else { return nil }
        let loginShell = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
        return CommandRestore.paneForeground(argv: argv, extra: loginShell).map { (pid, $0) }
    }
}
