import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux overlay exit")
@MainActor
struct LinuxOverlayExitTests {
    private func makeStore() -> (AppStore, Session) {
        let session = Session(initialCwd: "/tmp")
        return (AppStore(workspaces: [Workspace(name: "work", sessions: [session])]), session)
    }

    private func openHud(_ store: AppStore, _ session: Session, _ message: String) {
        let file = NSTemporaryDirectory() + "agterm-exit-test-\(UUID().uuidString)"
        #expect(store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: message), file: file,
                              size: HudPanelSize(widthPercent: 40, heightPercent: 20)))
    }

    @Test("a replaced HUD's late exit leaves the replacement in the slot", arguments: [false, true])
    func staleExitSparesReplacement(replacedByHud: Bool) {
        let (store, session) = makeStore()
        openHud(store, session, "first")
        let retired = session.overlaySlotGeneration
        if replacedByHud {
            openHud(store, session, "second")
        } else {
            #expect(store.openOverlay(session.id, command: "top"))
        }

        #expect(!AppController.settleOverlayExit(store, sessionID: session.id, generation: retired, code: 0))
        #expect(session.overlayActive)
        #expect(session.overlayExitCode == nil)
        #expect(replacedByHud ? session.hudSpec?.message == "second" : session.overlayCommand == "top")
    }

    @Test("the current occupant's exit records its code and closes the slot")
    func currentExitCloses() {
        let (store, session) = makeStore()
        #expect(store.openOverlay(session.id, command: "false"))

        #expect(AppController.settleOverlayExit(store, sessionID: session.id,
                                                generation: session.overlaySlotGeneration, code: 1))
        #expect(!session.overlayActive)
        #expect(session.overlayExitCode == 1)
    }

    private final class StubSurface: TerminalSurface {
        func teardown() {}
        func promoteToPrimaryPane() {}
        var isRealized: Bool { true }
        var paneToken: String { "" }
    }

    @Test("a pane overlay's exit settles the slot it occupies now, and a retired one settles nothing")
    func paneExitFollowsTheSurface() {
        let (store, session) = makeStore()
        session.isSplit = true
        let (left, right) = (StubSurface(), StubSurface())
        #expect(store.openPaneOverlay(session.id, pane: .left, command: "sleep 5; exit 7") == nil)
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "sleep 60") == nil)
        session.setPaneOverlaySurface(right, pane: .left)
        session.setPaneOverlaySurface(left, pane: .right)

        #expect(AppController.settlePaneOverlayExit(store, sessionID: session.id, surface: left, code: 7) == .right)
        #expect(session.paneOverlayExitCode(.right) == 7)
        #expect(session.paneOverlayExitCode(.left) == nil)

        #expect(AppController.settlePaneOverlayExit(store, sessionID: session.id, surface: StubSurface(), code: 1) == nil)
        #expect(session.paneOverlayExitCode(.left) == nil)
    }
}
