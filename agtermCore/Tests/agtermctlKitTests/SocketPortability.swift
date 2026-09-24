import Foundation

/// `SOCK_STREAM` as `socket`/`socketpair` take it: glibc imports it as an enum case, Darwin as an Int32.
#if canImport(Darwin)
let streamSocketType = SOCK_STREAM
#else
let streamSocketType = Int32(SOCK_STREAM.rawValue)
#endif

/// Keeps a write to a closed peer from killing the test process. glibc has no per-socket switch, so the
/// process ignores SIGPIPE there instead.
func suppressSigPipe(_ fd: Int32) {
    #if canImport(Darwin)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    #else
    signal(SIGPIPE, SIG_IGN)
    #endif
}
