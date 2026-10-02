import CGtk
import Foundation
import agtermCore

/// HTML pages in the overlay slots (`session.overlay.open --html|--url`), on the plugin `LinuxWebKit` loads.
/// A page is a third occupant beside a program and a HUD: `control-api.md` owns the contract.
@MainActor
extension AppController {
    /// syncHtmlCover mounts the session-wide page and is true while one holds the slot; otherwise it drops a
    /// floating frame a page left behind, which no overlay surface owns.
    func syncHtmlCover(_ s: Session, stack: OpaquePointer, allowFocus: Bool) -> Bool {
        guard s.htmlOverlayActive, let overlay = s.htmlOverlay else {
            if overlaySurfaces[s.id] == nil { removeFloatingOverlayFrame(s.id) }
            return false
        }
        let target: LinuxHtmlMount
        if s.overlaySizePercent != nil, let frame = floatingOverlayFrames[s.id] ?? makeFloatingOverlayFrame(s) {
            target = .frame(frame)
            applyFloatingOverlayGeometry(frame, session: s)
        } else {
            removeFloatingOverlayFrame(s.id)
            target = .stack(stack)
        }
        guard LinuxHtmlOverlays.shared.show(overlay, store: store, backgroundColor: s.overlayBackgroundColor,
                                            at: target) != nil else { return true }
        if case .stack = target { "overlay".withCString { gtk_stack_set_visible_child_name(stack, $0) } }
        if allowFocus, s.id == store.selectedSessionID { LinuxHtmlOverlays.shared.focusCover(of: s) }
        return true
    }

    /// syncHtmlPane mounts `pane`'s page on its host and is true while one holds that slot.
    func syncHtmlPane(_ s: Session, _ pane: OverlayPane, allowFocus: Bool) -> Bool {
        guard let host = paneHosts[s.id]?[pane] else { return s.paneOverlayIsHtml(pane) }
        guard let overlay = s.paneOverlay(pane), let page = overlay.html else {
            LinuxHtmlOverlays.shared.clear(.paneHost(host))
            return false
        }
        _ = LinuxHtmlOverlays.shared.show(page, store: store, backgroundColor: overlay.backgroundColor, at: .paneHost(host))
        if allowFocus, s.id == store.selectedSessionID, s.topmostHtmlOverlay?.id == page.id {
            LinuxHtmlOverlays.shared.focusCover(of: s)
        }
        return true
    }

    /// makeFloatingOverlayFrame is the framed card a sized overlay sits in, registered for its session.
    func makeFloatingOverlayFrame(_ s: Session) -> OpaquePointer? {
        guard let overlay = deckOverlay, let frame = op(gtk_frame_new(nil)) else { return nil }
        gtk_widget_add_css_class(W(frame), "card")
        gtk_widget_add_css_class(W(frame), "agterm-quick")
        gtk_widget_set_overflow(W(frame), GTK_OVERFLOW_HIDDEN)   // clip GL child to the rounded card; see LinuxQuickCardPolicy
        gtk_widget_set_halign(W(frame), GTK_ALIGN_CENTER)
        gtk_overlay_add_overlay(overlay, W(frame))
        gtk_widget_set_visible(W(frame), s.id == store.selectedSessionID ? 1 : 0)
        floatingOverlayFrames[s.id] = frame
        return frame
    }

    func removeFloatingOverlayFrame(_ id: UUID) {
        guard let frame = floatingOverlayFrames.removeValue(forKey: id) else { return }
        LinuxHtmlOverlays.shared.clear(.frame(frame))
        if let overlay = deckOverlay { gtk_overlay_remove_overlay(overlay, W(frame)) }
    }

    // MARK: - Zoom

    /// resizeFont is the font keys, palette and menu: a page owning the keys zooms every page instead, since the
    /// focused surface would be the terminal it hides. An open dashboard hides every page, so it keeps the terminal.
    func resizeFont(_ action: String, origin: GhosttySurface? = nil) {
        if origin == nil, htmlPageOwnsKeys {
            stepHtmlOverlayZoom(action)
            return
        }
        (origin ?? focusedSurface())?.performBindingAction(action)
    }

    /// htmlPageOwnsKeys is true when a page covers the active session while focus sits outside its terminals: on
    /// the page itself, or on the sidebar.
    private var htmlPageOwnsKeys: Bool {
        guard !dashboard.isOpen, let session = store.activeSession, session.topmostHtmlOverlay != nil else { return false }
        let id = session.id
        let terminals = [surfaces[id], splitSurfaces[id], scratchSurfaces[id], overlaySurfaces[id]].compactMap { $0 }
            + (paneOverlaySurfaces[id].map { Array($0.values) } ?? [])
        return !terminals.contains { gtk_widget_has_focus(W($0.glArea)) != 0 }
    }

    /// stepHtmlOverlayZoom moves every page's zoom by a font binding action and persists it.
    func stepHtmlOverlayZoom(_ action: String) {
        guard let zoom = HtmlZoom.applying(fontAction: action, to: LinuxHtmlOverlays.shared.zoom) else { return }
        persist(\.htmlOverlayZoom, zoom == 1 ? nil : zoom)
        LinuxHtmlOverlays.shared.setZoom(zoom)
    }

    // MARK: - Control

    func openHtmlOverlay(_ id: UUID, page source: HtmlSource, options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        if let reason = LinuxHtmlOverlays.shared.unavailable { return err(reason) }
        if store.session(withID: id)?.remoteOverlays.slot(options.pane) != nil {
            return err(options.pane == nil ? "overlay already open" : PaneOverlayError.alreadyOpen)
        }
        let overlay = HtmlOverlay(source: source, navigation: options.navigation, javascript: options.javascript)
        if let failure = store.openHtmlOverlay(id, pane: options.pane, overlay: overlay, sizePercent: options.sizePercent,
                                               backgroundColor: options.backgroundColor) {
            return err(failure.message(pane: options.pane))
        }
        if options.follow { selectSession(id, userInitiated: false) }
        reconcile()
        return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, pageID: overlay.id.uuidString))
    }

    func submitSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?, value: String) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let failure = store.submitHtmlOverlay(id, pane: pane, value: value) { return err(failure.message) }
            reconcile()
            return ok(id)
        }
    }

    func reloadSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?, current: Bool) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let failure = LinuxHtmlOverlays.shared.reload(sessionID: id, pane: pane, target: current ? .current : .original,
                                                             store: store) {
                return err(failure.message)
            }
            return ok(id)
        }
    }

    func navigateSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?,
                                navigation: HtmlNavigation) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let failure = store.htmlOverlayCommandFailure(id, pane: pane) { return err(failure.message) }
            let session = store.session(withID: id)
            guard let page = pane.map({ session?.paneOverlay($0)?.html }) ?? session?.htmlOverlay else {
                return err(OverlayHtmlError.notHtml)
            }
            if let error = LinuxHtmlOverlays.shared.navigate(page.id, navigation) { return err(error) }
            return ok(id)
        }
    }
}
