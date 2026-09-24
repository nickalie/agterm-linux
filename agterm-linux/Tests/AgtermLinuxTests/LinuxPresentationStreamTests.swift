import Foundation
import Glibc
import Testing
import agtermCore
@testable import AgtermLinux

@Suite(.serialized)
struct ControlStreamOwnerTests {
    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private var closes = 0
        func add(_ line: Data) { lock.withLock { lines.append(String(decoding: line, as: UTF8.self)) } }
        func closed() { lock.withLock { closes += 1 } }
        var snapshot: (lines: [String], closes: Int) { lock.withLock { (lines, closes) } }
    }

    private func pair() throws -> (owned: Int32, peer: Int32) {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    private func waitFor(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { usleep(2_000) }
    }

    private func limits(line: Int = 64, pending: Int = 4) -> ControlStreamOwner.Limits {
        ControlStreamOwner.Limits(maxLineBytes: line, maxPendingLines: pending, writeTimeoutSeconds: 1)
    }

    @Test func linesTravelBothWays() throws {
        let (owned, peer) = try pair()
        defer { close(peer) }
        let received = Received()
        let owner = ControlStreamOwner(descriptor: owned, limits: limits())
        owner.start(onLine: { received.add($0) }, onClose: { received.closed() })
        _ = "one\ntwo\n".withCString { write(peer, $0, 8) }
        waitFor { received.snapshot.lines.count == 2 }
        #expect(received.snapshot.lines == ["one", "two"])
        #expect(owner.send(Data("back\n".utf8)))
        var buffer = [UInt8](repeating: 0, count: 5)
        #expect(read(peer, &buffer, 5) == 5)
        #expect(String(decoding: buffer, as: UTF8.self) == "back\n")
        owner.shutdown()
        waitFor { received.snapshot.closes == 1 }
    }

    @Test func aLineOverTheLimitClosesTheStreamUndelivered() throws {
        let (owned, peer) = try pair()
        defer { close(peer) }
        let received = Received()
        let owner = ControlStreamOwner(descriptor: owned, limits: limits(line: 8))
        owner.start(onLine: { received.add($0) }, onClose: { received.closed() })
        let long = String(repeating: "x", count: 20) + "\n"
        _ = long.withCString { write(peer, $0, long.utf8.count) }
        waitFor { received.snapshot.closes == 1 }
        #expect(received.snapshot.lines.isEmpty)
        #expect(received.snapshot.closes == 1)
    }

    @Test func aFullQueueRefusesTheNextLineWithoutBlocking() throws {
        let (owned, peer) = try pair()
        defer { close(peer) }
        var small: Int32 = 1
        setsockopt(owned, SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        let owner = ControlStreamOwner(descriptor: owned, limits: limits(line: 1 << 20, pending: 2))
        let received = Received()
        owner.start(onLine: { received.add($0) }, onClose: { received.closed() })
        let big = Data(repeating: 0x61, count: 512 * 1024) + Data("\n".utf8)
        var accepted = 0
        for _ in 0..<16 where owner.send(big) { accepted += 1 }
        #expect(accepted < 16)
        owner.shutdown()
        waitFor { received.snapshot.closes == 1 }
    }

    @Test func thePeerClosingEndsTheStreamOnce() throws {
        let (owned, peer) = try pair()
        let received = Received()
        let owner = ControlStreamOwner(descriptor: owned, limits: limits())
        owner.start(onLine: { received.add($0) }, onClose: { received.closed() })
        close(peer)
        waitFor { received.snapshot.closes == 1 }
        owner.shutdown()
        usleep(50_000)
        #expect(received.snapshot.closes == 1)
        #expect(!owner.send(Data("late\n".utf8)))
    }
}

/// The viewer client as the service runs it, over a transport that records launches, on an injected clock.
@MainActor
@Suite(.serialized)
struct LinuxPresentationViewerTests {
    @MainActor
    final class RecordingTransport: RemotePresentationTransport {
        final class Link: RemotePresentationLink {
            var stopped = false
            func send(_ line: Data) {}
            func stop() { stopped = true }
        }

        var launches: [[String]] = []
        var links: [Link] = []
        var closers: [@MainActor (String) -> Void] = []

        func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
                  onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
            launches.append(argv)
            closers.append(onClose)
            let link = Link()
            links.append(link)
            return link
        }
    }

    private struct Fixture {
        let service: LinuxPresentationService
        let transport: RecordingTransport
        let store: AppStore
        let viewer: Session
        let clock: TestClock
    }

    private func fixture(version: Int? = PresentationCodec.version) throws -> Fixture {
        let library = WindowLibrary(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("agt-rpv-\(UUID().uuidString)", isDirectory: true), paneFinalizer: nil)
        let service = LinuxPresentationService(host: FakePresentationHost(library: library))
        let transport = RecordingTransport()
        let clock = TestClock()
        service.transport = transport
        service.clock = { clock.now }
        let store = try #require(library.activeStore)
        let workspace = try #require(store.currentWorkspaceID)
        let viewer = try #require(store.addSession(toWorkspace: workspace, cwd: "/tmp", remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: UUID().uuidString, daemonsByLocalPane: [:],
                                       presentationVersion: version), forSession: viewer.id)
        service.attach()
        return Fixture(service: service, transport: transport, store: store, viewer: viewer, clock: clock)
    }

    final class TestClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @Test func theBridgeRunsOverSshAgainstTheOriginsSession() throws {
        let fix = try fixture()
        defer { fix.service.stopRemotePresentations() }
        fix.service.startRemotePresentation(for: fix.viewer)
        #expect(fix.transport.launches.count == 1)
        #expect(fix.transport.launches[0].prefix(2) == ["ssh", "-T"])
        #expect(fix.transport.launches[0].last?.contains("agtermctl zmx present") == true)
        #expect(fix.viewer.remotePresentation?.connection == .connecting)
    }

    @Test func anOriginWithoutTheProtocolIsNeverLaunched() throws {
        let fix = try fixture(version: nil)
        defer { fix.service.stopRemotePresentations() }
        fix.service.startRemotePresentation(for: fix.viewer)
        #expect(fix.transport.launches.isEmpty)
        let node = fix.store.controlTree(paneForeground: { _ in nil }).workspaces.flatMap(\.sessions)
            .first { $0.id == fix.viewer.id.uuidString }
        #expect(node?.presentation?.state == "unsupported")
    }

    @Test func aLostLinkIsRetriedAfterOneThenTwoSecondsAndReadsBackFailed() throws {
        let fix = try fixture()
        defer { fix.service.stopRemotePresentations() }
        fix.service.startRemotePresentation(for: fix.viewer)
        fix.transport.closers[0]("exit 255")
        #expect(fix.viewer.remotePresentation?.connection == .failed("exit 255"))
        fix.clock.now += 0.9
        fix.service.tickRemoteClients()
        #expect(fix.transport.launches.count == 1)
        fix.clock.now += 0.2
        fix.service.tickRemoteClients()
        #expect(fix.transport.launches.count == 2)

        fix.transport.closers[1]("exit 255")
        fix.clock.now += 1.9
        fix.service.tickRemoteClients()
        #expect(fix.transport.launches.count == 2)
        fix.clock.now += 0.2
        fix.service.tickRemoteClients()
        #expect(fix.transport.launches.count == 3)
    }

    @Test func thirtySecondsWithoutAFrameCountsAsAFailure() throws {
        let fix = try fixture()
        defer { fix.service.stopRemotePresentations() }
        fix.service.startRemotePresentation(for: fix.viewer)
        fix.clock.now += 31
        fix.service.tickRemoteClients()
        #expect(fix.transport.links[0].stopped)
        #expect(fix.viewer.remotePresentation?.connection == .failed("no frames for 30 seconds"))
    }

    @Test func aSoftCloseStopsTheClientAndUndoStartsAFreshOne() throws {
        let fix = try fixture()
        defer { fix.service.stopRemotePresentations() }
        fix.service.startRemotePresentation(for: fix.viewer)
        #expect(fix.store.softCloseSession(fix.viewer.id))
        #expect(fix.transport.links[0].stopped)
        #expect(fix.service.remoteClients[fix.viewer.id] == nil)
        #expect(fix.store.undoPendingClose())
        #expect(fix.transport.launches.count == 2)
        #expect(fix.service.remoteClients[fix.viewer.id] != nil)
    }
}
