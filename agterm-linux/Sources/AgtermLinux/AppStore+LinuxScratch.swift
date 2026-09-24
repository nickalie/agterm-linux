import Foundation
import agtermCore

@MainActor
extension AppStore {
    /// `session.scratch`'s model half, upstream's order: a command replaces the shell, and replacing a
    /// visible one is a net no-op that emits no `pane.scratch` pair. `settle` runs between the teardown and
    /// the re-show, so the host drops the old widget before a new one is realized for the same session.
    func applyScratchRequest(_ id: UUID, want: Bool, command: String?, settle: () -> Void) {
        guard let session = session(withID: id) else { return }
        let replacing = want && !(command ?? "").isEmpty
        let respawningVisible = replacing && session.scratchActive && session.scratchSurface != nil
        if replacing, let command {
            if closeScratch(id, emitVisibility: !respawningVisible) { settle() }
            session.scratchCommand = command
        }
        if want != session.scratchActive { toggleScratch(id, emitVisibility: !respawningVisible) }
    }
}
