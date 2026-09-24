import Foundation
import agtermCore

/// The app-global `hooks.conf` runner: one scheduler fed by `WindowLibrary.onControlEvent`, so hooks see
/// exactly what `events.read` sees across every window. macOS keeps this beside `SettingsModel`; Linux has
/// no app-wide model, so the parsed file lives here.
@MainActor var gHooks: LinuxHookController?

@MainActor
final class LinuxHookController {
    let scheduler: HookScheduler
    private(set) var hooks = Hooks()
    private(set) var diagnostics: [KeymapDiagnostic] = []
    private let configDirectory: () -> URL

    init(configDirectory: @escaping () -> URL, launcher: HookLauncher,
         onFailure: @escaping (HookEntry, String) -> Void = { entry, detail in
             NotificationManager.sendHookFailure(kind: entry.kind.rawValue, command: entry.command, detail: detail)
         }) {
        self.configDirectory = configDirectory
        scheduler = HookScheduler(launcher: launcher)
        scheduler.onFailure = onFailure
    }

    var path: String { ConfigPaths.hooksPath(configDirectory: configDirectory()).path }

    func observe(_ library: WindowLibrary) {
        library.onControlEvent = { [scheduler] event in scheduler.dispatch(event) }
    }

    /// Re-read `hooks.conf` and apply it; returns the diagnostic count.
    @discardableResult
    func reload() -> Int {
        let url = ConfigPaths.hooksPath(configDirectory: configDirectory())
        do {
            let parsed = parseHooksConf(try String(contentsOf: url, encoding: .utf8))
            hooks = parsed.hooks
            diagnostics = parsed.diagnostics
        } catch {
            // an existing file that cannot be read must not read as clean, or a reload retires every hook
            hooks = Hooks()
            diagnostics = FileManager.default.fileExists(atPath: url.path)
                ? [KeymapDiagnostic(line: 0, message: "could not read hooks.conf: \(error.localizedDescription)")]
                : []
        }
        scheduler.apply(hooks)
        return diagnostics.count
    }

    /// The commented starter, also written by Edit Hooks after a config-directory change or a manual delete.
    func ensureStarter() {
        let url = ConfigPaths.hooksPath(configDirectory: configDirectory())
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ConfigPaths.starterHooksConf().write(to: url, atomically: true, encoding: .utf8)
    }

    var listing: ControlHooks {
        ControlHooks(path: path,
                     diagnostics: diagnostics.map { ControlKeymapDiagnostic(line: $0.line, message: $0.message) },
                     hooks: scheduler.status)
    }

    static func start(library: WindowLibrary) -> LinuxHookController {
        let controller = LinuxHookController(
            configDirectory: {
                ConfigPaths.configDirectory(setting: linuxSettingsStore().load().configDirectory,
                                            stateDir: ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"],
                                            home: FileManager.default.homeDirectoryForCurrentUser)
            },
            launcher: LinuxHookProcessRunner(socketProvider: {
                gControlServer.boundSocketPath ?? ControlServer.defaultSocketPath()
            }))
        controller.observe(library)
        controller.reload()
        return controller
    }
}

extension LinuxControlDispatcher {
    /// Mirrors upstream `dispatchHooksCommand`: app-global, so a target or `--window` is refused up front.
    func dispatchHooksCommand(_ request: ControlRequest) -> ControlResponse {
        if let refusal = Self.hooksScopeRefusal(request) { return refusal }
        return request.cmd == .hooksReload ? actions.reloadHooks() : actions.listHooks()
    }

    static func hooksScopeRefusal(_ request: ControlRequest) -> ControlResponse? {
        guard request.target != nil || request.args?.window != nil else { return nil }
        return ControlResponse(ok: false, error: "\(request.cmd.rawValue) takes no target or --window")
    }
}

func hooksReloadToast(count: Int) -> String? {
    guard count > 0 else { return nil }
    return "hooks.conf: \(count) issue\(count == 1 ? "" : "s") — see Preferences ▸ Key Mapping"
}

/// The config files an editor overlay was opened on, per window, so its close reloads that file.
enum LinuxEditedConfig {
    case keymap, hooks
}

@MainActor private var editorOverlays: [UUID: [LinuxEditedConfig: UUID]] = [:]

@MainActor
extension AppController {
    func editHooks() {
        guard let id = store.selectedSessionID, let hooks = gHooks else { return }
        hooks.ensureStarter()
        if store.openOverlay(id, command: ConfigPaths.editorCommand(forPath: hooks.path), sizePercent: 95) {
            editorOverlays[windowID, default: [:]][.hooks] = id
        }
        reconcile()
    }

    func noteKeymapEditorOverlay(_ session: UUID) {
        editorOverlays[windowID, default: [:]][.keymap] = session
    }

    /// Menu, palette and editor-close reload: errors toast here, a clean reload stays silent like the keymap's.
    @discardableResult
    func reloadHooksReporting() -> Int {
        let count = gHooks?.reload() ?? 0
        if let message = hooksReloadToast(count: count) { showToast(message) }
        return count
    }

    /// Called from every `reconcile`: an editor overlay that is no longer open reloads the file it edited.
    func reloadClosedEditorOverlays() {
        guard let open = editorOverlays[windowID] else { return }
        for (config, session) in open where store.session(withID: session)?.overlayActive != true {
            editorOverlays[windowID]?[config] = nil
            switch config {
            case .keymap: reloadKeymapAllWindows(reportingIn: self)
            case .hooks: reloadHooksReporting()
            }
        }
    }

    func reloadHooks() -> ControlResponse {
        guard let hooks = gHooks else { return err("hooks are not running") }
        return ControlResponse(ok: true, result: ControlResult(count: hooks.reload()))
    }

    func listHooks() -> ControlResponse {
        guard let hooks = gHooks else { return err("hooks are not running") }
        return ControlResponse(ok: true, result: ControlResult(hooks: hooks.listing))
    }
}
