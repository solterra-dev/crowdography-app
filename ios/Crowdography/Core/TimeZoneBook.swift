import CoreLocation
import Foundation

/// The time zone of a place, from Apple's free place lookup (Jeff 2026-11-26: show times where the clip was filmed, so a
/// clip filmed near a time zone line shows that place's local time no matter where the viewer is). Places a few kilometers
/// apart share one lookup, and each answer is kept, so a group of 100 clips needs only one or two lookups.
@MainActor
final class TimeZoneBook {
    static let shared = TimeZoneBook()
    private var known: [String: TimeZone] = [:]
    private var waiting: [String: Task<TimeZone?, Never>] = [:]
    private let geocoder = CLGeocoder()
    private var chain: Task<Void, Never>?

    /// About 5 kilometers: close enough that two places in one square share a zone, except right on a line.
    nonisolated static func key(lat: Double, lng: Double) -> String { String(format: "%.2f,%.2f", (lat * 20).rounded() / 20, (lng * 20).rounded() / 20) }

    func cached(lat: Double, lng: Double) -> TimeZone? { known[Self.key(lat: lat, lng: lng)] }

    func zone(lat: Double, lng: Double) async -> TimeZone? {
        let k = Self.key(lat: lat, lng: lng)
        if let z = known[k] { return z }
        if let t = waiting[k] { return await t.value }
        let previous = chain
        let t = Task<TimeZone?, Never> { [geocoder] in
            await previous?.value   // Apple allows one lookup at a time
            let marks = try? await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lng))
            return marks?.first?.timeZone
        }
        waiting[k] = t
        chain = Task { _ = await t.value }
        let z = await t.value
        waiting[k] = nil
        if let z { known[k] = z }
        return z
    }
}
