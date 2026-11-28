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
    /// True when the server can text codes, so a mobile number works as a login (Jeff 2026-11-25).
    @Published private(set) var phoneLoginOn = false
    @Published private(set) var gatheringName: String?
    /// The group new footage is filmed into, or nil to film anywhere.
    @Published private(set) var currentGroupId: String?
    @Published private(set) var hostSeesOriginals = false
    @Published var notice: String?

    let location = LocationProvider()
    let queue = UploadQueue.shared
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
            let s = try await APIClient.shared.postSigned("/v1/accounts/session", [:], deviceId: id, key: k).body
            phoneLoginOn = (s["phone_login"] as? Bool) == true
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

    // MARK: login (Jeff 2026-11-25): an email address or mobile number and a password, plus a 6-digit code the first time on each phone

    enum CodePurpose: String { case create, login, reset }
    /// Set while the app waits for the 6-digit code: where it was sent (by email or by text) and what it is for.
    struct PendingCode: Equatable { let login: LoginName; let purpose: CodePurpose }
    @Published private(set) var pendingCode: PendingCode?
    private var signinId: String?
    /// A new account's password and name wait here, in memory only, until the code is typed. Never saved, never logged.
    private var heldPassword: String?
    private var heldName: String?
    private let notReady = "This phone is not ready yet. Close the app and open it again."

    /// New account: Chronum checks the name, login and password, then sends a code. Nothing is saved until the code is typed.
    func createAccount(name: String, login: LoginName, password: String) async -> String? {
        await askForCode(.create, login: login, password: password, name: name)
    }

    /// Log in. A phone that already proved this login goes straight in; any other phone is sent a code first.
    func logIn(login: LoginName, password: String) async -> String? {
        await askForCode(.login, login: login, password: password, name: nil)
    }

    /// Forgotten password: Chronum sends a code. The new password is typed with the code.
    func startReset(login: LoginName) async -> String? {
        await askForCode(.reset, login: login, password: nil, name: nil)
    }

    private func askForCode(_ purpose: CodePurpose, login: LoginName, password: String?, name: String?) async -> String? {
        guard let deviceId, let key else { return notReady }
        var body: [String: Any] = ["purpose": purpose.rawValue, login.field: login.value]
        if let password { body["password"] = password }
        if let name { body["full_name"] = name }
        do {
            let r = try await APIClient.shared.postSigned("/v1/accounts/signin/codes", body, deviceId: deviceId, key: key).body
            if (r["signed_in"] as? Bool) == true { await finishSignIn(r); return nil }
            guard let sid = r["signin_id"] as? String else { return "Chronum did not confirm the code was sent. Try again." }
            signinId = sid
            heldPassword = purpose == .create ? password : nil
            heldName = name
            pendingCode = PendingCode(login: login, purpose: purpose)
            return nil
        } catch { return error.localizedDescription }
    }

    /// Checks the code. For a forgotten password, newPassword is the password to use from now on.
    /// On success the phone belongs to the account and the home screen opens.
    func confirmCode(_ code: String, newPassword: String? = nil) async -> String? {
        guard let deviceId, let key, let signinId, let pending = pendingCode else { return "Ask for a code first." }
        var body: [String: Any] = ["signin_id": signinId, "code": code, pending.login.field: pending.login.value]
        switch pending.purpose {
        case .create: body["password"] = heldPassword ?? ""; body["full_name"] = heldName ?? ""
        case .reset: body["password"] = newPassword ?? ""
        case .login: break
        }
        do {
            let r = try await APIClient.shared.postSigned("/v1/accounts/signin/verify", body, deviceId: deviceId, key: key).body
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
            _ = try await APIClient.shared.postSigned("/v1/accounts/signout", [:], deviceId: deviceId, key: key)
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
            let r = try await APIClient.shared.postSigned("/v1/accounts/profile", ["full_name": name], deviceId: deviceId, key: key).body
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
            let r = try await APIClient.shared.postSigned("/v1/gatherings/join", ["join_code": code.uppercased()], deviceId: deviceId, key: key).body
            guard let gid = r["gathering_id"] as? String else { return }
            gatheringName = r["gathering_name"] as? String
            currentGroupId = gid
            hostSeesOriginals = r["host_sees_originals"] as? Bool ?? false
            notice = r["notice"] as? String
            recorder.gatheringChanged(gid)
        } catch {
            notice = error.localizedDescription
        }
    }

    func leaveGathering() {
        gatheringName = nil
        currentGroupId = nil
        hostSeesOriginals = false
        recorder.gatheringChanged(nil)
    }

    // MARK: groups (Jeff 2026-11-26: a group code, then every angle of the same moment)

    struct StartedGroup: Identifiable { let id: String; let name: String; let code: String }

    /// Starts a group around where this phone is now, lasting `hours`, and films into it from now on. The code is shown to share.
    func startGroup(name: String, hours: Int) async throws -> StartedGroup {
        guard let deviceId, let key else { throw APIError(status: 0, code: "not_ready", message: notReady) }
        guard let fix = location.currentFix else {
            throw APIError(status: 0, code: "no_location", message: "Waiting for your location. Make sure Crowdography may use your location, then try again.")
        }
        let iso = ISO8601DateFormatter()
        let body: [String: Any] = ["gathering_name": name, "gathering_kind": "public_gathering",
                                   "starts_at": iso.string(from: Date().addingTimeInterval(-60)), "ends_at": iso.string(from: Date().addingTimeInterval(Double(hours) * 3600)),
                                   "area_lat": fix.coordinate.latitude, "area_lng": fix.coordinate.longitude, "area_radius_m": 5000]
        let r = try await APIClient.shared.postSigned("/v1/gatherings", body, deviceId: deviceId, key: key).body
        guard let gid = r["gathering_id"] as? String, let code = r["join_code"] as? String else {
            throw APIError(status: 0, code: "no_group", message: "Chronum did not confirm the group. Try again.")
        }
        gatheringName = name; currentGroupId = gid; hostSeesOriginals = false; notice = nil
        recorder.gatheringChanged(gid)
        return StartedGroup(id: gid, name: name, code: code)
    }

    /// Films into one of your groups from now on.
    func useGroup(_ g: GroupSummary) {
        gatheringName = g.name; currentGroupId = g.id; hostSeesOriginals = !g.isHost
        recorder.gatheringChanged(g.id)
    }

    func myGroups() async throws -> [GroupSummary] {
        guard let deviceId, let key else { throw APIError(status: 0, code: "not_ready", message: notReady) }
        let r = try await APIClient.shared.postSigned("/v1/gatherings/mine", [:], deviceId: deviceId, key: key).body
        return (r["groups"] as? [[String: Any]] ?? []).compactMap(GroupSummary.init)
    }

    /// Every angle in a group (or a moment, build 24), in the order they started.
    func groupFootage(_ id: String) async throws -> (group: GroupSummary?, clips: [GroupClip]) {
        guard let deviceId, let key else { throw APIError(status: 0, code: "not_ready", message: notReady) }
        let r = id.hasPrefix("moment-")
            ? try await APIClient.shared.postSigned("/v1/moments/footage", ["moment_id": id], deviceId: deviceId, key: key).body
            : try await APIClient.shared.postSigned("/v1/gatherings/footage", ["gathering_id": id], deviceId: deviceId, key: key).body
        return ((r["group"] as? [String: Any]).flatMap(GroupSummary.init), (r["items"] as? [[String: Any]] ?? []).compactMap(GroupClip.init))
    }

    /// A fresh private link to one angle in a group or a moment.
    func groupLink(_ captureId: String, in groupId: String) async throws -> URL {
        guard let deviceId, let key else { throw APIError(status: 0, code: "not_ready", message: notReady) }
        let r = groupId.hasPrefix("moment-")
            ? try await APIClient.shared.postSigned("/v1/moments/view", ["moment_id": groupId, "capture_id": captureId], deviceId: deviceId, key: key).body
            : try await APIClient.shared.postSigned("/v1/gatherings/view", ["capture_id": captureId], deviceId: deviceId, key: key).body
        guard let u = (r["url"] as? String).flatMap({ URL(string: $0) }) else { throw APIError(status: 0, code: "no_link", message: "Chronum did not give a link to that angle.") }
        return u
    }

    // MARK: moments (Jeff 2026-11-26: nearby clips grouped automatically, for people who share)

    /// Whether this account shares with others filming nearby. Off until the person turns it on.
    func nearbySharing(set on: Bool? = nil) async throws -> Bool {
        guard let deviceId, let key else { throw APIError(status: 0, code: "not_ready", message: notReady) }
        var body: [String: Any] = [:]
        if let on { body["nearby"] = on }
        let r = try await APIClient.shared.postSigned("/v1/accounts/sharing", body, deviceId: deviceId, key: key).body
        return r["nearby"] as? Bool ?? false
    }

    /// Moments this account filmed in that someone else filmed too, newest first.
    func myMoments() async throws -> [GroupSummary] {
        guard let deviceId, let key else { throw APIError(status: 0, code: "not_ready", message: notReady) }
        let r = try await APIClient.shared.postSigned("/v1/moments/mine", [:], deviceId: deviceId, key: key).body
        return (r["moments"] as? [[String: Any]] ?? []).compactMap(GroupSummary.init)
    }
}

