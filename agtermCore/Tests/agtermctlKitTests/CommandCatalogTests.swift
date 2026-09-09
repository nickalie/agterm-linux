import ArgumentParser
import Testing
@testable import agtermctlKit

/// The catalog seam this fork's Linux CLI is built on: it appends its own host commands to the shared
/// root instead of copying the parser types. Kept out of `CommandsTests` so the shared file carries no
/// downstream-only case.
struct CommandCatalogTests {
    @Test func sharedCatalogCanAppendAHostCommandWithoutChangingAgtermctl() throws {
        #expect(try ExtendedAgtermctl.parseAsRoot(["host-command"]) is HostCommand)
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["host-command"]) }
        #expect(AgtermctlCommandCatalog.subcommands.count + 1
            == ExtendedAgtermctl.configuration.subcommands.count)
    }
}

private struct ExtendedAgtermctl: ParsableCommand {
    static let configuration = AgtermctlCommandCatalog.rootConfiguration(
        appending: [HostCommand.self])
}

private struct HostCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "host-command")
}
