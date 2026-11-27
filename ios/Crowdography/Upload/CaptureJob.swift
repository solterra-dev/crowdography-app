import Foundation

/// A one-time ticket from Chronum. Recording must start after it was issued and before it expires (300 seconds).
struct Ticket: Codable, Equatable {
    let ticketId: String
    let nonce: String
    let gatheringId: String?
    let receivedAt: Date
    /// Build 21: how far this phone's clock was from Chronum's when the ticket was taken. Nil if it could not be measured.
    var clock: ClockReading? = nil
    var isFresh: Bool { Date().timeIntervalSince(receivedAt) < 240 }
}

/// One clip piece or photo waiting to be proven and stored. Saved to disk so nothing is lost if the app is closed.
struct CaptureJob: Codable, Identifiable, Equatable {
    /// checking (build 24): the server took the statement and is checking a big file in the background.
    enum Stage: String, Codable { case waiting, hashing, uploading, submitting, checking, verified, rejected, failed }

    let id: String
    let fileName: String
    let mimeType: String
    let chainId: String
    var segmentNo: Int
    let ticket: Ticket
    let startedAt: Date
    let endedAt: Date
    let lat: Double
    let lng: Double
    let accuracyM: Double

    var stage: Stage = .waiting
    var sha256: String?
    var byteSize: Int?
    var mediaAssetId: String?
    var uploadURL: URL?
    var uploadURLReceivedAt: Date?
    var uploaded = false
    var captureId: String?
    var lastProblem: String?
    var failedChecks: [String] = []
    var attempts = 0
    /// True once an exact copy is in the person's photo library.
    var inLibrary = false
    /// True once the app's own working copy has been removed (only after verified AND in the library).
    var localCopyRemoved = false
    /// Build 20 (Jeff 2026-11-26): viewing copies the phone makes after a video verifies. Optional, so job lists saved by
    /// earlier builds still load. True once every copy is stored, or the phone gave up on them (the original is enough to watch).
    var copiesDone: Bool?
    /// Kinds already stored: strip0, strip1..., "strips" once all strips are in, play, tile.
    var copiesStored: [String]?
    var copyAttempts: Int?
    /// Build 21 (Jeff 2026-11-26): where the phone was and which way the camera pointed through the piece, in a small file
    /// next to the clip. Its sha256 is signed with the clip, so the path cannot be changed later.
    var pathFileName: String? = nil
    var pathSha256: String? = nil
    /// Build 24: when the phone last asked the server how a background check is going.
    var checkAskedAt: Date? = nil

    var isDone: Bool { stage == .verified || stage == .rejected }
    var isPhoto: Bool { mimeType.hasPrefix("image/") }
    /// A verified video whose viewing copies are not made yet, with its working file still on the phone.
    /// Build 24: a photo needs only its signed camera direction sent; a video needs that and its viewing copies.
    var needsCopies: Bool {
        guard stage == .verified, captureId != nil, copiesDone != true else { return false }
        return isPhoto ? pathFileName != nil : !localCopyRemoved
    }
}

/// Where pieces and the job list live: the app's own private folder, left out of iCloud backups.
enum CaptureStore {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Captures", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var v = URLResourceValues(); v.isExcludedFromBackup = true
            try? dir.setResourceValues(v)
        }
        return dir
    }
    static func fileURL(_ name: String) -> URL { folder.appendingPathComponent(name) }
    private static var jobsURL: URL { folder.appendingPathComponent("jobs.json") }

    static func loadJobs() -> [CaptureJob] {
        guard let d = try? Data(contentsOf: jobsURL) else { return [] }
        return (try? JSONDecoder().decode([CaptureJob].self, from: d)) ?? []
    }
    static func saveJobs(_ jobs: [CaptureJob]) {
        if let d = try? JSONEncoder().encode(jobs) { try? d.write(to: jobsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }
}
