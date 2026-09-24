import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@MainActor
final class LinuxHooksTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-linux-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Exits on demand, so a test can drain each hook's queue without real processes.
    private final class RecordingLauncher: HookLauncher {
        var launched: [ControlEvent] = []
        private var running: [@MainActor @Sendable (Int32) -> Void] = []

        func launch(entry: HookEntry, event: ControlEvent,
                    onDeliveryFailure: @escaping @MainActor @Sendable (String) -> Void,
                    onExit: @escaping @MainActor @Sendable (Int32) -> Void) throws -> Int32 {
            launched.append(event)
            running.append(onExit)
            return Int32(launched.count)
        }

        func drain() {
            while !running.isEmpty { running.removeFirst()(0) }
        }
    }

    private final class StubSurface: TerminalSurface {
        func teardown() {}
        func promoteToPrimaryPane() {}
        var isRealized: Bool { true }
        var paneToken: String { "" }
    }

    private func controller(_ launcher: HookLauncher, failures: @escaping (HookEntry, String) -> Void = { _, _ in })
        -> LinuxHookController {
        LinuxHookController(configDirectory: { [directory] in directory }, launcher: launcher, onFailure: failures)
    }

    private func write(_ text: String) throws {
        try text.write(to: directory.appendingPathComponent("hooks.conf"), atomically: true, encoding: .utf8)
    }

    @Test func reloadParsesTheFileAndListsItsHooksAndDiagnostics() throws {
        let hooks = controller(RecordingLauncher())
        try write("on status echo hi\nbogus line\non pane.split ./layout.sh\n")

        #expect(hooks.reload() == 1)

        let listing = hooks.listing
        #expect(listing.path == directory.appendingPathComponent("hooks.conf").path)
        #expect(listing.hooks.map(\.kind) == ["status", "pane.split"])
        #expect(listing.hooks.map(\.line) == [1, 3])
        #expect(listing.diagnostics == [ControlKeymapDiagnostic(line: 2, message: "unknown verb 'bogus'")])
    }

    @Test func anUnreadableFileIsADiagnosticNotAnEmptyConfiguration() throws {
        let hooks = controller(RecordingLauncher())
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("hooks.conf"),
                                                withIntermediateDirectories: true)

        #expect(hooks.reload() == 1)
        #expect(hooks.diagnostics.first?.line == 0)
        #expect(hooks.listing.hooks.isEmpty)
    }

    @Test func aMissingFileIsCleanAndTheStarterIsWrittenOnlyOnce() throws {
        let hooks = controller(RecordingLauncher())
        #expect(hooks.reload() == 0)

        hooks.ensureStarter()
        let url = directory.appendingPathComponent("hooks.conf")
        #expect(try String(contentsOf: url, encoding: .utf8) == ConfigPaths.starterHooksConf())
        try write("on notify true\n")
        hooks.ensureStarter()
        #expect(try String(contentsOf: url, encoding: .utf8) == "on notify true\n")
    }

    @Test func libraryEventsReachHooksIncludingPaneAndRemoteEdges() throws {
        let launcher = RecordingLauncher()
        let hooks = controller(launcher)
        try write("""
        on pane.split true
        on pane.scratch true
        on remote.opened true
        on remote.closed true
        """)
        hooks.reload()
        let library = WindowLibrary(directory: directory.appendingPathComponent("state"),
                                    controlEventRing: ControlEventRing(runID: UUID()))
        hooks.observe(library)
        let store = try #require(library.activeStore)
        let workspace = try #require(store.workspaces.first)

        let remote = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", command: "ssh far",
                                                   name: "far", wait: true, remoteHost: "buildbox"))
        launcher.drain()
        store.setSplitVisibility(remote.id, shown: true, axis: .leftRight)
        launcher.drain()
        store.applyScratchRequest(remote.id, want: true, command: nil) {}
        remote.scratchSurface = StubSurface()
        launcher.drain()
        var settled = 0
        store.applyScratchRequest(remote.id, want: true, command: "htop") { settled += 1 }
        remote.scratchSurface = StubSurface()
        launcher.drain()
        store.applyScratchRequest(remote.id, want: false, command: nil) {}
        launcher.drain()
        #expect(store.softCloseSession(remote.id, grace: 60))
        launcher.drain()
        #expect(store.undoPendingClose())
        launcher.drain()

        #expect(settled == 1)
        #expect(remote.scratchCommand == "htop")
        let edges = launcher.launched.map { "\($0.kind.rawValue):\($0.payload.status ?? $0.payload.host ?? "")" }
        #expect(edges == ["remote.opened:buildbox", "pane.split:shown", "pane.scratch:shown", "pane.scratch:hidden",
                          "remote.closed:buildbox", "remote.opened:buildbox"])
    }

    @Test func deliveredNotificationsReachNotifyHooksWithTheEffectiveTitle() throws {
        let launcher = RecordingLauncher()
        let hooks = controller(launcher)
        try write("on notify true\n")
        hooks.reload()
        let library = WindowLibrary(directory: directory.appendingPathComponent("state"),
                                    controlEventRing: ControlEventRing(runID: UUID()))
        hooks.observe(library)
        let store = try #require(library.activeStore)
        let session = try #require(store.workspaces.first?.sessions.first)
        func record(_ title: String, focused: Bool, origin: NotificationOrigin) -> NotificationDelivery? {
            store.recordTerminalNotification(TerminalNotificationRecord(
                sessionID: session.id, windowID: UUID(), pane: .main, title: title, body: "b",
                firingIsFocused: focused, appActive: true), origin: origin)
        }

        #expect(record("typing", focused: true, origin: .terminal) == nil)
        let delivery = record("", focused: false, origin: .control)
        launcher.drain()

        #expect(delivery?.title == session.displayName)
        #expect(launcher.launched.map(\.payload.title) == [session.displayName])
        #expect(session.unseenCount == 1)
    }

    @Test func hooksCommandsRefuseATargetOrWindow() {
        #expect(LinuxControlDispatcher.hooksScopeRefusal(ControlRequest(cmd: .hooksReload)) == nil)
        let targeted = LinuxControlDispatcher.hooksScopeRefusal(ControlRequest(cmd: .hooksList, target: "abc"))
        #expect(targeted?.error == "hooks.list takes no target or --window")
        let windowed = LinuxControlDispatcher.hooksScopeRefusal(
            ControlRequest(cmd: .hooksReload, args: ControlArgs(window: "w")))
        #expect(windowed?.error == "hooks.reload takes no target or --window")
    }

    @Test func onlyADirtyReloadToasts() {
        #expect(hooksReloadToast(count: 0) == nil)
        #expect(hooksReloadToast(count: 1) == "hooks.conf: 1 issue — see Preferences ▸ Key Mapping")
        #expect(hooksReloadToast(count: 2) == "hooks.conf: 2 issues — see Preferences ▸ Key Mapping")
    }
}
