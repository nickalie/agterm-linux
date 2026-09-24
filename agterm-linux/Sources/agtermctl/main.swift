import ArgumentParser
import Foundation
import LinuxIntegrations
import agtermctlKit

struct AgtermctlLinux: ParsableCommand {
    static let configuration = AgtermctlCommandCatalog.rootConfiguration(
        abstract: "Drive agterm and manage local integrations.",
        appending: [Integration.self])
}

// the shared `terminfo install` falls back to TERMINFO when no macOS bundle surrounds the CLI, so the
// payload's own database takes that slot, ahead of whatever the caller exported, as the bundle does on macOS
if CommandLine.arguments.dropFirst().first == "terminfo",
   let directory = LinuxTerminfoPayload.directory(clientPath: LinuxTerminfoPayload.executablePath(),
                                                  home: FileManager.default.homeDirectoryForCurrentUser.path) {
    setenv("TERMINFO", directory, 1)
}

AgtermctlLinux.main()
