import Foundation
import agtermCore

/// The `PATH` a Linux custom command runs with.
///
/// Same failure as macOS #393 with different directories: a `.desktop`-launched app inherits the graphical
/// session's environment, `/bin/sh -c` reads no profile, and `~/.local/bin` — where `install-linux.sh` puts
/// both binaries — reaches `PATH` only through a shell rc many desktop sessions never source. A bare
/// `agtermctl` in a keymap line then exits 127 with the shell's diagnostic discarded.
enum LinuxCommandPath {
    /// The user-local install target `install-linux.sh` writes to. `CommandPath` already appends
    /// `/usr/local/bin`; its `/opt/homebrew/bin` is inert here and not worth a downstream fork of the
    /// shared implementation.
    static func userInstallDirectory(home: String?) -> String? {
        guard let home, !home.isEmpty else { return nil }
        return (home as NSString).appendingPathComponent(".local/bin")
    }

    /// The directory holding the running executable, which is where the packaged bundle and the script
    /// install both put `agtermctl`. It goes FIRST for the same reason macOS leads with the bundled CLI:
    /// it is present whether or not anything was installed system-wide, and its protocol matches this app.
    /// Which instance the CLI drives is decided by `--socket`/`AGTERM_STATE_DIR`, not by which binary runs.
    static func executableDirectory(arg0: String?, currentDirectory: String) -> String? {
        guard let arg0, !arg0.isEmpty else { return nil }
        // the STRING decides, not the URL: swift-corelibs-foundation resolves a relative
        // `URL(fileURLWithPath:)` against the process cwd, so its `path` is already absolute and testing it
        // would take the wrong branch every time.
        let absolute = arg0.hasPrefix("/")
            ? URL(fileURLWithPath: arg0)
            : URL(fileURLWithPath: currentDirectory, isDirectory: true).appendingPathComponent(arg0)
        return absolute.resolvingSymlinksInPath().deletingLastPathComponent().path
    }

    static func widened(_ path: String?, bundledCLIDirectory: String?, userInstallDirectory: String?)
        -> String {
        let base = CommandPath.widened(path, bundledCLIDirectory: bundledCLIDirectory)
        guard let userInstallDirectory, !userInstallDirectory.isEmpty,
              !base.split(separator: ":").contains(Substring(userInstallDirectory)) else { return base }
        return base + ":" + userInstallDirectory
    }

    /// The environment a spawned command sees, resolved from the process. Split from `widened` so the
    /// policy stays testable without touching `ProcessInfo`.
    static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        var environment = base
        environment["PATH"] = widened(
            base["PATH"],
            bundledCLIDirectory: executableDirectory(
                arg0: CommandLine.arguments.first,
                currentDirectory: FileManager.default.currentDirectoryPath),
            userInstallDirectory: userInstallDirectory(home: base["HOME"]))
        return environment
    }
}
