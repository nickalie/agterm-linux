/// AgentStatus is the per-session agent state driven over the control channel (`session.status`).
/// `idle` means nothing is shown; the other cases each render a tinted sidebar glyph.
public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case idle, active, completed, blocked

    /// True for the states that are waiting on the USER: a `blocked` prompt or a `completed` run, not `active`
    /// (still working) or `idle` (no glyph). The single membership rule for every attention surface —
    /// navigation (⌃⌥↑/↓, `session.go next-attention|prev-attention`) and `AppStore.attentionSessions`, which
    /// backs the titlebar bell, its popover, the Dock menu group, and the `.attention` palette.
    public var needsAttention: Bool { self == .blocked || self == .completed }

    /// The state a keystroke in the session's terminal moves this one to, or nil to leave it alone.
    /// `completed` clears on ANY key (you've engaged with the finished result), and `active` clears ONLY on an
    /// interrupt (Escape or Ctrl-C), so typing while the agent works keeps the "working" glyph. That covers the
    /// quick-cancel case: a pending question can still read `active` when you cancel it (Claude Code's
    /// `blocked` notification lands seconds later) and the interrupt fires no hook, so nothing else drops the
    /// stale value.
    ///
    /// `blocked` splits on the same flag rather than clearing outright. An ordinary key there is you ANSWERING
    /// the prompt, and the agent then works with NO hook announcing it — Claude Code's next event is
    /// `PostToolUse`, which lands only once the approved tool has finished, and its `PreToolUse` already fired
    /// before the prompt. Clearing to idle therefore left the glyph dark for the whole run, which is exactly
    /// the run you approved and walked away from. An interrupt stays the decline and still goes idle.
    /// The cost is that a stale `blocked` left by a dead agent becomes a stale `active` once you type; Esc,
    /// Ctrl-C and Clear Status drop it as they always did.
    func afterKeystroke(isInterrupt: Bool) -> AgentStatus? {
        switch self {
        case .blocked: return isInterrupt ? .idle : .active
        case .completed: return .idle
        case .active: return isInterrupt ? .idle : nil
        case .idle: return nil
        }
    }

    /// Sort priority for the attention list, lower first. Only `needsAttention` states reach it; `active` and
    /// `idle` keep ranks so an accidental inclusion sorts after the states that are actually waiting.
    public var attentionRank: Int {
        switch self {
        case .blocked: return 0
        case .active: return 1
        case .completed: return 2
        case .idle: return 3
        }
    }

    /// The sound to play for a `session.status` call, or nil for none: an explicit per-call sound
    /// (`session.status --sound`) wins, else the configured `blockedDefault` (Settings "Blocked sound") plays
    /// ONLY for `blocked`; empty strings count as unset. The app resolves the name with `NSSound(named:)`.
    public func effectiveSound(perCall: String?, blockedDefault: String?) -> String? {
        if let perCall, !perCall.isEmpty { return perCall }
        if self == .blocked, let blockedDefault, !blockedDefault.isEmpty { return blockedDefault }
        return nil
    }

    /// symbolName resolves the SF Symbol for the status glyph, shared by the AppKit sidebar and the SwiftUI
    /// attention list: the per-call `override` (from `session.status --shape`) wins, else the `configured`
    /// Settings shape, else `StatusShape.circle`. `idle` renders no glyph, so its "" is filtered out before use.
    public func symbolName(override: StatusShape?, configured: StatusShape?) -> String {
        guard self != .idle else { return "" }
        return (override ?? configured ?? .circle).symbolName
    }

    /// Tooltip for a visible status glyph. Idle renders no glyph and therefore has no tooltip.
    public var tooltipText: String? {
        self == .idle ? nil : "Agent status: \(rawValue.capitalized)"
    }
}

/// StatusPane records which pane set the current agent status, in the `--pane` control vocabulary it also
/// serializes as (`left`=main, `right`=split, `scratch`). Pane-scoped keystroke-clear and pane-aware
/// navigation read it off `AgentIndicator` to know which surface blocked.
public enum StatusPane: String, Codable, Sendable, CaseIterable {
    case left, right, scratch

    /// Parses every accepted positional or role spelling while keeping `rawValue` stable for read-back and
    /// the `AGTERM_PANE` environment (`left|right|scratch`).
    public init?(controlName: String) {
        switch controlName {
        case "left", "top", "primary": self = .left
        case "right", "bottom", "split": self = .right
        case "scratch": self = .scratch
        default: return nil
        }
    }
}

/// StatusShape is the silhouette a status glyph draws, so shape carries the state alongside the tint. Every
/// shape is plain, with no interior mark, selectable per status in Settings or per call via
/// `session.status --shape`; `circle` is what an unset status draws. The raw value is the SF Symbol base name.
public enum StatusShape: String, Codable, Sendable, CaseIterable {
    case circle, square, triangle, diamond, capsule, star

    /// SF Symbol name for the shape — the `.fill` variant, so every glyph is a solid silhouette, not an outline.
    public var symbolName: String { "\(rawValue).fill" }

    /// The human-facing name ("Triangle"): the Settings picker's per-option accessibility label and its value.
    public var displayName: String { rawValue.capitalized }

    /// The accepted names pipe-joined — the compact form the control server's rejection message uses. Derived
    /// from `allCases`, like `WatermarkConfig.validFits`, so no message can go stale.
    public static var validNamesList: String { validNames.joined(separator: "|") }

    /// The accepted names comma-joined — the prose form for `agtermctl --shape` help and its local rejection.
    public static var validNamesPhrase: String { validNames.joined(separator: ", ") }

    private static var validNames: [String] { allCases.map(\.rawValue) }
}

/// AgentIndicator is the per-session agent status value: state, blink, autoReset, per-call color and shape
/// overrides, and the pane that set it. Ephemeral (never persisted) and set only via the control API.
public struct AgentIndicator: Equatable, Sendable {
    public var status: AgentStatus = .idle
    /// blink makes the visible glyph pulse for attention.
    public var blink: Bool = false
    /// autoReset resets the indicator to idle once the session is visited (selected) — caller-set and
    /// status-agnostic, like blink.
    public var autoReset: Bool = false
    /// color, when set, is a `#rrggbb` hex overriding the Settings tint for this glyph only; it rides the
    /// ephemeral indicator, so the next `session.status` without a color discards it. nil = the default tint.
    public var color: String?
    /// shape, when set, overrides the Settings-configured silhouette for this glyph only, discarded like
    /// `color`. nil falls back to the Settings shape, else the default plain circle.
    public var shape: StatusShape?
    /// statusPane records which pane set this status; nil is unspecified and treated as `.left` (main) by the
    /// clear logic.
    public var statusPane: StatusPane?

    public init(status: AgentStatus = .idle, blink: Bool = false, autoReset: Bool = false,
                color: String? = nil, shape: StatusShape? = nil, statusPane: StatusPane? = nil) {
        self.status = status
        self.blink = blink
        self.autoReset = autoReset
        self.color = color
        self.shape = shape
        self.statusPane = statusPane
    }

    /// afterKeystroke: the indicator a keystroke from `pane` leaves behind, or nil to keep the current one.
    /// Only the pane OWNING the status may move it, so foreground typing can't wipe a background pane's glyph.
    /// The `blocked`→`active` promotion keeps the pane tag and blinks — matching the `active --blink` the hook
    /// would have set — but drops the per-call color and shape, which described the state being left.
    public func afterKeystroke(pane: StatusPane, isInterrupt: Bool) -> AgentIndicator? {
        guard (statusPane ?? .left) == pane,
              let next = status.afterKeystroke(isInterrupt: isInterrupt) else { return nil }
        return next == .idle ? AgentIndicator() : AgentIndicator(status: next, blink: true, statusPane: pane)
    }

    /// normalizedPane: the tag as the store keeps it — a `.right` tag on a splitless session folds to `.left`,
    /// since a promoted survivor's shell keeps its baked `AGTERM_PANE=right` and the sole (`.left`-role-aware)
    /// pane could never keystroke-clear a `.right` tag. nil is preserved so the read-back omits the field.
    func normalizedPane(hasSplit: Bool) -> StatusPane? {
        statusPane == .right && !hasSplit ? .left : statusPane
    }
}
