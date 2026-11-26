import XCTest
@testable import Crowdography

/// The app's first look at what a person logs in with. The server (crowd_login_identity and crowd_clean_phone in crowd_login.php)
/// applies the same rules and has the final say.
final class LoginNameTests: XCTestCase {
    func testReadsAnEmailAddress() {
        XCTAssertEqual(LoginName.parse("  Jeff@Example.com ", phoneAllowed: true), LoginName.email("jeff@example.com"))
        XCTAssertEqual(LoginName.parse("jeff@example.com", phoneAllowed: false)?.field, "email")
        XCTAssertNil(LoginName.parse("@example.com", phoneAllowed: true))
        XCTAssertNil(LoginName.parse("jeff@", phoneAllowed: true))
        XCTAssertNil(LoginName.parse("jeff smith@example.com", phoneAllowed: true))
    }

    func testReadsAMobileNumberHoweverItIsTyped() {
        for typed in ["(937) 555-0142", "937.555.0142", "+1 937-555-0142", "19375550142", "9375550142", " 937 555 0142 "] {
            XCTAssertEqual(LoginName.parse(typed, phoneAllowed: true), LoginName.phone("+19375550142"), typed)
        }
    }

    func testRefusesThingsThatAreNotMobileNumbers() {
        for typed in ["", "555", "123-456-7890", "(937) 155-0142", "+44 20 7946 0958", "call me", "937555014299", "+9375550142"] {
            XCTAssertNil(LoginName.parse(typed, phoneAllowed: true), typed)
        }
    }

    func testANumberIsNotALoginWhileTextingIsOff() {
        XCTAssertNil(LoginName.parse("(937) 555-0142", phoneAllowed: false))
    }

    func testWhatIsSentAndWhatIsShown() {
        let number = LoginName.phone("+19375550142")
        XCTAssertTrue(number.isPhone)
        XCTAssertEqual(number.field, "phone")
        XCTAssertEqual(number.value, "+19375550142")
        XCTAssertEqual(number.shown, "(937) 555-0142")
        XCTAssertEqual(number.passwordMustNotBe, "9375550142")
        XCTAssertNotNil(PasswordRule.problem("9375550142", email: number.passwordMustNotBe))
        let address = LoginName.email("jeff@example.com")
        XCTAssertFalse(address.isPhone)
        XCTAssertEqual(address.shown, "jeff@example.com")
        XCTAssertEqual(address.passwordMustNotBe, "jeff@example.com")
    }
}
