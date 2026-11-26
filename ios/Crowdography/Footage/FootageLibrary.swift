import AVFoundation
import Foundation
import ImageIO
import UIKit

/// The account's stored footage (Jeff 2026-11-25: the app had nothing to see past content).
/// The list comes from Chronum, so it is the same on every phone the account is signed in on.
/// Small preview pictures are made on the phone from the originals the first time they are needed, then kept in the app's cache.
@MainActor
final class FootageLibrary: ObservableObject {
    @Published private(set) var items: [FootageItem] = []
    @Published private(set) var loading = false
    @Published private(set) var loadedOnce = false
    @Published private(set) var problem: String?
    @Published private(set) var previews: [String: UIImage] = [:]

    private var nextBefore: String?
    private var deviceId: String?
    private var key: CaptureKey?
    private let api: APIClient
    private var waiting: [String] = []
    private var working = false
    private var failed: Set<String> = []

    /// Photos larger than this are not downloaded just to make a preview picture.
    private static let largestPhotoForPreview = 30_000_000
    private static let pageSize = 30

    init(api: APIClient = .shared) { self.api = api }

    func attach(deviceId: String, key: CaptureKey) {
        self.deviceId = deviceId
        self.key = key
    }

    private var notReady: APIError { APIError(status: 0, code: "not_registered", message: "This phone is not ready yet. Close the app and open it again.") }

    /// Loads the newest footage from the start.
    func reload() async {
        guard let deviceId, let key, !loading else { return }
        loading = true
        defer { loading = false; loadedOnce = true }
        do {
            let r = try await api.postSigned("/v1/crowd/footage", ["limit": Self.pageSize], deviceId: deviceId, key: key).body
            let now = Date()
            items = (r["items"] as? [[String: Any]] ?? []).compactMap { FootageItem($0, receivedAt: now) }
            nextBefore = r["next_before"] as? String
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    /// Loads the next, older page when the person scrolls to the end.
    func loadMore() async {
        guard let deviceId, let key, !loading, let before = nextBefore else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await api.postSigned("/v1/crowd/footage", ["limit": Self.pageSize, "before": before], deviceId: deviceId, key: key).body
            let now = Date()
            let known = Set(items.map(\.id))
            let more = (r["items"] as? [[String: Any]] ?? []).compactMap { FootageItem($0, receivedAt: now) }
            items.append(contentsOf: more.filter { !known.contains($0.id) })
            nextBefore = r["next_before"] as? String
        } catch { problem = error.localizedDescription }
    }

    /// A link that works right now: the one that came with the list while it is fresh, otherwise a new one from Chronum.
    func freshLink(for id: String) async throws -> URL {
        if let item = items.first(where: { $0.id == id }), item.linkIsFresh, let url = item.viewURL { return url }
        guard let deviceId, let key else { throw notReady }
        let r = try await api.postSigned("/v1/crowd/footage/view", ["capture_id": id], deviceId: deviceId, key: key).body
        guard let text = r["url"] as? String, let url = URL(string: text) else {
            throw APIError(status: 0, code: "no_link", message: "Chronum did not give a link to that file.")
        }
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].viewURL = url; items[i].linkReceivedAt = Date() }
        return url
    }

    // MARK: preview pictures

    /// Called when a tile comes on screen. Uses the saved preview if there is one, otherwise makes one in the background.
    func wantPreview(_ item: FootageItem) {
        guard previews[item.id] == nil, !failed.contains(item.id), !waiting.contains(item.id) else { return }
        if let data = try? Data(contentsOf: Self.previewFile(item.id)), let image = UIImage(data: data) { previews[item.id] = image; return }
        if !item.isVideo && item.byteSize > Self.largestPhotoForPreview { failed.insert(item.id); return }
        waiting.append(item.id)
        makePreviews()
    }

    private func makePreviews() {
        guard !working else { return }
        working = true
        Task {
            while let id = waiting.popLast() {   // the tile asked for most recently is the one on screen now
                guard let item = items.first(where: { $0.id == id }) else { continue }
                do {
                    let url = try await freshLink(for: id)
                    let jpeg = try await Self.previewJPEG(from: url, isVideo: item.isVideo)
                    try? jpeg.write(to: Self.previewFile(id), options: .atomic)
                    if let image = UIImage(data: jpeg) { previews[id] = image }
                } catch { failed.insert(id) }
            }
            working = false
        }
    }

    /// A small JPEG made from the original: the first frame of a video, or a shrunken copy of a photo.
    nonisolated private static func previewJPEG(from url: URL, isVideo: Bool) async throws -> Data {
        let cg: CGImage
        if isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            cg = try await generator.image(at: .zero).image
        } else {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let small = shrunken(data, longestSide: 480) else {
                throw APIError(status: 0, code: "no_preview", message: "The photo could not be read.")
            }
            cg = small
        }
        guard let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) else {
            throw APIError(status: 0, code: "no_preview", message: "The preview could not be made.")
        }
        return jpeg
    }

    /// Decodes a photo at a reduced size, turned the right way up, without loading the full picture into memory.
    nonisolated static func shrunken(_ data: Data, longestSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longestSide]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static var previewFolder: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("FootagePreviews", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
    }
    private static func previewFile(_ id: String) -> URL { previewFolder.appendingPathComponent(id + ".jpg") }

    /// At sign out: forget the list and remove the saved previews, so the next person on this phone sees none of it.
    func clear() {
        items = []; previews = [:]; waiting = []; failed = []; nextBefore = nil; problem = nil; loadedOnce = false
        try? FileManager.default.removeItem(at: Self.previewFolder)
    }
}
