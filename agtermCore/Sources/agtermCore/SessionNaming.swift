/// Whether a pane's OSC terminal title may stand in for an unnamed session's name (`AppSettings`'
/// `sessionNameFromTerminalTitle`, default off — the cwd basename names the session).
///
/// A process-global seam rather than a `Session` field or an `AppStore` property, because `displayName` is
/// computed on `Session`, which owns no settings reference, and is read from dozens of call sites that would
/// otherwise each have to thread the flag. The app targets push the persisted value here at launch and on
/// every settings change; nothing else writes it.
///
/// Not observed, so a flip needs an explicit refresh of whatever renders a name — the sidebar rows and the
/// window title. macOS rides `.agtermAppearanceChanged`; Linux rebuilds the sidebar and title per window.
public enum SessionNaming {
    @MainActor public static var usesTerminalTitle = false
}
