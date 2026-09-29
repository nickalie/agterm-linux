import CGtk
import Foundation
import agtermCore

/// LinuxHtmlBrowser opens a hand-off in the default web browser, never the file type's app, which could run it.
@MainActor
struct LinuxHtmlBrowser {
    var open: (URL) -> Bool = { url in
        guard let app = "https".withCString({ g_app_info_get_default_for_uri_scheme($0) }) else { return false }
        defer { g_object_unref(UnsafeMutableRawPointer(app)) }
        let uris = url.absoluteString.withCString { g_list_append(nil, UnsafeMutableRawPointer(mutating: $0)) }
        defer { g_list_free(uris) }
        return g_app_info_launch_uris(app, uris, nil, nil) != 0
    }
}

/// LinuxHtmlSharing is Show in Files and Copy Link, apart so tests can observe them.
@MainActor
struct LinuxHtmlSharing {
    var reveal: (URL) -> Void = { url in
        let file = url.path.withCString { g_file_new_for_path($0) }
        let launcher = gtk_file_launcher_new(file)
        gtk_file_launcher_open_containing_folder(launcher, nil, nil, nil, nil)
        g_object_unref(UnsafeMutableRawPointer(launcher))
        g_object_unref(UnsafeMutableRawPointer(file))
    }
    var copy: (String) -> Void = { text in
        guard let display = gdk_display_get_default(), let clipboard = gdk_display_get_clipboard(display) else { return }
        text.withCString { gdk_clipboard_set_text(clipboard, $0) }
    }
}

/// LinuxHtmlOverlays owns every open page, keyed by the page's id rather than a host widget or a pane, so a
/// page survives session switches, pane swaps and the soft-close window, and goes only when the model
/// releases it through `HtmlOverlayReleases`.
@MainActor
final class LinuxHtmlOverlays {
    static let shared = LinuxHtmlOverlays()
    var browser = LinuxHtmlBrowser()
    var sharing = LinuxHtmlSharing()
    private var pages: [UUID: LinuxHtmlOverlayPage] = [:]
    private(set) var terminal = HtmlOverlayTheme(background: "", foreground: "", dark: true)
    private static var backingColors: Set<String> = []
    private static var backingProvider: OpaquePointer?

    func install() {
        HtmlOverlayReleases.shared.onRelease = { [weak self] in self?.release($0) }
    }

    /// unavailable is why this process cannot show a page, nil when it can.
    var unavailable: String? {
        switch LinuxWebKit.api() {
        case .success: return nil
        case .failure(let failure): return failure.message
        }
    }

    /// page returns the live page for `overlay`, creating and loading it on first use; nil without WebKitGTK.
    func page(for overlay: HtmlOverlay, store: AppStore, backgroundColor: String?) -> LinuxHtmlOverlayPage? {
        if let page = pages[overlay.id] { return page }
        guard case .success(let api) = LinuxWebKit.api() else { return nil }
        let page = LinuxHtmlOverlayPage(overlay: overlay, store: store, backgroundColor: backgroundColor,
                                        theme: theme(backgroundColor: backgroundColor), api: api)
        pages[overlay.id] = page
        return page
    }

    func existing(_ id: UUID) -> LinuxHtmlOverlayPage? { pages[id] }

    func release(_ id: UUID) {
        pages.removeValue(forKey: id)?.close()
    }

    /// show mounts `overlay`'s page at `target`, moving it off any other mount and taking the place of any
    /// other page there.
    func show(_ overlay: HtmlOverlay, store: AppStore, backgroundColor: String?, at target: LinuxHtmlMount) -> LinuxHtmlOverlayPage? {
        for other in pages.values where other.mount == target && other.id != overlay.id { other.unmount() }
        guard let page = page(for: overlay, store: store, backgroundColor: backgroundColor) else { return nil }
        page.mount(in: target)
        page.apply(overlay)
        return page
    }

    /// clear takes any page off `target`, which its slot no longer holds.
    func clear(_ target: LinuxHtmlMount) {
        for page in pages.values where page.mount == target { page.unmount() }
    }

    func isMounted(at target: LinuxHtmlMount) -> Bool {
        pages.values.contains { $0.mount == target }
    }

    /// focusCover gives the keyboard to the page covering `session` and is true when one covers it, shown or
    /// not: the caller must then leave the hidden terminal beneath alone.
    @discardableResult func focusCover(of session: Session) -> Bool {
        guard let overlay = session.topmostHtmlOverlay else { return false }
        pages[overlay.id]?.focus()
        return true
    }

    // MARK: - Theme

    /// updateTerminal takes the resolved terminal colors; each page's default look follows them.
    func updateTerminal(background: String?, foreground: String?, palette: [String]) {
        let background = background ?? "#1e1e1e"
        let next = HtmlOverlayTheme(background: background, foreground: foreground ?? "#d4d4d4",
                                    dark: Self.isDark(background), palette: palette)
        guard next != terminal else { return }
        terminal = next
        for page in pages.values { page.applyTheme(theme(backgroundColor: page.backgroundColor)) }
    }

    /// theme is the terminal theme a page wears, the overlay's own background first.
    func theme(backgroundColor: String?) -> HtmlOverlayTheme {
        guard let backgroundColor else { return terminal }
        return HtmlOverlayTheme(background: backgroundColor, foreground: terminal.foreground,
                                dark: Self.isDark(backgroundColor), palette: terminal.palette)
    }

    static func isDark(_ hex: String) -> Bool {
        guard WatermarkConfig.isValidColorHex(hex), let value = UInt32(hex.dropFirst(), radix: 16) else { return true }
        return ThemeBrightness.isDark(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                                      blue: Double(value & 0xFF) / 255)
    }

    /// backingClass is the CSS class that paints `hex` behind a page, whose file canvas is transparent.
    static func backingClass(for hex: String) -> String {
        let color = WatermarkConfig.isValidColorHex(hex) ? hex.dropFirst().lowercased() : "1e1e1e"
        if !backingColors.contains(color) {
            backingColors.insert(color)
            let css = backingColors.sorted().map { ".agterm-html-backing-\($0) { background-color: #\($0); }" }.joined(separator: "\n")
            if backingProvider == nil, let display = gdk_display_get_default() {
                backingProvider = OpaquePointer(gtk_css_provider_new())
                gtk_style_context_add_provider_for_display(display, backingProvider, 700)
            }
            css.withCString { gtk_css_provider_load_from_string(cast(backingProvider), $0) }
        }
        return "agterm-html-backing-\(color)"
    }

    // MARK: - Shared actions

    func perform(_ kind: LinuxHtmlStripAction.Kind, page id: UUID) {
        guard let owner = owner(of: id) else { return }
        switch kind {
        case .back: _ = navigate(id, .back)
        case .forward: _ = navigate(id, .forward)
        case .browser: _ = navigate(id, .browser)
        case .finder: _ = navigate(id, .finder)
        case .copyLink: copyLink(id)
        case .reload: reload(id, target: .current, store: owner.store)
        case .close:
            owner.store.closeHtmlOverlay(id)
            owner.reconcile()
        }
    }

    /// navigate shares the strip's history and hand-off actions with `session.overlay.navigate`.
    func navigate(_ id: UUID, _ navigation: HtmlNavigation) -> String? {
        guard let page = pages[id] else { return OverlayHtmlError.notRealized }
        switch navigation {
        case .back: return page.navigate(back: true)
        case .forward: return page.navigate(back: false)
        case .browser: return browser.open(page.browserURL) ? nil : OverlayHtmlError.noBrowser
        case .finder:
            guard page.isFilePage else { return OverlayHtmlError.finderRequiresFile }
            sharing.reveal(page.pageURL)
            return nil
        }
    }

    func copyLink(_ id: UUID) {
        guard let page = pages[id] else { return }
        sharing.copy(page.browserURL.absoluteString)
    }

    /// reload is the other shared path: the strip reloads the current page, `session.overlay.reload` either.
    @discardableResult func reload(sessionID: UUID, pane: OverlayPane?, target: HtmlReloadTarget,
                                   store: AppStore) -> HtmlOverlayCommandFailure? {
        if let failure = store.reloadHtmlOverlay(sessionID, pane: pane, target: target) { return failure }
        let session = store.session(withID: sessionID)
        if let overlay = pane.map({ session?.paneOverlay($0)?.html }) ?? session?.htmlOverlay {
            pages[overlay.id]?.apply(overlay)
        }
        return nil
    }

    @discardableResult func reload(_ id: UUID, target: HtmlReloadTarget, store: AppStore) -> HtmlOverlayCommandFailure? {
        guard let slot = store.htmlOverlaySlot(id) else { return .noOverlay }
        return reload(sessionID: slot.session.id, pane: slot.pane, target: target, store: store)
    }

    // MARK: - Page events

    func noteActivity(store: AppStore?) {
        gWindows.values.first { $0.store === store }?.noteUserActivity()
    }

    /// pageFocused makes a pane page's pane the session's focused one, as a click on its terminal would.
    func pageFocused(_ id: UUID, store: AppStore?) {
        guard let store, let slot = store.htmlOverlaySlot(id), let pane = slot.pane,
              let owner = gWindows.values.first(where: { $0.store === store }) else { return }
        owner.surfaceDidFocus(slot.session.id, isSplit: pane == .right)
    }

    /// handleKey offers a key pressed on page `id` to the app's keymap first; false leaves it to the page.
    func handleKey(_ id: UUID, store: AppStore?, key: (keyval: UInt32, keycode: UInt32, state: UInt32),
                   event: OpaquePointer?) -> Bool {
        let (keyval, keycode, state) = key
        guard let store, let slot = store.htmlOverlaySlot(id),
              let owner = gWindows.values.first(where: { $0.store === store }) else { return false }
        owner.noteUserActivity()
        return owner.handleKey(keyval: keyval, keycode: keycode, state: state, sessionID: slot.session.id,
                               context: shortcutKeyContext(event: event, keycode: keycode))
    }

    func endSessionSwitch(_ page: LinuxHtmlOverlayPage?) {
        guard let page, let owner = owner(of: page.id) else { return }
        owner.endSessionSwitch()
    }

    private func owner(of id: UUID) -> AppController? {
        gWindows.values.first { $0.store.htmlOverlaySlot(id) != nil }
    }
}
