import CGtk
import Foundation
import agtermCore

/// LinuxHtmlMount is the widget a page's panel currently sits in: the session stack's `overlay` page, a
/// floating frame, or a pane host's overlay layer.
enum LinuxHtmlMount: Equatable {
    case stack(OpaquePointer), frame(OpaquePointer), paneHost(OpaquePointer)
}

/// LinuxHtmlOverlayPage is one page's panel: the app-drawn strip, the web view the plugin made, and the
/// failure panel over it. It keeps the store in step with the view, as `HtmlOverlayPage` does on macOS.
@MainActor
final class LinuxHtmlOverlayPage {
    let id: UUID
    let backgroundColor: String?
    /// panel is owned here, so it survives moving between mounts
    let panel: OpaquePointer
    private(set) var mount: LinuxHtmlMount?
    private let view: OpaquePointer
    private let api: UnsafePointer<agterm_webkit_api>
    // the plugin's callback context; the plugin stops calling at `close`, before the page can go
    private let handle: LinuxHtmlPageHandle
    private var overlay: HtmlOverlay
    private weak var store: AppStore?
    private var appliedRevision: Int
    private var theme: HtmlOverlayTheme
    private var load = LinuxHtmlLoad()
    private let body: OpaquePointer
    private let identity: OpaquePointer
    private let titleSeparator: OpaquePointer
    private let titleLabel: OpaquePointer
    private let failure: OpaquePointer
    private let failureMessage: OpaquePointer
    private var historyButtons: (back: OpaquePointer, forward: OpaquePointer)?
    private var actions: [LinuxHtmlStripAction] = []
    private var backingClass: String?
    private var prompt: (token: UUID, dialog: OpaquePointer)?
    // a declined prompt silences the page until a native key or press reaches it: script can click links
    // in a loop, but it cannot make those events
    private var promptsSilenced = false

    init(overlay: HtmlOverlay, store: AppStore, backgroundColor: String?, theme: HtmlOverlayTheme, zoom: Double,
         api: UnsafePointer<agterm_webkit_api>) {
        id = overlay.id
        self.overlay = overlay
        self.store = store
        self.backgroundColor = backgroundColor
        self.theme = theme
        self.api = api
        appliedRevision = overlay.reloadRevision
        panel = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))!
        _ = g_object_ref_sink(GOBJ(panel))
        body = OpaquePointer(gtk_overlay_new())
        identity = op(gtk_label_new(nil))!
        titleSeparator = op("·".withCString { gtk_label_new($0) })!
        titleLabel = op(gtk_label_new(nil))!
        // owned outright: a chromeless page never parents its strip's labels
        for label in [identity, titleSeparator, titleLabel] { _ = g_object_ref_sink(GOBJ(label)) }
        failure = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8))!
        failureMessage = op(gtk_label_new(nil))!
        let handle = LinuxHtmlPageHandle()
        self.handle = handle
        var callbacks = agterm_web_callbacks(context: Unmanaged.passUnretained(handle).toOpaque(), decide: onDecide,
                                             load: onLoad, changed: onChanged, input: onInput, focus: onFocus,
                                             request: onRequest)
        guard let created = Self.withBridge(overlay, { bridge in
            theme.script(themed: Self.themed(overlay)).withCString {
                api.pointee.create(&callbacks, overlay.javascript, Self.themed(overlay), $0, bridge)
            }
        }) else { preconditionFailure("WebKitGTK returned no web view") }
        view = OpaquePointer(created)
        _ = g_object_ref_sink(GOBJ(view))
        api.pointee.set_zoom(W(view), zoom)
        handle.page = self
        build()
        loadOriginal()
    }

    private static func themed(_ overlay: HtmlOverlay) -> Bool {
        if case .file = overlay.source { return true }
        return false
    }

    // a file page gets the bridge; a `--js` one also gets `agterm.request` and its relay. A URL page gets none.
    private static func withBridge<R>(_ overlay: HtmlOverlay, _ body: (UnsafePointer<agterm_web_bridge>?) -> R) -> R {
        guard themed(overlay) else { return body(nil) }
        return LinuxHtmlBridge.adapterScript.withCString { adapter in
            let scripts = overlay.javascript ? (LinuxHtmlBridge.relayScript, LinuxHtmlBridge.helperScript) : ("", "")
            return scripts.0.withCString { relay in
                scripts.1.withCString { helper in
                    var bridge = agterm_web_bridge(adapter: adapter, relay: overlay.javascript ? relay : nil,
                                                   helper: overlay.javascript ? helper : nil)
                    return body(&bridge)
                }
            }
        }
    }

    private func build() {
        gtk_widget_add_css_class(W(panel), "agterm-html-panel")
        gtk_widget_set_hexpand(W(panel), 1)
        gtk_widget_set_vexpand(W(panel), 1)
        if !overlay.chromeless { gtk_box_append(cast(panel), W(buildStrip())) }
        gtk_widget_set_hexpand(W(view), 1)
        gtk_widget_set_vexpand(W(view), 1)
        "htmlOverlay.page".withCString { gtk_widget_set_name(W(view), $0) }
        gtk_overlay_set_child(body, W(view))
        buildFailure()
        gtk_overlay_add_overlay(body, W(failure))
        gtk_widget_set_vexpand(W(body), 1)
        gtk_box_append(cast(panel), W(body))
        refreshBacking()
        refreshChrome()
        // app shortcuts first, as a macOS menu key equivalent preempts a focused web view
        let keys = gtk_event_controller_key_new()
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        let context = Unmanaged.passUnretained(handle).toOpaque()
        connect(keys, "key-pressed", unsafeBitCast(onPageKeyPressed as PageKeyCallback, to: GCallback.self), context)
        connect(keys, "key-released", unsafeBitCast(onPageKeyReleased as PageKeyReleaseCallback, to: GCallback.self), context)
        gtk_widget_add_controller(W(panel), keys)
    }

    private func buildStrip() -> OpaquePointer? {
        guard let strip = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)) else { return nil }
        gtk_widget_add_css_class(W(strip), "agterm-html-strip")
        if overlay.navigation {
            let back = button("go-previous-symbolic", "Back", "htmlOverlay.back", .back)
            let forward = button("go-next-symbolic", "Forward", "htmlOverlay.forward", .forward)
            if let back, let forward { historyButtons = (back, forward) }
            for widget in [back, forward, button("view-refresh-symbolic", "Reload", "htmlOverlay.reload", .reload)] {
                gtk_box_append(cast(strip), W(widget))
            }
        }
        gtk_box_append(cast(strip), W(buildLabel()))
        if overlay.navigation {
            gtk_box_append(cast(strip), W(button("web-browser-symbolic", "Open in Browser", "htmlOverlay.browser", .browser)))
            switch overlay.source {
            case .file:
                gtk_box_append(cast(strip), W(button("folder-open-symbolic", "Show in Files", "htmlOverlay.finder", .finder)))
            case .url:
                gtk_box_append(cast(strip), W(button("insert-link-symbolic", "Copy Link", "htmlOverlay.copy", .copyLink)))
            }
        }
        gtk_box_append(cast(strip), W(button("window-close-symbolic", "Close", "htmlOverlay.close", .close)))
        return strip
    }

    // the title is the page's own text, so it stays a separate dimmed label that gives up width before the
    // source does and cannot pass for part of the app-drawn identity
    private func buildLabel() -> OpaquePointer? {
        guard let label = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)) else { return nil }
        gtk_widget_set_hexpand(W(label), 1)
        gtk_widget_set_halign(W(label), GTK_ALIGN_CENTER)
        gtk_label_set_ellipsize(identity, PANGO_ELLIPSIZE_MIDDLE)
        gtk_widget_add_css_class(W(identity), "agterm-html-identity")
        "htmlOverlay.identity".withCString { gtk_widget_set_name(W(identity), $0) }
        gtk_label_set_ellipsize(titleLabel, PANGO_ELLIPSIZE_END)
        "htmlOverlay.title".withCString { gtk_widget_set_name(W(titleLabel), $0) }
        for widget in [titleSeparator, titleLabel] { gtk_widget_add_css_class(W(widget), "dim-label") }
        for widget in [identity, titleSeparator, titleLabel] { gtk_box_append(cast(label), W(widget)) }
        return label
    }

    private func button(_ icon: String, _ label: String, _ name: String, _ kind: LinuxHtmlStripAction.Kind) -> OpaquePointer? {
        guard let button = op(icon.withCString { gtk_button_new_from_icon_name($0) }) else { return nil }
        gtk_widget_add_css_class(W(button), "flat")
        label.withCString { gtk_widget_set_tooltip_text(W(button), $0) }
        name.withCString { gtk_widget_set_name(W(button), $0) }
        gtk_widget_set_focus_on_click(W(button), 0)
        let action = LinuxHtmlStripAction(pageID: id, kind: kind)
        actions.append(action)
        connect(button, "clicked", unsafeBitCast(onStripAction as @convention(c) (OpaquePointer?, gpointer?) -> Void,
                                                 to: GCallback.self), Unmanaged.passUnretained(action).toOpaque())
        return button
    }

    // over the page so a failed load never reads as a blank one; reload replaces it with the loading state
    private func buildFailure() {
        gtk_widget_set_halign(W(failure), GTK_ALIGN_FILL)
        gtk_widget_set_valign(W(failure), GTK_ALIGN_FILL)
        gtk_widget_add_css_class(W(failure), "agterm-html-failure")
        "htmlOverlay.error".withCString { gtk_widget_set_name(W(failure), $0) }
        let icon = op("dialog-warning-symbolic".withCString { gtk_image_new_from_icon_name($0) })
        gtk_image_set_pixel_size(icon, 24)
        gtk_widget_set_valign(W(icon), GTK_ALIGN_END)
        gtk_widget_set_vexpand(W(icon), 1)
        let title = op("The page could not be loaded".withCString { gtk_label_new($0) })
        gtk_widget_add_css_class(W(title), "heading")
        gtk_label_set_wrap(failureMessage, 1)
        gtk_label_set_justify(failureMessage, GTK_JUSTIFY_CENTER)
        gtk_label_set_selectable(failureMessage, 1)
        gtk_widget_set_valign(W(failureMessage), GTK_ALIGN_START)
        gtk_widget_set_vexpand(W(failureMessage), 1)
        for widget in [icon, title, failureMessage] { gtk_box_append(cast(failure), W(widget)) }
    }

    // MARK: - Mounting

    func mount(in target: LinuxHtmlMount) {
        guard mount != target else { return }
        unmount()
        switch target {
        case .stack(let stack): "overlay".withCString { _ = gtk_stack_add_named(stack, W(panel), $0) }
        case .frame(let frame): gtk_frame_set_child(cast(frame), W(panel))
        case .paneHost(let host): gtk_overlay_add_overlay(host, W(panel))
        }
        mount = target
    }

    func unmount() {
        switch mount {
        case .stack(let stack): gtk_stack_remove(stack, W(panel))
        case .frame(let frame): gtk_frame_set_child(cast(frame), nil)
        case .paneHost(let host): gtk_overlay_remove_overlay(host, W(panel))
        case nil: break
        }
        mount = nil
        endPrompt()
    }

    func focus() {
        guard gtk_widget_has_focus(W(view)) == 0 else { return }
        gtk_widget_grab_focus(W(view))
    }

    func setZoom(_ zoom: Double) {
        api.pointee.set_zoom(W(view), zoom)
    }

    func setDimmed(_ opacity: Double) {
        gtk_widget_set_opacity(W(panel), opacity)
    }

    func close() {
        endPrompt()
        api.pointee.close(W(view))
        unmount()
        actions.removeAll()
        g_object_unref(GOBJ(panel))
        g_object_unref(GOBJ(view))
        for label in [identity, titleSeparator, titleLabel] { g_object_unref(GOBJ(label)) }
    }

    // MARK: - Model

    /// apply takes the model's latest value and reloads when its revision moved.
    func apply(_ latest: HtmlOverlay) {
        overlay = latest
        refreshChrome()
        guard latest.reloadRevision != appliedRevision else { return }
        appliedRevision = latest.reloadRevision
        if latest.reloadTarget == .current { reloadShown() } else { loadOriginal() }
    }

    /// applyTheme gives later loads a changed theme; a file page wears it and reloads what it shows.
    func applyTheme(_ theme: HtmlOverlayTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        theme.script(themed: Self.themed(overlay)).withCString { api.pointee.set_theme_script(W(view), $0) }
        refreshBacking()
        if Self.themed(overlay) { reloadShown() }
    }

    // a file page without a grant is loaded from its text, so the file is both source and current page
    private var textLoaded: Bool {
        if case .file(_, nil) = overlay.source { return true }
        return false
    }

    private func loadOriginal() {
        load.begin()
        switch overlay.source {
        case .url(let url):
            url.absoluteString.withCString { api.pointee.load_uri(W(view), $0) }
        case .file(let path, let grantRoot?):
            path.withCString { file in grantRoot.withCString { api.pointee.load_file(W(view), file, $0) } }
        case .file(let path, nil):
            do {
                try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8).withCString {
                    api.pointee.load_html(W(view), $0)
                }
            } catch {
                receive(.failed(error.localizedDescription))
            }
        }
    }

    private func reloadShown() {
        // before a first commit WebKit has nothing to reload, so the source is loaded again instead
        if !textLoaded, load.committed {
            load.begin()
            api.pointee.reload(W(view))
        } else {
            loadOriginal()
        }
    }

    private var currentURI: String? {
        guard let raw = api.pointee.uri(W(view)) else { return nil }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    /// pageURL is what the page shows: its file when loaded from text, else the view's address.
    var pageURL: URL {
        if textLoaded, case .file(let path, _) = overlay.source { return URL(fileURLWithPath: path) }
        if let text = currentURI, let url = URL(string: text), url.scheme != "about" { return url }
        switch overlay.source {
        case .file(let path, _): return URL(fileURLWithPath: path)
        case .url(let url): return url
        }
    }

    /// browserURL is the original file of a file page, or what a URL page shows while it is web.
    var browserURL: URL {
        switch overlay.source {
        case .file(let path, _):
            return URL(fileURLWithPath: path)
        case .url(let original):
            guard let text = currentURI, let url = URL(string: text), url.scheme == "http" || url.scheme == "https" else {
                return original
            }
            return url
        }
    }

    var isFilePage: Bool { Self.themed(overlay) }

    func navigate(back: Bool) -> String? {
        let possible = back ? api.pointee.can_go_back(W(view)) : api.pointee.can_go_forward(W(view))
        guard possible else { return OverlayHtmlError.noHistory(back ? .back : .forward) }
        if back { api.pointee.go_back(W(view)) } else { api.pointee.go_forward(W(view)) }
        return nil
    }

    fileprivate func reportPage() {
        guard currentURI != nil else { return }
        let url = pageURL
        let raw = api.pointee.title(W(view))
        let title = raw.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        g_free(raw)
        let info = HtmlPageInfo(page: url.isFileURL ? url.path : url.absoluteString, title: title,
                                canGoBack: api.pointee.can_go_back(W(view)), canGoForward: api.pointee.can_go_forward(W(view)))
        overlay.current = info
        store?.setHtmlPage(id, info)
        refreshChrome()
    }

    fileprivate func record(_ outcome: LinuxHtmlLoad.Outcome) {
        switch outcome {
        case .none: return
        case .loading: setState(.loading, nil)
        case .loaded:
            setState(.loaded, nil)
            reportPage()
        case .failed(let message): setState(.failed, message)
        }
    }

    fileprivate func receive(_ event: LinuxHtmlLoad.Event) {
        record(load.handle(event))
    }

    private func setState(_ state: HtmlLoadState, _ error: String?) {
        overlay.loadState = state
        overlay.loadError = error
        store?.setHtmlLoadState(id, state: state, error: error)
        refreshChrome()
    }

    fileprivate func decide(_ uri: String, target: LinuxHtmlTarget, userActivated: Bool) -> Bool {
        guard let url = URL(string: uri) else { return false }
        let decision = LinuxHtmlPolicy.decide(url: url, target: target, userActivated: userActivated, overlay: overlay)
        if decision == .openExternal { askToOpen(url) }
        if decision == .cancel, target == .mainResponse { record(load.blocked(url)) }
        return decision == .allow
    }

    private func refreshChrome() {
        overlay.identity.withCString { gtk_label_set_text(identity, $0) }
        (overlay.current?.page ?? sourceText).withCString { gtk_widget_set_tooltip_text(W(identity), $0) }
        let title = overlay.current?.title
        (title ?? "").withCString {
            gtk_label_set_text(titleLabel, $0)
            gtk_widget_set_tooltip_text(W(titleLabel), $0)
        }
        for widget in [titleSeparator, titleLabel] { gtk_widget_set_visible(W(widget), title == nil ? 0 : 1) }
        if let historyButtons {
            gtk_widget_set_sensitive(W(historyButtons.back), overlay.current?.canGoBack == true ? 1 : 0)
            gtk_widget_set_sensitive(W(historyButtons.forward), overlay.current?.canGoForward == true ? 1 : 0)
        }
        gtk_widget_set_visible(W(failure), overlay.loadState == .failed ? 1 : 0)
        (overlay.loadError ?? "").withCString { gtk_label_set_text(failureMessage, $0) }
    }

    private var sourceText: String {
        switch overlay.source {
        case .file(let path, _): path
        case .url(let url): url.absoluteString
        }
    }

    private func refreshBacking() {
        let next = LinuxHtmlOverlays.backingClass(for: backgroundColor ?? theme.background)
        guard next != backingClass else { return }
        for widget in [body, failure] {
            if let backingClass { backingClass.withCString { gtk_widget_remove_css_class(W(widget), $0) } }
            next.withCString { gtk_widget_add_css_class(W(widget), $0) }
        }
        backingClass = next
    }

    // MARK: - Hand-off prompt

    private func askToOpen(_ url: URL) {
        // a page out of sight asks nothing
        guard gtk_widget_get_mapped(W(panel)) != 0, prompt == nil, !promptsSilenced else { return }
        let token = UUID()
        let dialog = OpaquePointer("Open in Browser?".withCString { heading in
            "The page asks to open \(url.absoluteString)".withCString { adw_alert_dialog_new(heading, $0) }
        })
        "cancel".withCString { i in "Cancel".withCString { adw_alert_dialog_add_response(cast(dialog), i, $0) } }
        "open".withCString { i in "Open".withCString { adw_alert_dialog_add_response(cast(dialog), i, $0) } }
        "cancel".withCString { adw_alert_dialog_set_default_response(cast(dialog), $0) }
        "cancel".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        prompt = (token, dialog!)
        let context = Unmanaged.passRetained(LinuxHtmlPrompt(pageID: id, token: token, url: url)).toOpaque()
        connect(dialog, "response", unsafeBitCast(onPromptResponse as @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void,
                                                  to: GCallback.self), context)
        adw_dialog_present(cast(dialog), W(view))
    }

    fileprivate func answer(_ token: UUID, _ url: URL, approved: Bool) {
        guard prompt?.token == token else { return }
        prompt = nil
        if approved {
            _ = LinuxHtmlOverlays.shared.browser.open(url)
        } else {
            promptsSilenced = true
        }
    }

    private func endPrompt() {
        guard let dialog = prompt?.dialog else { return }
        prompt = nil
        adw_dialog_force_close(cast(dialog))
    }

    fileprivate func noteInput() {
        promptsSilenced = false
        LinuxHtmlOverlays.shared.noteActivity(store: store)
    }

    fileprivate func handleKey(keyval: UInt32, keycode: UInt32, state: UInt32, event: OpaquePointer?) -> Bool {
        LinuxHtmlOverlays.shared.handleKey(id, store: store, key: (keyval, keycode, state), event: event)
    }

    fileprivate func noteFocus() {
        LinuxHtmlOverlays.shared.pageFocused(id, store: store)
    }

    /// handleBridgeRequest runs one request the page sent and answers it through `reply` exactly once. The page
    /// is resolved where it sits NOW, so a request after a swap or a move acts from its new place. The dispatch
    /// waits for the next main-loop turn, so a command that closes this page never runs inside WebKit's signal.
    fileprivate func handleBridgeRequest(_ json: String, reply: UnsafeMutableRawPointer?) {
        let api = api
        let answer: @MainActor (String?, String?) -> Void = { result, error in
            api.pointee.answer(reply, result, error)
        }
        guard let store, let slot = store.htmlOverlaySlot(id) else { return answer(nil, "page closed") }
        let origin = HtmlBridgePage(window: LinuxHtmlOverlays.shared.windowID(of: store), session: slot.session.id,
                                    pane: slot.pane)
        let request: ControlRequest
        switch LinuxHtmlBridge.request(json: json, page: origin) {
        case .success(let built): request = built
        case .failure(let refusal): return answer(nil, refusal.message)
        }
        _ = MainTimer.schedule(after: 0) {
            ControlServer.dispatchFromPage(request) { response in
                let (result, error) = LinuxHtmlBridge.reply(response)
                answer(result, error)
            }
        }
    }
}

/// LinuxHtmlStripAction is one strip button's target, held by its page for the button's life.
@MainActor
final class LinuxHtmlStripAction {
    enum Kind { case back, forward, reload, browser, finder, copyLink, close }
    let pageID: UUID
    let kind: Kind

    init(pageID: UUID, kind: Kind) {
        self.pageID = pageID
        self.kind = kind
    }
}

private final class LinuxHtmlPrompt {
    let pageID: UUID
    let token: UUID
    let url: URL

    init(pageID: UUID, token: UUID, url: URL) {
        self.pageID = pageID
        self.token = token
        self.url = url
    }
}

/// LinuxHtmlPageHandle is what the plugin holds for a page, filled once the page exists.
final class LinuxHtmlPageHandle {
    weak var page: LinuxHtmlOverlayPage?
}

// the plugin calls on the main thread; a context crosses into the main actor as its bit pattern
@MainActor private func page(_ context: UInt) -> LinuxHtmlOverlayPage? {
    guard let raw = UnsafeMutableRawPointer(bitPattern: context) else { return nil }
    return Unmanaged<LinuxHtmlPageHandle>.fromOpaque(raw).takeUnretainedValue().page
}

private typealias DecideCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, agterm_web_target, Bool) -> Bool
private typealias LoadCallback = @convention(c) (UnsafeMutableRawPointer?, agterm_web_load_event, UnsafePointer<CChar>?) -> Void

private let onDecide: DecideCallback = { context, uri, target, userActivated in
    let key = UInt(bitPattern: context)
    let text = uri.map { String(cString: $0) }
    let mapped: LinuxHtmlTarget
    switch target {
    case AGTERM_WEB_NAVIGATION_NEW_WINDOW: mapped = .newWindow
    case AGTERM_WEB_RESPONSE_MAIN_FRAME: mapped = .mainResponse
    case AGTERM_WEB_RESPONSE_SUBFRAME: mapped = .subframeResponse
    default: mapped = .frame
    }
    return MainActor.assumeIsolated {
        guard let page = page(key), let text else { return false }
        return page.decide(text, target: mapped, userActivated: userActivated)
    }
}

private let onLoad: LoadCallback = { context, event, message in
    let key = UInt(bitPattern: context)
    let text = message.map { String(cString: $0) } ?? ""
    let received: LinuxHtmlLoad.Event
    switch event {
    case AGTERM_WEB_LOAD_STARTED: received = .started
    case AGTERM_WEB_LOAD_COMMITTED: received = .committed
    case AGTERM_WEB_LOAD_FINISHED: received = .finished
    case AGTERM_WEB_LOAD_CANCELLED: received = .cancelled
    case AGTERM_WEB_LOAD_INTERRUPTED: received = .interrupted(text)
    case AGTERM_WEB_PROCESS_TERMINATED: received = .terminated
    default: received = .failed(text)
    }
    MainActor.assumeIsolated { page(key)?.receive(received) }
}

private typealias PageKeyCallback = @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) -> gboolean
private typealias PageKeyReleaseCallback = @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void

private let onPageKeyPressed: PageKeyCallback = { controller, keyval, keycode, state, context in
    let key = UInt(bitPattern: context)
    let event = UInt(bitPattern: gtk_event_controller_get_current_event(controller))
    return MainActor.assumeIsolated {
        let consumed = page(key)?.handleKey(keyval: keyval, keycode: keycode, state: state,
                                            event: OpaquePointer(bitPattern: event)) ?? false
        return consumed ? 1 : 0
    }
}

private let onPageKeyReleased: PageKeyReleaseCallback = { _, keyval, keycode, _, context in
    let key = UInt(bitPattern: context)
    MainActor.assumeIsolated {
        releaseOwnedKey(keycode)
        if keyval == 0xFFE3 || keyval == 0xFFE4 { LinuxHtmlOverlays.shared.endSessionSwitch(page(key)) }
    }
}

private let onChanged: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    let key = UInt(bitPattern: context)
    MainActor.assumeIsolated { page(key)?.reportPage() }
}

private let onInput: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    let key = UInt(bitPattern: context)
    MainActor.assumeIsolated { page(key)?.noteInput() }
}

private typealias RequestCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

private let onRequest: RequestCallback = { context, json, reply in
    let key = UInt(bitPattern: context)
    let text = json.map { String(cString: $0) } ?? ""
    let token = UInt(bitPattern: reply)
    MainActor.assumeIsolated {
        let reply = UnsafeMutableRawPointer(bitPattern: token)
        guard let page = page(key) else {
            return LinuxWebKit.answer(reply, nil, "page closed")
        }
        page.handleBridgeRequest(text, reply: reply)
    }
}

private let onFocus: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    let key = UInt(bitPattern: context)
    MainActor.assumeIsolated { page(key)?.noteFocus() }
}

private let onStripAction: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let action = Unmanaged<LinuxHtmlStripAction>.fromOpaque(data).takeUnretainedValue()
        LinuxHtmlOverlays.shared.perform(action.kind, page: action.pageID)
    }
}

private let onPromptResponse: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, response, data in
    guard let data else { return }
    let prompt = Unmanaged<LinuxHtmlPrompt>.fromOpaque(data).takeRetainedValue()
    let approved = response.map { String(cString: $0) } == "open"
    MainActor.assumeIsolated {
        LinuxHtmlOverlays.shared.existing(prompt.pageID)?.answer(prompt.token, prompt.url, approved: approved)
    }
}
