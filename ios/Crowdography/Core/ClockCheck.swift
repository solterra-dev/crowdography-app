import Foundation

/// How far this phone's clock is from Chronum's (Jeff 2026-11-26: clips must line up even when a cell tower set the phone's
/// clock wrong). The phone notes its clock when the request leaves and when the answer arrives; the server's time is taken
/// to be the middle of that trip, so the error is at most half the round trip. Several tries, keeping the shortest trip.
struct ClockReading: Codable, Equatable {
    /// Phone clock minus server clock, in milliseconds. Positive: the phone is ahead.
    let offsetMs: Int
    /// The round trip the reading came from, in milliseconds.
    let rttMs: Int
}

enum ClockCheck {
    static let tries = 3

    /// One reading from times in milliseconds since 1970: sent and received on the phone's clock, the server's in between.
    static func reading(sentMs: Double, serverMs: Double, receivedMs: Double) -> ClockReading {
        let rtt = max(0, receivedMs - sentMs)
        return ClockReading(offsetMs: Int(((sentMs + rtt / 2) - serverMs).rounded()), rttMs: Int(rtt.rounded()))
    }

    /// The most trustworthy reading: the one with the shortest round trip.
    static func best(_ readings: [ClockReading]) -> ClockReading? { readings.min { $0.rttMs < $1.rttMs } }

    /// Measures against Chronum. Nil when the server could not be reached; filming still works, just without the correction.
    static func measure(deviceId: String, key: CaptureKey, api: APIClient = .shared) async -> ClockReading? {
        var got: [ClockReading] = []
        for _ in 0..<tries {
            guard let r = try? await api.clockPing(deviceId: deviceId, key: key) else { continue }
            got.append(reading(sentMs: r.sentMs, serverMs: r.serverMs, receivedMs: r.receivedMs))
        }
        return best(got).flatMap { $0.rttMs <= 10_000 && abs($0.offsetMs) <= 3_600_000 ? $0 : nil }
    }
}
