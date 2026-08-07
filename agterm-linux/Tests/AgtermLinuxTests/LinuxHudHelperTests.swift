import Foundation
import Testing
@testable import AgtermLinux

struct LinuxHudHelperTests {
    @Test("a dev run resolves the repository helper, which is the file the shared tests exercise")
    func resolvesTheRepositoryHelper() {
        let candidates = AppController.hudHelperCandidates()
        #expect(candidates.allSatisfy { $0.hasSuffix("hud/hud.sh") })
        #expect(candidates.contains { FileManager.default.isReadableFile(atPath: $0) },
                "no hud.sh among \(candidates): staging or the repository layout moved")
    }

    @Test("the body file is per session, so an update rewrites the path the helper already opened")
    func bodyFileIsPerSession() {
        let id = UUID()
        #expect(AppController.hudBodyFile(for: id) == AppController.hudBodyFile(for: id))
        #expect(AppController.hudBodyFile(for: id) != AppController.hudBodyFile(for: UUID()))
        #expect(AppController.hudBodyFile(for: id).hasSuffix("\(id.uuidString).txt"))
    }
}
