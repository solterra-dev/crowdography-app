import Foundation

/// Fixed settings. Nothing secret lives in the app: every request is proven by the phone's own security-chip key.
enum Config {
    /// Chronum's address for Crowdography. Chronum answers at chronumapi.com/v1 (there is no api. subdomain).
    static let apiBase = URL(string: "https://chronumapi.com")!
    /// This app's id in Chronum's app list (registered 2026-11-26). Sent when the phone signs up, so the phone, its accounts
    /// and everything it films belong to Crowdography and never mix with another app built on Chronum.
    static let chronumApplicationId = "01M8DKTKRNQFEHA0J3S7QB1RZH"

    /// Jeff 2026-11-15: pieces are at most 15 minutes; a longer recording rolls into a new chained piece.
    /// Build 24 (Jeff 2026-11-26): back to the full 15 minutes. A piece over 500 MB is checked by a background job on the
    /// server (0.16), so nothing waits on the phone.
    static let maxPieceSeconds: Double = 900
    /// Ask for the next piece's one-time ticket this long before the current piece ends (tickets live 300 seconds).
    static let nextTicketLeadSeconds: Double = 60
    /// Jeff 2026-11-15: 4K at most. 30 frames a second keeps 4K HEVC near 3 MB a second, under the 5 MB server cap.
    static let maxFramesPerSecond: Int32 = 30
    /// The server counts location accuracy toward a gathering's area only up to 100 meters.
    static let usefulAccuracyMeters: Double = 100
}
