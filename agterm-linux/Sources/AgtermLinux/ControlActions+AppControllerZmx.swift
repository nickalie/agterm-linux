import Foundation
import agtermCore

/// The `restore.mode` and `zmx` command group on Linux. Every answer joins three things only a running
/// instance holds: the live stores, the persisted pane claims, and the daemons zmx reports.
@MainActor
extension AppController {
    func readRestoreMode() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(restore: restoreStatus()))
    }

    func setRestoreMode(_ mode: RestoreMode) -> ControlResponse {
        guard persistRestoreMode(mode) else {
            return ControlResponse(ok: false,
                                   error: "could not save the restore mode; the previous one is still in effect")
        }
        rebuildSettings(page: .general)
        return ControlResponse(ok: true, result: ControlResult(restore: restoreStatus()))
    }

    /// What settings hold, what this launch asked for, and what it got.
    func restoreStatus() -> ControlRestoreStatus {
        ControlRestoreStatus(configured: linuxSettingsStore().load().effectiveRestoreMode,
                             requestedAtLaunch: gZmx.requestedMode, active: gZmx.activeMode,
                             unavailableReason: gZmx.liveUnavailableReason)
    }

    /// Observed daemons joined against the panes that claim them. A failed listing is an ERROR rather than
    /// an empty inventory: an empty namespace is a real answer and must not read the same as not looking.
    func listZmxDaemons() -> ControlResponse {
        switch inventory() {
        case .failure(let response): return response
        case .success(let result):
            let payload = ControlZmxInventory(restore: restoreStatus(), result: result,
                                              endpoint: gZmx.client.endpoint)
            return ControlResponse(ok: true, result: ControlResult(zmx: payload))
        }
    }

    /// Kill the daemons the inventory shows unclaimed and detached.
    ///
    /// Checked and revalidated, never atomic: pinned zmx has no kill-if-detached, so this re-lists
    /// immediately before mutating and drops any candidate that gained a client in between.
    func pruneZmxDaemons() -> ControlResponse {
        switch inventory() {
        case .failure(let response): return response
        case .success(let result):
            guard let candidates = ZmxPrunePolicy.namesToPrune(result) else {
                return ControlResponse(ok: false, error: ControlZmxError.incompleteInventory)
            }
            guard !candidates.isEmpty else {
                return ControlResponse(ok: true, result: ControlResult(text: "no orphan daemons", affected: 0))
            }
            guard let recheck = gZmx.client.listSessions() else {
                return ControlResponse(ok: false,
                                       error: "could not re-read the zmx session list before pruning")
            }
            let stillDetached = Set(recheck.filter { $0.clients == 0 }.map(\.name))
            let names = candidates.filter { stillDetached.contains($0) }
            guard !names.isEmpty else {
                return ControlResponse(ok: true,
                                       result: ControlResult(text: "no orphan daemons left to prune", affected: 0))
            }
            let outcomes = gZmx.client.killObservedOrphan(names: names)
            return ControlResponse(ok: true,
                                   result: ControlResult(text: Self.pruneReport(outcomes),
                                                         affected: outcomes.filter { $0.value == .killed }.count))
        }
    }

    /// Destroy one pane's daemon, then drive the model transition the pane's own exit would have.
    ///
    /// Resolution runs against the INVENTORY, not the window stores: this command deliberately reaches
    /// closed and unindexed claims no window shows.
    func killZmxDaemon(target: String, window: String?, pane: ZmxPaneRole) -> ControlResponse {
        // `active` is refused on BOTH selectors rather than resolved: nothing about this destruction may
        // fall back to whatever happens to be in front of the user
        guard target != "active" else {
            return ControlResponse(ok: false, error: "zmx.kill needs a session id; 'active' is not accepted")
        }
        guard window != "active" else {
            return ControlResponse(ok: false, error: "zmx.kill needs a window id; 'active' is not accepted")
        }
        let result: ZmxInventoryResult
        switch inventory() {
        case .failure(let response): return response
        case .success(let joined): result = joined
        }
        var owned = result.rows.filter { $0.claim?.pane == pane }
        if let window, !window.isEmpty {
            let windowIDs = Array(Set(result.rows.compactMap { $0.claim?.windowID }))
            guard case .resolved(let windowID) = ControlResolve.resolve(window, candidates: windowIDs,
                                                                        active: nil) else {
                return ControlResponse(ok: false, error: "no such window: \(window)")
            }
            owned = owned.filter { $0.claim?.windowID == windowID }
        }
        let candidates = owned.compactMap { $0.claim?.sessionID }
        guard case .resolved(let sessionID) = ControlResolve.resolve(target, candidates: candidates,
                                                                     active: nil),
              let row = owned.first(where: { $0.claim?.sessionID == sessionID }), let claim = row.claim else {
            return ControlResponse(ok: false, error: "no \(pane.rawValue) pane daemon for session \(target)")
        }
        if let refusal = ControlZmxError.killRefusal(row) {
            return ControlResponse(ok: false, error: refusal)
        }
        // only an exact confirmation may close a live pane: zmx exits zero after unlinking a socket it
        // could not reach, so trusting the status would report a kill and leave the daemon running
        switch gZmx.client.killConfirmed(name: row.daemon) {
        case .killed: break
        case .staleSocket:
            return ControlResponse(ok: false, error: "\(row.daemon) did not confirm the kill; zmx cleaned "
                + "up a stale socket and the daemon may still be running")
        case .failed(let reason):
            return ControlResponse(ok: false, error: "could not kill \(row.daemon): \(reason)")
        }
        applyKilledPaneExit(claim)
        return ControlResponse(ok: true, result: ControlResult(id: claim.sessionID.uuidString,
                                                               text: "killed \(row.daemon)",
                                                               pane: claim.pane.rawValue))
    }

    private func inventory() -> ResolveResponse<ZmxInventoryResult> {
        guard let observed = gZmx.client.listSessions() else {
            return .failure(ControlResponse(ok: false, error: "could not read the zmx session list"))
        }
        let walk = library.paneClaims()
        return .success(ZmxInventory.join(observed: observed, claims: walk.claims,
                                          inventoryComplete: walk.complete))
    }

    /// Reports per daemon rather than a bare count: a stale-socket cleanup is not a kill, and a caller that
    /// cannot tell the two apart would believe a live unresponsive daemon had gone.
    private static func pruneReport(_ outcomes: [String: LinuxZmxClient.KillOutcome]) -> String {
        outcomes.keys.sorted().map { name in
            switch outcomes[name] {
            case .killed: return "killed \(name)"
            case .staleSocket: return "\(name): cleaned up a stale socket, the daemon may still be running"
            case .failed(let reason): return "\(name): not killed (\(reason))"
            case nil: return "\(name): no result"
            }
        }
        .joined(separator: "; ")
    }

    /// Runs the pane's exit transition for a daemon this command already destroyed. The killed identity is
    /// excluded from the finalizer, or the teardown would ask zmx to kill a name that is gone and, on a
    /// session close, reach the sibling.
    private func applyKilledPaneExit(_ claim: ZmxPaneClaim) {
        guard let controller = gWindows[claim.windowID] else { return }
        let surface = claim.pane == .left ? controller.surfaces[claim.sessionID]
            : controller.splitSurfaces[claim.sessionID]
        // `backedByZmx` is what makes this surface a CLIENT of the daemon just killed: on a requested-live
        // fallback the reap preserves claimed daemons while the pane gets a plain shell, and without this
        // the kill would close a live pane that never attached to the thing it destroyed
        guard let surface, surface.backedByZmx, surface.claimProcessExit() else { return }
        if claim.pane == .left {
            controller.closePrimaryPane(claim.sessionID, alreadyFinalized: claim.paneIdentity)
        } else {
            controller.closeSplitPane(claim.sessionID, alreadyFinalized: claim.paneIdentity)
        }
    }
}
