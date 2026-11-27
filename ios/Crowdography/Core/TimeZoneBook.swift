import CoreLocation
import Foundation

/// What a place is called and its time zone, from Apple's free place lookup (Jeff 2026-11-26: show times where the clip was
/// filmed, so a clip filmed near a time zone line shows that place's local time no matter where the viewer is; and group
/// your own footage by day and by place). Places a few kilometers apart share one lookup, and each answer is kept, so a group
/// of 100 clips needs only one or two lookups.
@MainActor
final class TimeZoneBook {
    struct Place: Equatable {
        let zone: TimeZone?
        /// For example "Portsmouth, OH".
        let name: String?
    }

    static let shared = TimeZoneBook()
    private var known: [String: Place] = [:]
    private var waiting: [String: Task<Place?, Never>] = [:]
    private let geocoder = CLGeocoder()
    private var chain: Task<Void, Never>?

    /// About 5 kilometers: close enough that two places in one square share a zone and a town, except right on a line.
    nonisolated static func key(lat: Double, lng: Double) -> String { String(format: "%.2f,%.2f", (lat * 20).rounded() / 20, (lng * 20).rounded() / 20) }

    func cached(lat: Double, lng: Double) -> TimeZone? { known[Self.key(lat: lat, lng: lng)]?.zone }
    func cachedPlace(lat: Double, lng: Double) -> Place? { known[Self.key(lat: lat, lng: lng)] }

    func zone(lat: Double, lng: Double) async -> TimeZone? { await place(lat: lat, lng: lng)?.zone }

    func place(lat: Double, lng: Double) async -> Place? {
        let k = Self.key(lat: lat, lng: lng)
        if let p = known[k] { return p }
        if let t = waiting[k] { return await t.value }
        let previous = chain
        let t = Task<Place?, Never> { [geocoder] in
            await previous?.value   // Apple allows one lookup at a time
            guard let m = (try? await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lng)))?.first else { return nil }
            let town = m.locality ?? m.subAdministrativeArea ?? m.name
            let name = [town, m.administrativeArea ?? m.country].compactMap { $0 }.joined(separator: ", ")
            return Place(zone: m.timeZone, name: name.isEmpty ? nil : name)
        }
        waiting[k] = t
        chain = Task { _ = await t.value }
        let p = await t.value
        waiting[k] = nil
        if let p { known[k] = p }
        return p
    }
}
