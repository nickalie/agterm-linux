import Foundation
import agtermCore
#if canImport(Glibc)
import Glibc
#endif

/// The Linux `HookLauncher`, macOS `HookProcessRunner`'s contract on threads instead of `DispatchIO`:
/// the stdin write end is non-blocking and owned by one writer thread, which gives up once the child has
/// exited (a grandchild holding stdin cannot pin it), and `onExit` hops to the GTK loop only after the
/// child has terminated AND the write end is closed. Callbacks go through `runOnMain`, never a main-actor
/// `Task`, which the GLib loop would never run.
@MainActor
final class LinuxHookProcessRunner: HookLauncher {
    struct LaunchError: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    private let socketProvider: () -> String
    private let executablePath: String
    private let encode: @Sendable (ControlEvent) throws -> Data
    private let baseEnvironment: () -> [String: String]

    /// `executablePath` and `encode` are injection points for tests (a missing shell, a failing encoder).
    init(socketProvider: @escaping () -> String,
         executablePath: String = "/bin/sh",
         encode: @escaping @Sendable (ControlEvent) throws -> Data = { try JSONEncoder().encode($0) },
         baseEnvironment: @escaping () -> [String: String] = { LinuxCommandPath.environment() }) {
        self.socketProvider = socketProvider
        self.executablePath = executablePath
        self.encode = encode
        self.baseEnvironment = baseEnvironment
    }

    func launch(entry: HookEntry, event: ControlEvent,
                onDeliveryFailure: @escaping @MainActor @Sendable (String) -> Void,
                onExit: @escaping @MainActor @Sendable (Int32) -> Void) throws -> Int32 {
        // a script that exits without reading turns the write into EPIPE instead of a process-killing SIGPIPE
        signal(SIGPIPE, SIG_IGN)
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            throw LaunchError(detail: "pipe: \(String(cString: strerror(errno)))")
        }
        let readFD = fds[0]
        let writeFD = fds[1]
        // CLOEXEC keeps the write end out of the child (dup2 onto its stdin clears the flag there); a
        // blocking write end would pin the writer thread past the child's exit
        guard fcntl(readFD, F_SETFD, FD_CLOEXEC) == 0, fcntl(writeFD, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK) == 0 else {
            let message = String(cString: strerror(errno))
            close(readFD)
            close(writeFD)
            throw LaunchError(detail: "O_NONBLOCK: \(message)")
        }
        let pid: pid_t
        do {
            pid = try HookSpawn.spawn(executablePath, arguments: ["sh", "-c", entry.command],
                                      environment: environment(for: event), stdin: readFD)
        } catch {
            close(readFD)
            close(writeFD)
            throw error
        }
        // the child holds its own copy; ours would keep the pipe alive past the child's exit
        close(readFD)

        let state = HookLaunchState(onExit: onExit)
        Thread.detachNewThread { state.childExited(HookSpawn.wait(pid)) }
        let encode = encode
        Thread.detachNewThread {
            HookStdinWriter.deliver(event, encode: encode, to: writeFD, state: state) { message in
                runOnMain { MainActor.assumeIsolated { onDeliveryFailure(message) } }
            }
        }
        return pid
    }

    /// Every fixed variable is set explicitly, empty when the event lacks the field, so an inherited value
    /// can never point a script at the wrong session.
    private func environment(for event: ControlEvent) -> [String: String] {
        var environment = baseEnvironment()
        environment["AGT_EVENT_KIND"] = event.kind.rawValue
        environment["AGT_EVENT_STATUS"] = event.payload.status ?? ""
        environment["AGT_EVENT_HOST"] = event.payload.host ?? ""
        environment["AGT_SESSION_ID"] = event.session ?? ""
        environment["AGT_WORKSPACE_ID"] = event.workspace ?? ""
        environment["AGT_WINDOW_ID"] = event.window ?? ""
        environment["AGT_SOCKET"] = socketProvider()
        return environment
    }
}

/// `posix_spawn` and a blocking `waitpid` rather than Foundation's `Process`, whose Linux termination
/// notice waits for EOF on a socket every descendant inherits: a hook that backgrounds a job would hold its
/// slot until that job ended, not until the hook's own shell exited.
enum HookSpawn {
    static func spawn(_ path: String, arguments: [String], environment: [String: String], stdin: Int32) throws -> pid_t {
        var attributes = posix_spawnattr_t()
        var actions = posix_spawn_file_actions_t()
        try check(posix_spawnattr_init(&attributes), "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }
        // its own process group like a Foundation child, with default signal handling and an empty mask
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        try check(posix_spawnattr_setsigmask(&attributes, &noSignals), "posix_spawnattr_setsigmask")
        try check(posix_spawnattr_setsigdefault(&attributes, &allSignals), "posix_spawnattr_setsigdefault")
        try check(posix_spawnattr_setpgroup(&attributes, 0), "posix_spawnattr_setpgroup")
        let flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)), "posix_spawnattr_setflags")
        try check(posix_spawn_file_actions_init(&actions), "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_adddup2(&actions, stdin, STDIN_FILENO), "adddup2")
        try check(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0), "addopen")
        try check(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0), "addopen")
        // nothing of the app's (sockets, the GL context, other hooks' pipes) reaches the script
        try check(posix_spawn_file_actions_addclosefrom_np(&actions, STDERR_FILENO + 1), "addclosefrom_np")

        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer { args in
            envp.withUnsafeMutableBufferPointer { vars in
                posix_spawn(&pid, path, &actions, &attributes, args.baseAddress!, vars.baseAddress!)
            }
        }
        guard spawned == 0 else {
            throw LinuxHookProcessRunner.LaunchError(detail: "\(path): \(String(cString: strerror(spawned)))")
        }
        return pid
    }

    /// The exit code, or the signal number for a child killed by one (Foundation's `terminationStatus`).
    static func wait(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { return -1 }
        }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }

    private static func check(_ result: Int32, _ operation: String) throws {
        guard result == 0 else {
            throw LinuxHookProcessRunner.LaunchError(detail: "\(operation): \(String(cString: strerror(result)))")
        }
    }
}

/// Owns the write end from launch to close, on its own thread.
enum HookStdinWriter {
    static let retryInterval: Int32 = 50

    static func deliver(_ event: ControlEvent, encode: (ControlEvent) throws -> Data, to fd: Int32,
                        state: HookLaunchState, onFailure: (String) -> Void) {
        defer {
            close(fd)
            state.inputClosed()
        }
        guard !state.hasExited else { return }
        let data: Data
        do {
            data = try encode(event) + Data("\n".utf8)
        } catch {
            onFailure("encode: \(error.localizedDescription)")
            return
        }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count, !state.hasExited {
                let written = write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK {
                    var pending = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pending, 1, retryInterval)
                    continue
                }
                if code != EPIPE { onFailure(String(cString: strerror(code))) }
                return
            }
        }
    }
}

/// Shared by the termination handler and the writer thread; `onExit` fires once, when both are in.
final class HookLaunchState: @unchecked Sendable {
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var inputDone = false
    private var delivered = false
    private let onExit: @MainActor @Sendable (Int32) -> Void

    init(onExit: @escaping @MainActor @Sendable (Int32) -> Void) {
        self.onExit = onExit
    }

    var hasExited: Bool { lock.withLock { exitStatus != nil } }

    func childExited(_ status: Int32) {
        lock.withLock { exitStatus = status }
        finishIfDone()
    }

    func inputClosed() {
        lock.withLock { inputDone = true }
        finishIfDone()
    }

    private func finishIfDone() {
        let status: Int32? = lock.withLock {
            guard let status = exitStatus, inputDone, !delivered else { return nil }
            delivered = true
            return status
        }
        guard let status else { return }
        let onExit = onExit
        runOnMain { MainActor.assumeIsolated { onExit(status) } }
    }
}
