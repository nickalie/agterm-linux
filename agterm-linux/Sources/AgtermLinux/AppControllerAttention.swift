import CGtk
import Foundation
import agtermCore

/// The cross-window attention list behind the title-bar bell and the Ctrl-Shift-I palette.
@MainActor
extension AppController {
    /// No terminal zoom, dashboard or picker covers this window, so an attention pick can land in it.
    var acceptsAttentionSelection: Bool {
        terminalZoom.target == nil && !dashboard.isOpen && !pickController.modalPending
    }

    /// Every window's bell reads every open window's sessions, so one window's change refreshes them all.
    func updateAttentionButton(settings: AppSettings? = nil) {
        updateRecentSessionsButton()
        let settings = settings ?? linuxSettingsStore().load()
        var controllers = Array(gWindows.values)
        // a window still constructing is not registered yet
        if !controllers.contains(where: { $0 === self }) { controllers.append(self) }
        for controller in controllers { controller.updateOwnAttentionButton(settings: settings) }
    }

    private func updateOwnAttentionButton(settings: AppSettings) {
        guard let button = attentionButton else { return }
        let enabled = settings.attentionButtonEnabled ?? false
        gtk_widget_set_visible(W(button), enabled ? 1 : 0)
        let entries = library.attentionAcrossWindows
        gtk_widget_set_sensitive(W(button), entries.isEmpty ? 0 : 1)
        let hasBlocked = entries.contains { $0.session.agentIndicator.status == .blocked }
        gtk_button_set_icon_name(BUTTON(button), hasBlocked ? "dialog-warning-symbolic" : "emblem-important-symbolic")
        if !enabled || entries.isEmpty, sessionPickerPopover != nil, sessionPickerShowsAttention {
            dismissSessionPicker()
        }
    }

    /// The attention palette's rows, in the library's order so the empty query keeps it.
    func attentionPaletteRows() -> [LinuxPaletteItem] {
        library.attentionAcrossWindows.map { entry in
            let windowID = entry.window.id
            let sessionID = entry.session.id
            let row = LinuxPaletteRow(title: "\(entry.session.displayName)  —  \(library.attentionSubtitle(entry))",
                                      enabled: canSelectAttention(windowID: windowID, sessionID: sessionID))
            // deferred past the palette's close, so a raise of another window never competes with it
            return (row: row, run: { MainTimer.schedule(after: 0) { selectAttention(windowID: windowID, sessionID: sessionID) } })
        }
    }
}

/// Whether an attention row can be acted on now: its window open and uncovered, its session still there.
/// Asked when the row renders and again when it is picked, since a row outlives all three.
@MainActor func canSelectAttention(windowID: UUID, sessionID: UUID) -> Bool {
    guard let controller = gWindows[windowID] else { return false }
    return controller.acceptsAttentionSelection && controller.store.session(withID: sessionID) != nil
}

/// Selects an attention row's session and reveals the pane that set its status, raising its window first
/// when that is not the frontmost one.
@MainActor func selectAttention(windowID: UUID, sessionID: UUID) {
    guard canSelectAttention(windowID: windowID, sessionID: sessionID),
          let controller = gWindows[windowID] else { return }
    if gController !== controller {
        openWindow(windowID)
        controller.becameFrontmost()
    }
    // read before the select, which clears an auto-reset indicator
    let statusPane = controller.store.session(withID: sessionID)?.agentIndicator.statusPane
    controller.selectSession(sessionID)
    handleAutoFollow(sessionID, statusPane: statusPane)
}

/// A background window closing changes every other window's attention list.
@MainActor func refreshAttentionButtons() {
    gWindows.values.first?.updateAttentionButton()
}
