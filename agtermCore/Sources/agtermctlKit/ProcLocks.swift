#if canImport(Glibc)
import Glibc
import Foundation

/// Reads `/proc/locks`, whose entries read `N: FLOCK ADVISORY WRITE pid MAJ:MIN:INODE start end` with the
/// device numbers in hex. A blocked waiter's entry carries `->` after the ordinal, so it never matches.
enum ProcLocks {
    static func flockHeld(path: String) -> Bool? {
        var info = stat()
        guard stat(path, &info) == 0,
              let table = try? String(contentsOfFile: "/proc/locks", encoding: .utf8) else { return nil }
        // glibc's gnu_dev_major/gnu_dev_minor, which Swift does not import
        let dev = UInt64(info.st_dev)
        let major = ((dev >> 8) & 0xfff) | ((dev >> 32) & ~UInt64(0xfff))
        let minor = (dev & 0xff) | ((dev >> 12) & ~UInt64(0xff))
        let key = String(format: "%02llx:%02llx:%llu", major, minor, UInt64(info.st_ino))
        return table.split(separator: "\n").contains { line in
            let fields = line.split(separator: " ")
            return fields.count > 5 && fields[1] == "FLOCK" && fields[5] == key
        }
    }
}
#endif
