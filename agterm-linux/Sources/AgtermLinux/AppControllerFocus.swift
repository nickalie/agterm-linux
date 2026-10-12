import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    /// Whether the deck may hand the keyboard to the active session. The first line is upstream's
    /// `focusActiveSession` bail list, the quick terminal counting only while it holds the window's focus as
    /// upstream's `holdsKey` does; the last is its surfaces' own "never steal from an `NSText`" guard.
    var deckMayTakeFocus: Bool {
        terminalZoom.target == nil && !dashboard.isOpen && renaming == nil
            && paletteWindow == nil && themeWindow == nil && !pickController.modalPending
            && !(quickVisible && quickSurface?.ownsWindowFocus == true)
            && !editableHoldsWindowFocus
    }

    /// Whether a visible text field (the rename or search entry) holds the window's focus. GTK leaves a hidden
    /// widget as the focus widget, and a hidden field holds no keyboard.
    var editableHoldsWindowFocus: Bool {
        guard let root = gtk_widget_get_root(W(window)), let focus = gtk_root_get_focus(root) else { return false }
        return gtk_widget_is_visible(focus) != 0 && gtk_widget_get_ancestor(focus, gtk_editable_get_type()) != nil
    }

    /// Upstream's `focusSplitPane`, or with no pane its `focusActiveSession`: the gated handover of the keyboard
    /// to the selected session's dialog, page or topmost terminal.
    func focusSession(_ session: Session, wantSplit: Bool? = nil) {
        guard deckMayTakeFocus, session.id == store.selectedSessionID, !focusSessionAsk(session.id),
              !LinuxHtmlOverlays.shared.focusCover(of: session) else { return }
        let target = wantSplit.map(session.focusTarget(wantSplit:)) ?? session.topmostSurface
        (target as? GhosttySurface)?.grabFocus()
    }

    func focusActiveSession() {
        if let active = store.activeSession { focusSession(active) }
    }

    /// Upstream's `setSplitFocus`: the pane focus moves whether or not the gate lets the keyboard follow.
    func setSplitFocus(_ toSplit: Bool, of session: Session) {
        store.setPaneFocus(toSplit, forSession: session.id)
        syncSplit(session)
        updatePaneDim(session)
        if !sidebarInteractionInProgress { rebuildSidebar() }
        updateTitle()
        focusSession(session, wantSplit: toSplit)
    }

    /// Whether the session's overlay, or `pane`'s, holds the window's keyboard: only then does closing it hand
    /// the keyboard to the pane, never taking it from the sidebar.
    func overlayOwnsWindowFocus(_ id: UUID, pane: OverlayPane?) -> Bool {
        guard let session = store.session(withID: id) else { return false }
        let surface = pane.map { paneOverlaySurfaces[id]?[$0] } ?? overlaySurfaces[id]
        let page = pane.map { session.paneOverlay($0)?.html } ?? session.htmlOverlay
        return surface?.ownsWindowFocus == true
            || page.flatMap { LinuxHtmlOverlays.shared.existing($0.id) }?.ownsWindowFocus == true
    }
}

/// Whether the window's focus widget is `widget` or inside it. Unlike `gtk_widget_has_focus`, it holds while
/// the window is inactive.
@MainActor func holdsWindowFocus(_ widget: OpaquePointer) -> Bool {
    guard let root = gtk_widget_get_root(W(widget)), let focus = gtk_root_get_focus(root) else { return false }
    return focus == W(widget) || gtk_widget_is_ancestor(focus, W(widget)) != 0
}

extension GhosttySurface {
    var ownsWindowFocus: Bool { holdsWindowFocus(glArea) }
}
