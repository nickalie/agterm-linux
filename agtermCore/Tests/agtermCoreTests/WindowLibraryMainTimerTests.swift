import Foundation
import Testing
@testable import agtermCore

/// The fork's `MainTimer`-seam cases, kept out of the upstream suite's file for its length limit.
extension WindowLibraryTests {
    @Test func debouncedSelectionSavePersistsOnlyWhenTheTimerFires() throws {
        // The cancel-contract test above asserts the pending save is DROPPED; this one pins the other
        // leg — that the debounced save reaches disk through the `MainTimer` seam at all. Without a
        // firing timer the selection never persists until the quit-flush, which is precisely what the
        // GLib main loop did on Linux (the seam is what makes the write land there).
        let library = WindowLibrary(directory: directory)
        let windowID = library.windows[0].id
        let store = try #require(library.store(for: windowID))
        let workspace = try #require(store.workspaces.first)
        let first = try #require(workspace.sessions.first)
        // structural add: selects the new session and saves synchronously, so disk starts at `second`
        let second = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "second"))
        #expect(persistedSelection(windowID) == second.id)

        // The fake records EVERY schedule (the global seam catches unrelated debouncers too), then fires
        // the one this test wants — selected by delay, never by position.
        try withFakeMainTimer { timers in
            store.selectSession(first.id)
            #expect(persistedSelection(windowID) == second.id) // deferred: the click has not reached disk yet
            let saveEntry = try #require(timers.index(ofDelay: 0.3)) // AppStore.saveDebounceInterval
            timers.fire(saveEntry)
            #expect(persistedSelection(windowID) == first.id)  // the timer is what persists the selection

            // a structural save cancels the pending debounced entry, so a stale snapshot can't land after it
            store.selectSession(second.id)
            let pending = try #require(timers.lastIndex(ofDelay: 0.3))
            #expect(!timers.cancelled.contains(pending))
            store.save()
            #expect(timers.cancelled.contains(pending))
            #expect(persistedSelection(windowID) == second.id)
        }
    }

    @Test func finalizingPendingClosesBeforeRemoveWindowLeavesNoOrphanFile() throws {
        // `removeWindow`'s `cancelPendingSave()` only disarms the STORE's debounced save; the soft-close
        // grace finalizer is a separate store-scoped timer it never touches, and that one also ends in
        // `save()`. A grace still running when the window is deleted would therefore re-create
        // `windows/<id>.json` as an orphan — a future index loss resurrects it via
        // `recoverOrphanedWindows()`. The window-teardown paths (`windowWillClose`, and the quit flush via
        // `WindowLibrary.finalizeAllPendingCloses`) close the grace out FIRST, which is what this pins:
        // finalize disarms the entry, so even the host timer the GLib loop already armed fires inert.
        let library = WindowLibrary(directory: directory)
        let extra = library.newWindow(name: "extra")
        let store = try #require(library.store(for: extra.id))   // the willClose/dialog retention
        let doomed = try #require(store.workspaces.first?.sessions.first)
        try withFakeMainTimer { timers in
            #expect(store.softCloseSession(doomed.id, grace: 7))  // an unmistakable delay, never a debouncer's
            let grace = try #require(timers.index(ofDelay: 7))
            #expect(!timers.cancelled.contains(grace))

            library.finalizeAllPendingCloses()   // what the window-teardown paths now drive
            #expect(timers.cancelled.contains(grace))
            #expect(store.pendingCloseSummary == nil)   // the record is gone, not merely disarmed

            library.removeWindow(extra.id)
            #expect(!FileManager.default.fileExists(atPath: windowFileURL(extra.id).path))
            timers.fireEvenIfCancelled(grace)    // the late host fire the GLib timer had already armed
            #expect(!FileManager.default.fileExists(atPath: windowFileURL(extra.id).path))
        }
        _ = store   // keep the store alive through the late fire (mirrors the retained-controller case)
    }

    /// The `selectedSessionID` as persisted in `windows/<id>.json` — the debounced save's observable effect.
    private func persistedSelection(_ windowID: UUID) -> UUID? {
        PersistenceStore(directory: directory.appendingPathComponent("windows"),
                         fileName: "\(windowID.uuidString).json").load().selectedSessionID
    }
}
