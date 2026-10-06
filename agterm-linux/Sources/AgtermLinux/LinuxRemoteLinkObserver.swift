import CGtk
import Foundation

/// Retries remote links when the machine resumes from sleep or the network becomes available, the Linux
/// counterpart of upstream's `RemoteLinkObserver`; `control-api.md` says when and why. Resume is logind's
/// `PrepareForSleep(false)` on the system bus, which a session without one simply never reports.
@MainActor
final class LinuxRemoteLinkObserver {
    private var onRetry: (@MainActor () -> Void)?
    private var started = false

    /// Idempotent: every remote feature that engages the presentation service calls it.
    func start(_ onRetry: @escaping @MainActor () -> Void) {
        self.onRetry = onRetry
        guard !started else { return }
        started = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let monitor = g_network_monitor_get_default() {
            connect(monitor, "network-changed",
                    unsafeBitCast(onNetworkChanged as @convention(c) (OpaquePointer?, gboolean, gpointer?) -> Void,
                                  to: GCallback.self), context)
        }
        var error: UnsafeMutablePointer<GError>?
        guard let bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nil, &error) else {
            g_clear_error(&error)
            return
        }
        _ = g_dbus_connection_signal_subscribe(
            bus, "org.freedesktop.login1", "org.freedesktop.login1.Manager", "PrepareForSleep",
            "/org/freedesktop/login1", nil, G_DBUS_SIGNAL_FLAGS_NONE, onPrepareForSleep, context, nil)
    }

    fileprivate func retry() { onRetry?() }
}

private let onNetworkChanged: @convention(c) (OpaquePointer?, gboolean, gpointer?) -> Void = { _, available, data in
    guard available != 0 else { return }
    retry(UInt(bitPattern: data))
}

// the bus delivers on the thread-default context of the subscribing thread, the GTK main loop here
private let onPrepareForSleep: GDBusSignalCallback = { _, _, _, _, _, parameters, data in
    guard let parameters, let data, g_variant_n_children(parameters) == 1 else { return }
    let child = g_variant_get_child_value(parameters, 0)
    defer { g_variant_unref(child) }
    // true announces the sleep, false the resume
    guard g_variant_get_boolean(child) == 0 else { return }
    retry(UInt(bitPattern: data))
}

private func retry(_ observer: UInt) {
    guard let pointer = UnsafeRawPointer(bitPattern: observer) else { return }
    MainActor.assumeIsolated { Unmanaged<LinuxRemoteLinkObserver>.fromOpaque(pointer).takeUnretainedValue().retry() }
}
