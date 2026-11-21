import Foundation

/// The small statement the phone signs for each clip or photo. The server signature-checks these exact bytes, then checks
/// every field against its own records and its own hash of the stored file (crowd_verify.php, statement version 1).
struct CaptureStatement: Codable, Equatable {
    var sha256: String
    var byteSize: Int
    var mimeType: String
    var gatheringId: String?
    var deviceId: String
    var ticketId: String
    var nonce: String
    var startedAt: Date
    var endedAt: Date
    var lat: Double
    var lng: Double
    var accuracyM: Double
    var segmentNo: Int
    var previousCaptureId: String?

    /// The exact bytes to sign and send. Only the fields the server knows; previous_capture_id only for a continued piece.
    func signedBytes() throws -> Data {
        var o: [String: Any] = [
            "v": 1,
            "sha256": sha256,
            "byte_size": byteSize,
            "mime_type": mimeType,
            "gathering_id": gatheringId.map { $0 as Any } ?? NSNull(),
            "device_id": deviceId,
            "ticket_id": ticketId,
            "nonce": nonce,
            "started_at": UTC.string(startedAt),
            "ended_at": UTC.string(endedAt),
            "lat": lat,
            "lng": lng,
            "accuracy_m": max(0, accuracyM),
            "segment_no": segmentNo,
        ]
        if segmentNo > 1, let p = previousCaptureId { o["previous_capture_id"] = p }
        return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
