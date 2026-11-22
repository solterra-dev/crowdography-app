import Foundation

enum PersonName {
    /// The same tidy-up the server does before it accepts a name: single spaces, 2 to 80 characters, starting with a letter,
    /// at least two letters, and nothing but letters, spaces, periods, commas, apostrophes and hyphens.
    /// Returns nil when the text cannot be a name. The server has the final say; this only keeps obvious mistakes from being sent.
    static func tidy(_ raw: String) -> String? {
        let s = raw.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let allowed: Set<Character> = [" ", ".", ",", "'", "\u{2019}", "-"]
        guard (2...80).contains(s.count), let first = s.first, first.isLetter,
              s.filter({ $0.isLetter }).count >= 2,
              s.allSatisfy({ $0.isLetter || allowed.contains($0) }) else { return nil }
        return s
    }
}
