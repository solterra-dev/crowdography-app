import BackgroundTasks
import UIKit

/// Jeff 2026-11-26: the work goes on when the app is open but not on the screen.
///   Uploads already use an iPhone background transfer that keeps going on its own.
///   Checking big files happens on the server (0.16), so it finishes even if this phone is closed.
///   What still needs the phone (sending the signed statement, asking how a check went, making and sending viewing copies)
///   runs: for about 30 seconds after the app leaves the screen, and again whenever iOS gives the app background time
///   (iOS decides when; often while charging, on Wi-Fi, or overnight).
enum BackgroundWork {
    static let processingId = "com.crowdography.app.work"
    static let refreshId = "com.crowdography.app.refresh"

    /// Called once at launch, before launch finishes, as iOS requires.
    static func register() {
        for id in [processingId, refreshId] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
                MainActor.assumeIsolated { handle(task) }
            }
        }
    }

    /// Asks iOS for background time later, when anything is still waiting.
    @MainActor static func schedule() {
        guard UploadQueue.shared.hasWaitingWork else { return }
        let p = BGProcessingTaskRequest(identifier: processingId)
        p.requiresNetworkConnectivity = true
        p.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(p)
        let r = BGAppRefreshTaskRequest(identifier: refreshId)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// The app just left the screen: keep going for the time iOS allows, then ask for more time later.
    @MainActor static func appLeftScreen() {
        schedule()
        let hold = Hold()
        hold.id = UIApplication.shared.beginBackgroundTask(withName: "Crowdography uploads") { MainActor.assumeIsolated { hold.end() } }
        let q = UploadQueue.shared
        q.kick()
        Task { @MainActor in
            for _ in 0..<14 where q.isBusy { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            hold.end()
        }
    }

    /// The background time iOS gave, ended exactly once.
    @MainActor private final class Hold {
        var id = UIBackgroundTaskIdentifier.invalid
        func end() { if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid } }
    }

    @MainActor private static func handle(_ task: BGTask) {
        let q = UploadQueue.shared
        q.attachFromKeychain()
        let work = Task { @MainActor in
            q.kick()
            for _ in 0..<120 {   // up to about 4 minutes, while iOS allows it
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled || !q.isBusy { break }
            }
            schedule()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}
