import Foundation
import agtermCore

/// `session.overlay.open` and the page commands, validated as upstream's `ControlDispatcher+Overlay` does.
@MainActor
extension LinuxControlDispatcher {
    private enum OverlayContent {
        case rejected(ControlResponse)
        case program
        case page(HtmlSource)
    }

    func dispatchOverlayOpen(_ request: ControlRequest) -> ControlResponse {
        let command = request.args?.command ?? ""
        let page: HtmlSource?
        switch Self.overlayContent(command: command, args: request.args) {
        case .rejected(let response): return response
        case .program: page = nil
        case .page(let source): page = source
        }
        if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
            return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
        }
        let openPane: OverlayPane?
        switch parseOverlayPane(request.args?.pane) {
        case .rejected(let response): return response
        case .pane(let parsed): openPane = parsed
        }
        if openPane != nil, request.args?.sizePercent != nil {
            return ControlResponse(ok: false, error: PaneOverlayError.sizePercentConflict)
        }
        return actions.openSessionOverlay(request.target, window: request.args?.window,
                                          options: ControlSessionOverlayOpenOptions(
                                            command: command,
                                            cwd: page == nil ? request.args?.cwd : nil,
                                            wait: request.args?.wait ?? false,
                                            sizePercent: request.args?.sizePercent,
                                            backgroundColor: request.args?.color,
                                            follow: request.args?.follow ?? false,
                                            pane: openPane,
                                            page: page,
                                            navigation: request.args?.navigation ?? false,
                                            javascript: request.args?.javascript ?? false
                                          ))
    }

    func dispatchOverlayPage(_ request: ControlRequest) -> ControlResponse {
        let navigation = request.args?.to.flatMap(HtmlNavigation.init(rawValue:))
        if request.cmd == .sessionOverlayNavigate, navigation == nil {
            return ControlResponse(ok: false, error: OverlayHtmlError.navigation)
        }
        switch parseOverlayPane(request.args?.pane) {
        case .rejected(let response): return response
        case .pane(let pane):
            guard let navigation else {
                return actions.reloadSessionOverlay(request.target, window: request.args?.window, pane: pane,
                                                    current: request.args?.current ?? false)
            }
            return actions.navigateSessionOverlay(request.target, window: request.args?.window, pane: pane,
                                                  navigation: navigation)
        }
    }

    private static func overlayContent(command: String, args: ControlArgs?) -> OverlayContent {
        let reject = { (error: String) in OverlayContent.rejected(ControlResponse(ok: false, error: error)) }
        switch (args?.html, args?.url) {
        case (nil, nil):
            if args?.navigation == true { return reject(OverlayHtmlError.navigationWithoutPage) }
            if args?.javascript == true { return reject(OverlayHtmlError.javascriptWithoutPage) }
            return command.isEmpty ? reject("session.overlay.open requires a command") : .program
        case (.some, .some):
            return reject(OverlayHtmlError.htmlAndURL)
        case (.some(let html), nil):
            if !command.isEmpty { return reject(OverlayHtmlError.commandAndHtml) }
            if args?.wait == true { return reject(OverlayHtmlError.waitWithHtml) }
            if let error = HtmlOverlay.grantError(file: html, grantRoot: args?.cwd) {
                return reject("session.overlay.open: \(error)")
            }
            return .page(.file(path: html, grantRoot: args?.cwd))
        case (nil, .some(let text)):
            if !command.isEmpty { return reject(OverlayHtmlError.commandAndURL) }
            if args?.wait == true { return reject(OverlayHtmlError.waitWithURL) }
            if args?.cwd != nil { return reject(OverlayHtmlError.cwdWithURL) }
            // `HtmlSource.webURL` is internal to the core; a public origin is the same test
            guard let url = URL(string: text), HtmlSource.origin(of: url) != nil else {
                return reject(OverlayHtmlError.invalidURL)
            }
            return .page(.url(url))
        }
    }
}
