import CryptoKit
import Foundation

extension Data {
    var hexLowercase: String { map { String(format: "%02x", $0) }.joined() }
}

enum Hash {
    static func sha256Hex(_ data: Data) -> String { Data(SHA256.hash(data: data)).hexLowercase }
    static func sha256Hex(_ text: String) -> String { sha256Hex(Data(text.utf8)) }

    /// Hashes a file of any size (a 15-minute 4K piece is several gigabytes) without loading it into memory.
    static func sha256HexOfFile(_ url: URL) throws -> (hex: String, bytes: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 8 * 1024 * 1024) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += chunk.count
        }
        return (Data(hasher.finalize()).hexLowercase, total)
    }
}

/// Times exactly as the server reads them: UTC with milliseconds, for example 2026-11-15T23:30:00.123Z.
enum UTC {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    static func string(_ date: Date) -> String { formatter.string(from: date) }
}
