import Foundation
import Glibc
import Testing
import agtermCore
@testable import AgtermLinux

/// Both roles in one process: an origin `ControlServer` serving `zmx.present` and `session.overlay.job.run`,
/// and a viewer client reaching it through the real `agtermctl zmx present` bridge, invoked directly where
/// production runs it over ssh.
@MainActor
@Suite(.serialized)
struct LinuxRemotePresentationTests {
    private struct Pair {
        let server: ControlServer
        let service: LinuxPresentationService
        let host: FakePresentationHost
        let store: AppStore
        let origin: Session
        let viewer: Session
        let socketPath: String
        let cli: String
    }

    private static var cli: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("agtermctl-linux").path
    }

    private func library() -> WindowLibrary {
        WindowLibrary(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("agt-rp-\(UUID().uuidString)", isDirectory: true), paneFinalizer: nil)
    }

    private func withPair(split: Bool = false, _ body: (Pair) throws -> Void) throws {
        let library = library()
        let host = FakePresentationHost(library: library)
        let service = LinuxPresentationService(host: host)
        service.schedule = { delay, fire in _ = LinuxRepeatingTimer(interval: delay) { fire(); return false } }
        let socketPath = "/tmp/agt-rp-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(path: socketPath)
        server.presentation = service
        server.start()
        defer {
            service.stopRemotePresentations()
            service.shutdownStreams()
            server.stop()
            unlink(ControlResolve.ownershipLockPath(forSocket: socketPath))
            pumpMainLoop(for: 0.1)
        }
        let store = try #require(library.activeStore)
        let workspace = try #require(store.currentWorkspaceID)
        let origin = try #require(store.addSession(toWorkspace: workspace, cwd: "/tmp"))
        origin.surface = TestSurface(backedByZmx: true)
        let viewer = try #require(store.addSession(toWorkspace: workspace, cwd: "/tmp", remoteHost: "buildbox"))
        viewer.surface = TestSurface()
        var daemons = [viewer.paneIdentity: ZmxSupport.daemonName(for: origin.paneIdentity)]
        if split {
            store.setSplitVisibility(origin.id, shown: true, axis: .leftRight)
            origin.splitSurface = TestSurface(backedByZmx: true)
            store.setSplitVisibility(viewer.id, shown: true, axis: .leftRight)
            viewer.splitSurface = TestSurface()
            let local = try #require(viewer.splitPaneIdentity), remote = try #require(origin.splitPaneIdentity)
            daemons[local] = ZmxSupport.daemonName(for: remote)
        }
        store.bindRemote(RemoteBinding(remoteSessionID: origin.id.uuidString, daemonsByLocalPane: daemons,
                                       presentationVersion: PresentationCodec.version), forSession: viewer.id)
        service.attach()
        service.transport = BridgeTransport(argv: [Self.cli, "zmx", "present", origin.id.uuidString, "--socket", socketPath])
        service.startRemotePresentation(for: viewer)
        pumpMainLoop(until: { viewer.remotePresentation?.connection == .connected && viewer.remotePresentation?.mode == .presenter })
        try #require(viewer.remotePresentation?.connection == .connected)
        try body(Pair(server: server, service: service, host: host, store: store, origin: origin, viewer: viewer,
                      socketPath: socketPath, cli: Self.cli))
    }

    private func node(_ session: Session, in store: AppStore) -> ControlSessionNode? {
        store.controlTree(paneForeground: { _ in nil }).workspaces.flatMap(\.sessions)
            .first { $0.id == session.id.uuidString }
    }

    @Test func statusContextHudAndNotifyTravelToTheViewerAndLeaveWithTheStream() throws {
        try withPair { pair in
            let (store, origin, viewer) = (pair.store, pair.origin, pair.viewer)
            #expect(node(origin, in: store)?.presenters == ControlPresentersNode(mirrors: 0, presenter: true))
            #expect(node(viewer, in: store)?.presentation == ControlPresentationNode(state: "connected", mode: "presenter"))

            _ = store.applyControlStatus(AgentIndicator(status: .blocked, blink: true), forSession: origin.id)
            pumpMainLoop(until: { viewer.agentIndicator.status == .blocked })
            #expect(viewer.agentIndicator.blink)

            _ = store.setContext("shipping", forSession: origin.id)
            pumpMainLoop(until: { viewer.mirroredContext == "shipping" })
            #expect(viewer.context == nil)
            #expect(node(viewer, in: store)?.context == "shipping")

            let file = "/tmp/agt-rp-hud-\(origin.id.uuidString.prefix(8)).txt"
            defer { unlink(file) }
            #expect(store.openHud(origin.id, command: "true", spec: HudSpec(message: "deploying", hideAfter: 60), file: file,
                                  size: HudPanelSize(widthPercent: 40, heightPercent: 20)))
            store.publishHud(forSession: origin.id, expiresAt: Date().addingTimeInterval(60))
            pumpMainLoop(until: { viewer.hudActive })
            #expect(viewer.hudSpec?.message == "deploying")
            #expect((pair.host.huds.last?.hideAfter ?? 0) > 50)
            #expect(viewer.remotePresentation?.hudBridged == true)

            _ = store.recordNotificationEvent(forSession: origin.id, title: "done", body: "the build finished",
                                              origin: .control)
            pumpMainLoop(until: { !pair.host.notifications.isEmpty })
            #expect(pair.host.notifications.map(\.body) == ["the build finished"])

            pair.service.shutdownStreams()
            pumpMainLoop(until: { viewer.agentIndicator.status == .idle && !viewer.hudActive && viewer.mirroredContext == nil })
            #expect(viewer.remotePresentation?.mode == .mirror)
            #expect(origin.agentIndicator.status == .blocked)
            #expect(origin.hudActive)
            #expect(node(origin, in: store)?.presenters == nil)
        }
    }

    @Test func theViewerFollowsTheOriginsSplitLayout() throws {
        try withPair(split: true) { pair in
            let (store, origin, viewer) = (pair.store, pair.origin, pair.viewer)
            store.setSplitVisibility(origin.id, shown: true, axis: .topBottom)
            pumpMainLoop(until: { viewer.splitAxis == .topBottom })
            #expect(viewer.splitAxis == .topBottom)

            store.setSplitVisibility(origin.id, shown: false)
            pumpMainLoop(until: { !viewer.isSplit })
            #expect(viewer.hasSplit)

            let formerSplit = viewer.splitPaneIdentity
            store.setSplitVisibility(origin.id, shown: true)
            #expect(store.swapPanes(origin.id) == nil)
            pumpMainLoop(until: { viewer.paneIdentity == formerSplit })
            #expect(viewer.paneIdentity == formerSplit)
            #expect(viewer.isSplit)
        }
    }

    @Test func anAskIsHandedToThePresenterAnsweredThereAndTakenBackWhenTheStreamGoes() throws {
        try withPair { pair in
            let (service, store, origin, viewer) = (pair.service, pair.store, pair.origin, pair.viewer)
            let windowID = try #require(pair.host.library?.windowID(for: store))
            let buttons = [ControlAskButton(id: "yes", label: "Yes"), ControlAskButton(id: "no", label: "No")]
            let first = PendingAsk(id: UUID().uuidString, title: "deploy?", buttons: buttons)
            let opened = service.presentAskRemotely(first, in: store, sessionID: origin.id,
                                                    placement: ControlAskPlacement(), windowID: windowID)
            #expect(opened?.ok == true)
            pumpMainLoop(until: { viewer.askReplica && viewer.askPending?.id == first.id })
            #expect(origin.askPresentedRemotely)
            #expect(node(origin, in: store)?.ask == ControlSessionAsk(id: first.id, remote: true))
            #expect(node(viewer, in: store)?.ask == ControlSessionAsk(id: first.id, replica: true))

            viewer.resolveAsk(id: first.id, ControlAskResult(result: .answered, id: "yes", label: "Yes", index: 0))
            pumpMainLoop(until: { AskRegistry.shared.result(for: first.id)?.result.result == .answered })
            #expect(AskRegistry.shared.result(for: first.id)?.result.id == "yes")

            let second = PendingAsk(id: UUID().uuidString, title: "again?", buttons: buttons)
            #expect(service.presentAskRemotely(second, in: store, sessionID: origin.id, placement: ControlAskPlacement(),
                                               windowID: windowID)?.ok == true)
            pumpMainLoop(until: { viewer.askPending?.id == second.id })
            service.shutdownStreams()
            pumpMainLoop(until: { !origin.askPresentedRemotely && viewer.askPending == nil })
            #expect(origin.askPending?.id == second.id)
            #expect(node(origin, in: store)?.ask == ControlSessionAsk(id: second.id))
        }
    }

    @Test func aGuiAskTheOriginCannotPlaceAfterTheStreamGoesEndsPresentationLost() throws {
        try withPair { pair in
            let (service, store, origin, viewer) = (pair.service, pair.store, pair.origin, pair.viewer)
            let windowID = try #require(pair.host.library?.windowID(for: store))
            pair.host.guiShown = true
            store.selectSession(viewer.id)
            let ask = PendingAsk(id: UUID().uuidString, title: "deploy?", buttons: [ControlAskButton(id: "yes", label: "Yes")],
                                 style: .gui)
            #expect(service.presentAskRemotely(ask, in: store, sessionID: origin.id, placement: ControlAskPlacement(),
                                               windowID: windowID)?.ok == true)
            pumpMainLoop(until: { viewer.askPending?.id == ask.id })
            #expect(viewer.askReplica)
            pair.host.guiShown = false

            service.shutdownStreams()
            pumpMainLoop(until: { AskRegistry.shared.result(for: ask.id)?.result.result == .cancelled })
            #expect(AskRegistry.shared.result(for: ask.id)?.result.reason == ControlAskResult.presentationLost)
            #expect(origin.askPending == nil)
        }
    }

    @Test func anOverlayJobIsClaimedOverTheSocketAndItsExitCodeIsTheOriginsResult() throws {
        try withPair { pair in
            let (service, store, origin, viewer) = (pair.service, pair.store, pair.origin, pair.viewer)
            let ran = "/tmp/agt-rp-ran-\(UUID().uuidString.prefix(8))"
            defer { unlink(ran) }
            let options = ControlSessionOverlayOpenOptions(command: "echo ran >> \(ran); exit 7", cwd: "/tmp", wait: false,
                                                           sizePercent: 60, backgroundColor: nil, follow: false, pane: nil)
            #expect(service.openRemoteOverlay(in: store, sessionID: origin.id, options: options)?.ok == true)
            pumpMainLoop(until: { viewer.overlayReplica != nil })
            let job = try #require(viewer.overlayReplica?.job)
            #expect(viewer.overlayCommand?.contains("run-job") == true)
            #expect(!origin.overlayActive)
            #expect(node(origin, in: store)?.remoteOverlays == [ControlRemoteOverlayNode(pane: nil, sizePercent: 60)])

            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: pair.cli)
            helper.arguments = ["session", "overlay", "run-job", job, "--socket", pair.socketPath]
            helper.standardInput = FileHandle.nullDevice
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try helper.run()
            pumpMainLoop(until: { origin.overlayExitCode == 7 })
            helper.waitUntilExit()
            #expect(origin.overlayExitCode == 7)
            #expect(helper.terminationStatus == 7)
            #expect(try String(contentsOfFile: ran, encoding: .utf8) == "ran\n")

            let again = request(ControlRequest(cmd: .sessionOverlayJobRun, target: job), socket: pair.socketPath)
            #expect(again?.error == "job not claimable")
        }
    }

    @Test func aSessionThatIsNotLiveBackedIsRefusedWithAnOrdinaryReply() throws {
        try withPair { pair in
            let workspace = try #require(pair.store.currentWorkspaceID)
            let plain = try #require(pair.store.addSession(toWorkspace: workspace, cwd: "/tmp"))
            let reply = request(ControlRequest(cmd: .zmxPresent, target: plain.id.uuidString), socket: pair.socketPath)
            #expect(reply?.error == "session is not live-backed, so nothing can be attached to it")
        }
    }

    @Test func aPeerThatNeverSaysHelloIsDroppedAfterTheDeadline() throws {
        try withPair { pair in
            pair.service.helloDeadline = 0.2
            let fd = try #require(connect(pair.socketPath))
            defer { close(fd) }
            send(ControlRequest(cmd: .zmxPresent, target: pair.origin.id.uuidString), on: fd)
            pumpMainLoop(until: { pair.service.streams.count == 2 })
            pumpMainLoop(until: { pair.service.streams.count == 1 })
            #expect(pair.service.streams.count == 1)
        }
    }

    @Test func aStreamEndsWhenItsSourceSessionLeaves() throws {
        try withPair { pair in
            pair.store.closeSession(pair.origin.id)
            pair.service.beat()
            pumpMainLoop(until: { pair.service.streams.isEmpty })
            #expect(pair.service.streams.isEmpty)
            pumpMainLoop(until: { pair.viewer.remotePresentation?.connection != .connected })
            #expect(pair.viewer.remotePresentation?.connection != .connected)
        }
    }

    // MARK: - Socket helpers

    private func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buf in
                bytes.withUnsafeBufferPointer { buf.update(from: $0.baseAddress!, count: $0.count) }
            }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private func send(_ request: ControlRequest, on fd: Int32) {
        guard var line = try? JSONEncoder().encode(request) else { return }
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// One request and its reply, read on a worker so the GTK loop keeps pumping for the server's hop.
    private func request(_ request: ControlRequest, socket path: String) -> ControlResponse? {
        guard let fd = connect(path) else { return nil }
        defer { close(fd) }
        send(request, on: fd)
        let reply = ReplyBox()
        Thread.detachNewThread {
            var line = Data()
            var byte: UInt8 = 0
            while read(fd, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
            reply.set(line)
        }
        pumpMainLoop(until: { reply.get() != nil })
        return reply.get().flatMap { try? JSONDecoder().decode(ControlResponse.self, from: $0) }
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var line: Data?
    func set(_ value: Data) { lock.withLock { line = value } }
    func get() -> Data? { lock.withLock { line } }
}

@MainActor
final class TestSurface: PaneRoleMutableSurface {
    let backedByZmx: Bool
    var isRealized = true
    let paneToken = ""

    init(backedByZmx: Bool = false) { self.backedByZmx = backedByZmx }

    func teardown() { isRealized = false }
    func promoteToPrimaryPane() {}
    func setPaneRole(_ role: SwappablePaneRole) {}
}

/// The GTK side of presentation, recorded. A mirrored HUD is opened in the store as the app's HUD path does.
@MainActor
final class FakePresentationHost: LinuxPresentationHost {
    let library: WindowLibrary?
    var huds: [HudSpec] = []
    var notifications: [PresentationNotify] = []
    var guiShown = false
    var closedPanes: [UUID] = []

    init(library: WindowLibrary?) { self.library = library }

    func sessionEnvironment(for session: Session, in store: AppStore) -> [String: String] {
        ["AGTERM_SESSION_ID": session.id.uuidString]
    }

    func openMirroredHud(_ spec: HudSpec, pane: OverlayPane?, sessionID: UUID) -> ControlResponse {
        huds.append(spec)
        let file = "/tmp/agt-rp-hud-\(sessionID.uuidString.prefix(8)).txt"
        guard library?.store(forSession: sessionID)?.openHud(sessionID, command: "true", spec: spec, file: file,
                                                               size: HudPanelSize(widthPercent: 40, heightPercent: 20)) == true
        else { return ControlResponse(ok: false, error: "overlay already open") }
        return ControlResponse(ok: true)
    }

    func updateMirroredHud(_ spec: HudSpec, pane: OverlayPane?, sessionID: UUID) -> ControlResponse {
        huds.append(spec)
        let updated = library?.store(forSession: sessionID)?.updateHud(sessionID, spec: spec,
                                                                        size: HudPanelSize(widthPercent: 40, heightPercent: 20))
        return ControlResponse(ok: updated == true)
    }

    func guiTargetShown(_ sessionID: UUID, in store: AppStore) -> Bool {
        guiShown && store.selectedSessionID == sessionID
    }

    func openTakenBackGuiAsk(_ ask: PendingAsk, session: Session, in store: AppStore) -> Bool { false }

    func deliverMirroredNotification(_ notify: PresentationNotify, sessionID: UUID, in store: AppStore) {
        notifications.append(notify)
    }

    func swapRemotePanes(_ sessionID: UUID, in store: AppStore) -> Bool { store.swapPanes(sessionID) == nil }

    func closeRemovedRemotePane(_ local: UUID, sessionID: UUID, in store: AppStore) { closedPanes.append(local) }

    func presentationChanged(_ sessionID: UUID, in store: AppStore, _ change: LinuxPresentationChange) {}
}

/// Launches the real bridge binary against the origin's socket, whatever argv the client builds for ssh.
@MainActor
final class BridgeTransport: RemotePresentationTransport {
    let argv: [String]
    private let process = LinuxRemotePresentationProcess()

    init(argv: [String]) { self.argv = argv }

    func open(_ ignored: [String], onLine: @escaping @MainActor (Data) -> Void,
              onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
        process.open(argv, onLine: onLine, onClose: onClose)
    }
}
