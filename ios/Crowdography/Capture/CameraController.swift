import AVFoundation
import Foundation

/// The camera. Films with Apple's own capture pipeline only: no filters, no effects, nothing generated.
/// Video is HEVC at up to 4K and 30 frames a second (Jeff 2026-11-15: 4K at most, no gigabyte-a-minute formats).
/// Photos are native HEIC, kept byte for byte.
final class CameraController: NSObject {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.crowdography.camera")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var configured = false

    /// Called on the main queue when a piece really starts (first frames on disk).
    var onPieceStarted: (@MainActor (URL, Date) -> Void)?
    /// Called on the main queue when a piece is closed. `hitLimit` is true when the 15-minute limit closed it.
    var onPieceFinished: (@MainActor (URL, Bool, Error?) -> Void)?
    private var photoHandlers: [Int64: (Result<Data, Error>) -> Void] = [:]
    private let handlerLock = NSLock()

    enum CameraError: LocalizedError {
        case noCamera, noPermission, setupFailed
        var errorDescription: String? {
            switch self {
            case .noCamera: return "No camera is available."
            case .noPermission: return "Crowdography needs the camera and microphone. Turn them on in Settings."
            case .setupFailed: return "The camera could not be started."
            }
        }
    }

    static func requestPermissions() async -> Bool {
        let v = await AVCaptureDevice.requestAccess(for: .video)
        let a = await AVCaptureDevice.requestAccess(for: .audio)
        return v && a
    }

    func configure() async throws {
        guard await Self.requestPermissions() else { throw CameraError.noPermission }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.configureOnQueue(); c.resume() } catch { c.resume(throwing: error) }
            }
        }
    }

    private func configureOnQueue() throws {
        if configured { if !session.isRunning { session.startRunning() }; return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.hd4K3840x2160) ? .hd4K3840x2160 : .high

        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw CameraError.noCamera }
        let camIn = try AVCaptureDeviceInput(device: cam)
        guard session.canAddInput(camIn) else { throw CameraError.setupFailed }
        session.addInput(camIn)
        if let mic = AVCaptureDevice.default(for: .audio), let micIn = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micIn) {
            session.addInput(micIn)
        }
        try lockFrameRate(cam)

        guard session.canAddOutput(movieOutput), session.canAddOutput(photoOutput) else { throw CameraError.setupFailed }
        session.addOutput(movieOutput)
        session.addOutput(photoOutput)
        movieOutput.maxRecordedDuration = CMTime(seconds: Config.maxPieceSeconds, preferredTimescale: 600)
        if let conn = movieOutput.connection(with: .video) {
            if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: conn)
            }
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        configured = true
        session.startRunning()
    }

    private func lockFrameRate(_ cam: AVCaptureDevice) throws {
        try cam.lockForConfiguration()
        defer { cam.unlockForConfiguration() }
        let d = CMTime(value: 1, timescale: Config.maxFramesPerSecond)
        let ok = cam.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameDuration <= d && d <= $0.maxFrameDuration }
        if ok { cam.activeVideoMinFrameDuration = d; cam.activeVideoMaxFrameDuration = d }
    }

    var isRecording: Bool { movieOutput.isRecording }

    func startPiece(to url: URL) {
        queue.async { self.movieOutput.startRecording(to: url, recordingDelegate: self) }
    }

    func stopPiece() {
        queue.async { if self.movieOutput.isRecording { self.movieOutput.stopRecording() } }
    }

    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            queue.async {
                let settings = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
                    ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                    : AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .quality
                if let conn = self.photoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                self.handlerLock.lock(); self.photoHandlers[settings.uniqueID] = { c.resume(with: $0) }; self.handlerLock.unlock()
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let started = Date()
        Task { @MainActor in self.onPieceStarted?(fileURL, started) }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        var hitLimit = false
        var realError = error
        if let ns = error as NSError? {
            let finished = (ns.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            if ns.code == AVError.maximumDurationReached.rawValue { hitLimit = true }
            if finished { realError = nil }
        }
        let err = realError, limit = hitLimit
        Task { @MainActor in self.onPieceFinished?(outputFileURL, limit, err) }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        handlerLock.lock(); let handler = photoHandlers.removeValue(forKey: photo.resolvedSettings.uniqueID); handlerLock.unlock()
        if let error { handler?(.failure(error)); return }
        guard let data = photo.fileDataRepresentation() else { handler?(.failure(CameraError.setupFailed)); return }
        handler?(.success(data))
    }
}
