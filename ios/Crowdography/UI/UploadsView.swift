import SwiftUI

/// Each piece and photo, and how far it has got: hashed, uploaded, verified.
struct UploadsView: View {
    @ObservedObject var queue: UploadQueue
    /// The name on the account, or nil while sign-in is not switched on.
    var author: String?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var askSignOut = false
    @State private var signingOut = false
    @State private var signOutProblem: String?

    var body: some View {
        NavigationStack {
            List(queue.jobs.reversed()) { job in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: job.isPhoto ? "photo" : "video")
                        Text(job.isPhoto ? "Photo" : "Video piece \(job.segmentNo)").font(.headline)
                        Spacer()
                        Text(label(job.stage)).font(.caption.weight(.semibold)).foregroundStyle(color(job.stage))
                    }
                    Text(job.startedAt.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    if let p = job.lastProblem { Text(p).font(.caption).foregroundStyle(.orange) }
                }
            }
            .overlay { if queue.jobs.isEmpty { Text("Nothing filmed yet.").foregroundStyle(.secondary) } }
            .safeAreaInset(edge: .bottom) {
                if let author {
                    VStack(spacing: 6) {
                        Text("Filmed by \(author) · name not yet verified")
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        // Sign out waits until nothing is left to upload, so no footage is stranded without its account.
                        Button(signingOut ? "Signing out…" : "Sign out") { askSignOut = true }
                            .font(.footnote).disabled(queue.pendingCount > 0 || signingOut)
                        if queue.pendingCount > 0 {
                            Text("You can sign out once everything here has finished uploading.").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let signOutProblem { Text(signOutProblem).font(.caption).foregroundStyle(.orange) }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8).background(.bar)
                }
            }
            .confirmationDialog("Sign out of Crowdography on this phone?", isPresented: $askSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    signingOut = true; signOutProblem = nil
                    Task { signOutProblem = await model.signOut(); signingOut = false }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your footage stays in your account. Log in again to keep filming.")
            }
            .navigationTitle("Your footage")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Retry") { queue.kick() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func label(_ s: CaptureJob.Stage) -> String {
        switch s {
        case .waiting: return "Waiting"
        case .hashing: return "Sealing"
        case .uploading: return "Uploading"
        case .submitting: return "Checking"
        case .verified: return "Verified"
        case .rejected: return "Not verified"
        case .failed: return "Will retry"
        }
    }

    private func color(_ s: CaptureJob.Stage) -> Color {
        switch s {
        case .verified: return .green
        case .rejected: return .red
        case .failed: return .orange
        default: return .secondary
        }
    }
}
