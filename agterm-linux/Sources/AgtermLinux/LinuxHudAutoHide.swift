import Foundation
import agtermCore

/// The HUD auto-hide timers, one per session: upstream's `ControlServer.hudAutoHide`/`armHudAutoHide`.
/// App-wide because a session outlives any one window's controller, and scheduled through `MainTimer`,
/// which is the only timer the GLib loop fires.
@MainActor
final class LinuxHudAutoHide {
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    /// The revision makes a superseded fire inert: an update restarts the interval without replacing the
    /// panel's surface, so nothing else tells an old timer from the live one.
    struct Entry {
        let revision: Int
        /// When the panel comes down, sampled for a viewer's remaining lifetime.
        let deadline: Date
        let cancel: @MainActor () -> Void
    }

    private(set) var entries: [UUID: Entry] = [:]
    /// Sessions whose HUD body rewrite is already queued for this main-loop turn (`watchHudGeometry`).
    var geometryPending: Set<UUID> = []
    private let schedule: Schedule
    private let clock: () -> Date

    init(schedule: @escaping Schedule = { MainTimer.schedule(after: $0, $1) }, clock: @escaping () -> Date = Date.init) {
        self.schedule = schedule
        self.clock = clock
    }

    /// Replaces whatever was armed for `session` and returns the new deadline, nil for a spec with no
    /// auto-hide. Called only after the body write succeeded, so a rejected open or update keeps the
    /// deadline the panel on screen came with. Cancellation rides `Session.onHudDiscarded`, which every
    /// store teardown of the panel calls.
    @discardableResult
    func arm(_ session: Session, spec: HudSpec, expire: @escaping @MainActor (UUID) -> Void) -> Date? {
        let id = session.id
        let revision = (entries[id]?.revision ?? 0) + 1
        cancel(id)
        // clamped as well as validated, so a raw-socket value past a drifted validation cannot overflow
        let seconds = min(spec.effectiveHideAfter, HudSpec.maxHideAfter)
        guard seconds > 0 else { return nil }
        let cancelTimer = schedule(seconds) { [weak self] in
            guard let self, self.entries[id]?.revision == revision else { return }
            self.entries[id] = nil
            expire(id)
        }
        let deadline = clock().addingTimeInterval(seconds)
        entries[id] = Entry(revision: revision, deadline: deadline, cancel: cancelTimer)
        session.onHudDiscarded = { [weak self] in
            MainActor.assumeIsolated { self?.cancel(id) }
        }
        return deadline
    }

    func cancel(_ id: UUID) {
        entries[id]?.cancel()
        entries[id] = nil
    }

    func now() -> Date { clock() }
}

@MainActor let gHudAutoHide = LinuxHudAutoHide()
