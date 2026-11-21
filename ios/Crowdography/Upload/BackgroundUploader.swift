import Foundation

/// Sends original files straight to Crowdography's private storage with a short-lived signed address from Chronum.
/// Uses an iPhone background transfer, so a multi-gigabyte piece keeps uploading after the app is closed.
final class BackgroundUploader: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    static let shared = BackgroundUploader()
    static let sessionId = "com.crowdography.app.uploads"

    /// Set by the app delegate when iOS wakes the app for finished transfers.
    var systemCompletionHandler: (() -> Void)?
    /// Job id, HTTP status (0 if none) and error. Called on the main queue.
    var onFinished: (@MainActor (String, Int, Error?) -> Void)?

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.allowsCellularAccess = true
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// Job ids that already have a transfer running (for example one that survived the app being closed).
    func runningJobIds() async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap { $0.taskDescription })
    }

    func upload(jobId: String, file: URL, to url: URL) {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        let task = session.uploadTask(with: req, fromFile: file)
        task.taskDescription = jobId
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let id = task.taskDescription ?? ""
        Task { @MainActor in self.onFinished?(id, status, error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.systemCompletionHandler?()
            self.systemCompletionHandler = nil
        }
    }
}
