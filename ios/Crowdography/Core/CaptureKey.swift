import CryptoKit
import Foundation

/// The phone's filming key. It is made inside the Secure Enclave (the iPhone's security chip) and can never leave it:
/// the app only ever holds a sealed reference that works on this one phone. Every request and every clip statement is
/// signed with it (ECDSA on curve P-256 with SHA-256), and Apple's check vouches for exactly this key at sign-up.
struct CaptureKey {
    private static let account = "capture-key-v1"
    private let key: SecureEnclave.P256.Signing.PrivateKey

    enum KeyError: LocalizedError {
        case noSecurityChip
        var errorDescription: String? { "This phone has no security chip, so it cannot film with Crowdography." }
    }

    /// The existing key, or a new one made in the security chip on first use.
    static func loadOrCreate() throws -> CaptureKey {
        guard SecureEnclave.isAvailable else { throw KeyError.noSecurityChip }
        if let sealed = Keychain.read(account), let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: sealed) {
            return CaptureKey(key: k)
        }
        let k = try SecureEnclave.P256.Signing.PrivateKey()
        Keychain.write(account, k.dataRepresentation)
        return CaptureKey(key: k)
    }

    /// Throws away the key, for example when the server refused to register it. A new one is made next time.
    static func discard() { Keychain.delete(account) }

    /// The public half in PEM text, exactly as sent to the server. Apple's check hashes this same text.
    var publicKeyPEM: String { key.publicKey.pemRepresentation }

    /// DER signature, base64, over the exact bytes given.
    func signBase64(_ bytes: Data) throws -> String {
        try key.signature(for: bytes).derRepresentation.base64EncodedString()
    }
}
