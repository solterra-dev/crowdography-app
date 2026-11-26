import Foundation

enum PasswordRule {
    static let minLength = 8
    static let maxLength = 128

    /// The app's first look at a new password, the same rules the server applies (crowd_password_problem in crowd_login.php):
    /// 8 to 128 characters, at least 4 different characters, and not the email address, the part before its @ sign, or the phone number the person logs in with.
    /// No symbols are forced. Returns what is wrong, or nil. The server also refuses very common passwords and has the final say.
    static func problem(_ password: String, email: String) -> String? {
        if password.isEmpty { return "Enter a password." }
        let count = password.unicodeScalars.count
        if count < minLength { return "Use at least \(minLength) characters for the password." }
        if count > maxLength { return "Use at most \(maxLength) characters for the password." }
        let low = password.lowercased()
        if Set(low.unicodeScalars).count < 4 { return "That password is too easy to guess." }
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !mail.isEmpty, low == mail || low == String(mail.prefix(while: { $0 != "@" })) {
            return "Do not use your email address or phone number as the password."
        }
        return nil
    }
}
