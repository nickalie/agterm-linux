import Foundation
import agtermCore

/// Remote sessions on GTK: `zmx.tree` lists another machine's attachable sessions and `zmx.attach` opens
/// one here. A remote pane is an ORDINARY command surface whose command is ssh — no new surface kind and
/// no remote daemon ownership, so closing it locally ends this side and the far daemon carries on.
///
/// Every entry point BLOCKS its calling thread, which the control server gives it: GLib drains neither
/// libdispatch's main queue nor the Swift Concurrency executor, so `agtermCore`'s async `ControlActions`
/// arms would never resume here (see `agterm-linux/docs/main-loop.md`). Model reads and writes hop to the
/// GTK thread through `onMain`; the ssh itself never runs there.
enum LinuxRemoteSessions {
    /// Bounds the whole remote read: `ConnectTimeout` ends at the handshake and cannot bound a command
    /// that never returns.
    static let treeDeadline: TimeInterval = 20

    static func tree(host: String?) -> ControlResponse {
        guard let host = host?.linuxTrimmedOrNil else { return onMain(window: nil) { $0.localAttachableSessions() } }
        let argv: [String]
        do {
            argv = try RemoteSession.treeCommand(host: host)
        } catch {
            // the host is NOT echoed: reaching here means validation rejected it for carrying control
            // characters, which agtermctl would print to a terminal after decoding
            return ControlResponse(ok: false, error: "invalid host")
        }
        let result = LinuxRemoteCommandRunner.run(argv, deadline: treeDeadline)
        guard result.status == 0 else {
            // stdout first: the remote's agtermctl prints a not-ok response there and exits nonzero, so
            // its own sentence never reaches stderr, and an ok-looking payload from a nonzero process is
            // never accepted
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = RemoteTreeMerger.remoteError(stdout: result.stdout) ?? (stderr.isEmpty ? nil : stderr)
            return ControlResponse(ok: false, error: detail ?? "the remote command failed on \(host)")
        }
        do {
            let remote = try RemoteTreeMerger.decode(stdout: result.stdout)
            // the far side cannot know which name reached it, so the destination we were given is stamped
            // here rather than self-reported there
            return ControlResponse(ok: true, result: ControlResult(remote: remote.stamped(host: host)))
        } catch let error as RemoteTreeMerger.MergeError {
            return ControlResponse(ok: false, error: error.message)
        } catch {
            return ControlResponse(ok: false, error: "the remote answer could not be read")
        }
    }

    /// Create a local session attached to one of `host`'s.
    ///
    /// The remote is resolved AGAIN here rather than trusted from whatever the caller last saw: a picker's
    /// answer can be minutes old, and a daemon that has gone since would otherwise be CREATED by the
    /// attach, handing back a fresh shell wearing the session's name.
    static func attach(host: String, session: String, window: String?) -> ControlResponse {
        let discovery = tree(host: host)
        guard discovery.ok, let remoteTree = discovery.result?.remote else { return discovery }
        // by id only: remote session names are mutable and deliberately non-unique across workspaces
        guard let remote = remoteTree.sessions.first(where: { $0.id == session }) else {
            return ControlResponse(ok: false, error: "no attachable session \(session) on \(host)")
        }
        // by role, never by position: a payload with two lefts or no left must fail rather than quietly
        // become one pane, or the wrong one
        let byRole = Dictionary(remote.panes.map { (ZmxPaneRole(controlName: $0.pane), $0.daemon) },
                                uniquingKeysWith: { first, _ in first })
        guard byRole.count == remote.panes.count, let left = byRole[.left] else {
            return ControlResponse(ok: false, error: "\(host) reported panes agterm cannot address")
        }
        let primary: String
        let split: String?
        // attaching is the user asking for the session HERE, so every pane claims the lead at once
        let attachment = RemoteAttachment(
            remoteSessionID: remote.id, presentationVersion: remoteTree.presentation, left: left, right: byRole[.right],
            origin: RemoteBinding.Origin(host: host, endpoint: remoteTree.endpoint, sessionName: remote.name))
        do {
            primary = try RemoteSession.attachPaneCommand(host: host, endpoint: remoteTree.endpoint, daemon: left,
                                                          session: remote.name, pane: .left, lead: attachment.leads.left)
            split = try byRole[.right].map {
                try RemoteSession.attachPaneCommand(host: host, endpoint: remoteTree.endpoint, daemon: $0,
                                                    session: remote.name, pane: .right, lead: attachment.leads.right)
            }
        } catch {
            return ControlResponse(ok: false, error: "\(host) reported a session agterm cannot address")
        }
        // everything that can fail is checked before the model is touched, so a refusal leaves no
        // half-built row behind; ssh itself starts after insertion, as an ordinary pane on the held path
        return onMain(window: window) { controller in
            controller.insertRemoteSession(host: host, name: remote.name, primary: primary, split: split,
                                           axis: remote.splitAxis.flatMap(SplitAxis.init(rawValue:)),
                                           attachment: attachment)
        }
    }

    /// Runs `body` on the GTK thread and blocks until it answers, the same hop the control server uses.
    private static func onMain(window: String?,
                               _ body: @escaping @MainActor (AppController) -> ControlResponse)
        -> ControlResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        runOnMain {
            MainActor.assumeIsolated {
                switch resolveTargetWindow(window) {
                case .failure(let response): box.value = response
                case .success(let controller): box.value = body(controller)
                }
                semaphore.signal()
            }
        }
        semaphore.wait()
        return box.value
    }

    /// The window an attach lands in. A named target that is unknown or closed FAILS rather than falling
    /// back to the frontmost one, so a script placing a session in a background window cannot silently
    /// place it under the user's hands instead.
    @MainActor private static func resolveTargetWindow(_ window: String?)
        -> AppController.ResolveResponse<AppController> {
        let frontmost = gLibrary?.frontmostWindowID.flatMap { gWindows[$0] } ?? gWindows.values.first
        guard let window = window?.linuxTrimmedOrNil else {
            guard let frontmost else {
                return .failure(ControlResponse(ok: false, error: "no window to attach into"))
            }
            return .success(frontmost)
        }
        guard let anyController = frontmost else {
            return .failure(ControlResponse(ok: false, error: "no window to attach into"))
        }
        switch anyController.resolveWindowResponse(window) {
        case .failure(let response): return .failure(response)
        case .success(let id):
            guard let controller = gWindows[id] else {
                return .failure(ControlResponse(ok: false, error: "window not open — window.select it first"))
            }
            return .success(controller)
        }
    }
}

@MainActor
extension AppController {
    /// Insert the attached session into this window's current workspace and focus it.
    func insertRemoteSession(host: String, name: String, primary: String, split: String?,
                             axis: SplitAxis?, attachment: RemoteAttachment? = nil) -> ControlResponse {
        guard let workspace = store.currentWorkspaceID else {
            return ControlResponse(ok: false, error: "no window to attach into")
        }
        // the LOCAL working directory, not the remote one: libghostty chdirs the ssh process here, and a
        // path that exists on the far side may not exist on this machine
        guard let created = store.addSession(toWorkspace: workspace, cwd: Self.homeCwd, command: primary,
                                             name: name, wait: true, remoteHost: host) else {
            return ControlResponse(ok: false, error: "could not create the session")
        }
        if let split {
            created.splitInitialCommand = split
            created.splitCommandWait = true
            store.setSplitVisibility(created.id, shown: true, axis: axis ?? .leftRight)
        }
        attachment?.record(on: created, in: store)
        reconcile()
        (created.splitFocused ? splitSurfaces[created.id] : surfaces[created.id])?.grabFocus()
        return ControlResponse(ok: true, result: ControlResult(id: created.id.uuidString))
    }

    /// This app's own attachable sessions, across every OPEN window. An empty list is a successful answer
    /// and does not distinguish "not running live" from "live with nothing eligible"; `zmx list` is the
    /// restore-mode diagnostic.
    func localAttachableSessions() -> ControlResponse {
        guard gZmx.client.isAvailable else {
            return ControlResponse(ok: false, error: ControlZmxError.unavailable)
        }
        guard let observed = gZmx.client.listSessions() else {
            return ControlResponse(ok: false, error: "could not read the zmx session list")
        }
        let walk = library.paneClaims()
        let inventory = ControlZmxInventory(restore: restoreStatus(),
                                            result: ZmxInventory.join(observed: observed, claims: walk.claims,
                                                                      inventoryComplete: walk.complete),
                                            endpoint: gZmx.client.endpoint)
        // a live store IS the open-window test: a closed window's panes are not attachable from here
        let windows = library.windows.compactMap { entry -> RemoteWindowProjection? in
            guard let controller = gWindows[entry.id] else { return nil }
            return RemoteWindowProjection(id: entry.id.uuidString, name: entry.name,
                                          tree: controller.store.controlTree(paneForeground: { _ in nil }))
        }
        do {
            return ControlResponse(ok: true,
                                   result: ControlResult(remote: try RemoteTreeMerger.candidates(
                                       windows: windows, inventory: inventory)))
        } catch let error as RemoteTreeMerger.MergeError {
            return ControlResponse(ok: false, error: error.message)
        } catch {
            return ControlResponse(ok: false, error: "the session list could not be built")
        }
    }
}

/// What `zmx.attach` hands the new row: each pane's claiming attachment and what attaching it again takes.
struct RemoteAttachment: Sendable {
    let remoteSessionID: String
    let presentationVersion: Int?
    let left: String
    let right: String?
    let origin: RemoteBinding.Origin
    let leads = (left: ZmxLeadAttachment(claim: true), right: ZmxLeadAttachment(claim: true))

    @MainActor
    func record(on session: Session, in store: AppStore) {
        var daemons = [session.paneIdentity: left]
        ZmxLeadBook.shared.begin(leads.left, pane: session.paneIdentity)
        if let right, let local = session.splitPaneIdentity {
            daemons[local] = right
            ZmxLeadBook.shared.begin(leads.right, pane: local)
        }
        store.bindRemote(RemoteBinding(remoteSessionID: remoteSessionID, daemonsByLocalPane: daemons,
                                       presentationVersion: presentationVersion, origin: origin), forSession: session.id)
        // the row's created event fired inside `addSession`, before the binding existed
        gPresentation.startRemotePresentation(for: session)
    }
}
