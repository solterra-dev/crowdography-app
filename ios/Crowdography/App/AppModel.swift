import Foundation
import SwiftUI

/// Everything the screens need: sign-up state, the camera, the upload queue and the current gathering.
@MainActor
final class AppModel: ObservableObject {
    /// blocked: this phone may not film (failed the genuine-phone check, or the service is not offered here).
    /// problem: something else went wrong; shows a title and the exact reason, with a Try again button.
    /// ready: signed in; the home screen with the account's footage is showing.
    /// signIn: the phone is genuine but nobody is signed in on it yet.
    /// nameStep: signed in, but the account has no name yet, so footage would have no author.
    enum Phase: Equatable { case starting, signingUp, signIn, nameStep, ready, blocked(String), problem(String, String) }
    @Published private(set) var phase: Phase = .starting
    /// The name footage from this account is credited to. Self-declared: nothing has checked it yet.
    @Published private(set) var authorName: String?
    @Published private(set) var gatheringName: String?
    @Published private(set) var hostSeesOriginals = false
    @Published var notice: String?

    let location = LocationProvider()
    let queue = UploadQueue()
    let library = FootageLibrary()
    lazy var recorder = Recorder(location: location, queue: queue)
    private(set) var deviceId: String?
    private var key: CaptureKey?

    func start() async {
        let began = Date()
        location.start()
        do {
            phase = .signingUp
            let k = try CaptureKey.loadOrCreate()
            let id = try await DeviceRegistrar.register()
            key = k; deviceId = id
            // Jeff 2026-11-21: sign in before filming. The server says whether this phone is signed in and whether sign-in is switched on.
            let s = try await APIClient.shared.postSigned("/v1/crowd/session", [:], deviceId: id, key: k).body
            if (s["signed_in"] as? Bool) != true && (s["sign_in_required"] as? Bool) == true { phase = .signIn; return }
            // Jeff 2026-11-22: every photo and video has a named author, so the account needs a name before filming.
            authorName = s["name"] as? String
            if (s["name_required"] as? Bool) == true { phase = .nameStep; return }
            await enterHome(began: began)
        } catch let e as APIError where ["not_genuine", "device_not_allowed", "region_not_served"].contains(e.code) {
            phase = .blocked(e.message)
        } catch let e as DeviceRegistrar.RegistrationError {
            phase = .blocked(e.localizedDescription)
        } catch let e as CaptureKey.KeyError {
            phase = .blocked(e.localizedDescription)
        } catch {
            phase = .problem("Can't reach Crowdography right now", error.localizedDescription)
        }
    }

    /// Signed in and named: show the home screen with the account's footage (Jeff 2026-11-25).
    /// The camera is not started here. It opens only when the person taps Film.
    private func enterHome(began: Date?) async {
        guard let id = deviceId, let k = key else { return }
        if let began {   // keep the opening screen up long enough to be seen
            let shown = Date().timeIntervalSince(began)
            if shown < 1.2 { try? await Task.sleep(nanoseconds: UInt64((1.2 - shown) * 1_000_000_000)) }
        }
        queue.attach(deviceId: id, key: k)     // uploads that were not finished carry on
        library.attach(deviceId: id, key: k)
        phase = .ready
    }

    /// Starts the camera when the camera screen opens. Returns what went wrong, or nil.
    func startCamera() async -> String? {
        guard let id = deviceId, let k = key else { return notReady }
        do { try await recorder.camera.configure() } catch { return error.localizedDescription }
        await PhotoLibrarySaver.requestAccess()   // add-only; filming works either way
        recorder.attach(deviceId: id, key: k)
        return nil
    }

    /// Turns the camera off when the person leaves the camera screen.
    func closeCamera() {
        if !recorder.isRecording { recorder.camera.stop() }
    }

    // MARK: login (Jeff 2026-11-25): email and password, plus a 6-digit emailed code the first time on each phone

    enum CodePurpose: String { case create, login, reset }
    /// Set while the app waits for the 6-digit code: where it was sent and what it is for.
    struct PendingCode: Equatable { let email: String; let purpose: CodePurpose }
    @Published private(set) var pendingCode: PendingCode?
    private var signinId: String?
    /// A new account's password and name wait here, in memory only, until the code is typed. Never saved, never logged.
    private var heldPassword: String?
    private var heldName: String?
    private let notReady = "This phone is not ready yet. Close the app and open it again."

    /// New account: Chronum checks the name, email and password, then emails a code. Nothing is saved until the code is typed.
    func createAccount(name: String, email: String, password: String) async -> String? {
        await askForCode(.create, email: email, password: password, name: name)
    }

    /// Log in. A phone that already proved this email goes straight in; any other phone is emailed a code first.
    func logIn(email: String, password: String) async -> String? {
        await askForCode(.login, email: email, password: password, name: nil)
    }

    /// Forgotten password: Chronum emails a code. The new password is typed with the code.
    func startReset(email: String) async -> String? {
        await askForCode(.reset, email: email, password: nil, name: nil)
    }

    private func askForCode(_ purpose: CodePurpose, email: String, password: String?, name: String?) async -> String? {
        guard let deviceId, let key else { return notReady }
        var body: [String: Any] = ["purpose": purpose.rawValue, "email": email]
        if let password { body["password"] = password }
        if let name { body["full_name"] = name }
        do {
            let r = try await APIClient.shared.postSigned("/v1/crowd/signin/codes", body, deviceId: deviceId, key: key).body
            if (r["signed_in"] as? Bool) == true { await finishSignIn(r); return nil }
            guard let sid = r["signin_id"] as? String else { return "Chronum did not confirm the code was sent. Try again." }
            signinId = sid
            heldPassword = purpose == .create ? password : nil
            heldName = name
            pendingCode = PendingCode(email: email, purpose: purpose)
            return nil
        } catch { return error.localizedDescription }
    }

    /// Checks the code. For a forgotten password, newPassword is the password to use from now on.
    /// On success the phone belongs to the account and the home screen opens.
    func confirmCode(_ code: String, newPassword: String? = nil) async -> String? {
        guard let deviceId, let key, let signinId, let pending = pendingCode else { return "Ask for a code first." }
        var body: [String: Any] = ["signin_id": signinId, "code": code, "email": pending.email]
        switch pending.purpose {
        case .create: body["password"] = heldPassword ?? ""; body["full_name"] = heldName ?? ""
        case .reset: body["password"] = newPassword ?? ""
        case .login: break
        }
        do {
            let r = try await APIClient.shared.postSigned("/v1/crowd/signin/verify", body, deviceId: deviceId, key: key).body
            await finishSignIn(r)
            return nil
        } catch { return error.localizedDescription }
    }

    private func finishSignIn(_ r: [String: Any]) async {
        forgetCode()
        authorName = r["name"] as? String
        if (r["name_required"] as? Bool) == true { phase = .nameStep; return }
        phase = .signingUp
        await enterHome(began: nil)
    }

    /// Leaves the code step and forgets what was typed.
    func forgetCode() { signinId = nil; pendingCode = nil; heldPassword = nil; heldName = nil }

    /// Signs this phone out. Waits until nothing is being filmed or still uploading, so no footage is left without its account.
    func signOut() async -> String? {
        guard let deviceId, let key else { return notReady }
        if recorder.isRecording { return "Stop filming first." }
        if queue.pendingCount > 0 { return "Wait until everything has finished uploading, then sign out." }
        do {
            _ = try await APIClient.shared.postSigned("/v1/crowd/signout", [:], deviceId: deviceId, key: key)
            leaveGathering()
            queue.forgetFinished()
            library.clear()
            recorder.camera.stop()
            authorName = nil; notice = nil
            phase = .signIn
            return nil
        } catch { return error.localizedDescription }
    }

    /// Saves the name footage is credited to, then opens the home screen. Returns what went wrong, or nil.
    func saveName(_ name: String) async -> String? {
        guard let deviceId, let key else { return "This phone is not ready yet. Close the app and open it again." }
        do {
            let r = try await APIClient.shared.postSigned("/v1/crowd/account/profile", ["full_name": name], deviceId: deviceId, key: key).body
            authorName = r["name"] as? String ?? name
            phase = .signingUp
            await enterHome(began: nil)
            return nil
        } catch { return error.localizedDescription }
    }

    func appBecameActive() { queue.kick() }

    /// Join a host's gathering with the 8-character code. Filming without one works anywhere, anytime (Jeff 2026-11-15).
    func join(code: String) async {
        guard let deviceId, let key else { return }
        do {
            let r = try await APIClient.shared.postSigned("/v1/crowd/gatherings/join", ["join_code": code.uppercased()], deviceId: deviceId, key: key).body
            guard let gid = r["gathering_id"] as? String else { return }
            gatheringName = r["gathering_name"] as? String
            hostSeesOriginals = r["host_sees_originals"] as? Bool ?? false
            notice = r["notice"] as? String
            recorder.gatheringChanged(gid)
        } catch {
            notice = error.localizedDescription
        }
    }

    func leaveGathering() {
        gatheringName = nil
        hostSeesOriginals = false
        recorder.gatheringChanged(nil)
    }
}
