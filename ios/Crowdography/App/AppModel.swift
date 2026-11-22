import Foundation
import SwiftUI

/// Everything the screens need: sign-up state, the camera, the upload queue and the current gathering.
@MainActor
final class AppModel: ObservableObject {
    /// blocked: this phone may not film (failed the genuine-phone check, or the service is not offered here).
    /// problem: something else went wrong; shows a title and the exact reason, with a Try again button.
    enum Phase: Equatable { case starting, signingUp, ready, blocked(String), problem(String, String) }
    @Published private(set) var phase: Phase = .starting
    @Published private(set) var gatheringName: String?
    @Published private(set) var hostSeesOriginals = false
    @Published var notice: String?

    let location = LocationProvider()
    let queue = UploadQueue()
    lazy var recorder = Recorder(location: location, queue: queue)
    private(set) var deviceId: String?
    private var key: CaptureKey?

    func start() async {
        location.start()
        do {
            phase = .signingUp
            let k = try CaptureKey.loadOrCreate()
            let id = try await DeviceRegistrar.register()
            key = k; deviceId = id
            do { try await recorder.camera.configure() }
            catch { phase = .problem("The camera could not start", error.localizedDescription); return }
            queue.attach(deviceId: id, key: k)
            recorder.attach(deviceId: id, key: k)
            phase = .ready
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
