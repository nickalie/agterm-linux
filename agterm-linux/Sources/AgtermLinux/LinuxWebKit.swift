import CGtk
import Foundation

/// LinuxWebKit loads libagterm-webkit.so, the one library linked against WebKitGTK 6.0, on the first HTML
/// overlay. The app itself never links WebKitGTK, so it runs without it and refuses only those overlays.
@MainActor
enum LinuxWebKit {
    static let pluginName = "libagterm-webkit.so"
    static let missingMessage = "html overlays need WebKitGTK 6.0: install libwebkitgtk-6.0-4 (Debian, Ubuntu), "
        + "webkitgtk6.0 (Fedora) or webkitgtk-6.0 (Arch) and restart agterm"

    private static var loaded: Result<UnsafePointer<agterm_webkit_api>, LoadFailure>?

    struct LoadFailure: Error, Equatable {
        let message: String
    }

    /// api is the plugin's function table, loaded once; a failure is remembered for the process.
    static func api() -> Result<UnsafePointer<agterm_webkit_api>, LoadFailure> {
        if let loaded { return loaded }
        let result = load(candidates: candidates())
        loaded = result
        return result
    }

    /// candidates are the launcher's `AGTERM_WEBKIT_PLUGIN`, then the library beside this executable (a
    /// source build) and the payload's `lib/agterm`.
    static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment,
                           executable: String = CommandLine.arguments.first ?? "") -> [String] {
        let directory = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        var paths = [directory.appendingPathComponent(pluginName).path,
                     directory.deletingLastPathComponent().appendingPathComponent("lib/agterm/\(pluginName)").path]
        if let override = environment["AGTERM_WEBKIT_PLUGIN"], !override.isEmpty { paths.insert(override, at: 0) }
        return paths
    }

    /// answer resolves a page request whose page is gone; the reply still has to be freed.
    static func answer(_ reply: UnsafeMutableRawPointer?, _ result: String?, _ error: String?) {
        guard case .success(let api)? = loaded else { return }
        api.pointee.answer(reply, result, error)
    }

    static func load(candidates: [String]) -> Result<UnsafePointer<agterm_webkit_api>, LoadFailure> {
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return .failure(LoadFailure(message: "html overlays are not available in this build"))
        }
        // RTLD_LOCAL keeps WebKit's symbols out of the app's namespace
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? path
            return .failure(LoadFailure(message: reason.contains("webkitgtk") ? missingMessage : reason))
        }
        guard let symbol = dlsym(handle, AGTERM_WEBKIT_ENTRY) else {
            return .failure(LoadFailure(message: "\(path) has no \(AGTERM_WEBKIT_ENTRY)"))
        }
        let entry = unsafeBitCast(symbol, to: agterm_webkit_entry.self)
        guard let api = entry(), api.pointee.abi == UInt32(AGTERM_WEBKIT_ABI) else {
            return .failure(LoadFailure(message: "\(path) does not match this agterm"))
        }
        return .success(api)
    }
}
