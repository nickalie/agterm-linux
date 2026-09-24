import Dispatch
import Foundation
import Glibc

/// The Linux counterpart of macOS `ProcessOutputCapture`, shared by the zmx and ssh runners: both streams
/// drain while the child runs, so a full pipe cannot block its exit, and the pipes are close-on-exec, so a
/// surface child spawned meanwhile cannot hold EOF back.
///
/// `posix_spawn` and `waitpid` rather than Foundation's `Process`, for `HookSpawn`'s reason: an ssh
/// `ControlPersist` master would otherwise hold the termination notice for its own lifetime.
enum LinuxProcessCapture {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    enum Failure: Error, Equatable {
        case launch(String)
        /// The child outlived the deadline and was killed.
        case timedOut
        /// The child exited but a write end leaked to another process kept its output open past the grace.
        case outputStalled
    }

    /// Blocks the calling thread for up to `timeout` plus two `grace` periods. `arguments` starts with argv[0].
    static func run(_ path: String, arguments: [String], environment: [String: String],
                    timeout: TimeInterval, grace: TimeInterval) throws(Failure) -> Output {
        let out = try pipePair()
        let err: [Int32]
        do {
            err = try pipePair()
        } catch {
            out.forEach { close($0) }
            throw error
        }
        let pid: pid_t
        do {
            pid = try HookSpawn.spawn(path, arguments: arguments, environment: environment, stdin: nil,
                                      stdout: out[1], stderr: err[1])
        } catch {
            (out + err).forEach { close($0) }
            throw .launch((error as? LinuxHookProcessRunner.LaunchError)?.detail ?? "\(error)")
        }
        // EOF cannot arrive while the parent still holds the write ends
        close(out[1])
        close(err[1])
        let stdoutReader = PipeReader(fileDescriptor: out[0])
        let stderrReader = PipeReader(fileDescriptor: err[0])
        let exit = ExitWaiter(pid: pid)

        guard let status = exit.wait(until: .now() + timeout) else {
            kill(pid, SIGTERM)
            if exit.wait(until: .now() + grace) == nil {
                kill(pid, SIGKILL)
                _ = exit.wait(until: .distantFuture)
            }
            stdoutReader.cancel()
            stderrReader.cancel()
            throw .timedOut
        }
        let deadline = DispatchTime.now() + grace
        guard let stdout = stdoutReader.wait(until: deadline), let stderr = stderrReader.wait(until: deadline) else {
            stdoutReader.cancel()
            stderrReader.cancel()
            throw .outputStalled
        }
        return Output(status: status, stdout: String(decoding: stdout, as: UTF8.self),
                      stderr: String(decoding: stderr, as: UTF8.self))
    }

    /// Swift does not import glibc's `pipe2`, which needs `_GNU_SOURCE`.
    private static func pipePair() throws(Failure) -> [Int32] {
        var pair: [Int32] = [-1, -1]
        guard pipe(&pair) == 0 else { throw .launch("pipe: \(String(cString: strerror(errno)))") }
        guard fcntl(pair[0], F_SETFD, FD_CLOEXEC) == 0, fcntl(pair[1], F_SETFD, FD_CLOEXEC) == 0 else {
            let message = String(cString: strerror(errno))
            pair.forEach { close($0) }
            throw .launch("FD_CLOEXEC: \(message)")
        }
        return pair
    }

    /// Reaps the child on a thread of its own, never a pool worker, since the wait can outlast the caller's.
    private final class ExitWaiter: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        // written once before `done` is signalled, read only after a successful wait
        private var status: Int32 = -1

        init(pid: pid_t) {
            Thread.detachNewThread { [self] in
                status = HookSpawn.wait(pid)
                done.signal()
            }
        }

        func wait(until deadline: DispatchTime) -> Int32? {
            guard done.wait(timeout: deadline) == .success else { return nil }
            done.signal()
            return status
        }
    }
}

/// One pipe read end drained through a `DispatchIO` channel, which owns the descriptor and alone closes
/// it. Cancelling interrupts a read the peer still holds open, where a blocking read would park a thread
/// for that peer's lifetime.
final class PipeReader: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private let channel: DispatchIO
    // written only by the read handler before `finished` is signalled, and read only after a successful wait
    private var data = Data()
    private var failure: Int32 = 0

    init(fileDescriptor fd: Int32) {
        let queue = DispatchQueue(label: "agterm.pipe-reader")
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue,
                                 cleanupHandler: { @Sendable _ in close(fd) })
        self.channel = channel
        channel.read(offset: 0, length: Int.max, queue: queue) { @Sendable [self] done, chunk, error in
            if let chunk, !chunk.isEmpty { data.append(contentsOf: chunk) }
            guard done else { return }
            failure = error
            channel.close()
            finished.signal()
        }
    }

    /// Everything read through EOF, or nil when `deadline` passed first or the read failed.
    func wait(until deadline: DispatchTime) -> Data? {
        guard finished.wait(timeout: deadline) == .success else { return nil }
        finished.signal()
        return failure == 0 ? data : nil
    }

    func cancel() {
        channel.close(flags: .stop)
    }
}
