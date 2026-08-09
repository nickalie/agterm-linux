import CGtk
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux HUD panel anchoring")
@MainActor
struct LinuxHudAnchorTests {
    @Test("an edge band holds the margin on its own side and nothing on the other")
    func edgeBandsHoldOneMargin() {
        let leading = AppController.floatingOverlayAnchor(extent: 1000, sizePercent: 20, band: .leading)
        #expect(leading.leadingMargin == 100)
        #expect(leading.trailingMargin == 0)

        let trailing = AppController.floatingOverlayAnchor(extent: 1000, sizePercent: 20, band: .trailing)
        #expect(trailing.leadingMargin == 0)
        #expect(trailing.trailingMargin == 100)

        let middle = AppController.floatingOverlayAnchor(extent: 1000, sizePercent: 20, band: .middle)
        #expect(middle.leadingMargin == 0)
        #expect(middle.trailingMargin == 0)
    }

    @Test("a panel with no room for its margin centers on that axis instead of overhanging")
    func noRoomCollapsesToCenter() {
        // 80% is the size clamp, where two margins exactly fill the rest, so anything past it has no room.
        #expect(AppController.floatingOverlayAnchor(extent: 1000, sizePercent: 90, band: .leading).band
            == .middle)
        #expect(AppController.floatingOverlayAnchor(extent: 1000, sizePercent: 70, band: .leading).band
            == .leading)
    }

    @Test("each band maps to its own GTK alignment, so the two axes share one resolution")
    func bandsMapToAlignments() {
        let leading = AppController.floatingOverlayAnchor(extent: 1000, sizePercent: 20, band: .leading)
        let trailing = AppController.floatingOverlayAnchor(extent: 1000, sizePercent: 20, band: .trailing)
        let middle = AppController.floatingOverlayAnchor(extent: 1000, sizePercent: 20, band: .middle)

        #expect(leading.align(start: GTK_ALIGN_START, end: GTK_ALIGN_END) == GTK_ALIGN_START)
        #expect(trailing.align(start: GTK_ALIGN_START, end: GTK_ALIGN_END) == GTK_ALIGN_END)
        #expect(middle.align(start: GTK_ALIGN_START, end: GTK_ALIGN_END) == GTK_ALIGN_CENTER)
    }
}
