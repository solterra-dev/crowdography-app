import Foundation

/// Everything that touches the camera runs through here. Apple's camera code reports misuse by raising an
/// Objective-C exception, which closes the app on the spot; this turns it into an error the screen can show.
enum ExceptionGuard {
    static func run(_ work: () throws -> Void) throws {
        var inner: Error?
        try ObjCTry.run { do { try work() } catch { inner = error } }
        if let inner { throw inner }
    }
}
