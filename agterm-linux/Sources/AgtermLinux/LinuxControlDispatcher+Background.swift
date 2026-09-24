import Foundation
import agtermCore

/// `session.background`, mirroring upstream's validation order and error strings.
extension LinuxControlDispatcher {
    static let statusPaneError = "--pane must be left, right, or scratch"

    enum BackgroundSelection {
        case options(ControlSessionBackgroundOptions)
        case rejected(ControlResponse)
    }

    func dispatchSessionBackground(_ request: ControlRequest) -> ControlResponse {
        switch Self.sessionBackgroundOptions(request.args) {
        case .options(let options):
            return actions.setSessionBackground(request.target, window: request.args?.window, options: options)
        case .rejected(let rejection):
            return rejection
        }
    }

    static func sessionBackgroundOptions(_ args: ControlArgs?) -> BackgroundSelection {
        func reject(_ error: String) -> BackgroundSelection { .rejected(ControlResponse(ok: false, error: error)) }
        if let fit = args?.fit, !WatermarkConfig.isValidFit(fit) {
            return reject("invalid fit: \(fit) (contain|cover|stretch|none)")
        }
        if let position = args?.position, !WatermarkConfig.isValidPosition(position) {
            return reject("invalid position: \(position)")
        }
        if let opacity = args?.opacity, !WatermarkConfig.isValidOpacity(opacity) {
            return reject("invalid opacity: \(opacity) (0.0-1.0)")
        }
        let fit = args?.fit.flatMap(BackgroundWatermark.Fit.init(rawValue:))
        let position = args?.position.flatMap(BackgroundWatermark.Position.init(rawValue:))
        let watermark: BackgroundWatermark?
        switch args?.mode {
        case "image":
            guard let path = args?.path, !path.isEmpty else { return reject("session.background image requires a path") }
            guard WatermarkConfig.isValidImagePath(path) else {
                return reject("image path must not contain control characters")
            }
            watermark = BackgroundWatermark(kind: .image, imagePath: path, opacity: args?.opacity, fit: fit,
                                            position: position, repeats: args?.repeats)
        case "text":
            guard let text = args?.text, !text.isEmpty else { return reject("session.background text requires text") }
            guard text.count <= WatermarkConfig.maxTextLength else {
                return reject("session.background text too long (max \(WatermarkConfig.maxTextLength) characters)")
            }
            if let color = args?.color, !WatermarkConfig.isValidColorHex(color) {
                return reject("invalid color: \(color) (#rrggbb)")
            }
            watermark = BackgroundWatermark(kind: .text, text: text, colorHex: args?.color, opacity: args?.opacity,
                                            fit: fit, position: position)
        case "color":
            guard let color = args?.color, !color.isEmpty else { return reject("session.background color requires a color") }
            guard WatermarkConfig.isValidColorHex(color) else { return reject("invalid color: \(color) (#rrggbb)") }
            watermark = BackgroundWatermark(kind: .color, colorHex: color)
        case "clear", .none:
            watermark = nil
        default:
            return reject("invalid background mode: \(args?.mode ?? "") (image|text|color|clear)")
        }
        guard let raw = args?.pane else { return .options(ControlSessionBackgroundOptions(watermark: watermark)) }
        guard let pane = StatusPane(controlName: raw) else { return reject(statusPaneError) }
        return .options(ControlSessionBackgroundOptions(watermark: watermark, pane: pane))
    }
}
