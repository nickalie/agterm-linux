import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux custom-command process launching")
struct LinuxCustomCommandProcessTests {
    @Test("requests preserve expansion, environment, cwd, pane, and null stdio")
    func requestPolicy() {
        let command = CustomCommand(
            name: "inspect", command: "printf '%s' \"$AGT_PANE\"; echo {AGT_PANE}:{AGT_SELECTION}",
            shortcut: "")
        for pane in [CommandContext.Pane.left, .right, .scratch] {
            let context = CommandContext(
                sessionID: "session", sessionName: "name", sessionPWD: "/tmp/work",
                workspaceID: "workspace", workspaceName: "work", windowID: "window",
                windowName: "main", pane: pane, selection: "selected", socket: "/tmp/agterm.sock")
            let request = LinuxCustomCommandProcess.request(
                command: command, context: context,
                baseEnvironment: ["KEEP": "yes", "AGT_PANE": "stale"])

            #expect(request.executablePath == "/bin/sh")
            #expect(request.arguments == [
                "-c", "printf '%s' \"$AGT_PANE\"; echo \(pane.rawValue):selected"
            ])
            #expect(request.environment["KEEP"] == "yes")
            #expect(request.environment["AGT_PANE"] == pane.rawValue)
            #expect(request.environment["AGT_SELECTION"] == "selected")
            #expect(request.currentDirectoryPath == "/tmp/work")
            #expect(request.standardIO == .null)
        }
    }

    @Test("empty cwd is omitted")
    func emptyCwd() {
        let command = CustomCommand(name: "noop", command: "true", shortcut: "")
        let request = LinuxCustomCommandProcess.request(
            command: command, context: CommandContext(), baseEnvironment: [:])
        #expect(request.currentDirectoryPath == nil)
    }

    @Test("spawn errors and non-zero exits report while successful exits stay silent")
    func failureRouting() {
        let command = CustomCommand(name: "failure", command: "exit 19", shortcut: "")
        let context = CommandContext(sessionPWD: "/tmp", pane: .right)
        let failures = LockedValue<[LinuxCustomCommandFailure]>([])

        let throwing = RecordingProcessLauncher()
        throwing.error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        LinuxCustomCommandProcess.launch(
            command: command, context: context, baseEnvironment: [:], launcher: throwing
        ) { failure, _ in failures.withValue { $0.append(failure) } }
        #expect(failures.value.count == 1)
        if case .launch(let detail) = failures.value[0] {
            #expect(!detail.isEmpty)
        } else {
            Issue.record("spawn error was not classified as a launch failure")
        }

        let running = RecordingProcessLauncher()
        LinuxCustomCommandProcess.launch(
            command: command, context: context, baseEnvironment: [:], launcher: running
        ) { failure, _ in failures.withValue { $0.append(failure) } }
        running.finish(status: 0)
        #expect(failures.value.count == 1)

        LinuxCustomCommandProcess.launch(
            command: command, context: context, baseEnvironment: [:], launcher: running
        ) { failure, _ in failures.withValue { $0.append(failure) } }
        running.finish(status: 19)
        #expect(failures.value.last == .exit(19))
    }

    @Test("only an error-hud command captures stderr, and its last usable line becomes the detail")
    func stderrCaptureIsOptIn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-capture-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let reports = LockedValue<[(LinuxCustomCommandFailure, String?)]>([])
        let launcher = RecordingProcessLauncher()

        let plain = CustomCommand(name: "plain", command: "exit 3", shortcut: "")
        LinuxCustomCommandProcess.launch(command: plain, context: CommandContext(), baseEnvironment: [:],
                                         captureDirectory: directory, launcher: launcher) { failure, detail in
            reports.withValue { $0.append((failure, detail)) }
        }
        #expect(launcher.requests.last?.standardIO == .null)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory).isEmpty)
        launcher.finish(status: 3)
        #expect(reports.value.last?.0 == .exit(3))
        #expect(reports.value.last?.1 == nil)

        let opted = CustomCommand(name: "opted", command: "exit 4", shortcut: "", errorHud: true)
        LinuxCustomCommandProcess.launch(command: opted, context: CommandContext(), baseEnvironment: [:],
                                         captureDirectory: directory, launcher: launcher) { failure, detail in
            reports.withValue { $0.append((failure, detail)) }
        }
        guard case .stderrFile(let path) = launcher.requests.last?.standardIO else {
            Issue.record("an error-hud command did not capture stderr")
            return
        }
        try Data("first\n\u{1B}[31mlast line\u{1B}[0m\n\u{1B}[0m\n".utf8).write(to: URL(fileURLWithPath: path))
        launcher.finish(status: 4)
        #expect(reports.value.last?.0 == .exit(4))
        #expect(reports.value.last?.1 == "last line")
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("a successful error-hud command reports nothing and still removes its capture")
    func successfulCaptureIsRemoved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-capture-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let reports = LockedValue<Int>(0)
        let launcher = RecordingProcessLauncher()
        let command = CustomCommand(name: "ok", command: "true", shortcut: "", errorHud: true)
        LinuxCustomCommandProcess.launch(command: command, context: CommandContext(), baseEnvironment: [:],
                                         captureDirectory: directory, launcher: launcher) { _, _ in
            reports.withValue { $0 += 1 }
        }
        launcher.finish(status: 0)
        #expect(reports.value == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory).isEmpty)
    }

    @Test("a launch error reports its reason with no detail")
    func launchErrorHasNoDetail() {
        let launcher = RecordingProcessLauncher()
        launcher.error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        let reports = LockedValue<[(LinuxCustomCommandFailure, String?)]>([])
        let command = CustomCommand(name: "gone", command: "true", shortcut: "", errorHud: true)
        LinuxCustomCommandProcess.launch(command: command, context: CommandContext(), baseEnvironment: [:],
                                         launcher: launcher) { failure, detail in
            reports.withValue { $0.append((failure, detail)) }
        }
        guard case .launch(let reason)? = reports.value.first?.0 else {
            Issue.record("the spawn error was not reported as a launch failure")
            return
        }
        #expect(reports.value.first?.0.reason == reason)
        #expect(reports.value.first?.1 == nil)
    }

    @Test("the real launcher captures stderr into the opted-in panel's detail")
    func realStderrCapture() async {
        let command = CustomCommand(name: "loud", command: "echo boom >&2; exit 7", shortcut: "", errorHud: true)
        await confirmation { confirmed in
            let launcher = FoundationLinuxProcessLauncher()
            LinuxCustomCommandProcess.launch(command: command, context: CommandContext(sessionPWD: "/tmp"),
                                             baseEnvironment: [:], launcher: launcher) { failure, detail in
                #expect(failure == .exit(7))
                #expect(detail == "boom")
                confirmed()
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    @Test("the failure panel is opt-in and carries the name, reason, placement and ten-second lifetime")
    @MainActor
    func failureHudSpec() {
        let plain = CustomCommand(name: "Build", command: "make", shortcut: "")
        #expect(AppController.failureHudSpec(plain, failure: .exit(2), detail: "oops") == nil)

        let opted = CustomCommand(name: "Build", command: "make", shortcut: "", errorHud: true,
                                  errorPosition: .topRight, errorPane: .right)
        let spec = AppController.failureHudSpec(opted, failure: .exit(2), detail: "oops")
        #expect(spec?.message == "Build: exit 2")
        #expect(spec?.detail == "oops")
        #expect(spec?.position == .topRight)
        #expect(spec?.hideAfter == 10)
        #expect(AppController.failureHudSpec(opted, failure: .launch("No such file"), detail: nil)?.message
            == "Build: No such file")
    }

    @Test("AGT_PANE_ID expands and exports beside AGT_PANE")
    func paneIDReachesTheCommand() {
        let command = CustomCommand(name: "id", command: "echo {AGT_PANE_ID}", shortcut: "")
        let request = LinuxCustomCommandProcess.request(
            command: command, context: CommandContext(pane: .right, paneID: "token-1"), baseEnvironment: [:])
        #expect(request.arguments == ["-c", "echo token-1"])
        #expect(request.environment["AGT_PANE_ID"] == "token-1")

        let sessionless = LinuxCustomCommandProcess.request(
            command: command, context: CommandContext(), baseEnvironment: [:])
        #expect(sessionless.environment["AGT_PANE_ID"] == "")
        #expect(!CommandContext.referencesSessionScopedContext(command.command))
    }

    @Test("an overlay names the pane underneath it")
    func overlayPane() {
        #expect(LinuxCommandPane.underOverlay(scratchActive: false, overlayPane: nil, focusedPane: .left) == .left)
        #expect(LinuxCommandPane.underOverlay(scratchActive: false, overlayPane: nil, focusedPane: .right) == .right)
        #expect(LinuxCommandPane.underOverlay(scratchActive: false, overlayPane: .right, focusedPane: .left)
            == .right)
        #expect(LinuxCommandPane.underOverlay(scratchActive: false, overlayPane: .left, focusedPane: .right)
            == .left)
        #expect(LinuxCommandPane.underOverlay(scratchActive: true, overlayPane: .right, focusedPane: .right)
            == .scratch)
    }

    @Test("Foundation launcher rejects a missing executable")
    func missingExecutable() {
        let launcher = FoundationLinuxProcessLauncher()
        let request = LinuxProcessLaunchRequest(
            executablePath: "/definitely/missing/agterm-command",
            arguments: [], environment: [:], currentDirectoryPath: nil, standardIO: .null)
        do {
            try launcher.launch(request) { _ in }
            Issue.record("missing executable unexpectedly launched")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test("Foundation launcher rejects an invalid working directory")
    func invalidWorkingDirectory() {
        let launcher = FoundationLinuxProcessLauncher()
        let request = LinuxProcessLaunchRequest(
            executablePath: "/bin/sh", arguments: ["-c", "true"], environment: [:],
            currentDirectoryPath: "/definitely/missing/agterm-cwd", standardIO: .null)
        do {
            try launcher.launch(request) { _ in }
            Issue.record("invalid working directory unexpectedly launched")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test("Foundation launcher reports successful and non-zero termination")
    func realTermination() async {
        let launcher = FoundationLinuxProcessLauncher()
        for (line, expected) in [("true", Int32(0)), ("exit 23", Int32(23))] {
            await confirmation { confirmed in
                let request = LinuxProcessLaunchRequest(
                    executablePath: "/bin/sh", arguments: ["-c", line], environment: [:],
                    currentDirectoryPath: "/tmp", standardIO: .null)
                do {
                    try launcher.launch(request) { status in
                        #expect(status == expected)
                        confirmed()
                    }
                } catch {
                    Issue.record("shell launch failed: \(error.localizedDescription)")
                    confirmed()
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    @Test("closing and reopening the same window id cannot reactivate an old origin")
    @MainActor
    func controllerIncarnation() async {
        let oldOrigin = LinuxCustomCommandOrigin()
        let launcher = RecordingProcessLauncher()
        let deliveries = LockedValue<[LinuxCustomCommandFailure]>([])
        let command = CustomCommand(name: "slow", command: "exit 29", shortcut: "")
        LinuxCustomCommandProcess.launch(
            command: command, context: CommandContext(), baseEnvironment: [:], launcher: launcher
        ) { [weak oldOrigin] failure, _ in
            Task { @MainActor in
                oldOrigin?.deliverIfActive { deliveries.withValue { $0.append(failure) } }
            }
        }
        oldOrigin.invalidate()
        let reopenedOrigin = LinuxCustomCommandOrigin()
        launcher.finish(status: 29)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(deliveries.value.isEmpty)
        #expect(!oldOrigin.isActive)
        #expect(reopenedOrigin.isActive)
        #expect(oldOrigin !== reopenedOrigin)
    }
}

private final class RecordingProcessLauncher: LinuxProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    var error: (any Error)?
    private var completions: [@Sendable (Int32) -> Void] = []
    private var recorded: [LinuxProcessLaunchRequest] = []

    var requests: [LinuxProcessLaunchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func launch(
        _ request: LinuxProcessLaunchRequest,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        if let error { throw error }
        completions.append(onTermination)
    }

    func finish(status: Int32) {
        lock.lock()
        let completion = completions.removeFirst()
        lock.unlock()
        completion(status)
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}
