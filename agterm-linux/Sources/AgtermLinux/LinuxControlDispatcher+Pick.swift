import Foundation
import agtermCore

/// A caller input the Linux dispatcher refuses, carrying the exact upstream error text.
struct LinuxControlRefusal: Error, Equatable {
    let message: String
}

/// `pick.*`, mirroring `agtermCore`'s internal `ControlDispatcher+Pick` so the Linux server refuses the same
/// inputs with the same words.
extension LinuxControlDispatcher {
    func dispatchPickCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .pickOpen:
            switch Self.pendingPick(from: request.args) {
            case .failure(let refusal):
                return ControlResponse(ok: false, error: refusal.message)
            case .success(let pick):
                return actions.openPick(pick, window: request.args?.window, follow: request.args?.follow == true)
            }
        case .pickResult:
            guard let target = request.target else {
                return ControlResponse(ok: false, error: "pick.result requires a pick id")
            }
            return actions.pickResult(target, window: request.args?.window)
        case .pickCancel:
            guard let target = request.target else {
                return ControlResponse(ok: false, error: "pick.cancel requires a pick id")
            }
            return actions.cancelPick(target, window: request.args?.window)
        default:
            preconditionFailure("unexpected pick command: \(request.cmd.rawValue)")
        }
    }

    static func pendingPick(from args: ControlArgs?, id: String = UUID().uuidString)
        -> Result<PendingPick, LinuxControlRefusal> {
        guard let items = args?.items else { return .failure(.init(message: "pick.open requires items")) }
        let allowCustom = args?.allowCustom == true
        // an empty list is a text prompt, which only makes sense when a custom answer is accepted
        guard !items.isEmpty || allowCustom else {
            return .failure(.init(message: "pick.open requires at least one item"))
        }
        guard items.count <= ControlPickItem.maxItems else {
            return .failure(.init(message: "too many items (max \(ControlPickItem.maxItems))"))
        }
        guard items.allSatisfy({ !$0.label.isEmpty }) else {
            return .failure(.init(message: "pick item label must not be empty"))
        }
        var ids = Set<String>()
        guard items.allSatisfy({ ids.insert($0.id).inserted }) else {
            return .failure(.init(message: "pick item ids must be unique"))
        }
        guard items.allSatisfy({
            !containsControlCharacters($0.label) && $0.subtitle.map { !containsControlCharacters($0) } != false
        }) else {
            return .failure(.init(message: "item text must not contain control characters"))
        }
        // checked against the caller's items, not the rows a `query` prefill leaves visible
        let selection = args?.selection
        if let selection, !items.contains(where: { $0.id == selection }) {
            return .failure(.init(message: "pick select must name an item id"))
        }
        return .success(PendingPick(id: id, items: items, prompt: args?.prompt, query: args?.query,
                                    allowCustom: allowCustom, selection: selection))
    }
}
