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
    /// Every video running at moment t, placed where it was at that moment and turned the way it pointed. The angle being
    /// watched is always shown. With no moment yet, every video at its starting place.
    static func markers(_ clips: [GroupClip], paths: [String: CameraPath], at t: Int?, current: String?) -> [CameraMarker] {
        clips.compactMap { c in
            guard c.isVideo else { return nil }
            let isCurrent = c.id == current
            guard t == nil || isCurrent || c.covers(t!) else { return nil }
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

/// A video camera symbol with the person's initials in it, turned the way the camera pointed.
struct CameraSymbol: View {
    let initials: String
    let azimuth: Double?
    let current: Bool

    var body: some View {
        let turn = (azimuth ?? 90) - 90   // the symbol's lens faces east before it is turned
        let color: Color = current ? .red : .blue
        return ZStack {
            if let az = azimuth {
                ViewCone().fill(color.opacity(0.22)).frame(width: 84, height: 84).rotationEffect(.degrees(az))
            }
            ZStack {
                Image(systemName: "video.fill").font(.system(size: 30)).foregroundStyle(color)
                    .shadow(color: .black.opacity(0.4), radius: 1)
                Text(initials).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .rotationEffect(.degrees(-turn)).offset(x: -3)
            }
            .rotationEffect(.degrees(turn))
            .opacity(azimuth == nil ? 0.75 : 1)
        }
        .frame(width: 84, height: 84)
        .scaleEffect(current ? 1.15 : 1)
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
                    CameraSymbol(initials: Initials.of(m.clip.filmedBy), azimuth: m.azimuth, current: m.isCurrent)
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
