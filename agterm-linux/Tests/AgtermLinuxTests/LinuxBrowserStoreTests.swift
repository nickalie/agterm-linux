import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@MainActor
@Suite("Linux saved browser store")
struct LinuxBrowserStoreTests {
    private static func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-browser-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("without a profile the saved store is unavailable")
    func noProfile() {
        let overlays = LinuxHtmlOverlays()
        #expect(overlays.persistentStoreFailure() == OverlayHtmlError.persistentUnavailable)
        #expect(overlays.clearPersistentStore() == OverlayHtmlError.persistentUnavailable)
    }

    @Test("clearing a profile never created answers without creating one")
    func clearCreatesNothing() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let overlays = LinuxHtmlOverlays()
        overlays.profile = BrowserProfile(directory: dir)
        #expect(overlays.clearPersistentStore() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test("a malformed profile refuses the store and is left alone")
    func malformedProfile() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("browser-profile")
        try Data("not a uuid\n".utf8).write(to: file)
        let overlays = LinuxHtmlOverlays()
        overlays.profile = BrowserProfile(directory: dir)
        #expect(overlays.persistentStoreFailure() == BrowserProfile.Failure.malformed(file.path).description)
        #expect(try String(contentsOf: file, encoding: .utf8) == "not a uuid\n")
    }
}
