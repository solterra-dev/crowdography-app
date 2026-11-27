import XCTest
@testable import Crowdography

/// Build 24: your footage by day and place, moments shown like groups, photos on the map, and big-file checks.
final class FootageByDayAndPlaceTests: XCTestCase {
    private func item(_ id: String, _ when: String, lat: Double? = 38.7317, lng: Double? = -82.9977) -> FootageItem {
        var d: [String: Any] = ["capture_id": id, "kind": "video", "started_at": when, "verified": true]
        if let lat { d["lat"] = lat }
        if let lng { d["lng"] = lng }
        return FootageItem(d)!
    }

    func testGroupsByDayThenPlace() {
        let ny = TimeZone(identifier: "America/New_York")!
        let items = [
            item("e", "2026-11-27T01:30:00Z", lat: 38.7317, lng: -82.9977),   // 8:30 PM Nov 26 in Ohio
            item("d", "2026-11-26T20:00:00Z", lat: 38.7317, lng: -82.9977),   // 3 PM Nov 26, same town
            item("c", "2026-11-26T15:00:00Z", lat: 39.1031, lng: -84.5120),   // 10 AM Nov 26, Cincinnati
            item("b", "2026-11-25T20:00:00Z", lat: 39.1031, lng: -84.5120),   // Nov 25, Cincinnati
            item("a", "2026-11-25T19:00:00Z", lat: nil, lng: nil),            // Nov 25, no place
        ]
        let s = FootageSections.group(items, zoneFor: { _ in ny })
        XCTAssertEqual(s.map { $0.items.map(\.id) }, [["e", "d"], ["c"], ["b"], ["a"]],
                       "a late-evening clip stays on its own local day, and a new town starts a new section")
        XCTAssertNil(s[3].placeKey)
        XCTAssertEqual(FootageSections.dayTitle(s[0]).hasPrefix("Thursday, November 26"), true)
    }

    func testTheDayIsTheDayWhereItWasFilmed() {
        let items = [item("x", "2026-11-27T03:00:00Z")]   // 10 PM Nov 26 in Ohio, 11 AM Nov 27 in Manila
        XCTAssertEqual(FootageSections.dayKey(items[0].startedAt, TimeZone(identifier: "America/New_York")!), "2026-11-26")
        XCTAssertEqual(FootageSections.dayKey(items[0].startedAt, TimeZone(identifier: "Asia/Manila")!), "2026-11-27")
    }

    func testMomentsReadLikeGroups() throws {
        let m = try XCTUnwrap(GroupSummary(["gathering_id": "moment-01ABC", "gathering_name": "Filmed nearby", "kind": "moment", "is_live": false,
                                            "starts_at": "2026-11-26T22:00:00Z", "ends_at": "2026-11-26T22:10:00Z", "clip_count": 3, "phone_count": 2, "lat": 38.73, "lng": -82.99]))
        XCTAssertTrue(m.isMoment); XCTAssertFalse(m.isLive); XCTAssertNil(m.joinCode)
        XCTAssertEqual(m.clipCount, 3); XCTAssertEqual(m.lat ?? 0, 38.73, accuracy: 0.0001)
    }

    func testPhotosShowOnTheMapNearTheirMoment() {
        let photo = GroupClip(["capture_id": "p", "kind": "photo", "start_ms": 10_000, "end_ms": 10_000, "lat": 38.7, "lng": -82.9, "filmed_by": "A B"])!
        XCTAssertEqual(GroupMap.markers([photo], paths: [:], at: 13_000, current: nil).count, 1)
        XCTAssertEqual(GroupMap.markers([photo], paths: [:], at: 16_000, current: nil).count, 0, "more than 5 seconds away")
    }

    func testCopiesWaitForAVerifiedClipAndPhotosNeedOnlyTheirDirection() {
        let t = Ticket(ticketId: "T", nonce: "n", gatheringId: nil, receivedAt: Date())
        var photo = CaptureJob(id: "1", fileName: "a.heic", mimeType: "image/heic", chainId: "c", segmentNo: 1, ticket: t, startedAt: Date(), endedAt: Date(), lat: 1, lng: 2, accuracyM: 3)
        photo.stage = .verified; photo.captureId = "C"
        XCTAssertFalse(photo.needsCopies, "a photo with no direction recorded has nothing to send")
        photo.pathFileName = "a.path.json"; photo.localCopyRemoved = true
        XCTAssertTrue(photo.needsCopies, "its direction is sent even after the photo itself left the phone")
        var video = CaptureJob(id: "2", fileName: "b.mov", mimeType: "video/quicktime", chainId: "c", segmentNo: 1, ticket: t, startedAt: Date(), endedAt: Date(), lat: 1, lng: 2, accuracyM: 3)
        video.stage = .checking; video.captureId = "D"
        XCTAssertFalse(video.isDone, "a clip the server is still checking is not finished")
        XCTAssertFalse(video.needsCopies)
        video.stage = .verified
        XCTAssertTrue(video.needsCopies)
    }

    func testFullLengthPieces() { XCTAssertEqual(Config.maxPieceSeconds, 900) }
}
