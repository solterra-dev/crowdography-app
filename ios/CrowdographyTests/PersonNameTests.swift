import XCTest
@testable import Crowdography

/// The app's first look at a name. The server (crowd_clean_name in crowd_signin.php) applies the same rules and has the final say.
final class PersonNameTests: XCTestCase {
    func testTidiesSpaces() {
        XCTAssertEqual(PersonName.tidy("  Jeff   Huxmann \n"), "Jeff Huxmann")
        XCTAssertEqual(PersonName.tidy("a\u{00A0}b"), "a b")
    }

    func testAcceptsRealNames() {
        for n in ["O'Brien", "O\u{2019}Brien", "María-José Núñez", "Jean-Luc Picard Jr.", "李小龙", "Smith, John", "Jo"] {
            XCTAssertEqual(PersonName.tidy(n), n, n)
        }
    }

    func testJoinsAccentsTheWayTheServerDoes() {
        // "e" followed by a separate accent mark becomes the single letter "é", as the server stores it.
        XCTAssertEqual(PersonName.tidy("Jose\u{0301}")?.unicodeScalars.count, 4)
        XCTAssertEqual(PersonName.tidy("Jose\u{0301}"), "Jos\u{00E9}")
    }

    func testRefusesThingsThatAreNotNames() {
        for n in ["", " ", "x", "J.", "A1 Steak", "http://example.com", "Jeff 😀", "-Jeff", String(repeating: "a", count: 81)] {
            XCTAssertNil(PersonName.tidy(n), n)
        }
    }

    func testEightyCharactersIsTheLimit() {
        XCTAssertNotNil(PersonName.tidy(String(repeating: "a", count: 80)))
    }
}
