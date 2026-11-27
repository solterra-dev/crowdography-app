import AVFoundation
import UIKit

/// Makes the viewing copies of a verified video on the phone itself (Jeff 2026-11-26: the phone makes the copies,
/// so the work grows with the number of people filming at no cost to us). The original is never changed; it stays the proof.
///   play:  1280 wide, about 2.5 megabits a second, for the big screen
///   tile:  960 wide, about 1.2 megabits a second, for the four-screen view
///   strips: one picture per minute holding up to 60 small frames, one for each second, for the scrolling list of angles
/// Both videos keep the original frame rate and put a full frame every second, so jumping to any moment is quick.
enum CopyMaker {
    struct Strip { let url: URL; let frames: Int }
    struct CopyError: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Re-encodes `src` into a smaller MP4 at `dst`. The longer side becomes `longSide` (never enlarged).
    static func transcode(_ src: URL, to dst: URL, longSide: CGFloat, videoBitsPerSecond: Int) async throws {
        try? FileManager.default.removeItem(at: dst)
        let asset = AVURLAsset(url: src)
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else { throw CopyError(message: "The clip has no picture.") }
        let at = try await asset.loadTracks(withMediaType: .audio).first
        let (natural, transform, fps) = try await vt.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let scale = min(1, longSide / max(natural.width, natural.height, 1))
        let w = max(2, Int((natural.width * scale / 2).rounded()) * 2), h = max(2, Int((natural.height * scale / 2).rounded()) * 2)

        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h, AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: videoBitsPerSecond, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                              AVVideoMaxKeyFrameIntervalDurationKey: 1, AVVideoExpectedSourceFrameRateKey: max(1, Int(fps.rounded()))]])
        vIn.transform = transform
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)

        var aPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        if let at {
            let aOut = AVAssetReaderTrackOutput(track: at, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: 2, AVSampleRateKey: 44100])
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 44100, AVEncoderBitRateKey: 96000])
            aIn.expectsMediaDataInRealTime = false
            if reader.canAdd(aOut) && writer.canAdd(aIn) { reader.add(aOut); writer.add(aIn); aPair = (aOut, aIn) }
        }

        guard writer.startWriting() else { throw CopyError(message: writer.error?.localizedDescription ?? "The phone could not start making a copy.") }
        guard reader.startReading() else { writer.cancelWriting(); throw CopyError(message: reader.error?.localizedDescription ?? "The phone could not read the clip.") }
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            func pump(_ out: AVAssetReaderTrackOutput, _ input: AVAssetWriterInput, _ label: String) {
                group.enter()
                let finished = DoneFlag()
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "copy." + label)) {
                    while !finished.value && input.isReadyForMoreMediaData {
                        if let s = out.copyNextSampleBuffer(), input.append(s) { continue }
                        finished.value = true
                        input.markAsFinished()
                        group.leave()
                    }
                }
            }
            pump(vOut, vIn, "video")
            if let p = aPair { pump(p.0, p.1, "audio") }
            group.notify(queue: .global()) { done.resume() }
        }

        if reader.status == .failed { writer.cancelWriting(); throw CopyError(message: reader.error?.localizedDescription ?? "Reading the clip stopped.") }
        await writer.finishWriting()
        guard writer.status == .completed else { throw CopyError(message: writer.error?.localizedDescription ?? "The copy could not be finished.") }
    }

    /// One JPEG per minute of the clip, each a 10 by 6 grid of frames, one frame for each second (see StripLayout).
    static func strips(_ src: URL, folder: URL) async throws -> [Strip] {
        let asset = AVURLAsset(url: src)
        let seconds = min(Int(try await asset.load(.duration).seconds.rounded(.up)), StripLayout.maxMinutes * 60)
        guard seconds > 0 else { throw CopyError(message: "The clip has no length.") }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 320)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)

        var cell: CGSize?
        var out: [Strip] = []
        for minute in 0..<((seconds + 59) / 60) {
            var frames: [CGImage?] = []
            for k in 0..<StripLayout.perStrip {
                let t = minute * 60 + k
                guard t < seconds else { break }
                let img = try? await gen.image(at: CMTime(value: CMTimeValue(t), timescale: 1)).image
                if cell == nil, let img { cell = StripLayout.cellSize(forFrameWidth: CGFloat(img.width), height: CGFloat(img.height)) }
                frames.append(img)
            }
            let c = cell ?? StripLayout.cellSize(forFrameWidth: 16, height: 9)
            let size = CGSize(width: c.width * CGFloat(StripLayout.columns), height: c.height * CGFloat(StripLayout.rows))
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
            let sheet = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
                UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                for (k, f) in frames.enumerated() {
                    guard let f else { continue }
                    UIImage(cgImage: f).draw(in: StripLayout.cellRect(cell: k, sheetSize: size))
                }
            }
            guard let data = sheet.jpegData(compressionQuality: 0.6) else { throw CopyError(message: "The frame strip could not be saved.") }
            let url = folder.appendingPathComponent("strip\(minute).jpg")
            try data.write(to: url, options: .atomic)
            out.append(Strip(url: url, frames: frames.count))
        }
        return out
    }
}

/// Set once a track has no more samples, so it is marked finished only once.
private final class DoneFlag { var value = false }

/// Where each second's frame sits in a strip picture. Pure arithmetic, so it is tested on its own.
enum StripLayout {
    static let columns = 10
    static let rows = 6
    static let perStrip = 60
    static let maxMinutes = 15
    static let cellWidth: CGFloat = 160

    /// Cells keep the shape of the frames: 160 wide, height to match (taller for a clip filmed upright).
    static func cellSize(forFrameWidth w: CGFloat, height h: CGFloat) -> CGSize {
        CGSize(width: cellWidth, height: max(2, (cellWidth * h / max(w, 1)).rounded()))
    }
    /// The rectangle of cell `cell` (0 to 59, left to right, then down) in a strip of `sheetSize` pixels.
    static func cellRect(cell: Int, sheetSize: CGSize) -> CGRect {
        let w = sheetSize.width / CGFloat(columns), h = sheetSize.height / CGFloat(rows)
        return CGRect(x: CGFloat(cell % columns) * w, y: CGFloat(cell / columns) * h, width: w, height: h).integral
    }
    /// Which strip and cell show the frame at moment `ms` of a clip running from `startMs` to `endMs`.
    /// Before the clip starts it shows the first frame; after it ends, the last.
    static func locate(startMs: Int, endMs: Int, at ms: Int) -> (strip: Int, cell: Int) {
        let last = max(0, min((endMs - startMs - 1) / 1000, maxMinutes * 60 - 1))
        let s = min(max(0, (ms - startMs) / 1000), last)
        return (s / perStrip, s % perStrip)
    }
}
