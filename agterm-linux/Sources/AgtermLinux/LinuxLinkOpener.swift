import CGtk
import Foundation
import agtermCore

/// LinuxLinkOpener carries out what `LinkPolicy.route` decides for a clicked terminal link, as upstream's
/// `LinkOpener` does. Linux has no portable select-in-file-manager API, so a local file reveal opens its
/// containing directory with the desktop's default file manager.
@MainActor
enum LinuxLinkOpener {
    static func follow(_ raw: String, from surface: GhosttySurface?) {
        let owner = surface.flatMap { surface in
            gWindows.values.first { $0.store.session(withID: surface.sessionID) != nil }
        }
        let origin = surface.map { clickOrigin(of: $0, owner: owner) } ?? .quick
        switch LinkPolicy.route(for: raw, mode: linuxSettingsStore().load().effectiveLinkOpenMode, origin: origin) {
        case .browser(let url): open(url.absoluteString)
        case .overlay(let url, let session):
            if owner?.openLinkOverlay(url, session: session) != true { open(url.absoluteString) }
        case .reveal(let url): open(url.deletingLastPathComponent().absoluteString)
        case .ignore: return
        }
    }

    static func clickOrigin(of surface: GhosttySurface, owner: AppController?) -> LinkPolicy.ClickOrigin {
        switch surface.role {
        case .main, .split: return .pane(surface.sessionID)
        case .scratch: return .scratch(surface.sessionID)
        case .quick: return .quick
        case .overlay:
            guard let owner, let session = owner.store.session(withID: surface.sessionID), session.hudActive,
                  owner.overlaySurfaces[session.id] === surface else { return .programOverlay }
            return .hud
        }
    }

    private static func open(_ uri: String) {
        #if DEBUG
        if let capturePath = ProcessInfo.processInfo.environment["AGTERM_ATSPI_URL_CAPTURE"],
           !capturePath.isEmpty {
            try? uri.write(toFile: capturePath, atomically: true, encoding: .utf8)
        }
        #endif
        uri.withCString { _ = g_app_info_launch_default_for_uri($0, nil, nil) }
    }
}

@MainActor
extension AppController {
    /// Opens a clicked link as a browsing page over its session, false to send it to the browser instead. A
    /// HUD and a zoomed terminal come first: the store would accept those opens, and one closes the HUD for
    /// good while the other shows nothing.
    func openLinkOverlay(_ url: URL, session id: UUID) -> Bool {
        guard let session = store.session(withID: id), !session.hudActive, terminalZoom.target == nil else {
            return false
        }
        let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: nil,
                                                       backgroundColor: nil, page: .url(url), navigation: true,
                                                       javascript: true, persistent: true, browse: true)
        return openSessionOverlay(id.uuidString, window: nil, options: options).ok
    }
}
