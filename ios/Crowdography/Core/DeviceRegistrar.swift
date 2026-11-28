import CryptoKit
import DeviceCheck
import Foundation

/// Sign-up for a phone. Jeff 2026-11-15: phones that cannot prove they are genuine are not allowed to film.
/// Steps: make the security-chip filming key, get a one-time challenge from Chronum, have Apple's App Attest vouch
/// for "<challenge>:<sha256 of the filming key's PEM>", and send it all to Chronum, which runs Apple's checks itself.
enum DeviceRegistrar {
    private static let deviceIdAccount = "device-id-v1"

    enum RegistrationError: LocalizedError {
        case appAttestUnsupported
        case badChallenge
        case missingDeviceId
        var errorDescription: String? {
            switch self {
            case .appAttestUnsupported: return "This iPhone cannot pass Apple's genuine-phone check, so it cannot film with Crowdography."
            case .badChallenge: return "Chronum did not send a usable sign-up challenge. Try again."
            case .missingDeviceId: return "Chronum did not return a phone id. Try again."
            }
        }
    }

    /// The registered phone id, if sign-up already happened on this phone.
    static var savedDeviceId: String? { Keychain.read(deviceIdAccount).flatMap { String(data: $0, encoding: .utf8) } }

    /// What Apple's check signs over, as the server rebuilds it.
    static func clientData(challenge: String, publicKeyPEM: String) -> Data {
        Data("\(challenge):\(Hash.sha256Hex(publicKeyPEM))".utf8)
    }

    static func register(api: APIClient = .shared) async throws -> String {
        if let id = savedDeviceId { return id }
        let attest = DCAppAttestService.shared
        guard attest.isSupported else { throw RegistrationError.appAttestUnsupported }
        let key = try CaptureKey.loadOrCreate()
        let pem = key.publicKeyPEM

        let ch = try await api.postUnsigned("/v1/devices/challenges", [:])
        guard let challengeId = ch["challenge_id"] as? String, let challenge = ch["challenge"] as? String else { throw RegistrationError.badChallenge }

        let keyId = try await attest.generateKey()   // already base64 of the 32-byte key id
        let hash = Data(SHA256.hash(data: clientData(challenge: challenge, publicKeyPEM: pem)))
        let attestation = try await attest.attestKey(keyId, clientDataHash: hash)

        let body: [String: Any] = [
            "platform": "ios",
            "public_key_pem": pem,
            "challenge_id": challengeId,
            "application_id": Config.chronumApplicationId,   // 2026-11-28: the app this phone runs, on Chronum's plain addresses
            "attestation": attestation.base64EncodedString(),
            "key_id": keyId,
            // Jeff 2026-11-15: keep device data. Apps cannot read hardware serial numbers; make, model and versions are kept.
            "device_make": "Apple",
            "device_model": hardwareModel(),
            "os_version": "iOS " + osVersion(),
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        ]
        do {
            let r = try await api.postUnsigned("/v1/devices", body)
            guard let id = r["device_id"] as? String else { throw RegistrationError.missingDeviceId }
            Keychain.write(deviceIdAccount, Data(id.utf8))
            return id
        } catch let e as APIError where e.code == "key_registered" || e.code == "not_genuine" {
            CaptureKey.discard()   // start over with a fresh key next time
            throw e
        }
    }

    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The exact model code, for example "iPhone17,1".
    static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
