enum GhosttyDefaults {
    /// `no-title` stops ghostty's shell integration from re-titling the terminal with the abbreviated cwd
    /// (`…/a/b/c`) at every prompt, which would stand in for the cwd on line two and — with
    /// `sessionNameFromTerminalTitle` on — for the session name itself. Explicit titles (a remote host over
    /// SSH, a PROMPT_COMMAND emitting OSC 2) still arrive. Matches macOS `ghostty-defaults.conf`.
    static let baseConfLines = """
    cursor-style = block
    cursor-click-to-move = false
    shell-integration-features = no-title

    """
}
