import CGtk
import Foundation
import agtermCore

@MainActor
final class CustomCommandRowContext {
    unowned let controller: AppController
    let command: CustomCommand

    init(controller: AppController, command: CustomCommand) {
        self.controller = controller
        self.command = command
    }
}

@MainActor
extension AppController {
    /// How many most-run commands lead the popover, and the command count above which that section appears.
    static let mostUsedCommandLimit = 5

    /// Run counts behind the most-used section. Per state directory, so every window counts into one file.
    static var customCommandUsage: CustomCommandUsageStore {
        CustomCommandUsageStore(directory: linuxStateDirectory())
    }

    /// The title-bar popover listing every `keymap.conf` command with its chord, the mouse form of the
    /// custom-command palette. Counts are read on every open, so a run from a chord or the palette counts
    /// too; they decide only WHICH commands lead, never the order inside either group.
    func showCustomCommands(anchor: OpaquePointer?) {
        guard let anchor else { return }
        let commands = keymap.commands
        guard !commands.isEmpty, store.activeSession != nil else { return }

        dismissCustomCommands()
        guard let popover = op(gtk_popover_new()), let rows = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)),
              let scroller = op(gtk_scrolled_window_new()) else { return }
        customCommandsPopover = popover
        gtk_widget_set_parent(W(popover), W(anchor))
        gtk_popover_set_position(POPOVER(popover), GTK_POS_BOTTOM)
        gtk_widget_add_css_class(W(rows), "agterm-interface")
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(W(rows), 6)
        }
        gtk_widget_set_size_request(W(rows), 320, -1)

        let mostUsed = commands.count > Self.mostUsedCommandLimit
            ? Self.customCommandUsage.load().mostUsed(of: commands, limit: Self.mostUsedCommandLimit)
            : []
        let leadingIDs = Set(mostUsed.map(\.id))
        let leading = commands.filter { leadingIDs.contains($0.id) }
        let rest = commands.filter { !leadingIDs.contains($0.id) }
        for command in leading { appendCustomCommandRow(command, to: rows) }
        if !leading.isEmpty, !rest.isEmpty {
            let separator = op(gtk_separator_new(GTK_ORIENTATION_HORIZONTAL))
            gtk_widget_set_margin_top(W(separator), 4)
            gtk_widget_set_margin_bottom(W(separator), 4)
            gtk_box_append(cast(rows), W(separator))
        }
        for command in rest { appendCustomCommandRow(command, to: rows) }

        // the keymap has no cap, so the list scrolls rather than growing the popover past the screen
        gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(scroller, 1)
        gtk_scrolled_window_set_max_content_height(scroller, 420)
        gtk_scrolled_window_set_child(scroller, W(rows))
        connect(popover, "closed", unsafeBitCast(onCustomCommandsClosed as @convention(c)
            (OpaquePointer?, gpointer?) -> Void, to: GCallback.self),
            Unmanaged.passUnretained(self).toOpaque())
        gtk_popover_set_child(POPOVER(popover), W(scroller))
        gtk_popover_popup(POPOVER(popover))
    }

    private func appendCustomCommandRow(_ command: CustomCommand, to rows: OpaquePointer) {
        guard let button = op(gtk_button_new()), let row = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)) else {
            return
        }
        gtk_button_set_has_frame(BUTTON(button), 0)
        gtk_widget_set_halign(W(button), GTK_ALIGN_FILL)
        "custom-command-row".withCString { gtk_widget_set_name(W(button), $0) }
        let title = op(gtk_label_new(command.name))
        gtk_label_set_xalign(title, 0)
        gtk_widget_set_hexpand(W(title), 1)
        gtk_box_append(cast(row), W(title))
        if let chord = command.shortcut.linuxTrimmedOrNil {
            let shortcut = op(gtk_label_new(chord))
            gtk_widget_add_css_class(W(shortcut), "dim-label")
            gtk_box_append(cast(row), W(shortcut))
        }
        gtk_button_set_child(BUTTON(button), W(row))
        let context = CustomCommandRowContext(controller: self, command: command)
        customCommandContexts.append(context)
        connect(button, "clicked", unsafeBitCast(onCustomCommandRow as @convention(c)
            (OpaquePointer?, gpointer?) -> Void, to: GCallback.self),
            Unmanaged.passUnretained(context).toOpaque())
        gtk_box_append(cast(rows), W(button))
    }

    func activateCustomCommandRow(_ context: CustomCommandRowContext) {
        let command = context.command
        dismissCustomCommands()
        runCustomCommand(command)
        // the row ran like a chord would, so the keyboard goes back to the terminal
        if let id = store.selectedSessionID { focusedSurface(for: id)?.grabFocus() }
    }

    /// Enabled only with a parsed command and an active session: the runner ignores a command fired
    /// without one, so every row would silently no-op.
    func updateCustomCommandsButton() {
        guard let button = customCommandsButton else { return }
        let enabled = !keymap.commands.isEmpty && store.activeSession != nil
        gtk_widget_set_sensitive(W(button), enabled ? 1 : 0)
        gtk_widget_set_opacity(W(button), enabled ? 1 : 0.35)
        if !enabled { dismissCustomCommands() }
    }

    func dismissCustomCommands() {
        guard let popover = customCommandsPopover else { return }
        customCommandsPopover = nil
        customCommandContexts.removeAll()
        gtk_popover_popdown(POPOVER(popover))
        gtk_widget_unparent(W(popover))
    }

    func customCommandsDidClose(_ popover: OpaquePointer?) {
        guard popover == customCommandsPopover else { return }
        customCommandsPopover = nil
        customCommandContexts.removeAll()
        gtk_widget_unparent(W(popover))
    }
}

private let onCustomCommandRow: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let context = Unmanaged<CustomCommandRowContext>.fromOpaque(data).takeUnretainedValue()
        context.controller.activateCustomCommandRow(context)
    }
}

private let onCustomCommandsClosed: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { popover, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue().customCommandsDidClose(popover)
    }
}
