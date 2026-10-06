import Foundation
import Testing
import agtermCore
@testable import LinuxIntegrations

@Suite("OpenCode Linux integration")
struct OpenCodeIntegrationTests {
    @Test("plugin installs, updates, and is idempotent")
    func pluginInstall() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        try FileManager.default.createDirectory(
            at: fixture.home.appendingPathComponent(".config/opencode"),
            withIntermediateDirectories: true
        )
        let service = fixture.service(path: [])
        #expect(service.status()[.opencodePlugin]?.state == .notInstalled)
        #expect(try service.apply(service.planHooks()).succeeded)
        #expect(service.status()[.opencodePlugin]?.state == .installed)

        let plugin = fixture.home.appendingPathComponent(
            ".config/opencode/plugins/agterm-status.js")
        try fixture.write(
            "\(AgentHooksInstall.opencodePluginMarker)\nold\n", to: plugin)
        #expect(service.status()[.opencodePlugin]?.state == .updateAvailable)
        #expect(try service.apply(service.planHooks()).succeeded)
        #expect(service.status()[.opencodePlugin]?.state == .installed)
        #expect(!(try service.planHooks()).steps.contains { $0.path == plugin.path })
    }

    @Test("user-owned plugin is preserved")
    func userOwnedPlugin() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let plugin = fixture.home.appendingPathComponent(
            ".config/opencode/plugins/agterm-status.js")
        try fixture.write("export const Mine = async () => ({})\n", to: plugin)
        let service = fixture.service(path: [])
        #expect(service.status()[.opencodePlugin]?.state == .conflict)
        let plan = try service.planHooks()
        #expect(plan.conflicts.contains { $0.contains("user-owned") && $0.contains("opencode") })
        _ = try service.apply(plan)
        #expect(try String(contentsOf: plugin, encoding: .utf8)
            == "export const Mine = async () => ({})\n")
    }

    @Test("OpenCode 2 installs into its own configuration directory and retires agterm's v1 plugin there")
    func v2Install() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let config = fixture.root.appendingPathComponent("opencode-config", isDirectory: true)
        let legacy = config.appendingPathComponent("plugins/agterm-status.js")
        try fixture.write("\(AgentHooksInstall.opencodePluginMarker)\nold\n", to: legacy)
        let service = fixture.service(path: [], opencode: OpenCodeProbe(version: .v2, v2ConfigurationDirectory: config.path))
        let plugin = config.appendingPathComponent("plugins/agterm-v2/tui.js")
        #expect(service.status()[.opencodePlugin]?.state == .notInstalled)
        #expect(service.status()[.opencodePlugin]?.path == plugin.path)
        #expect(try service.apply(service.planHooks()).succeeded)
        #expect(service.status()[.opencodePlugin]?.state == .installed)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("a user-owned v1 plugin beside OpenCode 2 stays, with a warning")
    func v2KeepsUserPlugin() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let config = fixture.root.appendingPathComponent("opencode-config", isDirectory: true)
        let legacy = config.appendingPathComponent("plugins/agterm-status.js")
        try fixture.write("export const Mine = async () => ({})\n", to: legacy)
        let service = fixture.service(path: [], opencode: OpenCodeProbe(version: .v2, v2ConfigurationDirectory: config.path))
        let plan = try service.planHooks()
        #expect(plan.warnings.contains { $0.contains(legacy.path) && $0.contains("user-owned") })
        #expect(try service.apply(plan).succeeded)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("OpenCode 2 without its configuration directory is skipped")
    func v2WithoutDirectory() throws {
        let fixture = try Fixture()
        try fixture.makeHookResources()
        let missing = fixture.root.appendingPathComponent("absent").path
        let service = fixture.service(path: [], opencode: OpenCodeProbe(version: .v2, v2ConfigurationDirectory: missing))
        #expect(service.status()[.opencodePlugin]?.state == .unavailable)
        #expect(try service.planHooks().warnings.contains { $0.contains(missing) })
    }
}
