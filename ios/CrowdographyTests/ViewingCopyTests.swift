import CoreGraphics
import XCTest
@testable import Crowdography

/// Viewing copies (build 20): reading them from Chronum, finding a second's frame in a strip, and filling four screens.
final class ViewingCopyTests: XCTestCase {
    private func clip(_ id: String, _ start: Int, _ end: Int, copies: [String: Any]? = nil) -> GroupClip {
        var d: [String: Any] = ["capture_id": id, "kind": "video", "start_ms": start, "end_ms": end, "view_url": "https://x.example/\(id).mov"]
        if let copies { d["copies"] = copies }
        return GroupClip(d)!
    }

    func testReadsTheCopies() {
        let c = clip("A", 0, 90_000, copies: ["play": "https://x.example/play.mp4", "tile": "https://x.example/tile.mp4",
                                               "strips": ["https://x.example/strip0.jpg", "https://x.example/strip1.jpg"]])
        XCTAssertEqual(c.bigScreenURL?.lastPathComponent, "play.mp4")
        XCTAssertEqual(c.tileScreenURL?.lastPathComponent, "tile.mp4")
        XCTAssertEqual(c.stripURLs.count, 2)
    }

    func testWithoutCopiesTheOriginalIsUsed() {
        let c = clip("B", 0, 10_000)
        XCTAssertNil(c.playURL)
        XCTAssertEqual(c.bigScreenURL?.lastPathComponent, "B.mov")
        XCTAssertEqual(c.tileScreenURL?.lastPathComponent, "B.mov")
        XCTAssertTrue(c.stripURLs.isEmpty)
        let partial = clip("C", 0, 10_000, copies: ["play": "https://x.example/p.mp4"])
        XCTAssertEqual(partial.tileScreenURL?.lastPathComponent, "p.mp4", "the four-screen view falls back to the playback copy")
    }

    func testFindsTheFrameForEachSecond() {
        // A clip from 1,000 ms to 125,500 ms: seconds 0 to 124, so three strips.
        XCTAssertEqual(StripLayout.locate(startMs: 1_000, endMs: 125_500, at: 1_000).strip, 0)
        XCTAssertEqual(StripLayout.locate(startMs: 1_000, endMs: 125_500, at: 1_999).cell, 0)
        XCTAssertEqual(StripLayout.locate(startMs: 1_000, endMs: 125_500, at: 2_000).cell, 1)
        let m = StripLayout.locate(startMs: 1_000, endMs: 125_500, at: 61_000 + 15_400)
        XCTAssertEqual(m.strip, 1); XCTAssertEqual(m.cell, 15)
        let before = StripLayout.locate(startMs: 1_000, endMs: 125_500, at: 0)
        XCTAssertEqual(before.strip, 0); XCTAssertEqual(before.cell, 0)
        let after = StripLayout.locate(startMs: 1_000, endMs: 125_500, at: 999_999)
        XCTAssertEqual(after.strip, 2); XCTAssertEqual(after.cell, 4, "after the end it shows the last second, 124")
    }

    func testCellsSitInATenBySixGrid() {
        let size = CGSize(width: 1600, height: 540)
        XCTAssertEqual(StripLayout.cellRect(cell: 0, sheetSize: size), CGRect(x: 0, y: 0, width: 160, height: 90))
        XCTAssertEqual(StripLayout.cellRect(cell: 13, sheetSize: size), CGRect(x: 480, y: 90, width: 160, height: 90))
        XCTAssertEqual(StripLayout.cellRect(cell: 59, sheetSize: size), CGRect(x: 1440, y: 450, width: 160, height: 90))
        XCTAssertEqual(StripLayout.cellSize(forFrameWidth: 320, height: 180), CGSize(width: 160, height: 90))
        XCTAssertEqual(StripLayout.cellSize(forFrameWidth: 180, height: 320), CGSize(width: 160, height: 284), "upright clips get tall cells")
    }

    func testFillsFourScreensWithWhatIsRunning() {
        let a = clip("a", 0, 50_000), b = clip("b", 5_000, 90_000), c = clip("c", 8_000, 20_000)
        let later = clip("later", 30_000, 60_000), gone = clip("gone", 0, 5_000)
        let picks = GroupTimeline.fill(4, at: 10_000, from: [a, b, c, later, gone]).map(\.id)
        XCTAssertEqual(picks, ["b", "a", "c", "later"])
    }

    func testNeverShowsOneAngleTwice() {
        let now = clip("now", 0, 10_000), shown = clip("shown", 0, 40_000), free = clip("free", 0, 20_000)
        XCTAssertEqual(GroupTimeline.next(after: now, at: 10_000, in: [now, shown, free], excluding: ["shown"])?.clip.id, "free")
        XCTAssertNil(GroupTimeline.next(after: now, at: 10_000, in: [now, shown], excluding: ["shown"]))
    }
}
