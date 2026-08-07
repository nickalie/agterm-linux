import Testing
import agtermCore
@testable import AgtermLinux

struct LinuxInterfacePolicyTests {
    @Test("the default size reproduces what the panels rendered before the setting existed")
    func defaultSize() {
        let css = LinuxInterfacePolicy.interfaceCSS(fontSize: nil)
        #expect(css.contains(".agterm-interface label { font-size: 13.0pt; }"))
        #expect(css.contains(".agterm-interface .dim-label { font-size: 12.0pt; }"))
        #expect(css.contains(".agterm-interface .agterm-palette-badge { font-size: 10.0pt; }"))
        let panel = LinuxInterfacePolicy.panelSize(fontSize: nil, width: 480, height: 360)
        #expect(panel == (width: 480, height: 360))
    }

    @Test("the switcher takes the same size as the palette, so the two cannot drift")
    func switcherMatchesPalette() {
        let css = LinuxInterfacePolicy.interfaceCSS(fontSize: 18)
        #expect(css.contains(".agterm-interface label { font-size: 18.0pt; }"))
        #expect(css.contains(".agterm-switcher label { font-size: 18.0pt; }"))
    }

    @Test("panels scale with the text, so a larger font shows the same number of rows")
    func panelScales() {
        let panel = LinuxInterfacePolicy.panelSize(fontSize: 26, width: 480, height: 360)
        // 26 clamps to the 20pt maximum, so the scale is 20/13
        #expect(panel.width == 738)
        #expect(panel.height == 554)
    }

    @Test("derived text stops shrinking at the readable floor")
    func derivedFloor() {
        let css = LinuxInterfacePolicy.interfaceCSS(fontSize: 9)
        #expect(css.contains(".agterm-interface .agterm-palette-badge { font-size: 8.0pt; }"))
    }
}
