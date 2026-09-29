import Foundation
import agtermCore

/// LinuxHtmlTarget is what WebKitGTK tells about a navigation: it names no target frame, so the main frame's
/// origin is checked again on its response, which does say whether it is the main frame's.
enum LinuxHtmlTarget: Equatable {
    case frame, newWindow, mainResponse, subframeResponse
}

/// LinuxHtmlPolicy maps a WebKitGTK decision onto the shared `HtmlNavigationPolicy`.
enum LinuxHtmlPolicy {
    /// A clicked link is judged as the main frame's, where a hand-off belongs. Anything else is judged as a
    /// subframe's at navigation time, which admits what an iframe may load; the main frame is pinned when its
    /// response arrives.
    static func action(url: URL, target: LinuxHtmlTarget, userActivated: Bool) -> HtmlNavigationAction {
        let frame: HtmlNavigationTarget
        switch target {
        case .newWindow: frame = .newWindow
        case .mainResponse: frame = .mainFrame
        case .subframeResponse: frame = .subframe
        case .frame: frame = userActivated ? .mainFrame : .subframe
        }
        let clicked = userActivated && (target == .frame || target == .newWindow)
        return HtmlNavigationAction(url: url, target: frame, userActivated: clicked)
    }

    static func decide(url: URL, target: LinuxHtmlTarget, userActivated: Bool,
                       overlay: HtmlOverlay) -> HtmlNavigationDecision {
        HtmlNavigationPolicy.decide(action(url: url, target: target, userActivated: userActivated), overlay: overlay)
    }
}

/// LinuxHtmlLoad keeps a page's main-frame load ending `loaded` or `failed`, as `HtmlOverlayPage` does on
/// macOS: `pending` is a load in flight, explicit or started by the page, and `committed` a document the web
/// process still shows, which an interrupted load leaves in place.
struct LinuxHtmlLoad: Equatable {
    enum Event: Equatable {
        case started, committed, finished, cancelled, terminated
        case interrupted(String), failed(String)
    }

    enum Outcome: Equatable {
        case none, loading, loaded
        case failed(String)
    }

    private(set) var pending = false
    private(set) var committed = false
    // the app started the pending load, rather than the page
    private(set) var explicit = false

    mutating func begin() {
        pending = true
        explicit = true
    }

    mutating func handle(_ event: Event) -> Outcome {
        switch event {
        case .started:
            pending = true
            return .loading
        case .committed:
            committed = true
            return .none
        case .finished:
            // WebKitGTK also finishes a load it reported failed; the failure stands
            guard pending else { return .none }
            return settle()
        case .cancelled:
            return .none
        case .interrupted(let message):
            guard pending else { return .none }
            guard committed else { return fail(message) }
            return settle()
        case .failed(let message):
            return fail(message)
        case .terminated:
            committed = false
            return fail("web content process terminated")
        }
    }

    /// blocked is the policy refusing the main frame's response while a load is pending. WebKitGTK asks only
    /// once the load started, where macOS refuses a page's own navigation before it starts and the shown
    /// document stays, so only a load the app started fails here.
    mutating func blocked(_ url: URL) -> Outcome {
        guard pending else { return .none }
        if !explicit, committed { return settle() }
        return fail("navigation blocked: \(url.absoluteString)")
    }

    private mutating func settle() -> Outcome {
        pending = false
        explicit = false
        return .loaded
    }

    private mutating func fail(_ message: String) -> Outcome {
        pending = false
        explicit = false
        return .failed(message)
    }
}
