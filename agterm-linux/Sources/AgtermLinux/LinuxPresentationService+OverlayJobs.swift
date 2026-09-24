import Foundation
import agtermCore

/// One helper's connection to a claimed remote overlay job. The origin speaks first, with the launch
/// context; the helper reports `started` and one terminal outcome, and the origin can send `cancel`. The
/// helper runs on this machine, so its process dying closes the socket, which ends a job whose helper went.
@MainActor
final class LinuxOverlayJobStream {
    let job: String
    private let owner: ControlStreamOwner
    private weak var service: LinuxPresentationService?

    init(job: String, owner: ControlStreamOwner, service: LinuxPresentationService) {
        self.job = job
        self.owner = owner
        self.service = service
    }

    func send(_ frame: OverlayJobFrame) {
        guard let line = try? frame.line(), owner.send(line) else {
            owner.shutdown()
            return
        }
    }

    func receive(_ line: Data) {
        guard let jobs = service?.overlayJobs else { return }
        guard let frame = try? JSONDecoder().decode(OverlayJobFrame.self, from: line) else {
            owner.shutdown()
            return
        }
        switch frame {
        case .started: jobs.started(job)
        case .exited(let code): _ = jobs.finish(job, .exited(code))
        case .canceled: _ = jobs.finish(job, .canceled)
        case .launchFailed: _ = jobs.finish(job, .launchFailed)
        case .context, .cancel: owner.shutdown()
        }
    }

    func shutdown() { owner.shutdown() }

    func closed() {
        service?.overlayJobs.helperGone(job)
        if service?.jobStreams[job] === self { service?.jobStreams[job] = nil }
    }
}

private final class WeakJobStream: @unchecked Sendable {
    weak var stream: LinuxOverlayJobStream?
    init(_ stream: LinuxOverlayJobStream) { self.stream = stream }
}

// MARK: - Origin: overlays handed to a presenter

extension LinuxPresentationService {
    /// Answers `session.overlay.job.run`: the request is the claim, so an ok here is the one winner of the
    /// race against the job's launch deadline. Validation mirrors `ControlDispatcher+Overlay`.
    func claimOverlayJob(_ target: String?) -> ControlResponse {
        guard let job = target?.trimmingCharacters(in: .whitespacesAndNewlines), !job.isEmpty else {
            return ControlResponse(ok: false, error: "session.overlay.job.run requires a job id")
        }
        guard UUID(uuidString: job) != nil else { return ControlResponse(ok: false, error: "invalid job id") }
        attach()
        let claimed = overlayJobs.claim(job) { [weak self] in self?.cancelJobHelper(job) }
        guard claimed != nil else { return ControlResponse(ok: false, error: "job not claimable") }
        scheduleOverlayJobExpiry(after: OverlayJobs.startWindow)
        return ControlResponse(ok: true, result: ControlResult(id: job))
    }

    /// Takes over the connection of a job whose claim was just answered ok, and sends its launch context.
    func adoptOverlayJobStream(descriptor: Int32, job: String) {
        let owner = ControlStreamOwner(descriptor: descriptor, limits: Self.overlayJobLimits)
        let stream = LinuxOverlayJobStream(job: job, owner: owner, service: self)
        jobStreams[job] = stream
        let box = WeakJobStream(stream)
        owner.start(
            onLine: { line in runOnMain { MainActor.assumeIsolated { box.stream?.receive(line) } } },
            onClose: { runOnMain { MainActor.assumeIsolated { box.stream?.closed() } } })
        // a job that ended between its claim and this adoption must not launch, its queued cancel gone with it
        guard let claimed = overlayJobs.job(job), case .claimed = claimed.state else {
            stream.shutdown()
            return
        }
        stream.send(.context(claimed.context))
        if pendingJobCancels.remove(job) != nil { stream.send(.cancel) }
    }

    /// Reaches a claimed job's helper. A cancel that arrives before its connection is adopted is held for it.
    func cancelJobHelper(_ job: String) {
        guard let stream = jobStreams[job] else {
            pendingJobCancels.insert(job)
            return
        }
        stream.send(.cancel)
    }

    /// Hands an overlay to the viewer presenting the session; nil when none does, so the caller opens it
    /// here. The launch context is built as a local overlay's would be, from this machine's session.
    func openRemoteOverlay(in store: AppStore, sessionID: UUID, options: ControlSessionOverlayOpenOptions) -> ControlResponse? {
        guard let session = store.session(withID: sessionID) else { return nil }
        attach()
        let context = OverlayLaunchContext(
            command: options.command,
            cwd: OverlayLaunchContext.cwd(explicit: options.cwd, session: session, homeDirectory: AppController.homeCwd),
            sessionEnvironment: host.sessionEnvironment(for: session, in: store))
        switch store.openRemoteOverlay(sessionID, options: options, context: context) {
        case .notPresented:
            return nil
        case .slotTaken:
            return ControlResponse(ok: false, error: options.pane == nil ? "overlay already open" : PaneOverlayError.alreadyOpen)
        case .paneMissing:
            return ControlResponse(ok: false, error: PaneOverlayError.paneNotVisible)
        case .tooLarge:
            return ControlResponse(ok: false, error: OverlayResultError.tooLarge)
        case .opened:
            scheduleOverlayJobExpiry(after: OverlayJobs.launchWindow)
            changed(sessionID, .deck)
            return ControlResponse(ok: true, result: ControlResult(id: sessionID.uuidString))
        }
    }

    /// Runs the table's expiry once `seconds` have passed, which ends whatever deadline fell in between.
    func scheduleOverlayJobExpiry(after seconds: TimeInterval) {
        schedule(seconds + 0.1) { [weak self] in self?.overlayJobs.expire() }
    }
}
