import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux session adapter")
@MainActor
struct LinuxSessionAdapterTests {
    private func store(cwd: String, splitCwd: String? = nil) -> (AppStore, Session) {
        let session = Session(initialCwd: cwd, splitPaneIdentity: splitCwd == nil ? nil : UUID())
        session.splitCwd = splitCwd
        session.isSplit = splitCwd != nil
        return (AppStore(workspaces: [Workspace(name: "work", sessions: [session])]), session)
    }

    @Test("a title equal to the pane's own cwd is libghostty's OSC 7 echo and is dropped")
    func titleEqualToOwnCwdIsDropped() {
        let (store, session) = store(cwd: "/home/nick/develop")
        #expect(!store.recordTitle("/home/nick/develop", forSession: session.id, isSplit: false))
        #expect(session.oscTitle == nil)
    }

    @Test("a real title is recorded, including one naming another pane's directory")
    func realTitleIsRecorded() {
        let (store, session) = store(cwd: "/home/nick/develop", splitCwd: "/tmp")
        #expect(store.recordTitle("develop", forSession: session.id, isSplit: false))
        #expect(session.oscTitle == "develop")
        #expect(store.recordTitle("/tmp", forSession: session.id, isSplit: false))
        #expect(session.oscTitle == "/tmp")
    }

    @Test("the split pane is compared against its own cwd, not the primary's")
    func splitPaneComparesItsOwnCwd() {
        let (store, session) = store(cwd: "/home/nick/develop", splitCwd: "/tmp")
        #expect(!store.recordTitle("/tmp", forSession: session.id, isSplit: true))
        #expect(session.splitTitle == nil)
        #expect(store.recordTitle("/home/nick/develop", forSession: session.id, isSplit: true))
        #expect(session.splitTitle == "/home/nick/develop")
    }
}
