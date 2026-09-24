import Foundation
import agtermCore

/// `session.background` on GTK. The store owns the default and the per-pane overrides and moves or drops
/// them on swap, promotion and pane close; this applies them to the live surfaces.
@MainActor
extension AppController {
    func setSessionBackground(_ target: String?, window: String?,
                              options: ControlSessionBackgroundOptions) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session")
            }
            if let error = session.missingBackgroundPaneError(options.pane) {
                return ControlResponse(ok: false, error: error)
            }
            guard store.setBackgroundWatermark(options.watermark, forSession: id, pane: options.pane) else {
                return ok(id)
            }
            if options.watermark == nil, options.pane == nil { WatermarkStorage.removeRenderedText(sessionID: id) }
            for pane in session.backgroundPanesToApply(options.pane) {
                backgroundSurface(pane, of: id)?.applyWatermarkFromSession()
            }
            return ok(id)
        }
    }

    private func backgroundSurface(_ pane: StatusPane, of id: UUID) -> GhosttySurface? {
        switch pane {
        case .left: surfaces[id]
        case .right: splitSurfaces[id]
        case .scratch: scratchSurfaces[id]
        }
    }
}

extension Session {
    /// linuxBackground is what a surface in `pane` renders; a nil pane (a pane overlay) takes the default.
    func linuxBackground(for pane: StatusPane?) -> BackgroundWatermark? {
        pane.map(effectiveBackground(for:)) ?? backgroundWatermark
    }

    /// backgroundPaneKey names the rendered text file of `pane`'s override, nil when it inherits the default.
    func backgroundPaneKey(for pane: StatusPane?) -> String? {
        guard let pane, paneBackgrounds[pane] != nil else { return nil }
        return backgroundFileKey(for: pane)
    }

    /// missingBackgroundPaneError refuses an override that would outlive nothing and land on the next pane.
    func missingBackgroundPaneError(_ pane: StatusPane?) -> String? {
        switch pane {
        case .right where !hasSplit: "session has no split pane"
        case .scratch where scratchSurface == nil: "session has no scratch terminal"
        default: nil
        }
    }

    /// backgroundPanesToApply skips overridden panes on a default change: re-applying one drops its OSC 11 latch.
    func backgroundPanesToApply(_ pane: StatusPane?) -> [StatusPane] {
        pane.map { [$0] } ?? StatusPane.allCases.filter { paneBackgrounds[$0] == nil }
    }
}
