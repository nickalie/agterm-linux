import CGtk
import Foundation

/// What a HUD panel needs from its surface: the cell it is measured with, and the link click the deck claims
/// for it while the panel itself takes no input.
@MainActor
extension GhosttySurface {
    /// This surface's real cell in points, nil when the surface is not created or reports no grid; derived
    /// as `readCursorColumn` derives it.
    func cellSize() -> (width: Double, height: Double)? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        guard h > 0, h.isFinite else { return nil }
        return (width: h * Double(size.cell_width_px) / Double(size.cell_height_px), height: h)
    }

    /// A click the deck claimed for this passive panel, pressed and released at `(x, y)`: libghostty opens a
    /// link under it. The position is withdrawn afterwards, as the pointer never really entered.
    func forwardPassiveClick(x: Double, y: Double, mods: ghostty_input_mods_e) {
        guard let surface else { return }
        let point = GhosttySurfaceGeometry.pointerPosition(gtkX: x, gtkY: y)
        ghostty_surface_mouse_pos(surface, point.x, point.y, mods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        ghostty_surface_mouse_pos(surface, -1, -1, GHOSTTY_MODS_NONE)
    }
}
