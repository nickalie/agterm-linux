import Foundation
import agtermCore

enum LinuxProcessStandardIO: Sendable, Equatable {
    case null
    /// stdin and stdout to `/dev/null`, stderr appended to the file at this path.
    case stderrFile(String)
}

struct LinuxProcessLaunchRequest: Sendable, Equatable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryPath: String?
    let standardIO: LinuxProcessStandardIO
}

protocol LinuxProcessLaunching: Sendable {
    func launch(
        _ request: LinuxProcessLaunchRequest,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws
}

struct FoundationLinuxProcessLauncher: LinuxProcessLaunching {
    func launch(
        _ request: LinuxProcessLaunchRequest,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        process.environment = request.environment
        if let path = request.currentDirectoryPath {
            process.currentDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        var stderrHandle: FileHandle?
        if case .stderrFile(let path) = request.standardIO { stderrHandle = FileHandle(forWritingAtPath: path) }
        process.standardError = stderrHandle ?? FileHandle.nullDevice
        // our copy of the capture fd stays open until the child is gone, as upstream's `StderrFile` keeps it
        let handle = stderrHandle
        process.terminationHandler = {
            try? handle?.close()
            onTermination($0.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            try? handle?.close()
            throw error
        }
    }
}

/// A command's stderr captured to a temp file so a failure panel can say what it printed: upstream's
/// `StderrFile`. A file rather than a pipe, so a background descendant never takes SIGPIPE once agterm quits.
struct LinuxStderrCapture: Sendable {
    let path: String

    /// Nil when the file cannot be created; the command's stderr then goes to `/dev/null`.
    init?(directory: String = NSTemporaryDirectory()) {
        path = (directory as NSString).appendingPathComponent("agterm-command-\(UUID().uuidString).err")
        guard FileManager.default.createFile(atPath: path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else { return nil }
    }

    /// The last `CommandFailure.tailLimit` bytes written, then the file is removed. The size is sampled once,
    /// so a descendant still appending cannot hand back everything it wrote.
    func consume() -> [UInt8] {
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let reader = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? reader.close() }
        let size = (try? reader.seekToEnd()) ?? 0
        let wanted = min(size, UInt64(CommandFailure.tailLimit))
        try? reader.seek(toOffset: size - wanted)
        return [UInt8]((try? reader.read(upToCount: Int(wanted))) ?? Data())
    }
}

enum LinuxCustomCommandFailure: Sendable, Equatable {
    case launch(String)
    case exit(Int32)

    /// The failure panel's reason: the exit status, or the launch error of a command that never started.
    var reason: String {
        switch self {
        case .launch(let detail): detail
        case .exit(let status): "exit \(status)"
        }
    }

    func toast(commandName: String) -> String {
        switch self {
        case .launch(let detail): "command failed to launch: \(commandName) — \(detail)"
        case .exit(let status): "command failed (exit \(status)): \(commandName)"
        }
    }
}

enum LinuxCustomCommandProcess {
    /// `cwd` is where the process STARTS, which a remote session separates from the reported
    /// `AGT_SESSION_PWD` the context still carries: the far side's path need not exist here.
    static func request(
        command: CustomCommand, context: CommandContext, baseEnvironment: [String: String],
        cwd: String? = nil, stderrPath: String? = nil
    ) -> LinuxProcessLaunchRequest {
        let directory = cwd ?? context.sessionPWD
        return LinuxProcessLaunchRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", context.expand(command.command)],
            environment: baseEnvironment.merging(context.environment()) { _, commandValue in commandValue },
            currentDirectoryPath: directory.isEmpty ? nil : directory,
            standardIO: stderrPath.map(LinuxProcessStandardIO.stderrFile) ?? .null)
    }

    /// Only an `errorHud` command captures stderr; `onFailure` receives its last usable line as the detail.
    static func launch(
        command: CustomCommand,
        context: CommandContext,
        baseEnvironment: [String: String] = LinuxCommandPath.environment(),
        cwd: String? = nil,
        captureDirectory: String = NSTemporaryDirectory(),
        launcher: any LinuxProcessLaunching,
        onFailure: @escaping @Sendable (LinuxCustomCommandFailure, String?) -> Void
    ) {
        let capture = command.errorHud ? LinuxStderrCapture(directory: captureDirectory) : nil
        let request = request(command: command, context: context, baseEnvironment: baseEnvironment, cwd: cwd,
                              stderrPath: capture?.path)
        do {
            try launcher.launch(request) { status in
                // consumed whatever the status, or every successful run would leave its file behind
                let detail = capture.flatMap { CommandFailure.detail(fromTail: $0.consume()) }
                if status != 0 { onFailure(.exit(status), detail) }
            }
        } catch {
            _ = capture?.consume()
            onFailure(.launch(error.localizedDescription), nil)
        }
    }
}

/// A per-controller generation token. Closing a window invalidates this instance; reopening the same
/// persisted window id creates a different token, so an old process completion cannot reach the new UI.
@MainActor
final class LinuxCustomCommandOrigin {
    let launcher: any LinuxProcessLaunching
    private(set) var isActive = true

    init(launcher: any LinuxProcessLaunching = FoundationLinuxProcessLauncher()) {
        self.launcher = launcher
    }

    func invalidate() { isActive = false }

    func deliverIfActive(_ action: () -> Void) {
        guard isActive else { return }
        action()
    }
}
