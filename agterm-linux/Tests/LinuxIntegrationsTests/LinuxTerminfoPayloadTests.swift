import Testing
@testable import LinuxIntegrations

struct LinuxTerminfoPayloadTests {
    @Test func theStagedPayloadIsSearchedBeforeThePerUserInstall() {
        #expect(LinuxTerminfoPayload.candidates(clientPath: "/opt/agterm-linux/bin/agtermctl.bin", home: "/home/u") == [
            "/opt/agterm-linux/share/terminfo",
            "/opt/agterm-linux/share/agterm/terminfo",
            "/home/u/.local/share/agterm/terminfo",
        ])
        #expect(LinuxTerminfoPayload.candidates(clientPath: nil, home: "/home/u") == ["/home/u/.local/share/agterm/terminfo"])
    }

    @Test func theFirstCandidateHoldingTheEntryWins() {
        let present: Set = ["/opt/a/share/agterm/terminfo/x/xterm-ghostty",
                            "/home/u/.local/share/agterm/terminfo/x/xterm-ghostty"]
        let directory = LinuxTerminfoPayload.directory(clientPath: "/opt/a/bin/agtermctl.bin", home: "/home/u",
                                                       fileExists: { present.contains($0) })
        #expect(directory == "/opt/a/share/agterm/terminfo")
    }

    @Test func noCandidateHoldingTheEntryResolvesNothing() {
        #expect(LinuxTerminfoPayload.directory(clientPath: "/opt/a/bin/agtermctl.bin", home: "/home/u",
                                               fileExists: { _ in false }) == nil)
    }
}
