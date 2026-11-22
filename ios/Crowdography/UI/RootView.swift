import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.phase {
        case .starting, .signingUp:
            VStack(spacing: 16) {
                ProgressView()
                Text("Checking this phone is genuine…").font(.headline)
                Text("Crowdography only films on phones that can prove it, so your footage can be trusted.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(32)
        case .blocked(let why):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.shield").font(.system(size: 48))
                Text("This phone can't film with Crowdography").font(.headline).multilineTextAlignment(.center)
                Text(why).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { Task { await model.start() } }.buttonStyle(.borderedProminent)
            }
            .padding(32)
        case .offline(let why):
            VStack(spacing: 16) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 48))
                Text("Can't reach Crowdography right now").font(.headline).multilineTextAlignment(.center)
                Text(why).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { Task { await model.start() } }.buttonStyle(.borderedProminent)
            }
            .padding(32)
        case .ready:
            CameraScreen(recorder: model.recorder, queue: model.queue)
        }
    }
}
