import SwiftUI
import YardletRemote

/// A task's model, effort and permission mode as its composer on the Mac shows them (docs/REMOTE_PROTOCOL.md
/// §15.23), changed through the Mac's own controls. A choice the Mac asks about first is asked about here too, in
/// the Mac's words.
struct TaskSettingsView: View {
    let session: HostSession
    let taskID: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirming: (setting: RemoteSetting, choice: RemoteSetting.Choice)?
    @State private var isApplying = false

    static let shownRoles: Set<String> = ["mode", "plan", "permission", "model", "effort", "speed"]

    private var settings: [RemoteSetting] {
        (session.taskSettings[taskID] ?? []).filter { Self.shownRoles.contains($0.role ?? "") }
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(settings, id: \.id) { setting in
                    row(setting)
                }
                if settings.isEmpty {
                    Text("\(session.name) offers no settings for this task now.").foregroundStyle(.secondary)
                }
            }
            .disabled(isApplying || !session.isConnected)
            .navigationTitle("Model and Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .overlay { if isApplying { ProgressView() } }
            .task {
                // The Mac's menu reads its choices before it opens (`prepare`); this sheet is that menu.
                if (session.taskSettings[taskID] ?? []).contains(where: { $0.prepare == true }) {
                    await session.readTaskSettings(taskID, prepare: true)
                }
            }
            .alert(confirming?.choice.confirm?.title ?? "", isPresented: Binding(get: { confirming != nil },
                                                                                 set: { if !$0 { confirming = nil } }),
                   presenting: confirming) { pending in
                Button(pending.choice.confirm?.button ?? String(localized: "Continue"), role: .destructive) {
                    apply(pending.setting, pending.choice, confirmed: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(pending.choice.confirm?.message ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func row(_ setting: RemoteSetting) -> some View {
        if setting.choices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(setting.name, value: setting.title ?? setting.value)
                if let note = setting.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
        } else {
            Picker(selection: Binding(get: { setting.value }, set: { value in
                guard let choice = setting.choices.first(where: { $0.value == value }) else { return }
                if choice.confirm != nil {
                    confirming = (setting, choice)
                } else {
                    apply(setting, choice, confirmed: false)
                }
            })) {
                ForEach(setting.choices, id: \.value) { choice in
                    VStack(alignment: .leading) {
                        Text(choice.name)
                        if let description = choice.description { Text(description).font(.footnote) }
                    }
                    .tag(choice.value)
                }
            } label: {
                Text(setting.name)
                    .foregroundStyle(setting.elevated == true ? Color.orange : Color.primary)
            }
            .disabled(setting.prepare == true)
        }
    }

    private func apply(_ setting: RemoteSetting, _ choice: RemoteSetting.Choice, confirmed: Bool) {
        isApplying = true
        Task {
            await session.setTaskSetting(taskID, setting: setting.id, value: choice.value, confirmed: confirmed)
            isApplying = false
        }
    }

    /// "Opus 5.5 · High · Manual": the row's values in its order.
    static func summary(_ settings: [RemoteSetting]) -> String {
        settings.filter { shownRoles.contains($0.role ?? "") }.map { setting in
            setting.choices.first { $0.value == setting.value }?.name ?? setting.title ?? setting.value
        }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
