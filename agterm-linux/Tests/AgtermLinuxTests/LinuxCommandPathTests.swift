import Foundation
import Testing
@testable import AgtermLinux

@Suite("Linux custom-command PATH")
struct LinuxCommandPathTests {
    @Test("the executable's directory leads and the user install target is appended once")
    func widenedOrder() {
        let widened = LinuxCommandPath.widened(
            "/usr/bin:/bin", bundledCLIDirectory: "/opt/agterm/bin",
            userInstallDirectory: "/home/u/.local/bin")
        let entries = widened.split(separator: ":").map(String.init)

        #expect(entries.first == "/opt/agterm/bin")
        #expect(entries.last == "/home/u/.local/bin")
        #expect(entries.contains("/usr/local/bin"))
        #expect(entries.count == Set(entries).count)
    }

    @Test("a PATH that already names the user install target keeps its own order")
    func alreadyPresentIsNotReappended() {
        let widened = LinuxCommandPath.widened(
            "/home/u/.local/bin:/usr/bin", bundledCLIDirectory: nil,
            userInstallDirectory: "/home/u/.local/bin")
        let entries = widened.split(separator: ":").map(String.init)

        #expect(entries.first == "/home/u/.local/bin")
        #expect(entries.filter { $0 == "/home/u/.local/bin" }.count == 1)
    }

    @Test("a missing HOME yields no user install target rather than a bare .local/bin")
    func userInstallDirectoryNeedsHome() {
        #expect(LinuxCommandPath.userInstallDirectory(home: nil) == nil)
        #expect(LinuxCommandPath.userInstallDirectory(home: "") == nil)
        #expect(LinuxCommandPath.userInstallDirectory(home: "/home/u") == "/home/u/.local/bin")
    }

    @Test("a relative arg0 resolves against the working directory, which is where agtermctl sits")
    func executableDirectoryResolvesRelativeArg0() {
        #expect(LinuxCommandPath.executableDirectory(arg0: "/opt/agterm/bin/agterm-linux.bin",
                                                     currentDirectory: "/tmp") == "/opt/agterm/bin")
        #expect(LinuxCommandPath.executableDirectory(arg0: "bin/agterm-linux",
                                                     currentDirectory: "/opt/agterm") == "/opt/agterm/bin")
        #expect(LinuxCommandPath.executableDirectory(arg0: nil, currentDirectory: "/tmp") == nil)
    }
}
