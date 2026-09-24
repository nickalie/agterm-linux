import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@MainActor
@Suite("Linux per-pane session background")
struct LinuxPaneBackgroundTests {
    private let driver = BackgroundWatermark(kind: .text, text: "DRIVER")
    private let peer = BackgroundWatermark(kind: .text, text: "PEER")
    private let tint = BackgroundWatermark(kind: .color, colorHex: "#201414")
    private let blue = BackgroundWatermark(kind: .color, colorHex: "#102030")

    private final class StubSurface: PaneRoleMutableSurface {
        var paneToken = ""
        var isRealized = true
        var roles: [SwappablePaneRole] = []
        func teardown() {}
        func promoteToPrimaryPane() {}
        func setPaneRole(_ role: SwappablePaneRole) { roles.append(role) }
    }

    private func options(_ args: ControlArgs) -> ControlSessionBackgroundOptions? {
        guard case .options(let options) = LinuxControlDispatcher.sessionBackgroundOptions(args) else { return nil }
        return options
    }

    private func rejection(_ args: ControlArgs) -> String? {
        guard case .rejected(let response) = LinuxControlDispatcher.sessionBackgroundOptions(args) else { return nil }
        return response.error
    }

    private func makeSplitSession() throws -> (store: AppStore, session: Session) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-linux-tests-\(UUID().uuidString)")
        let store = AppStore(persistence: PersistenceStore(directory: dir))
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        session.surface = StubSurface()
        store.toggleSplit(session.id)
        session.splitSurface = StubSurface()
        return (store, session)
    }

    @Test("--pane selects the override and its aliases resolve")
    func paneParses() {
        #expect(options(ControlArgs(mode: "color", pane: "right", color: "#102030"))?.pane == .right)
        #expect(options(ControlArgs(mode: "clear", pane: "scratch"))?.pane == .scratch)
        #expect(options(ControlArgs(mode: "clear", pane: "primary"))?.pane == .left)
        let bare = options(ControlArgs(mode: "color", color: "#102030"))
        #expect(bare?.pane == nil)
        #expect(bare?.watermark == BackgroundWatermark(kind: .color, colorHex: "#102030"))
    }

    @Test("rejections keep upstream's strings and order")
    func rejections() {
        #expect(rejection(ControlArgs(mode: "clear", pane: "middle")) == "--pane must be left, right, or scratch")
        #expect(rejection(ControlArgs(mode: "color", pane: "middle")) == "session.background color requires a color")
        #expect(rejection(ControlArgs(mode: "tint", pane: "left")) == "invalid background mode: tint (image|text|color|clear)")
        #expect(rejection(ControlArgs(mode: "text", pane: "left")) == "session.background text requires text")
    }

    @Test("an override needs the pane it names")
    func missingPane() throws {
        let session = Session(initialCwd: "/tmp")
        #expect(session.missingBackgroundPaneError(.right) == "session has no split pane")
        #expect(session.missingBackgroundPaneError(.scratch) == "session has no scratch terminal")
        #expect(session.missingBackgroundPaneError(.left) == nil)
        #expect(session.missingBackgroundPaneError(nil) == nil)
        let split = try makeSplitSession().session
        #expect(split.missingBackgroundPaneError(.right) == nil)
        split.scratchSurface = StubSurface()
        #expect(split.missingBackgroundPaneError(.scratch) == nil)
    }

    @Test("a pane set applies to that pane, a default change to inheriting panes only")
    func applySelection() {
        let session = Session(initialCwd: "/tmp")
        #expect(session.backgroundPanesToApply(nil) == [.left, .right, .scratch])
        session.paneBackgrounds.right = peer
        #expect(session.backgroundPanesToApply(nil) == [.left, .scratch])
        #expect(session.backgroundPanesToApply(.right) == [.right])
    }

    @Test("each surface role renders its pane's effective background")
    func surfaceRendering() {
        let session = Session(initialCwd: "/tmp")
        session.backgroundWatermark = tint
        session.paneBackgrounds.right = peer
        #expect(session.linuxBackground(for: LinuxSurfaceRole.main.statusPane) == tint)
        #expect(session.linuxBackground(for: LinuxSurfaceRole.split.statusPane) == peer)
        #expect(session.linuxBackground(for: LinuxSurfaceRole.scratch.statusPane) == tint)
        #expect(session.linuxBackground(for: LinuxSurfaceRole.overlay.statusPane) == tint)
        session.paneBackgrounds.right = nil
        #expect(session.linuxBackground(for: .right) == tint)
    }

    @Test("a text override renders to its own pane-keyed file, the default to the session's")
    func renderedFileNaming() throws {
        let session = try makeSplitSession().session
        let state = URL(fileURLWithPath: "/state")
        #expect(session.backgroundPaneKey(for: .right) == nil)
        session.paneBackgrounds = PaneBackgrounds(left: driver, right: peer, scratch: driver)
        let right = try #require(session.backgroundPaneKey(for: .right))
        #expect(right == session.splitPaneIdentity?.uuidString)
        #expect(session.backgroundPaneKey(for: .left) == session.paneIdentity.uuidString)
        #expect(session.backgroundPaneKey(for: .scratch) == "scratch")
        #expect(session.backgroundPaneKey(for: nil) == nil)
        #expect(WatermarkStorage.renderedTextURL(sessionID: session.id, paneKey: "scratch", stateDir: state).lastPathComponent
                    == "\(session.id.uuidString)-scratch.png")
        #expect(WatermarkStorage.renderedTextURL(sessionID: session.id, paneKey: nil, stateDir: state).lastPathComponent
                    == "\(session.id.uuidString).png")
    }

    @Test("overrides follow the terminal through swap, promotion and close")
    func overridesFollowTheTerminal() throws {
        let (store, session) = try makeSplitSession()
        session.paneBackgrounds = PaneBackgrounds(left: tint, right: blue)
        let rightKey = session.backgroundPaneKey(for: .right)
        #expect(store.swapPanes(session.id) == nil)
        #expect(session.paneBackgrounds == PaneBackgrounds(left: blue, right: tint))
        #expect(session.backgroundPaneKey(for: .left) == rightKey)
        store.closePrimaryPane(session.id)
        #expect(session.paneBackgrounds == PaneBackgrounds(left: tint))
        store.toggleSplit(session.id)
        session.splitSurface = StubSurface()
        session.paneBackgrounds.right = blue
        store.closeSplit(session.id)
        #expect(session.paneBackgrounds == PaneBackgrounds(left: tint))
    }

    @Test("tree lists overrides only, omitted when none")
    func treeReadBack() throws {
        let (store, session) = try makeSplitSession()
        func node() throws -> ControlSessionNode {
            try #require(store.controlTree(paneForeground: { _ in nil }).workspaces.first?.sessions.first)
        }
        #expect(try node().paneBackgrounds == nil)
        #expect(store.setBackgroundWatermark(tint, forSession: session.id))
        #expect(store.setBackgroundWatermark(blue, forSession: session.id, pane: .right))
        #expect(try node().background == tint)
        #expect(try node().paneBackgrounds == PaneBackgrounds(right: blue))
        #expect(store.setBackgroundWatermark(nil, forSession: session.id, pane: .right))
        #expect(try node().paneBackgrounds == nil)
    }
}
