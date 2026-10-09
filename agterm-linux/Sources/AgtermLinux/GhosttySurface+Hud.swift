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

}
