import CGtk
import Foundation
import agtermCore

/// Attach Remote…, File ▸ Attach Remote on macOS: a palette row and `attach_remote` here, GTK having no menu
/// bar. It composes the `zmx.tree` read, the window picker and `zmx.attach` as upstream's
/// `AppActions.attachRemote` does, so it adds no control command. The two ssh waits run on a thread of their
/// own, as over the socket, and hop back to the GTK thread with what they read.
@MainActor
extension AppController {
    static let remoteAttachErrorSeconds: Double = 5
    /// A progress panel is timed, so a soft-closed session drops it.
    static let remoteAttachProgressSeconds: Double = 30

    /// attachRemote asks which configured machine to attach from; a single entry needs no question.
    func attachRemote() {
        let remotes = LinuxRemotes.shared.entries(reportingIn: self)
        guard acceptsAttentionSelection, let first = remotes.first else { return }
        guard remotes.count > 1 else { return attachRemote(first.destination) }
        let items = remotes.map {
            ControlPickItem(id: $0.destination, label: $0.label, subtitle: $0.label == $0.destination ? nil : $0.destination)
        }
        pickInApp(PendingPick(id: UUID().uuidString, items: items, prompt: "Attach from which machine?")) { [weak self] picked in
            guard let self, picked?.result == .picked, let destination = picked?.id else { return }
            self.attachRemote(destination)
        }
    }

    /// attachRemote lets the user pick one of `destination`'s sessions and attaches it in this window.
    func attachRemote(_ destination: String) {
        guard acceptsAttentionSelection else { return }
        let hud = RemoteAttachHud(controller: self, session: store.selectedSessionID)
        hud.progress("listing sessions on \(destination)…")
        let windowID = windowID
        Thread.detachNewThread {
            let listing = LinuxRemoteSessions.tree(host: destination)
            runOnMain {
                MainActor.assumeIsolated {
                    // the window may have closed during the ssh wait
                    guard let controller = gWindows[windowID] else { return }
                    controller.offerRemoteSessions(listing, from: destination, hud: hud)
                }
            }
        }
    }

    private func offerRemoteSessions(_ listing: ControlResponse, from destination: String, hud: RemoteAttachHud) {
        guard listing.ok, let sessions = listing.result?.remote?.sessions else {
            return hud.fail("\(destination): \(listing.error ?? "no answer")")
        }
        guard !sessions.isEmpty, sessions.count <= ControlPickItem.maxItems else {
            return hud.fail(sessions.isEmpty ? "nothing to attach on \(destination)" : "\(destination) offers too many sessions")
        }
        hud.close()
        let pick = PendingPick(id: UUID().uuidString, items: sessions.map(Self.remotePickItem),
                               prompt: "Attach from \(destination)")
        let windowID = windowID
        pickInApp(pick) { picked in
            guard picked?.result == .picked, let session = picked?.id else { return }
            hud.progress("attaching \(picked?.label ?? session)…")
            Thread.detachNewThread {
                let attached = LinuxRemoteSessions.attach(host: destination, session: session, window: windowID.uuidString)
                runOnMain {
                    MainActor.assumeIsolated {
                        if attached.ok { hud.close() } else { hud.fail(attached.error ?? "attach failed") }
                    }
                }
            }
        }
    }

    static func remotePickItem(_ session: ControlRemoteSession) -> ControlPickItem {
        let programs = session.panes.compactMap { $0.foreground?.first.map { ($0 as NSString).lastPathComponent } }
        let parts = ["\(session.windowName)/\(session.workspaceName)", session.context ?? "", session.cwd,
                     programs.joined(separator: " | ")]
        return ControlPickItem(id: session.id, label: session.name,
                               subtitle: parts.filter { !$0.isEmpty }.joined(separator: "  ·  "))
    }
}

/// RemoteAttachHud is the HUD an attach posts over the session it started from. A window with no session has
/// nowhere to put one, so a failure there falls back to a toast.
@MainActor
private final class RemoteAttachHud {
    private weak var controller: AppController?
    private let session: UUID?
    /// owned is the HUD this attach opened; one another caller posted meanwhile is not its to close.
    private var owned: Int?

    init(controller: AppController, session: UUID?) {
        self.controller = controller
        self.session = session
    }

    func progress(_ text: String) {
        open(HudSpec(message: Self.message(text), spinner: .bar, hideAfter: AppController.remoteAttachProgressSeconds))
    }

    func close() {
        guard let session, let owned, let owner = owner(of: session), generation(session, in: owner) == owned else { return }
        _ = owner.closeHud(session.uuidString, window: nil)
        self.owned = nil
    }

    func fail(_ text: String) {
        if open(HudSpec(message: Self.message(text), hideAfter: AppController.remoteAttachErrorSeconds)) { return }
        close()
        controller?.showToast(Self.message(text))
    }

    @discardableResult
    private func open(_ spec: HudSpec) -> Bool {
        guard let session, let owner = owner(of: session),
              owner.openHud(session.uuidString, window: nil, spec: spec).ok else { return false }
        owned = generation(session, in: owner)
        return true
    }

    // the session may have moved to another window during an ssh wait
    private func owner(of session: UUID) -> AppController? {
        gWindows.values.first { $0.store.session(withID: session) != nil }
    }

    private func generation(_ session: UUID, in owner: AppController) -> Int? {
        owner.store.session(withID: session).flatMap { $0.hudActive ? $0.overlaySlotGeneration : nil }
    }

    /// a direct `openHud` skips the dispatcher's validation, so remote text is cleaned and capped here
    private static func message(_ text: String) -> String {
        CommandFailure.message(name: "Attach Remote", reason: text)
    }
}

/// LinuxRemotes reads `remotes.conf` when the palette is built or Attach Remote runs. The palette reads its
/// rows each time it opens, so a fresh read is as current as upstream's file watcher, which exists because
/// SwiftUI rebuilds its menus on a schedule of its own.
@MainActor
final class LinuxRemotes {
    static let shared = LinuxRemotes()
    private var issueCount = 0

    /// The configured entries; an unreadable file reads as none. A read that finds a clean file turned into
    /// one with problems toasts once, as upstream banners once per such episode.
    func entries(reportingIn controller: AppController?) -> [RemoteEntry] {
        let url = ConfigPaths.remotesPath(configDirectory: (controller ?? gController)?.configDirectory()
            ?? ConfigPaths.configDirectory(setting: nil, stateDir: ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"],
                                           home: FileManager.default.homeDirectoryForCurrentUser))
        let loaded = try? RemotesFile.load(at: url)
        let issues = loaded?.diagnostics.count ?? 1
        if issueCount == 0, issues > 0 {
            controller?.showToast("remotes.conf: \(issues) issue\(issues == 1 ? "" : "s")")
        }
        issueCount = issues
        return loaded?.remotes.entries ?? []
    }
}
