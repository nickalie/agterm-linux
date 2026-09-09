import CGtk
import Foundation
import agtermCore

/// The two GTK presentations of a pending ask and the input arbitration around them.
///
/// The terminal style is a panel inside the deck overlay, drawn in the terminal theme's own colors and
/// monospace face and clipped to the anchored pane, so a split's other pane keeps its keyboard. The GUI
/// style is a transient modal window with ordinary GTK buttons, which is what this desktop's question
/// dialog is; it takes the window's modal slot beside `pick`.
/// The widgets and keyboard state behind the two ask presentations. One property on `AppController`
/// rather than six, since none of it is meaningful apart from the rest.
@MainActor
struct LinuxAskWidgets {
    /// Terminal-style panel and its buttons, one per owning session.
    var sessionFrames: [UUID: OpaquePointer] = [:]
    var sessionButtons: [UUID: [OpaquePointer]] = [:]
    /// The gui-style dialog, which takes the window's modal slot beside `pick`.
    var guiWindow: OpaquePointer?
    var guiButtons: [OpaquePointer] = []
    /// Keyboard selection, keyed by ask id.
    var navigations: [String: AskNavigation] = [:]
    /// The terminal panel's theme CSS, display-wide and replaced on every rebuild.
    static var styleProvider: OpaquePointer?
}

@MainActor
extension AppController {
    // MARK: - Terminal style

    /// Rebuilds the deck panels to match the store: one per session holding a pending terminal ask. Called
    /// from `reconcile` and after every ask mutation, so a resize, a pane swap or a reselection re-places
    /// a live dialog without the caller knowing about widgets.
    /// This window's modal slots: the pick controller, which also holds a GUI ask, and the ask registry's
    /// owner lookup. One indirection for both owners, so `ask.result` reads whichever live slot holds the
    /// id rather than a second copy the registry would have to keep in step.
    func registerModalSlots() {
        PickRegistry.shared.register(windowID, controller: pickController)
        AskRegistry.shared.resolveOwner = { owner in
            switch owner {
            case .window(let id): gWindows[id]?.pickController.pendingAsk
            case .session(let id, let window): gWindows[window]?.store.session(withID: id)?.askPending
            }
        }
    }

    func syncSessionAsks() {
        for (id, frame) in askWidgets.sessionFrames where store.session(withID: id)?.askPending == nil {
            removeSessionAskFrame(id, frame: frame)
        }
        for workspace in store.workspaces {
            for session in workspace.sessions where session.askPending != nil {
                if askWidgets.sessionFrames[session.id] == nil { buildSessionAskFrame(session) }
                applySessionAskGeometry(session)
            }
        }
        updateSessionAskVisibility()
    }

    private func removeSessionAskFrame(_ id: UUID, frame: OpaquePointer) {
        if let overlay = deckOverlay { gtk_overlay_remove_overlay(overlay, W(frame)) }
        askWidgets.sessionFrames[id] = nil
        askWidgets.sessionButtons[id] = nil
    }

    private func buildSessionAskFrame(_ session: Session) {
        guard let overlay = deckOverlay, let ask = session.askPending,
              let frame = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)) else { return }
        gtk_widget_add_css_class(W(frame), "agterm-ask")
        gtk_widget_set_focusable(W(frame), 1)
        applyTerminalAskStyle()

        if let title = op(gtk_label_new(ask.title)) {
            gtk_label_set_xalign(title, 0)
            gtk_label_set_wrap(title, 1)
            gtk_widget_add_css_class(W(title), "agterm-ask-title")
            gtk_box_append(cast(frame), W(title))
        }
        if let message = ask.message, let label = op(gtk_label_new(message)) {
            gtk_label_set_xalign(label, 0)
            gtk_label_set_wrap(label, 1)
            gtk_widget_add_css_class(W(label), "agterm-ask-message")
            gtk_box_append(cast(frame), W(label))
        }
        let (row, buttons) = buildAskButtonRow(ask, terminalStyle: true)
        gtk_box_append(cast(frame), W(row))
        askWidgets.sessionButtons[session.id] = buttons

        let keys = gtk_event_controller_key_new()
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        connect(keys, "key-pressed", unsafeBitCast(
            onAskKey as @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean,
            to: GCallback.self))
        gtk_widget_add_controller(W(frame), keys)

        gtk_overlay_add_overlay(overlay, W(frame))
        askWidgets.sessionFrames[session.id] = frame
        refreshAskButtonStyles(ask, buttons: buttons)
    }

    /// Places the panel over its anchor. `GtkOverlay` measures margins from the deck's edges, so the pane's
    /// own inset is folded into the leading margin and both axes align to the start.
    private func applySessionAskGeometry(_ session: Session) {
        guard let frame = askWidgets.sessionFrames[session.id], let overlay = deckOverlay,
              let ask = session.askPending else { return }
        let deck = (width: gtk_widget_get_width(W(overlay)), height: gtk_widget_get_height(W(overlay)))
        let bounds = session.askTargetPane.flatMap { paneBoundsInDeck(session: session.id, pane: $0) }
        let area = (x: bounds.map { Int32($0.x) } ?? 0, y: bounds.map { Int32($0.y) } ?? 0,
                    width: bounds.map { Int32($0.width) } ?? deck.width,
                    height: bounds.map { Int32($0.height) } ?? deck.height)
        // `--width` fixes the panel to a percent of the anchor; content sizing otherwise, capped so a long
        // message can never overhang the pane it belongs to.
        let width = ask.width.map { area.width * Int32($0) / 100 } ?? (area.width * 9 / 10)
        gtk_widget_set_size_request(W(frame), max(width, 1), -1)
        let height = max(gtk_widget_get_height(W(frame)), 1)
        gtk_widget_set_halign(W(frame), GTK_ALIGN_START)
        gtk_widget_set_valign(W(frame), GTK_ALIGN_START)
        gtk_widget_set_margin_start(W(frame), area.x + max(0, (area.width - width) / 2))
        gtk_widget_set_margin_top(W(frame), area.y + max(0, (area.height - height) / 2))
        gtk_widget_set_margin_end(W(frame), 0)
        gtk_widget_set_margin_bottom(W(frame), 0)
    }

    /// A panel is drawn only while its session is selected and its anchor still renders, mirroring the HUD's
    /// visibility rule: zoom and the dashboard cover the deck, and a pane ask is hidden by the scratch.
    private func updateSessionAskVisibility() {
        for (id, frame) in askWidgets.sessionFrames {
            gtk_widget_set_visible(W(frame), sessionAskVisible(id) ? 1 : 0)
        }
        if let id = store.selectedSessionID, sessionAskWantsFocus(id), let frame = askWidgets.sessionFrames[id] {
            _ = gtk_widget_grab_focus(W(frame))
        }
    }

    func sessionAskVisible(_ id: UUID) -> Bool {
        guard let session = store.session(withID: id), session.askPending != nil,
              store.selectedSessionID == id, !dashboard.isOpen, terminalZoom.target == nil else { return false }
        guard session.askPaneIdentity != nil else { return true }
        guard let pane = session.askTargetPane else { return false }
        return session.rendersPane(pane) && !session.scratchActive
    }

    /// Whether the dialog, rather than a terminal pane, should hold the keyboard. A pane-scoped ask claims
    /// keys only while its own pane is the focused one, which is what lets an agent ask about one pane from
    /// the other without taking that other pane's keyboard away.
    func sessionAskWantsFocus(_ id: UUID) -> Bool {
        guard sessionAskVisible(id), gtk_window_is_active(WIN(windowPointer)) != 0,
              !pickController.modalPending, paletteWindow == nil, !quickVisible,
              let session = store.session(withID: id) else { return false }
        guard let target = session.askTargetPane else { return true }
        return target == (session.splitFocused ? .right : .left)
    }

    func resolveSessionAsk(_ sessionID: UUID, id: String, _ result: ControlAskResult) {
        guard let session = store.session(withID: sessionID) else { return }
        guard session.resolveAsk(id: id, result) else { return }
        askWidgets.navigations[id] = nil
        syncSessionAsks()
        MainTimer.schedule(after: 0) { [weak self] in self?.focusedSurface()?.grabFocus() }
    }

    // MARK: - GUI style

    func showGuiAsk(_ ask: PendingAsk) {
        guard let win = op(gtk_window_new()) else {
            pickController.cancelAsk()
            return
        }
        askWidgets.guiWindow = win
        attachControllerContext(to: win, windowID: windowID)
        connect(win, "destroy", unsafeBitCast(
            onGuiAskDestroyed as @convention(c) (OpaquePointer?, gpointer?) -> Void,
            to: GCallback.self), Unmanaged.passRetained(self).toOpaque())
        connect(win, "close-request", unsafeBitCast(
            onGuiAskCloseRequest as @convention(c) (OpaquePointer?, gpointer?) -> gboolean,
            to: GCallback.self))
        gtk_window_set_transient_for(WIN(win), WIN(windowPointer))
        gtk_window_set_modal(WIN(win), 1)
        ask.title.withCString { gtk_window_set_title(WIN(win), $0) }

        guard let box = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)) else { return }
        gtk_widget_add_css_class(W(box), "agterm-interface")
        for margin in [gtk_widget_set_margin_start, gtk_widget_set_margin_end,
                       gtk_widget_set_margin_top, gtk_widget_set_margin_bottom] {
            margin(W(box), 18)
        }
        if let title = op(gtk_label_new(ask.title)) {
            gtk_label_set_xalign(title, 0)
            gtk_label_set_wrap(title, 1)
            gtk_widget_add_css_class(W(title), "title-4")
            gtk_box_append(cast(box), W(title))
        }
        if let message = ask.message, let label = op(gtk_label_new(message)) {
            gtk_label_set_xalign(label, 0)
            gtk_label_set_wrap(label, 1)
            gtk_widget_add_css_class(W(label), "dim-label")
            gtk_box_append(cast(box), W(label))
        }
        let (row, buttons) = buildAskButtonRow(ask, terminalStyle: false)
        gtk_box_append(cast(box), W(row))
        askWidgets.guiButtons = buttons
        gtk_window_set_child(WIN(win), W(box))

        let keys = gtk_event_controller_key_new()
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        connect(keys, "key-pressed", unsafeBitCast(
            onAskKey as @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean,
            to: GCallback.self))
        gtk_widget_add_controller(W(win), keys)

        refreshAskButtonStyles(ask, buttons: buttons)
        gtk_window_present(WIN(win))
        if let index = askWidgets.navigations[ask.id]?.highlighted, buttons.indices.contains(index) {
            _ = gtk_widget_grab_focus(W(buttons[index]))
        }
    }

    func cancelGuiAsk() {
        guard pickController.pendingAsk != nil else { return }
        pickController.cancelAsk()
        dismissGuiAsk()
    }

    func escapeGuiAsk() {
        guard pickController.pendingAsk != nil else { return }
        pickController.escapeAsk()
        dismissGuiAsk()
    }

    func guiAskWasDestroyed() {
        guard askWidgets.guiWindow != nil else { return }
        askWidgets.guiWindow = nil
        askWidgets.guiButtons = []
        if let pending = pickController.pendingAsk {
            askWidgets.navigations[pending.id] = nil
            pickController.cancelAsk()
        }
        MainTimer.schedule(after: 0) { [weak self] in self?.focusedSurface()?.grabFocus() }
    }

    private func dismissGuiAsk() {
        if let pending = pickController.pendingAsk { askWidgets.navigations[pending.id] = nil }
        guard let win = askWidgets.guiWindow else { return }
        askWidgets.guiWindow = nil
        askWidgets.guiButtons = []
        gtk_window_destroy(WIN(win))
    }

    // MARK: - Shared presentation and input

    /// One button row, or a column when the labels do not fit side by side. Every button shares the widest
    /// one's width, as upstream's do, so a dialog never reads as a ragged stack.
    private func buildAskButtonRow(_ ask: PendingAsk, terminalStyle: Bool) -> (OpaquePointer, [OpaquePointer]) {
        let row = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)) ?? op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8))!
        gtk_widget_set_halign(W(row), askAlignment(ask.align))
        gtk_box_set_homogeneous(cast(row), 1)
        var buttons: [OpaquePointer] = []
        for button in ask.buttons {
            guard let widget = op(gtk_button_new_with_label(button.label)) else { continue }
            if terminalStyle { gtk_widget_add_css_class(W(widget), "agterm-ask-button") }
            connect(widget, "clicked", unsafeBitCast(
                onAskButton as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
            gtk_box_append(cast(row), W(widget))
            buttons.append(widget)
        }
        return (row, buttons)
    }

    private func askAlignment(_ align: ControlAskAlignment) -> GtkAlign {
        switch align {
        case .left: return GTK_ALIGN_START
        case .center: return GTK_ALIGN_CENTER
        case .right: return GTK_ALIGN_END
        }
    }

    /// The highlighted button carries the suggested tint and the destructive one the destructive tint, so
    /// the same navigation state reads the same in both styles.
    private func refreshAskButtonStyles(_ ask: PendingAsk, buttons: [OpaquePointer]) {
        let highlighted = askWidgets.navigations[ask.id]?.highlighted
        for (index, widget) in buttons.enumerated() {
            gtk_widget_remove_css_class(W(widget), "suggested-action")
            gtk_widget_remove_css_class(W(widget), "destructive-action")
            if ask.buttons.indices.contains(index), ask.buttons[index].id == ask.destructiveID {
                gtk_widget_add_css_class(W(widget), "destructive-action")
            } else if index == highlighted {
                gtk_widget_add_css_class(W(widget), "suggested-action")
            }
        }
    }

    /// The pending ask this window's keyboard belongs to, with its owner, so one key handler drives both
    /// styles. The GUI slot wins: it is window-modal, so no session dialog can be taking keys behind it.
    private func focusedAsk() -> (ask: PendingAsk, session: UUID?)? {
        if let pending = pickController.pendingAsk, askWidgets.guiWindow != nil { return (pending, nil) }
        guard let id = store.selectedSessionID, sessionAskVisible(id),
              let pending = store.session(withID: id)?.askPending else { return nil }
        return (pending, id)
    }

    func askButtonActivated(_ widget: OpaquePointer?) {
        guard let widget, let focused = focusedAsk() else { return }
        let buttons = focused.session.flatMap { askWidgets.sessionButtons[$0] } ?? askWidgets.guiButtons
        guard let index = buttons.firstIndex(of: widget) else { return }
        answerAsk(focused, index: index)
    }

    /// Maps an unmodified key onto `AskNavigation`. Returns true when the dialog consumed it, which is what
    /// keeps a hotkey letter out of the terminal underneath.
    func askKeyPressed(keyval: UInt32) -> Bool {
        guard let focused = focusedAsk() else { return false }
        switch keyval {
        case 0xFF1B, 0xFF57:   // Escape
            resolveAsk(focused, ControlAskResult(result: .escaped))
            return true
        case 0xFF0D, 0xFF8D:   // Return, KP_Enter
            if let index = askWidgets.navigations[focused.ask.id]?.activate() { answerAsk(focused, index: index) }
            return true
        case 0xFF09, 0xFF53, 0xFF54:   // Tab, Right, Down
            askWidgets.navigations[focused.ask.id]?.moveForward()
        case 0xFE20, 0xFF51, 0xFF52:   // ISO_Left_Tab, Left, Up
            askWidgets.navigations[focused.ask.id]?.moveBackward()
        default:
            guard let scalar = Unicode.Scalar(keyval), scalar.isASCII,
                  CharacterSet.letters.contains(scalar) else { return false }
            guard let index = askWidgets.navigations[focused.ask.id]?.hotkey(String(scalar)) else { return false }
            answerAsk(focused, index: index)
            return true
        }
        refreshFocusedAskButtons(focused)
        return true
    }

    private func refreshFocusedAskButtons(_ focused: (ask: PendingAsk, session: UUID?)) {
        let buttons = focused.session.flatMap { askWidgets.sessionButtons[$0] } ?? askWidgets.guiButtons
        refreshAskButtonStyles(focused.ask, buttons: buttons)
        if let index = askWidgets.navigations[focused.ask.id]?.highlighted, buttons.indices.contains(index),
           focused.session == nil {
            _ = gtk_widget_grab_focus(W(buttons[index]))
        }
    }

    private func answerAsk(_ focused: (ask: PendingAsk, session: UUID?), index: Int) {
        guard focused.ask.buttons.indices.contains(index) else { return }
        let button = focused.ask.buttons[index]
        resolveAsk(focused, ControlAskResult(result: .answered, id: button.id, label: button.label, index: index))
    }

    private func resolveAsk(_ focused: (ask: PendingAsk, session: UUID?), _ result: ControlAskResult) {
        if let session = focused.session {
            resolveSessionAsk(session, id: focused.ask.id, result)
        } else {
            pickController.resolveAsk(result)
            askWidgets.navigations[focused.ask.id] = nil
            dismissGuiAskAfterResolve()
        }
    }

    private func dismissGuiAskAfterResolve() {
        guard let win = askWidgets.guiWindow else { return }
        askWidgets.guiWindow = nil
        askWidgets.guiButtons = []
        gtk_window_destroy(WIN(win))
        MainTimer.schedule(after: 0) { [weak self] in self?.focusedSurface()?.grabFocus() }
    }

    /// The terminal panel takes the theme's own background and foreground, so a dialog over a terminal reads
    /// as part of it rather than as desktop chrome. Re-applied on every build, which is also every theme
    /// change, since a change tears the panels down and rebuilds them.
    private func applyTerminalAskStyle() {
        guard let display = gdk_display_get_default() else { return }
        let settings = linuxSettingsStore().load()
        let colors = Self.themeColors(for: settings.theme)
        let background = colors.background ?? "#1e1e1e"
        let foreground = colors.foreground ?? "#e6e6e6"
        let family = settings.fontFamily ?? "monospace"
        let css = """
        .agterm-ask {
          background-color: \(background);
          color: \(foreground);
          border: 1px solid alpha(\(foreground), 0.35);
          border-radius: 8px;
          padding: 14px;
          font-family: "\(family)", monospace;
        }
        .agterm-ask-title { font-weight: bold; }
        .agterm-ask-message { opacity: 0.75; }
        .agterm-ask-button {
          background-image: none;
          background-color: alpha(\(foreground), 0.12);
          color: \(foreground);
          border: none;
        }
        """
        if let previous = LinuxAskWidgets.styleProvider {
            gtk_style_context_remove_provider_for_display(display, previous)
        }
        guard let provider = gtk_css_provider_new() else { return }
        css.withCString { gtk_css_provider_load_from_string(provider, $0) }
        gtk_style_context_add_provider_for_display(display, OpaquePointer(provider),
                                                   guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION) + 1)
        LinuxAskWidgets.styleProvider = OpaquePointer(provider)
    }
}

private let onAskKey: @MainActor @convention(c)
    (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { keys, keyval, _, _, _ in
        MainActor.assumeIsolated {
            controllerForEventController(keys)?.askKeyPressed(keyval: keyval) == true ? 1 : 0
        }
    }

private let onAskButton: @MainActor @convention(c)
    (OpaquePointer?, gpointer?) -> Void = { button, _ in
        MainActor.assumeIsolated { controllerForWidget(button)?.askButtonActivated(button) }
    }

private let onGuiAskCloseRequest: @MainActor @convention(c)
    (OpaquePointer?, gpointer?) -> gboolean = { window, _ in
        MainActor.assumeIsolated { controllerForWidget(window)?.escapeGuiAsk() }
        return 1
    }

private let onGuiAskDestroyed: @MainActor @convention(c)
    (OpaquePointer?, gpointer?) -> Void = { _, data in
        guard let data else { return }
        MainActor.assumeIsolated {
            Unmanaged<AppController>.fromOpaque(data).takeRetainedValue().guiAskWasDestroyed()
        }
    }
