import Foundation
import Testing
@testable import AgtermLinux
import agtermCore

@Suite("Linux HTML overlay policy")
struct LinuxHtmlPolicyTests {
    private let site = HtmlOverlay(source: .url(URL(string: "http://localhost:5173/")!))
    private let file = HtmlOverlay(source: .file(path: "/work/report/index.html", grantRoot: "/work/report"))

    private func decide(_ text: String, _ target: LinuxHtmlTarget, clicked: Bool = false,
                        on overlay: HtmlOverlay) -> HtmlNavigationDecision {
        LinuxHtmlPolicy.decide(url: URL(string: text)!, target: target, userActivated: clicked, overlay: overlay)
    }

    @Test("an unclicked navigation elsewhere passes as a subframe's until its main-frame response")
    func mainFramePinnedAtResponse() {
        #expect(decide("https://cdn.example.com/embed", .frame, on: site) == .allow)
        #expect(decide("https://cdn.example.com/embed", .subframeResponse, on: site) == .allow)
        #expect(decide("https://evil.example.com/", .mainResponse, on: site) == .cancel)
        #expect(decide("http://localhost:5173/next", .mainResponse, on: site) == .allow)
    }

    @Test("a clicked link off the origin is handed to the browser; a new window only when clicked")
    func clickedLinksHandOff() {
        #expect(decide("https://docs.example.com/", .frame, clicked: true, on: site) == .openExternal)
        #expect(decide("http://localhost:5173/about", .frame, clicked: true, on: site) == .allow)
        #expect(decide("https://docs.example.com/", .newWindow, clicked: true, on: site) == .openExternal)
        #expect(decide("https://docs.example.com/", .newWindow, on: site) == .cancel)
    }

    @Test("a response is never treated as clicked")
    func responsesAreUnclicked() {
        #expect(LinuxHtmlPolicy.action(url: URL(string: "https://x.example/")!, target: .mainResponse,
                                       userActivated: true).userActivated == false)
    }

    @Test("a file page stays inside its grant and hands web links off only when clicked")
    func filePageGrant() {
        #expect(decide("file:///work/report/detail.html", .mainResponse, on: file) == .allow)
        #expect(decide("file:///work/other/secret.html", .mainResponse, on: file) == .cancel)
        #expect(decide("https://example.com/", .frame, clicked: true, on: file) == .openExternal)
        #expect(decide("https://example.com/", .frame, on: file) == .cancel)
    }
}

@Suite("Linux HTML overlay load")
struct LinuxHtmlLoadTests {
    @Test("an explicit load ends loaded, and the finish WebKit sends after a failure keeps it failed")
    func finishAfterFailure() {
        var load = LinuxHtmlLoad()
        load.begin()
        #expect(load.handle(.started) == .loading)
        #expect(load.handle(.failed("unreachable")) == .failed("unreachable"))
        #expect(load.handle(.finished) == .none)
        load.begin()
        #expect(load.handle(.committed) == .none)
        #expect(load.handle(.finished) == .loaded)
    }

    @Test("an interrupted load keeps a shown document and fails one never committed")
    func interrupted() {
        var shown = LinuxHtmlLoad()
        shown.begin()
        _ = shown.handle(.committed)
        shown.begin()
        #expect(shown.handle(.interrupted("interrupted")) == .loaded)
        var fresh = LinuxHtmlLoad()
        fresh.begin()
        #expect(fresh.handle(.interrupted("interrupted")) == .failed("interrupted"))
        #expect(fresh.handle(.interrupted("again")) == .none)
    }

    @Test("a blocked main frame fails a pending load once, and the interruption that follows is ignored")
    func blocked() {
        var load = LinuxHtmlLoad()
        load.begin()
        let url = URL(string: "https://elsewhere.example/")!
        #expect(load.blocked(url) == .failed("navigation blocked: https://elsewhere.example/"))
        #expect(load.handle(.interrupted("interrupted")) == .none)
        #expect(load.blocked(url) == .none)
    }

    @Test("the page's own blocked navigation leaves its shown document loaded")
    func pageNavigationBlocked() {
        var load = LinuxHtmlLoad()
        load.begin()
        _ = load.handle(.committed)
        #expect(load.handle(.finished) == .loaded)
        #expect(load.handle(.started) == .loading)
        #expect(load.blocked(URL(string: "https://elsewhere.example/")!) == .loaded)
        #expect(!load.pending)
    }

    @Test("a cancelled load changes nothing and a crashed web process fails the page")
    func cancelledAndTerminated() {
        var load = LinuxHtmlLoad()
        load.begin()
        #expect(load.handle(.cancelled) == .none)
        #expect(load.pending)
        _ = load.handle(.committed)
        #expect(load.handle(.terminated) == .failed("web content process terminated"))
        #expect(!load.committed)
    }
}

@Suite("Linux WebKit plugin loading")
@MainActor
struct LinuxWebKitTests {
    @Test("the launcher's plugin path comes first, then the build and payload layouts")
    func candidates() {
        let paths = LinuxWebKit.candidates(environment: ["AGTERM_WEBKIT_PLUGIN": "/opt/p.so"],
                                           executable: "/opt/agterm/bin/agterm-linux.bin")
        #expect(paths == ["/opt/p.so", "/opt/agterm/bin/libagterm-webkit.so", "/opt/agterm/lib/agterm/libagterm-webkit.so"])
        #expect(LinuxWebKit.candidates(environment: [:], executable: "/opt/agterm/bin/x").count == 2)
    }

    @Test("a build without the plugin refuses with a reason rather than loading nothing")
    func missingPlugin() {
        guard case .failure(let failure) = LinuxWebKit.load(candidates: ["/nonexistent/libagterm-webkit.so"]) else {
            Issue.record("a missing plugin loaded")
            return
        }
        #expect(failure.message == "html overlays are not available in this build")
    }

    @Test("a library that is not the plugin is refused by its missing entry point")
    func wrongLibrary() throws {
        let libc = try #require(["/lib/x86_64-linux-gnu/libc.so.6", "/usr/lib/libc.so.6", "/lib64/libc.so.6"]
            .first { FileManager.default.fileExists(atPath: $0) })
        guard case .failure(let failure) = LinuxWebKit.load(candidates: [libc]) else {
            Issue.record("libc loaded as the plugin")
            return
        }
        #expect(failure.message.hasSuffix("has no agterm_webkit_api_v1"))
    }
}
