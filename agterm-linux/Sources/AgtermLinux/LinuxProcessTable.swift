import Foundation
import Glibc
import agtermCore

/// LinuxProcessTable is the live process table as `ProcessSweep` reads it, from `/proc/<pid>/stat`.
enum LinuxProcessTable {
    /// read returns every process `/proc` lists, nil when `/proc` cannot be read.
    static func read() -> [ProcessRecord]? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
        return entries.compactMap { entry in
            guard Int32(entry) != nil,
                  let raw = try? String(contentsOfFile: "/proc/\(entry)/stat", encoding: .utf8) else { return nil }
            return record(stat: raw)
        }
    }

    /// record parses one stat line. `started` is field 22, clock ticks since boot, which identifies a pid's
    /// holder as `kp_proc.p_starttime` does on macOS. The scan starts after the LAST `)`, as
    /// `LinuxZmxForeground.parse(stat:)` explains.
    static func record(stat raw: String) -> ProcessRecord? {
        guard let open = raw.firstIndex(of: "("), let close = raw.lastIndex(of: ")"),
              let pid = Int32(raw[..<open].trimmingCharacters(in: .whitespaces)) else { return nil }
        // field 3 (state) is the first after the name, so field n sits at index n - 3
        let fields = raw[raw.index(after: close)...].split(separator: " ")
        guard fields.count > 19, let group = Int32(fields[2]), let foreground = Int32(fields[5]),
              let started = Int64(fields[19]) else { return nil }
        return ProcessRecord(pid: pid, started: started, group: group, foreground: foreground)
    }
}

/// LinuxProcessSweeper hangs up the foreground job a killed daemon's shell leaves running, as closing a
/// terminal would have; upstream's `ProcessSweeper`. Injected into `LinuxZmxClient`, which has none by
/// default: a test's fake listing names pids that are real processes on the machine running it.
struct LinuxProcessSweeper {
    var table: () -> [ProcessRecord]? = LinuxProcessTable.read
    var signal: (Int32, pid_t) -> Void = { _ = kill($1, $0) }

    /// capture returns each shell's foreground job, keyed like `shells`, omitting shells without one.
    func capture(shells: [String: pid_t]) -> [String: [ProcessRecord]] {
        guard let table = table() else { return [:] }
        return shells.mapValues { ProcessSweep.foregroundJob(of: $0, in: table) }.filter { !$0.value.isEmpty }
    }

    /// foregroundJob returns one shell's foreground job, nil when the table cannot be read.
    func foregroundJob(of shell: pid_t) -> [ProcessRecord]? {
        table().map { ProcessSweep.foregroundJob(of: shell, in: $0) }
    }

    /// isRunning is whether any process of `job` still runs; an unreadable table counts as running.
    func isRunning(_ job: [ProcessRecord]) -> Bool {
        guard let table = table() else { return !job.isEmpty }
        return !ProcessSweep.survivors(of: job, in: table).isEmpty
    }

    func send(_ signal: Int32, to job: [ProcessRecord]) {
        guard let table = table() else { return }
        for record in ProcessSweep.survivors(of: job, in: table) { self.signal(signal, record.pid) }
    }
}
