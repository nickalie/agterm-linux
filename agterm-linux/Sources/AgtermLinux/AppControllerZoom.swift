import CGtk
import agtermCore

@MainActor
extension AppController {
    /// This window's zoom target, quick panel included. Upstream detached its quick terminal into one
    /// app-global panel and so dropped `.quick` from `TerminalZoomController`; the Linux panel still lives in
    /// this window's overlay, which keeps it a surface this window can zoom and this the only place that
    /// precedence is spelled.
    func resolveZoomTarget() -> TerminalZoomTarget? {
        quickVisible ? .quick : TerminalZoomController.resolveTarget(store: store)
    }

    /// The counterpart gate: core answers `.quick` invalid unconditionally for the same reason.
    func isZoomTargetValid(_ target: TerminalZoomTarget) -> Bool {
        target == .quick ? quickVisible : TerminalZoomController.isTargetValid(target, in: store)
    }

    func clearInvalidTerminalZoom() {
        guard let target = terminalZoom.target, !isZoomTargetValid(target) else { return }
        setTerminalZoom(.off, target: target)
    }

    func setTerminalZoom(_ mode: ControlToggleMode, target: TerminalZoomTarget?) {
        if mode != .off, dashboard.isOpen { closeDashboard(refocus: false) }
        let old = terminalZoom.target
        terminalZoom.set(mode, target: target)
        let new = terminalZoom.target
        guard old != new else { return }
        if let old { restoreZoomedSurface(old) }
        if let new, !hostZoomedSurface(new) {
            terminalZoom.clear()
        }
        let zoomed = terminalZoom.target != nil
        gtk_widget_set_visible(W(splitView), zoomed ? 0 : 1)
        if let host = zoomHost { gtk_widget_set_visible(W(host), zoomed ? 1 : 0) }
        if !zoomed { showActive() }
    }

    func surface(for target: TerminalZoomTarget) -> GhosttySurface? {
        switch target {
        case .quick: return quickSurface
        case .session(let id, .primary): return surfaces[id]
        case .session(let id, .split): return splitSurfaces[id]
        case .session(let id, .scratch): return scratchSurfaces[id]
        case .session(let id, .overlay): return overlaySurfaces[id]
        case .session(let id, .overlayLeft): return paneOverlaySurfaces[id]?[.left]
        case .session(let id, .overlayRight): return paneOverlaySurfaces[id]?[.right]
        }
    }

    private func hostZoomedSurface(_ target: TerminalZoomTarget) -> Bool {
        guard let surface = surface(for: target), detach(surface.glArea, from: target),
              let deckOverlay else { return false }
        let host = OpaquePointer(adw_toolbar_view_new())
        let header = OpaquePointer(adw_header_bar_new())
        gtk_widget_set_halign(W(host), GTK_ALIGN_FILL)
        gtk_widget_set_valign(W(host), GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(W(host), 1)
        gtk_widget_set_vexpand(W(host), 1)
        gtk_widget_add_css_class(W(header), "agterm-modal-header")
        let decorationLayout = LinuxDesktopEnvironment.hidesClientSideWindowButtons() ? ":" : "close,minimize,maximize:"
        decorationLayout.withCString { adw_header_bar_set_decoration_layout(header, $0) }
        let title = LinuxModalTitle.normal(
            sessionName: store.activeSession?.displayName,
            window: library.windows.first(where: { $0.id == windowID }))
        let titleLabel = OpaquePointer(gtk_label_new(title))
        gtk_widget_add_css_class(W(titleLabel), "title")
        adw_header_bar_set_title_widget(header, W(titleLabel))

        let exit = OpaquePointer(gtk_button_new_with_label("Exit Terminal Zoom"))
        gtk_widget_set_tooltip_text(W(exit), "Exit Terminal Zoom")
        connect(exit, "clicked", unsafeBitCast(onTerminalZoomExit, to: GCallback.self))
        adw_header_bar_pack_end(header, W(exit))
        adw_toolbar_view_add_top_bar(host, W(header))
        adw_toolbar_view_set_content(host, W(surface.glArea))
        if linuxSettingsStore().load().effectiveToolbarMode == .hidden {
            gtk_widget_set_visible(W(header), 0)
        }
        gtk_overlay_add_overlay(deckOverlay, W(host))
        zoomHost = host
        zoomHeader = header
        zoomTitleLabel = titleLabel
        surface.grabFocus()
        surface.refresh()
        g_object_unref(RAW(surface.glArea))
        return true
    }

    func detach(_ widget: OpaquePointer, from target: TerminalZoomTarget) -> Bool {
        _ = g_object_ref(RAW(widget))
        switch target {
        case .quick:
            guard let frame = quickFrame else { g_object_unref(RAW(widget)); return false }
            gtk_frame_set_child(cast(frame), nil)
            gtk_widget_set_visible(W(frame), 0)
        // A pane's terminal is the main child of its host overlay; a pane overlay is a layer on top of it.
        case .session(let id, .primary):
            guard let host = paneHosts[id]?[.left] else { g_object_unref(RAW(widget)); return false }
            gtk_overlay_set_child(host, nil)
        case .session(let id, .split):
            guard let host = paneHosts[id]?[.right] else { g_object_unref(RAW(widget)); return false }
            gtk_overlay_set_child(host, nil)
        case .session(let id, .overlayLeft):
            guard let host = paneHosts[id]?[.left] else { g_object_unref(RAW(widget)); return false }
            gtk_overlay_remove_overlay(host, W(widget))
        case .session(let id, .overlayRight):
            guard let host = paneHosts[id]?[.right] else { g_object_unref(RAW(widget)); return false }
            gtk_overlay_remove_overlay(host, W(widget))
        case .session(let id, .scratch), .session(let id, .overlay):
            guard let stack = sessionStacks[id] else { g_object_unref(RAW(widget)); return false }
            if let frame = floatingOverlayFrames[id], target == .session(id, .overlay) {
                gtk_frame_set_child(cast(frame), nil)
            } else {
                gtk_stack_remove(stack, W(widget))
            }
        }
        return true
    }

    private func restoreZoomedSurface(_ target: TerminalZoomTarget) {
        guard let surface = surface(for: target), let host = zoomHost, let deckOverlay else { return }
        _ = g_object_ref(RAW(surface.glArea))
        adw_toolbar_view_set_content(host, nil)
        gtk_overlay_remove_overlay(deckOverlay, W(host))
        zoomHost = nil
        zoomHeader = nil
        zoomTitleLabel = nil
        reattach(surface.glArea, to: target)
        g_object_unref(RAW(surface.glArea))
        surface.refresh()
    }

    func reattach(_ widget: OpaquePointer, to target: TerminalZoomTarget) {
        switch target {
        case .quick:
            if let frame = quickFrame {
                gtk_frame_set_child(cast(frame), W(widget))
                gtk_widget_set_visible(W(frame), quickVisible ? 1 : 0)
            }
        case .session(let id, .primary):
            if let host = paneHosts[id]?[.left] { gtk_overlay_set_child(host, W(widget)) }
        case .session(let id, .split):
            if let host = paneHosts[id]?[.right] { gtk_overlay_set_child(host, W(widget)) }
        case .session(let id, .overlayLeft):
            if let host = paneHosts[id]?[.left] { gtk_overlay_add_overlay(host, W(widget)) }
        case .session(let id, .overlayRight):
            if let host = paneHosts[id]?[.right] { gtk_overlay_add_overlay(host, W(widget)) }
        case .session(let id, .scratch):
            if let stack = sessionStacks[id] {
                "scratch".withCString { _ = gtk_stack_add_named(stack, W(widget), $0) }
            }
        case .session(let id, .overlay):
            if let frame = floatingOverlayFrames[id] {
                gtk_frame_set_child(cast(frame), W(widget))
            } else if let stack = sessionStacks[id] {
                "overlay".withCString { _ = gtk_stack_add_named(stack, W(widget), $0) }
            }
        }
    }
}

private let onTerminalZoomExit: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated {
        controllerForWidget(button)?.setTerminalZoom(.off, target: nil)
    }
}
