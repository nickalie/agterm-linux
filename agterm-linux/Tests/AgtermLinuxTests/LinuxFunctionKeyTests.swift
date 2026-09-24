import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux function-key shortcuts")
struct LinuxFunctionKeyTests {
    private let shift: UInt32 = 1 << 0
    private let control: UInt32 = 1 << 2

    private func chord(_ keyval: UInt32, state: UInt32 = 0) -> Chord? {
        shortcutChord(fromKeyval: keyval, keycode: 0, state: state, context: nil)
    }

    @Test("GDK F1 through F20 become the keymap's f1 through f20")
    func keyvalTable() {
        for number in 1...20 {
            #expect(chord(0xFFBE + UInt32(number - 1)) == Chord(mods: [], key: "f\(number)"))
        }
        #expect(linuxFunctionKey(forKeyval: 0xFFBD) == nil)
        #expect(linuxFunctionKey(forKeyval: 0xFFD2) == nil)
        #expect(chord(0xFFD2) == nil)
    }

    @Test("an F-key keeps its modifiers")
    func modifiedFunctionKeys() {
        #expect(chord(0xFFC3, state: shift) == Chord(mods: [.shift], key: "f6"))
        #expect(chord(0xFFC2, state: control | shift) == Chord(mods: [.control, .shift], key: "f5"))
    }

    @Test("bare and modified F-keys bind commands, built-ins and leaders through Linux validation")
    func functionKeyBindings() throws {
        let loaded = try loadKeymap("""
        command "Build" f5 make
        command "Leader" f7>x true
        command "Shifted" ctrl+f8 true
        map shift+f6 new_session
        """)
        #expect(loaded.diagnostics.isEmpty)
        #expect(loaded.keymap.builtinOverrides[.newSession] == Chord(mods: [.shift], key: "f6"))

        var engine = CustomCommandEngine(commands: loaded.keymap.commands,
                                         builtinSequences: loaded.keymap.builtinSequences)
        guard case .fired(let build) = engine.advance(Chord(mods: [], key: "f5")) else {
            Issue.record("a bare F5 did not fire its command")
            return
        }
        #expect(build.name == "Build")
        #expect(engine.advance(Chord(mods: [], key: "f7")) == .armed)
        guard case .fired(let leader) = engine.advance(Chord(mods: [], key: "x")) else {
            Issue.record("the F7 leader did not complete")
            return
        }
        #expect(leader.name == "Leader")
        guard case .fired(let shifted) = engine.advance(Chord(mods: [.control], key: "f8")) else {
            Issue.record("Ctrl+F8 did not fire its command")
            return
        }
        #expect(shifted.name == "Shifted")
        #expect(engine.advance(Chord(mods: [], key: "f9")) == .unmatched)
    }

    private func loadKeymap(_ contents: String) throws -> (keymap: Keymap, diagnostics: [KeymapDiagnostic]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: directory.appendingPathComponent("keymap.conf"), atomically: true, encoding: .utf8)
        return loadLinuxKeymap(configDirectory: directory)
    }
}

@Suite("Linux key-press ownership")
struct LinuxKeyPressOwnershipTests {
    @Test("an owned press swallows its repeats until the release")
    func repeatsStayOwned() {
        var ownership = LinuxKeyPressOwnership()
        var observed: [Bool] = []
        observed.append(ownership.isOwnedRepeat(71, now: 0))
        ownership.claim(71, now: 0)
        observed.append(ownership.isOwnedRepeat(71, now: 0.5))
        observed.append(ownership.isOwnedRepeat(71, now: 0.53))
        observed.append(ownership.isOwnedRepeat(72, now: 0.53))
        observed.append(ownership.release(71))
        observed.append(ownership.isOwnedRepeat(71, now: 0.6))
        observed.append(ownership.release(71))
        #expect(observed == [false, true, true, false, true, false, false])
    }

    @Test("each repeat extends the window, so a long hold stays owned")
    func longHold() {
        var ownership = LinuxKeyPressOwnership()
        ownership.claim(71, now: 0)
        let held = (1...100).map { ownership.isOwnedRepeat(71, now: 1.5 + Double($0) * 0.03) }
        #expect(held.allSatisfy { $0 })
    }

    @Test("a release lost outside the app lapses, so the next deliberate press fires")
    func lostReleaseLapses() {
        var ownership = LinuxKeyPressOwnership()
        ownership.claim(71, now: 10)
        let late = ownership.isOwnedRepeat(71, now: 10 + LinuxKeyPressOwnership.repeatWindow + 0.1)
        let next = ownership.isOwnedRepeat(71, now: 10 + LinuxKeyPressOwnership.repeatWindow + 0.2)
        #expect(!late && !next)
    }
}
