import Foundation
import Testing

/// Runs a copy of the CLI staged as `stage-linux.sh` lays it out, against a stand-in `ssh` on PATH.
@Suite("agtermctl terminfo install from the staged payload")
struct TerminfoInstallProcessTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("agtermctl-terminfo-\(UUID().uuidString)", isDirectory: true)

    private var builtCLI: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("agtermctl-linux")
    }

    private var vendoredTerminfo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/ghostty/share/terminfo")
    }

    @Test func thePayloadDatabaseIsDumpedAndSentOverSsh() throws {
        try #require(FileManager.default.fileExists(atPath: vendoredTerminfo.appendingPathComponent("x/xterm-ghostty").path))
        try #require(FileManager.default.isExecutableFile(atPath: "/usr/bin/infocmp"))
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let prefix = root.appendingPathComponent("payload")
        try fm.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("share"), withIntermediateDirectories: true)
        let cli = prefix.appendingPathComponent("bin/agtermctl.bin")
        try fm.copyItem(at: builtCLI, to: cli)
        try fm.copyItem(at: vendoredTerminfo, to: prefix.appendingPathComponent("share/terminfo"))
        let fakeBin = root.appendingPathComponent("fakebin")
        try fm.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let received = root.appendingPathComponent("received")
        let ssh = fakeBin.appendingPathComponent("ssh")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(received.path).argv'\ncat > '\(received.path)'\n"
            .write(to: ssh, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)

        let process = Process()
        process.executableURL = cli
        process.arguments = ["terminfo", "install", "box"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fakeBin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["TERMINFO"] = root.appendingPathComponent("elsewhere").path
        environment["HOME"] = root.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "\(printed)")
        #expect(printed.contains("installed xterm-ghostty on box"))
        let source = try String(contentsOf: received, encoding: .utf8)
        #expect(source.hasPrefix("xterm-ghostty|") || source.contains("\nxterm-ghostty|"))
        let argv = try String(contentsOf: URL(fileURLWithPath: received.path + ".argv"), encoding: .utf8)
        #expect(argv.contains("\nbox\n"))
    }
}
