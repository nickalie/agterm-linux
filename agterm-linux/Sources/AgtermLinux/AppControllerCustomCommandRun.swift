import Foundation
import agtermCore

/// Which pane a custom command names as `$AGT_PANE`, mirroring upstream `CustomCommandRunner`.
enum LinuxCommandPane {
    /// An overlay names the surface underneath it: the scratch whenever one is up, since a session-wide
    /// overlay sits above it and it covers a pane overlay; else the covered pane, or the focused one for a
    /// session-wide overlay.
    static func underOverlay(scratchActive: Bool, overlayPane: OverlayPane?,
                             focusedPane: OverlayPane) -> CommandContext.Pane {
        if scratchActive { return .scratch }
        return (overlayPane ?? focusedPane) == .right ? .right : .left
    }
}

@MainActor
extension AppController {
    /// How long a custom command's failure panel stays up (upstream `failureHudSeconds`).
    static let failureHudSeconds: TimeInterval = 10

    /// The session, pane, and selection source of a chord fired from `surface`; nil for a surface that is
    /// nobody's pane (the quick terminal), which takes the active-session path.
    private func commandOrigin(of surface: GhosttySurface)
        -> (session: Session, pane: CommandContext.Pane, selection: GhosttySurface)? {
        let roles: [([UUID: GhosttySurface], CommandContext.Pane)] = [
            (surfaces, .left), (splitSurfaces, .right), (scratchSurfaces, .scratch)
        ]
        for (map, pane) in roles {
            if let id = map.first(where: { $0.value === surface })?.key, let session = store.session(withID: id) {
                return (session, pane, surface)
            }
        }
        for session in store.workspaces.flatMap(\.sessions) {
            let overlayPane = paneOverlaySurfaces[session.id]?.first(where: { $0.value === surface })?.key
            guard overlayPane != nil || overlaySurfaces[session.id] === surface else { continue }
            let pane = LinuxCommandPane.underOverlay(scratchActive: session.scratchActive, overlayPane: overlayPane,
                                                     focusedPane: session.focusedPane)
            // an overlay reads its OWN selection but names the pane underneath
            return (session, pane, surface)
        }
        return nil
    }

    func runCustomCommand(_ cmd: CustomCommand, origin: GhosttySurface? = nil,
                          allowSessionless: Bool = false) {
        // the OWNING session first: sidebar selection moves ahead of the asynchronous focus handoff, and in
        // that gap a chord fired from a scratch or split pane would build its context from the active
        // session instead, so every $AGT_SESSION_* value described a pane the user was not looking at
        let resolved = origin.flatMap(commandOrigin(of:))
        let s = resolved?.session ?? store.activeSession
        guard s != nil || allowSessionless else { return }
        if s == nil, CommandContext.referencesSessionScopedContext(cmd.command) {
            showToast("\(cmd.name) needs an active session")
            return
        }
        let workspace = s.flatMap { store.workspace(forSession: $0.id) }
        let pane: CommandContext.Pane
        let selectionSurface: GhosttySurface?
        if let resolved {
            (pane, selectionSurface) = (resolved.pane, resolved.selection)
        } else if let s, s.splitFocused, let split = splitSurfaces[s.id] {
            (pane, selectionSurface) = (.right, split)
        } else {
            (pane, selectionSurface) = (.left, s.flatMap { surfaces[$0.id] })
        }
        let context = CommandContext(sessionID: s?.id.uuidString ?? "", sessionName: s?.displayName ?? "",
                                     sessionPWD: s?.effectiveCwd ?? "",
                                     sessionHost: TerminalText.sanitized(s?.remoteHost ?? ""),
                                     workspaceID: workspace?.id.uuidString ?? "",
                                     workspaceName: workspace?.name ?? "",
                                     windowID: windowID.uuidString,
                                     windowName: gLibrary.windows.first(where: { $0.id == windowID })?.name ?? "",
                                     pane: pane, paneID: s?.paneToken(for: pane) ?? "",
                                     selection: selectionSurface?.readSelection() ?? "",
                                     socket: gControlServer.boundSocketPath ?? "")
        let controllerOrigin = customCommandOrigin
        let launcher = controllerOrigin.launcher
        // every spawn path counts, so the popover's most-used section sees chord and palette runs too
        Self.customCommandUsage.record(cmd)
        // the reported cwd can be the far side's, which need not exist here; the context keeps it raw
        let cwd = s?.localWorkingDirectory(reported: context.sessionPWD, homeDirectory: Self.homeCwd)
        let sessionID = s?.id
        LinuxCustomCommandProcess.launch(command: cmd, context: context, cwd: cwd,
                                         launcher: launcher) { [weak self] failure, detail in
            runOnMain { [weak self, weak controllerOrigin] in
                MainActor.assumeIsolated {
                    guard let self, let controllerOrigin,
                          self.customCommandOrigin === controllerOrigin,
                          gWindows[self.windowID] === self else { return }
                    controllerOrigin.deliverIfActive {
                        self.reportCommandFailure(cmd, failure: failure, detail: detail, sessionID: sessionID)
                    }
                }
            }
        }
    }

    /// The failure panel an `--error-hud` command posts, nil for one that did not opt in.
    static func failureHudSpec(_ cmd: CustomCommand, failure: LinuxCustomCommandFailure, detail: String?) -> HudSpec? {
        guard cmd.errorHud else { return nil }
        return HudSpec(message: CommandFailure.message(name: cmd.name, reason: failure.reason),
                       detail: detail, position: cmd.errorPosition, hideAfter: failureHudSeconds)
    }

    /// The toast always; the panel only for an `--error-hud` command with a session to cover. A program
    /// overlay keeps its slot, and an unusable `--error-pane` falls back to the whole session.
    func reportCommandFailure(_ cmd: CustomCommand, failure: LinuxCustomCommandFailure, detail: String?,
                              sessionID: UUID?) {
        showToast(failure.toast(commandName: cmd.name))
        guard let sessionID, let spec = Self.failureHudSpec(cmd, failure: failure, detail: detail) else { return }
        // the session may have moved to another window while the command ran
        let owner = gWindows.values.first { $0.store.session(withID: sessionID) != nil } ?? self
        let response = owner.openCommandFailureHud(sessionID, spec: spec, pane: cmd.errorPane)
        if !response.ok {
            FileHandle.standardError.write(Data(
                "agterm: custom command \"\(cmd.name)\" failed (\(failure.reason)); no failure panel: \(response.error ?? "refused")\n".utf8))
        }
    }
}
