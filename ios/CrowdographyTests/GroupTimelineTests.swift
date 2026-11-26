import XCTest
@testable import Crowdography

/// Reading a group's angles and choosing the next one when the one being watched ends.
final class GroupTimelineTests: XCTestCase {
    private func clip(_ id: String, _ start: Int, _ end: Int, video: Bool = true, lat: Double? = 38.7317, lng: Double? = -82.9977) -> GroupClip {
        var d: [String: Any] = ["capture_id": id, "kind": video ? "video" : "photo", "start_ms": start, "end_ms": end, "filmed_by": "Tester \(id)", "phone_key": id]
        if let lat { d["lat"] = lat }
        if let lng { d["lng"] = lng }
        return GroupClip(d)!
    }

    func testReadsAnAngle() throws {
        let c = try XCTUnwrap(GroupClip(["capture_id": "A", "kind": "video", "start_ms": 1_795_664_595_250, "end_ms": 1_795_664_655_250,
                                         "filmed_by": "Jeff", "is_mine": true, "phone_key": "abc", "lat": 38.74, "lng": -82.99, "view_url": "https://x.example/a.mov"]))
        XCTAssertEqual(c.startMs, 1_795_664_595_250)
        XCTAssertEqual(c.seconds, 60)
        XCTAssertEqual(c.lengthLabel, "1:00")
        XCTAssertTrue(c.isMine)
        XCTAssertEqual(c.lat ?? 0, 38.74, accuracy: 0.0001)
        XCTAssertTrue(c.covers(1_795_664_600_000))
        XCTAssertFalse(c.covers(1_795_664_655_250))
        XCTAssertNil(GroupClip(["capture_id": "B", "kind": "video"]))
    }

    func testSwitchesToTheClosestAngleStillRunning() {
        let now = clip("now", 0, 10_000)
        let far = clip("far", 5_000, 30_000, lat: 38.80, lng: -82.99)
        let near = clip("near", 2_000, 20_000, lat: 38.7320, lng: -82.9980)
        let ending = clip("ending", 0, 10_300)
        let photo = clip("photo", 9_000, 9_000, video: false)
        let r = GroupTimeline.next(after: now, at: 10_000, in: [now, far, near, ending, photo])
        XCTAssertEqual(r?.clip.id, "near")
        XCTAssertEqual(r?.atMs, 10_000)
    }

    func testWithoutPlacesTakesTheLongestRunning() {
        let now = clip("now", 0, 10_000, lat: nil, lng: nil)
        let a = clip("a", 0, 15_000, lat: nil, lng: nil)
        let b = clip("b", 0, 40_000, lat: nil, lng: nil)
        XCTAssertEqual(GroupTimeline.next(after: now, at: 10_000, in: [now, a, b])?.clip.id, "b")
    }

    func testWhenNothingIsRunningJumpsToTheNextAngleToStart() {
        let now = clip("now", 0, 10_000)
        let later = clip("later", 25_000, 30_000)
        let soonest = clip("soonest", 12_000, 14_000)
        let r = GroupTimeline.next(after: now, at: 10_000, in: [now, later, soonest])
        XCTAssertEqual(r?.clip.id, "soonest")
        XCTAssertEqual(r?.atMs, 12_000)
    }

    func testNothingLeft() {
        let now = clip("now", 0, 10_000)
        XCTAssertNil(GroupTimeline.next(after: now, at: 10_000, in: [now, clip("old", 0, 5_000), clip("pic", 20_000, 20_000, video: false)]))
    }

    func testReadsAGroup() throws {
        let g = try XCTUnwrap(GroupSummary(["gathering_id": "G", "gathering_name": "Parade", "is_host": true, "is_live": true,
                                            "starts_at": "2026-11-26T22:00:00Z", "ends_at": "2026-11-27T00:00:00Z", "join_code": "ABCD1234",
                                            "clip_count": 12, "phone_count": 4]))
        XCTAssertEqual(g.joinCode, "ABCD1234")
        XCTAssertEqual(g.clipCount, 12)
        XCTAssertEqual(g.endsAt.timeIntervalSince(g.startsAt), 7200)
        XCTAssertNil(GroupSummary(["gathering_id": "G"]))
    }
}
