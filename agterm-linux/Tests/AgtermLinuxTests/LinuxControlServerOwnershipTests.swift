import Foundation
import Glibc
import Testing
import agtermCore
@testable import AgtermLinux

@Suite(.serialized)
struct LinuxControlServerOwnershipTests {
    private let path = "/tmp/agt-own-\(UUID().uuidString.prefix(8)).sock"

    private func cleanUp() {
        unlink(path)
        unlink(ControlResolve.ownershipLockPath(forSocket: path))
    }

    @Test func aSecondInstanceRefusesToBindAndAdvertisesTheUnavailablePath() {
        defer { cleanUp() }
        let owner = ControlServer(path: path)
        owner.start()
        defer { owner.stop() }
        let second = ControlServer(path: path)
        second.start()
        defer { second.stop() }

        #expect(owner.boundSocketPath == path)
        #expect(owner.resolvedSocketPath == path)
        #expect(second.refused)
        #expect(second.boundSocketPath == nil)
        #expect(second.resolvedSocketPath == path + ".unavailable")
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func stoppingTheOwnerLetsARefusedInstanceTakeThePathOver() {
        defer { cleanUp() }
        let owner = ControlServer(path: path)
        owner.start()
        let second = ControlServer(path: path)
        #expect(second.refused)

        owner.stop()
        second.start()
        defer { second.stop() }

        #expect(!second.refused)
        #expect(second.boundSocketPath == path)
        #expect(second.resolvedSocketPath == path)
    }

    @Test func theLockIsReleasedWhenTheOwningProcessExits() throws {
        defer { cleanUp() }
        let lockPath = ControlResolve.ownershipLockPath(forSocket: path)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/flock")
        holder.arguments = ["-o", lockPath, "sleep", "10"]
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        try #require(waitUntilLocked(lockPath))

        let server = ControlServer(path: path)
        server.start()
        defer { server.stop() }
        #expect(server.boundSocketPath == nil)

        kill(holder.processIdentifier, SIGKILL)
        let deadline = Date().addingTimeInterval(5)
        while server.boundSocketPath == nil, Date() < deadline {
            usleep(20_000)
            server.start()
        }

        #expect(server.boundSocketPath == path)
        #expect(server.resolvedSocketPath == path)
    }

    private func waitUntilLocked(_ lockPath: String) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let fd = open(lockPath, O_RDWR | O_CLOEXEC)
            if fd >= 0 {
                let acquired = flock(fd, LOCK_EX | LOCK_NB) == 0
                close(fd)
                if !acquired { return true }
            }
            usleep(20_000)
        }
        return false
    }
}
