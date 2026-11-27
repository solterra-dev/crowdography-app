import Foundation
import UIKit

/// Proves and stores each piece, in the order it was filmed:
/// 1. hash every byte of the file, 2. ask Chronum for an upload address, 3. upload the original untouched,
/// 4. sign the statement and send it; Chronum re-reads the stored file and checks everything itself.
/// A continued piece waits for the piece before it, because its statement names that piece's proof.
@MainActor
final class UploadQueue: ObservableObject {
    /// One queue for the whole app, so iOS can wake it in the background without the screens (build 24).
    static let shared = UploadQueue()
    @Published private(set) var jobs: [CaptureJob] = CaptureStore.loadJobs()
    private var running = false
    private var again = false
    private var deviceId: String?
    private var key: CaptureKey?
    private let api: APIClient
    private var copying = false
    /// Set by the recorder while filming, so making copies never competes with the camera.
    var copiesOnHold = false { didSet { if !copiesOnHold { kickCopies() } } }

    init(api: APIClient = .shared) {
        self.api = api
        BackgroundUploader.shared.onFinished = { [weak self] id, status, error in
            self?.uploadFinished(jobId: id, status: status, error: error)
        }
    }

    var pendingCount: Int { jobs.filter { !$0.isDone }.count }
    /// Anything still to do: an upload, a check to hear back about, or copies to make and send.
    var hasWaitingWork: Bool { jobs.contains { !$0.isDone || $0.needsCopies } }
    /// Working right now (used to decide how long to keep background time).
    var isBusy: Bool { running || copying || jobs.contains { $0.stage == .uploading || $0.stage == .checking || $0.stage == .submitting } }

    /// When iOS wakes the app in the background, before any screen has started: the phone's saved identity, never a new one.
    func attachFromKeychain() {
        guard deviceId == nil, let id = DeviceRegistrar.savedDeviceId, let k = CaptureKey.loadExisting() else { return }
        attach(deviceId: id, key: k)
    }

    func attach(deviceId: String, key: CaptureKey) {
        self.deviceId = deviceId
        self.key = key
        kick()
    }

    func add(_ job: CaptureJob) {
        jobs.append(job)
        save()
        kick()
    }

    /// Run the queue now (after a new piece, a finished upload, or the app coming back to the screen).
    func kick() {
        guard deviceId != nil, key != nil else { return }
        if running { again = true; return }   // a pass is under way: run one more when it ends, so no finished upload is left waiting
        running = true
        Task {
            repeat { self.again = false; await self.drain() } while self.again
            self.running = false
            self.kickCopies()
        }
    }

    private func drain() async {
        var madeProgress = true
        while madeProgress {
            madeProgress = false
            let busy = await BackgroundUploader.shared.runningJobIds()
            // A transfer marked as running that iOS no longer has (the phone restarted) starts again.
            for i in jobs.indices where jobs[i].stage == .uploading && !busy.contains(jobs[i].id) && !jobs[i].uploaded {
                jobs[i].stage = .waiting
            }
            save()
            for i in jobs.indices where !jobs[i].isDone && !busy.contains(jobs[i].id) && jobs[i].stage != .uploading {
                if await step(i) { madeProgress = true }
            }
        }
    }

    /// Moves one job forward as far as it can go right now. Returns true if anything changed.
    private func step(_ i: Int) async -> Bool {
        guard let deviceId, let key else { return false }
        var job = jobs[i]
        let file = CaptureStore.fileURL(job.fileName)
        do {
            // Build 24: a big file is being checked by the server in the background; ask how it is going now and then.
            if job.stage == .checking, let cid = job.captureId {
                if let t = job.checkAskedAt, Date().timeIntervalSince(t) < 15 { return false }
                job.checkAskedAt = Date()
                let r = try await api.postSigned("/v1/crowd/captures/status", ["capture_id": cid], deviceId: deviceId, key: key).body
                switch r["status"] as? String {
                case "verified": job.stage = .verified
                case "rejected":
                    job.stage = .rejected
                    let checks = r["checks"] as? [[String: Any]] ?? []
                    job.failedChecks = checks.filter { ($0["passed"] as? Bool) == false }.compactMap { $0["check"] as? String }
                    job.lastProblem = "Chronum could not verify this piece: " + job.failedChecks.joined(separator: ", ")
                default:
                    update(i, job); scheduleRetry(after: 20); return false
                }
                update(i, job); return true
            }
            if job.sha256 == nil {
                job.stage = .hashing; update(i, job)
                let h = try await Task.detached(priority: .utility) { try Hash.sha256HexOfFile(file) }.value
                job.sha256 = h.hex; job.byteSize = h.bytes
            }
            if job.mediaAssetId == nil || (!job.uploaded && urlExpired(job)) {
                if job.mediaAssetId != nil {
                    // An unused address ran out: ask again (Chronum makes a new pending record; the old one stays unused).
                    job.mediaAssetId = nil
                }
                let r = try await api.postSigned("/v1/crowd/captures/upload-requests",
                                                 ["mime_type": job.mimeType, "byte_size": job.byteSize ?? 0], deviceId: deviceId, key: key).body
                guard let mid = r["media_asset_id"] as? String, let u = (r["upload_url"] as? String).flatMap(URL.init(string:)) else {
                    throw APIError(status: 0, code: "bad_answer", message: "Chronum did not give an upload address.")
                }
                job.mediaAssetId = mid; job.uploadURL = u; job.uploadURLReceivedAt = Date()
            }
            if !job.uploaded, let u = job.uploadURL {
                job.stage = .uploading; job.lastProblem = nil; update(i, job)
                BackgroundUploader.shared.upload(jobId: job.id, file: file, to: u)
                return true   // uploadFinished() picks it up again
            }
            // A continued piece needs the proof of the piece before it.
            var previousId: String? = nil
            if job.segmentNo > 1 {
                guard let prev = jobs.first(where: { $0.chainId == job.chainId && $0.segmentNo == job.segmentNo - 1 }) else {
                    job.segmentNo = 1; update(i, job); return true
                }
                switch prev.stage {
                case .verified: previousId = prev.captureId
                case .rejected:
                    job.segmentNo = 1   // the chain broke: this piece is proven on its own as a new first piece
                default:
                    update(i, job); return false   // wait for the earlier piece
                }
            }
            job.stage = .submitting; update(i, job)
            let st = CaptureStatement(sha256: job.sha256!, byteSize: job.byteSize!, mimeType: job.mimeType, gatheringId: job.ticket.gatheringId,
                                      deviceId: deviceId, ticketId: job.ticket.ticketId, nonce: job.ticket.nonce, startedAt: job.startedAt, endedAt: job.endedAt,
                                      lat: job.lat, lng: job.lng, accuracyM: job.accuracyM, segmentNo: job.segmentNo, previousCaptureId: previousId,
                                      pathSha256: job.pathSha256, clock: job.ticket.clock)
            let bytes = try st.signedBytes()
            let sig = try key.signBase64(bytes)
            let r = try await api.postSigned("/v1/crowd/captures",
                                             ["media_asset_id": job.mediaAssetId!, "statement": String(decoding: bytes, as: UTF8.self), "signature": sig],
                                             deviceId: deviceId, key: key)
            job.captureId = r.body["capture_id"] as? String
            if r.status == 202 {   // build 24: a big file; the server checks it in the background, even if this phone is closed
                job.stage = .checking; job.checkAskedAt = Date(); update(i, job)
                scheduleRetry(after: 20)
                return true
            }
            let verified = r.body["verified"] as? Bool ?? false
            job.stage = verified ? .verified : .rejected
            if !verified {
                let checks = r.body["checks"] as? [[String: Any]] ?? []
                job.failedChecks = checks.filter { ($0["passed"] as? Bool) == false }.compactMap { $0["check"] as? String }
                job.lastProblem = "Chronum could not verify this piece: " + job.failedChecks.joined(separator: ", ")
            }
            update(i, job)
            return true
        } catch let e as APIError where e.code == "not_uploaded" {
            job.uploaded = false; job.stage = .waiting; job.lastProblem = e.message; update(i, job); return false
        } catch let e as APIError where [400, 403, 404, 409, 413, 451].contains(e.status) {
            // The server said no for good (for example too large, or this phone is blocked): trying again would not help.
            job.stage = .rejected; job.lastProblem = e.message; update(i, job); return true
        } catch {
            job.attempts += 1
            job.stage = .failed
            job.lastProblem = error.localizedDescription
            update(i, job)
            scheduleRetry(after: min(300, Double(5 << min(job.attempts, 6))))
            return false
        }
    }

    private func urlExpired(_ job: CaptureJob) -> Bool {
        guard let t = job.uploadURLReceivedAt else { return true }
        return Date().timeIntervalSince(t) > 3000   // addresses live 3600 seconds
    }

    private func uploadFinished(jobId: String, status: Int, error: Error?) {
        guard let i = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        var job = jobs[i]
        if error == nil && (200..<300).contains(status) {
            job.uploaded = true; job.stage = .waiting; job.lastProblem = nil
        } else {
            job.stage = .failed; job.attempts += 1
            job.lastProblem = error?.localizedDescription ?? "Storage answered \(status)."
            if status == 403 { job.uploadURL = nil; job.uploadURLReceivedAt = nil; job.mediaAssetId = nil }
            scheduleRetry(after: 30)
        }
        update(i, job)
        kick()
    }

    private func scheduleRetry(after seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.kick()
        }
    }

    private func update(_ i: Int, _ job: CaptureJob) {
        guard jobs.indices.contains(i) else { return }
        var merged = job
        merged.inLibrary = job.inLibrary || jobs[i].inLibrary   // the library copy may have finished while this step was waiting
        jobs[i] = merged
        removeLocalCopyIfSafe(i)
        save()
    }

    /// Called when the copy for the person's photo library has been saved.
    func markInLibrary(fileName: String) {
        guard let i = jobs.firstIndex(where: { $0.fileName == fileName }) else { return }
        jobs[i].inLibrary = true
        removeLocalCopyIfSafe(i)
        save()
    }

    /// Jeff 2026-11-21: once the server has verified a clip, the app deletes its own working copy. It does so only when
    /// BOTH are true: Chronum answered verified, and an exact copy is in the person's photo library. A clip that was
    /// not verified, or that could not be copied to the library, is kept.
    /// Build 20: a video's working copy is also kept until its viewing copies are made (or the phone gave up on them).
    private func removeLocalCopyIfSafe(_ i: Int) {
        guard jobs[i].stage == .verified, jobs[i].inLibrary, !jobs[i].localCopyRemoved else { return }
        guard jobs[i].isPhoto || jobs[i].copiesDone == true else { return }
        try? FileManager.default.removeItem(at: CaptureStore.fileURL(jobs[i].fileName))
        jobs[i].localCopyRemoved = true
    }

    /// At sign out: drop finished entries whose working copy is already gone, so the next person to sign in on this phone
    /// does not see them. Anything that still holds a file on the phone stays listed.
    func forgetFinished() {
        jobs.removeAll { $0.stage == .verified && $0.localCopyRemoved }
        save()
    }

    private func save() { CaptureStore.saveJobs(jobs) }

    // MARK: viewing copies (Jeff 2026-11-26: the phone makes the copies, so it scales by itself)

    /// Starts making copies for the next verified video that needs them, one video at a time.
    func kickCopies() {
        guard !copying, !copiesOnHold, let deviceId, let key, let job = jobs.first(where: { $0.needsCopies }) else { return }
        copying = true
        let id = job.id
        Task {
            let task = UIApplication.shared.beginBackgroundTask(withName: "Crowdography copies")
            let finished = await self.makeCopies(jobId: id, deviceId: deviceId, key: key)
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            self.copying = false
            if finished { self.kickCopies() } else { self.scheduleCopyRetry() }
        }
    }

    private func scheduleCopyRetry() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            self?.kickCopies()
        }
    }

    private func changeJob(_ id: String, _ edit: (inout CaptureJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        edit(&jobs[i])
        removeLocalCopyIfSafe(i)
        save()
    }

    /// Makes and sends the frame strips, then the playback copy, then the four-screen copy. Each one that is stored is
    /// remembered, so an interrupted run picks up where it stopped. Returns false when it should be tried again later.
    private func makeCopies(jobId: String, deviceId: String, key: CaptureKey) async -> Bool {
        guard let job = jobs.first(where: { $0.id == jobId }), let cid = job.captureId else { return true }
        let src = CaptureStore.fileURL(job.fileName)
        // A video's copies are made from its working file; a photo sends only its camera direction (build 24).
        if !job.isPhoto && !FileManager.default.fileExists(atPath: src.path) { changeJob(jobId) { $0.copiesDone = true }; return true }
        let dir = CaptureStore.folder.appendingPathComponent("copies/" + jobId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var stored = Set(job.copiesStored ?? [])
        func remember(_ kind: String) { stored.insert(kind); let list = Array(stored).sorted(); changeJob(jobId) { $0.copiesStored = list } }
        do {
            // The signed camera path first: it is tiny, and it is what puts this angle on the map (build 21).
            if let pf = job.pathFileName, job.pathSha256 != nil, !stored.contains("path") {
                let pathURL = CaptureStore.fileURL(pf)
                if FileManager.default.fileExists(atPath: pathURL.path) {
                    try await sendCopy(cid, kind: "path", file: pathURL, mime: "application/json", frames: nil, deviceId: deviceId, key: key)
                    try? FileManager.default.removeItem(at: pathURL)
                }
                remember("path")
            }
            if job.isPhoto { changeJob(jobId) { $0.copiesDone = true }; return true }
            if !stored.contains("strips") {
                // Strips first: they are the quickest to make, and they are what puts this angle in the scrolling list.
                let strips = try await CopyMaker.strips(src, folder: dir)
                for (n, s) in strips.enumerated() where !stored.contains("strip\(n)") {
                    try await sendCopy(cid, kind: "strip\(n)", file: s.url, mime: "image/jpeg", frames: s.frames, deviceId: deviceId, key: key)
                    remember("strip\(n)")
                }
                remember("strips")
            }
            for (kind, side, bits) in [("play", CGFloat(1280), 2_500_000), ("tile", CGFloat(960), 1_200_000)] where !stored.contains(kind) {
                if copiesOnHold { return false }
                let out = dir.appendingPathComponent(kind + ".mp4")
                try await CopyMaker.transcode(src, to: out, longSide: side, videoBitsPerSecond: bits)
                try await sendCopy(cid, kind: kind, file: out, mime: "video/mp4", frames: nil, deviceId: deviceId, key: key)
                try? FileManager.default.removeItem(at: out)
                remember(kind)
            }
            try? FileManager.default.removeItem(at: dir)
            changeJob(jobId) { $0.copiesDone = true }
            return true
        } catch let e as APIError where [400, 403, 404, 409, 413, 422].contains(e.status) {
            // Chronum said no for good (for example the copy is too large): the original still plays, so stop trying.
            try? FileManager.default.removeItem(at: dir)
            changeJob(jobId) { $0.copiesDone = true; $0.lastProblem = "Viewing copies were not stored: " + e.message }
            return true
        } catch {
            // A copy stops when the app leaves the screen; that is not counted as a failed try.
            let counts = UIApplication.shared.applicationState == .active
            var gaveUp = false
            changeJob(jobId) { j in
                if counts { j.copyAttempts = (j.copyAttempts ?? 0) + 1 }
                if (j.copyAttempts ?? 0) >= 5 { j.copiesDone = true; j.lastProblem = "Viewing copies could not be made: " + error.localizedDescription; gaveUp = true }
            }
            if gaveUp { try? FileManager.default.removeItem(at: dir) }
            return gaveUp
        }
    }

    /// Asks Chronum for an address for one copy, uploads it, then confirms it (Chronum checks the stored size).
    private func sendCopy(_ cid: String, kind: String, file: URL, mime: String, frames: Int?, deviceId: String, key: CaptureKey) async throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        do {
            let r = try await api.postSigned("/v1/crowd/captures/copies/upload-requests",
                                             ["capture_id": cid, "kind": kind, "mime_type": mime, "byte_size": size], deviceId: deviceId, key: key).body
            guard let u = (r["upload_url"] as? String).flatMap(URL.init(string:)) else {
                throw APIError(status: 0, code: "bad_answer", message: "Chronum did not give an address for the \(kind) copy.")
            }
            var req = URLRequest(url: u); req.httpMethod = "PUT"
            let (_, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
            let st = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(st) else { throw APIError(status: 0, code: "copy_upload", message: "Storage answered \(st) for the \(kind) copy.") }
        } catch let e as APIError where e.code == "already_have" {
            return   // stored on an earlier try
        }
        var body: [String: Any] = ["capture_id": cid, "kind": kind, "byte_size": size]
        if let frames { body["frame_count"] = frames }
        _ = try await api.postSigned("/v1/crowd/captures/copies", body, deviceId: deviceId, key: key)
    }
}
