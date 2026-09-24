import CGtk
import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

/// The runner's callbacks hop through `runOnMain`, so every test pumps the GLib default context itself.
@MainActor
@Suite(.serialized)
final class LinuxHookProcessRunnerTests {
    private let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-linux-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private final class Outcome: @unchecked Sendable {
        var deliveryFailures: [String] = []
        var exits: [Int32] = []
    }

    private func runner(encode: @escaping @Sendable (ControlEvent) throws -> Data = { try JSONEncoder().encode($0) },
                        shell: String = "/bin/sh") -> LinuxHookProcessRunner {
        LinuxHookProcessRunner(socketProvider: { "/tmp/test.sock" }, executablePath: shell, encode: encode,
                               baseEnvironment: { LinuxCommandPath.environment() })
    }

    @discardableResult
    private func run(_ command: String, event: ControlEvent = ControlEvent(seq: 1, ts: 1, kind: .status),
                     timeout: TimeInterval = 10) throws -> Outcome {
        let outcome = Outcome()
        let entry = HookEntry(identity: HookIdentity(kind: event.kind, command: command), line: 1)
        _ = try runner().launch(
            entry: entry, event: event,
            onDeliveryFailure: { outcome.deliveryFailures.append($0) },
            onExit: { outcome.exits.append($0) })
        #expect(outcome.exits.isEmpty, "onExit must never run inline from launch")
        pumpMainLoop(until: { !outcome.exits.isEmpty }, timeout: timeout)
        pumpMainLoop(for: 0.05)
        #expect(outcome.exits.count == 1)
        return outcome
    }

    private func largeEvent() -> ControlEvent {
        ControlEvent(seq: 7, ts: 7, kind: .notify, window: "w", workspace: "ws", session: "s",
                     payload: ControlEventPayload(name: "n", title: "t", body: String(repeating: "x", count: 300_000)))
    }

    private func openDescriptors() -> Set<Int32> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []).compactMap(Int32.init))
    }

    @Test func stdinCarriesTheEventAndTheEnvironmentIsFullySet() throws {
        let stdin = scratch.appendingPathComponent("stdin").path
        let env = scratch.appendingPathComponent("env").path
        let event = ControlEvent(seq: 3, ts: 3.5, kind: .status, window: "win-1", workspace: "ws-1", session: "sess-1",
                                 payload: ControlEventPayload(name: "api", status: "blocked", previous: "active"))
        let script = """
        cat > '\(stdin)'; printf '%s\\n' "$AGT_EVENT_KIND" "$AGT_EVENT_STATUS" "$AGT_SESSION_ID" "$AGT_WORKSPACE_ID" \
        "$AGT_WINDOW_ID" "$AGT_SOCKET" "$PWD" "$PATH" > '\(env)'
        """

        let outcome = try run(script, event: event)

        #expect(outcome.exits == [0])
        #expect(outcome.deliveryFailures.isEmpty)
        let raw = try String(contentsOfFile: stdin, encoding: .utf8)
        #expect(raw.hasSuffix("\n"))
        #expect(raw.filter { $0 == "\n" }.count == 1)
        #expect(try JSONDecoder().decode(ControlEvent.self, from: Data(raw.utf8)) == event)
        let lines = try String(contentsOfFile: env, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(Array(lines[0..<6]) == ["status", "blocked", "sess-1", "ws-1", "win-1", "/tmp/test.sock"])
        #expect(lines[6] == Substring(FileManager.default.currentDirectoryPath))
        #expect(lines[7].split(separator: ":").contains("/usr/local/bin"), "PATH is widened like a custom command's")
    }

    @Test func missingFieldsAreExportedEmptyNotInherited() throws {
        let env = scratch.appendingPathComponent("env").path
        setenv("AGT_SESSION_ID", "inherited-and-wrong", 1)
        setenv("AGT_EVENT_HOST", "inherited-and-wrong", 1)
        defer {
            unsetenv("AGT_SESSION_ID")
            unsetenv("AGT_EVENT_HOST")
        }
        let script = "printf '[%s][%s][%s][%s]' \"$AGT_EVENT_STATUS\" \"$AGT_SESSION_ID\" \"$AGT_WINDOW_ID\" \"$AGT_EVENT_HOST\" > '\(env)'"

        let outcome = try run(script, event: ControlEvent(seq: 1, ts: 1, kind: .treeChanged))

        #expect(outcome.exits == [0])
        #expect(try String(contentsOfFile: env, encoding: .utf8) == "[][][][]")
    }

    @Test func aRemoteEdgeExportsTheHost() throws {
        let env = scratch.appendingPathComponent("env").path
        let event = ControlEvent(seq: 4, ts: 4.5, kind: .remoteOpened, window: "win-1", workspace: "ws-1",
                                 session: "sess-1", payload: ControlEventPayload(name: "far", host: "buildbox"))

        let outcome = try run("cat >/dev/null; printf '%s' \"$AGT_EVENT_HOST\" > '\(env)'", event: event)

        #expect(outcome.exits == [0])
        #expect(try String(contentsOfFile: env, encoding: .utf8) == "buildbox")
    }

    @Test func anEarlyStdinCloseWithALargePayloadIsNotADeliveryFailure() throws {
        let clean = try run("exec <&-; exit 0", event: largeEvent())
        #expect(clean.exits == [0])
        #expect(clean.deliveryFailures.isEmpty)

        let failed = try run("exec <&-; exit 1", event: largeEvent())
        #expect(failed.exits == [1])
        #expect(failed.deliveryFailures.isEmpty)
    }

    @Test func aMissingShellThrowsWithItsReasonAndRunsNoCallbackOrLeak() throws {
        let runner = runner(shell: scratch.appendingPathComponent("no-such-shell").path)
        let outcome = Outcome()
        let entry = HookEntry(identity: HookIdentity(kind: .status, command: "true"), line: 1)
        let before = openDescriptors()

        let error = #expect(throws: (any Error).self) {
            _ = try runner.launch(entry: entry, event: ControlEvent(seq: 1, ts: 1, kind: .status),
                                  onDeliveryFailure: { outcome.deliveryFailures.append($0) },
                                  onExit: { outcome.exits.append($0) })
        }
        #expect(error?.localizedDescription.contains("no-such-shell") == true)

        pumpMainLoop(for: 0.3)
        #expect(outcome.exits.isEmpty)
        #expect(outcome.deliveryFailures.isEmpty)
        #expect(openDescriptors() == before, "a failed spawn closes both pipe ends")
    }

    @Test func aDeliveryFailureArrivesWhileTheChildLivesAndBeforeExit() throws {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let outcome = Outcome()
        let entry = HookEntry(identity: HookIdentity(kind: .status, command: "sleep 1"), line: 1)
        _ = try runner(encode: { _ in throw Boom() }).launch(
            entry: entry, event: ControlEvent(seq: 1, ts: 1, kind: .status),
            onDeliveryFailure: { outcome.deliveryFailures.append($0) },
            onExit: { outcome.exits.append($0) })

        pumpMainLoop(until: { !outcome.deliveryFailures.isEmpty }, timeout: 0.5)
        #expect(outcome.deliveryFailures == ["encode: boom"])
        #expect(outcome.exits.isEmpty, "the failure arrives while the child still sleeps")
        pumpMainLoop(until: { !outcome.exits.isEmpty })
        #expect(outcome.exits == [0])
    }

    @Test func theWriteEndIsClosedBeforeExitIsReported() throws {
        final class Probe: @unchecked Sendable {
            var opened: Set<Int32> = []
            var stillOpenAtExit: Set<Int32>?
        }
        let before = openDescriptors()
        let probe = Probe()
        let entry = HookEntry(identity: HookIdentity(kind: .notify, command: "sleep 0.5; exit 0"), line: 1)

        _ = try runner().launch(entry: entry, event: largeEvent(), onDeliveryFailure: { _ in }, onExit: { _ in
            probe.stillOpenAtExit = probe.opened.filter { fcntl($0, F_GETFD) != -1 }
        })
        probe.opened = openDescriptors().subtracting(before)
        #expect(!probe.opened.isEmpty, "the blocked write keeps the pipe's write end open")
        pumpMainLoop(until: { probe.stillOpenAtExit != nil })

        #expect(probe.stillOpenAtExit == [])
    }

    @Test func aGrandchildHoldingStdinDoesNotDelayExit() throws {
        let started = Date()
        let script = "exec 3<&0; (sleep 3 <&3 3<&-) & exec 3<&-; exit 0"

        let outcome = try run(script, event: largeEvent(), timeout: 2)

        #expect(outcome.exits == [0])
        #expect(outcome.deliveryFailures.isEmpty)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func theSchedulerRunsOneChildPerHookInEventOrderAndBannersAFailureOnce() throws {
        let log = scratch.appendingPathComponent("log").path
        let scheduler = HookScheduler(launcher: runner())
        var failures: [String] = []
        scheduler.onFailure = { _, detail in failures.append(detail) }
        let ordered = "cat >/dev/null; echo \"$AGT_EVENT_STATUS\" >> '\(log)'; sleep 0.1"
        scheduler.apply(Hooks(entries: [
            HookEntry(identity: HookIdentity(kind: .status, command: ordered), line: 1),
            HookEntry(identity: HookIdentity(kind: .status, command: "exit 3"), line: 2),
        ]))

        for status in ["a", "b", "c"] {
            scheduler.dispatch(ControlEvent(seq: 1, ts: 1, kind: .status, payload: ControlEventPayload(status: status)))
        }

        #expect(scheduler.status.map(\.pending) == [2, 2])
        #expect(scheduler.status.allSatisfy { $0.runningPid != nil })
        pumpMainLoop(until: { scheduler.status.allSatisfy { $0.runningPid == nil } })
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "a\nb\nc\n")
        #expect(failures == ["exit 3"])
        #expect(scheduler.status.map(\.lastFailure) == [nil, "exit 3"])
    }
}

@MainActor
func pumpMainLoop(until done: () -> Bool, timeout: TimeInterval = 10) {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline {
        while g_main_context_iteration(nil, 0) != 0 {}
        usleep(2_000)
    }
}

@MainActor
func pumpMainLoop(for interval: TimeInterval) {
    pumpMainLoop(until: { false }, timeout: interval)
}
