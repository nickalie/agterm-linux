import Foundation
import agtermCore

/// The app-wide flagged view layout (Settings ▸ General and `sidebar.flagged-layout`) and the workspace
/// fold commands whose rows it decides.
@MainActor
extension AppController {
    var sidebarRendersWorkspaceRows: Bool {
        store.rendersWorkspaceRows(flaggedLayout: GhosttyApp.shared.flaggedViewLayout)
    }

    /// The one write seam, shared by the Settings picker and the control command. An unchanged value
    /// writes nothing and rebuilds nothing.
    func setFlaggedViewLayout(_ layout: FlaggedViewLayout) {
        guard layout != GhosttyApp.shared.flaggedViewLayout else { return }
        persist(\.flaggedViewLayout, layout == .flat ? nil : layout.rawValue)
        GhosttyApp.shared.flaggedViewLayout = layout
        for controller in gWindows.values {
            controller.rebuildSidebar()
            // a layout switch moves the selected row, so reveal it again
            controller.syncSidebarSelection()
        }
    }

    /// `sidebar.flagged-layout`: app-wide, so it takes no window, and echoes the resulting layout.
    func setFlaggedViewLayout(_ mode: ControlFlaggedLayoutMode) -> ControlResponse {
        let want = LinuxSidebarPolicy.flaggedLayout(for: mode, current: GhosttyApp.shared.flaggedViewLayout)
        let changed = want != GhosttyApp.shared.flaggedViewLayout
        setFlaggedViewLayout(want)
        if changed {
            for controller in gWindows.values where controller.settingsDialog != nil {
                controller.rebuildSettings(page: .general)
            }
        }
        return ControlResponse(ok: true, result: ControlResult(text: want.rawValue))
    }

    /// Expand every workspace (show all sessions) — the palette + `sidebar.expand` control arm. A no-op
    /// under the flat flagged list, which has no workspace rows.
    func expandWorkspaces() {
        guard sidebarRendersWorkspaceRows else { return }
        store.setWorkspacesExpanded(Set(store.workspaces.map(\.id)))
        rebuildSidebar()
    }

    /// Collapse every workspace except the active one to a header — the palette + `sidebar.collapse` arm.
    func collapseOtherWorkspaces() {
        guard sidebarRendersWorkspaceRows else { return }
        let expanded = store.currentWorkspaceID.map { Set([$0]) } ?? []
        store.setWorkspacesExpanded(expanded)
        rebuildSidebar()
        syncSidebarSelection()
    }

    /// Fold or unfold the current workspace's own subtree — the per-row twin of Expand / Collapse Workspaces.
    func toggleCurrentWorkspaceCollapse() {
        guard sidebarRendersWorkspaceRows, let id = store.currentWorkspaceID else { return }
        store.setWorkspaceExpanded(id, expanded: store.isCurrentWorkspaceCollapsed)
        rebuildSidebar()
        syncSidebarSelection()
    }
}
