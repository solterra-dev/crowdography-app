import XCTest
@testable import Crowdography

/// The app's first look at a new password. The server (crowd_password_problem in crowd_login.php) applies the same rules,
/// also refuses very common passwords, and has the final say.
final class PasswordRuleTests: XCTestCase {
    private let email = "jeff@example.com"

    func testAcceptsLongEnoughPasswords() {
        for p in ["horse-battery-staple", "jeffjeffx", "pässwörd-länge", "12ab34cd", String(repeating: "xy1z", count: 32)] {
            XCTAssertNil(PasswordRule.problem(p, email: email), p)
        }
    }

    func testRefusesShortLongAndEmpty() {
        XCTAssertNotNil(PasswordRule.problem("", email: email))
        XCTAssertNotNil(PasswordRule.problem("short1", email: email))
        XCTAssertNotNil(PasswordRule.problem(String(repeating: "xy1z", count: 33), email: email))
    }

    func testRefusesTooFewDifferentCharacters() {
        XCTAssertNotNil(PasswordRule.problem("aaaaaaaaaaaa", email: email))
        XCTAssertNotNil(PasswordRule.problem("AbAbAbAbAbAb", email: email))
    }

    func testRefusesTheEmailAddressItself() {
        XCTAssertNotNil(PasswordRule.problem("Jeff@Example.com", email: email))
        XCTAssertNotNil(PasswordRule.problem("longname", email: " LongName@example.com "))
        XCTAssertNil(PasswordRule.problem("longname1", email: "longname@example.com"))
    }
}
