import CryptoKit
import XCTest
@testable import Crowdography

/// These match what the Chronum server expects (crowd_verify.php and crowd_api.php), byte for byte.
final class StatementTests: XCTestCase {
    private func sample(segment: Int = 1, previous: String? = nil, gathering: String? = nil) -> CaptureStatement {
        CaptureStatement(sha256: String(repeating: "ab", count: 32), byteSize: 1234, mimeType: "video/quicktime", gatheringId: gathering,
                         deviceId: "01JDEVICE0000000000000000A", ticketId: "01JTICKET0000000000000000A", nonce: "ff",
                         startedAt: Date(timeIntervalSince1970: 1_763_249_400.125), endedAt: Date(timeIntervalSince1970: 1_763_249_460.5),
                         lat: 38.7317, lng: -82.9977, accuracyM: 6.5, segmentNo: segment, previousCaptureId: previous)
    }

    private func object(_ s: CaptureStatement) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: s.signedBytes()) as? [String: Any])
    }

    func testOnlyKnownFields() throws {
        let o = try object(sample())
        let allowed: Set<String> = ["v", "sha256", "byte_size", "mime_type", "gathering_id", "device_id", "ticket_id", "nonce",
                                    "started_at", "ended_at", "lat", "lng", "accuracy_m", "segment_no", "previous_capture_id"]
        XCTAssertTrue(Set(o.keys).isSubset(of: allowed))
        XCTAssertEqual(o.count, 14)
        XCTAssertEqual(o["v"] as? Int, 1)
        XCTAssertTrue(o["gathering_id"] is NSNull, "filming anywhere sends gathering_id null")
        XCTAssertNil(o["previous_capture_id"], "a first piece names no previous piece")
    }

    func testTimesLookLikeTheServerWants() throws {
        let o = try object(sample())
        let started = try XCTUnwrap(o["started_at"] as? String)
        XCTAssertNotNil(started.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression), started)
        XCTAssertEqual(started, "2025-11-15T23:30:00.125Z")
    }

    func testContinuedPieceNamesThePreviousOne() throws {
        let o = try object(sample(segment: 2, previous: "01JPREVIOUS000000000000000"))
        XCTAssertEqual(o["previous_capture_id"] as? String, "01JPREVIOUS000000000000000")
        XCTAssertEqual(o["segment_no"] as? Int, 2)
    }

    func testRequestSigningText() {
        let m = APIClient.signingMessage(method: "POST", path: "/v1/captures/tickets", time: 1_763_249_400, nonce: "00112233445566778899aabbccddeeff", body: Data("{}".utf8))
        XCTAssertEqual(String(decoding: m, as: UTF8.self),
                       "POST\n/v1/captures/tickets\n1763249400\n00112233445566778899aabbccddeeff\n44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
    }

    func testNoncesAreOneTimeAndWellFormed() {
        let a = APIClient.newNonce(), b = APIClient.newNonce()
        XCTAssertNotEqual(a, b)
        XCTAssertNotNil(a.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression), a)
    }

    func testAppleCheckClientData() {
        let pem = "-----BEGIN PUBLIC KEY-----\nabc\n-----END PUBLIC KEY-----"
        let d = DeviceRegistrar.clientData(challenge: "c0ffee", publicKeyPEM: pem)
        XCTAssertEqual(String(decoding: d, as: UTF8.self), "c0ffee:" + Hash.sha256Hex(pem))
    }

    func testSignaturesAreDerP256OverTheExactBytes() throws {
        // The simulator has no Secure Enclave, so this uses a software key of the same kind to check the format.
        let k = P256.Signing.PrivateKey()
        let bytes = try sample().signedBytes()
        let sig = try k.signature(for: bytes)
        XCTAssertTrue(k.publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: sig.derRepresentation), for: bytes))
        XCTAssertTrue(k.publicKey.pemRepresentation.hasPrefix("-----BEGIN PUBLIC KEY-----"))
    }

    func testCameraExceptionsBecomeErrorsInsteadOfClosingTheApp() {
        XCTAssertThrowsError(try ExceptionGuard.run { NSException(name: .genericException, reason: "startRunning may not be called here", userInfo: nil).raise() }) { e in
            XCTAssertTrue(e.localizedDescription.contains("startRunning may not be called here"), e.localizedDescription)
        }
        XCTAssertNoThrow(try ExceptionGuard.run { })
        struct Plain: Error {}
        XCTAssertThrowsError(try ExceptionGuard.run { throw Plain() }) { XCTAssertTrue($0 is Plain) }
    }

    func testFileHashStreams() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data((0..<20_000_000).map { UInt8($0 % 251) })
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let h = try Hash.sha256HexOfFile(url)
        XCTAssertEqual(h.bytes, data.count)
        XCTAssertEqual(h.hex, Hash.sha256Hex(data))
    }
}
