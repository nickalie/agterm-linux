import Foundation
import agtermCore

/// The GUI half of the pane commands — split arrangement and teardown, the scratch cover, and pane focus.
/// Their control twins live in `ControlActions+AppController.swift`; these carry the cover rungs a chord or
/// a palette row owes and a socket command deliberately does not.
@MainActor
extension AppController {
    /// A session-wide cover hides the panes, so rearranging them behind it would only show up once the cover
    /// goes — the layout the user left is silently different. A shown scratch is DISMISSED instead, matching
    /// Ctrl+W's cover-first rule, so either one is the way back to the panes as they were; hiding is
    /// keep-alive, so the scratch shell survives. A full program overlay runs a caller's program that must
    /// not be closed under it, so the press is inert. Control's `session.split` still drives the deck behind
    /// either cover.
    func toggleSplit() {
        toggleSplit(axis: .leftRight)
    }

    /// Toggle the active session's top/bottom split, or transpose a shown left/right one in place.
    func toggleHorizontalSplit() {
        toggleSplit(axis: .topBottom)
    }

    /// Preserve the current arrangement. The titlebar's stateful split button uses this rather than either
    /// orientation-specific action, so pressing it never transposes a split it only meant to hide.
    func toggleCurrentSplit() {
        toggleSplit(axis: nil)
    }

    private func toggleSplit(axis: SplitAxis?) {
        guard let id = store.selectedSessionID, let session = store.session(withID: id) else { return }
        guard !session.fullOverlayActive else { return }
        if session.scratchActive {
            store.toggleScratch(id)
            reconcile()
            updateToggleIcons()
            return
        }
        store.toggleSplit(id, axis: axis)
        reconcile()
        updateToggleIcons()
        focusedSurface(for: id)?.grabFocus()
    }

    /// The palette's Close Split, GUI twin of `session.split.close`. Gated on `hasSplit`, so the hidden pane
    /// a plain toggle leaves behind is still reachable. Immediate and unconfirmed like the other pane
    /// teardowns, and it carries `toggleSplit`'s cover rungs, which matter more here: behind a cover this
    /// destroys a live shell, so the dismissed scratch makes it a second, deliberate press with panes in view.
    func closeSplit() {
        guard let id = store.selectedSessionID, let session = store.session(withID: id) else { return }
        guard session.hasSplit, !session.fullOverlayActive else { return }
        if session.scratchActive {
            store.toggleScratch(id)
            reconcile()
            updateToggleIcons()
            return
        }
        store.closeSplit(id)
        reconcile()
        updateToggleIcons()
        surfaces[id]?.grabFocus()
    }

    func closeSplitPane(_ id: UUID, alreadyFinalized: UUID? = nil) {
        store.closeSplitPane(id, alreadyFinalized: alreadyFinalized)
        reconcile()
        surfaces[id]?.grabFocus()
    }

    func toggleScratch() {
        guard let id = store.selectedSessionID else { return }
        store.toggleScratch(id)
        reconcile()
        updateToggleIcons()
    }

    /// Move keyboard focus between the two split panes of the active session.
    func focusPane(left: Bool) {
        guard let id = store.selectedSessionID, store.session(withID: id)?.hasSplit == true else { return }
        (left ? surfaces[id] : splitSurfaces[id])?.grabFocus()
    }
}
