import AVFoundation
import CoreLocation
import Foundation

/// Runs filming: one-time tickets, 15-minute pieces that chain automatically, photos, and handing each file to the upload queue.
@MainActor
final class Recorder: ObservableObject {
    enum Mode: String { case video, photo }
    @Published var mode: Mode = .video
    @Published private(set) var isRecording = false {
        didSet { queue.copiesOnHold = isRecording; if isRecording { location.startHeading() } else { location.stopHeading() } }
    }   // build 20: no copies made while filming; build 21: the compass runs only while filming   // build 20: no copies made while filming
    @Published private(set) var pieceNo = 0
    @Published private(set) var pieceStartedAt: Date?
    @Published var problem: String?

    let camera = CameraController()
    private let location: LocationProvider
    private let queue: UploadQueue
    private let api: APIClient
    /// Build 21: where the phone is and which way the camera points through each piece.
    private let path = PathRecorder()
    private var deviceId: String?
    private var key: CaptureKey?
    var gatheringId: String?

    // The piece being filmed and what it will need.
    private var chainId = UUID().uuidString
    private var current: (ticket: Ticket, fix: CLLocation, url: URL, startedAt: Date?)?
    private var nextTicket: Ticket?
    private var nextTicketTask: Task<Void, Never>?
    private var stopRequested = false
    /// A spare ticket kept ready so filming starts the moment the button is pressed.
    private var spare: Ticket?

    init(location: LocationProvider, queue: UploadQueue, api: APIClient = .shared) {
        self.location = location
        self.queue = queue
        self.api = api
        camera.onPieceStarted = { [weak self] url, at in self?.pieceStarted(url: url, at: at) }
        camera.onPieceFinished = { [weak self] url, hitLimit, err in self?.pieceFinished(url: url, hitLimit: hitLimit, error: err) }
        location.onEachLocation = { [weak self] l in self?.path.location(l) }
        location.onHeading = { [weak self] h in self?.path.heading(h) }
        let cam = camera
        path.onLocation = { l in cam.appendLocation(l) }
        path.onAim = { text in cam.appendAim(text) }
    }

    func attach(deviceId: String, key: CaptureKey) {
        self.deviceId = deviceId
        self.key = key
        Task { self.spare = try? await self.fetchTicket() }
    }

    // MARK: tickets

    private func fetchTicket() async throws -> Ticket {
        guard let deviceId, let key else { throw APIError(status: 0, code: "not_registered", message: "This phone is not signed up yet.") }
        let gid = gatheringId
        let r = try await api.postSigned("/v1/crowd/tickets", ["gathering_id": gid.map { $0 as Any } ?? NSNull()], deviceId: deviceId, key: key).body
        guard let tid = r["ticket_id"] as? String, let nonce = r["nonce"] as? String else {
            throw APIError(status: 0, code: "bad_answer", message: "Chronum did not give a ticket.")
        }
        var t = Ticket(ticketId: tid, nonce: nonce, gatheringId: gid, receivedAt: Date())
        t.clock = await ClockCheck.measure(deviceId: deviceId, key: key, api: api)   // build 21: how far this phone's clock is off
        return t
    }

    /// A fresh ticket for the current gathering: the spare one if it is still good, otherwise a new one.
    private func takeTicket() async throws -> Ticket {
        if let s = spare, s.isFresh, s.gatheringId == gatheringId { spare = nil; refillSpare(); return s }
        let t = try await fetchTicket()
        refillSpare()
        return t
    }

    private func refillSpare() {
        Task { self.spare = try? await self.fetchTicket() }
    }

    /// Changing gatherings throws away the spare ticket, which was issued for the old one.
    func gatheringChanged(_ id: String?) {
        gatheringId = id
        spare = nil
        refillSpare()
    }

    // MARK: video

    func toggleRecording() {
        if isRecording { stopRequested = true; camera.stopPiece(); return }
        Task { await self.startChain() }
    }

    private func startChain() async {
        problem = nil
        guard let fix = location.currentFix else {
            problem = "Waiting for your location. Crowdography needs it to prove where you filmed."
            return
        }
        do {
            let t = try await takeTicket()
            chainId = UUID().uuidString
            pieceNo = 0
            stopRequested = false
            isRecording = true
            beginPiece(ticket: t, fix: fix)
        } catch {
            problem = "Could not start: " + error.localizedDescription
        }
    }

    private func beginPiece(ticket: Ticket, fix: CLLocation) {
        let url = CaptureStore.fileURL(UUID().uuidString + ".mov")
        current = (ticket, fix, url, nil)
        path.begin(url)
        pieceNo += 1
        camera.startPiece(to: url)
    }

    private func pieceStarted(url: URL, at: Date) {
        guard current?.url == url else { return }
        current?.startedAt = at
        path.setStart(url, at: at)
        pieceStartedAt = at
        // Get the next piece's ticket a minute before this one reaches its full length.
        nextTicket = nil
        nextTicketTask?.cancel()
        nextTicketTask = Task { [weak self] in
            let wait = Config.maxPieceSeconds - Config.nextTicketLeadSeconds
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isRecording else { return }
            self.nextTicket = try? await self.fetchTicket()
        }
    }

    private func pieceFinished(url: URL, hitLimit: Bool, error: Error?) {
        guard let cur = current, cur.url == url else { return }
        current = nil
        let finishedChain = chainId, finishedPiece = pieceNo, finishedAt = Date()
        Task {
            // Start the next piece first, so the gap between pieces stays well under the 2 seconds the server allows.
            if hitLimit && !self.stopRequested && error == nil {
                await self.continueChain(previousFinishedAt: finishedAt)
            } else {
                self.isRecording = false
                self.pieceStartedAt = nil
                self.nextTicketTask?.cancel()
            }
            await self.enqueue(cur, chain: finishedChain, segmentNo: finishedPiece, error: error)
        }
    }

    /// The next piece starts right away. If its ticket is not ready, or more than 2 seconds pass, it starts a new chain instead.
    private func continueChain(previousFinishedAt: Date) async {
        let fix = location.currentFix ?? location.latest
        var t = nextTicket
        if t == nil { t = try? await takeTicket() }
        guard let ticket = t, let fix else {
            isRecording = false
            pieceStartedAt = nil
            problem = "Filming stopped: no ticket or location for the next piece."
            return
        }
        nextTicket = nil
        if Date().timeIntervalSince(previousFinishedAt) > 1.5 {
            chainId = UUID().uuidString
            pieceNo = 0
        }
        beginPiece(ticket: ticket, fix: fix)
    }

    private func enqueue(_ cur: (ticket: Ticket, fix: CLLocation, url: URL, startedAt: Date?), chain: String, segmentNo: Int, error: Error?) async {
        guard FileManager.default.fileExists(atPath: cur.url.path), let started = cur.startedAt else {
            path.cancel(cur.url)
            if let error { problem = "The camera stopped: " + error.localizedDescription }
            return
        }
        let seconds = (try? await AVURLAsset(url: cur.url).load(.duration).seconds) ?? 0
        let ended = started.addingTimeInterval(seconds.isFinite ? max(0, seconds) : 0)
        var job = CaptureJob(id: UUID().uuidString, fileName: cur.url.lastPathComponent, mimeType: "video/quicktime", chainId: chain,
                             segmentNo: segmentNo, ticket: cur.ticket, startedAt: started, endedAt: ended,
                             lat: cur.fix.coordinate.latitude, lng: cur.fix.coordinate.longitude, accuracyM: cur.fix.horizontalAccuracy)
        // Build 21: the camera path goes in a small file next to the clip; its fingerprint is signed with the clip.
        if let data = path.finish(cur.url, endedAt: ended) {
            let name = cur.url.deletingPathExtension().lastPathComponent + ".path.json"
            if (try? data.write(to: CaptureStore.fileURL(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil {
                job.pathFileName = name; job.pathSha256 = Hash.sha256Hex(data)
            }
        }
        queue.add(job)
        saveToLibrary(cur.url, isVideo: true, takenAt: started, place: cur.fix)
    }

    /// A copy for the person's own photo library. A failure here never affects the proof or the upload.
    private func saveToLibrary(_ url: URL, isVideo: Bool, takenAt: Date, place: CLLocation) {
        Task {
            switch await PhotoLibrarySaver.save(fileURL: url, isVideo: isVideo, takenAt: takenAt, place: place) {
            case .saved: self.queue.markInLibrary(fileName: url.lastPathComponent)
            case .notAllowed: break   // the person said no to library access: the app keeps its own copy
            case .failed(let why): self.problem = "Filmed and queued, but not copied to your photo library: " + why
            }
        }
    }

    // MARK: photo

    func takePhoto() {
        Task {
            problem = nil
            guard let fix = location.currentFix else {
                problem = "Waiting for your location. Crowdography needs it to prove where you took the photo."
                return
            }
            do {
                let t = try await takeTicket()
                let at = Date()
                // Build 24 (Jeff 2026-11-26): which way the camera points as the shutter fires, read while the photo is taken.
                if !isRecording { location.startHeading() }
                let aim = Task { await self.path.snapshot(location: fix) }
                let data = try await camera.capturePhoto()
                let pathData = await aim.value
                if !isRecording { location.stopHeading() }
                let base = UUID().uuidString, name = base + ".heic"
                try data.write(to: CaptureStore.fileURL(name), options: .atomic)
                var job = CaptureJob(id: UUID().uuidString, fileName: name, mimeType: "image/heic", chainId: UUID().uuidString,
                                     segmentNo: 1, ticket: t, startedAt: at, endedAt: at,
                                     lat: fix.coordinate.latitude, lng: fix.coordinate.longitude, accuracyM: fix.horizontalAccuracy)
                if let pathData, (try? pathData.write(to: CaptureStore.fileURL(base + ".path.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil {
                    job.pathFileName = base + ".path.json"; job.pathSha256 = Hash.sha256Hex(pathData)
                }
                queue.add(job)
                saveToLibrary(CaptureStore.fileURL(name), isVideo: false, takenAt: at, place: fix)
            } catch {
                problem = "Photo not taken: " + error.localizedDescription
            }
        }
    }
}
