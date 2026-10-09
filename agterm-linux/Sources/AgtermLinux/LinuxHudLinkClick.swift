import CGtk
import Foundation
import agtermCore

/// A HUD panel takes no input, so a Ctrl-click on a link in it would reach the pane behind. The deck claims
/// that click in the capture phase and hands it to the panel's own surface, whose libghostty resolves the
/// link and reports OPEN_URL, as upstream's `HudLinkClick` does. It grabs no focus. The pointer stays the
/// pane's over a link: GTK takes the cursor from the widget under it, and an untargetable panel is never that.
@MainActor
extension AppController {
    func installHudLinkClick() {
        guard let overlay = deckOverlay else { return }
        let click = gtk_gesture_click_new()
        gtk_gesture_single_set_button(click, 1)
        gtk_event_controller_set_propagation_phase(click, GTK_PHASE_CAPTURE)
        connect(click, "pressed", unsafeBitCast(onHudLinkPressed, to: GCallback.self))
        gtk_widget_add_controller(W(overlay), click)
    }

    /// The selected session's live HUD surface and `(x, y)` in its own coordinates, when the deck point lies
    /// inside the panel. A pending ask is drawn over the panel and keeps its own clicks.
    func hudLinkTarget(x: Double, y: Double) -> (surface: GhosttySurface, x: Double, y: Double)? {
        guard let overlay = deckOverlay, let id = store.selectedSessionID, let session = store.session(withID: id),
              session.hudActive, session.askPending == nil, floatingOverlayFrames[id] != nil,
              let surface = overlaySurfaces[id], gtk_widget_get_mapped(W(surface.glArea)) != 0 else { return nil }
        var from = graphene_point_t(x: Float(x), y: Float(y))
        var to = graphene_point_t()
        guard gtk_widget_compute_point(W(overlay), W(surface.glArea), &from, &to) != 0 else { return nil }
        let width = Double(gtk_widget_get_width(W(surface.glArea)))
        let height = Double(gtk_widget_get_height(W(surface.glArea)))
        let point = (x: Double(to.x), y: Double(to.y))
        guard point.x >= 0, point.y >= 0, point.x < width, point.y < height else { return nil }
        return (surface, point.x, point.y)
    }
}

private typealias HudLinkPressed = @MainActor @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void

private let onHudLinkPressed: HudLinkPressed = { gesture, _, x, y, _ in
    guard let gesture else { return }
    MainActor.assumeIsolated {
        let state = gtk_event_controller_get_current_event_state(gesture).rawValue
        guard state & GDK_CONTROL_MASK.rawValue != 0, let controller = controllerForEventController(gesture),
              let target = controller.hudLinkTarget(x: x, y: y) else { return }
        gtk_gesture_set_state(gesture, GTK_EVENT_SEQUENCE_CLAIMED)
        target.surface.forwardPassiveClick(x: target.x, y: target.y, mods: ghosttyMods(state))
    }
}
