import Foundation
import agtermCore

public struct IntegrationEnvironment: Sendable {
    public let homeDirectory: URL
    public let executableURL: URL
    public let pathDirectories: [URL]
    public let resourceRoot: URL?
    public let knownCommandLineTools: [URL]
    public let versionOverride: String?
    public let portableLauncherAllowed: Bool
    /// What the user's OpenCode said about itself, nil when nothing was probed.
    public let opencode: OpenCodeProbe?

    public init(homeDirectory: URL, executableURL: URL, pathDirectories: [URL], resourceRoot: URL?,
                knownCommandLineTools: [URL] = [], versionOverride: String? = nil,
                portableLauncherAllowed: Bool = true, opencode: OpenCodeProbe? = nil) {
        self.homeDirectory = homeDirectory
        self.executableURL = executableURL
        self.pathDirectories = pathDirectories
        self.resourceRoot = resourceRoot
        self.knownCommandLineTools = knownCommandLineTools
        self.versionOverride = versionOverride
        self.portableLauncherAllowed = portableLauncherAllowed
        self.opencode = opencode
    }

    public static func process(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> IntegrationEnvironment {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let paths = (environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true)
        }
        let rawExecutable = arguments.first ?? ""
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let executable: URL
        if rawExecutable.contains("/") {
            executable = URL(fileURLWithPath: rawExecutable, relativeTo: cwd).standardizedFileURL
        } else if let onPath = paths.lazy.map({ $0.appendingPathComponent(rawExecutable) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            executable = onPath.standardizedFileURL
        } else {
            executable = cwd.appendingPathComponent(rawExecutable).standardizedFileURL
        }
        let override = environment["AGTERM_RESOURCE_ROOT"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
        let appImage = environment["APPIMAGE"]?.isEmpty == false
        let flatpak = environment["FLATPAK_ID"]?.isEmpty == false
        return IntegrationEnvironment(homeDirectory: home, executableURL: executable,
                                      pathDirectories: paths, resourceRoot: override,
                                      knownCommandLineTools: [
                                          URL(fileURLWithPath: "/usr/bin/agtermctl"),
                                          URL(fileURLWithPath: "/usr/local/bin/agtermctl"),
                                          URL(fileURLWithPath: "/opt/agterm-linux/bin/agtermctl"),
                                      ],
                                      versionOverride: environment["AGTERM_VERSION"],
                                      portableLauncherAllowed: !appImage && !flatpak,
                                      opencode: OpenCodeProbe.detect(
                                          home: home, cwd: cwd, environment: environment,
                                          searchPath: paths + [home.appendingPathComponent(".opencode/bin")]))
    }

    public var userBinDirectory: URL {
        homeDirectory.appendingPathComponent(".local/bin", isDirectory: true)
    }

    public var hooksDirectory: URL {
        homeDirectory.appendingPathComponent(".config/agterm/agent-status", isDirectory: true)
    }

    var launcherOwnershipFile: URL {
        homeDirectory.appendingPathComponent(".local/share/agterm/cli-launcher-v1")
    }

    func resource(named name: String) -> URL? {
        let fm = FileManager.default
        if let resourceRoot {
            let explicit = resourceRoot.appendingPathComponent(name, isDirectory: true)
            return fm.fileExists(atPath: explicit.path) ? explicit : nil
        }

        // A portable install exposes ~/.local/bin/agtermctl as a symlink into the extracted archive.
        // Resolve it before walking to share/agterm, otherwise resources are incorrectly searched for
        // under ~/.local/share/agterm when the command is invoked through PATH.
        let installed = executableURL.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/agterm/\(name)", isDirectory: true)
        if fm.fileExists(atPath: installed.path) { return installed }

        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let checkout: URL
        if name == "agent-skill" {
            checkout = root.appendingPathComponent("plugins/agterm/skills/agterm", isDirectory: true)
        } else {
            checkout = root.appendingPathComponent("agterm/Resources/\(name)", isDirectory: true)
        }
        return fm.fileExists(atPath: checkout.path) ? checkout : nil
    }

    func bundledCLI() -> URL? {
        let fm = FileManager.default
        let directory = executableURL.deletingLastPathComponent()
        for name in ["agtermctl", "agtermctl-linux", "agtermctl.bin"] {
            let candidate = directory.appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate.resolvingSymlinksInPath() }
        }
        return nil
    }

    func pathCLI() -> URL? {
        let fm = FileManager.default
        let transientBundleTarget = portableLauncherAllowed ? nil : bundledCLI()?.resolvingSymlinksInPath()
        for directory in pathDirectories {
            let candidate = directory.appendingPathComponent("agtermctl")
            guard fm.isExecutableFile(atPath: candidate.path) else { continue }
            // linuxdeploy may prepend the mounted AppImage's usr/bin to PATH. That executable disappears
            // after exit, so keep scanning for a persistent host installation in sandboxed builds.
            if candidate.resolvingSymlinksInPath() == transientBundleTarget { continue }
            return candidate
        }
        return nil
    }

    func packageCLI() -> URL? {
        knownCommandLineTools.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func version(for cli: URL) -> String? {
        if let version = versionOverride?.trimmedNonempty { return version }
        let resolved = cli.resolvingSymlinksInPath()
        let roots = [resolved.deletingLastPathComponent().deletingLastPathComponent(),
                     executableURL.deletingLastPathComponent().deletingLastPathComponent()]
        for root in roots {
            let file = root.appendingPathComponent("share/agterm/VERSION")
            if let raw = try? String(contentsOf: file, encoding: .utf8),
               let version = raw.trimmedNonempty {
                return version
            }
        }
        return nil
    }
}

private extension String {
    var trimmedNonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// OpenCodeProbe is what selects the OpenCode status plugin: the major version `opencode --version` reports,
/// and the configuration directory OpenCode 2 reads, `OPENCODE_CONFIG_DIR` over `XDG_CONFIG_HOME`.
public struct OpenCodeProbe: Sendable, Equatable {
    public let version: AgentHooksInstall.OpenCode.Version?
    public let v2ConfigurationDirectory: String?

    public init(version: AgentHooksInstall.OpenCode.Version?, v2ConfigurationDirectory: String?) {
        self.version = version
        self.v2ConfigurationDirectory = v2ConfigurationDirectory
    }

    static let timeout: TimeInterval = 3

    static func detect(home: URL, cwd: URL, environment: [String: String], searchPath: [URL]) -> OpenCodeProbe {
        let directory = AgentHooksInstall.OpenCode.configurationDirectory(
            home: home.path, opencodeConfigDirectory: environment["OPENCODE_CONFIG_DIR"],
            xdgConfigHome: environment["XDG_CONFIG_HOME"], workingDirectory: cwd.path)
        let executable = searchPath.map { $0.appendingPathComponent("opencode") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        return OpenCodeProbe(version: executable.flatMap { version(of: $0, environment: environment) },
                             v2ConfigurationDirectory: directory)
    }

    private static func version(of executable: URL, environment: [String: String]) -> AgentHooksInstall.OpenCode.Version? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { return nil }
        return AgentHooksInstall.OpenCode.Version(versionOutput: text)
    }
}
