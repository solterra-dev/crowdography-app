import AVKit
import SwiftUI

/// Plays one stored video piece, or shows one stored photo, straight from the account's storage.
struct FootageViewer: View {
    let item: FootageItem
    @ObservedObject var library: FootageLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var photo: UIImage?
    @State private var problem: String?
    /// Where it was filmed decides the time zone of its title (Jeff 2026-11-26).
    @State private var zone: TimeZone?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                } else if let photo {
                    Image(uiImage: photo).resizable().scaledToFit()
                } else if let problem {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(problem).font(.footnote).multilineTextAlignment(.center)
                        Button("Try again") { self.problem = nil; Task { await load() } }.buttonStyle(.bordered)
                    }
                    .foregroundStyle(.white).padding(32)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .bottomBar) { details }
            }
        }
        .task { await load() }
        .task(id: item.id) { if let la = item.lat, let lo = item.lng { zone = await TimeZoneBook.shared.zone(lat: la, lng: lo) } }
        .onDisappear { player?.pause() }
    }

    /// For example "Nov 26, 2026, 5:39 PM EST", in the time zone where it was filmed.
    private var titleText: String {
        let z = zone ?? .current
        let when = item.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: z))
        return when + (z.abbreviation(for: item.startedAt).map { " " + $0 } ?? "")
    }

    private var details: some View {
        HStack(spacing: 8) {
            Image(systemName: item.verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(item.verified ? .green : .orange)
            Text(item.verified ? "Verified original" : "Not verified")
            Text("·")
            Text(item.isVideo ? "\(item.lengthLabel) · \(item.sizeLabel)" : item.sizeLabel)
            if let gathering = item.gatheringName { Text("· \(gathering)") }
        }
        .font(.footnote).lineLimit(1).minimumScaleFactor(0.7)
    }

    private func load() async {
        do {
            let url = try await library.freshLink(for: item.id)
            if item.isVideo {
                // Sound plays even when the phone's ring switch is set to silent, as it does in the Photos app.
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                let p = AVPlayer(url: url)
                player = p
                p.play()
            } else {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, let cg = FootageLibrary.shrunken(data, longestSide: 2400) else {
                    problem = "The photo could not be opened."
                    return
                }
                photo = UIImage(cgImage: cg)
            }
        } catch { problem = error.localizedDescription }
    }
}
