import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundWork.register()          // build 24: iOS may give the app time later to finish its work
        _ = UploadQueue.shared             // so finished background uploads are heard even before a screen starts
        return true
    }

    /// iOS wakes the app when background uploads finish; hand the system's callback to the uploader, and carry on with
    /// the next steps (the signed statement) while the app is awake.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == BackgroundUploader.sessionId { BackgroundUploader.shared.systemCompletionHandler = completionHandler }
        UploadQueue.shared.attachFromKeychain()
        UploadQueue.shared.kick()
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
                .onChange(of: scenePhase) { _, p in
                    if p == .active { model.appBecameActive() }
                    if p == .background { BackgroundWork.appLeftScreen() }   // build 24: keep working off the screen
                }
                .preferredColorScheme(.dark)
        }
    }
}
