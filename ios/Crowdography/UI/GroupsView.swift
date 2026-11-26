import SwiftUI

/// Groups (Jeff 2026-11-26): start a group and share its code, join one with a code, and watch every angle of a group.
struct GroupsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [GroupSummary] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var showStart = false
    @State private var showJoin = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showStart = true } label: { Label("Start a group", systemImage: "plus.circle.fill") }
                    Button { showJoin = true } label: { Label("Join with a code", systemImage: "number") }
                } footer: {
                    Text("Everyone in a group can watch every angle the group films, lined up to the same moment, with the name of who filmed it.")
                }
                if let name = model.gatheringName {
                    Section("Filming into") {
                        Text(name)
                        Button("Stop filming into this group", role: .destructive) { model.leaveGathering() }
                    }
                }
                Section("Your groups") {
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
                    if loaded && groups.isEmpty && problem == nil { Text("No groups yet.").foregroundStyle(.secondary) }
                    if !loaded { ProgressView() }
                    ForEach(groups) { g in
                        NavigationLink { GroupWatchView(summary: g, model: model) } label: { row(g) }
                    }
                }
            }
            .navigationTitle("Groups")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showStart, onDismiss: { Task { await load() } }) { StartGroupSheet().environmentObject(model) }
            .sheet(isPresented: $showJoin, onDismiss: { Task { await load() } }) { JoinSheet().environmentObject(model) }
        }
    }

    private func load() async {
        do { groups = try await model.myGroups(); problem = nil } catch { problem = error.localizedDescription }
        loaded = true
    }

    private func row(_ g: GroupSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(g.name).font(.headline).lineLimit(1)
                if g.isLive { Text("LIVE").font(.caption2.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2).background(Color.red, in: Capsule()) }
            }
            Text("\(g.clipCount) \(g.clipCount == 1 ? "clip" : "clips") from \(g.phoneCount) \(g.phoneCount == 1 ? "phone" : "phones") · \(g.startsAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if let code = g.joinCode { Text("Code \(code)").font(.caption.monospaced()).foregroundStyle(.secondary) }
        }
    }
}

/// Start a group where you are now, and share its code with the people filming.
struct StartGroupSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hours = 4
    @State private var busy = false
    @State private var problem: String?
    @State private var started: AppModel.StartedGroup?

    var body: some View {
        NavigationStack {
            Form {
                if let s = started {
                    Section {
                        VStack(spacing: 12) {
                            Text("Share this code").font(.headline)
                            Text(s.code).font(.system(size: 40, weight: .bold, design: .monospaced)).textSelection(.enabled)
                            ShareLink(item: "Join my Crowdography group \"\(s.name)\" with the code \(s.code)") { Label("Share code", systemImage: "square.and.arrow.up") }
                                .buttonStyle(.borderedProminent)
                            Text("Anything you film now goes into this group. You can see the code again under Groups.")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                } else {
                    Section {
                        TextField("Name, like Portsmouth Christmas Parade", text: $name)
                        Picker("Lasts", selection: $hours) {
                            ForEach([1, 2, 4, 8, 12, 24], id: \.self) { Text("\($0) \($0 == 1 ? "hour" : "hours")").tag($0) }
                        }
                    } footer: {
                        Text("The group covers about 3 miles around where you are now. Footage filmed farther away or after it ends is not added.")
                    }
                    if let problem { Section { Text(problem).font(.footnote).foregroundStyle(.orange) } }
                    Section {
                        Button(busy ? "Starting…" : "Start group") { start() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                }
            }
            .navigationTitle("Start a group")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func start() {
        busy = true; problem = nil
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        Task {
            do { started = try await model.startGroup(name: n, hours: hours) } catch { problem = error.localizedDescription }
            busy = false
        }
    }
}
