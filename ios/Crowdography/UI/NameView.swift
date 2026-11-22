import SwiftUI

/// The author's name (Jeff 2026-11-22): every photo and video is credited to a named person.
/// Asked once, right after the first sign-in. The name is what the person types; nothing has checked it yet.
struct NameView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            VStack(spacing: 18) {
                Image("LaunchMark").resizable().scaledToFit().frame(width: 72, height: 72)
                Text("Your name").font(.title2.weight(.semibold)).foregroundStyle(.white)
                Text("Every photo and video you film is credited to you. Use your real, full name.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)

                TextField("Full name", text: $name)
                    .textContentType(.name).textInputAutocapitalization(.words).autocorrectionDisabled()
                    .submitLabel(.done).onSubmit { save() }
                    .padding(12).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                Button(busy ? "Saving…" : "Continue") { save() }
                    .buttonStyle(.borderedProminent).disabled(PersonName.tidy(name) == nil || busy)

                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }
            .padding(32)
        }
    }

    private func save() {
        guard !busy, let tidy = PersonName.tidy(name) else { return }
        busy = true
        problem = nil
        Task {
            problem = await model.saveName(tidy)
            busy = false
        }
    }
}
