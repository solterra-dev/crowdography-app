import Foundation

/// One stored photo or video piece from the account, as Chronum lists it (POST /v1/crowd/footage).
struct FootageItem: Identifiable, Equatable {
    /// The capture id.
    let id: String
    /// False for a photo.
    let isVideo: Bool
    let mimeType: String
    let byteSize: Int
    let startedAt: Date
    let seconds: Int
    let pieceNo: Int
    /// True when Chronum checked the original and it passed.
    let verified: Bool
    let gatheringName: String?
    /// Where it was filmed (build 21), so its time can be shown in that place's time zone.
    let lat: Double?
    let lng: Double?
    /// A private link to the original. It stops working about 30 minutes after it was received.
    var viewURL: URL?
    var linkReceivedAt: Date

    /// The server gives each link 30 minutes. The app asks for a new one a little early.
    static let linkLifetime: TimeInterval = 1500

    var linkIsFresh: Bool { viewURL != nil && Date().timeIntervalSince(linkReceivedAt) < Self.linkLifetime }

    init?(_ d: [String: Any], receivedAt: Date = Date()) {
        guard let id = d["capture_id"] as? String, !id.isEmpty,
              let kind = d["kind"] as? String,
              let startedText = d["started_at"] as? String, let started = Self.parseTime(startedText) else { return nil }
        self.id = id
        isVideo = kind != "photo"
        mimeType = d["mime_type"] as? String ?? ""
        byteSize = d["byte_size"] as? Int ?? 0
        startedAt = started
        seconds = max(0, d["seconds"] as? Int ?? 0)
        pieceNo = d["piece_no"] as? Int ?? 1
        verified = d["verified"] as? Bool ?? false
        gatheringName = d["gathering_name"] as? String
        lat = (d["lat"] as? NSNumber)?.doubleValue
        lng = (d["lng"] as? NSNumber)?.doubleValue
        viewURL = (d["view_url"] as? String).flatMap { URL(string: $0) }
        linkReceivedAt = receivedAt
    }

    /// Chronum sends times as 2026-11-25T03:43:00Z.
    static func parseTime(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }

    /// A video's length as minutes and seconds, like 2:05.
    var lengthLabel: String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file) }
}
