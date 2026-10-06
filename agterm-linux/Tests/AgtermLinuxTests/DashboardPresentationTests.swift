import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux dashboard presentation")
struct DashboardPresentationTests {
    private let first = DashboardMember(session: UUID(), surface: .primary)
    private let second = DashboardMember(session: UUID(), surface: .split)

    @Test("the latest click supersedes an older generation")
    func latestClickWins() {
        var intent = DashboardClickIntent()
        let firstGeneration = intent.begin(member: first)
        let secondGeneration = intent.begin(member: second)

        #expect(!intent.accepts(generation: firstGeneration, member: first))
        #expect(intent.accepts(generation: secondGeneration, member: second))
        #expect(DashboardClickIntent.delayMilliseconds == 180)
    }

    @Test("cancellation rejects an already scheduled click")
    func cancellationRejectsScheduledClick() {
        var intent = DashboardClickIntent()
        let generation = intent.begin(member: first)

        intent.cancel()

        #expect(!intent.accepts(generation: generation, member: first))
        #expect(intent.member == nil)
    }

    @Test("normal titles add only custom window names")
    func normalTitles() {
        #expect(LinuxModalTitle.normal(sessionName: nil, window: nil) == "Agterm")
        #expect(LinuxModalTitle.normal(
            sessionName: "build", window: WindowInfo(name: "window 3")) == "build")
        #expect(LinuxModalTitle.normal(
            sessionName: "build", window: WindowInfo(name: "release")) == "build — release")
    }

    @Test("dashboard titles add only custom window names")
    func dashboardTitles() {
        #expect(LinuxModalTitle.dashboard(window: nil) == "Dashboard")
        #expect(LinuxModalTitle.dashboard(window: WindowInfo(name: "window 3")) == "Dashboard")
        #expect(LinuxModalTitle.dashboard(window: WindowInfo(name: "release")) == "Dashboard — release")
    }
}

@Suite("Linux dashboard overlay cover")
struct LinuxDashboardCoverTextTests {
    @Test("a page cover names its source and keeps the page title apart")
    func page() {
        let text = LinuxDashboardCoverText(.page(identity: "report.html", title: "Build"))
        #expect(text.kind == "HTML overlay")
        #expect(text.source == "report.html")
        #expect(text.title == "Build")
    }

    @Test("a program cover names its command, a replica's none")
    func program() {
        #expect(LinuxDashboardCoverText(.program(command: "htop")).source == "htop")
        #expect(LinuxDashboardCoverText(.program(command: nil)).source == nil)
        #expect(LinuxDashboardCoverText(.program(command: "htop")).kind == "Program overlay")
    }
}
