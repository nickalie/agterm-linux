import Foundation

/// The keys a shortcut consumed, held until their release so the OS repeats of a held chord neither refire
/// it nor reach the terminal: upstream's `CustomCommandRunner.consumedKeyCodes`.
///
/// GTK 4 key events carry no repeat flag, so a press of a key still owned counts as its repeat. A release
/// can land outside agterm, and then ownership lapses once no repeat has arrived for `repeatWindow`, so the
/// next deliberate press fires instead of being swallowed as a stale repeat.
struct LinuxKeyPressOwnership {
    /// Longer than any desktop's configurable initial repeat delay.
    static let repeatWindow: TimeInterval = 2

    private var lastSeen: [UInt32: TimeInterval] = [:]

    /// Whether `keycode`'s press is a repeat of an owned press, refreshing the ownership when it is.
    mutating func isOwnedRepeat(_ keycode: UInt32, now: TimeInterval) -> Bool {
        guard let seen = lastSeen[keycode], now - seen <= Self.repeatWindow else {
            lastSeen[keycode] = nil
            return false
        }
        lastSeen[keycode] = now
        return true
    }

    mutating func claim(_ keycode: UInt32, now: TimeInterval) {
        lastSeen[keycode] = now
    }

    @discardableResult
    mutating func release(_ keycode: UInt32) -> Bool {
        lastSeen.removeValue(forKey: keycode) != nil
    }
}

/// App-wide like the keyboard itself: an action that opens another window moves the held key's repeats
/// there, and they must stay consumed.
@MainActor var gKeyPressOwnership = LinuxKeyPressOwnership()
