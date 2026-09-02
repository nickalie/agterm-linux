import CGtk
import Foundation
import agtermCore

/// Linux host actions added by upstream protocol releases.
/// Kept beside the main adapter so that already-large compatibility surface stays within the lint limit.
@MainActor
extension AppController {
    func applySessionWatermark(_ id: UUID) {
        surfaces[id]?.applyWatermarkFromSession()
        splitSurfaces[id]?.applyWatermarkFromSession()
        scratchSurfaces[id]?.applyWatermarkFromSession()
    }

    func appIdentity() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(app: LinuxAppMetadata.identity))
    }

    /// `restore.capture`: fill every open pane's capture slot now, the read the app-exit close already
    /// does. Rerun only, like upstream: a fresh-shell launch ignores the slot, and live mode keeps the
    /// process instead of replaying it.
    func captureRestoreCommands() -> ControlResponse {
        let configured = linuxSettingsStore().load().effectiveRestoreMode
        guard configured == .rerun else {
            return ControlResponse(ok: false, error: "restore.capture requires rerun mode; configured restore mode is "
                + configured.rawValue)
        }
        let captured = gWindows.values.reduce(0) { $0 + $1.captureForegroundCommands() }
        // the command's whole claim is that the argv reached disk, so the ack waits on the write
        guard library.saveAllOpenChecked() else {
            return ControlResponse(ok: false, error: "captured \(captured) pane\(captured == 1 ? "" : "s") "
                + "but at least one window's save failed; failed windows keep their argv in memory until they "
                + "save successfully")
        }
        var result = ControlResult(count: captured)
        result.text = "captured \(captured) pane\(captured == 1 ? "" : "s")"
        return ControlResponse(ok: true, result: result)
    }

    func swapSessionPanes(_ target: String?, window: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let refusal = swapPanes(id) else {
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
            let error: String
            switch refusal {
            case .noSession: error = "session closed during swap"
            case .noSplit: error = "session has no split pane"
            case .slotNotRealized: error = "session not realized"
            case .roleNotMutable: error = "session panes do not support swapping"
            }
            return ControlResponse(ok: false, error: error)
        }
    }

    func setSessionContext(_ target: String?, window: String?, context: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard store.session(withID: id) != nil else {
                return ControlResponse(ok: false, error: "no such session: \(target ?? "active")")
            }
            _ = store.setContext(context, forSession: id) // no-op, no save and no event when unchanged
            updateTitle()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Moves the sidebar divider and echoes the STORED width, so a clamped request is distinguishable
    /// from an honored one.
    func setSidebarWidth(_ points: Double, window: String?) -> ControlResponse {
        store.setSidebarWidth(points)
        gtk_paned_set_position(splitView, Int32(store.sidebarWidth.rounded()))
        return ControlResponse(ok: true, result: ControlResult(sidebarWidth: store.sidebarWidth))
    }

    func readEvents(_ options: ControlEventReadOptions) -> ControlResponse {
        library.readEvents(options)
    }

    func setWorkspaceExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse {
        switch resolveWorkspaceResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            store.setWorkspaceExpanded(id, expanded: expanded)
            rebuildSidebar()
            syncSidebarSelection()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func setSessionRestore(_ target: String?, window: String?,
                           update: ControlSessionRestoreUpdate) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id): return applySessionRestore(id: id, update: update)
        }
    }

    private func applySessionRestore(id: UUID, update: ControlSessionRestoreUpdate) -> ControlResponse {
        guard let session = store.session(withID: id) else {
            return ControlResponse(ok: false, error: "no such session")
        }
        let pane: StatusPane
        if let token = update.paneID, !token.isEmpty {
            guard let resolved = session.paneRole(forToken: token) ?? update.pane else {
                return ControlResponse(ok: false, error: "unknown pane id: \(token)")
            }
            pane = resolved
        } else {
            pane = update.pane ?? .left
        }
        guard pane != .scratch else {
            return ControlResponse(ok: false, error: "the scratch terminal is never restored")
        }
        guard pane != .right || session.hasSplit else {
            return ControlResponse(ok: false, error: "session has no split")
        }

        let value: String?
        switch update.pin {
        case .pin(let command): value = command
        case .pinNone: value = ""
        case .unpin: value = nil
        }
        guard store.setRestoreCommand(value, pane: pane, forSession: id) else {
            return ControlResponse(
                ok: false,
                error: "failed to save the restore override, the previous value is still in effect"
            )
        }
        var result = ControlResult(id: id.uuidString)
        if case .pin = update.pin, linuxSettingsStore().load().restoreRunningCommand != true {
            result.text = "saved, but \"Restore running commands on restart\" is off, so the override will not run"
        }
        return ControlResponse(ok: true, result: result)
    }
}
