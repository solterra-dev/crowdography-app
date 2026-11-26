import XCTest
@testable import Crowdography

/// How the app reads one entry of the footage list Chronum sends (crowd_footage_item in crowd_footage.php).
final class FootageItemTests: XCTestCase {
    private func entry(_ changes: [String: Any] = [:]) -> [String: Any] {
        var d: [String: Any] = ["capture_id": "01M8AZRWBYJHG4ATAKE1QYDNG2", "kind": "video", "mime_type": "video/quicktime", "byte_size": 172_000_000,
                                "started_at": "2026-11-26T03:43:15Z", "ended_at": "2026-11-26T03:45:20Z", "seconds": 125, "piece_no": 2,
                                "continues_capture_id": "01M8AZRWBYJHG4ATAKE1QYDNG1", "verified": true, "gathering_name": NSNull(),
                                "view_url": "https://storage.example/originals/a.mov"]
        for (k, v) in changes { d[k] = v }
        return d
    }

    func testReadsAVideoPiece() throws {
        let item = try XCTUnwrap(FootageItem(entry()))
        XCTAssertEqual(item.id, "01M8AZRWBYJHG4ATAKE1QYDNG2")
        XCTAssertTrue(item.isVideo)
        XCTAssertTrue(item.verified)
        XCTAssertEqual(item.byteSize, 172_000_000)
        XCTAssertEqual(item.seconds, 125)
        XCTAssertEqual(item.lengthLabel, "2:05")
        XCTAssertEqual(item.pieceNo, 2)
        XCTAssertNil(item.gatheringName)
        XCTAssertEqual(item.viewURL?.absoluteString, "https://storage.example/originals/a.mov")
        XCTAssertEqual(item.startedAt.timeIntervalSince1970, 1_795_664_595, accuracy: 0.5)
    }

    func testReadsAPhotoThatFailedItsCheck() throws {
        let item = try XCTUnwrap(FootageItem(entry(["kind": "photo", "verified": false, "seconds": 0, "gathering_name": "Smith wedding", "view_url": NSNull()])))
        XCTAssertFalse(item.isVideo)
        XCTAssertFalse(item.verified)
        XCTAssertEqual(item.gatheringName, "Smith wedding")
        XCTAssertNil(item.viewURL)
        XCTAssertFalse(item.linkIsFresh)
    }

    func testAnEntryWithoutItsIdOrTimeIsLeftOut() {
        XCTAssertNil(FootageItem(entry(["capture_id": NSNull()])))
        XCTAssertNil(FootageItem(entry(["capture_id": ""])))
        XCTAssertNil(FootageItem(entry(["started_at": "yesterday"])))
    }

    func testALinkGoesStaleBeforeTheServerEndsIt() throws {
        let fresh = try XCTUnwrap(FootageItem(entry(), receivedAt: Date().addingTimeInterval(-60)))
        XCTAssertTrue(fresh.linkIsFresh)
        let old = try XCTUnwrap(FootageItem(entry(), receivedAt: Date().addingTimeInterval(-1600)))
        XCTAssertFalse(old.linkIsFresh)
    }
}
