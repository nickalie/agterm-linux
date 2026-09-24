import CGtk
import Foundation

/// A repeating GLib timeout owned by one subsystem, the Linux side of a re-arming timer that `MainTimer`
/// deliberately does not offer (`agterm-linux/docs/main-loop.md`). The source retains this object and its
/// destroy notify releases it, on the stop path and on `cancel` alike.
@MainActor
final class LinuxRepeatingTimer {
    private var sourceID: guint = 0
    /// Returns false to stop repeating.
    private let tick: @MainActor () -> Bool

    init(interval: TimeInterval, tick: @escaping @MainActor () -> Bool) {
        self.tick = tick
        let ms = guint(min(max(1, (interval * 1000).rounded()), Double(guint.max)))
        sourceID = g_timeout_add_full(G_PRIORITY_DEFAULT, ms, onLinuxRepeatingTimerTick,
                                      Unmanaged.passRetained(self).toOpaque(), releaseLinuxRepeatingTimer)
    }

    var isRunning: Bool { sourceID != 0 }

    fileprivate func fired() -> gboolean {
        guard sourceID != 0, tick() else {
            sourceID = 0
            return 0
        }
        return 1
    }

    func cancel() {
        guard sourceID != 0 else { return }
        let id = sourceID
        sourceID = 0
        _ = g_source_remove(id)
    }
}

private let onLinuxRepeatingTimerTick: @MainActor @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    let timer = Unmanaged<LinuxRepeatingTimer>.fromOpaque(data).takeUnretainedValue()
    return MainActor.assumeIsolated { timer.fired() }
}

private let releaseLinuxRepeatingTimer: @MainActor @convention(c) (gpointer?) -> Void = { data in
    guard let data else { return }
    Unmanaged<LinuxRepeatingTimer>.fromOpaque(data).release()
}
