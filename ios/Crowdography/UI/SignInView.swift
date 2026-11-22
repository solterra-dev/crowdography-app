import SwiftUI

/// Sign in before filming (Jeff 2026-11-21): type an email, get a 6-digit code, type the code. No password.
/// The code only works on this phone, once, for 10 minutes.
struct SignInView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var code = ""
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            VStack(spacing: 18) {
                Image("LaunchMark").resizable().scaledToFit().frame(width: 72, height: 72)
                Text("Sign in to film").font(.title2.weight(.semibold)).foregroundStyle(.white)
                Text("Your footage is kept under your account, so it follows you to any phone you sign in on. We email you a 6-digit code. There is no password.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)

                if let sent = model.codeSentTo {
                    Text("Code sent to \(sent)").font(.subheadline).foregroundStyle(.white)
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center).font(.title2.monospacedDigit())
                        .padding(12).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        .onChange(of: code) { _, v in code = String(v.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
                    Button(busy ? "Checking…" : "Sign in") { run { await model.confirmCode(code) } }
                        .buttonStyle(.borderedProminent).disabled(code.count != 6 || busy)
                    Button("Use a different email") { code = ""; problem = nil; model.useDifferentEmail() }
                        .font(.footnote)
                } else {
                    TextField("Email address", text: $email)
                        .keyboardType(.emailAddress).textContentType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(12).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    Button(busy ? "Sending…" : "Email me a code") {
                        run { await model.requestCode(email: email.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    }
                    .buttonStyle(.borderedProminent).disabled(!email.contains("@") || busy)
                }

                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }
            .padding(32)
        }
    }

    private func run(_ work: @escaping () async -> String?) {
        busy = true
        problem = nil
        Task {
            problem = await work()
            busy = false
        }
    }
}
