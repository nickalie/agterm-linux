import CGtk
import agtermCore

@MainActor
extension AppController {
    /// The card's size, re-read on every summon so a Settings change lands on the next ⌃`.
    ///
    /// Upstream's panel is detached and sizes itself against the SCREEN; the Linux panel belongs to its
    /// window, so a percentage here is of the window content — the same measure the floating session
    /// overlay uses. Unset keeps the fixed insets the card shipped with, which is the Default row.
    func applyQuickCardGeometry(_ frame: OpaquePointer) {
        guard let overlay = deckOverlay else { return }
        guard let percent = linuxSettingsStore().load().quickTerminalSizePercent else {
            gtk_widget_set_halign(W(frame), GTK_ALIGN_FILL)
            gtk_widget_set_valign(W(frame), GTK_ALIGN_FILL)
            gtk_widget_set_size_request(W(frame), -1, -1)
            gtk_widget_set_margin_top(W(frame), 56)
            for margin in [gtk_widget_set_margin_start, gtk_widget_set_margin_end, gtk_widget_set_margin_bottom] {
                margin(W(frame), 44)
            }
            return
        }
        let share = Int32(QuickTerminalMetrics.clampSizePercent(percent))
        gtk_widget_set_halign(W(frame), GTK_ALIGN_CENTER)
        gtk_widget_set_valign(W(frame), GTK_ALIGN_CENTER)
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_start,
                       gtk_widget_set_margin_end, gtk_widget_set_margin_bottom] {
            margin(W(frame), 0)
        }
        gtk_widget_set_size_request(W(frame),
                                    max(Int32(240), gtk_widget_get_width(W(overlay)) * share / 100),
                                    max(Int32(160), gtk_widget_get_height(W(overlay)) * share / 100))
    }
}
