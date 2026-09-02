import Foundation
import agtermCore

/// Linux-local synchronous control dispatcher.
///
/// Upstream `agtermCore.ControlDispatcher` is async because macOS may need to realize SwiftUI/AppKit
/// surfaces before handling some commands.
/// The GTK control server already dispatches on the GTK main thread and needs a synchronous route from
/// its C socket callback, so the Linux fork keeps this adapter inside the Linux target instead of adding
/// Linux-driven API surface to `agtermCore`.
@MainActor
struct LinuxControlDispatcher {
    private let actions: AppController

    init(actions: AppController) {
        self.actions = actions
    }

    func dispatch(_ request: ControlRequest) -> ControlResponse? {
        switch request.cmd {
        case .tree:
            return actions.controlTree(window: request.args?.window)
        case .eventsRead:
            return dispatchEventsRead(request)
        case .sessionNew, .sessionDuplicate, .sessionSelect, .sessionGo, .sessionClose, .sessionRename, .sessionReveal,
                .sessionMove, .sessionFlag, .sessionSeen, .sessionStatus, .sessionRestore:
            return dispatchSessionCommand(request)
        case .sessionContext:
            return dispatchSessionContext(request)
        case .sessionSwap:
            return dispatchSwapPanes(request)
        case .sessionSplit, .sessionSplitClose, .sessionScratch, .sessionFocus, .sessionResize, .surfaceZoom,
                .surfaceCursor,
                .sessionCopy, .sessionPaste, .sessionSelectAll, .sessionOverlayOpen,
                .sessionOverlayClose, .sessionOverlayResize, .sessionOverlayResult,
                .sessionOverlayCopy, .sessionOverlayText,
                .sessionBackground, .sessionText:
            return dispatchSessionSurfaceCommand(request)
        case .sessionType, .quickType, .quickText:
            return nil
        case .workspaceNew, .workspaceSelect, .workspaceGo, .workspaceRename, .workspaceDelete,
                .workspaceMove, .workspaceFocus, .workspaceFilter, .workspaceCollapse, .workspaceExpand:
            return dispatchWorkspaceCommand(request)
        case .fontInc, .fontDec, .fontReset, .keymapReload, .keymapList, .configReload, .notify,
                .themeSet, .themeList, .sidebar, .sidebarMode, .sidebarExpand,
                .sidebarCollapse, .restoreClear:
            return dispatchAppCommand(request)
        case .version:
            return actions.appIdentity()
        case .restoreCapture:
            return actions.captureRestoreCommands()
        case .sidebarWidth:
            guard let points = request.args?.sidebarWidth, points.isFinite else {
                return ControlResponse(ok: false, error: "sidebar.width requires a width in points")
            }
            return actions.setSidebarWidth(points, window: request.args?.window)
        case .restoreMode, .zmxList, .zmxPrune, .zmxKill:
            return dispatchZmxCommand(request)
        case .windowRename, .windowResize, .windowMove, .windowZoom, .windowFullscreen, .windowMinimize:
            return dispatchWindowCommand(request)
        case .pickOpen, .pickResult, .pickCancel:
            return dispatchPickCommand(request)
        case .dashboard:
            return dispatchDashboard(request)
        default:
            return nil
        }
    }

    /// `session.context`, whose mode is required so a client sending both or neither is refused, and
    /// whose text validation lives on the model.
    private func dispatchSessionContext(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let context: String?
        switch args?.mode ?? "" {
        case "set":
            guard let text = args?.text else {
                return ControlResponse(ok: false, error: "session.context set requires text")
            }
            switch Session.validateContext(text) {
            case .valid(let value): context = value
            case .invalid(let message): return ControlResponse(ok: false, error: message)
            }
        case "clear":
            guard args?.text == nil else {
                return ControlResponse(ok: false, error: "session.context clear takes no text")
            }
            context = nil
        default:
            return ControlResponse(ok: false, error: "invalid context mode: \(args?.mode ?? "") (set|clear)")
        }
        return actions.setSessionContext(request.target, window: args?.window, context: context)
    }

    /// `session.swap`. Upstream awaits a readiness poll for a split still occupying its second slot; the
    /// GTK deck creates both surfaces synchronously in `syncSplit`, so there is nothing to wait for.
    private func dispatchSwapPanes(_ request: ControlRequest) -> ControlResponse {
        actions.swapSessionPanes(request.target, window: request.args?.window)
    }

    /// `restore.mode` and the local half of the `zmx` group. `zmx.tree`/`zmx.attach` never reach here:
    /// they run ssh, so the control server hands them to a worker thread of its own.
    private func dispatchZmxCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .restoreMode:
            guard let raw = request.args?.mode else { return actions.readRestoreMode() }
            // parsed strictly, unlike `RestoreMode`'s lossy decoder: a typo must not silently select
            // `none`, the one mode whose next launch reaps every detached daemon
            guard let mode = RestoreMode(rawValue: raw) else {
                return ControlResponse(ok: false, error: "invalid restore mode: \(raw)")
            }
            return actions.setRestoreMode(mode)
        case .zmxList:
            return actions.listZmxDaemons()
        case .zmxPrune:
            return actions.pruneZmxDaemons()
        case .zmxKill:
            // no `active` or left-pane default: this destroys a backend process, reaching claims no window
            // shows and every client attached to the daemon
            guard let target = request.target, !target.isEmpty else {
                return ControlResponse(ok: false, error: "zmx.kill requires an explicit --target")
            }
            guard let rawPane = request.args?.pane, let pane = ZmxPaneRole(controlName: rawPane) else {
                return ControlResponse(ok: false, error: "zmx.kill requires --pane left|right")
            }
            guard request.args?.force == true else {
                return ControlResponse(ok: false, error: "zmx.kill requires --force")
            }
            return actions.killZmxDaemon(target: target, window: request.args?.window, pane: pane)
        default:
            return ControlResponse(ok: false, error: "unexpected zmx command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchEventsRead(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let cursor: ControlEventCursor?
        switch (args?.run, args?.after) {
        case (nil, nil):
            cursor = nil
        case (.some, nil), (nil, .some):
            return ControlResponse(ok: false, error: ControlEventRequestError.cursorPair)
        case let (.some(runText), .some(afterText)):
            guard let run = UUID(uuidString: runText) else {
                return ControlResponse(ok: false, error: ControlEventRequestError.invalidRun)
            }
            guard let after = UInt64(afterText) else {
                return ControlResponse(ok: false, error: ControlEventRequestError.invalidCursor)
            }
            cursor = ControlEventCursor(run: run, after: after)
        }

        let limit = args?.limit ?? 100
        guard (1...1_000).contains(limit) else {
            return ControlResponse(ok: false, error: ControlEventRequestError.invalidLimit)
        }

        var parsedKinds = Set<ControlEventKind>()
        for field in args?.kinds ?? [] {
            for component in field.split(separator: ",", omittingEmptySubsequences: false) {
                let rawKind = component.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let kind = ControlEventKind(rawValue: rawKind) else {
                    return ControlResponse(ok: false, error: ControlEventRequestError.invalidKind(rawKind))
                }
                parsedKinds.insert(kind)
            }
        }
        let kinds: Set<ControlEventKind>? = parsedKinds.isEmpty ? nil : parsedKinds
        return actions.readEvents(ControlEventReadOptions(cursor: cursor, kinds: kinds, limit: limit))
    }

    private func dispatchPickCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .pickOpen:
            guard let items = request.args?.items else {
                return ControlResponse(ok: false, error: "pick.open requires items")
            }
            let allowCustom = request.args?.allowCustom == true
            // an empty list is a text prompt, which only makes sense when a custom answer is accepted
            guard !items.isEmpty || allowCustom else {
                return ControlResponse(ok: false, error: "pick.open requires at least one item")
            }
            guard items.count <= ControlPickItem.maxItems else {
                return ControlResponse(ok: false, error: "too many items (max \(ControlPickItem.maxItems))")
            }
            guard items.allSatisfy({ !$0.label.isEmpty }) else {
                return ControlResponse(ok: false, error: "pick item label must not be empty")
            }
            var ids = Set<String>()
            guard items.allSatisfy({ ids.insert($0.id).inserted }) else {
                return ControlResponse(ok: false, error: "pick item ids must be unique")
            }
            guard items.allSatisfy({
                !containsControlCharacters($0.label)
                    && $0.subtitle.map { !containsControlCharacters($0) } != false
            }) else {
                return ControlResponse(ok: false, error: "item text must not contain control characters")
            }
            return actions.openPick(
                PendingPick(
                    id: UUID().uuidString,
                    items: items,
                    prompt: request.args?.prompt,
                    query: request.args?.query,
                    allowCustom: allowCustom
                ),
                window: request.args?.window,
                follow: request.args?.follow == true
            )
        case .pickResult:
            guard let target = request.target else {
                return ControlResponse(ok: false, error: "pick.result requires a pick id")
            }
            return actions.pickResult(target, window: request.args?.window)
        case .pickCancel:
            guard let target = request.target else {
                return ControlResponse(ok: false, error: "pick.cancel requires a pick id")
            }
            return actions.cancelPick(target, window: request.args?.window)
        default:
            preconditionFailure("unexpected pick command: \(request.cmd.rawValue)")
        }
    }

    private func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    private func dispatchSessionCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionNew:
            let args = request.args
            if args?.after != nil, args?.before != nil {
                return ControlResponse(ok: false, error: "use either --after or --before, not both")
            }
            if args?.after != nil || args?.before != nil, args?.workspace != nil || args?.workspaceName != nil {
                return ControlResponse(ok: false, error: "session.new takes --after/--before or a workspace, not both")
            }
            if args?.workspace != nil, args?.workspaceName != nil {
                return ControlResponse(ok: false, error: "use either --workspace or --workspace-name, not both")
            }
            if args?.createWorkspace == true, args?.workspaceName == nil {
                return ControlResponse(ok: false, error: "--create-workspace requires --workspace-name")
            }
            if args?.wait == true, args?.command == nil {
                return ControlResponse(ok: false, error: "--wait requires --command")
            }
            return actions.createSession(ControlSessionCreateOptions(
                window: args?.window,
                cwd: args?.cwd,
                workspace: args?.workspace,
                workspaceName: args?.workspaceName,
                createWorkspace: args?.createWorkspace,
                command: args?.command,
                wait: args?.wait,
                name: args?.name,
                after: args?.after,
                before: args?.before,
                noSelect: args?.noSelect == true
            ))
        case .sessionDuplicate:
            return actions.duplicateSession(request.target, window: request.args?.window)
        case .sessionSelect:
            return actions.selectSession(request.target, window: request.args?.window)
        case .sessionGo:
            guard let dir = (request.args?.to).flatMap(SessionNavigation.init(wire:)) else {
                return ControlResponse(ok: false, error: "session.go requires --to next|prev|first|last|next-attention|prev-attention")
            }
            return actions.goSession(window: request.args?.window, direction: dir)
        case .sessionClose:
            if let targets = request.args?.targets {
                return actions.closeSessions(targets, window: request.args?.window)
            }
            return actions.closeSession(request.target, window: request.args?.window)
        case .sessionRename:
            guard let name = request.args?.name else {
                return ControlResponse(ok: false, error: "session.rename requires a name")
            }
            return actions.renameSession(request.target, window: request.args?.window, name: name)
        case .sessionReveal:
            return actions.revealSession(request.target, window: request.args?.window)
        case .sessionMove:
            let args = request.args
            if args?.after != nil, args?.before != nil {
                return ControlResponse(ok: false, error: "use either --after or --before, not both")
            }
            if let anchor = args?.after ?? args?.before {
                if args?.to != nil {
                    return ControlResponse(ok: false, error: "session.move takes --after/--before or --to, not both")
                }
                if args?.workspace != nil {
                    return ControlResponse(ok: false, error: "session.move takes --after/--before or a workspace, not both")
                }
                let move = ControlSessionMove.place(anchor: anchor, after: args?.after != nil)
                if let targets = args?.targets {
                    return actions.moveSessions(targets, window: args?.window, move: move)
                }
                return actions.moveSession(request.target, window: args?.window, move: move)
            }
            if args?.to != nil && args?.workspace != nil {
                return ControlResponse(ok: false, error: "session.move takes either --to or a workspace, not both")
            }
            if let to = args?.to {
                if args?.targets != nil {
                    return ControlResponse(
                        ok: false,
                        error: "session.move --target can be repeated only with a workspace or --after/--before"
                    )
                }
                guard let direction = ReorderDirection(rawValue: to) else {
                    return ControlResponse(ok: false, error: "session.move --to must be up|down|top|bottom")
                }
                return actions.moveSession(request.target, window: args?.window, move: .reorder(direction))
            }
            guard let workspace = args?.workspace else {
                return ControlResponse(ok: false, error: "session.move requires --to or a workspace")
            }
            let move = ControlSessionMove.workspace(workspace)
            if let targets = args?.targets {
                return actions.moveSessions(targets, window: args?.window, move: move)
            }
            return actions.moveSession(request.target, window: args?.window, move: move)
        case .sessionFlag:
            return actions.setSessionFlag(request.target, window: request.args?.window, mode: request.args?.mode)
        case .sessionSeen:
            return actions.markSessionSeen(request.target, window: request.args?.window)
        case .sessionStatus:
            guard let status = AgentStatus(rawValue: request.args?.status ?? "") else {
                return ControlResponse(ok: false, error: "invalid status")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color (expected #rrggbb)")
            }
            var pane: StatusPane?
            if let rawPane = request.args?.pane {
                guard let parsed = StatusPane(rawValue: rawPane) else {
                    return ControlResponse(ok: false, error: "--pane must be left, right, or scratch")
                }
                pane = parsed
            }
            let update = ControlSessionStatusUpdate(status: status, blink: request.args?.blink,
                                                    autoReset: request.args?.autoReset,
                                                    sound: request.args?.sound, color: request.args?.color,
                                                    pane: pane, paneID: request.args?.paneID)
            return actions.setSessionStatus(request.target, window: request.args?.window, update: update)
        case .sessionRestore:
            return dispatchSessionRestore(request)
        default:
            preconditionFailure("unexpected session command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchSessionRestore(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let pin: ControlRestoreOverride
        switch args?.mode ?? "" {
        case "set":
            guard let command = args?.command else {
                return ControlResponse(ok: false, error: "session.restore set requires a command")
            }
            guard !command.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                return ControlResponse(ok: false, error: "command must not contain control characters")
            }
            guard command.utf8.count <= ControlRestoreOverride.maxCommandBytes else {
                return ControlResponse(ok: false,
                                       error: "command too long (max \(ControlRestoreOverride.maxCommandBytes) bytes)")
            }
            pin = .pin(command)
        case "none":
            pin = .pinNone
        case "clear":
            pin = .unpin
        default:
            return ControlResponse(ok: false,
                                   error: "invalid restore mode: \(args?.mode ?? "") (set|none|clear)")
        }
        let pane: StatusPane?
        if let rawPane = args?.pane {
            guard let parsed = StatusPane(rawValue: rawPane) else {
                return ControlResponse(ok: false, error: "--pane must be left, right, or scratch")
            }
            pane = parsed
        } else {
            pane = nil
        }
        return actions.setSessionRestore(request.target, window: args?.window,
                                         update: ControlSessionRestoreUpdate(
                                            pin: pin, pane: pane, paneID: args?.paneID))
    }

    private func dispatchWorkspaceCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .workspaceNew:
            return actions.createWorkspace(window: request.args?.window, name: request.args?.name,
                                           collapsed: request.args?.collapsed ?? false)
        case .workspaceSelect:
            return actions.selectWorkspace(request.target, window: request.args?.window)
        case .workspaceGo:
            guard let dir = (request.args?.to).flatMap(WorkspaceNavigation.init(wire:)) else {
                return ControlResponse(ok: false, error: "workspace.go requires --to next|prev")
            }
            return actions.goWorkspace(window: request.args?.window, direction: dir)
        case .workspaceRename:
            guard let name = request.args?.name?.linuxTrimmedOrNil else {
                return ControlResponse(ok: false, error: "workspace.rename requires a name")
            }
            return actions.renameWorkspace(request.target, window: request.args?.window, name: name)
        case .workspaceDelete:
            return actions.deleteWorkspace(request.target, window: request.args?.window)
        case .workspaceMove:
            guard let to = request.args?.to else {
                return ControlResponse(ok: false, error: "workspace.move requires --to")
            }
            guard let direction = ReorderDirection(rawValue: to) else {
                return ControlResponse(ok: false, error: "workspace.move --to must be up|down|top|bottom")
            }
            return actions.moveWorkspace(request.target, window: request.args?.window, direction: direction)
        case .workspaceFocus:
            let rawMode = request.args?.mode ?? ControlWorkspaceFocusMode.toggle.rawValue
            guard let mode = ControlWorkspaceFocusMode(rawValue: rawMode) else {
                return ControlResponse(ok: false,
                    error: "invalid workspace.focus mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.focusWorkspace(request.target, window: request.args?.window, mode: mode)
        case .workspaceFilter:
            guard let mode = ControlToggleMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false,
                    error: "invalid workspace filter mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setWorkspaceFilter(window: request.args?.window, mode: mode)
        case .workspaceCollapse:
            return actions.setWorkspaceExpansion(request.target, window: request.args?.window, expanded: false)
        case .workspaceExpand:
            return actions.setWorkspaceExpansion(request.target, window: request.args?.window, expanded: true)
        default:
            preconditionFailure("unexpected workspace command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchSessionSurfaceCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionSplit:
            let axis: SplitAxis?
            if let raw = request.args?.axis {
                guard let parsed = SplitAxis(rawValue: raw) else {
                    return ControlResponse(ok: false, error: "invalid split axis: \(raw) (vertical|horizontal)")
                }
                axis = parsed
            } else {
                axis = nil
            }
            return actions.splitSession(request.target, window: request.args?.window,
                                        mode: request.args?.mode, axis: axis)
        case .sessionSplitClose:
            return actions.closeSessionSplit(request.target, window: request.args?.window)
        case .sessionScratch:
            return actions.scratchSession(request.target, window: request.args?.window, mode: request.args?.mode,
                                          command: request.args?.command)
        case .sessionFocus:
            return actions.focusSessionPane(request.target, window: request.args?.window, pane: request.args?.pane)
        case .sessionResize:
            switch (request.args?.ratio, request.args?.ratioDelta) {
            case (nil, nil):
                return ControlResponse(ok: false, error: "session.resize requires --split-ratio, --grow-left, or --grow-right")
            case (.some, .some):
                return ControlResponse(ok: false, error: "session.resize: --split-ratio is mutually exclusive with --grow-left/--grow-right")
            case (.some(let ratio), nil):
                return actions.resizeSplit(request.target, window: request.args?.window, resize: .ratio(ratio))
            case (nil, .some(let delta)):
                return actions.resizeSplit(request.target, window: request.args?.window, resize: .delta(delta))
            }
        case .sessionCopy:
            return actions.copySessionSelection(request.target, window: request.args?.window)
        case .sessionPaste:
            return actions.pasteSession(request.target, window: request.args?.window)
        case .sessionSelectAll:
            return actions.selectAllSession(request.target, window: request.args?.window)
        case .surfaceZoom:
            guard let mode = ControlToggleMode.parse(request.args?.mode, on: "show", off: "hide") else {
                return ControlResponse(ok: false,
                                       error: "invalid surface.zoom mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSurfaceZoom(request.target, window: request.args?.window, mode: mode)
        case .sessionOverlayOpen:
            guard let command = request.args?.command, !command.isEmpty else {
                return ControlResponse(ok: false, error: "session.overlay.open requires a command")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            let openPane: OverlayPane?
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let parsed): openPane = parsed
            }
            if openPane != nil, request.args?.sizePercent != nil {
                return ControlResponse(ok: false, error: PaneOverlayError.sizePercentConflict)
            }
            return actions.openSessionOverlay(request.target, window: request.args?.window,
                                              options: ControlSessionOverlayOpenOptions(
                                                command: command,
                                                cwd: request.args?.cwd,
                                                wait: request.args?.wait ?? false,
                                                sizePercent: request.args?.sizePercent,
                                                backgroundColor: request.args?.color,
                                                follow: request.args?.follow ?? false,
                                                pane: openPane
                                              ))
        case .sessionOverlayClose:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.closeSessionOverlay(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlayResize:
            // pane overlays are always full, so ANY `--pane` is refused here, valid spelling or not.
            if request.args?.pane != nil {
                return ControlResponse(ok: false, error: PaneOverlayError.resizeUnsupported)
            }
            let wantsFull = request.args?.full == true
            let percent = request.args?.sizePercent
            if wantsFull, percent != nil {
                return ControlResponse(ok: false, error: "session.overlay.resize: --full is mutually exclusive with --size-percent")
            }
            if !wantsFull, percent == nil {
                return ControlResponse(ok: false, error: "session.overlay.resize requires --size-percent or --full")
            }
            if let percent, !(1...100).contains(percent) {
                return ControlResponse(ok: false, error: "session.overlay.resize: --size-percent must be 1...100")
            }
            return actions.resizeSessionOverlay(request.target, window: request.args?.window,
                                                sizePercent: wantsFull ? nil : percent)
        case .sessionOverlayResult:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.sessionOverlayResult(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionBackground:
            return dispatchSessionBackground(request)
        case .surfaceCursor:
            return actions.readSurfaceCursor(request.target, window: request.args?.window)
        case .sessionOverlayCopy:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.copySessionOverlaySelection(request.target, window: request.args?.window,
                                                           pane: pane)
            }
        case .sessionOverlayText:
            return dispatchSessionOverlayText(request)
        case .sessionText:
            return dispatchSessionText(request)
        default:
            preconditionFailure("unexpected session surface command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchAppCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .fontInc:
            return actions.font(request.target, window: request.args?.window, pane: request.args?.pane,
                                action: FontBindingAction.increase)
        case .fontDec:
            return actions.font(request.target, window: request.args?.window, pane: request.args?.pane,
                                action: FontBindingAction.decrease)
        case .fontReset:
            return actions.font(request.target, window: request.args?.window, pane: request.args?.pane,
                                action: FontBindingAction.reset)
        case .keymapReload:
            return actions.reloadKeymap()
        case .keymapList:
            return actions.listKeymap()
        case .configReload:
            return actions.reloadGhosttyConfig()
        case .notify:
            guard let body = request.args?.body, !body.isEmpty else {
                return ControlResponse(ok: false, error: "notify requires a body")
            }
            return actions.sendNotification(request.target, window: request.args?.window,
                                            title: request.args?.title, body: body)
        case .themeSet:
            return actions.setTheme(args: request.args)
        case .themeList:
            return actions.listThemes()
        case .sidebar:
            guard let mode = ControlToggleMode.parse(request.args?.mode, on: "show", off: "hide") else {
                return ControlResponse(ok: false, error: "invalid sidebar mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSidebarVisibility(mode)
        case .sidebarMode:
            guard let mode = ControlSidebarViewMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false, error: "invalid sidebar mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSidebarViewMode(mode)
        case .sidebarExpand:
            return actions.expandSidebar(window: request.args?.window)
        case .sidebarCollapse:
            return actions.collapseSidebar(window: request.args?.window)
        case .restoreClear:
            return actions.clearRestoreCommands()
        default:
            preconditionFailure("unexpected app command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchSessionBackground(_ request: ControlRequest) -> ControlResponse {
        if let fit = request.args?.fit, !WatermarkConfig.isValidFit(fit) {
            return ControlResponse(ok: false, error: "invalid fit: \(fit) (contain|cover|stretch|none)")
        }
        if let position = request.args?.position, !WatermarkConfig.isValidPosition(position) {
            return ControlResponse(ok: false, error: "invalid position: \(position)")
        }
        if let opacity = request.args?.opacity, !WatermarkConfig.isValidOpacity(opacity) {
            return ControlResponse(ok: false, error: "invalid opacity: \(opacity) (0.0-1.0)")
        }
        let watermark: BackgroundWatermark?
        switch request.args?.mode {
        case "image":
            guard let path = request.args?.path, !path.isEmpty else {
                return ControlResponse(ok: false, error: "session.background image requires a path")
            }
            guard WatermarkConfig.isValidImagePath(path) else {
                return ControlResponse(ok: false, error: "image path must not contain control characters")
            }
            watermark = BackgroundWatermark(kind: .image, imagePath: path, opacity: request.args?.opacity,
                                            fit: request.args?.fit.flatMap(BackgroundWatermark.Fit.init(rawValue:)),
                                            position: request.args?.position.flatMap(BackgroundWatermark.Position.init(rawValue:)),
                                            repeats: request.args?.repeats)
        case "text":
            guard let text = request.args?.text, !text.isEmpty else {
                return ControlResponse(ok: false, error: "session.background text requires text")
            }
            guard text.count <= WatermarkConfig.maxTextLength else {
                return ControlResponse(ok: false,
                                       error: "session.background text too long (max \(WatermarkConfig.maxTextLength) characters)")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            watermark = BackgroundWatermark(kind: .text, text: text, colorHex: request.args?.color,
                                            opacity: request.args?.opacity,
                                            fit: request.args?.fit.flatMap(BackgroundWatermark.Fit.init(rawValue:)),
                                            position: request.args?.position.flatMap(BackgroundWatermark.Position.init(rawValue:)))
        case "color":
            guard let color = request.args?.color, !color.isEmpty else {
                return ControlResponse(ok: false, error: "session.background color requires a color")
            }
            guard WatermarkConfig.isValidColorHex(color) else {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            watermark = BackgroundWatermark(kind: .color, colorHex: color)
        case "clear", .none:
            watermark = nil
        default:
            return ControlResponse(ok: false,
                                   error: "invalid background mode: \(request.args?.mode ?? "") (image|text|color|clear)")
        }
        return actions.setSessionBackground(request.target, window: request.args?.window,
                                            options: ControlSessionBackgroundOptions(watermark: watermark))
    }

    /// How much of a buffer a read covers, or the rejection its arm returns as-is. Shared by `session.text`
    /// and `session.overlay.text` so the two cannot drift; an unchecked nonpositive `lines` would fall
    /// through to the full buffer.
    private enum BufferExtent {
        case extent(all: Bool, lines: Int?)
        case rejected(ControlResponse)
    }

    private func parseBufferExtent(_ args: ControlArgs?) -> BufferExtent {
        let all = args?.all ?? false
        let lines = args?.lines
        if all, lines != nil {
            return .rejected(ControlResponse(ok: false, error: "use either --all or --lines, not both"))
        }
        if let lines, lines <= 0 {
            return .rejected(ControlResponse(ok: false, error: "--lines must be greater than 0"))
        }
        return .extent(all: all, lines: lines)
    }

    private func dispatchSessionText(_ request: ControlRequest) -> ControlResponse {
        switch parseBufferExtent(request.args) {
        case .rejected(let response): return response
        case .extent(let all, let lines):
            return actions.readSessionText(request.target, window: request.args?.window,
                                           options: ControlSessionTextOptions(pane: request.args?.pane,
                                                                              all: all,
                                                                              lines: lines))
        }
    }

    /// The extent is checked before the pane, so the same flags produce the same first error here and on
    /// `session.text`.
    private func dispatchSessionOverlayText(_ request: ControlRequest) -> ControlResponse {
        let all: Bool
        let lines: Int?
        switch parseBufferExtent(request.args) {
        case .rejected(let response): return response
        case .extent(let parsedAll, let parsedLines):
            all = parsedAll
            lines = parsedLines
        }
        switch parseOverlayPane(request.args?.pane) {
        case .rejected(let response): return response
        case .pane(let pane):
            return actions.readSessionOverlayText(request.target, window: request.args?.window,
                                                  options: ControlSessionOverlayTextOptions(pane: pane,
                                                                                            all: all,
                                                                                            lines: lines))
        }
    }

    private func dispatchWindowCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .windowRename:
            guard let name = request.args?.name?.linuxTrimmedOrNil else {
                return ControlResponse(ok: false, error: "window.rename requires a name")
            }
            return actions.windowRename(request.target, name: name)
        case .windowResize:
            guard let width = request.args?.width, let height = request.args?.height,
                  width > 0, height > 0 else {
                return ControlResponse(ok: false, error: "window.resize requires positive width and height")
            }
            return actions.windowResize(request.target, width: width, height: height)
        case .windowMove:
            guard let x = request.args?.x, let y = request.args?.y else {
                return ControlResponse(ok: false, error: "window.move requires x and y")
            }
            return actions.windowMove(request.target, x: x, y: y, display: request.args?.display)
        case .windowZoom:
            return actions.windowZoom(request.target)
        case .windowFullscreen:
            return actions.windowFullscreen(request.target)
        case .windowMinimize:
            guard let mode = ControlToggleMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false,
                                       error: "invalid minimize mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.windowMinimizeSync(request.target, mode: mode)
        default:
            preconditionFailure("unexpected window command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchDashboard(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let targets = args?.targets ?? []
        let fontSize = args?.fontSize
        let autoSize = args?.autoSize ?? false
        let mru = args?.mru ?? false
        if args?.close == true {
            guard targets.isEmpty, !mru, fontSize == nil, !autoSize else {
                return ControlResponse(ok: false,
                                       error: "dashboard --close takes no ids, --mru, or font options")
            }
            return actions.setDashboard(targets: [], window: args?.window, close: true,
                                        fontMode: .untouched, mru: false)
        }
        if fontSize != nil, autoSize {
            return ControlResponse(ok: false,
                                   error: "dashboard: --font-size is mutually exclusive with --auto-size")
        }
        if let fontSize, !fontSize.isFinite || fontSize <= 0 {
            return ControlResponse(ok: false, error: "dashboard --font-size must be a positive number")
        }
        let mode: DashboardFontMode = autoSize ? .auto : (fontSize.map(DashboardFontMode.fixed) ?? .untouched)
        if mru {
            guard targets.isEmpty else {
                return ControlResponse(ok: false,
                                       error: "dashboard --mru cannot be combined with explicit session ids")
            }
            return actions.setDashboard(targets: [], window: args?.window, close: false,
                                        fontMode: mode, mru: true)
        }
        guard !targets.isEmpty else {
            return ControlResponse(ok: false, error: "dashboard requires at least one session id")
        }
        // grammar only: a malformed pane suffix fails the command here, while a well-formed ref that
        // resolves to nothing is app-side and joins the `unresolved` note instead.
        if let malformed = targets.first(where: { DashboardTarget(rawValue: $0) == nil }) {
            return ControlResponse(
                ok: false,
                error: "dashboard: invalid session id '\(malformed)' — use <id>, <id>:left, or <id>:right")
        }
        return actions.setDashboard(targets: targets, window: args?.window, close: false,
                                    fontMode: mode, mru: false)
    }

    private enum OverlayPaneSelection {
        case pane(OverlayPane?)
        case rejected(ControlResponse)
    }

    /// The `session.overlay` `--pane` selector: nil when absent, the parsed pane when the spelling is
    /// accepted, and the pinned rejection otherwise. Mirrors the upstream dispatcher's `parseOverlayPane`.
    private func parseOverlayPane(_ raw: String?) -> OverlayPaneSelection {
        guard let raw else { return .pane(nil) }
        guard let parsed = OverlayPane(controlName: raw) else {
            return .rejected(ControlResponse(ok: false, error: PaneOverlayError.invalidPane))
        }
        return .pane(parsed)
    }
}
