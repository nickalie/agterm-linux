import agtermCore

enum LinuxSidebarPolicy {
    /// The CSS that scales the sidebar rows to the configured sidebar font size (nil = the shared
    /// default): the row text size, plus a `min-height` derived from the shared
    /// `AppSettings.sidebarRowHeight` that lowers libadwaita's `navigation-sidebar` row pin.
    /// That height is a FLOOR, not a cap — taller content still grows the row.
    /// Read the Linux row-height bullet in `.claude/rules/sidebar.md` before changing this: it records
    /// which libadwaita rule is overridden, why the row's inner box is deliberately left alone, and what
    /// the emitted floor actually measures at each supported size.
    static func sidebarCSS(fontSize: Double?) -> String {
        let size = AppSettings.clampSidebarFontSize(fontSize ?? AppSettings.defaultSidebarFontSize)
        let rowHeight = Int(AppSettings.sidebarRowHeight(fontSize: size))
        return """
            .agterm-sidebar label { font-size: \(size)pt; }
            .agterm-sidebar .navigation-sidebar > row { min-height: \(rowHeight)px; }
            """
    }

    /// The workspace rows and the session rows under each, in store order; nil under the flat flagged list,
    /// which has no workspace rows. The flagged tree reads every workspace, since flagged mode ignores the
    /// focus filter, and omits a workspace holding nothing flagged.
    @MainActor
    static func workspaceProjection(_ store: AppStore, flaggedLayout: FlaggedViewLayout)
        -> [(workspace: Workspace, sessions: [Session])]? {
        guard store.rendersWorkspaceRows(flaggedLayout: flaggedLayout) else { return nil }
        guard store.sidebarMode == .flagged else { return store.visibleWorkspaces.map { ($0, $0.sessions) } }
        return store.workspaces.compactMap { workspace in
            let flagged = workspace.sessions.filter(\.flagged)
            return flagged.isEmpty ? nil : (workspace, flagged)
        }
    }

    /// The layout `sidebar.flagged-layout` asks for; `toggle` resolves from the current one.
    static func flaggedLayout(for mode: ControlFlaggedLayoutMode, current: FlaggedViewLayout) -> FlaggedViewLayout {
        switch mode {
        case .flat: return .flat
        case .tree: return .tree
        case .toggle: return current == .flat ? .tree : .flat
        }
    }

    /// Only the flat flagged list names each row's workspace; every other layout nests rows under it.
    @MainActor
    static func labelsSessionsWithWorkspace(_ store: AppStore, flaggedLayout: FlaggedViewLayout) -> Bool {
        store.sidebarMode == .flagged && flaggedLayout == .flat
    }

    @MainActor
    static func flaggedRowLabel(for session: Session, in store: AppStore) -> String {
        if let workspace = store.workspace(forSession: session.id) {
            return "\(session.displayName)  —  \(workspace.name)"
        }
        return session.displayName
    }

    /// The notice a remote row shows while its presentation stream is not up, nil otherwise.
    @MainActor
    static func presentationNotice(for session: Session) -> String? {
        guard let host = session.remoteHost else { return nil }
        return session.remotePresentation?.connection.rowNotice(host: host)
    }

    /// The row's leading glyph: a terminal, a cloud for an attached session, and a disconnected network for
    /// one whose stream is down, where macOS slashes the cloud.
    @MainActor
    static func sessionIcon(for session: Session, notice: String?) -> String {
        guard session.remoteHost != nil else { return "utilities-terminal-symbolic" }
        return notice == nil ? "weather-overcast-symbolic" : "network-offline-symbolic"
    }
}
