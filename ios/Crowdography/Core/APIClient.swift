import Foundation

struct APIError: LocalizedError {
    let status: Int
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// Talks to Chronum. Every request after sign-up carries three headers proving it came from this registered phone:
/// X-Crowd-Device, X-Crowd-Time and X-Crowd-Signature, the signature covering "METHOD\nPATH\nTIME\nsha256(body)".
final class APIClient {
    static let shared = APIClient()
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    /// The exact text the phone signs for one request. Kept separate so the tests can check it byte for byte.
    static func signingMessage(method: String, path: String, time: Int, body: Data) -> Data {
        Data("\(method)\n\(path)\n\(time)\n\(Hash.sha256Hex(body))".utf8)
    }

    /// POST without a phone signature: only the sign-up addresses accept this.
    func postUnsigned(_ path: String, _ json: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: json)
        var req = URLRequest(url: Config.apiBase.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(req).body
    }

    /// POST signed by the phone's security-chip key. Returns the status too, because a failed clip check (422) still has a useful answer.
    func postSigned(_ path: String, _ json: [String: Any], deviceId: String, key: CaptureKey) async throws -> (status: Int, body: [String: Any]) {
        let body = try JSONSerialization.data(withJSONObject: json)
        let time = Int(Date().timeIntervalSince1970)
        let sig = try key.signBase64(Self.signingMessage(method: "POST", path: path, time: time, body: body))
        var req = URLRequest(url: Config.apiBase.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Crowd-Device")
        req.setValue(String(time), forHTTPHeaderField: "X-Crowd-Time")
        req.setValue(sig, forHTTPHeaderField: "X-Crowd-Signature")
        return try await send(req, okStatuses: [422])
    }

    private func send(_ req: URLRequest, okStatuses: Set<Int> = []) async throws -> (status: Int, body: [String: Any]) {
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // Chronum answers {"ok":true,"data":{...}} or {"ok":false,"error":{"code","message"}}.
        let payload = obj["data"] as? [String: Any] ?? obj
        if (200..<300).contains(status) || okStatuses.contains(status) { return (status, payload) }
        let err = obj["error"] as? [String: Any]
        throw APIError(status: status, code: err?["code"] as? String ?? "http_\(status)",
                       message: err?["message"] as? String ?? "Chronum answered \(status).")
    }
}
