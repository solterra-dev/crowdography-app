import Foundation

/// Proves and stores each piece, in the order it was filmed:
/// 1. hash every byte of the file, 2. ask Chronum for an upload address, 3. upload the original untouched,
/// 4. sign the statement and send it; Chronum re-reads the stored file and checks everything itself.
/// A continued piece waits for the piece before it, because its statement names that piece's proof.
@MainActor
final class UploadQueue: ObservableObject {
    @Published private(set) var jobs: [CaptureJob] = CaptureStore.loadJobs()
    private var running = false
    private var again = false
    private var deviceId: String?
    private var key: CaptureKey?
    private let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
        BackgroundUploader.shared.onFinished = { [weak self] id, status, error in
            self?.uploadFinished(jobId: id, status: status, error: error)
        }
    }

    var pendingCount: Int { jobs.filter { !$0.isDone }.count }

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
                                      lat: job.lat, lng: job.lng, accuracyM: job.accuracyM, segmentNo: job.segmentNo, previousCaptureId: previousId)
            let bytes = try st.signedBytes()
            let sig = try key.signBase64(bytes)
            let r = try await api.postSigned("/v1/crowd/captures",
                                             ["media_asset_id": job.mediaAssetId!, "statement": String(decoding: bytes, as: UTF8.self), "signature": sig],
                                             deviceId: deviceId, key: key)
            job.captureId = r.body["capture_id"] as? String
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
    private func removeLocalCopyIfSafe(_ i: Int) {
        guard jobs[i].stage == .verified, jobs[i].inLibrary, !jobs[i].localCopyRemoved else { return }
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
}
