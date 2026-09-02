import Foundation
import Glibc
import agtermCore

/// Runs the bundled `zmx` and turns its output into the host-free records `ZmxLifecycle` and
/// `ZmxInventory` reason about. Every invocation is bounded: a hung daemon must not hold the GTK main
/// loop, which is the thread every caller here runs on.
@MainActor
final class LinuxZmxClient {
    /// A cold listing of 55 daemons measured in tens of milliseconds upstream; the timeout plus the kill
    /// grace stays inside the quit budget.
    nonisolated static let captureInvocationTimeout: TimeInterval = 0.1
    nonisolated static let terminationGrace: TimeInterval = 0.25

    struct Invocation {
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
        let timeout: TimeInterval
    }

    enum CommandError: Error {
        case timedOut
        case failed(Int32, String)
    }

    /// What a single unforced kill actually did. `staleSocket` is its own case because zmx prints
    /// `cleaned up stale session` and exits ZERO after merely unlinking a socket it could not connect to —
    /// the daemon may still be running, so counting that as a kill would report a process gone that is not.
    enum KillOutcome: Equatable {
        case killed
        case staleSocket
        case failed(String)
    }

    /// What the launch reap learned. `runningNames` is every daemon whose client count the listing could
    /// read; nil when the list was skipped, failed or did not parse.
    struct ReapOutcome: Equatable {
        let runningNames: Set<String>?
        let killedAll: Bool
    }

    typealias Runner = (Invocation) throws -> String

    private let executablePath: String
    private let socketDirectory: String
    private let timeout: TimeInterval
    private let runner: Runner

    init(executablePath: String, socketDirectory: String, timeout: TimeInterval = 3,
         runner: @escaping Runner = LinuxZmxClient.run) {
        self.executablePath = executablePath
        self.socketDirectory = socketDirectory
        self.timeout = timeout
        self.runner = runner
    }

    /// Whether the bundled binary is there at all. A source build without it has no daemons to reason
    /// about, and every command answers `zmx is unavailable in this instance` rather than an error per call.
    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executablePath) }

    /// What a caller on another machine needs to reach these daemons.
    var endpoint: ControlZmxEndpoint {
        ControlZmxEndpoint(executable: executablePath, socketDirectory: socketDirectory)
    }

    @discardableResult
    func reap(knownPaneIdentities: Set<UUID>?, launchDecision: RestoreLaunchDecision) -> ReapOutcome {
        // nothing to reap without the binary, and nothing to say about it every launch
        guard isAvailable else { return ReapOutcome(runningNames: nil, killedAll: true) }
        if launchDecision.requested == .live, knownPaneIdentities == nil {
            log("skipping the live reap: the persisted pane inventory is incomplete")
            return ReapOutcome(runningNames: nil, killedAll: true)
        }
        guard let sessions = listSessions() else { return ReapOutcome(runningNames: nil, killedAll: false) }
        let running = Set(sessions.filter { $0.clients != nil }.map(\.name))
        let knownNames = knownPaneIdentities.map { Set($0.map(ZmxSupport.daemonName(for:))) }
        guard let names = ZmxReapPolicy.namesToKill(sessions: sessions,
                                                    requestedMode: launchDecision.requested,
                                                    knownNames: knownNames) else {
            return ReapOutcome(runningNames: running, killedAll: true)
        }
        return ReapOutcome(runningNames: running, killedAll: kill(names: names))
    }

    @discardableResult
    func kill(paneIdentities: [UUID]) -> Bool {
        guard isAvailable else { return true }
        return kill(names: paneIdentities.map(ZmxSupport.daemonName(for:)))
    }

    /// The parsed listing. Nil when it could not be read or parsed, which is NOT the same answer as an
    /// empty namespace: a failure must not read as "nothing to see" and let a caller act on that silence.
    func listSessions() -> [ZmxSessionRecord]? {
        guard isAvailable else { return nil }
        do {
            return try ZmxListParser.parse(invoke(["list"]))
        } catch {
            log("list failed: \(error)")
            return nil
        }
    }

    func sessionLeaderPIDs(timeout override: TimeInterval? = nil) -> [String: Int32]? {
        guard isAvailable else { return nil }
        do {
            return ZmxLeaderMap.leaders(in: try ZmxListParser.parse(invoke(["list"], timeout: override)))
        } catch {
            log("leader refresh failed: \(error)")
            return nil
        }
    }

    /// Kills daemons the caller's listing observed unclaimed and detached, one invocation each so the
    /// result can be reported per name. Never passes `--force`: what it would add is the stale-socket
    /// unlink, the one outcome indistinguishable from success. The caller must re-list immediately before.
    func killObservedOrphan(names: [String]) -> [String: KillOutcome] {
        var outcomes: [String: KillOutcome] = [:]
        for name in Set(names) {
            do {
                outcomes[name] = Self.outcome(of: try invoke(["kill", name]), name: name)
            } catch {
                log("kill failed for \(name): \(error)")
                outcomes[name] = .failed(String(describing: error))
            }
        }
        return outcomes
    }

    /// Force-kill ONE daemon and report what zmx actually did. The caller closes or promotes a LIVE pane
    /// on this answer, so an exit status is not enough.
    func killConfirmed(name: String) -> KillOutcome {
        do {
            return Self.outcome(of: try invoke(["kill", name, "--force"]), name: name)
        } catch {
            log("kill failed for \(name): \(error)")
            return .failed(String(describing: error))
        }
    }

    /// Classifies a kill by EXACT output line: zmx exits zero on more than the two happy answers, and a
    /// substring test would let a line merely CONTAINING the confirmation count as one.
    static func outcome(of output: String, name: String) -> KillOutcome {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains("killed session \(name)") { return .killed }
        if lines.contains("cleaned up stale session \(name)") { return .staleSocket }
        return .failed(lines.first ?? "no output")
    }

    private func kill(names: [String]) -> Bool {
        var seen: Set<String> = []
        let unique = names.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return true }
        do {
            _ = try invoke(["kill"] + unique + ["--force"])
            return true
        } catch {
            log("kill failed for \(unique.joined(separator: ",")): \(error)")
            return false
        }
    }

    private func invoke(_ arguments: [String], timeout override: TimeInterval? = nil) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["ZMX_DIR"] = socketDirectory
        environment.removeValue(forKey: "ZMX_SESSION")
        environment.removeValue(forKey: "ZMX_SESSION_PREFIX")
        return try runner(Invocation(executablePath: executablePath, arguments: arguments,
                                     environment: environment, timeout: override ?? timeout))
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("agterm: zmx \(message)\n".utf8))
    }

    /// A blocking run with a hard deadline. `DispatchSemaphore` and the termination handler are safe here:
    /// libdispatch owns its own threads, and only the GLib MAIN loop is the thing `MainTimer` exists for.
    private nonisolated static func run(_ invocation: Invocation) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + invocation.timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + terminationGrace) == .timedOut {
                Glibc.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw CommandError.timedOut
        }
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CommandError.failed(process.terminationStatus, stdout + stderr)
        }
        return stdout
    }
}
