import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux HUD panel anchoring")
@MainActor
struct LinuxHudAnchorTests {
    @Test("an edge band holds the margin on its own side and nothing on the other")
    func edgeBandsHoldOneMargin() {
        let leading = AppController.floatingOverlayAnchor(extent: 1000, sizePercent: 20, band: .leading)
        #expect(leading.offset(extent: 1000, panel: 200) == 100)

        let trailing = AppController.floatingOverlayAnchor(extent: 1000, sizePercent: 20, band: .trailing)
        #expect(trailing.offset(extent: 1000, panel: 200) == 700)

        let middle = AppController.floatingOverlayAnchor(extent: 1000, sizePercent: 20, band: .middle)
        #expect(middle.offset(extent: 1000, panel: 200) == 400)
    }

    @Test("a panel with no room for its margin centers on that axis instead of overhanging")
    func noRoomCollapsesToCenter() {
        // 80% is the size clamp, where two margins exactly fill the rest, so anything past it has no room.
        #expect(AppController.floatingOverlayAnchor(extent: 1000, sizePercent: 90, band: .leading).band
            == .middle)
        #expect(AppController.floatingOverlayAnchor(extent: 1000, sizePercent: 70, band: .leading).band
            == .leading)
    }

    @Test("a panel wider than its anchor sits at the anchor's own edge rather than outside it")
    func oversizedPanelNeverOverhangs() {
        let trailing = AppController.floatingOverlayAnchor(extent: 100, sizePercent: 20, band: .trailing)
        #expect(trailing.offset(extent: 100, panel: 400) == 0)

        let middle = AppController.floatingOverlayAnchor(extent: 100, sizePercent: 20, band: .middle)
        #expect(middle.offset(extent: 100, panel: 400) == 0)
    }
}
