import Foundation
import agtermCore

/// Turns a `SpawnPacer` grant back into a spawn. The pacer is host-free and knows only pane keys, so the
/// app owns one registry mapping a granted key to the surface waiting on it.
///
/// Entries are WEAK: a pane the user closed, or one whose window went away before its turn, is dropped
/// rather than resurrected by its own grant.
@MainActor
final class LinuxSpawnRegistry {
    private struct Entry {
        weak var surface: GhosttySurface?
    }

    private var entries: [UUID: Entry] = [:]

    init(pacer: SpawnPacer) {
        pacer.onGrant = { [weak self] key in self?.grant(key) }
    }

    /// Enrolls `surface` under `key` when this pane will actually replay a program, and drops the key from
    /// the expected order otherwise — an expected key nobody claims stalls the queue at its head.
    func enqueue(_ surface: GhosttySurface, key: UUID?, paces: Bool) {
        guard let key else { return }
        guard paces else {
            gSpawnPacer.discard(key)
            return
        }
        entries[key] = Entry(surface: surface)
        surface.useSpawnPacer(gSpawnPacer, key: key)
    }

    /// Spawns the granted pane and forgets it: a key is granted once. A burst or expedited key is granted
    /// synchronously inside the pane's own `request`, while its `createSurface` is still on the stack, so
    /// only a pane DENIED earlier has a spawn left to re-enter.
    private func grant(_ key: UUID) {
        guard let surface = entries.removeValue(forKey: key)?.surface, surface.awaitingSpawnPermit else {
            return
        }
        surface.spawnOnPermit()
    }
}

@MainActor let gSpawnPacer = SpawnPacer()
@MainActor let gSpawnRegistry = LinuxSpawnRegistry(pacer: gSpawnPacer)
