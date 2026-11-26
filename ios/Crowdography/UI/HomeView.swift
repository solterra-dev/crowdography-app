import SwiftUI

/// The first screen after logging in (Jeff 2026-11-25: the app opened the camera at once and had nothing to see past content).
/// Shows the account's footage, newest first. The camera opens only when the person taps Film.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var library: FootageLibrary
    @ObservedObject var queue: UploadQueue
    @State private var showCamera = false
    @State private var showGroups = false
    @State private var showUploads = false
    @State private var viewing: FootageItem?
    @State private var askSignOut = false
    @State private var signOutProblem: String?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if queue.pendingCount > 0 { uploadingBar }
                    if let problem = library.problem {
                        Text(problem).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.horizontal)
                    }
                    if !library.items.isEmpty {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(library.items) { tile($0) }
                        }
                    } else if !library.loadedOnce {
                        ProgressView().padding(.top, 80)
                    } else if library.problem == nil {
                        ContentUnavailableView("Nothing filmed yet", systemImage: "video",
                                               description: Text("Tap Film to record your first verified video or photo."))
                            .padding(.top, 40)
                    }
                }
                .padding(.bottom, 96)
            }
            .refreshable { await library.reload() }
            .navigationTitle("Your footage")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showGroups = true } label: { Label("Groups", systemImage: "person.3") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section(model.authorName ?? "Account") {
                            Button { showUploads = true } label: { Label("Uploads from this phone", systemImage: "arrow.up.circle") }
                        }
                        Section {
                            Button(role: .destructive) { askSignOut = true } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle").font(.title3)
                    }
                    .accessibilityLabel("Account")
                }
            }
            .overlay(alignment: .bottom) { filmButton }
        }
        .task { await library.reload() }
        .onChange(of: queue.pendingCount) { _, _ in Task { await library.reload() } }   // a clip just finished its check
        .fullScreenCover(isPresented: $showCamera, onDismiss: { model.closeCamera(); Task { await library.reload() } }) {
            CameraScreen(recorder: model.recorder, queue: model.queue).environmentObject(model)
        }
        .sheet(item: $viewing) { FootageViewer(item: $0, library: library) }
        .sheet(isPresented: $showGroups) { GroupsView().environmentObject(model) }
        .sheet(isPresented: $showUploads) { UploadsView(queue: queue, author: model.authorName).environmentObject(model) }
        .confirmationDialog("Sign out of Crowdography on this phone?", isPresented: $askSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { signOutProblem = await model.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your footage stays in your account. Log in again to see it and keep filming.")
        }
        .alert("Can't sign out yet", isPresented: Binding(get: { signOutProblem != nil }, set: { if !$0 { signOutProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(signOutProblem ?? "")
        }
    }

    private var uploadingBar: some View {
        Button { showUploads = true } label: {
            HStack(spacing: 10) {
                ProgressView()
                Text(queue.pendingCount == 1 ? "1 clip is still uploading or being checked" : "\(queue.pendingCount) clips are still uploading or being checked")
                    .font(.footnote)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote)
            }
            .padding(12).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal)
        }
        .buttonStyle(.plain)
    }

    private var filmButton: some View {
        VStack(spacing: 6) {
            if let g = model.gatheringName {
                Text("Filming into \(g)").font(.caption.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(.ultraThinMaterial, in: Capsule())
            }
            Button { showCamera = true } label: {
                Label("Film", systemImage: "video.fill").font(.headline).foregroundStyle(.white)
                    .padding(.horizontal, 34).padding(.vertical, 16).background(Color.red, in: Capsule())
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
            }
        }
        .padding(.bottom, 12)
        .accessibilityLabel("Film a video or take a photo")
    }

    private func tile(_ item: FootageItem) -> some View {
        Button { viewing = item } label: {
            Color.white.opacity(0.08).aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image = library.previews[item.id] {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: item.isVideo ? "video" : "photo").font(.title2).foregroundStyle(.secondary)
                    }
                }
                .clipped()
                .overlay(alignment: .topLeading) {
                    Image(systemName: item.verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(item.verified ? .green : .orange)
                        .padding(4).background(.black.opacity(0.45), in: Circle()).padding(4)
                }
                .overlay(alignment: .bottomTrailing) {
                    if item.isVideo {
                        Text(item.lengthLabel).font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4)).padding(4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.isVideo ? "Video" : "Photo"), \(item.startedAt.formatted(date: .abbreviated, time: .shortened)), \(item.verified ? "verified" : "not verified")")
        .onAppear {
            library.wantPreview(item)
            if item.id == library.items.last?.id { Task { await library.loadMore() } }
        }
    }
}
