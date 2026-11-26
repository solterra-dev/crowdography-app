import Foundation

/// What a person logs in with: an email address, or a mobile number (Jeff 2026-11-25: a phone option to log in).
/// The server (crowd_login_identity in crowd_login.php) applies the same rules and has the final say.
enum LoginName: Equatable {
    case email(String)
    /// A United States or Canadian mobile number as +1 and ten digits.
    case phone(String)

    /// Reads what was typed. Returns nil when it is neither an email address nor, where allowed, a mobile number.
    static func parse(_ raw: String, phoneAllowed: Bool) -> LoginName? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("@") {
            guard text.count <= 254, !text.hasPrefix("@"), !text.hasSuffix("@"), !text.contains(" ") else { return nil }
            return .email(text.lowercased())
        }
        guard phoneAllowed, let number = cleanPhone(text) else { return nil }
        return .phone(number)
    }

    /// (937) 555-0142, 937.555.0142, 1 937 555 0142 and +1 937-555-0142 all become +19375550142. Other countries are not accepted yet.
    static func cleanPhone(_ text: String) -> String? {
        let allowed = Set("0123456789+().- ")
        guard !text.isEmpty, text.count <= 40, text.allSatisfy({ allowed.contains($0) }) else { return nil }
        var digits = text.filter { $0.isASCII && $0.isNumber }
        if digits.count == 11, digits.hasPrefix("1") { digits.removeFirst() } else if text.hasPrefix("+") { return nil }
        guard digits.count == 10 else { return nil }
        let d = Array(digits)
        guard "23456789".contains(d[0]), "23456789".contains(d[3]) else { return nil }
        return "+1" + digits
    }

    var isPhone: Bool { if case .phone = self { return true } else { return false } }

    /// The name of the field the server expects.
    var field: String { isPhone ? "phone" : "email" }

    var value: String {
        switch self {
        case .email(let address): return address
        case .phone(let number): return number
        }
    }

    /// What a password must not simply repeat: the email address, or the ten digits of the number.
    var passwordMustNotBe: String {
        switch self {
        case .email(let address): return address
        case .phone(let number): return String(number.dropFirst(2))
        }
    }

    /// How the app shows it back to the person: the address, or (937) 555-0142.
    var shown: String {
        switch self {
        case .email(let address): return address
        case .phone(let number):
            let d = Array(number.dropFirst(2))
            guard d.count == 10 else { return number }
            return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
        }
    }
}
