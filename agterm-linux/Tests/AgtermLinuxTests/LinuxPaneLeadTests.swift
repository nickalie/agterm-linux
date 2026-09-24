import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux pane lead")
@MainActor
struct LinuxPaneLeadTests {
    private let endpoint = ControlZmxEndpoint(executable: "/opt/agterm/libexec/zmx", socketDirectory: "/tmp/zmx-1")

    @Test("a pane whose zmx never reported stays on its surface")
    func unreportedStaysOnSurface() {
        #expect(PaneLeadSource.resolve(covered: false, role: nil, daemon: "agterm-x") == .surface)
    }

    @Test("a local managed pane types and reads layout through the daemon even while it leads")
    func leadingLocalGoesThroughDaemon() {
        #expect(PaneLeadSource.resolve(covered: false, role: .leader, daemon: "agterm-x") == .daemon("agterm-x"))
        #expect(PaneLeadSource.resolve(covered: false, role: .leader, daemon: "agterm-x", viewport: true) == .surface)
    }

    @Test("a covered local pane reads even its viewport from the daemon")
    func coveredViewportFromDaemon() {
        #expect(PaneLeadSource.resolve(covered: true, role: .follower, daemon: "agterm-x", viewport: true)
            == .daemon("agterm-x"))
        #expect(PaneLeadSource.resolve(covered: true, role: nil, daemon: "agterm-x") == .daemon("agterm-x"))
    }

    @Test("a covered attached pane refuses with the upstream text, a leading one keeps its surface")
    func attachedPaneRefusesWhileCovered() {
        #expect(PaneLeadSource.resolve(covered: true, role: .follower, daemon: nil)
            == .refused("pane is in use on the Mac it runs on; take the lead to drive it from here"))
        #expect(PaneLeadSource.resolve(covered: false, role: .leader, daemon: nil) == .surface)
        #expect(PaneLeadSource.coveredRefusal
            == "pane is covered while another Mac leads it; take the lead first (session lead)")
    }

    @Test("a local re-attach never creates the daemon it expected")
    func localReattachGuardsAVanishedDaemon() {
        let configuration = ZmxSupport.Configuration(
            executablePath: "/opt/zmx", environment: ["ZMX_MANAGED": "abc"], daemonName: "agterm-d",
            socketDirectory: "/tmp/z", paneID: "p")
        let launch = PaneReattach.local(configuration, workingDirectory: "/home/u")
        #expect(launch.command == CommandRestore.shellQuotedLine(
            ["/opt/zmx", "attach", "agterm-d", "/bin/sh", "-c", PaneReattach.goneScript]))
        #expect(!launch.wait)
        #expect(launch.environment["ZMX_MANAGED"] == "abc")
        #expect(launch.workingDirectory == "/home/u")
    }

    @Test("a remote re-attach is rebuilt from the binding with a fresh nonce")
    func remoteReattachCarriesTheNewNonce() throws {
        let local = UUID()
        let daemon = ZmxSupport.daemonName(for: UUID())
        let binding = RemoteBinding(remoteSessionID: "s1", daemonsByLocalPane: [local: daemon], presentationVersion: nil,
                                    origin: RemoteBinding.Origin(host: "mac", endpoint: endpoint, sessionName: "work"))
        let claiming = ZmxLeadAttachment(nonce: "fresh1", claim: true)
        let command = try #require(PaneReattach.remoteCommand(binding, pane: local, role: .left, lead: claiming))
        #expect(command.contains("ZMX_MANAGED=fresh1"))
        #expect(command.contains("ZMX_MANAGED_CLAIM=1"))
        #expect(command.contains(daemon))
        let quiet = try #require(PaneReattach.remoteCommand(binding, pane: local, role: .left,
                                                            lead: ZmxLeadAttachment(nonce: "fresh2", claim: false)))
        #expect(quiet.contains("ZMX_MANAGED=fresh2"))
        #expect(!quiet.contains("ZMX_MANAGED_CLAIM"))
        #expect(PaneReattach.remoteCommand(binding, pane: UUID(), role: .left, lead: claiming) == nil)
    }

    @Test("zmx.attach claims the lead in every pane it opens")
    func attachClaims() {
        let attachment = RemoteAttachment(
            remoteSessionID: "s1", presentationVersion: 1, left: "agterm-l", right: "agterm-r",
            origin: RemoteBinding.Origin(host: "mac", endpoint: endpoint, sessionName: "work"))
        #expect(attachment.leads.left.claim && attachment.leads.right.claim)
        #expect(attachment.leads.left.nonce != attachment.leads.right.nonce)
    }

    @Test("the cover names its state and hides the key hint while taking over")
    func coverCaption() {
        #expect(LinuxPaneLeadCover.caption(role: .follower, reattaching: false, remote: false)
            == ("In use from another machine", true))
        #expect(LinuxPaneLeadCover.caption(role: .follower, reattaching: false, remote: true)
            == ("In use on the machine it runs on", true))
        #expect(LinuxPaneLeadCover.caption(role: .unowned, reattaching: false, remote: false) == ("Reconnecting…", true))
        #expect(LinuxPaneLeadCover.caption(role: nil, reattaching: true, remote: false) == ("Taking over…", false))
    }

    @Test("tree reads each pane's reported lead, and only the current attachment's reports count")
    func treeReadsTheBook() throws {
        let session = Session(initialCwd: "/")
        let store = AppStore(workspaces: [Workspace(name: "w", sessions: [session])], selectedSessionID: session.id)
        let book = ZmxLeadBook.shared
        defer { book.forget(pane: session.paneIdentity) }
        func primaryLead() throws -> ZmxLeadRole? {
            let node = try #require(store.controlTree(paneForeground: { (_: Session) -> CommandRestore.PaneForeground? in nil }).workspaces.first?.sessions.first)
            return node.surfaces?.first { $0.kind == TerminalZoomSurface.primary.rawValue }?.lead
        }
        let attachment = ZmxLeadAttachment(nonce: "n1", claim: false)
        book.begin(attachment, pane: session.paneIdentity)
        #expect(try primaryLead() == nil)
        #expect(!book.covered(pane: session.paneIdentity))

        let forged = try #require(ZmxLeadNotice(title: "zmx-role;other:follower:3"))
        #expect(book.apply(forged, pane: session.paneIdentity) == nil)

        let follower = try #require(ZmxLeadNotice(title: "zmx-role;n1:follower:2"))
        #expect(book.apply(follower, pane: session.paneIdentity) == .follower)
        #expect(try primaryLead() == .follower)
        #expect(book.covered(pane: session.paneIdentity))

        let stale = try #require(ZmxLeadNotice(title: "zmx-role;n1:leader:1"))
        #expect(book.apply(stale, pane: session.paneIdentity) == nil)
        #expect(ZmxLeadNotice(title: "a program title") == nil)
        #expect(ZmxLeadNotice(title: "zmx-role;n1:boss:4") == nil)
    }

    @Test("the scripted text goes to zmx type as typed keystrokes, one CR per line ending")
    func typedBytes() {
        #expect(KeystrokeSegments.ptyBytes("ls\r\n") == Array("ls\r".utf8))
    }
}
