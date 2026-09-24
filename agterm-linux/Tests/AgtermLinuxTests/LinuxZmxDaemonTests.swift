import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

/// Drives the vendored, patched zmx against a throwaway `ZMX_DIR`. Skipped when the binary is not staged.
@Suite("Linux zmx client against a real daemon", .serialized)
@MainActor
struct LinuxZmxDaemonTests {
    nonisolated private static let binary = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("vendor/zmx/zmx").path

    nonisolated private static var available: Bool { FileManager.default.isExecutableFile(atPath: binary) }

    @Test("list, type and screen work against the pinned zmx", .enabled(if: available))
    func typeAndScreen() throws {
        // short, so the socket path stays under the sun_path limit
        let directory = "/tmp/zlt-\(getpid())"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let name = ZmxSupport.daemonName(for: UUID())
        let client = LinuxZmxClient(executablePath: Self.binary, socketDirectory: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["ZMX_DIR"] = directory
        environment["SHELL"] = "/bin/sh"
        environment.removeValue(forKey: "ZMX_SESSION")
        _ = try LinuxZmxClient.run(.init(executablePath: Self.binary, arguments: ["run", name, "-d", "/bin/sh"],
                                         environment: environment, timeout: 5))
        defer { _ = client.killConfirmed(name: name) }

        let listed = try #require(client.listSessions())
        #expect(listed.contains { $0.name == name && $0.clients == 0 })

        #expect(client.type(name: name, bytes: KeystrokeSegments.ptyBytes("echo LEAD-$((40+2))\n")))
        var screen: ZmxScreen?
        for _ in 0..<40 where !(screen?.text.contains("LEAD-42") ?? false) {
            usleep(50_000)
            screen = client.screen(name: name, all: true)
        }
        let text = try #require(screen).text
        #expect(text.contains("LEAD-42"))
        #expect(try #require(screen).columns > 0)
        #expect(!client.type(name: name, bytes: []))
        #expect(client.screen(name: "agterm-missing", all: false) == nil)
    }
}
