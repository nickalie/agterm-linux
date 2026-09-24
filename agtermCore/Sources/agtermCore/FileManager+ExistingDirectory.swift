import Foundation

extension FileManager {
    /// corelibs-foundation answers an EMPTY listing where Darwin throws when the path is not a directory,
    /// so a caller that must tell "nothing there" from "could not look" checks this first.
    func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
