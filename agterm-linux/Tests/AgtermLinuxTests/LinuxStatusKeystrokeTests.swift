import Testing
import agtermCore
@testable import AgtermLinux

@Suite("GDK keystroke classification for the agent-status glyph")
struct LinuxStatusKeystrokeTests {
    private func classify(_ keyval: UInt32, _ state: UInt32 = 0, base: Unicode.Scalar? = nil) -> StatusKeystroke {
        LinuxStatusKeystroke.classify(keyval: keyval, state: state, baseCharacter: base)
    }

    @Test func escapeAndBareControlCInterrupt() {
        #expect(classify(LinuxStatusKeystroke.escape) == .interrupt)
        #expect(classify(LinuxStatusKeystroke.escape, LinuxStatusKeystroke.shiftMask) == .interrupt)
        #expect(classify(0x63, LinuxStatusKeystroke.controlMask, base: "c") == .interrupt)
    }

    @Test func controlCWithAnotherModifierIsPlainTyping() {
        let mods = LinuxStatusKeystroke.controlMask | LinuxStatusKeystroke.shiftMask
        #expect(classify(0x63, mods, base: "c") == .other)
        #expect(classify(0x63, LinuxStatusKeystroke.controlMask, base: "j") == .other)
        #expect(classify(0x63, 0, base: "c") == .other)
    }

    @Test func nonLatinLayoutStillInterruptsOnTheCPosition() {
        // a Cyrillic layout reports the base letter it produces, and the keyval is that letter too
        #expect(classify(0x6441, LinuxStatusKeystroke.controlMask, base: "c") == .interrupt)
    }

    @Test func bareReturnSubmitsAndAModifiedOneDoesNot() {
        #expect(classify(LinuxStatusKeystroke.returnKey) == .submit)
        #expect(classify(LinuxStatusKeystroke.keypadEnter) == .submit)
        #expect(classify(LinuxStatusKeystroke.isoEnter) == .submit)
        #expect(classify(LinuxStatusKeystroke.returnKey, LinuxStatusKeystroke.shiftMask) == .other)
        #expect(classify(LinuxStatusKeystroke.returnKey, LinuxStatusKeystroke.altMask) == .other)
    }

    @Test func capsLockIsNoModifier() {
        let lock: UInt32 = 1 << 1
        #expect(classify(LinuxStatusKeystroke.returnKey, lock) == .submit)
        #expect(classify(0x63, LinuxStatusKeystroke.controlMask | lock, base: "c") == .interrupt)
    }

    @Test func anOrdinaryKeyIsPlainTyping() {
        #expect(classify(0x61, base: "a") == .other)
    }
}
