import Foundation
import Testing
@testable import AgtermLinux
import agtermCore

@Suite("Linux zmx host")
struct LinuxZmxTests {
    @Test("the launcher's variable wins over the payload layout")
    func executableTakesTheExportedPath() {
        #expect(LinuxZmxLaunch.executablePath(environment: ["AGTERM_ZMX": "/opt/agterm/libexec/zmx"])
            == "/opt/agterm/libexec/zmx")
    }

    @Test("without it the path is derived from this executable's payload")
    func executableFallsBackToLibexec() {
        let derived = LinuxZmxLaunch.executablePath(environment: [:])
        #expect(derived.hasSuffix("/libexec/zmx"))
        #expect((derived as NSString).isAbsolutePath)
    }

    @Test("live is refused when the account's login shell is not zsh")
    func liveNeedsZsh() {
        let reason = LinuxZmxLaunch.liveUnavailableReason(
            environment: ["AGTERM_ZMX": "/bin/sh"], passwordDatabaseShell: "/bin/bash")
        #expect(reason == ZmxSupport.Rejection.unsupportedLoginShell.message)
    }

    @Test("live is refused when the bundled binary is missing")
    func liveNeedsTheBinary() {
        let reason = LinuxZmxLaunch.liveUnavailableReason(
            environment: ["AGTERM_ZMX": "/nonexistent/zmx"], passwordDatabaseShell: "/usr/bin/zsh")
        #expect(reason == ZmxSupport.Rejection.executableUnavailable.message)
    }

    @Test("the leader probe reads tpgid past a name carrying spaces and parentheses")
    func probeParsesStat() {
        #expect(LinuxZmxForegroundResolver.parse(stat: "4242 (my (odd) name) S 1 4242 4242 34816 9182 419")
            == .foreground(9182))
        #expect(LinuxZmxForegroundResolver.parse(stat: "7 (zsh) S 1 7 7 34816 -1 419") == .noForeground)
        #expect(LinuxZmxForegroundResolver.parse(stat: "7 (zsh) S 1 7") == .dead)
        #expect(LinuxZmxForegroundResolver.parse(stat: "garbage") == .dead)
    }

    @Test("a pid with no stat file reads as dead and this process reads as alive")
    func probeReadsProc() {
        #expect(LinuxZmxForegroundResolver.probe(-1) == .dead)
        #expect(LinuxZmxForegroundResolver.probe(Int32(ProcessInfo.processInfo.processIdentifier)) != .dead)
    }

    @MainActor
    @Test("a kill is confirmed only by the exact line zmx prints")
    func killOutcomeIsExact() {
        #expect(LinuxZmxClient.outcome(of: "killed session agterm-a\n", name: "agterm-a") == .killed)
        #expect(LinuxZmxClient.outcome(of: "cleaned up stale session agterm-a\n", name: "agterm-a")
            == .staleSocket)
        // a line merely CONTAINING the confirmation must not count as one
        #expect(LinuxZmxClient.outcome(of: "not killed session agterm-a\n", name: "agterm-a")
            == .failed("not killed session agterm-a"))
        #expect(LinuxZmxClient.outcome(of: "", name: "agterm-a") == .failed("no output"))
    }
}
