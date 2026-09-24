import Foundation
import agtermCore

/// What a presentation effect changed, so the host repaints only that part of the window.
enum LinuxPresentationChange {
    case sidebar, title, asks, deck
}

/// The GTK side of remote presentation. The service keeps the protocol, the model and the threads; this is
/// what only a window can do. Production is `LinuxPresentationAppHost`; a test supplies its own.
@MainActor
protocol LinuxPresentationHost: AnyObject {
    var library: WindowLibrary? { get }
    /// What a program started for `session` sees on this machine, the variables a local overlay gets.
    func sessionEnvironment(for session: Session, in store: AppStore) -> [String: String]
    func openMirroredHud(_ spec: HudSpec, pane: OverlayPane?, sessionID: UUID) -> ControlResponse
    func updateMirroredHud(_ spec: HudSpec, pane: OverlayPane?, sessionID: UUID) -> ControlResponse
    /// Whether `sessionID` is on screen for a GUI ask: selected, with no zoom target and no dashboard over it.
    func guiTargetShown(_ sessionID: UUID, in store: AppStore) -> Bool
    /// Moves a taken-back GUI ask into its window's modal slot. False when the slot is held by a pick.
    func openTakenBackGuiAsk(_ ask: PendingAsk, session: Session, in store: AppStore) -> Bool
    func deliverMirroredNotification(_ notify: PresentationNotify, sessionID: UUID, in store: AppStore)
    /// Exchanges a realized pair's panes in the model and the widgets, as `session.swap` does.
    func swapRemotePanes(_ sessionID: UUID, in store: AppStore) -> Bool
    /// Closes a replica the origin removed, once `AppStore.canCloseRemovedRemotePane` allows it.
    func closeRemovedRemotePane(_ local: UUID, sessionID: UUID, in store: AppStore)
    func presentationChanged(_ sessionID: UUID, in store: AppStore, _ change: LinuxPresentationChange)
}

/// Remote presentation on Linux, both roles in one object: this app as the ORIGIN of attached sessions,
/// serving `zmx.present` and `session.overlay.job.run` streams through the hub, and as a VIEWER running one
/// `RemotePresentationClient` per attached row. The macOS twins are the `ControlServer+Presentation`,
/// `+RemotePresentation`, `+OverlayJobs` and `+Ask` extensions; the contract is `control-api.md`'s Remote
/// sessions section.
@MainActor
final class LinuxPresentationService {
    static let presentationLimits = ControlStreamOwner.Limits(maxLineBytes: PresentationCodec.maxFrameBytes,
                                                              maxPendingLines: PresentationCodec.maxPendingFrames,
                                                              writeTimeoutSeconds: 5)
    static let overlayJobLimits = ControlStreamOwner.Limits(maxLineBytes: PresentationCodec.maxFrameBytes,
                                                            maxPendingLines: 16, writeTimeoutSeconds: 5)
    static let heartbeatSeconds: TimeInterval = 10
    /// Lines a viewer may have waiting for the GTK thread. The reader stops reading past this, so a fast or
    /// faulty peer backs up into its own socket instead of into this app's memory.
    static let inboundLimit = 64

    let host: LinuxPresentationHost
    let hub = PresentationHub(staleTimeout: 30)
    let overlayJobs = OverlayJobs()
    var streams: [LinuxPresentationStream] = []
    var jobStreams: [String: LinuxOverlayJobStream] = [:]
    /// Jobs cancelled between their claim and the adoption of the helper's connection.
    var pendingJobCancels: Set<String> = []
    /// How long an adopted stream may stay silent before its first hello.
    var helloDeadline: TimeInterval = 10
    var heartbeat: LinuxRepeatingTimer?

    /// The viewer role: one client per attached row. The transport is injectable so a test needs no ssh.
    var remoteClients: [UUID: RemotePresentationClient] = [:]
    var transport: RemotePresentationTransport = LinuxRemotePresentationProcess()
    var remoteTick: LinuxRepeatingTimer?
    /// The clock HUD deadlines and the clients' backoff read.
    var clock: () -> Date = Date.init
    /// The one-shot deadlines, the hello and the overlay job windows. Injected by a test, `MainTimer` otherwise.
    var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, body in
        _ = MainTimer.schedule(after: delay, body)
    }

    init(host: LinuxPresentationHost) {
        self.host = host
    }

    var library: WindowLibrary? { host.library }

    // MARK: - Origin: presentation streams

    /// Answers `zmx.present`. The stream itself starts only after this reply is on the wire.
    func openPresentation(session target: String?) -> ControlResponse {
        attach()
        switch resolveSession(target) {
        case .failure(let response): return response
        case .success(let (store, id)):
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session")
            }
            guard session.allPanesBackedByZmx else {
                return ControlResponse(ok: false, error: "session is not live-backed, so nothing can be attached to it")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Takes over a connection whose `zmx.present` was just answered ok. Returns at once; the owner's
    /// threads do the I/O from here.
    func adoptPresentationStream(descriptor: Int32, session: UUID) {
        let owner = ControlStreamOwner(descriptor: descriptor, limits: Self.presentationLimits)
        let stream = LinuxPresentationStream(session: session, owner: owner, service: self)
        streams.append(stream)
        attach()
        startHeartbeat()
        // reads carry no idle timeout, and the hub's heartbeat only knows subscribers, so a peer that takes
        // the reply and then says nothing would otherwise hold two threads and a descriptor for good
        schedule(helloDeadline) { [weak stream] in
            guard let stream, !stream.subscribed else { return }
            stream.shutdown()
        }
        let inbound = DispatchSemaphore(value: Self.inboundLimit)
        let box = WeakStream(stream)
        owner.start(
            onLine: { line in
                inbound.wait()
                runOnMain {
                    MainActor.assumeIsolated { box.stream?.receive(line) }
                    inbound.signal()
                }
            },
            onClose: {
                runOnMain { MainActor.assumeIsolated { box.stream?.closed() } }
            })
    }

    func subscribe(_ stream: LinuxPresentationStream, hello: PresentationHello) throws -> PresentationHub.SubscriberID {
        let id = stream.session
        let library = library
        let now = clock()
        return try hub.subscribe(session: id, hello: hello, sink: stream) {
            library?.store(forSession: id)?.presentationSnapshot(forSession: id, now: now)
                ?? PresentationSnapshot(status: nil, hud: nil)
        }
    }

    func sourceExists(_ session: UUID) -> Bool {
        library?.store(forSession: session)?.session(withID: session) != nil
    }

    /// Points every open store at the hub and the job table, installs the row-visibility hook the viewer
    /// role follows, and ends streams whose session left. Stores are created by the window library, so this
    /// runs wherever the open windows are walked: every control request, and both timers.
    func attach() {
        hub.onPresenterLost = { [weak self] session in
            self?.takeBackRemoteAsk(forSession: session)
            self?.library?.store(forSession: session)?.remoteOverlayPresenterLost(forSession: session)
            self?.changed(session, .deck)
        }
        hub.onPresenterFrame = { [weak self] session, body in
            self?.receivePresenterFrame(body, forSession: session)
        }
        overlayJobs.onFinished = { [weak self] job in
            self?.pendingJobCancels.remove(job.id)
            self?.library?.store(forSession: job.session)?.finishRemoteOverlay(job)
        }
        guard let library else { return }
        for entry in library.windows {
            guard let store = library.store(for: entry.id) else { continue }
            store.presentationHub = hub
            store.overlayJobs = overlayJobs
            store.onRemoteRowVisibility = { [weak self] session, shown in
                MainActor.assumeIsolated { self?.remoteRowVisibilityChanged(session, shown: shown) }
            }
        }
        dropOrphanedStreams()
    }

    /// Ends the streams of sessions no open window holds. A viewer would otherwise keep the last mirrored
    /// state for good, on a stream that still answers pings.
    func dropOrphanedStreams() {
        for stream in streams where !sourceExists(stream.session) { stream.shutdown() }
    }

    func shutdownStreams() {
        for stream in streams { stream.shutdown() }
        for stream in jobStreams.values { stream.shutdown() }
        heartbeat?.cancel()
        heartbeat = nil
    }

    /// The hub's ping and stale check, on a timer of its own that stops once no stream is left.
    func beat() {
        dropOrphanedStreams()
        hub.heartbeat()
    }

    private func startHeartbeat() {
        guard heartbeat?.isRunning != true else { return }
        heartbeat = LinuxRepeatingTimer(interval: Self.heartbeatSeconds) { [weak self] in
            guard let self, !self.streams.isEmpty else {
                self?.heartbeat = nil
                return false
            }
            self.attach()
            self.beat()
            return true
        }
    }

    // MARK: - Shared

    func store(forSession id: UUID) -> AppStore? { library?.store(forSession: id) }

    func changed(_ sessionID: UUID, _ change: LinuxPresentationChange) {
        guard let store = store(forSession: sessionID) else { return }
        host.presentationChanged(sessionID, in: store, change)
    }

    /// A session target resolved across every open window, `active` meaning the frontmost one's selection.
    func resolveSession(_ target: String?) -> AppController.ResolveResponse<(AppStore, UUID)> {
        let stores = (library?.windows ?? []).compactMap { library?.store(for: $0.id) }
        let candidates = stores.flatMap { $0.workspaces.flatMap { $0.sessions.map(\.id) } }
        let spelled = target?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = spelled?.isEmpty == false ? spelled! : "active"
        switch ControlResolve.resolve(name, candidates: candidates, active: library?.activeStore?.selectedSessionID) {
        case .resolved(let id):
            guard let store = stores.first(where: { $0.session(withID: id) != nil }) else {
                return .failure(ControlResponse(ok: false, error: "no such session"))
            }
            return .success((store, id))
        case .ambiguous(let hits):
            return .failure(ControlResponse(ok: false, error: ControlResolve.ambiguousMessage(noun: "session",
                                                                                             target: name, hits: hits)))
        case .notFound:
            return .failure(ControlResponse(ok: false, error: ControlResolve.notFoundMessage(noun: "session",
                                                                                            target: name)))
        }
    }
}

/// Lets a thread callback reach a main-actor stream without retaining it.
private final class WeakStream: @unchecked Sendable {
    weak var stream: LinuxPresentationStream?
    init(_ stream: LinuxPresentationStream) { self.stream = stream }
}

/// One viewer's presentation stream: the hub's sink on one side, a `ControlStreamOwner` on the other.
///
/// The viewer speaks first. Its hello subscribes it, and everything after goes to the hub as that
/// subscriber's frames. Main-actor only; the owner's thread callbacks hop here before touching it.
@MainActor
final class LinuxPresentationStream: PresentationSink {
    let session: UUID
    private let owner: ControlStreamOwner
    private weak var service: LinuxPresentationService?
    private var subscriber: PresentationHub.SubscriberID?

    init(session: UUID, owner: ControlStreamOwner, service: LinuxPresentationService) {
        self.session = session
        self.owner = owner
        self.service = service
    }

    /// False for a frame that cannot be encoded, too: reporting it taken would advance the revision over an
    /// event the viewer never got, on a stream that still looks healthy.
    func offer(_ frame: PresentationFrame) -> Bool {
        guard let line = try? PresentationCodec.encode(frame) else { return false }
        return owner.send(line)
    }

    var subscribed: Bool { subscriber != nil }

    func close(_ reason: PresentationHub.CloseReason) { owner.shutdown() }

    func shutdown() { owner.shutdown() }

    func receive(_ line: Data) {
        guard let service else { return }
        guard let frame = try? PresentationCodec.decode(line) else {
            owner.shutdown()
            return
        }
        if let subscriber {
            service.hub.receive(frame, from: subscriber)
            return
        }
        guard case .hello(let hello) = frame.body, service.sourceExists(session),
              let subscribed = try? service.subscribe(self, hello: hello) else {
            owner.shutdown()
            return
        }
        subscriber = subscribed
    }

    func closed() {
        if let subscriber { service?.hub.unsubscribe(subscriber) }
        subscriber = nil
        service?.streams.removeAll { $0 === self }
    }
}
