import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

struct LinuxProcessCaptureTests {
    private func sh(_ script: String, timeout: TimeInterval = 5, grace: TimeInterval = 0.25)
        throws(LinuxProcessCapture.Failure) -> LinuxProcessCapture.Output {
        try LinuxProcessCapture.run("/bin/sh", arguments: ["sh", "-c", script],
                                    environment: ProcessInfo.processInfo.environment, timeout: timeout, grace: grace)
    }

    @Test func outputLargerThanAPipeBufferOnBothStreamsDoesNotBlockTheExit() throws {
        let started = Date()
        let output = try sh("head -c 204800 /dev/zero | tr '\\0' o; head -c 204800 /dev/zero | tr '\\0' e >&2; exit 3")

        #expect(output.status == 3)
        #expect(output.stdout.utf8.count == 204_800)
        #expect(output.stderr.utf8.count == 204_800)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func aChildOutlivingTheDeadlineIsKilled() {
        let started = Date()
        #expect(throws: LinuxProcessCapture.Failure.timedOut) { try sh("exec sleep 30", timeout: 0.2) }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func aLeakedWriteEndMissesTheGraceInsteadOfWaitingForItsHolder() {
        let started = Date()
        #expect(throws: LinuxProcessCapture.Failure.outputStalled) { try sh("sleep 30 & echo partial") }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func aMissingExecutableIsALaunchFailure() {
        #expect(throws: LinuxProcessCapture.Failure.launch("/nonexistent/zmx: No such file or directory")) {
            try LinuxProcessCapture.run("/nonexistent/zmx", arguments: ["zmx"], environment: [:], timeout: 1, grace: 0.1)
        }
    }

    @Test func theRemoteRunnerReturnsALargeReplyWhole() {
        let result = LinuxRemoteCommandRunner.run(["sh", "-c", "head -c 204800 /dev/zero | tr '\\0' r"], deadline: 5)

        #expect(result.status == 0)
        #expect(result.stdout.utf8.count == 204_800)
    }
}

@Suite("Linux process table")
struct LinuxProcessTableTests {
    @Test("a stat line yields pid, process group, terminal foreground group and start time")
    func parsesStat() {
        let line = "4242 (sh (x) y) S 1 4242 4242 34816 5000 4194304 0 0 0 0 0 0 0 0 20 0 1 0 987654 0 0"
        #expect(LinuxProcessTable.record(stat: line)
            == ProcessRecord(pid: 4242, started: 987654, group: 4242, foreground: 5000))
    }

    @Test("a truncated stat line is no record")
    func rejectsTruncated() {
        #expect(LinuxProcessTable.record(stat: "12 (sh) S 1 12") == nil)
    }

    @Test("this process is in the live table")
    func readsLiveTable() throws {
        let table = try #require(LinuxProcessTable.read())
        #expect(table.contains { $0.pid == getpid() })
    }
}
