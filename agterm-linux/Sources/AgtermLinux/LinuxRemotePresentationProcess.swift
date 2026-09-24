import Foundation
import Glibc
import agtermCore

/// Runs the presentation bridge as a long-lived child process, the ssh to an origin in production. The Linux
/// port of macOS `RemotePresentationProcess`, on `HookSpawn` rather than Foundation's `Process` for the reason
/// `LinuxProcessCapture` gives.
@MainActor
final class LinuxRemotePresentationProcess: RemotePresentationTransport {
    func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
              onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
        LinuxProcessLink(argv: argv, onLine: onLine, onClose: onClose)
    }
}

/// Whether the child was waited for, under a lock, so `stop` never signals a pid the waiter already reaped
/// and the kernel may have reused.
private final class ChildState: @unchecked Sendable {
    let lock = NSLock()
    var exited = false
    /// Descriptors both readers poll beside their own pipe; one byte ends both, and the last reader closes it.
    let wake: [Int32]
    private var readers = 2

    init(wake: [Int32]) { self.wake = wake }

    func readerEnded() {
        let last: Bool = lock.withLock {
            readers -= 1
            return readers == 0
        }
        if last { wake.forEach { close($0) } }
    }
}

/// One child and its three pipes. Stdout is read a line at a time on a thread of its own and handed to the
/// GTK thread; stdin takes the client's frames; stderr goes to the log, where an ssh failure is worth reading.
@MainActor
private final class LinuxProcessLink: RemotePresentationLink {
    private var pid: pid_t = 0
    private var input: Int32 = -1
    private var state: ChildState?
    private var closed = false
    private var exitReason: String?
    private var outputEnded = false
    private var readersEnded = false
    private let onClose: @MainActor (String) -> Void

    init(argv: [String], onLine: @escaping @MainActor (Data) -> Void, onClose: @escaping @MainActor (String) -> Void) {
        self.onClose = onClose
        guard let stdin = Self.pipePair(), let stdout = Self.pipePair(), let stderr = Self.pipePair(),
              let wake = Self.pipePair() else {
            fail("could not create the bridge's pipes")
            return
        }
        do {
            // env resolves `ssh` through PATH, so a user who put their own ahead of /usr/bin keeps it
            pid = try HookSpawn.spawn("/usr/bin/env", arguments: ["env"] + argv,
                                      environment: ProcessInfo.processInfo.environment,
                                      stdin: stdin[0], stdout: stdout[1], stderr: stderr[1])
        } catch {
            (stdin + stdout + stderr + wake).forEach { close($0) }
            fail("could not run \(argv.first ?? "the bridge"): \(error)")
            return
        }
        [stdin[0], stdout[1], stderr[1]].forEach { close($0) }
        input = stdin[1]
        // a frame is a few hundred bytes and the pipe holds 64 KiB, so a write that would block means the
        // child stopped reading: fail it then, never stall the GTK thread on it
        _ = fcntl(input, F_SETFL, fcntl(input, F_GETFL) | O_NONBLOCK)
        let state = ChildState(wake: wake)
        self.state = state
        let pid = pid
        Thread.detachNewThread { [weak self] in
            let reason = "exit \(Self.waitForExit(pid, state: state))"
            let link = WeakLink(self)
            runOnMain { MainActor.assumeIsolated { link.link?.exited(reason) } }
        }
        // the reader stops reading past this many undelivered lines, so a busy GTK thread backs the child up
        // into its own pipe and never into this app's memory
        let inbound = DispatchSemaphore(value: LinuxPresentationService.inboundLimit)
        let link = WeakLink(self)
        Self.readLines(from: stdout[0], state: state, deliver: { line in
            inbound.wait()
            runOnMain {
                MainActor.assumeIsolated { onLine(line) }
                inbound.signal()
            }
        }, ended: {
            runOnMain { MainActor.assumeIsolated { link.link?.outputDidEnd() } }
        })
        Self.readLines(from: stderr[0], state: state, deliver: { line in
            FileHandle.standardError.write(Data("agterm: presentation bridge: ".utf8) + line + Data("\n".utf8))
        }, ended: {})
    }

    func send(_ line: Data) {
        guard !closed, input >= 0 else { return }
        let written = line.withUnsafeBytes { Glibc.write(input, $0.baseAddress, $0.count) }
        guard written != line.count else { return }
        stop()
    }

    func stop() {
        // the client releases a link right after stopping it, so no later callback can end the readers
        endReaders()
        guard let state, pid > 0 else { return }
        let pid = pid
        state.lock.withLock {
            if !state.exited { kill(pid, SIGTERM) }
        }
    }

    /// The close waits for stdout's end, queued behind the last line, so the frames a child wrote just
    /// before exiting are delivered first. A descendant can hold the pipe open past the exit, hence the
    /// deadline.
    fileprivate func exited(_ reason: String) {
        exitReason = reason
        if outputEnded { finish(reason); return }
        MainTimer.schedule(after: 2) { [weak self] in self?.finish(reason) }
    }

    fileprivate func outputDidEnd() {
        outputEnded = true
        if let exitReason { finish(exitReason); return }
        stop()   // nothing more can be read, so the child is of no use
    }

    private func fail(_ reason: String) {
        MainTimer.schedule(after: 0) { [weak self] in self?.finish(reason) }
    }

    private func endReaders() {
        guard !readersEnded, let state else { return }
        readersEnded = true
        state.lock.withLock {
            var byte: UInt8 = 0
            _ = Glibc.write(state.wake[1], &byte, 1)
        }
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        if input >= 0 { close(input) }
        input = -1
        endReaders()
        onClose(reason)
    }

    /// Waits without reaping, marks the child exited under the lock, then reaps it.
    private nonisolated static func waitForExit(_ pid: pid_t, state: ChildState) -> Int32 {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
        state.lock.withLock { state.exited = true }
        return HookSpawn.wait(pid)
    }

    private nonisolated static func pipePair() -> [Int32]? {
        var pair: [Int32] = [-1, -1]
        guard pipe(&pair) == 0 else { return nil }
        pair.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        return pair
    }

    /// Reads `fd` on a thread of its own, one line at a time, until its end or a byte on the wake pipe, then
    /// closes it and calls `ended`. A line over the frame limit ends the read undelivered, which the child
    /// sees as a closed pipe.
    private nonisolated static func readLines(from fd: Int32, state: ChildState,
                                              deliver: @escaping @Sendable (Data) -> Void,
                                              ended: @escaping @Sendable () -> Void) {
        let thread = Thread {
            var polled = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                          pollfd(fd: state.wake[0], events: Int16(POLLIN), revents: 0)]
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            reading: while true {
                let ready = poll(&polled, 2, -1)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0, polled[1].revents == 0 else { break }
                let count = read(fd, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    guard newline - buffer.startIndex <= PresentationCodec.maxFrameBytes else { break reading }
                    deliver(Data(buffer[buffer.startIndex..<newline]))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
                guard buffer.count <= PresentationCodec.maxFrameBytes else { break }
            }
            close(fd)
            ended()
            state.readerEnded()
        }
        thread.name = "agterm.presentation.read"
        thread.start()
    }
}

private final class WeakLink: @unchecked Sendable {
    weak var link: LinuxProcessLink?
    init(_ link: LinuxProcessLink?) { self.link = link }
}
