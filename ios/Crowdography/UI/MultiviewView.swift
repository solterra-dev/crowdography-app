import AVFoundation
import QuartzCore
import SwiftUI
import UIKit

/// Four angles at once, like a control booth (Jeff 2026-11-26). All four run on one shared clock: each player is started
/// at the same instant of the phone's own clock at the right point of its clip, and checked every two seconds; one that
/// drifted (for example after a slow download) is put back on the clock. When an angle ends, its screen switches to
/// another angle of the same moment that is not already showing.
@MainActor
final class Multiview: ObservableObject {
    static let screens = 4
    @Published private(set) var slots: [GroupClip?] = Array(repeating: nil, count: screens)
    @Published private(set) var running: [Bool] = Array(repeating: false, count: screens)
    @Published private(set) var momentMs: Int
    @Published var soundSlot = 0 { didSet { applySound() } }
    @Published private(set) var note: String?

    let players: [AVPlayer] = (0..<screens).map { _ in AVPlayer() }
    private let source: GroupPlayback
    /// The shared clock: moment `clockMoment` happens at `clockHost` seconds of the phone's media clock.
    private var clockMoment: Int
    private var clockHost: CFTimeInterval = CACurrentMediaTime()
    private var loop: Task<Void, Never>?

    init(source: GroupPlayback, clips: [GroupClip], at moment: Int) {
        self.source = source
        momentMs = moment; clockMoment = moment
        for (i, c) in clips.prefix(Self.screens).enumerated() { slots[i] = c }
        for p in players { p.automaticallyWaitsToMinimizeStalling = false; p.isMuted = true }
    }

    var zone: TimeZone? { source.zone }

    func moment(atHost h: CFTimeInterval) -> Int { clockMoment + Int(((h - clockHost) * 1000).rounded()) }

    func start() async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<Self.screens { g.addTask { await self.prepare(i) } }
        }
        clockHost = CACurrentMediaTime() + 0.4   // a short lead so every screen starts on the same instant
        for i in 0..<Self.screens { startOnClock(i) }
        applySound()
        loop = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                n += 1
                await self.tick(checkDrift: n % 8 == 0)
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        for p in players { p.pause(); p.replaceCurrentItem(with: nil) }
    }

    /// Loads screen i's angle and waits until it can play (at most 8 seconds).
    private func prepare(_ i: Int) async {
        guard let c = slots[i], let url = await source.freshURL(for: c, tile: true) else { return }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 3
        players[i].replaceCurrentItem(with: item)
        for _ in 0..<80 where item.status == .unknown { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// Starts screen i at the point of its clip that matches the shared clock a moment from now.
    private func startOnClock(_ i: Int) {
        guard let c = slots[i], let item = players[i].currentItem, item.status == .readyToPlay else { running[i] = false; return }
        let host = CACurrentMediaTime() + 0.25
        let m = moment(atHost: host)
        guard m >= c.startMs, m < c.endMs else { players[i].pause(); running[i] = false; return }   // starts later, or already over
        let itemTime = CMTime(seconds: Double(m - c.startMs) / 1000, preferredTimescale: 600)
        players[i].setRate(1, time: itemTime, atHostTime: CMTime(seconds: host, preferredTimescale: 1_000_000_000))
        running[i] = true
    }

    private func tick(checkDrift: Bool) async {
        let now = CACurrentMediaTime()
        momentMs = moment(atHost: now)
        var shown = Set(slots.compactMap { $0?.id })
        for i in 0..<Self.screens {
            guard let c = slots[i] else { continue }
            if momentMs >= c.endMs - 150 {   // this angle is over: switch to another one of the same moment
                if let n = GroupTimeline.next(after: c, at: momentMs, in: source.clips, excluding: shown) {
                    shown.remove(c.id); shown.insert(n.clip.id)
                    slots[i] = n.clip; running[i] = false
                    note = "Screen \(i + 1) switched to \(n.clip.filmedBy ?? "another angle")"
                    await prepare(i); startOnClock(i)
                    clearNote(after: 3)
                } else if running[i] {
                    players[i].pause(); running[i] = false
                }
                continue
            }
            if !running[i] {
                if momentMs >= c.startMs {   // an angle that starts later has reached its start
                    if players[i].currentItem == nil { await prepare(i) }
                    startOnClock(i)
                }
                continue
            }
            if checkDrift, let item = players[i].currentItem, item.status == .readyToPlay {
                let expected = Double(momentMs - c.startMs) / 1000
                if abs(players[i].currentTime().seconds - expected) > 0.25 { startOnClock(i) }
            }
        }
        if slots.allSatisfy({ c in c.map { momentMs >= $0.endMs } ?? true }) && running.allSatisfy({ !$0 }) {
            note = "That is the end of these angles."
        }
    }

    private func clearNote(after seconds: UInt64) {
        let shownNote = note
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if self?.note == shownNote { self?.note = nil }
        }
    }

    private func applySound() { for (i, p) in players.enumerated() { p.isMuted = i != soundSlot } }
}

/// A plain video surface with no controls, for one screen of the four.
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> Surface {
        let v = Surface(); v.backgroundColor = .black
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }
    func updateUIView(_ v: Surface, context: Context) { if v.playerLayer.player !== player { v.playerLayer.player = player } }
}

struct MultiviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var booth: Multiview
    /// Called with an angle and the moment when a screen is opened on the big screen.
    let onBigScreen: (GroupClip, Int) -> Void

    init(source: GroupPlayback, clips: [GroupClip], at moment: Int, onBigScreen: @escaping (GroupClip, Int) -> Void) {
        _booth = StateObject(wrappedValue: Multiview(source: source, clips: clips, at: moment))
        self.onBigScreen = onBigScreen
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                    ForEach(0..<Multiview.screens, id: \.self) { screen($0) }
                }
                HStack {
                    Text(GroupTimeline.clockLabel(booth.momentMs, zone: booth.zone)).font(.title3.monospacedDigit().weight(.semibold))
                    Spacer()
                    if let n = booth.note { Text(n).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                }
                .padding(.horizontal)
                Text("Tap a screen to hear it. Tap the arrows to watch it on the big screen.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                Spacer()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Four screens")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .task { await booth.start() }
        .onDisappear { booth.stop() }
    }

    private func screen(_ i: Int) -> some View {
        let clip = booth.slots[i]
        return ZStack(alignment: .bottomLeading) {
            PlayerSurface(player: booth.players[i])
            if let c = clip, !booth.running[i], booth.momentMs < c.startMs {
                Text("Starts " + GroupTimeline.clockLabel(c.startMs, zone: booth.zone)).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if clip == nil {
                Image(systemName: "video.slash").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 4) {
                if booth.soundSlot == i { Image(systemName: "speaker.wave.2.fill") }
                Text(clip?.filmedBy ?? "Empty").lineLimit(1)
                Spacer(minLength: 0)
                if let c = clip {
                    Button { onBigScreen(c, booth.momentMs); dismiss() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .accessibilityLabel("Watch on the big screen")
                }
            }
            .font(.caption2.weight(.semibold)).padding(4).background(.black.opacity(0.55))
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(booth.soundSlot == i ? Color.red : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { booth.soundSlot = i }
    }
}
