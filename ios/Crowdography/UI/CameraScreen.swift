import SwiftUI

struct CameraScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var recorder: Recorder
    @ObservedObject var queue: UploadQueue
    @State private var showJoin = false
    @State private var showUploads = false

    var body: some View {
        ZStack {
            CameraPreview(session: recorder.camera.session).ignoresSafeArea()
            VStack {
                topBar
                Spacer()
                if let p = recorder.problem { banner(p) }
                if let n = model.notice { banner(n).onTapGesture { model.notice = nil } }
                bottomBar
            }
            .padding()
        }
        .sheet(isPresented: $showJoin) { JoinSheet() }
        .sheet(isPresented: $showUploads) { UploadsView(queue: queue) }
    }

    private var topBar: some View {
        HStack {
            Button { showJoin = true } label: {
                Label(model.gatheringName ?? "Filming anywhere", systemImage: model.gatheringName == nil ? "globe" : "person.3")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            if recorder.isRecording, let start = recorder.pieceStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Piece \(recorder.pieceNo) · \(Self.clock(ctx.date.timeIntervalSince(start)))")
                        .font(.subheadline.monospacedDigit()).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.red.opacity(0.85), in: Capsule())
                }
            }
            Button { showUploads = true } label: {
                Label("\(queue.pendingCount)", systemImage: queue.pendingCount == 0 ? "checkmark.seal" : "arrow.up.circle")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            Picker("Mode", selection: $recorder.mode) {
                Text("Video").tag(Recorder.Mode.video)
                Text("Photo").tag(Recorder.Mode.photo)
            }
            .pickerStyle(.segmented).frame(width: 200).disabled(recorder.isRecording)
            Button {
                if recorder.mode == .video { recorder.toggleRecording() } else { recorder.takePhoto() }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 5).frame(width: 78, height: 78)
                    if recorder.mode == .video {
                        RoundedRectangle(cornerRadius: recorder.isRecording ? 6 : 31)
                            .fill(.red).frame(width: recorder.isRecording ? 30 : 62, height: recorder.isRecording ? 30 : 62)
                    } else {
                        Circle().fill(.white).frame(width: 62, height: 62)
                    }
                }
            }
            .accessibilityLabel(recorder.mode == .video ? (recorder.isRecording ? "Stop filming" : "Start filming") : "Take photo")
        }
    }

    private func banner(_ text: String) -> some View {
        Text(text).font(.footnote).padding(10).frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    static func clock(_ s: Double) -> String {
        let t = max(0, Int(s)); return String(format: "%d:%02d", t / 60, t % 60)
    }
}
