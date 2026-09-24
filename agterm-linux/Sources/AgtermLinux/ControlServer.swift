// The Linux control socket: a unix-domain socket that decodes one ControlRequest
// per connection and dispatches it onto the shared AppController/AppStore, writing
// one ControlResponse back. Mirrors the macOS ControlServer, but hops to the GTK
// main thread via g_idle (runOnMain) + a semaphore instead of DispatchQueue.main.
// The wire protocol (ControlProtocol) is shared from agtermCore; the Linux agtermctl wrapper lives in
// agterm-linux so Glibc socket code stays inside the Linux boundary.
import Foundation
import agtermCore
#if canImport(Glibc)
import Glibc
#endif

final class ControlServer: @unchecked Sendable {
    let path: String
    private var listenFD: Int32 = -1
    private static let maxLine = 1 << 20
    private static let readTimeoutMS: Int32 = 5_000

    /// The held `<path>.lock` fd, or -1 when this process does not own `path`.
    private var lockFD: Int32 = -1
    /// Set while another live instance owns `path`, so this one never serves it.
    private(set) var refused = false

    /// The socket path once actually bound (nil before bind / after a bind failure).
    var boundSocketPath: String? { listenFD >= 0 ? path : nil }

    static let unavailableSuffix = ".unavailable"

    /// What spawned shells get as `AGTERM_SOCKET`: macOS `resolvedSocketPath`, which owns the contract.
    /// A refused instance advertises a path nothing creates, so its shells cannot reach the owner.
    var resolvedSocketPath: String { refused ? path + Self.unavailableSuffix : path }

    /// Ownership is settled here, not in `start()`, as on macOS: a shell spawned before the bind must
    /// already see the right `AGTERM_SOCKET`.
    init(path: String = ControlServer.defaultSocketPath()) {
        self.path = path
        _ = acquireOwnership()
    }

    static func defaultSocketPath() -> String {
        ControlResolve.socketPath(stateDir: ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"],
                                  appSupport: PersistenceStore.defaultDirectory.path)
    }

    func start() {
        guard listenFD < 0 else { return }
        signal(SIGPIPE, SIG_IGN)
        guard path.utf8.count < 104 else { return }
        // every failure below keeps the lock, as on macOS: releasing it would let another instance bind
        // the path this one still advertises
        guard lockFD >= 0 || acquireOwnership() else { return }
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buf in
                bytes.withUnsafeBufferPointer { src in buf.update(from: src.baseAddress!, count: src.count) }
            }
        }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        // Restrict the socket to the owner (mirrors the macOS server's chmod 0600) so another local
        // user can't drive this terminal over the control channel.
        _ = path.withCString { chmod($0, 0o600) }
        listenFD = fd
        Thread.detachNewThread { [self] in acceptLoop(fd) }
        FileHandle.standardError.write(Data("agterm: control socket at \(path)\n".utf8))
    }

    func stop() {
        defer { releaseOwnership() }
        guard listenFD >= 0 else { return }
        close(listenFD)
        listenFD = -1
        unlink(path)
    }

    private func acquireOwnership() -> Bool {
        let lockPath = ControlResolve.ownershipLockPath(forSocket: path)
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            refused = true
            FileHandle.standardError.write(
                Data("agterm: control socket \(path) is already served by another instance — not binding\n".utf8))
            return false
        }
        lockFD = fd
        refused = false
        return true
    }

    /// The lock FILE stays: unlinking it would let the next instance lock a fresh inode, excluding nobody.
    private func releaseOwnership() {
        guard lockFD >= 0 else { return }
        close(lockFD)
        lockFD = -1
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 {
                // a closed listener (stop()) makes accept fail — exit; EINTR (signal) / ECONNABORTED
                // are transient, so keep serving instead of dying. Mirrors the macOS accept loop.
                if errno == EBADF || errno == EINVAL { return }
                continue
            }
            guard handle(conn) else { continue }   // a handed-off connection closes itself
            close(conn)
        }
    }

    /// Answers one request; false when the connection was handed to a worker that owns it from here.
    private func handle(_ conn: Int32) -> Bool {
        guard let line = readLine(conn) else { return true }
        guard let req = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
            respond(conn, ControlResponse(ok: false, error: "could not decode request"))
            return true
        }
        // `zmx.tree` and `zmx.attach` run ssh, and the two are the ONLY commands that leave this thread:
        // `zmx tree <this machine>` would otherwise deadlock, the far side's own agtermctl waiting in the
        // backlog this connection is holding. The GLib loop drains no Swift Concurrency executor, so the
        // work blocks a thread of its own and hops to the GTK thread only for model access.
        guard req.cmd == .zmxTree || req.cmd == .zmxAttach else {
            respond(conn, dispatchOnMain(req))
            return true
        }
        Thread.detachNewThread { [self] in
            respond(conn, Self.remoteResponse(for: req))
            close(conn)
        }
        return false
    }

    private static func remoteResponse(for req: ControlRequest) -> ControlResponse {
        switch req.cmd {
        case .zmxTree:
            return LinuxRemoteSessions.tree(host: req.args?.host)
        default:
            guard let host = req.args?.host?.linuxTrimmedOrNil else {
                return ControlResponse(ok: false, error: "zmx.attach requires a host")
            }
            // no `active` default: the target names a session on ANOTHER machine, which nothing local
            // could resolve for the caller
            guard let session = req.target?.linuxTrimmedOrNil else {
                return ControlResponse(ok: false, error: "zmx.attach requires a remote session")
            }
            // the unresolved case names the id it could not find, so a control character here would reach
            // a terminal through that message
            guard RemoteSession.isPlain(session) else {
                return ControlResponse(ok: false, error: "invalid remote session")
            }
            return LinuxRemoteSessions.attach(host: host, session: session, window: req.args?.window)
        }
    }

    private func respond(_ conn: Int32, _ response: ControlResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        writeAll(conn, data)
    }

    /// Run the dispatch on the GTK main thread and block until it returns.
    private func dispatchOnMain(_ req: ControlRequest) -> ControlResponse {
        let sem = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        runOnMain {
            MainActor.assumeIsolated {
                box.value = Self.route(for: req).response(for: req)
                sem.signal()
            }
        }
        sem.wait()
        return box.value
    }

    private enum ControllerRoute {
        case controller(AppController?)
        case failure(String)

        @MainActor func response(for req: ControlRequest) -> ControlResponse {
            switch self {
            case .controller(let controller):
                return controller?.handleControl(req) ?? ControlResponse(ok: false, error: "no controller")
            case .failure(let error):
                return ControlResponse(ok: false, error: error)
            }
        }
    }

    @MainActor private static func route(for req: ControlRequest) -> ControllerRoute {
        // app-global: the dispatcher refuses `--window` itself, which an unknown window must not preempt
        if req.cmd == .hooksReload || req.cmd == .hooksList { return .controller(gController) }
        if let window = req.args?.window, !window.isEmpty {
            guard let library = gLibrary else {
                return .failure("window not open")
            }
            let id: UUID
            switch library.resolveWindow(window) {
            case .resolved(let resolved):
                id = resolved
            case .ambiguous(let hits):
                return .failure(ControlResolve.ambiguousMessage(noun: "window", target: window, hits: hits))
            case .notFound:
                return .failure(ControlResolve.notFoundMessage(noun: "window", target: window))
            }
            guard let controller = gWindows[id] else {
                return .failure("window not open")
            }
            return .controller(controller)
        }
        switch req.cmd {
        case .sessionClose, .sessionDuplicate, .sessionSelect, .sessionGo, .sessionRename, .sessionReveal,
             .sessionMove, .sessionType,
             .sessionStatus, .sessionRestore, .sessionFlag, .sessionSeen,
             .sessionSplit, .sessionSplitClose, .sessionScratch, .sessionFocus,
             .sessionCopy, .sessionPaste, .sessionSelectAll, .sessionSearch,
             .sessionOverlayOpen, .sessionOverlayClose, .sessionOverlayResize, .sessionOverlayResult,
             .sessionOverlayCopy, .sessionOverlayText,
             .sessionHudOpen, .sessionHudUpdate, .sessionHudClose,
             .sessionBackground, .sessionResize, .sessionText, .sessionContext, .sessionSwap, .sessionLead, .notify,
             .fontInc, .fontDec, .fontReset:
            return routeOwningSession(req.target) ?? .controller(gController)
        case .workspaceRename, .workspaceDelete, .workspaceSelect, .workspaceMove, .workspaceFocus,
             .workspaceCollapse, .workspaceExpand:
            return routeOwningWorkspace(req.target) ?? .controller(gController)
        case .sessionNew:
            return routeOwningWorkspace(req.args?.workspace) ?? .controller(gController)
        case .tree, .eventsRead, .workspaceNew, .workspaceGo, .quick, .quickType, .quickText,
             .surfaceZoom, .surfaceCursor, .dashboard,
             .sidebar, .sidebarMode, .sidebarFlaggedLayout, .sidebarExpand, .sidebarCollapse, .sidebarWidth,
             .workspaceFilter, .hooksReload, .hooksList, .sessionOverlayJobRun,
             .windowNew, .windowList, .windowSelect, .windowGo, .windowClose, .windowRename, .windowDelete,
             .windowResize, .windowMove, .windowZoom, .windowFullscreen, .windowMinimize,
             .keymapReload, .keymapList, .configReload, .themeSet, .themeList,
             .pickOpen, .pickResult, .pickCancel, .askOpen, .askResult, .askCancel,
             .restoreClear, .restoreCapture, .restoreMode,
             .zmxList, .zmxPrune, .zmxKill, .zmxReset, .zmxTree, .zmxAttach, .zmxPresent, .version, .debugAppearance:
            return .controller(gController)
        }
    }

    @MainActor private static func explicitTarget(_ target: String?) -> String? {
        guard let target = target?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty, target != "active" else { return nil }
        return target
    }

    @MainActor private static func routeOwningSession(_ target: String?) -> ControllerRoute? {
        guard let target = explicitTarget(target) else { return nil }
        let controllers = gWindows.values
        let candidates = controllers.flatMap { $0.store.workspaces.flatMap { $0.sessions.map(\.id) } }
        switch ControlResolve.resolve(target, candidates: candidates, active: nil) {
        case .resolved(let id):
            return .controller(controllers.first { $0.store.session(withID: id) != nil })
        case .ambiguous(let hits):
            return .failure(ControlResolve.ambiguousMessage(noun: "session", target: target, hits: hits))
        case .notFound:
            return .failure(ControlResolve.notFoundMessage(noun: "session", target: target))
        }
    }

    @MainActor private static func routeOwningWorkspace(_ target: String?) -> ControllerRoute? {
        guard let target = explicitTarget(target) else { return nil }
        let controllers = gWindows.values
        let candidates = controllers.flatMap { $0.store.workspaces.map(\.id) }
        switch ControlResolve.resolve(target, candidates: candidates, active: nil) {
        case .resolved(let id):
            return .controller(controllers.first { $0.store.workspaces.contains { $0.id == id } })
        case .ambiguous(let hits):
            return .failure(ControlResolve.ambiguousMessage(noun: "workspace", target: target, hits: hits))
        case .notFound:
            return .failure(ControlResolve.notFoundMessage(noun: "workspace", target: target))
        }
    }

    private func readLine(_ conn: Int32) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            var pfd = pollfd(fd: conn, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Self.readTimeoutMS)
            if ready == 0 { return nil }
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard (pfd.revents & Int16(POLLIN)) != 0 else { return nil }
            let n = read(conn, &byte, 1)
            if n == 0 { return buffer.isEmpty ? nil : buffer }
            if n < 0 { return nil }
            if byte == 0x0A { return buffer }
            buffer.append(byte)
            if buffer.count > Self.maxLine { return nil }
        }
    }

    private func writeAll(_ conn: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = write(conn, base + offset, data.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }
}

final class ResponseBox: @unchecked Sendable {
    var value = ControlResponse(ok: false, error: "internal")
}
