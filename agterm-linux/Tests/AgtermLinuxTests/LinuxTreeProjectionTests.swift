import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

/// `projectingLinuxAutoFollow` rebuilds its argument field by field, and every `ControlTree` and
/// `ControlWindowNode` field defaults to nil, so an omitted one is erased from the read-back with no
/// diagnostic. Each case rebuilds with the SAME auto-follow timeout and requires an identical encoding, so
/// a field added upstream fails here rather than silently disappearing from `tree` and `window list`.
@Suite("Linux tree projection")
struct LinuxTreeProjectionTests {
    private func canonical(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test("the tree carries every field it was given")
    func treeCarriesEveryField() throws {
        let tree = ControlTree(
            workspaces: [], idleMs: 10, autoFollowMs: 1,
            sidebarVisible: true, sidebarMode: "tree", sidebarFlaggedLayout: "tree", sidebarWidth: 240,
            workspaceFilter: true, quickVisible: false, zoomedSurface: "s:left", dashboardMembers: ["a"],
            dashboardHighlighted: "a", dashboardFontSize: 13, dashboardFontMode: "auto",
            pickPending: "pick-id", askPending: "ask-id",
            app: AppIdentity(version: "0.27.1", commit: "abcdef"),
            liveReset: ControlLiveResetReadback(pending: 1, last: nil))
        let projected = ControlTree(
            workspaces: tree.workspaces, idleMs: tree.idleMs, autoFollowMs: tree.autoFollowMs,
            sidebarVisible: tree.sidebarVisible, sidebarMode: tree.sidebarMode,
            sidebarFlaggedLayout: tree.sidebarFlaggedLayout,
            sidebarWidth: tree.sidebarWidth, workspaceFilter: tree.workspaceFilter,
            quickVisible: tree.quickVisible, zoomedSurface: tree.zoomedSurface,
            dashboardMembers: tree.dashboardMembers, dashboardHighlighted: tree.dashboardHighlighted,
            dashboardFontSize: tree.dashboardFontSize, dashboardFontMode: tree.dashboardFontMode,
            pickPending: tree.pickPending, askPending: tree.askPending, app: tree.app,
            liveReset: tree.liveReset)
        #expect(try canonical(projected) == canonical(tree))
    }

    @Test("the window node carries every field it was given")
    func windowNodeCarriesEveryField() throws {
        let node = ControlWindowNode(
            id: "w", name: "main", open: true, active: true, autoFollowMs: 1, sidebarVisible: true,
            geometry: ControlWindowFrame(x: 0, y: 0, width: 100, height: 80, display: 0),
            fullscreen: false, zoomed: true, minimized: false)
        let projected = ControlWindowNode(
            id: node.id, name: node.name, open: node.open, active: node.active,
            autoFollowMs: node.autoFollowMs, sidebarVisible: node.sidebarVisible,
            geometry: node.geometry, fullscreen: node.fullscreen, zoomed: node.zoomed,
            minimized: node.minimized)
        #expect(try canonical(projected) == canonical(node))
    }
}
