import Foundation
import SwiftUI

/// Everything the screens need: sign-up state, the camera, the upload queue and the current gathering.
@MainActor
final class AppModel: ObservableObject {
    /// blocked: this phone may not film (failed the genuine-phone check, or the service is not offered here).
    /// problem: something else went wrong; shows a title and the exact reason, with a Try again button.
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
            await openCamera(began: began)
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

    /// The last stretch of getting ready: camera, photo-library permission, then the camera screen.
    private func openCamera(began: Date?) async {
        guard let id = deviceId, let k = key else { return }
        do { try await recorder.camera.configure() }
        catch { phase = .problem("The camera could not start", error.localizedDescription); return }
        await PhotoLibrarySaver.requestAccess()   // add-only; filming works either way
        if let began {   // keep the opening screen up long enough to be seen
            let shown = Date().timeIntervalSince(began)
            if shown < 1.2 { try? await Task.sleep(nanoseconds: UInt64((1.2 - shown) * 1_000_000_000)) }
        }
        queue.attach(deviceId: id, key: k)
        recorder.attach(deviceId: id, key: k)
        phase = .ready
    }

    // MARK: sign-in by email code

    /// The address the last code went to, while the app waits for the person to type the code.
    @Published private(set) var codeSentTo: String?
    private var signinId: String?

    /// Asks Chronum to email a 6-digit code. Returns what went wrong, or nil.
    func requestCode(email: String) async -> String? {
        guard let deviceId, let key else { return "This phone is not ready yet. Close the app and open it again." }
        do {
            let r = try await APIClient.shared.postSigned("/v1/crowd/signin/codes", ["email": email], deviceId: deviceId, key: key).body
            guard let sid = r["signin_id"] as? String else { return "Chronum did not confirm the code was sent. Try again." }
            signinId = sid; codeSentTo = email
            return nil
        } catch { return error.localizedDescription }
    }

    /// Checks the code. On success the phone belongs to the account; the camera opens, or the name step if the account has no name yet.
    func confirmCode(_ code: String) async -> String? {
        guard let deviceId, let key, let signinId else { return "Ask for a code first." }
        do {
            var body: [String: Any] = ["signin_id": signinId, "code": code]
            if let codeSentTo { body["email"] = codeSentTo }   // the code proves this address, so the server can keep it with the account
            let r = try await APIClient.shared.postSigned("/v1/crowd/signin/verify", body, deviceId: deviceId, key: key).body
            self.signinId = nil; codeSentTo = nil
            authorName = r["name"] as? String
            if (r["name_required"] as? Bool) == true { phase = .nameStep; return nil }
            phase = .signingUp
            await openCamera(began: nil)
            return nil
        } catch { return error.localizedDescription }
    }

    /// Saves the name footage is credited to, then opens the camera. Returns what went wrong, or nil.
    func saveName(_ name: String) async -> String? {
        guard let deviceId, let key else { return "This phone is not ready yet. Close the app and open it again." }
        do {
            let r = try await APIClient.shared.postSigned("/v1/crowd/account/profile", ["full_name": name], deviceId: deviceId, key: key).body
            authorName = r["name"] as? String ?? name
            phase = .signingUp
            await openCamera(began: nil)
            return nil
        } catch { return error.localizedDescription }
    }

    func useDifferentEmail() { signinId = nil; codeSentTo = nil }

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
