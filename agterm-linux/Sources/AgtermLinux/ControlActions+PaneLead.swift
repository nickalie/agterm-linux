import Foundation
import agtermCore

/// Reads and scripted typing for a pane whose zmx client takes part in explicit leadership. A pane that does
/// not lead holds output laid out for another client's grid, and the daemon drops what it types, so screen
/// text and the cursor come from the daemon's terminal and typing goes through the daemon's acknowledged path.
///
/// The role the app holds is a REPORT, a main-loop hop and up to 250 ms behind the daemon, so it never decides
/// delivery: a local managed pane always types and reads its cursor through the daemon.
enum PaneLeadSource: Equatable {
    /// The pane's zmx never reported a role, or the read is of the viewport of a pane that leads.
    case surface
    case daemon(String)
    case refused(String)

    /// The strings are protocol text shared with macOS peers, verbatim.
    static let coveredRefusal = "pane is covered while another Mac leads it; take the lead first (session lead)"
    static let remoteRefusal = "pane is in use on the Mac it runs on; take the lead to drive it from here"

    /// `viewport` is a default `session.text`: the one read whose meaning is the pane's own scrolled view,
    /// kept on the surface while the pane leads. `daemon` is nil for a pane whose daemon is on another machine.
    static func resolve(covered: Bool, role: ZmxLeadRole?, daemon: String?, viewport: Bool = false) -> PaneLeadSource {
        guard covered || role != nil else { return .surface }
        guard let daemon else { return covered ? .refused(remoteRefusal) : .surface }
        return !covered && viewport ? .surface : .daemon(daemon)
    }
}

@MainActor
extension AppController {
    func paneLeadSource(_ surface: GhosttySurface, viewport: Bool = false) -> PaneLeadSource {
        let daemon = gZmx?.client.isAvailable == true ? surface.zmxDaemonName : nil
        return PaneLeadSource.resolve(covered: surface.leadCovered,
                                      role: ZmxLeadBook.shared.role(pane: surface.leadPaneIdentity),
                                      daemon: daemon, viewport: viewport)
    }

    /// The refusal for a command acting on the pane's OWN surface — paste, select-all, copy and an opening
    /// or navigating search — which on a covered pane holds output laid out for another grid.
    func coveredRefusal(_ surface: GhosttySurface?) -> ControlResponse? {
        guard let surface, surface.leadCovered else { return nil }
        return err(PaneLeadSource.coveredRefusal)
    }

    /// The search refusal, judged on the PINNED owner when a search is open on this session, else on
    /// `fallback`, the pane an open would land on. Close stays available as cleanup.
    func searchLeadRefusal(_ id: UUID, fallback: GhosttySurface?) -> ControlResponse? {
        coveredRefusal(searchSurface?.sessionID == id ? searchSurface : fallback)
    }

    /// `session.lead`: what a key press on the pane's cover does. A pane that already leads answers ok, so a
    /// caller can ask without reading `lead` first; one whose zmx never reported a role has no lead to take.
    func takeSessionLead(_ target: String?, window: String?, pane: StatusPane?) -> ControlResponse {
        guard pane != .scratch else { return err("the scratch terminal has no lead") }
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if pane == .right, splitSurfaces[id] == nil { return err("session has no split pane") }
            guard let surface = pane == .right ? splitSurfaces[id] : surfaces[id],
                  let identity = surface.leadPaneIdentity else { return err("session not realized") }
            let book = ZmxLeadBook.shared
            guard book.role(pane: identity) != nil || surface.leadCovered else { return err("pane has no lead to take") }
            if surface.leadCovered, !book.reattaching(pane: identity) { reattachPane(surface, claim: true) }
            return ok(id)
        }
    }

    /// `session.text` answered by the daemon, nil when the pane's own surface is the source.
    func coveredText(_ surface: GhosttySurface, all: Bool, lines: Int?) -> ControlResponse? {
        switch paneLeadSource(surface, viewport: !all && lines == nil) {
        case .surface: return nil
        case .refused(let reason): return err(reason)
        case .daemon(let name):
            guard let screen = gZmx.client.screen(name: name, all: all || lines != nil) else {
                return err("failed to read surface buffer")
            }
            return ControlResponse(ok: true, result: ControlResult(text: lines.map(screen.lastLines) ?? screen.text))
        }
    }

    /// `surface.cursor` answered by the daemon, nil when the pane's own surface is the source.
    func coveredCursor(_ surface: GhosttySurface, controlID: String) -> ControlResponse? {
        switch paneLeadSource(surface) {
        case .surface: return nil
        case .refused(let reason): return err(reason)
        case .daemon(let name):
            guard let screen = gZmx.client.screen(name: name, all: false) else {
                return err("failed to read cursor position")
            }
            return ControlResponse(ok: true, result: ControlResult(id: controlID,
                                                                   cursor: ControlCursor(column: screen.cursorColumn)))
        }
    }

    /// `session.type` through the daemon, nil when the pane's own surface takes it.
    func coveredType(_ text: String, into surface: GhosttySurface, session id: UUID, pane: StatusPane) -> ControlResponse? {
        switch paneLeadSource(surface) {
        case .surface: return nil
        case .refused(let reason): return err(reason)
        case .daemon(let name):
            // a half-typed composition goes first and on the same acknowledged path: left in place it would
            // commit after the scripted line, and committed through the surface the daemon may drop it
            let bytes = KeystrokeSegments.ptyBytes(surface.pendingComposition + text)
            guard bytes.isEmpty || gZmx.client.type(name: name, bytes: bytes) else {
                return err("the pane's zmx daemon did not accept the input")
            }
            surface.discardComposition()
            if !text.isEmpty {
                applyKeystrokeToStatus(id, pane: pane, keystroke: InterruptKeystroke.classify(text: text))
            }
            return ok(id)
        }
    }
}
