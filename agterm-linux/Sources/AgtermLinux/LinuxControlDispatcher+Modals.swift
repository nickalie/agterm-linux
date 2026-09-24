import Foundation
import agtermCore

/// The two modal families whose validation `agtermCore` keeps internal to its own dispatcher, mirrored so
/// the Linux control server refuses the same inputs with the same words. Split out of
/// `LinuxControlDispatcher` for file length; the host halves live in `ControlAsk` and
/// `ControlActions+AppControllerHud`.
extension LinuxControlDispatcher {
    /// `ask.*`. Mirrors `agtermCore`'s `ControlDispatcher+Ask`, which is internal to that module: caller
    /// input is checked here, and modal state, placement and presentation belong to the host.
    func dispatchAskCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .askOpen:
            return dispatchAskOpen(request)
        case .askResult:
            guard let target = request.target else {
                return ControlResponse(ok: false, error: "ask.result requires an ask id")
            }
            return actions.askResult(target, window: request.args?.window)
        default:
            guard let target = request.target else {
                return ControlResponse(ok: false, error: "ask.cancel requires an ask id")
            }
            return actions.cancelAsk(target, window: request.args?.window)
        }
    }

    func dispatchAskOpen(_ request: ControlRequest) -> ControlResponse {
        guard let args = request.args, let title = args.title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ControlResponse(ok: false, error: "ask.open requires a title")
        }
        guard let buttons = args.buttons else {
            return ControlResponse(ok: false, error: "ask.open requires buttons")
        }
        guard !buttons.isEmpty else {
            return ControlResponse(ok: false, error: "ask.open requires at least one button")
        }
        guard buttons.count <= ControlAskButton.maxButtons else {
            return ControlResponse(ok: false, error: "too many buttons (max \(ControlAskButton.maxButtons))")
        }
        guard buttons.allSatisfy({ !$0.label.isEmpty }) else {
            return ControlResponse(ok: false, error: "ask button label must not be empty")
        }
        var ids = Set<String>()
        guard buttons.allSatisfy({ ids.insert($0.id).inserted }) else {
            return ControlResponse(ok: false, error: "ask button ids must be unique")
        }
        guard !containsControlCharacters(title), !containsControlCharacters(args.message ?? ""),
              buttons.allSatisfy({ !containsControlCharacters($0.label) }) else {
            return ControlResponse(ok: false, error: "ask text must not contain control characters")
        }
        for (role, id) in [("default", args.defaultButton), ("destructive", args.destructiveButton)] {
            if let id, !ids.contains(id) {
                return ControlResponse(ok: false, error: "unknown \(role) button: \(id)")
            }
        }
        if let destructive = args.destructiveButton, args.defaultButton == destructive {
            return ControlResponse(ok: false, error: "default button must not be destructive")
        }
        guard let style = ControlAskStyle(rawValue: args.style ?? "terminal") else {
            return ControlResponse(ok: false, error: "unknown style")
        }
        guard let align = ControlAskAlignment(rawValue: args.align ?? "right") else {
            return ControlResponse(ok: false, error: "unknown align")
        }
        if let width = args.width, !(10...100).contains(width) {
            return ControlResponse(ok: false, error: "width must be 10 to 100")
        }
        var hotkeys = Set<String>()
        for button in buttons {
            guard let hotkey = button.hotkey else { continue }
            guard hotkey.utf8.count == 1, let ascii = hotkey.utf8.first,
                  (65...90).contains(ascii) || (97...122).contains(ascii) else {
                return ControlResponse(ok: false, error: "ask button hotkey must be one ASCII letter")
            }
            guard hotkeys.insert(hotkey.lowercased()).inserted else {
                return ControlResponse(ok: false, error: "ask button hotkeys must be unique")
            }
        }
        if style == .gui, args.pane != nil || args.paneID != nil, request.target == nil {
            return ControlResponse(ok: false, error: "--pane requires a session")
        }
        let pane: OverlayPane?
        switch parsePane(args.pane, error: "--pane must be left or right",
                         parse: { OverlayPane(controlName: $0) }) {
        case .pane(let parsed): pane = parsed
        case .rejected(let response): return response
        }
        let ask = PendingAsk(
            id: UUID().uuidString, title: title, message: args.message,
            buttons: buttons.map { ControlAskButton(id: $0.id, label: $0.label, hotkey: $0.hotkey?.lowercased()) },
            defaultID: args.defaultButton, destructiveID: args.destructiveButton,
            style: style, align: align, width: args.width)
        return actions.openAsk(ask, target: request.target, window: args.window,
                               placement: ControlAskPlacement(pane: pane, paneID: args.paneID),
                               follow: args.follow == true)
    }

    /// `session.hud.*`. Mirrors `agtermCore`'s `ControlDispatcher+Hud`, which is internal to that module:
    /// text, color, percent, position, spinner and pane spelling are checked here, and slot occupancy,
    /// pane identity and sizing need the store and stay in the host.
    func dispatchHudCommand(_ request: ControlRequest) -> ControlResponse {
        if request.cmd == .sessionHudClose {
            return actions.closeHud(request.target, window: request.args?.window)
        }
        let post: (String?, String?, HudSpec, ControlHudPlacement) -> ControlResponse
        switch request.cmd {
        case .sessionHudOpen: post = actions.openHud
        default: post = actions.updateHud
        }
        let pane: OverlayPane?
        switch parsePane(request.args?.pane, error: "--pane must be left or right",
                         parse: { OverlayPane(controlName: $0) }) {
        case .pane(let parsed): pane = parsed
        case .rejected(let response): return response
        }
        switch Self.parseHudSpec(request) {
        case .rejected(let response): return response
        case .spec(let spec):
            return post(request.target, request.args?.window, spec,
                        ControlHudPlacement(pane: pane, paneID: request.args?.paneID))
        }
    }

    enum HudSpecParse {
        case spec(HudSpec)
        case rejected(ControlResponse)
    }

    /// Mirrors the shared `ControlDispatcher.parseHudSpec`: open and update validate alike except for
    /// `fontSize`, which only open takes, and an update replaces the whole spec rather than patching it.
    static func parseHudSpec(_ request: ControlRequest) -> HudSpecParse {
        let args = request.args
        let markdown = args?.markdown ?? false
        guard let message = args?.message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(ControlResponse(ok: false, error: "\(request.cmd.rawValue) requires a message"))
        }
        guard !containsHudControlCharacters(message, markdown: markdown),
              !containsHudControlCharacters(args?.detail ?? "", markdown: false) else {
            return .rejected(ControlResponse(ok: false, error: "hud text must not contain control characters"))
        }
        let cap = markdown ? HudSpec.maxMarkdownLength : HudSpec.maxTextLength
        guard hudTextLength(message) <= cap else {
            return .rejected(ControlResponse(ok: false, error: "hud message too long (max \(cap) characters)"))
        }
        guard !markdown || HudMarkdown.rendersVisibleText(message) else {
            return .rejected(ControlResponse(ok: false, error: "\(request.cmd.rawValue) requires a message"))
        }
        guard hudTextLength(args?.detail ?? "") <= HudSpec.maxTextLength else {
            return .rejected(ControlResponse(
                ok: false, error: "hud detail too long (max \(HudSpec.maxTextLength) characters)"))
        }
        if let color = args?.color, !WatermarkConfig.isValidColorHex(color) {
            return .rejected(ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)"))
        }
        if let textColor = args?.textColor, !WatermarkConfig.isValidColorHex(textColor) {
            return .rejected(ControlResponse(ok: false, error: "invalid text color: \(textColor) (#rrggbb)"))
        }
        if let fontSize = args?.fontSize {
            guard request.cmd == .sessionHudOpen else {
                return .rejected(ControlResponse(
                    ok: false, error: "session.hud.update: --font-size is fixed at open; reopen the hud to change it"))
            }
            guard HudSpec.isValidFontSize(fontSize) else {
                let range = HudSpec.fontSizeRange
                return .rejected(ControlResponse(
                    ok: false,
                    error: "session.hud.open: --font-size must be \(Int(range.lowerBound))...\(Int(range.upperBound)) points"))
            }
        }
        if let percent = args?.sizePercent, !(1...100).contains(percent) {
            return .rejected(ControlResponse(ok: false,
                                             error: "\(request.cmd.rawValue): --size-percent must be 1...100"))
        }
        if let hideAfter = args?.hideAfter, !HudSpec.isValidHideAfter(hideAfter) {
            return .rejected(ControlResponse(
                ok: false,
                error: "\(request.cmd.rawValue): --hide-after must be 0...\(Int(HudSpec.maxHideAfter)) seconds"))
        }
        var position = HudPosition.defaultPosition
        if let raw = args?.position {
            guard let parsed = HudPosition.parse(raw) else {
                return .rejected(ControlResponse(
                    ok: false, error: "invalid position: \(raw) (\(HudPosition.acceptedNamesList))"))
            }
            position = parsed
        }
        // `none` is the read-back's spelling for a static panel, so a caller echoing one back means "no
        // spinner" rather than a style this rejects.
        var spinner: HudSpinner?
        if let raw = args?.spinner, raw != HudSpinner.noneName {
            guard let parsed = HudSpinner(rawValue: raw) else {
                return .rejected(ControlResponse(
                    ok: false, error: "invalid spinner: \(raw) (\(HudSpinner.acceptedNamesList))"))
            }
            spinner = parsed
        }
        return .spec(HudSpec(message: message, detail: args?.detail, spinner: spinner,
                             backgroundColor: args?.color, textColor: args?.textColor,
                             sizePercent: args?.sizePercent, position: position,
                             hideAfter: args?.hideAfter, markdown: markdown, fontSize: args?.fontSize))
    }

    /// The helper prints these bytes into a live terminal, so any C0 control or DEL is refused, less the LF
    /// and TAB markdown structure needs.
    static func containsHudControlCharacters(_ text: String, markdown: Bool) -> Bool {
        text.unicodeScalars.contains { scalar in
            if markdown, scalar == "\n" || scalar == "\t" { return false }
            return scalar.value < 0x20 || scalar.value == 0x7f
        }
    }

    /// `HudLayout.textLength`'s unit, which that module keeps internal: scalars of the precomposed form the
    /// panel is laid out in, so the cap bounds what the frame actually has to fit.
    static func hudTextLength(_ text: String) -> Int {
        text.precomposedStringWithCanonicalMapping.unicodeScalars.count
    }
}
