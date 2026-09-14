import agtermCore

enum FontBindingAction {
    static let increase = "increase_font_size:1"
    static let decrease = "decrease_font_size:1"
    static let reset = "reset_font_size"
}

extension BuiltinAction {
    var linuxDefaultChord: Chord? {
        switch self {
        case .newWindow: return Chord(mods: [.control, .shift], key: "n")
        case .newWorkspace: return Chord(mods: [.control, .shift], key: "w")
        case .newSession: return Chord(mods: [.control, .shift], key: "t")
        case .openDirectory: return Chord(mods: [.control, .shift], key: "o")
        case .closeSession: return Chord(mods: [.control, .shift], key: "q")
        case .toggleSplit: return Chord(mods: [.control, .shift], key: "d")
        // macOS pairs the two splits as Cmd-D / Cmd-Shift-D. Linux already spends Shift on every default,
        // so the top/bottom sibling takes H for horizontal rather than a second modifier.
        case .toggleHorizontalSplit: return Chord(mods: [.control, .shift], key: "h")
        case .dashboard: return Chord(mods: [.control, .shift], key: "m")
        case .toggleScratch: return Chord(mods: [.control, .shift], key: "j")
        case .toggleSearch: return Chord(mods: [.control, .shift], key: "f")
        case .toggleSidebar: return Chord(mods: [.control, .shift], key: "s")
        case .toggleFlag: return Chord(mods: [.control, .shift], key: "g")
        case .quickTerminal: return Chord(mods: [.control], key: "`")
        case .sessionPalette: return Chord(mods: [.control], key: "p")
        case .commandPalette: return Chord(mods: [.control, .shift], key: "p")
        // Ctrl+Shift+O belongs to Open Directory on Linux. Keep the custom-command palette keyless so
        // restoring a reserved Open Directory override cannot create a default-vs-default collision.
        case .customCommandPalette: return nil
        case .showAttention: return Chord(mods: [.control, .shift], key: "i")
        default: return nil
        }
    }
}

/// What a GTK key press means to an agent-status glyph. The shared `InterruptKeystroke` classifier reads
/// macOS virtual key codes, so Linux answers the same question from the GDK keyval and modifier state.
enum LinuxStatusKeystroke {
    static let escape: UInt32 = 0xFF1B
    static let returnKey: UInt32 = 0xFF0D
    static let keypadEnter: UInt32 = 0xFF8D
    static let isoEnter: UInt32 = 0xFE34

    static let shiftMask: UInt32 = 1 << 0
    static let controlMask: UInt32 = 1 << 2
    static let altMask: UInt32 = 1 << 3
    static let superMask: UInt32 = 1 << 26

    /// Interrupt first, then submit, else plain typing — the order `InterruptKeystroke.classify` uses.
    /// `baseCharacter` is the layout's unshifted letter, so a Cyrillic or Greek layout still interrupts on
    /// the physical C key; the caller reads it with `gdk_keyval_to_unicode`. Caps Lock is ignored
    /// throughout: it is no modifier a user meant to hold.
    static func classify(keyval: UInt32, state: UInt32, baseCharacter: Unicode.Scalar?) -> StatusKeystroke {
        if isInterrupt(keyval: keyval, state: state, baseCharacter: baseCharacter) { return .interrupt }
        return isSubmit(keyval: keyval, state: state) ? .submit : .other
    }

    static func isInterrupt(keyval: UInt32, state: UInt32, baseCharacter: Unicode.Scalar?) -> Bool {
        if keyval == escape { return true }
        let others = shiftMask | altMask | superMask
        guard state & controlMask != 0, state & others == 0 else { return false }
        return baseCharacter?.value == 0x63
    }

    /// Return, keypad Enter or the ISO variant with NO modifier held. Shift-Return and Alt-Return insert a
    /// newline in Claude Code and Codex, so they stay plain typing.
    static func isSubmit(keyval: UInt32, state: UInt32) -> Bool {
        guard keyval == returnKey || keyval == keypadEnter || keyval == isoEnter else { return false }
        return state & (shiftMask | controlMask | altMask | superMask) == 0
    }
}
