import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux pane placement")
@MainActor
struct LinuxPanePlacementTests {
    private func session(split: Bool) -> Session {
        let session = Session(initialCwd: "/tmp", splitPaneIdentity: split ? UUID() : nil)
        session.isSplit = split
        return session
    }

    private func resolve(_ pane: OverlayPane?, paneID: String? = nil, in session: Session,
                         requireVisible: Bool = true) -> LinuxPanePlacement.Resolution {
        LinuxPanePlacement.resolve(pane, paneID: paneID, in: session, requireVisible: requireVisible,
                                   invalidPaneError: "pane must be left or right")
    }

    @Test("no selector places against the whole session, carrying no identity to follow")
    func absentSelectorIsSessionWide() {
        guard case let .resolved(identity, pane) = resolve(nil, in: session(split: true)) else {
            Issue.record("session-wide placement was rejected"); return
        }
        #expect(identity == nil)
        #expect(pane == nil)
    }

    @Test("a resolved pane carries the identity that follows its shell through a swap")
    func resolvedPaneCarriesItsIdentity() {
        let session = session(split: true)
        guard case let .resolved(identity, pane) = resolve(.right, in: session) else {
            Issue.record("the split pane was rejected"); return
        }
        #expect(identity == session.splitPaneIdentity)
        #expect(pane == .right)
    }

    @Test("the split pane of an unsplit session is not visible, so an anchored open is refused")
    func splitPaneOfUnsplitSessionIsRefused() {
        guard case .rejected = resolve(.right, in: session(split: false)) else {
            Issue.record("an absent split pane resolved"); return
        }
    }

    /// `session.hud.update` re-places a live panel, which a hidden split must still be able to do.
    @Test("without the visibility requirement a hidden split resolves and a missing one still does not")
    func hiddenSplitResolvesWithoutTheVisibilityRequirement() {
        let hidden = session(split: false)
        hidden.splitPaneIdentity = UUID()
        guard case let .resolved(identity, _) = resolve(.right, in: hidden, requireVisible: false) else {
            Issue.record("a hidden split was rejected"); return
        }
        #expect(identity == hidden.splitPaneIdentity)

        let none = session(split: false)
        none.splitPaneIdentity = nil
        guard case .rejected = resolve(.right, in: none, requireVisible: false) else {
            Issue.record("a session with no split resolved"); return
        }
    }

    @Test("an unresolvable pane token errors rather than silently falling back to session-wide")
    func unknownPaneTokenIsRefused() {
        guard case .rejected = resolve(nil, paneID: "no-such-token", in: session(split: true)) else {
            Issue.record("an unknown pane token resolved"); return
        }
    }
}
