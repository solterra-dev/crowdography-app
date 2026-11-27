import AVFoundation
import CoreLocation
import CoreMedia
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
    private var cameraDevice: AVCaptureDevice?
    /// Build 21: a data track in the video file itself, carrying where the phone was and which way the camera pointed
    /// (Jeff 2026-11-26). Written while recording, so it is part of the original and inside the proof.
    private var metadataInput: AVCaptureMetadataInput?
    static let aimIdentifier = AVMetadataIdentifier(rawValue: "mdta/com.crowdography.camera.aim")

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
        if !configured {
            try ExceptionGuard.run { try self.buildSession() }      // begins and commits the configuration
            try? ExceptionGuard.run { try self.lockFrameRate() }    // after the commit, when the 4K format is active; not fatal if refused
            configured = true
        }
        // Starting the camera must happen AFTER the configuration is committed (build 10 did it before, which closed the app).
        if !session.isRunning { try ExceptionGuard.run { self.session.startRunning() } }
    }

    private func buildSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach { session.removeInput($0) }      // a clean start if an earlier try stopped half way
        session.outputs.forEach { session.removeOutput($0) }

        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw CameraError.noCamera }
        let camIn = try AVCaptureDeviceInput(device: cam)
        guard session.canAddInput(camIn) else { throw CameraError.setupFailed }
        session.addInput(camIn)
        cameraDevice = cam
        if let mic = AVCaptureDevice.default(for: .audio), let micIn = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micIn) {
            session.addInput(micIn)
        }
        if session.canSetSessionPreset(.hd4K3840x2160) { session.sessionPreset = .hd4K3840x2160 }
        else if session.canSetSessionPreset(.high) { session.sessionPreset = .high }

        guard session.canAddOutput(movieOutput) else { throw CameraError.setupFailed }
        session.addOutput(movieOutput)
        guard session.canAddOutput(photoOutput) else { throw CameraError.setupFailed }
        session.addOutput(photoOutput)
        movieOutput.maxRecordedDuration = CMTime(seconds: Config.maxPieceSeconds, preferredTimescale: 600)
        if let conn = movieOutput.connection(with: .video) {
            if movieOutput.availableVideoCodecTypes.contains(.hevc) {
                movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: conn)
            }
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        try? ExceptionGuard.run { self.addDataTrack() }   // never stops the camera: without it the separate signed path still has everything
    }

    /// Connects a timed data track to the movie output: the standard location format, plus the camera direction as short text.
    private func addDataTrack() {
        let specs: [[String: Any]] = [
            [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: AVMetadataIdentifier.quickTimeMetadataLocationISO6709.rawValue,
             kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String],
            [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: Self.aimIdentifier.rawValue,
             kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_UTF8 as String],
        ]
        var desc: CMFormatDescription?
        guard CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
                                                                          metadataSpecifications: specs as CFArray, formatDescriptionOut: &desc) == noErr,
              let desc else { return }
        let input = AVCaptureMetadataInput(formatDescription: desc, clock: CMClockGetHostTimeClock())
        guard session.canAddInput(input) else { return }
        session.addInputWithNoConnections(input)
        let conn = AVCaptureConnection(inputPorts: input.ports, output: movieOutput)
        guard session.canAddConnection(conn) else { session.removeInput(input); return }
        session.addConnection(conn)
        metadataInput = input
    }

    /// Adds one location reading to the data track of the piece being recorded (ignored between pieces).
    func appendLocation(_ l: CLLocation) {
        let text = CameraAim.iso6709(lat: l.coordinate.latitude, lng: l.coordinate.longitude, altitude: l.verticalAccuracy >= 0 ? l.altitude : nil)
        appendItem(AVMetadataIdentifier.quickTimeMetadataLocationISO6709, text, kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String)
    }
    /// Adds one camera-direction reading to the data track.
    func appendAim(_ text: String) { appendItem(Self.aimIdentifier, text, kCMMetadataBaseDataType_UTF8 as String) }

    private func appendItem(_ id: AVMetadataIdentifier, _ value: String, _ dataType: String) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async {
            guard let input = self.metadataInput, self.movieOutput.isRecording else { return }
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value as NSString
            item.dataType = dataType
            let group = AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(start: now, duration: .invalid))
            try? ExceptionGuard.run { try input.append(group) }
        }
    }

    private func lockFrameRate() throws {
        guard let cam = cameraDevice else { return }
        try cam.lockForConfiguration()
        defer { cam.unlockForConfiguration() }
        let d = CMTime(value: 1, timescale: Config.maxFramesPerSecond)
        let ok = cam.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameDuration <= d && d <= $0.maxFrameDuration }
        if ok { cam.activeVideoMinFrameDuration = d; cam.activeVideoMaxFrameDuration = d }
    }

    var isRecording: Bool { movieOutput.isRecording }

    func startPiece(to url: URL) {
        queue.async {
            do { try ExceptionGuard.run { self.movieOutput.startRecording(to: url, recordingDelegate: self) } }
            catch { let e = error; Task { @MainActor in self.onPieceFinished?(url, false, e) } }
        }
    }

    /// Turns the camera off. Used at sign out, so it is not left running behind the log-in screen. configure() turns it back on.
    func stop() {
        queue.async { try? ExceptionGuard.run { if self.session.isRunning { self.session.stopRunning() } } }
    }

    func stopPiece() {
        queue.async { try? ExceptionGuard.run { if self.movieOutput.isRecording { self.movieOutput.stopRecording() } } }
    }

    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            queue.async {
                var registered: Int64?
                do {
                    try ExceptionGuard.run {
                        let settings = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
                            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                            : AVCapturePhotoSettings()
                        settings.photoQualityPrioritization = .quality
                        if let conn = self.photoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                        self.handlerLock.lock(); self.photoHandlers[settings.uniqueID] = { c.resume(with: $0) }; self.handlerLock.unlock()
                        registered = settings.uniqueID
                        self.photoOutput.capturePhoto(with: settings, delegate: self)
                    }
                } catch {
                    // Answer exactly once: through the registered handler if there is one, otherwise directly.
                    self.handlerLock.lock(); let h = registered.flatMap { self.photoHandlers.removeValue(forKey: $0) }; self.handlerLock.unlock()
                    if let h { h(.failure(error)) } else if registered == nil { c.resume(throwing: error) }
                }
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
