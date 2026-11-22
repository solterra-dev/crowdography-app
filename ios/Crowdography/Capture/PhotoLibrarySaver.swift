import CoreLocation
import Foundation
import Photos

/// Puts an exact copy of each photo and video into the person's own photo library (Jeff 2026-11-21).
/// Add-only access: the app can add to the library but cannot look through it. The app keeps its own file for the
/// upload; the copy in the library is for the person, and the verified original is the one Chronum stores.
enum PhotoLibrarySaver {
    private static func isAllowed(_ s: PHAuthorizationStatus) -> Bool { s == .authorized || s == .limited }

    /// Asks once; later calls just report the answer.
    @discardableResult
    static func requestAccess() async -> Bool { isAllowed(await PHPhotoLibrary.requestAuthorization(for: .addOnly)) }

    /// Returns nil when saved (or when the person said no to library access), otherwise what went wrong.
    static func save(fileURL: URL, isVideo: Bool, takenAt: Date, place: CLLocation?) async -> String? {
        guard isAllowed(PHPhotoLibrary.authorizationStatus(for: .addOnly)) else { return nil }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false   // copy: the app's own file stays for the upload
                request.addResource(with: isVideo ? .video : .photo, fileURL: fileURL, options: options)
                request.creationDate = takenAt
                request.location = place
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
