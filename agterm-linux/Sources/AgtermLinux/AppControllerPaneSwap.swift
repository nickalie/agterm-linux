import CGtk
import Foundation
import agtermCore

/// `session.swap` on GTK: `AppStore.swapPanes` exchanges the model's two panes, and this moves the widget
/// layer to match. The pane HOSTS trade paned slots, never the `GtkGLArea`s they wrap, the same operation
/// `closePrimaryPane` already uses to promote a survivor — unparenting a realized `GtkGLArea` would
/// invalidate the GL context libghostty built its surface against and leave the terminal blank.
@MainActor
extension AppController {
    /// Exchange the active session's two panes, the palette and menu twin of the control command.
    func swapActivePanes() {
        guard let session = store.activeSession else { return }
        _ = swapPanes(session.id)
    }

    /// Returns the refusal, or nil once both the model and the widgets have swapped.
    func swapPanes(_ id: UUID) -> SwapRefusal? {
        guard let paned = sessionPanes[id] else { return .slotNotRealized }
        if let refusal = store.swapPanes(id) { return refusal }
        guard let session = store.session(withID: id) else { return .noSession }

        swap(&surfaces[id], &splitSurfaces[id])
        let hosts = paneHosts[id] ?? [:]
        paneHosts[id] = [.left: hosts[.right], .right: hosts[.left]].compactMapValues { $0 }
        let overlays = paneOverlaySurfaces[id] ?? [:]
        paneOverlaySurfaces[id] = [.left: overlays[.right], .right: overlays[.left]].compactMapValues { $0 }

        // detach both before reattaching: a widget still parented to the slot it is moving out of cannot
        // be set as the other slot's child
        gtk_paned_set_start_child(paned, nil)
        gtk_paned_set_end_child(paned, nil)
        if let primaryHost = paneHosts[id]?[.left] { gtk_paned_set_start_child(paned, W(primaryHost)) }
        if let splitHost = paneHosts[id]?[.right] { gtk_paned_set_end_child(paned, W(splitHost)) }

        surfaces[id]?.onExit = { [weak self] in self?.closePrimaryPane(id) }
        splitSurfaces[id]?.onExit = { [weak self] in self?.closeSplitPane(id) }
        surfaces[id]?.queueRender()
        splitSurfaces[id]?.queueRender()

        clearInvalidTerminalZoom()
        reconcile()
        (session.splitFocused ? splitSurfaces[id] : surfaces[id])?.grabFocus()
        return nil
    }
}
