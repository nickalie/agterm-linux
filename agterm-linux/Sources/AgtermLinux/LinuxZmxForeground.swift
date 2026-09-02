import Foundation
import agtermCore

/// Maps a wrapped pane's stable daemon name to the process holding its pty's foreground group. The pane's
/// own `ghostty_surface_foreground_pid` sees the ATTACH CLIENT, so without this every live pane would
/// report `zmx attach …` as its foreground and the restore capture would pin that.
///
/// One bounded `zmx list` refresh populates every pane; a per-pane lookup is then a dictionary hit plus
/// one `/proc` read.
@MainActor
final class LinuxZmxForegroundResolver {
    enum LeaderProbe: Equatable {
        case foreground(Int32)
        case noForeground
        case dead
    }

    typealias LeaderProvider = (TimeInterval?) -> [String: Int32]?
    typealias Probe = (Int32) -> LeaderProbe

    struct Snapshot {
        let leaders: [String: Int32]
        let leaderProbe: Probe

        func foregroundPID(sessionName: String) -> Int32? {
            guard let leader = leaders[sessionName], case .foreground(let pid) = leaderProbe(leader) else {
                return nil
            }
            return pid
        }
    }

    private let leaderProvider: LeaderProvider
    private let leaderProbe: Probe
    private var leaders: [String: Int32] = [:]
    private var refreshGate = ZmxRefreshGate()

    init(leaderProvider: @escaping LeaderProvider,
         leaderProbe: @escaping Probe = LinuxZmxForegroundResolver.probe) {
        self.leaderProvider = leaderProvider
        self.leaderProbe = leaderProbe
    }

    func noteLifecycleChange() { refreshGate.noteLifecycleChange() }

    func refreshIfNeeded(now: Date = Date()) {
        guard refreshGate.shouldRefresh(now: now), let refreshed = leaderProvider(nil) else { return }
        leaders = refreshed
    }

    func freshSnapshot(timeout: TimeInterval) -> Snapshot? {
        leaderProvider(timeout).map { Snapshot(leaders: $0, leaderProbe: leaderProbe) }
    }

    func foregroundPID(sessionName: String) -> Int32? {
        guard let leader = leaders[sessionName] else {
            refreshGate.noteLifecycleChange()
            return nil
        }
        switch leaderProbe(leader) {
        case .foreground(let pid): return pid
        case .noForeground: return nil
        case .dead:
            leaders[sessionName] = nil
            refreshGate.noteLifecycleChange()
            return nil
        }
    }

    /// `/proc/<pid>/stat` field 8 is the pty's foreground process group — the Linux answer to macOS's
    /// `kinfo_proc.kp_eproc.e_tpgid`.
    nonisolated static func probe(_ leader: Int32) -> LeaderProbe {
        guard let raw = try? String(contentsOfFile: "/proc/\(leader)/stat", encoding: .utf8) else {
            return .dead
        }
        return parse(stat: raw)
    }

    /// The scan starts after the LAST `)`: field 2 is the executable name in parentheses and may contain
    /// both spaces and parentheses of its own, so splitting from the front misreads every such process.
    nonisolated static func parse(stat raw: String) -> LeaderProbe {
        guard let close = raw.lastIndex(of: ")") else { return .dead }
        // after the name come state, ppid, pgrp, session, tty_nr, tpgid
        let fields = raw[raw.index(after: close)...].split(separator: " ")
        guard fields.count >= 6, let foreground = Int32(fields[5]) else { return .dead }
        return foreground > 0 ? .foreground(foreground) : .noForeground
    }
}
