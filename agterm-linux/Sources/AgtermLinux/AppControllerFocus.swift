import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    /// Whether the deck may hand the keyboard to the active session: upstream's `focusActiveSession` bail list.
    /// The quick terminal and the search entry are widgets in this toplevel, so each counts only while it
    /// holds the window's focus.
    var deckMayTakeFocus: Bool {
        terminalZoom.target == nil && !dashboard.isOpen && renaming == nil
            && paletteWindow == nil && themeWindow == nil && !pickController.modalPending
            && !(quickVisible && quickSurface?.ownsWindowFocus == true)
            && !(searchBar.map(holdsWindowFocus) ?? false)
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
