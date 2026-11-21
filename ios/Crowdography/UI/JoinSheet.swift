import SwiftUI

/// Join a host's gathering with their 8-character code, or film anywhere without one.
struct JoinSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if let name = model.gatheringName {
                    Section("Current gathering") {
                        Text(name)
                        if model.hostSeesOriginals {
                            Text("The host of this gathering can see the full-quality originals you film here.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Leave and film anywhere", role: .destructive) { model.leaveGathering(); dismiss() }
                    }
                }
                Section {
                    TextField("8-character code", text: $code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled().font(.title3.monospaced())
                        .onChange(of: code) { _, v in code = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8)) }
                    Button(busy ? "Joining…" : "Join gathering") {
                        busy = true
                        Task { await model.join(code: code); busy = false; if model.gatheringName != nil { dismiss() } }
                    }
                    .disabled(code.count != 8 || busy)
                } header: { Text("Join a gathering") } footer: {
                    Text("You don't need a gathering. Anything you film anywhere is still proven real; gatherings just keep a group's footage together.")
                }
            }
            .navigationTitle("Gathering")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
