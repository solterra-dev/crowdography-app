import CoreLocation
import CoreMotion
import Foundation

/// Records where the phone is and which way the back camera points while a piece is filmed (Jeff 2026-11-26: know where
/// the phone was and which way it pointed in each frame, even when filming from a moving car).
///   loc: about once a second from GPS: time, latitude, longitude, accuracy, speed, direction of travel, altitude
///   aim: 5 times a second from the motion sensors: time, compass direction and up-down angle of the back camera, the raw
///        orientation (kept so the reading can be worked out again later), and the compass heading with its accuracy
/// Any frame's position and direction come from the readings either side of it (CameraPath.pose).
/// The same readings also go into the video file itself as a data track (CameraController.appendMetadata).
@MainActor
final class PathRecorder {
    static let aimInterval: TimeInterval = 0.2

    private final class Segment {
        var startMs: Double
        var loc: [[Double]] = []
        var aim: [[Double]] = []
        init(startMs: Double) { self.startMs = startMs }
    }
    private var segments: [URL: Segment] = [:]
    private let motion = CMMotionManager()
    private var frame: CMAttitudeReferenceFrame = .xArbitraryZVertical
    private var lastHeading: CLHeading?
    /// Each reading is also handed to the camera, which writes it into the video's data track.
    var onLocation: ((CLLocation) -> Void)?
    var onAim: ((String) -> Void)?

    var frameName: String {
        switch frame {
        case .xTrueNorthZVertical: return "true_north"
        case .xMagneticNorthZVertical: return "magnetic_north"
        default: return "arbitrary"
        }
    }

    /// Opens a path for the piece filmed to `url`. Readings start now; `setStart` fixes the real first-frame time.
    func begin(_ url: URL) {
        segments[url] = Segment(startMs: Date().timeIntervalSince1970 * 1000)
        startSensors()
    }
    func setStart(_ url: URL, at date: Date) { segments[url]?.startMs = date.timeIntervalSince1970 * 1000 }
    func cancel(_ url: URL) { segments[url] = nil; if segments.isEmpty { stopSensors() } }

    /// Closes the piece's path and returns its file bytes, keeping only readings from its first to its last frame
    /// (a second either side). Nil when there were no readings at all.
    func finish(_ url: URL, endedAt: Date) -> Data? {
        guard let seg = segments.removeValue(forKey: url) else { return nil }
        if segments.isEmpty { stopSensors() }
        let length = endedAt.timeIntervalSince1970 * 1000 - seg.startMs
        func within(_ rows: [[Double]]) -> [[Double]] {
            rows.compactMap { r in
                let t = r[0] - seg.startMs
                guard t >= -1000, t <= length + 1000 else { return nil }
                return [t.rounded()] + r.dropFirst()
            }
        }
        let loc = within(seg.loc), aim = within(seg.aim)
        guard !loc.isEmpty || !aim.isEmpty else { return nil }
        return CameraPath.encode(startedAt: Date(timeIntervalSince1970: seg.startMs / 1000), frame: frameName, loc: loc, aim: aim)
    }

    func location(_ l: CLLocation) {
        guard !segments.isEmpty, l.horizontalAccuracy >= 0 else { return }
        let row = [l.timestamp.timeIntervalSince1970 * 1000, l.coordinate.latitude, l.coordinate.longitude, l.horizontalAccuracy,
                   l.speed, l.course, l.verticalAccuracy >= 0 ? l.altitude : -9999]
        for s in segments.values { s.loc.append(row) }
        onLocation?(l)
    }
    func heading(_ h: CLHeading) { lastHeading = h }

    private func startSensors() {
        guard !motion.isDeviceMotionActive, motion.isDeviceMotionAvailable else { return }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        frame = frames.contains(.xTrueNorthZVertical) ? .xTrueNorthZVertical
              : frames.contains(.xMagneticNorthZVertical) ? .xMagneticNorthZVertical : .xArbitraryZVertical
        motion.deviceMotionUpdateInterval = Self.aimInterval
        let bootMs = (Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime) * 1000
        motion.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] m, _ in
            guard let m else { return }
            MainActor.assumeIsolated { self?.motionReading(m, bootMs: bootMs) }
        }
    }
    private func stopSensors() { if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() } }

    private func motionReading(_ m: CMDeviceMotion, bootMs: Double) {
        guard !segments.isEmpty else { return }
        let q = m.attitude.quaternion
        let a = CameraAim.of(qx: q.x, qy: q.y, qz: q.z, qw: q.w)
        let northKnown = frame != .xArbitraryZVertical
        let h = lastHeading
        let compass = h.map { $0.trueHeading >= 0 ? $0.trueHeading : $0.magneticHeading } ?? -1
        let row = [bootMs + m.timestamp * 1000, northKnown ? a.azimuth : -1, a.pitch, q.x, q.y, q.z, q.w,
                   compass, h.map { $0.headingAccuracy } ?? -1]
        for s in segments.values { s.aim.append(row) }
        onAim?(CameraAim.dataTrackText(azimuth: northKnown ? a.azimuth : nil, pitch: a.pitch, compass: compass >= 0 ? compass : nil))
    }
}

/// Which way the back camera points, from the phone's orientation. Pure arithmetic, so it is tested on its own.
/// The orientation turns the phone's own directions into the world's: x north, y west, z up (Core Motion's
/// north-referenced frames). The back camera looks out of the back of the phone, along the phone's minus z.
enum CameraAim {
    /// Compass direction (0 north, 90 east) and up-down angle (positive above the horizon), in degrees.
    static func of(qx: Double, qy: Double, qz: Double, qw: Double) -> (azimuth: Double, pitch: Double) {
        let v = rotate((0, 0, -1), qx: qx, qy: qy, qz: qz, qw: qw)
        var az = atan2(-v.1, v.0) * 180 / .pi
        if az < 0 { az += 360 }
        let pitch = asin(max(-1, min(1, v.2))) * 180 / .pi
        return ((az * 10).rounded() / 10, (pitch * 10).rounded() / 10)
    }
    /// Rotates vector v by the unit quaternion (qx, qy, qz, qw).
    static func rotate(_ v: (Double, Double, Double), qx: Double, qy: Double, qz: Double, qw: Double) -> (Double, Double, Double) {
        // v' = v + 2w(q × v) + 2 q × (q × v)
        let c1 = (qy * v.2 - qz * v.1, qz * v.0 - qx * v.2, qx * v.1 - qy * v.0)
        let c2 = (qy * c1.2 - qz * c1.1, qz * c1.0 - qx * c1.2, qx * c1.1 - qy * c1.0)
        return (v.0 + 2 * (qw * c1.0 + c2.0), v.1 + 2 * (qw * c1.1 + c2.1), v.2 + 2 * (qw * c1.2 + c2.2))
    }
    /// The text written into the video's data track for one reading, for example {"az":91.5,"pitch":-3.2,"compass":90.0}.
    static func dataTrackText(azimuth: Double?, pitch: Double, compass: Double?) -> String {
        var parts: [String] = []
        if let azimuth { parts.append("\"az\":" + String(format: "%.1f", azimuth)) }
        parts.append("\"pitch\":" + String(format: "%.1f", pitch))
        if let compass { parts.append("\"compass\":" + String(format: "%.1f", compass)) }
        return "{" + parts.joined(separator: ",") + "}"
    }
    /// The standard place format video files use for location (ISO 6709), for example +38.73170-082.99770+150.000/.
    static func iso6709(lat: Double, lng: Double, altitude: Double?) -> String {
        String(format: "%+09.5f%+010.5f", lat, lng) + (altitude.map { String(format: "%+.3f", $0) } ?? "") + "/"
    }
}
