import agtermCore

/// The GTK half of upstream's palette/switcher interface size (#367). `InterfaceMetrics` owns every number;
/// this only spells them as CSS and as the panel's default size, so the two surfaces cannot drift apart or
/// from macOS. The sidebar is deliberately NOT one of them — it has its own `sidebarFontSize`.
enum LinuxInterfacePolicy {
    /// Title, subtitle/badge and shortcut sizes for the command palette, the control picker and the
    /// Ctrl-Tab switcher. The badge keeps its `em`-relative padding, so it scales with the text it sits in.
    static func interfaceCSS(fontSize: Double?) -> String {
        let metrics = InterfaceMetrics(fontSize: fontSize ?? AppSettings.defaultInterfaceFontSize)
        return """
            .agterm-interface label { font-size: \(metrics.base)pt; }
            .agterm-interface .dim-label { font-size: \(metrics.shortcut)pt; }
            .agterm-interface .agterm-palette-badge { font-size: \(metrics.secondary)pt; }
            .agterm-switcher label { font-size: \(metrics.base)pt; }
            .agterm-switcher label.agterm-switcher-current { font-size: \(metrics.base)pt; }
            """
    }

    /// The title bar's parts with each Interface toggle resolved. The workspace comes from the ACTIVE
    /// SESSION, not `currentWorkspaceID`: selecting an empty workspace makes it current while the previous
    /// session stays selected, and the title names that session's home.
    @MainActor
    static func titlebarParts(store: AppStore, hidden: Set<InterfaceElement>,
                              window: WindowInfo?) -> TitlebarComposition.Parts {
        let session = store.activeSession
        return TitlebarComposition.Parts(
            workspaceName: hidden.contains(.workspaceName)
                ? nil : session.flatMap { store.workspace(forSession: $0.id)?.name },
            sessionName: hidden.contains(.sessionName) ? nil : (session?.displayName ?? "agterm"),
            windowName: hidden.contains(.windowName) || window?.hasCustomName != true ? nil : window?.name,
            context: hidden.contains(.sessionContext) ? nil : session?.context,
            detail: session?.subtitleDetail ?? "",
            remoteHost: hidden.contains(.remoteHost) ? nil : session?.remoteHost
        )
    }

    /// Shows or hides one chrome element. A `hiddenByDefault` element is governed by `shownInterfaceElements`,
    /// the same shape with the opposite sense; an empty list maps back to nil.
    static func settingElement(_ element: InterfaceElement, visible: Bool, in settings: AppSettings) -> AppSettings {
        var settings = settings
        if element.hiddenByDefault {
            var shown = Set(settings.shownInterfaceElements ?? [])
            if visible { shown.insert(element.rawValue) } else { shown.remove(element.rawValue) }
            settings.shownInterfaceElements = shown.isEmpty ? nil : shown.sorted()
        } else {
            var hidden = Set(settings.hiddenInterfaceElements ?? [])
            if visible { hidden.remove(element.rawValue) } else { hidden.insert(element.rawValue) }
            settings.hiddenInterfaceElements = hidden.isEmpty ? nil : hidden.sorted()
        }
        return settings
    }

    /// A panel's default size at the current interface size. Scaling both axes is what keeps the same number
    /// of rows visible as the text grows, which is the whole point of `InterfaceMetrics.scaled`.
    static func panelSize(fontSize: Double?, width: Double, height: Double) -> (width: Int32, height: Int32) {
        let metrics = InterfaceMetrics(fontSize: fontSize ?? AppSettings.defaultInterfaceFontSize)
        return (Int32(metrics.scaled(width)), Int32(metrics.scaled(height)))
    }
}
