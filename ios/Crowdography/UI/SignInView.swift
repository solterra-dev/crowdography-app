import SwiftUI

/// The way in (Jeff 2026-11-25): log in with an email address or mobile number and a password, create an account, or reset
/// a forgotten password. The first time an account is used on a phone, Chronum sends a 6-digit code, by email or by text,
/// to prove the address or number is real. Mobile numbers work only once the server has texting switched on.
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

    /// What was typed in the login field, when it is a usable email address or mobile number.
    private var login: LoginName? { LoginName.parse(email, phoneAllowed: model.phoneLoginOn) }

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
                if let login { run { await model.logIn(login: login, password: password) } }
            }
            .buttonStyle(.borderedProminent).disabled(login == nil || password.isEmpty || busy)
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
                .disabled(PersonName.tidy(name) == nil || login == nil || password.isEmpty || busy)
            link("I already have an account") { mode = .logIn }
        case .forgot:
            heading("Reset your password", model.phoneLoginOn ? "We send a 6-digit code to your email address or mobile number. Type it here with a new password." : "We email a 6-digit code to your address. Type it here with a new password.")
            emailField
            Button(busy ? "Sending…" : "Send me a code") {
                if let login { run { await model.startReset(login: login) } }
            }
            .buttonStyle(.borderedProminent).disabled(login == nil || busy)
            link("Back to log in") { mode = .logIn }
        }
    }

    private var emailField: some View {
        TextField(model.phoneLoginOn ? "Email or mobile number" : "Email address", text: $email)
            .keyboardType(.emailAddress).textContentType(.username)
            .textInputAutocapitalization(.never).autocorrectionDisabled().modifier(FieldLook())
    }

    // MARK: the code step

    @ViewBuilder private func codeStep(_ pending: AppModel.PendingCode) -> some View {
        let title = pending.login.isPhone ? "Check your texts" : "Check your email"
        let sent = (pending.login.isPhone ? "We texted" : "We sent") + " a 6-digit code to \(pending.login.shown)."
        switch pending.purpose {
        case .create: heading(title, sent + " Type it to finish creating your account.")
        case .login: heading(title, "This is the first time your account is used on this phone. " + sent)
        case .reset: heading(title, sent + " Type it with your new password.")
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
        guard let login, let tidy = PersonName.tidy(name) else { return }
        if let wrong = PasswordRule.problem(password, email: login.passwordMustNotBe) { problem = wrong; return }
        run { await model.createAccount(name: tidy, login: login, password: password) }
    }

    private func confirm(_ pending: AppModel.PendingCode) {
        if pending.purpose == .reset, let wrong = PasswordRule.problem(newPassword, email: pending.login.passwordMustNotBe) { problem = wrong; return }
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
