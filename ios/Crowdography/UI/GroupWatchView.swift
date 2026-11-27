import AVFoundation
import AVKit
import SwiftUI

/// Plays a group's angles on one shared clock (Jeff 2026-11-26). Tap an angle and it plays from the same moment;
/// when the angle being watched ends, it switches to another angle of the same moment that is still running.
@MainActor
final class GroupPlayback: ObservableObject {
    @Published private(set) var group: GroupSummary?
    @Published private(set) var clips: [GroupClip] = []
    @Published private(set) var current: GroupClip?
    /// The moment on the shared clock being watched, in milliseconds since 1970.
    @Published private(set) var momentMs: Int?
    @Published private(set) var loaded = false
    @Published var problem: String?
    @Published private(set) var note: String?

    let player = AVPlayer()
    private let groupId: String
    private let model: AppModel
    private var fetchedAt = Date.distantPast
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init(groupId: String, model: AppModel) {
        self.groupId = groupId
        self.model = model
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time) }
        }
    }

    func load() async {
        do {
            let r = try await model.groupFootage(groupId)
            group = r.group; clips = r.clips; fetchedAt = Date(); problem = nil
            if current == nil, let first = clips.first(where: { $0.isVideo }) { await play(first, at: first.startMs) }
        } catch { problem = error.localizedDescription }
        loaded = true
    }

    /// Tap on an angle: play it from the moment being watched if it covers that moment, otherwise from its start.
    func select(_ c: GroupClip) async {
        guard c.isVideo else { player.pause(); current = c; momentMs = c.startMs; return }
        if let t = momentMs, c.covers(t) { await play(c, at: t) } else { await play(c, at: c.startMs) }
    }

    /// A link to play angle c that is still good: the playback copy (or for the four-screen view, the small copy) when the
    /// filming phone has made one, otherwise the original. Links last 30 minutes, so the list is fetched again after 25.
    func freshURL(for c: GroupClip, tile: Bool = false) async -> URL? {
        var clip = c
        if Date().timeIntervalSince(fetchedAt) > 1500 {
            if let r = try? await model.groupFootage(groupId) { group = r.group ?? group; clips = r.clips; fetchedAt = Date() }
            clip = clips.first(where: { $0.id == c.id }) ?? c
        }
        if let u = tile ? clip.tileScreenURL : clip.bigScreenURL, Date().timeIntervalSince(fetchedAt) < 1500 { return u }
        return try? await model.groupLink(c.id)
    }

    /// Back from the four-screen view: play this angle on the big screen from that moment.
    func watch(_ c: GroupClip, at t: Int) async { await play(c, at: c.covers(t) ? t : c.startMs) }
    func pause() { player.pause() }

    private func play(_ c: GroupClip, at t: Int) async {
        do {
            guard let url = await freshURL(for: c) else { throw APIError(status: 0, code: "no_link", message: "Chronum did not give a link to that angle.") }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            let item = AVPlayerItem(url: url)
            if let o = endObserver { NotificationCenter.default.removeObserver(o) }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.ended(c.id) }
            }
            player.replaceCurrentItem(with: item)
            current = c; momentMs = t
            let offset = max(0, Double(t - c.startMs) / 1000)
            _ = await player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
        } catch { problem = error.localizedDescription }
    }

    private func tick(_ time: CMTime) {
        guard let c = current, c.isVideo, player.timeControlStatus == .playing, time.isNumeric else { return }
        momentMs = c.startMs + Int(time.seconds * 1000)
    }

    private func ended(_ id: String) async {
        guard let c = current, c.id == id else { return }
        if let n = GroupTimeline.next(after: c, at: c.endMs, in: clips) {
            note = "Switched to \(n.clip.filmedBy ?? "another angle")"
            await play(n.clip, at: n.atMs)
            let shown = n.clip.id
            Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if current?.id == shown { note = nil } }
        } else {
            note = "That is the end of this group's footage."
        }
    }

    func stop() {
        player.pause()
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
    }
}

struct GroupWatchView: View {
    @EnvironmentObject private var model: AppModel
    let summary: GroupSummary
    @StateObject private var playback: GroupPlayback
    @State private var filmingHere = false
    /// Picking angles for the four-screen view (Jeff 2026-11-26: select 4 feeds, like a control booth).
    @State private var picking = false
    @State private var picked: [String] = []
    @State private var booth: BoothStart?

    struct BoothStart: Identifiable { let id = UUID(); let clips: [GroupClip]; let at: Int }

    init(summary: GroupSummary, model: AppModel) {
        self.summary = summary
        _playback = StateObject(wrappedValue: GroupPlayback(groupId: summary.id, model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            screen
            info
            List {
                if let p = playback.problem { Text(p).font(.footnote).foregroundStyle(.orange) }
                if playback.loaded && playback.clips.isEmpty && playback.problem == nil {
                    Text("Nothing filmed in this group yet. Anyone in the group can tap Film to add an angle.").font(.footnote).foregroundStyle(.secondary)
                }
                if picking {
                    Text("Pick up to 4 videos for the four-screen view. Leave them unpicked to use the angles running at this moment.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(playback.clips) { row($0) }
            }
            .listStyle(.plain)
            .refreshable { await playback.load() }
        }
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    if playback.clips.contains(where: { $0.isVideo }) {
                        Button { picking.toggle(); picked = [] } label: { Image(systemName: picking ? "xmark" : "square.grid.2x2") }
                            .accessibilityLabel(picking ? "Stop picking" : "Four screens")
                    }
                    if let code = summary.joinCode {
                        ShareLink(item: "Join my Crowdography group \"\(summary.name)\" with the code \(code)") { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Share the group code")
                    }
                    if summary.isLive {
                        Button(model.currentGroupId == summary.id ? "Filming here" : "Film here") { model.useGroup(summary); filmingHere = true }
                            .disabled(model.currentGroupId == summary.id)
                    }
                }
            }
        }
        .alert("Filming into \(summary.name)", isPresented: $filmingHere) { Button("OK", role: .cancel) {} } message: {
            Text("Everything you film from now on goes into this group, until you leave it under Groups.")
        }
        .safeAreaInset(edge: .bottom) {
            if picking {
                Button { openBooth() } label: {
                    Text(picked.isEmpty ? "Watch four screens" : "Watch \(picked.count) on four screens").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.red).padding()
            }
        }
        .fullScreenCover(item: $booth) { b in
            MultiviewView(source: playback, clips: b.clips, at: b.at) { clip, t in Task { await playback.watch(clip, at: t) } }
        }
        .task { await playback.load() }
        .onDisappear { playback.stop() }
    }

    private var screen: some View {
        ZStack {
            Color.black
            if let c = playback.current, !c.isVideo, let u = c.viewURL {
                AsyncImage(url: u) { img in img.resizable().scaledToFit() } placeholder: { ProgressView().tint(.white) }
            } else if playback.current != nil {
                VideoPlayer(player: playback.player)
            } else if !playback.loaded {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "video.slash").font(.largeTitle).foregroundStyle(.secondary)
            }
            if let n = playback.note {
                Text(n).font(.footnote.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule()).frame(maxHeight: .infinity, alignment: .top).padding(.top, 8)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }

    private var info: some View {
        HStack {
            if let c = playback.current {
                Text(c.filmedBy ?? "Someone in the group").font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Spacer()
            if let t = playback.momentMs { Text(GroupTimeline.clockLabel(t)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func openBooth() {
        let now = playback.momentMs ?? playback.clips.first(where: { $0.isVideo })?.startMs ?? 0
        let chosen = picked.isEmpty ? GroupTimeline.fill(Multiview.screens, at: now, from: playback.clips)
                                    : playback.clips.filter { picked.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let at = chosen.contains(where: { $0.covers(now) }) ? now : (chosen.map(\.startMs).min() ?? now)
        playback.pause(); picking = false; picked = []
        booth = BoothStart(clips: chosen, at: at)
    }

    private func row(_ c: GroupClip) -> some View {
        let isCurrent = playback.current?.id == c.id
        let sameMoment = playback.momentMs.map { c.covers($0) } ?? false
        let isPicked = picked.contains(c.id)
        return Button {
            if picking {
                guard c.isVideo else { return }
                if isPicked { picked.removeAll { $0 == c.id } } else if picked.count < Multiview.screens { picked.append(c.id) }
            } else { Task { await playback.select(c) } }
        } label: {
            HStack(spacing: 12) {
                if picking {
                    Image(systemName: isPicked ? "checkmark.circle.fill" : "circle").foregroundStyle(isPicked ? .red : .secondary).font(.title3)
                }
                // The frame of this angle at the moment being watched, from its one-a-second strip (build 20).
                StripFrame(clip: c, momentMs: playback.momentMs)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(isCurrent ? Color.red : (sameMoment ? Color.green : Color.clear), lineWidth: 2))
                VStack(alignment: .leading, spacing: 2) {
                    Text((c.filmedBy ?? "Someone") + (c.isMine ? " (you)" : "")).font(.subheadline.weight(isCurrent ? .semibold : .regular)).lineLimit(1)
                    Text(GroupTimeline.clockLabel(c.startMs) + (sameMoment && !isCurrent ? " · same moment" : ""))
                        .font(.caption).foregroundStyle(sameMoment ? .green : .secondary)
                }
                Spacer()
                if c.isVideo { Text(c.lengthLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
        .listRowBackground(isCurrent ? Color.white.opacity(0.08) : Color.clear)
    }
}
