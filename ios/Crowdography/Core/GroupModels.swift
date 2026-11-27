import Foundation

/// One group (Jeff 2026-11-26: a group code, then every angle of the same moment). Chronum calls these gatherings.
struct GroupSummary: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let isHost: Bool
    let isLive: Bool
    let startsAt: Date
    let endsAt: Date
    /// Only the host gets the code back.
    let joinCode: String?
    let clipCount: Int
    let phoneCount: Int
    /// Build 24: a moment, made automatically from clips filmed near each other at the same time outside any group.
    let isMoment: Bool
    let lat: Double?
    let lng: Double?

    init?(_ d: [String: Any]) {
        guard let id = d["gathering_id"] as? String, !id.isEmpty, let name = d["gathering_name"] as? String,
              let s = (d["starts_at"] as? String).flatMap(FootageItem.parseTime),
              let e = (d["ends_at"] as? String).flatMap(FootageItem.parseTime) else { return nil }
        self.id = id; self.name = name; startsAt = s; endsAt = e
        isHost = d["is_host"] as? Bool ?? false
        isLive = d["is_live"] as? Bool ?? false
        joinCode = d["join_code"] as? String
        clipCount = GroupClip.int(d["clip_count"]) ?? 0
        phoneCount = GroupClip.int(d["phone_count"]) ?? 0
        isMoment = (d["kind"] as? String) == "moment" || id.hasPrefix("moment-")
        lat = (d["lat"] as? NSNumber)?.doubleValue
        lng = (d["lng"] as? NSNumber)?.doubleValue
    }
}

/// One angle in a group: a photo or a video piece, with its exact start and end on the shared clock.
struct GroupClip: Identifiable, Equatable {
    let id: String
    let isVideo: Bool
    let mimeType: String
    /// Milliseconds since 1970, from the time the filming phone signed.
    let startMs: Int
    let endMs: Int
    let filmedBy: String?
    let isMine: Bool
    /// Tells apart two phones of the same person.
    let phoneKey: String
    let lat: Double?
    let lng: Double?
    let viewURL: URL?
    /// Viewing copies made by the filming phone (build 20). Nil until that phone has made them; the original is used instead.
    let playURL: URL?
    let tileURL: URL?
    /// One picture per minute, each holding a frame for every second (see StripLayout).
    let stripURLs: [URL]
    /// The signed camera path (build 21): where the phone was and which way it pointed through the clip.
    let pathURL: URL?
    /// True when the filming phone checked its clock against Chronum's, so start and end are on the server's clock.
    let clockChecked: Bool

    init?(_ d: [String: Any]) {
        guard let id = d["capture_id"] as? String, !id.isEmpty, let s = Self.int(d["start_ms"]), let e = Self.int(d["end_ms"]) else { return nil }
        self.id = id; startMs = s; endMs = max(s, e)
        isVideo = (d["kind"] as? String) != "photo"
        mimeType = d["mime_type"] as? String ?? ""
        filmedBy = d["filmed_by"] as? String
        isMine = d["is_mine"] as? Bool ?? false
        phoneKey = d["phone_key"] as? String ?? ""
        lat = (d["lat"] as? NSNumber)?.doubleValue
        lng = (d["lng"] as? NSNumber)?.doubleValue
        viewURL = (d["view_url"] as? String).flatMap { URL(string: $0) }
        let copies = d["copies"] as? [String: Any]
        playURL = (copies?["play"] as? String).flatMap { URL(string: $0) }
        tileURL = (copies?["tile"] as? String).flatMap { URL(string: $0) }
        stripURLs = (copies?["strips"] as? [String] ?? []).compactMap { URL(string: $0) }
        pathURL = (copies?["path"] as? String).flatMap { URL(string: $0) }
        clockChecked = d["clock_checked"] as? Bool ?? false
    }

    /// What the big screen plays: the playback copy when there is one, otherwise the original.
    var bigScreenURL: URL? { playURL ?? viewURL }
    /// What a quarter of the four-screen view plays.
    var tileScreenURL: URL? { tileURL ?? playURL ?? viewURL }

    static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    /// Is this angle running at moment t?
    func covers(_ t: Int) -> Bool { startMs <= t && t < endMs }
    var seconds: Int { (endMs - startMs) / 1000 }
    var lengthLabel: String { String(format: "%d:%02d", seconds / 60, seconds % 60) }
}

/// Choosing angles on the shared clock. Pure functions, so they are tested on their own.
enum GroupTimeline {
    /// Angles must still have this much left to be worth switching to.
    static let minimumLeftMs = 500

    /// The angle to switch to when `current` ends at moment t, and the moment to start it at:
    /// another video still running then (the one filmed closest to the current one, or the longest running if places are unknown),
    /// otherwise the next video to start after t, from its beginning. Nil when nothing is left.
    /// `excluding`: angles already on another screen (the four-screen view never shows one angle twice).
    static func next(after current: GroupClip, at t: Int, in clips: [GroupClip], excluding: Set<String> = []) -> (clip: GroupClip, atMs: Int)? {
        let clips = clips.filter { !excluding.contains($0.id) }
        let running = clips.filter { $0.isVideo && $0.id != current.id && $0.startMs <= t && $0.endMs > t + minimumLeftMs }
        if !running.isEmpty {
            let pick = running.min { a, b in
                switch (distance(current, a), distance(current, b)) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.endMs > b.endMs
                }
            }!
            return (pick, t)
        }
        if let later = clips.filter({ $0.isVideo && $0.id != current.id && $0.startMs > t }).min(by: { $0.startMs < $1.startMs }) {
            return (later, later.startMs)
        }
        return nil
    }

    /// Up to `count` videos to fill the four-screen view at moment t: the ones running then, longest left first,
    /// then the next ones to start.
    static func fill(_ count: Int, at t: Int, from clips: [GroupClip]) -> [GroupClip] {
        let videos = clips.filter { $0.isVideo }
        let running = videos.filter { $0.covers(t) }.sorted { $0.endMs > $1.endMs }
        let later = videos.filter { $0.startMs > t }.sorted { $0.startMs < $1.startMs }
        return Array((running + later).prefix(count))
    }

    /// Meters between where two angles were filmed, or nil when either place is unknown.
    static func distance(_ a: GroupClip, _ b: GroupClip) -> Double? {
        guard let la = a.lat, let oa = a.lng, let lb = b.lat, let ob = b.lng else { return nil }
        let x = (ob - oa) * cos((la + lb) / 2 * .pi / 180) * 111_320
        let y = (lb - la) * 110_540
        return (x * x + y * y).squareRoot()
    }

    /// 5:39:42.3 PM EST for a moment on the shared clock. Jeff 2026-11-26: shown in the time zone where the clip was
    /// filmed (worked out from its location), not the viewer's; the viewer's own zone only until that is known.
    static func clockLabel(_ ms: Int, zone: TimeZone? = nil) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm:ss.S a zzz"; f.timeZone = zone ?? .current
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
