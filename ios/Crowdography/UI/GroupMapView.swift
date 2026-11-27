import MapKit
import SwiftUI

/// Downloads each angle's signed camera path once, for the map.
@MainActor
final class PathStore: ObservableObject {
    @Published private(set) var paths: [String: CameraPath] = [:]
    private var asked: Set<String> = []

    func want(_ clips: [GroupClip]) {
        for c in clips where !asked.contains(c.id) {
            guard let u = c.pathURL else { continue }
            asked.insert(c.id)
            let id = c.id
            Task {
                guard let r = try? await URLSession.shared.data(from: u), ((r.1 as? HTTPURLResponse)?.statusCode ?? 0) == 200,
                      let p = CameraPath(data: r.0) else { asked.remove(id); return }
                paths[id] = p
            }
        }
    }
}

/// One camera on the map at the moment being watched.
struct CameraMarker: Identifiable, Equatable {
    let id: String
    let clip: GroupClip
    let lat: Double
    let lng: Double
    /// Which way it pointed, 0 north and 90 east; nil when unknown (clips filmed before build 21).
    let azimuth: Double?
    let isCurrent: Bool
}

enum GroupMap {
    /// A photo shows on the map this long either side of the moment it was taken (build 24).
    static let photoShownMs = 5000

    /// Every video running at moment t, and every photo taken within 5 seconds of it, placed where it was at that moment and
    /// turned the way it pointed. The angle being watched is always shown. With no moment yet, everything at its start.
    static func markers(_ clips: [GroupClip], paths: [String: CameraPath], at t: Int?, current: String?) -> [CameraMarker] {
        clips.compactMap { c in
            let isCurrent = c.id == current
            let showing = c.isVideo ? t.map { c.covers($0) } ?? true : t.map { abs($0 - c.startMs) <= photoShownMs } ?? true
            guard isCurrent || showing else { return nil }
            let offset = Double(min(max((t ?? c.startMs) - c.startMs, 0), c.endMs - c.startMs))
            if let pose = paths[c.id]?.pose(at: offset) {
                return CameraMarker(id: c.id, clip: c, lat: pose.lat, lng: pose.lng, azimuth: pose.azimuth, isCurrent: isCurrent)
            }
            guard let lat = c.lat, let lng = c.lng else { return nil }
            return CameraMarker(id: c.id, clip: c, lat: lat, lng: lng, azimuth: nil, isCurrent: isCurrent)
        }
    }

    /// A map area showing every place in the group, with a little room around it.
    static func region(_ clips: [GroupClip]) -> MKCoordinateRegion? {
        let pts = clips.compactMap { c in c.lat.flatMap { la in c.lng.map { (la, $0) } } }
        guard let minLat = pts.map(\.0).min(), let maxLat = pts.map(\.0).max(), let minLng = pts.map(\.1).min(), let maxLng = pts.map(\.1).max() else { return nil }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2),
                                  span: MKCoordinateSpan(latitudeDelta: max(0.004, (maxLat - minLat) * 1.6), longitudeDelta: max(0.004, (maxLng - minLng) * 1.6)))
    }
}

/// The black "C" around each person's circle (Jeff 2026-11-26, from the Crowdography logo). Its opening faces east before
/// it is turned, the way the logo's C opens to the right.
struct LogoC: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), radius = min(r.width, r.height) / 2
        for (i, a) in stride(from: 38.0, through: 322.0, by: 4.0).enumerated() {
            let pt = CGPoint(x: c.x + radius * cos(a * .pi / 180), y: c.y + radius * sin(a * .pi / 180))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// The wedge showing what the camera could see, pointing north before it is turned.
struct ViewCone: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        p.move(to: c)
        p.addArc(center: c, radius: r.width / 2, startAngle: .degrees(-90 - 26), endAngle: .degrees(-90 + 26), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// One person on the map (Jeff 2026-11-26): the Crowdography mark. A red circle with their initials on top, inside a black
/// C whose opening faces the way their camera pointed. The angle being watched is larger and shows what its camera saw.
/// When the direction is unknown (clips filmed before build 23) the C opens to the right, like the logo, and is lighter.
struct CrowdMarker: View {
    static let red = Color(red: 0.93, green: 0.27, blue: 0.24)
    let initials: String
    let azimuth: Double?
    let current: Bool

    var body: some View {
        ZStack {
            if current, let az = azimuth {
                ViewCone().fill(Self.red.opacity(0.22)).frame(width: 96, height: 96).rotationEffect(.degrees(az))
            }
            Circle().fill(.white).frame(width: 40, height: 40)
            LogoC().stroke(.black, style: StrokeStyle(lineWidth: 5, lineCap: .butt)).frame(width: 38, height: 38)
                .rotationEffect(.degrees((azimuth ?? 90) - 90))
            Circle().fill(Self.red).frame(width: 27, height: 27)
            Text(initials).font(.system(size: 11, weight: .heavy)).foregroundStyle(.white).minimumScaleFactor(0.6).lineLimit(1).frame(width: 24)
        }
        .frame(width: 96, height: 96)
        .opacity(azimuth == nil ? 0.8 : 1)
        .scaleEffect(current ? 1.2 : 0.95)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

/// The map under the video (Jeff 2026-11-26): every camera filming at the moment being watched, with the person's
/// initials, moving along its path and turned the way it pointed. The one being watched is red. Tap one to watch it.
struct GroupMapView: View {
    @ObservedObject var playback: GroupPlayback
    @StateObject private var store = PathStore()
    @State private var position: MapCameraPosition = .automatic
    @State private var framed = false

    var body: some View {
        let t = playback.momentMs.map { $0 / 250 * 250 }
        let marks = GroupMap.markers(playback.clips, paths: store.paths, at: t, current: playback.current?.id)
        return Map(position: $position, interactionModes: [.pan, .zoom]) {   // no turning, so north stays up and the symbols stay true
            ForEach(marks) { m in
                Annotation(m.clip.filmedBy ?? "Someone", coordinate: CLLocationCoordinate2D(latitude: m.lat, longitude: m.lng), anchor: .center) {
                    CrowdMarker(initials: Initials.of(m.clip.filmedBy), azimuth: m.azimuth, current: m.isCurrent)
                        .onTapGesture { Task { await playback.select(m.clip) } }
                        .accessibilityLabel("\(m.clip.filmedBy ?? "Someone")'s camera")
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .overlay(alignment: .bottomLeading) {
            if marks.isEmpty && playback.loaded {
                Text("No camera is filming at this moment.").font(.caption2).padding(6).background(.ultraThinMaterial, in: Capsule()).padding(8)
            }
        }
        .onAppear { refresh() }
        .onChange(of: playback.clips) { refresh() }
    }

    private func refresh() {
        store.want(playback.clips)
        if !framed, let r = GroupMap.region(playback.clips) { position = .region(r); framed = true }
    }
}
