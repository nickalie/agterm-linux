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

    /// A panel's default size at the current interface size. Scaling both axes is what keeps the same number
    /// of rows visible as the text grows, which is the whole point of `InterfaceMetrics.scaled`.
    static func panelSize(fontSize: Double?, width: Double, height: Double) -> (width: Int32, height: Int32) {
        let metrics = InterfaceMetrics(fontSize: fontSize ?? AppSettings.defaultInterfaceFontSize)
        return (Int32(metrics.scaled(width)), Int32(metrics.scaled(height)))
    }
}
