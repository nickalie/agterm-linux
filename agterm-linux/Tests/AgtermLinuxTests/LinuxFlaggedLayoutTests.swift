import Testing
import agtermCore
@testable import AgtermLinux

@MainActor
@Suite("Linux flagged view layout")
struct LinuxFlaggedLayoutTests {
    @MainActor
    private struct Fixture {
        let flaggedAlpha = Session(initialCwd: "/a1")
        let plainAlpha = Session(initialCwd: "/a2")
        let flaggedGamma = Session(initialCwd: "/g1")
        let alpha: Workspace
        let beta = Workspace(name: "beta", sessions: [Session(initialCwd: "/b1")])
        let gamma: Workspace
        let store: AppStore

        init() {
            flaggedAlpha.flagged = true
            flaggedGamma.flagged = true
            alpha = Workspace(name: "alpha", sessions: [flaggedAlpha, plainAlpha])
            gamma = Workspace(name: "gamma", sessions: [flaggedGamma])
            store = AppStore(workspaces: [alpha, beta, gamma])
        }
    }

    private func fixture() -> Fixture { Fixture() }

    @Test("the flagged tree nests flagged rows under their workspaces and omits a workspace with none")
    func flaggedTreeProjection() throws {
        let fx = fixture()
        fx.store.setSidebarMode(.flagged)
        let rows = try #require(LinuxSidebarPolicy.workspaceProjection(fx.store, flaggedLayout: .tree))
        #expect(rows.map(\.workspace.id) == [fx.alpha.id, fx.gamma.id])
        #expect(rows.map { $0.sessions.map(\.id) } == [[fx.flaggedAlpha.id], [fx.flaggedGamma.id]])
        #expect(!LinuxSidebarPolicy.labelsSessionsWithWorkspace(fx.store, flaggedLayout: .tree))
    }

    @Test("the flagged tree ignores the focus filter, which restricts the ordinary tree only")
    func flaggedTreeIgnoresFocus() throws {
        let fx = fixture()
        fx.store.applyFocusMode(.on, to: fx.alpha.id)
        #expect(LinuxSidebarPolicy.workspaceProjection(fx.store, flaggedLayout: .tree)?.map(\.workspace.id)
            == [fx.alpha.id])
        fx.store.setSidebarMode(.flagged)
        let rows = try #require(LinuxSidebarPolicy.workspaceProjection(fx.store, flaggedLayout: .tree))
        #expect(rows.map(\.workspace.id) == [fx.alpha.id, fx.gamma.id])
    }

    @Test("the flat flagged list has no workspace rows and names each row's workspace")
    func flatFlaggedList() {
        let fx = fixture()
        fx.store.setSidebarMode(.flagged)
        #expect(LinuxSidebarPolicy.workspaceProjection(fx.store, flaggedLayout: .flat) == nil)
        #expect(LinuxSidebarPolicy.labelsSessionsWithWorkspace(fx.store, flaggedLayout: .flat))
    }

    @Test("the ordinary tree renders every session whatever the flagged layout")
    func ordinaryTreeIgnoresLayout() throws {
        let fx = fixture()
        for layout in FlaggedViewLayout.allCases {
            let rows = try #require(LinuxSidebarPolicy.workspaceProjection(fx.store, flaggedLayout: layout))
            #expect(rows.map(\.workspace.id) == [fx.alpha.id, fx.beta.id, fx.gamma.id])
            #expect(rows[0].sessions.map(\.id) == [fx.flaggedAlpha.id, fx.plainAlpha.id])
            #expect(!LinuxSidebarPolicy.labelsSessionsWithWorkspace(fx.store, flaggedLayout: layout))
        }
    }

    @Test("toggle resolves from the current layout and explicit layouts are absolute")
    func controlModes() {
        #expect(LinuxSidebarPolicy.flaggedLayout(for: .toggle, current: .flat) == .tree)
        #expect(LinuxSidebarPolicy.flaggedLayout(for: .toggle, current: .tree) == .flat)
        for current in FlaggedViewLayout.allCases {
            #expect(LinuxSidebarPolicy.flaggedLayout(for: .flat, current: current) == .flat)
            #expect(LinuxSidebarPolicy.flaggedLayout(for: .tree, current: current) == .tree)
        }
    }

    @Test("the tree reports the flagged layout, the one the sidebars render from")
    func treeReadBack() {
        let fx = fixture()
        let tree = fx.store.controlTree(paneForeground: { _ in nil }, flaggedLayout: .tree)
        #expect(tree.sidebarFlaggedLayout == "tree")
        #expect(tree.sidebarMode == "tree")
    }
}
