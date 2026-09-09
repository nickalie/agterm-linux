import Testing
@testable import agtermctlKit

/// Socket-path precedence, which the two platforms answer differently: Foundation resolves application
/// support to `~/Library/Application Support` on Darwin and the XDG data directory here. The tests inject
/// the resolved directory rather than reading it, so both answers are pinned from either host.
struct SocketPathTests {
    @Test func socketPathExplicitFlagWins() throws {
        let command = try Tree.parse(["--socket", "/tmp/explicit.sock"])
        let env = ["AGTERM_STATE_DIR": "/tmp/state", "HOME": "/Users/x"]
        #expect(command.options.basic.socketPath(
            env: env, applicationSupportDirectory: "/ignored") == "/tmp/explicit.sock")
    }

    @Test func socketPathStateDirOverHome() throws {
        let command = try Tree.parse([])
        let env = ["AGTERM_STATE_DIR": "/tmp/state", "HOME": "/Users/x"]
        #expect(command.options.basic.socketPath(
            env: env, applicationSupportDirectory: "/ignored") == "/tmp/state/agterm.sock")
    }

    @Test func socketPathPreservesMacOSApplicationSupportLocation() throws {
        let command = try Tree.parse([])
        let env = ["HOME": "/Users/x"]
        #expect(command.options.basic.socketPath(
            env: env, applicationSupportDirectory: "/Users/x/Library/Application Support/agterm")
            == "/Users/x/Library/Application Support/agterm/agterm.sock")
    }

    @Test func socketPathUsesLinuxFoundationApplicationSupportLocation() throws {
        let command = try Tree.parse([])
        #expect(command.options.basic.socketPath(
            env: ["HOME": "/home/x", "XDG_DATA_HOME": "/xdg/data"],
            applicationSupportDirectory: "/xdg/data/agterm") == "/xdg/data/agterm/agterm.sock")
    }

    @Test func socketPathFallsBackToTmpWithoutFoundationLocation() throws {
        let command = try Tree.parse([])
        #expect(command.options.basic.socketPath(
            env: [:], applicationSupportDirectory: nil) == "/tmp/agterm/agterm.sock")
    }

}
