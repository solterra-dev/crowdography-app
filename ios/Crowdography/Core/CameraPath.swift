import Foundation

/// A clip's signed camera path (build 21): where the phone was and which way the back camera pointed, through the clip.
/// Times are milliseconds from the clip's first frame. See PathRecorder for how it is recorded.
struct CameraPath: Equatable {
    /// [t, lat, lng, accuracy m, speed m/s, course degrees, altitude m]; speed and course are negative when unknown.
    let loc: [[Double]]
    /// [t, azimuth, pitch, qx, qy, qz, qw, compass, compass accuracy]; azimuth and compass are negative when unknown.
    let aim: [[Double]]

    struct Pose: Equatable {
        let lat: Double
        let lng: Double
        let accuracyM: Double
        /// Which way the camera points, 0 north and 90 east; nil when it cannot be told.
        let azimuth: Double?
        let speedMps: Double?
    }

    static let fieldNames: [String: [String]] = [
        "loc": ["t_ms", "lat", "lng", "accuracy_m", "speed_mps", "course_deg", "altitude_m"],
        "aim": ["t_ms", "azimuth_deg", "pitch_deg", "qx", "qy", "qz", "qw", "compass_deg", "compass_accuracy_deg"],
    ]

    /// The file the phone signs. Numbers are rounded so a 15-minute piece stays a few hundred kilobytes.
    static func encode(startedAt: Date, frame: String, loc: [[Double]], aim: [[Double]]) -> Data? {
        func round(_ rows: [[Double]], _ places: [Int]) -> [[Double]] {
            rows.map { r in r.enumerated().map { i, v in
                let p = pow(10, Double(places[min(i, places.count - 1)])); return (v * p).rounded() / p } }
        }
        let o: [String: Any] = ["v": 1, "camera": "back", "started_at": UTC.string(startedAt), "frame": frame, "fields": fieldNames,
                                "loc": round(loc, [0, 7, 7, 1, 2, 1, 1]), "aim": round(aim, [0, 1, 1, 4, 4, 4, 4, 1, 1])]
        return try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    init(loc: [[Double]], aim: [[Double]]) {
        self.loc = loc.filter { $0.count >= 4 }.sorted { $0[0] < $1[0] }
        self.aim = aim.filter { $0.count >= 3 }.sorted { $0[0] < $1[0] }
    }

    init?(data: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], (o["v"] as? Int) == 1 else { return nil }
        func rows(_ k: String) -> [[Double]] { (o[k] as? [[Any]] ?? []).map { $0.compactMap { ($0 as? NSNumber)?.doubleValue } } }
        self.init(loc: rows("loc"), aim: rows("aim"))
        if loc.isEmpty && aim.isEmpty { return nil }
    }

    /// Where the camera was and which way it pointed `t` milliseconds into the clip. The place is worked out between the
    /// two GPS readings either side; the direction is the motion reading nearest in time (within 1.5 seconds).
    /// Direction, best first: the motion sensors' compass direction, then the compass heading, then the direction of travel
    /// when moving faster than a walk (a car's metal can throw a compass off, so a moving phone falls back to its travel).
    func pose(at t: Double) -> Pose? {
        guard let place = placeAt(t) else { return nil }
        var az: Double?
        if let a = nearest(aim, t, within: 1500) {
            if a.count > 1, a[1] >= 0 { az = a[1] } else if a.count > 7, a[7] >= 0 { az = a[7] }
        }
        if az == nil, place.speed >= 2, place.course >= 0 { az = place.course }
        return Pose(lat: place.lat, lng: place.lng, accuracyM: place.acc, azimuth: az, speedMps: place.speed >= 0 ? place.speed : nil)
    }

    private func placeAt(_ t: Double) -> (lat: Double, lng: Double, acc: Double, speed: Double, course: Double)? {
        guard let first = loc.first else { return nil }
        func parts(_ r: [Double]) -> (Double, Double, Double, Double, Double) { (r[1], r[2], r[3], r.count > 4 ? r[4] : -1, r.count > 5 ? r[5] : -1) }
        if t <= first[0] || loc.count == 1 { return parts(first) }
        guard let i = loc.firstIndex(where: { $0[0] >= t }) else { return parts(loc[loc.count - 1]) }
        let a = loc[i - 1], b = loc[i]
        let f = b[0] > a[0] ? (t - a[0]) / (b[0] - a[0]) : 0
        let pa = parts(a), pb = parts(b)
        return (pa.0 + (pb.0 - pa.0) * f, pa.1 + (pb.1 - pa.1) * f, max(pa.2, pb.2), f < 0.5 ? pa.3 : pb.3, f < 0.5 ? pa.4 : pb.4)
    }

    private func nearest(_ rows: [[Double]], _ t: Double, within ms: Double) -> [Double]? {
        guard let best = rows.min(by: { abs($0[0] - t) < abs($1[0] - t) }), abs(best[0] - t) <= ms else { return nil }
        return best
    }
}

/// Two letters for a person's camera on the map: first and last name, like JH for Jeff Huxmann.
enum Initials {
    static func of(_ name: String?) -> String {
        let words = (name ?? "").split(whereSeparator: { $0.isWhitespace }).filter { $0.first?.isLetter == true }
        guard let first = words.first?.first else { return "?" }
        guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }
}
