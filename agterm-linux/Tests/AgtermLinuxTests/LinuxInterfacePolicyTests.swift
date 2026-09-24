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

    @Test("the workspace name starts hidden and leads the identity once shown")
    @MainActor
    func workspaceNameToggle() {
        let session = Session(initialCwd: "/work", customName: "build")
        let store = AppStore(workspaces: [Workspace(name: "backend", sessions: [session])])
        _ = store.selectSession(session.id)
        let window = WindowInfo(name: "main")
        let settings = AppSettings()
        #expect(settings.isInterfaceElementHidden(.workspaceName))
        let hidden = TitlebarComposition.compose(
            LinuxInterfacePolicy.titlebarParts(store: store, hidden: settings.resolvedHiddenInterfaceElements,
                                               window: window), mode: .compact)
        #expect(hidden.title == "build — main")

        let shown = LinuxInterfacePolicy.settingElement(.workspaceName, visible: true, in: settings)
        #expect(shown.shownInterfaceElements == ["workspaceName"])
        #expect(shown.hiddenInterfaceElements == nil)
        let composed = TitlebarComposition.compose(
            LinuxInterfacePolicy.titlebarParts(store: store, hidden: shown.resolvedHiddenInterfaceElements,
                                               window: window), mode: .compact)
        #expect(composed.title == "backend — build — main")
        #expect(LinuxInterfacePolicy.settingElement(.workspaceName, visible: false, in: shown)
            .shownInterfaceElements == nil)
    }

    @Test("the title names the selected session's workspace, not an empty one made current")
    @MainActor
    func workspaceFollowsActiveSession() {
        let session = Session(initialCwd: "/work")
        let store = AppStore(workspaces: [Workspace(name: "home", sessions: [session])])
        _ = store.selectSession(session.id)
        let empty = store.addWorkspace(name: "empty")
        _ = store.selectWorkspace(empty.id)
        #expect(store.currentWorkspaceID == empty.id)
        let parts = LinuxInterfacePolicy.titlebarParts(store: store, hidden: [], window: nil)
        #expect(parts.workspaceName == "home")
    }

    @Test("a default-shown element still toggles through the hidden list")
    func defaultShownElementToggle() {
        let hidden = LinuxInterfacePolicy.settingElement(.sessionName, visible: false, in: AppSettings())
        #expect(hidden.hiddenInterfaceElements == ["sessionName"])
        #expect(hidden.shownInterfaceElements == nil)
        #expect(LinuxInterfacePolicy.settingElement(.sessionName, visible: true, in: hidden)
            .hiddenInterfaceElements == nil)
    }
}
