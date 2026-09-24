import Foundation

/// Where a Linux install keeps the bundled `xterm-ghostty` database, which the shared
/// `TerminfoInstall` resolver cannot see: it looks beside a macOS bundle, then at `TERMINFO`.
/// The staged payload (tar, packages, AppImage, Flatpak) puts it at `<prefix>/share/terminfo` beside
/// `<prefix>/bin`; `install-linux.sh` puts it at `~/.local/share/agterm/terminfo`.
public enum LinuxTerminfoPayload {
    public static let entry = "xterm-ghostty"

    /// `clientPath` is the CLI's real path, `bin/agtermctl.bin` in the payload.
    public static func candidates(clientPath: String?, home: String) -> [String] {
        var candidates: [String] = []
        if let clientPath {
            let prefix = URL(fileURLWithPath: clientPath).deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(prefix.appendingPathComponent("share/terminfo").path)
            candidates.append(prefix.appendingPathComponent("share/agterm/terminfo").path)
        }
        candidates.append(URL(fileURLWithPath: home).appendingPathComponent(".local/share/agterm/terminfo").path)
        return candidates
    }

    /// The running executable's real path; the PATH entry may be a symlink or the payload's wrapper script.
    public static func executablePath() -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
    }

    public static func directory(clientPath: String?, home: String,
                                 fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        candidates(clientPath: clientPath, home: home).first { fileExists("\($0)/x/\(entry)") }
    }
}
