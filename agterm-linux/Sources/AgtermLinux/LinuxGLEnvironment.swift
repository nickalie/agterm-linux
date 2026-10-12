import CGtk
import Foundation

/// libghostty renders through desktop OpenGL only, and GDK creates every `GtkGLArea` context to share the
/// display's, so a display that picked GLES (NVIDIA's EGL default) leaves no pane able to get a context
/// whatever the area allows. GDK reads the switch once, at display init, so it is set before the app runs
/// and put back on activate, before any pane spawns a shell that would inherit it.
enum LinuxGLEnvironment {
    @MainActor private static var userValue: (name: String, value: String?)?

    /// The variable and its new value that keep GDK off GLES, nil when it already is or GTK has no switch.
    static func gdkOverride(gtkMinor: UInt32, environment: [String: String]) -> (name: String, value: String)? {
        guard gtkMinor >= 14 else { return nil }
        let (name, flag) = gtkMinor >= 16 ? ("GDK_DISABLE", "gles-api") : ("GDK_DEBUG", "gl-disable-gles")
        let current = environment[name] ?? ""
        let flags = current.split(whereSeparator: { $0 == "," || $0 == ":" || $0 == " " })
        guard !flags.contains(Substring(flag)) else { return nil }
        return (name, current.isEmpty ? flag : "\(current),\(flag)")
    }

    @MainActor static func preferDesktopGL() {
        let environment = ProcessInfo.processInfo.environment
        guard let (name, value) = gdkOverride(gtkMinor: gtk_get_minor_version(), environment: environment) else { return }
        userValue = (name, environment[name])
        setenv(name, value, 1)
    }

    @MainActor static func restoreUserEnvironment() {
        guard let (name, value) = userValue else { return }
        userValue = nil
        if let value { setenv(name, value, 1) } else { unsetenv(name) }
    }
}
