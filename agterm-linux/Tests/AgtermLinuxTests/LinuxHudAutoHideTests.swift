import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@MainActor
private final class HudScheduleRecorder {
    private(set) var delays: [TimeInterval] = []
    private(set) var cancelled: [Bool] = []
    private var fires: [@MainActor () -> Void] = []

    func schedule(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        let index = delays.count
        delays.append(delay)
        cancelled.append(false)
        fires.append(fire)
        return { [weak self] in self?.cancelled[index] = true }
    }

    /// Runs the fire even when cancelled, the way a host timer that raced its cancel would.
    func fire(_ index: Int) { fires[index]() }
}

@Suite("Linux HUD auto-hide")
@MainActor
struct LinuxHudAutoHideTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func makeTimers(_ recorder: HudScheduleRecorder) -> LinuxHudAutoHide {
        LinuxHudAutoHide(schedule: { recorder.schedule($0, $1) }, clock: { [start] in start })
    }

    @Test("a timed HUD expires once, through the caller, at its deadline")
    func expires() {
        let recorder = HudScheduleRecorder()
        let timers = makeTimers(recorder)
        let session = Session(initialCwd: "/tmp")
        var expired: [UUID] = []

        let deadline = timers.arm(session, spec: HudSpec(message: "done", hideAfter: 5)) { expired.append($0) }

        #expect(recorder.delays == [5])
        #expect(deadline == start.addingTimeInterval(5))
        recorder.fire(0)
        #expect(expired == [session.id])
        #expect(timers.entries[session.id] == nil)
    }

    @Test("no hide-after arms nothing and cancels what was armed")
    func persistentCancels() {
        let recorder = HudScheduleRecorder()
        let timers = makeTimers(recorder)
        let session = Session(initialCwd: "/tmp")

        timers.arm(session, spec: HudSpec(message: "a", hideAfter: 5)) { _ in }
        #expect(timers.arm(session, spec: HudSpec(message: "b")) { _ in } == nil)
        #expect(recorder.delays == [5])
        #expect(recorder.cancelled == [true])
        #expect(timers.entries[session.id] == nil)
    }

    @Test("an update restarts the interval and the superseded fire is inert")
    func supersededFireIsInert() {
        let recorder = HudScheduleRecorder()
        let timers = makeTimers(recorder)
        let session = Session(initialCwd: "/tmp")
        var expired = 0

        timers.arm(session, spec: HudSpec(message: "a", hideAfter: 5)) { _ in expired += 1 }
        timers.arm(session, spec: HudSpec(message: "b", hideAfter: 8)) { _ in expired += 1 }
        #expect(recorder.delays == [5, 8])
        #expect(recorder.cancelled == [true, false])

        recorder.fire(0)
        #expect(expired == 0)
        recorder.fire(1)
        #expect(expired == 1)
    }

    @Test("discarding the panel cancels its timer")
    func discardCancels() {
        let recorder = HudScheduleRecorder()
        let timers = makeTimers(recorder)
        let session = Session(initialCwd: "/tmp")
        var expired = 0

        timers.arm(session, spec: HudSpec(message: "a", hideAfter: 5)) { _ in expired += 1 }
        session.discardHudBody()
        #expect(recorder.cancelled == [true])
        recorder.fire(0)
        #expect(expired == 0)
    }

    @Test("a duration past the ceiling is clamped rather than overflowing the scheduler")
    func clampsToTheCeiling() {
        let recorder = HudScheduleRecorder()
        let timers = makeTimers(recorder)

        timers.arm(Session(initialCwd: "/tmp"), spec: HudSpec(message: "a", hideAfter: 1e12)) { _ in }
        #expect(recorder.delays == [HudSpec.maxHideAfter])
    }
}

@Suite("Linux HUD dispatch validation")
@MainActor
struct LinuxHudDispatchValidationTests {
    private func parse(_ args: ControlArgs, _ cmd: Command = .sessionHudOpen) -> LinuxControlDispatcher.HudSpecParse {
        LinuxControlDispatcher.parseHudSpec(ControlRequest(cmd: cmd, args: args))
    }

    private func error(_ result: LinuxControlDispatcher.HudSpecParse) -> String? {
        if case .rejected(let response) = result { return response.error }
        return nil
    }

    private func spec(_ result: LinuxControlDispatcher.HudSpecParse) -> HudSpec? {
        if case .spec(let spec) = result { return spec }
        return nil
    }

    @Test("markdown takes LF and TAB and carries its mode, font size and hide-after to the host")
    func markdownCarriesItsFields() {
        let parsed = spec(parse(ControlArgs(message: "# Tasks\n\n- build\n\t- test", hideAfter: 30,
                                            markdown: true, fontSize: 18)))
        #expect(parsed?.markdown == true)
        #expect(parsed?.fontSize == 18)
        #expect(parsed?.hideAfter == 30)
        #expect(error(parse(ControlArgs(message: "two\nlines"))) == "hud text must not contain control characters")
    }

    @Test(arguments: ["cr\rhere", "esc\u{1b}[2J", "del\u{7f}", "bell\u{07}"])
    func markdownRejectsOtherControlCharacters(message: String) {
        #expect(error(parse(ControlArgs(message: message, markdown: true)))
            == "hud text must not contain control characters")
    }

    @Test("markdown keeps the detail's plain rules and caps the message at its own length")
    func markdownCaps() {
        #expect(error(parse(ControlArgs(message: "ok", detail: "two\nlines", markdown: true)))
            == "hud text must not contain control characters")
        let atCap = String(repeating: "m", count: HudSpec.maxMarkdownLength)
        #expect(spec(parse(ControlArgs(message: atCap, markdown: true))) != nil)
        #expect(error(parse(ControlArgs(message: atCap + "m", markdown: true)))
            == "hud message too long (max 4096 characters)")
        #expect(error(parse(ControlArgs(message: String(repeating: "m", count: HudSpec.maxTextLength + 1))))
            == "hud message too long (max 256 characters)")
    }

    @Test(arguments: [" \n\t\n ", "[x]: /y", "&#32;", "- "])
    func markdownRenderingNothingIsNoMessage(message: String) {
        #expect(error(parse(ControlArgs(message: message, markdown: true))) == "session.hud.open requires a message")
    }

    @Test("font size is open-only and bounded")
    func fontSize() {
        #expect(spec(parse(ControlArgs(message: "a", fontSize: 6)))?.fontSize == 6)
        #expect(spec(parse(ControlArgs(message: "a", fontSize: 72)))?.fontSize == 72)
        #expect(error(parse(ControlArgs(message: "a", fontSize: 5.5)))
            == "session.hud.open: --font-size must be 6...72 points")
        #expect(error(parse(ControlArgs(message: "a", fontSize: 12), .sessionHudUpdate))
            == "session.hud.update: --font-size is fixed at open; reopen the hud to change it")
    }

    @Test("hide-after is rejected outside 0...86400, not clamped")
    func hideAfterBounds() {
        #expect(spec(parse(ControlArgs(message: "a", hideAfter: 0)))?.hideAfter == 0)
        #expect(spec(parse(ControlArgs(message: "a", hideAfter: 86_400)))?.hideAfter == 86_400)
        #expect(error(parse(ControlArgs(message: "a", hideAfter: -1)))
            == "session.hud.open: --hide-after must be 0...86400 seconds")
        #expect(error(parse(ControlArgs(message: "a", hideAfter: 86_401), .sessionHudUpdate))
            == "session.hud.update: --hide-after must be 0...86400 seconds")
    }

    @Test("the tree reads back the configured hide-after, markdown and requested font size")
    func treeReadBack() throws {
        let session = Session(initialCwd: "/tmp")
        let store = AppStore(workspaces: [Workspace(name: "work", sessions: [session])], selectedSessionID: session.id)
        let spec = HudSpec(message: "**done**", hideAfter: 12, markdown: true, fontSize: 20)
        #expect(store.openHud(session.id, command: "true", spec: spec, file: "/tmp/agterm-hud-test",
                              size: HudPanelSize(widthPercent: 30, heightPercent: 20), fontSize: 20))
        let hud = try #require(store.controlTree(paneForeground: { _ in nil }).workspaces.first?.sessions.first?.hud)
        #expect(hud.hideAfter == 12)
        #expect(hud.markdown)
        #expect(hud.fontSize == 20)
        #expect(session.hudFontSize == 20)
        store.closeHud(session.id)
    }
}
