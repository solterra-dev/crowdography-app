import Foundation

/// Your own footage grouped by day and by place (Jeff 2026-11-26), newest first. A new section starts whenever the day or
/// the place changes, so a day spent in two towns shows as two sections. The day is the day where it was filmed.
struct FootageSection: Identifiable, Equatable {
    let id: String
    /// The day, in the time zone where the first clip in the section was filmed.
    let day: Date
    let zone: TimeZone
    /// The place key (see TimeZoneBook.key), or nil when the clips have no location.
    let placeKey: String?
    let items: [FootageItem]
}

enum FootageSections {
    /// Groups items (already newest first). `zoneFor` gives each place key's time zone when known.
    static func group(_ items: [FootageItem], zoneFor: (String?) -> TimeZone?) -> [FootageSection] {
        var out: [FootageSection] = []
        var cur: (day: String, place: String?, zone: TimeZone, items: [FootageItem])?
        func close() {
            guard let c = cur, let first = c.items.first else { return }
            var cal = Calendar(identifier: .gregorian); cal.timeZone = c.zone
            out.append(FootageSection(id: c.day + "|" + (c.place ?? "-") + "|" + first.id, day: cal.startOfDay(for: first.startedAt), zone: c.zone, placeKey: c.place, items: c.items))
        }
        for item in items {
            let place = placeKey(item)
            let zone = zoneFor(place) ?? .current
            let day = dayKey(item.startedAt, zone)
            if let c = cur, c.day == day, c.place == place { cur!.items.append(item); continue }
            close()
            cur = (day, place, zone, [item])
        }
        close()
        return out
    }

    static func placeKey(_ item: FootageItem) -> String? {
        guard let la = item.lat, let lo = item.lng else { return nil }
        return TimeZoneBook.key(lat: la, lng: lo)
    }

    static func dayKey(_ date: Date, _ zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// For example "Thursday, November 26".
    static func dayTitle(_ s: FootageSection) -> String {
        let f = DateFormatter(); f.timeZone = s.zone; f.dateFormat = "EEEE, MMMM d"
        var cal = Calendar(identifier: .gregorian); cal.timeZone = s.zone
        if cal.component(.year, from: s.day) != cal.component(.year, from: Date()) { f.dateFormat = "EEEE, MMMM d, yyyy" }
        return f.string(from: s.day)
    }
}
