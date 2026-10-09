import Foundation
import Glibc
import Testing
@testable import AgtermLinux

@Suite("Linux session.restart replay")
struct LinuxRestartReplayTests {
    @Test("a process's working directory comes from /proc")
    func workingDirectory() {
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        #expect(AppController.workingDirectory(of: getpid()) == expected)
        #expect(AppController.workingDirectory(of: Int32.max) == nil)
    }
}
