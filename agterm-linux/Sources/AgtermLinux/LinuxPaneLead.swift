import CGtk
import Foundation
import agtermCore

/// App side of explicit zmx leadership: a pane's zmx client reports its role, a pane that does not lead is
/// covered, and taking the lead is always a FRESH attach into a new surface. `.claude/rules/control-api.md`
/// owns the contract.
@MainActor
extension GhosttySurface {
    /// The model identity of the pane this surface fills, nil for the ephemeral ones, which have no daemon.
    /// Read from the model rather than `paneToken`: a pane that is not wrapped carries a per-spawn token.
    var leadPaneIdentity: UUID? {
        guard !isTornDown, let pane = role.statusPane,
              let session = controller?.store.session(withID: sessionID) else { return nil }
        return session.paneIdentity(for: pane)
    }

    /// Whether this pane's terminal must not be seen or typed into: it follows another client's grid, or it
    /// is a fresh attach that has not reported yet.
    var leadCovered: Bool { ZmxLeadBook.shared.covered(pane: leadPaneIdentity) }

    /// A role report parsed off the title action. One from a surface this pane already replaced carries that
    /// attachment's token and the book drops it.
    func reportLead(_ notice: ZmxLeadNotice) {
        guard let controller, let pane = leadPaneIdentity,
              let role = ZmxLeadBook.shared.apply(notice, pane: pane) else { return }
        controller.leadRoleChanged()
        // without the claim, so this attach leads only if nobody claimed the session in the meantime
        if role == .unowned { controller.reattachPane(self, claim: false) }
    }

    /// The attach ended on its exit prompt, a failed take-over included: no client is left to report a role,
    /// and a cover would hide the line saying what died and swallow the key that closes it.
    func leadExitHeld() {
        guard let controller, let pane = leadPaneIdentity, ZmxLeadBook.shared.states[pane] != nil else { return }
        ZmxLeadBook.shared.forget(pane: pane)
        controller.leadRoleChanged()
    }

    /// Nil when the pane is not covered and the press takes its ordinary path; true when the cover consumed
    /// it. App shortcuts still run, as a macOS menu key equivalent does ahead of the covered view.
    func leadKeyGate(keyval: UInt32, keycode: UInt32, state: UInt32, event: OpaquePointer?) -> Bool? {
        guard leadCovered else { return nil }
        if controller?.handleKey(keyval: keyval, keycode: keycode, state: state, sessionID: sessionID,
                                 origin: self, context: shortcutKeyContext(event: event, keycode: keycode)) == true {
            return true
        }
        // a modifier alone is not the press the cover asks for, and a Super chord is swallowed like a
        // Command chord upstream
        guard ModifierKeyMods.modifierBit(forKeyval: keyval) == nil, state & PaneLeadKey.superMask == 0 else {
            return true
        }
        // already on its way: the fresh surface is covered too until its first report
        guard !ZmxLeadBook.shared.reattaching(pane: leadPaneIdentity) else { return true }
        // owned until released, so neither its repeats nor its release reach the program through the new surface
        gKeyPressOwnership.claim(keycode, now: ProcessInfo.processInfo.systemUptime)
        controller?.reattachPane(self, claim: true)
        return true
    }

    /// The text of a live IM composition, empty when none.
    var pendingComposition: String {
        guard let imContext else { return "" }
        var text: UnsafeMutablePointer<CChar>?
        gtk_im_context_get_preedit_string(cast(imContext), &text, nil, nil)
        defer { g_free(text) }
        return text.map { String(cString: $0) } ?? ""
    }

    /// Ends a composition whose text a caller delivered another way, without committing it here.
    func discardComposition() {
        guard !pendingComposition.isEmpty, let imContext else { return }
        gtk_im_context_reset(cast(imContext))
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
    }
}

enum PaneLeadKey {
    /// `GDK_SUPER_MASK`.
    static let superMask: UInt32 = 1 << 26
}

/// What a fresh attach of an existing pane spawns with. It attaches and never creates: the trailing
/// `/bin/sh -c` runs only when the daemon is gone, and fails, so a vanished session ends the pane instead of
/// handing back a new shell under the old identity.
struct PaneReattach: Equatable {
    static let goneScript = "printf '%s\\n' 'agterm: session is gone'; exit 1"

    let command: String
    let wait: Bool
    let environment: [String: String]
    let workingDirectory: String

    static func local(_ configuration: ZmxSupport.Configuration, workingDirectory: String) -> PaneReattach {
        PaneReattach(command: CommandRestore.shellQuotedLine(configuration.attachArguments + ["/bin/sh", "-c", goneScript]),
                     wait: false, environment: configuration.environment, workingDirectory: workingDirectory)
    }

    /// An attached pane is rebuilt from the binding, never from its first command line, which carries that
    /// attachment's nonce. Waits on exit like the attach, so the disconnect line stays readable.
    static func remoteCommand(_ binding: RemoteBinding, pane identity: UUID, role: ZmxPaneRole,
                              lead: ZmxLeadAttachment) -> String? {
        guard let origin = binding.origin, let daemon = binding.daemon(forLocalPane: identity) else { return nil }
        return try? RemoteSession.attachPaneCommand(host: origin.host, endpoint: origin.endpoint, daemon: daemon,
                                                    session: origin.sessionName, pane: role, lead: lead)
    }
}

@MainActor
extension AppController {
    /// A pane's `lead` read-back changed, or its cover must follow.
    func leadRoleChanged() {
        store.leadRoleChanged()
        LinuxPaneLeadCover.syncAll()
    }

    /// Replaces `old` with a fresh attach of the same pane in the same slot. None of the pane's close paths
    /// run: the session, the daemon and the pane identity all stay, so the program inside keeps the
    /// `AGTERM_PANE_ID` it was started with.
    func reattachPane(_ old: GhosttySurface, claim: Bool) {
        let lead = ZmxLeadAttachment(claim: claim)
        guard let session = store.session(withID: old.sessionID), let pane = old.role.statusPane, pane != .scratch,
              let identity = session.paneIdentity(for: pane),
              let launch = reattachLaunch(old, session: session, identity: identity, pane: pane, lead: lead)
        else { return }
        let id = session.id
        let slot: OverlayPane = pane == .right ? .right : .left
        let zoomTarget = TerminalZoomTarget.session(id, slot == .left ? .primary : .split)
        guard let container = terminalZoom.target == zoomTarget
            ? zoomHost.flatMap({ op(adw_toolbar_view_get_content($0)) }) : paneHosts[id]?[slot] else { return }
        // a dashboard cell's transient font is not the pane's: seeding from it would persist the small size
        let fontSize = old.dashboardFontOverride == nil ? old.currentFontSize() ?? session.fontSize : session.fontSize
        let fresh = GhosttySurface(sessionID: id, cwd: launch.workingDirectory, command: launch.command,
                                   env: launch.environment, controller: self, waitAfterCommand: launch.wait,
                                   role: old.role, fontSize: fontSize, backedByZmx: old.backedByZmx)
        ZmxLeadBook.shared.begin(lead, pane: identity, reattaching: true)
        // the old client's exit must not close the pane the new one now owns
        _ = old.claimProcessExit()
        let hadFocus = gtk_widget_has_focus(W(old.glArea)) != 0
        // synchronously: END_SEARCH would answer through a surface about to be freed
        if searchSurface === old { abandonSearch(ownedBy: id) }
        if slot == .left {
            fresh.onExit = { [weak self] in self?.closePrimaryPane(id) }
            session.surface = fresh
            surfaces[id] = fresh
        } else {
            fresh.onExit = { [weak self] in self?.closeSplitPane(id) }
            session.splitSurface = fresh
            splitSurfaces[id] = fresh
        }
        old.teardown()
        gtk_overlay_set_child(container, W(fresh.glArea))
        if old.backedByZmx { gZmx?.foreground.noteLifecycleChange() }
        if let title = GhosttyApp.shared.staticTitle { fresh.applyTitle(title) }
        if dashboard.isOpen, dashboard.members.contains(where: { $0.session == id }) {
            restoreDashboardAfterReconcile(prepareDashboardForReconcile())
        }
        fresh.realizeWidgetIfNeeded()
        if hadFocus { fresh.grabFocus() }
        leadRoleChanged()
    }

    private func reattachLaunch(_ old: GhosttySurface, session: Session, identity: UUID, pane: StatusPane,
                                lead: ZmxLeadAttachment) -> PaneReattach? {
        if old.backedByZmx {
            return LinuxZmxLaunch.configuration(paneIdentity: identity, pane: pane == .right ? "split" : "primary",
                                                environment: old.env, lead: lead)
                .map { PaneReattach.local($0, workingDirectory: old.cwd) }
        }
        guard let binding = session.remotePresentation?.binding,
              let command = PaneReattach.remoteCommand(binding, pane: identity, role: pane == .right ? .right : .left,
                                                       lead: lead) else { return nil }
        return PaneReattach(command: command, wait: true, environment: old.env, workingDirectory: old.cwd)
    }

    /// Applies the config's static `title`, which libghostty no longer applies itself, to every pane.
    func applyStaticTitle(_ title: String) {
        for surface in Array(surfaces.values) + Array(splitSurfaces.values) { surface.applyTitle(title) }
    }
}
