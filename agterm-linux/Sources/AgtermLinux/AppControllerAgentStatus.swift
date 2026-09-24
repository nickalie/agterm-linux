import Foundation
import agtermCore

/// The agent-status glyph's window-side arms: the keystroke transition, the explicit clear, and the
/// Settings ▸ Agent Status cache the keystroke path reads.
@MainActor
extension AppController {
    /// Move the pane's agent status along a keystroke: typing clears completed and answers blocked into
    /// active, Escape or bare Ctrl-C clears everything, all gated by Settings ▸ Agent Status ▸ Status reset.
    /// `AgentIndicator.afterKeystroke` owns the table.
    func applyKeystrokeToStatus(_ id: UUID, pane: StatusPane, keystroke: StatusKeystroke) {
        // a status mirrored from an origin pane this machine has no counterpart for is not this pane's to clear
        guard let session = store.session(withID: id),
              session.remotePresentation?.allowsKeystrokeStatusClear != false,
              let next = session.agentIndicator
                  .afterKeystroke(pane: pane, keystroke: keystroke, reset: statusResetMode)
        else { return }
        store.setAgentIndicator(next, forSession: id)
        rebuildSidebar()
    }

    /// Reset the active session's agent status to idle (the palette "Clear Status", GUI half of
    /// `session.status idle`).
    func clearActiveStatus() {
        guard let id = store.selectedSessionID else { return }
        store.setAgentIndicator(AgentIndicator(), forSession: id)
        rebuildSidebar()
    }

    /// Refresh the cached Status reset mode; the keystroke path reads it instead of the disk per press.
    func applyAgentStatusSettings() {
        statusResetMode = linuxSettingsStore().load().effectiveStatusReset
    }
}
