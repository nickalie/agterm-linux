import CGtk
import Foundation
import agtermCore

/// Covers a pane whose zmx client does not lead: what its terminal drew is laid out for another client's
/// grid. Every host of a pane's terminal mounts one directly over it — the deck's pane host, terminal zoom
/// and a dashboard cell — and each is shown only while its pane is covered. The deck's sits BELOW the pane's
/// own overlay, being added to the host before any overlay can be, and hides while one is up.
@MainActor
final class LinuxPaneLeadCover {
    enum Placement {
        /// The pane host moves with a swap, so the pane is looked up by host each sync.
        case deck(host: OpaquePointer)
        case zoom(OverlayPane)
        case dashboard(OverlayPane)
    }

    let widget: OpaquePointer
    private let title: OpaquePointer
    private let hint: OpaquePointer
    private let windowID: UUID
    private let sessionID: UUID
    private let placement: Placement

    private static var live: [OpaquePointer: LinuxPaneLeadCover] = [:]

    /// Builds a cover, registers it until its widget is destroyed, and settles its state.
    static func mount(on overlay: OpaquePointer?, windowID: UUID, sessionID: UUID, placement: Placement) {
        guard let overlay else { return }
        let cover = LinuxPaneLeadCover(windowID: windowID, sessionID: sessionID, placement: placement)
        live[cover.widget] = cover
        connect(cover.widget, "destroy", unsafeBitCast(onCoverDestroy as @convention(c) (OpaquePointer?, gpointer?) -> Void,
                                                        to: GCallback.self))
        gtk_overlay_add_overlay(overlay, W(cover.widget))
        cover.sync()
    }

    static func syncAll() { live.values.forEach { $0.sync() } }

    private init(windowID: UUID, sessionID: UUID, placement: Placement) {
        self.windowID = windowID
        self.sessionID = sessionID
        self.placement = placement
        widget = OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8))
        gtk_widget_add_css_class(W(widget), "agterm-lead-cover")
        gtk_widget_set_hexpand(W(widget), 1)
        gtk_widget_set_vexpand(W(widget), 1)
        let icon = OpaquePointer(gtk_image_new_from_icon_name("view-dual-symbolic"))
        gtk_image_set_pixel_size(icon, 32)
        title = OpaquePointer(gtk_label_new(nil))
        gtk_widget_add_css_class(W(title), "title-4")
        hint = OpaquePointer(gtk_label_new("Press any key to use it here"))
        gtk_widget_add_css_class(W(hint), "dim-label")
        let column = OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8))
        gtk_widget_set_valign(W(column), GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(W(column), 1)
        for child in [icon, title, hint] { gtk_box_append(cast(column), W(child)) }
        gtk_box_append(cast(widget), W(column))
        if case .dashboard = placement {
            gtk_widget_set_can_target(W(widget), 0)
        } else {
            // a click focuses the pane, whose next key press takes the lead
            let click = gtk_gesture_click_new()
            connect(click, "pressed", unsafeBitCast(onCoverPressed as @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?)
                -> Void, to: GCallback.self), RAW(widget))
            gtk_widget_add_controller(W(widget), click)
        }
    }

    /// What the cover says: the title for its state, and whether the key hint shows.
    static func caption(role: ZmxLeadRole?, reattaching: Bool, remote: Bool) -> (title: String, hint: Bool) {
        if reattaching { return ("Taking over…", false) }
        if role == .unowned { return ("Reconnecting…", true) }
        return (remote ? "In use on the machine it runs on" : "In use from another machine", true)
    }

    private var controller: AppController? { gWindows[windowID] }

    /// The pane this cover sits over now, nil once it has none.
    private var pane: OverlayPane? {
        switch placement {
        case .deck(let host):
            return controller?.paneHosts[sessionID]?.first(where: { $0.value == host })?.key
        case .zoom(let pane), .dashboard(let pane):
            return pane
        }
    }

    private func sync() {
        guard let session = controller?.store.session(withID: sessionID), let pane else {
            gtk_widget_set_visible(W(widget), 0)
            return
        }
        let book = ZmxLeadBook.shared
        let identity = session.paneIdentity(for: pane == .left ? StatusPane.left : .right)
        // a pane overlay above the deck's cover is another program's and stays visible on its own backing
        let hidden = if case .deck = placement { session.paneOverlay(pane) != nil } else { false }
        guard book.covered(pane: identity), !hidden else {
            gtk_widget_set_visible(W(widget), 0)
            return
        }
        let caption = Self.caption(role: book.role(pane: identity), reattaching: book.reattaching(pane: identity),
                                   remote: session.remoteHost != nil)
        gtk_label_set_text(title, caption.title)
        gtk_widget_set_visible(W(hint), caption.hint ? 1 : 0)
        gtk_widget_set_visible(W(widget), 1)
    }

    fileprivate func focusPane() {
        guard let controller, let pane else { return }
        (pane == .left ? controller.surfaces[sessionID] : controller.splitSurfaces[sessionID])?.grabFocus()
    }

    fileprivate static func forget(_ widget: OpaquePointer) { live[widget] = nil }
    fileprivate static func cover(for widget: OpaquePointer) -> LinuxPaneLeadCover? { live[widget] }
}

private let onCoverDestroy: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { widget, _ in
    MainActor.assumeIsolated { if let widget { LinuxPaneLeadCover.forget(widget) } }
}

private let onCoverPressed: @MainActor @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { _, _, _, _, data in
    MainActor.assumeIsolated { data.flatMap { LinuxPaneLeadCover.cover(for: OpaquePointer($0)) }?.focusPane() }
}
