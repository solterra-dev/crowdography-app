import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iOS wakes the app when background uploads finish; hand the system's callback to the uploader.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == BackgroundUploader.sessionId { BackgroundUploader.shared.systemCompletionHandler = completionHandler }
    }
}

@main
struct CrowdographyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, p in if p == .active { model.appBecameActive() } }
                .preferredColorScheme(.dark)
        }
    }
}
