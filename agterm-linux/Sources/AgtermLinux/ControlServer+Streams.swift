import Foundation
import agtermCore

/// The two streaming hand-offs, `zmx.present` and `session.overlay.job.run`: each is dispatched on the GTK
/// thread, its ordinary reply is written, and on ok the descriptor passes to a `ControlStreamOwner` whose
/// reader thread is the only one that closes it. The accept thread goes straight back to accepting.
extension ControlServer {
    static func streams(_ cmd: Command) -> Bool {
        cmd == .zmxPresent || cmd == .sessionOverlayJobRun
    }

    /// False: the connection now belongs to a stream owner, or was closed by it.
    func handleStream(_ conn: Int32, _ req: ControlRequest) -> Bool {
        let presents = req.cmd == .zmxPresent
        let response = onMainSync { service in
            presents ? service.openPresentation(session: req.target) : service.claimOverlayJob(req.target)
        }
        let written = respond(conn, response)
        guard response.ok, let id = response.result?.id else { return true }
        if presents {
            guard written, let session = UUID(uuidString: id) else { return true }
            _ = onMainSync { service in
                service.adoptPresentationStream(descriptor: conn, session: session)
                return ControlResponse(ok: true)
            }
            return false
        }
        // a claim whose reply never reached the helper leaves nobody to run the job
        guard written else {
            _ = onMainSync { service in
                service.overlayJobs.helperGone(id)
                return ControlResponse(ok: true)
            }
            return true
        }
        _ = onMainSync { service in
            service.adoptOverlayJobStream(descriptor: conn, job: id)
            return ControlResponse(ok: true)
        }
        return false
    }

    private func onMainSync(_ body: @escaping @MainActor (LinuxPresentationService) -> ControlResponse) -> ControlResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        runOnMain { [self] in
            MainActor.assumeIsolated {
                box.value = body(presentation ?? gPresentation)
                semaphore.signal()
            }
        }
        semaphore.wait()
        return box.value
    }
}
