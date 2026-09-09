import Foundation
import agtermCore

extension AppStore {
    func setPaneFocus(_ toSplit: Bool, forSession sessionID: UUID) {
        guard let session = session(withID: sessionID), session.hasSplit else { return }
        if session.splitFocused != toSplit { session.splitFocused = toSplit }
    }

    @discardableResult
    func recordPwd(_ pwd: String, forSession sessionID: UUID, isSplit: Bool) -> Bool {
        guard let session = session(withID: sessionID) else { return false }
        if isSplit {
            guard session.splitCwd != pwd else { return false }
            session.splitCwd = pwd
        } else if session.currentCwd != pwd {
            session.currentCwd = pwd
        } else {
            return false
        }
        return true
    }

    /// Records an OSC 2 title, dropping one equal to the pane's own working directory.
    ///
    /// libghostty answers an OSC 7 with a synthetic title equal to that directory, and its PWD action does
    /// not reliably reach `recordPwd` before the title, so no arming handshake catches it. A shell titles
    /// with a basename or an abbreviated path, never the bare absolute cwd. Live restore is what made a
    /// wrong title stick rather than flicker: a reattached shell draws no new prompt, so nothing writes a
    /// real title over it. Residual: between a `cd` and its OSC 7 the compared cwd is still the old one, so
    /// a synthetic title naming the NEW directory is accepted.
    @discardableResult
    func recordTitle(_ title: String, forSession sessionID: UUID, isSplit: Bool) -> Bool {
        guard let session = session(withID: sessionID) else { return false }
        if title == (isSplit ? session.cwd(for: .right) : session.effectiveCwd) { return false }
        if isSplit {
            guard session.splitTitle != title else { return false }
            session.splitTitle = title
        } else if session.oscTitle != title {
            session.oscTitle = title
        } else {
            return false
        }
        return true
    }
}
