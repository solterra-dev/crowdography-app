import XCTest
@testable import Crowdography

/// Build 21: the clock check, the camera path, the direction the camera points, and initials on the map.
final class CameraPathTests: XCTestCase {
    func testClockReadingUsesTheMiddleOfTheTrip() {
        // Sent at 1,000, answered at 1,200 on the phone; the server said 950 at the middle (1,100): the phone is 150 ahead.
        let r = ClockCheck.reading(sentMs: 1_000, serverMs: 950, receivedMs: 1_200)
        XCTAssertEqual(r.offsetMs, 150); XCTAssertEqual(r.rttMs, 200)
        let best = ClockCheck.best([ClockReading(offsetMs: 900, rttMs: 400), ClockReading(offsetMs: 140, rttMs: 60), ClockReading(offsetMs: 300, rttMs: 120)])
        XCTAssertEqual(best?.offsetMs, 140, "the shortest round trip is trusted most")
        XCTAssertNil(ClockCheck.best([]))
    }

    func testStatementCarriesThePathAndClockOnlyWhenPresent() throws {
        var st = CaptureStatement(sha256: String(repeating: "a", count: 64), byteSize: 10, mimeType: "video/quicktime", gatheringId: nil, deviceId: "D", ticketId: "T",
                                  nonce: "n", startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 60), lat: 1, lng: 2, accuracyM: 3, segmentNo: 1, previousCaptureId: nil)
        let plain = String(decoding: try st.signedBytes(), as: UTF8.self)
        XCTAssertFalse(plain.contains("path_sha256")); XCTAssertFalse(plain.contains("clock"))
        st.pathSha256 = String(repeating: "b", count: 64); st.clock = ClockReading(offsetMs: -1250, rttMs: 84)
        let full = String(decoding: try st.signedBytes(), as: UTF8.self)
        XCTAssertTrue(full.contains("\"path_sha256\":\"" + String(repeating: "b", count: 64) + "\""))
        XCTAssertTrue(full.contains("\"clock_offset_ms\":-1250")); XCTAssertTrue(full.contains("\"clock_rtt_ms\":84"))
    }

    func testCameraDirectionFromOrientation() {
        // Lying flat, screen up: the back camera looks straight down.
        let flat = CameraAim.of(qx: 0, qy: 0, qz: 0, qw: 1)
        XCTAssertEqual(flat.pitch, -90, accuracy: 0.1)
        // Turned 90 degrees about the phone's left-right line: the back camera looks level, toward the world's +y (west).
        let s = sin(Double.pi / 4), c = cos(Double.pi / 4)
        let up = CameraAim.of(qx: s, qy: 0, qz: 0, qw: c)
        XCTAssertEqual(up.pitch, 0, accuracy: 0.1); XCTAssertEqual(up.azimuth, 270, accuracy: 0.1)
        // Then turned a further 90 degrees about the vertical: from west round to south.
        let v = CameraAim.rotate((0, 1, 0), qx: 0, qy: 0, qz: s, qw: c)
        XCTAssertEqual(v.0, -1, accuracy: 0.0001); XCTAssertEqual(v.1, 0, accuracy: 0.0001)
    }

    func testDataTrackTexts() {
        XCTAssertEqual(CameraAim.iso6709(lat: 38.7317, lng: -82.9977, altitude: 150), "+38.73170-082.99770+150.000/")
        XCTAssertEqual(CameraAim.iso6709(lat: -8.5, lng: 124.6, altitude: nil), "-08.50000+124.60000/")
        XCTAssertEqual(CameraAim.dataTrackText(azimuth: 91.54, pitch: -3.2, compass: nil), "{\"az\":91.5,\"pitch\":-3.2}")
    }

    func testPoseBetweenReadings() throws {
        let p = CameraPath(loc: [[0, 38.0, -83.0, 5, 20, 90, 100], [1000, 38.0, -82.9998, 6, 20, 90, 100]],
                           aim: [[0, 45, 0], [200, 50, 0], [1000, -1, 0, 0, 0, 0, 1, 120, 10]])
        let mid = try XCTUnwrap(p.pose(at: 500))
        XCTAssertEqual(mid.lng, -82.9999, accuracy: 0.0000001, "half way between the two GPS readings")
        XCTAssertEqual(mid.accuracyM, 6)
        XCTAssertEqual(p.pose(at: 150)?.azimuth, 50, "the nearest motion reading")
        XCTAssertEqual(p.pose(at: 1000)?.azimuth, 120, "the compass when the motion direction is unknown")
        XCTAssertEqual(p.pose(at: 99_000)?.lng, -82.9998, "after the last reading it stays at the last place")
    }

    func testMovingFastFallsBackToTheDirectionOfTravel() {
        let car = CameraPath(loc: [[0, 38, -83, 5, 25, 180, 0]], aim: [])
        XCTAssertEqual(car.pose(at: 0)?.azimuth, 180)
        let walking = CameraPath(loc: [[0, 38, -83, 5, 1, 180, 0]], aim: [])
        XCTAssertNil(walking.pose(at: 0)?.azimuth, "a slow phone's travel says nothing about where it points")
    }

    func testThePathFileReadsBack() throws {
        let data = try XCTUnwrap(CameraPath.encode(startedAt: Date(timeIntervalSince1970: 1_800_000_000), frame: "true_north",
                                                   loc: [[0, 38.123456789, -82.987654321, 5.55, 12.345, 90.06, 150.04]], aim: [[0, 91.54, -3.26, 0.1, 0.2, 0.3, 0.9, 92.1, 10]]))
        let p = try XCTUnwrap(CameraPath(data: data))
        XCTAssertEqual(p.loc[0][1], 38.1234568, accuracy: 0.00000001)
        XCTAssertEqual(p.aim[0][1], 91.5, accuracy: 0.0001)
        XCTAssertNil(CameraPath(data: Data("{\"v\":2}".utf8)))
    }

    func testInitials() {
        XCTAssertEqual(Initials.of("Jeff Huxmann"), "JH")
        XCTAssertEqual(Initials.of("Mary Ann van der Berg"), "MB")
        XCTAssertEqual(Initials.of("roda"), "R")
        XCTAssertEqual(Initials.of(nil), "?")
        XCTAssertEqual(Initials.of("  "), "?")
    }

    func testMapShowsOnlyCamerasFilmingAtTheMoment() {
        func clip(_ id: String, _ s: Int, _ e: Int) -> GroupClip { GroupClip(["capture_id": id, "kind": "video", "start_ms": s, "end_ms": e, "lat": 38.7, "lng": -82.9, "filmed_by": "A B"])! }
        let a = clip("a", 0, 10_000), b = clip("b", 5_000, 20_000)
        XCTAssertEqual(GroupMap.markers([a, b], paths: [:], at: 2_000, current: nil).map(\.id), ["a"])
        XCTAssertEqual(GroupMap.markers([a, b], paths: [:], at: 12_000, current: "a").map(\.id), ["a", "b"], "the angle being watched always shows")
        XCTAssertEqual(GroupMap.markers([a, b], paths: [:], at: nil, current: nil).count, 2)
        XCTAssertNil(GroupMap.markers([a], paths: [:], at: 1_000, current: nil).first?.azimuth, "no path, no direction")
        let path = CameraPath(loc: [[0, 38.71, -82.91, 5, 0, -1, 0]], aim: [[1_000, 33, 0]])
        let m = GroupMap.markers([a], paths: ["a": path], at: 1_000, current: nil).first
        XCTAssertEqual(m?.lat, 38.71); XCTAssertEqual(m?.azimuth, 33)
    }

    func testTimesShowInTheClipsOwnZone() {
        let ms = 1_795_732_800_000   // 2026-11-26 22:40 UTC
        XCTAssertTrue(GroupTimeline.clockLabel(ms, zone: TimeZone(identifier: "America/New_York")).hasPrefix("5:40:00.0 PM"))
        XCTAssertTrue(GroupTimeline.clockLabel(ms, zone: TimeZone(identifier: "America/Chicago")).hasPrefix("4:40:00.0 PM"))
        XCTAssertTrue(GroupTimeline.clockLabel(ms, zone: TimeZone(identifier: "Asia/Manila")).hasPrefix("6:40:00.0 AM"))
        XCTAssertEqual(TimeZoneBook.key(lat: 38.7317, lng: -82.9977), TimeZoneBook.key(lat: 38.74, lng: -82.99), "places a few kilometers apart share one lookup")
    }
}
