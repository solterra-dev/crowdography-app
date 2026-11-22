import Foundation

/// Fixed settings. Nothing secret lives in the app: every request is proven by the phone's own security-chip key.
enum Config {
    /// Chronum's address for Crowdography. Chronum answers at chronumapi.com/v1 (there is no api. subdomain).
    static let apiBase = URL(string: "https://chronumapi.com")!

    /// Jeff 2026-11-15: pieces are at most 15 minutes; a longer recording rolls into a new chained piece.
    /// TEST PHASE (2026-11-21): the server checks each file inside the request and caps one upload at 500 MB, so pieces
    /// are 2 minutes for now (about 340 MB of 4K). A longer recording still chains into pieces. Goes back to 900.
    static let maxPieceSeconds: Double = 120
    /// Ask for the next piece's one-time ticket this long before the current piece ends (tickets live 300 seconds).
    static let nextTicketLeadSeconds: Double = 60
    /// Jeff 2026-11-15: 4K at most. 30 frames a second keeps 4K HEVC near 3 MB a second, under the 5 MB server cap.
    static let maxFramesPerSecond: Int32 = 30
    /// The server counts location accuracy toward a gathering's area only up to 100 meters.
    static let usefulAccuracyMeters: Double = 100
}
