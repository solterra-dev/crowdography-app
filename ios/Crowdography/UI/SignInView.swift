import SwiftUI

/// The way in (Jeff 2026-11-25): log in with an email and password, create an account, or reset a forgotten password.
/// The first time an account is used on a phone, Chronum emails a 6-digit code to prove the email address is real.
/// The code only works on this phone, once, for 10 minutes. The password is never saved or logged by the app.
struct SignInView: View {
    private enum Mode { case logIn, create, forgot }

    @EnvironmentObject private var model: AppModel
    @State private var mode: Mode = .logIn
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var newPassword = ""
    @State private var code = ""
    @State private var busy = false
    @State private var problem: String?

    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    Image("LaunchMark").resizable().scaledToFit().frame(width: 72, height: 72).padding(.top, 24)
                    if let pending = model.pendingCode { codeStep(pending) } else { form }
                    if let problem {
                        Text(problem).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                    }
                }
                .padding(32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: the three forms

    @ViewBuilder private var form: some View {
        switch mode {
        case .logIn:
            heading("Log in", "Your footage is kept under your account.")
            emailField
            SecureField("Password", text: $password).textContentType(.password).modifier(FieldLook())
            Button(busy ? "Logging in…" : "Log in") {
                run { await model.logIn(email: cleanEmail, password: password) }
            }
            .buttonStyle(.borderedProminent).disabled(!cleanEmail.contains("@") || password.isEmpty || busy)
            link("Create an account") { mode = .create }
            link("Forgot your password") { mode = .forgot }
        case .create:
            heading("Create your account", "Every photo and video you film is credited to you. Use your real, full name.")
            TextField("Full name", text: $name)
                .textContentType(.name).textInputAutocapitalization(.words).autocorrectionDisabled().modifier(FieldLook())
            emailField
            SecureField("Password", text: $password).textContentType(.newPassword).modifier(FieldLook())
            Text("At least \(PasswordRule.minLength) characters. A few words in a row work well.")
                .font(.caption).foregroundStyle(.white.opacity(0.55))
            Button(busy ? "Checking…" : "Create account") { create() }
                .buttonStyle(.borderedProminent)
                .disabled(PersonName.tidy(name) == nil || !cleanEmail.contains("@") || password.isEmpty || busy)
            link("I already have an account") { mode = .logIn }
        case .forgot:
            heading("Reset your password", "We email a 6-digit code to your address. Type it here with a new password.")
            emailField
            Button(busy ? "Sending…" : "Email me a code") {
                run { await model.startReset(email: cleanEmail) }
            }
            .buttonStyle(.borderedProminent).disabled(!cleanEmail.contains("@") || busy)
            link("Back to log in") { mode = .logIn }
        }
    }

    private var emailField: some View {
        TextField("Email address", text: $email)
            .keyboardType(.emailAddress).textContentType(.username)
            .textInputAutocapitalization(.never).autocorrectionDisabled().modifier(FieldLook())
    }

    // MARK: the code step

    @ViewBuilder private func codeStep(_ pending: AppModel.PendingCode) -> some View {
        switch pending.purpose {
        case .create: heading("Check your email", "We sent a 6-digit code to \(pending.email). Type it to finish creating your account.")
        case .login: heading("Check your email", "This is the first time your account is used on this phone, so we sent a 6-digit code to \(pending.email).")
        case .reset: heading("Check your email", "We sent a 6-digit code to \(pending.email). Type it with your new password.")
        }
        TextField("6-digit code", text: $code)
            .keyboardType(.numberPad).textContentType(.oneTimeCode)
            .multilineTextAlignment(.center).font(.title2.monospacedDigit()).modifier(FieldLook())
            .onChange(of: code) { _, v in code = String(v.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
        if pending.purpose == .reset {
            SecureField("New password", text: $newPassword).textContentType(.newPassword).modifier(FieldLook())
            Text("At least \(PasswordRule.minLength) characters.").font(.caption).foregroundStyle(.white.opacity(0.55))
        }
        Button(busy ? "Checking…" : (pending.purpose == .reset ? "Save new password" : "Continue")) { confirm(pending) }
            .buttonStyle(.borderedProminent)
            .disabled(code.count != 6 || busy || (pending.purpose == .reset && newPassword.isEmpty))
        link("Start over") { code = ""; newPassword = ""; problem = nil; model.forgetCode() }
    }

    // MARK: actions

    private func create() {
        if let wrong = PasswordRule.problem(password, email: cleanEmail) { problem = wrong; return }
        guard let tidy = PersonName.tidy(name) else { return }
        run { await model.createAccount(name: tidy, email: cleanEmail, password: password) }
    }

    private func confirm(_ pending: AppModel.PendingCode) {
        if pending.purpose == .reset, let wrong = PasswordRule.problem(newPassword, email: pending.email) { problem = wrong; return }
        run { await model.confirmCode(code, newPassword: pending.purpose == .reset ? newPassword : nil) }
    }

    private func run(_ work: @escaping () async -> String?) {
        busy = true
        problem = nil
        Task {
            problem = await work()
            busy = false
        }
    }

    // MARK: small pieces

    @ViewBuilder private func heading(_ title: String, _ text: String) -> some View {
        Text(title).font(.title2.weight(.semibold)).foregroundStyle(.white)
        Text(text).font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
    }

    private func link(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title) { problem = nil; action() }.font(.footnote).disabled(busy)
    }
}

private struct FieldLook: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(12).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}
