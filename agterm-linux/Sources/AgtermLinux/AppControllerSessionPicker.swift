import CGtk
import Foundation
import agtermCore

@MainActor
final class SessionPickerRowContext {
    unowned let controller: AppController
    let sessionID: UUID
    /// The window owning an attention row, which may not be this popover's; nil for a recent-session row.
    let attentionWindowID: UUID?

    init(controller: AppController, sessionID: UUID, attentionWindowID: UUID?) {
        self.controller = controller
        self.sessionID = sessionID
        self.attentionWindowID = attentionWindowID
    }
}

/// One popover row: the session and, for an attention row, its window and whether it can be picked now.
struct SessionPickerRow {
    let session: Session
    let subtitle: String
    let windowID: UUID?
    let enabled: Bool
}

@MainActor
extension AppController {
    /// Open the mouse-accessible twin of the Ctrl-Tab MRU switcher or attention palette.
    /// These are interactive-only popovers, so no control-socket command is meaningful.
    func showSessionPicker(attention: Bool, anchor: OpaquePointer?) {
        guard let anchor else { return }
        let sessions = attention ? attentionPickerRows() : recentPickerRows()
        guard !sessions.isEmpty else { return }

        dismissSessionPicker()
        guard let popover = op(gtk_popover_new()), let rows = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)) else {
            return
        }
        sessionPickerPopover = popover
        sessionPickerShowsAttention = attention
        sessionPickerSuppressesAutoFollow = true
        suppressAutoFollow()
        gtk_widget_set_parent(W(popover), W(anchor))
        gtk_popover_set_position(POPOVER(popover), GTK_POS_BOTTOM)
        gtk_widget_add_css_class(W(rows), "agterm-session-picker")
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(W(rows), 6)
        }
        gtk_widget_set_size_request(W(rows), 320, -1)

        for entry in sessions {
            let session = entry.session
            guard let button = op(gtk_button_new()), let row = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)),
                  let labels = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 1)) else { continue }
            gtk_button_set_has_frame(BUTTON(button), 0)
            gtk_widget_set_halign(W(button), GTK_ALIGN_FILL)
            gtk_widget_set_hexpand(W(button), 1)
            (attention ? "attention-session-row" : "recent-session-row").withCString {
                gtk_widget_set_name(W(button), $0)
            }

            if attention, let icon = Self.makeStatusGlyph(
                session.agentIndicator, settings: linuxSettingsStore().load()
            ) {
                gtk_box_append(cast(row), W(icon))
            }

            let title = op(gtk_label_new(session.displayName))
            gtk_label_set_xalign(title, 0)
            gtk_widget_add_css_class(W(title), "heading")
            gtk_box_append(cast(labels), W(title))
            let subtitle = op(gtk_label_new(entry.subtitle))
            gtk_label_set_xalign(subtitle, 0)
            gtk_widget_add_css_class(W(subtitle), "dim-label")
            gtk_box_append(cast(labels), W(subtitle))
            gtk_widget_set_hexpand(W(labels), 1)
            gtk_box_append(cast(row), W(labels))
            gtk_button_set_child(BUTTON(button), W(row))

            // a row whose window sits under a cover renders inert, as the palette's does
            gtk_widget_set_sensitive(W(button), entry.enabled ? 1 : 0)
            let context = SessionPickerRowContext(controller: self, sessionID: session.id,
                                                  attentionWindowID: entry.windowID)
            sessionPickerContexts.append(context)
            connect(button, "clicked", unsafeBitCast(onSessionPickerRow as @convention(c)
                (OpaquePointer?, gpointer?) -> Void, to: GCallback.self),
                Unmanaged.passUnretained(context).toOpaque())
            gtk_box_append(cast(rows), W(button))
        }

        connect(popover, "closed", unsafeBitCast(onSessionPickerClosed as @convention(c)
            (OpaquePointer?, gpointer?) -> Void, to: GCallback.self),
            Unmanaged.passUnretained(self).toOpaque())
        // a long cross-window list scrolls at about ten rows instead of running off the screen
        let scroller = op(gtk_scrolled_window_new())
        gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(scroller, 1)
        let metrics = InterfaceMetrics(fontSize: linuxSettingsStore().load().interfaceFontSize
            ?? AppSettings.defaultInterfaceFontSize)
        gtk_scrolled_window_set_max_content_height(scroller, Int32(metrics.scaled(Self.attentionRowsCap)))
        gtk_scrolled_window_set_child(scroller, W(rows))
        gtk_popover_set_child(POPOVER(popover), W(scroller))
        gtk_popover_popup(POPOVER(popover))
    }

    /// The popover's row-stack cap at the default interface size, about ten rows.
    static let attentionRowsCap: Double = 440

    private func recentPickerRows() -> [SessionPickerRow] {
        store.recentSessions(limit: 11)
            .filter { $0 != store.selectedSessionID }
            .prefix(10)
            .compactMap { store.session(withID: $0) }
            .map { session in
                let workspace = store.workspace(forSession: session.id)?.name ?? ""
                let detail = workspace.isEmpty ? session.subtitleDetail : "\(workspace) · \(session.subtitleDetail)"
                return SessionPickerRow(session: session, subtitle: detail, windowID: nil, enabled: true)
            }
    }

    private func attentionPickerRows() -> [SessionPickerRow] {
        library.attentionAcrossWindows.map { entry in
            SessionPickerRow(session: entry.session, subtitle: library.attentionSubtitle(entry),
                             windowID: entry.window.id,
                             enabled: canSelectAttention(windowID: entry.window.id, sessionID: entry.session.id))
        }
    }

    func updateRecentSessionsButton() {
        guard let button = recentSessionsButton else { return }
        let hasOther = store.recentSessions(limit: 2).contains { $0 != store.selectedSessionID }
        gtk_widget_set_sensitive(W(button), hasOther ? 1 : 0)
        gtk_widget_set_opacity(W(button), hasOther ? 1 : 0.35)
        if !hasOther, sessionPickerPopover != nil, !sessionPickerShowsAttention { dismissSessionPicker() }
    }

    func activateSessionPickerRow(_ context: SessionPickerRowContext) {
        let id = context.sessionID
        dismissSessionPicker()
        if let windowID = context.attentionWindowID {
            guard canSelectAttention(windowID: windowID, sessionID: id) else { return }
            // on the next turn, so a raise of another window never competes with this popover's dismissal
            MainTimer.schedule(after: 0) { selectAttention(windowID: windowID, sessionID: id) }
            return
        }
        selectSession(id)
        focusedSurface(for: id)?.grabFocus()
    }

    func dismissSessionPicker() {
        guard let popover = sessionPickerPopover else { return }
        sessionPickerPopover = nil
        sessionPickerShowsAttention = false
        sessionPickerContexts.removeAll()
        if sessionPickerSuppressesAutoFollow {
            sessionPickerSuppressesAutoFollow = false
            resumeAutoFollow()
        }
        gtk_popover_popdown(POPOVER(popover))
        gtk_widget_unparent(W(popover))
    }

    func sessionPickerDidClose(_ popover: OpaquePointer?) {
        guard popover == sessionPickerPopover else { return }
        sessionPickerPopover = nil
        sessionPickerShowsAttention = false
        sessionPickerContexts.removeAll()
        if sessionPickerSuppressesAutoFollow {
            sessionPickerSuppressesAutoFollow = false
            resumeAutoFollow()
        }
        gtk_widget_unparent(W(popover))
    }
}

private let onSessionPickerRow: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let context = Unmanaged<SessionPickerRowContext>.fromOpaque(data).takeUnretainedValue()
        context.controller.activateSessionPickerRow(context)
    }
}

private let onSessionPickerClosed: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { popover, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue().sessionPickerDidClose(popover)
    }
}
