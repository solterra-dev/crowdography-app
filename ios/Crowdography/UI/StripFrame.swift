import SwiftUI
import UIKit

/// Keeps downloaded frame strips so a list of 100 angles can show each one's frame at the same moment without
/// downloading anything twice. One strip covers one minute of one angle.
@MainActor
final class StripStore {
    static let shared = StripStore()
    private var images: [String: CGImage] = [:]
    private var order: [String] = []
    private var loading: [String: Task<CGImage?, Never>] = [:]
    private let keep = 400

    func cached(_ key: String) -> CGImage? { images[key] }

    func load(_ key: String, from url: URL) async -> CGImage? {
        if let i = images[key] { return i }
        if let t = loading[key] { return await t.value }
        let t = Task<CGImage?, Never> {
            guard let r = try? await URLSession.shared.data(from: url),
                  ((r.1 as? HTTPURLResponse)?.statusCode ?? 0) == 200 else { return nil }
            return UIImage(data: r.0)?.cgImage
        }
        loading[key] = t
        let img = await t.value
        loading[key] = nil
        if let img {
            images[key] = img; order.append(key)
            if order.count > keep { images[order.removeFirst()] = nil }
        }
        return img
    }
}

/// The frame of one angle at the moment being watched, taken from its one-a-second strip.
/// Before an angle starts it shows its first frame; after it ends, its last.
struct StripFrame: View {
    let clip: GroupClip
    let momentMs: Int?
    var width: CGFloat = 80
    @State private var sheet: CGImage?
    @State private var sheetKey = ""

    var body: some View {
        let at = StripLayout.locate(startMs: clip.startMs, endMs: clip.endMs, at: momentMs ?? clip.startMs)
        let key = clip.id + "-" + String(at.strip)
        let url = clip.stripURLs.indices.contains(at.strip) ? clip.stripURLs[at.strip] : nil
        return ZStack {
            Color.black.opacity(0.85)
            if sheetKey == key, let sheet, let frame = sheet.cropping(to: StripLayout.cellRect(cell: at.cell, sheetSize: CGSize(width: sheet.width, height: sheet.height))) {
                Image(decorative: frame, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: clip.isVideo ? "video" : "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: key) {
            guard let url else { return }
            if let c = StripStore.shared.cached(key) { sheet = c; sheetKey = key; return }
            if let img = await StripStore.shared.load(key, from: url) { sheet = img; sheetKey = key }
        }
    }
}
