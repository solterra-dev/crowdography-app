import Foundation

/// A one-time ticket from Chronum. Recording must start after it was issued and before it expires (300 seconds).
struct Ticket: Codable, Equatable {
    let ticketId: String
    let nonce: String
    let gatheringId: String?
    let receivedAt: Date
    var isFresh: Bool { Date().timeIntervalSince(receivedAt) < 240 }
}

/// One clip piece or photo waiting to be proven and stored. Saved to disk so nothing is lost if the app is closed.
struct CaptureJob: Codable, Identifiable, Equatable {
    enum Stage: String, Codable { case waiting, hashing, uploading, submitting, verified, rejected, failed }

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

    var isDone: Bool { stage == .verified || stage == .rejected }
    var isPhoto: Bool { mimeType.hasPrefix("image/") }
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
