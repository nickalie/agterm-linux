import CGtk
import Foundation
import agtermCore

/// The first-launch pointer at the optional integrations, shown once per install. The due-decision and the
/// title come from host-free `agtermCore.FirstRunWelcome`; the body is Linux-specific because upstream's
/// names the macOS Help menu, while the Linux equivalents live in Preferences ▸ Integrations.
///
/// Each button hands off to the normal integration flow (`prepareIntegration`), which previews the exact
/// file plan before touching anything — so the welcome never installs behind the user's back, unlike the
/// macOS alert whose checkboxes run the installers directly.
@MainActor
enum WelcomeDialog {
    private static var presented = false

    static let body = """
    agterm ships optional integrations. None is needed to use it as a terminal, and you can install any of \
    them later from Preferences ▸ Integrations.

    The agent skill teaches Claude Code and Codex to drive agterm over its control socket.

    The agent status hooks make an agent session report active, blocked or completed in the sidebar.

    The command line tool puts agtermctl on your PATH; a DEB or RPM install already has it.
    """

    /// Whether this launch should show the welcome. Must be read BEFORE the app writes any state, since a
    /// first launch seeds a session and saves its window within a second of the window appearing.
    static func isDue(stateDirectory: URL, settings: AppSettings) -> Bool {
        FirstRunWelcome.isDue(welcomeShown: settings.welcomeShown,
                              hasPriorState: FirstRunWelcome.hasPriorState(in: stateDirectory))
    }

    /// Show it once per process, marking it shown before any installer runs so a cancelled or failed
    /// install cannot bring it back on the next launch.
    static func presentOnce(in controller: AppController) {
        guard !presented else { return }
        presented = true
        controller.setWelcomeShown(true)
        controller.presentWelcomeDialog()
    }
}

@MainActor
extension AppController {
    func setWelcomeShown(_ shown: Bool) {
        persist(\.welcomeShown, shown ? true : nil)
    }

    func presentWelcomeDialog() {
        let dialog = OpaquePointer(FirstRunWelcome.title.withCString { h in
            WelcomeDialog.body.withCString { b in adw_alert_dialog_new(h, b) }
        })
        attachControllerContext(to: dialog, windowID: windowID)
        "later".withCString { i in "Later".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "hooks".withCString { i in
            FirstRunWelcome.hooksOption.withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) }
        }
        "skill".withCString { i in
            FirstRunWelcome.skillOption.withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) }
        }
        "skill".withCString { adw_alert_dialog_set_response_appearance(cast(dialog), $0, ADW_RESPONSE_SUGGESTED) }
        "later".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        connect(dialog, "response", unsafeBitCast(onWelcomeResponse as @convention(c)
            (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self))
        adw_dialog_present(cast(dialog), W(window))
    }

    func respondToWelcome(_ response: String) {
        switch response {
        case "skill": prepareIntegration(.skill)
        case "hooks": prepareIntegration(.hooks)
        default: break
        }
    }
}

private let onWelcomeResponse: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { dialog, response, _ in
    MainActor.assumeIsolated {
        guard let response else { return }
        controllerForWidget(dialog)?.respondToWelcome(String(cString: response))
    }
}
