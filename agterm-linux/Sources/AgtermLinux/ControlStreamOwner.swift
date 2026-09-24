import Foundation
import Glibc

/// Owns one control connection that stays open and carries newline-delimited lines both ways, once the
/// accept loop has handed its descriptor over. The Linux port of macOS `ControlStreamOwner`.
///
/// A reader thread and a writer thread do the blocking I/O, so neither the accept thread nor the GTK thread
/// ever waits on the peer. The reader thread is the only closer of the descriptor: `shutdown` wakes it with
/// `shutdown(2)` rather than closing from another thread, which could hand a reused descriptor number to a
/// thread still reading. The `shutdown(2)` and the final `close` both happen under `state`, or the reader
/// could close in between and the call would land on whatever reused the number.
final class ControlStreamOwner: @unchecked Sendable {
    struct Limits: Sendable {
        var maxLineBytes: Int
        var maxPendingLines: Int
        /// Bounds one blocked write. A peer that stops reading is dropped after this, not waited on.
        var writeTimeoutSeconds: Int
    }

    private let fd: Int32
    private let limits: Limits
    private let state = NSCondition()
    private var pending: [Data] = []
    private var closing = false
    private var descriptorClosed = false
    private var started = false

    init(descriptor: Int32, limits: Limits) {
        fd = descriptor
        self.limits = limits
    }

    /// Replaces request/reply socket timing with stream timing and starts both threads. `onLine` and
    /// `onClose` run on the reader thread; `onClose` runs exactly once, after the descriptor is closed.
    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        let first: Bool = state.withLock {
            defer { started = true }
            return !started
        }
        guard first else { return }

        // an idle stream is healthy, so reads never time out; liveness is the app-level ping. Writes stay
        // bounded: with no send timeout a peer that stopped reading would park the writer thread forever.
        var none = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        var bound = timeval(tv_sec: limits.writeTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &bound, socklen_t(MemoryLayout<timeval>.size))

        let writerDone = DispatchSemaphore(value: 0)
        let writer = Thread { [self] in
            writeLoop()
            writerDone.signal()
        }
        writer.name = "agterm.control.stream.write"
        writer.start()

        let reader = Thread { [self] in
            readLoop(onLine: onLine)
            shutdown()
            writerDone.wait()
            state.withLock {
                descriptorClosed = true
                close(fd)
            }
            onClose()
        }
        reader.name = "agterm.control.stream.read"
        reader.start()
    }

    /// Queues one line, newline included. False when the stream is closing or the queue is full, which the
    /// caller treats as a stalled peer. Never blocks.
    func send(_ line: Data) -> Bool {
        state.withLock {
            guard !closing, pending.count < limits.maxPendingLines else { return false }
            pending.append(line)
            state.signal()
            return true
        }
    }

    /// Ends the stream from any thread. Idempotent.
    func shutdown() {
        state.withLock {
            guard !closing else { return }
            closing = true
            state.broadcast()
            if !descriptorClosed { Glibc.shutdown(fd, Int32(SHUT_RDWR)) }
        }
    }

    private func readLoop(onLine: (Data) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                guard newline - buffer.startIndex <= limits.maxLineBytes else { return oversize() }
                onLine(Data(buffer[buffer.startIndex..<newline]))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            guard buffer.count <= limits.maxLineBytes else { return oversize() }
        }
    }

    private func oversize() {
        FileHandle.standardError.write(Data("agterm: control stream line exceeds \(limits.maxLineBytes) bytes; closing\n".utf8))
    }

    private func writeLoop() {
        while let line = nextLine() {
            guard write(line) else {
                shutdown()
                return
            }
        }
    }

    private func nextLine() -> Data? {
        state.withLock {
            while pending.isEmpty, !closing { state.wait() }
            return closing ? nil : pending.removeFirst()
        }
    }

    /// `MSG_NOSIGNAL` where Darwin sets `SO_NOSIGPIPE`: a peer gone mid-write must fail the write, not the app.
    private func write(_ line: Data) -> Bool {
        line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < line.count {
                let count = Glibc.send(fd, base + offset, line.count - offset, Int32(MSG_NOSIGNAL))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
