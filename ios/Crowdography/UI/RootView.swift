import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.phase {
        case .starting, .signingUp:
            SplashView()
        case .blocked(let why):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.shield").font(.system(size: 48))
                Text("This phone can't film with Crowdography").font(.headline).multilineTextAlignment(.center)
                Text(why).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { Task { await model.start() } }.buttonStyle(.borderedProminent)
            }
            .padding(32)
        case .problem(let title, let why):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 48))
                Text(title).font(.headline).multilineTextAlignment(.center)
                Text(why).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                Button("Try again") { Task { await model.start() } }.buttonStyle(.borderedProminent)
            }
            .padding(32)
        case .ready:
            CameraScreen(recorder: model.recorder, queue: model.queue)
        }
    }
}

/// The opening screen: the Crowdography mark and name while the phone is checked and the camera gets ready.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            VStack(spacing: 18) {
                Image("LaunchMark").resizable().scaledToFit().frame(width: 120, height: 120)
                Text("Crowdography").font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Text("Real footage, proven.").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                ProgressView().tint(.white).padding(.top, 24)
                Text("Checking this phone is genuine…").font(.footnote).foregroundStyle(.white.opacity(0.55))
            }
            .padding(32)
        }
    }
}
