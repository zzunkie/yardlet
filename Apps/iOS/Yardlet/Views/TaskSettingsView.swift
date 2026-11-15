import SwiftUI
import YardletRemote

/// A task's model, effort and permission mode as its composer on the Mac shows them (docs/REMOTE_PROTOCOL.md
/// §15.23), changed through the Mac's own controls. A choice the Mac asks to confirm first, such as Bypass permissions
/// or Full access, lets an agent act without asking: it is chosen on the Mac, so the phone does not offer it, and shows
/// it only while the task already uses it. Why the Mac refused a change shows in the sheet.
struct TaskSettingsView: View {
    let session: HostSession
    let taskID: String
    @Environment(\.dismiss) private var dismiss
    @State private var isApplying = false
    @State private var refusal: String?

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
                if let refusal {
                    Section {
                        Text(refusal).font(.footnote).foregroundStyle(.red)
                    }
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
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func row(_ setting: RemoteSetting) -> some View {
        if setting.role == "plan" {
            // Codex's Plan indicator, sent while Plan mode is on: its command turns it off, as on the Mac.
            LabeledContent(setting.name) {
                Button("Turn Off") {
                    isApplying = true
                    Task {
                        _ = await session.runComposerCommand(taskID, name: "plan-mode")
                        isApplying = false
                    }
                }
            }
        } else if setting.choices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(setting.name, value: setting.title ?? setting.value)
                if let note = setting.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
        } else {
            Picker(selection: Binding(get: { setting.value }, set: { value in
                guard let choice = setting.choices.first(where: { $0.value == value }) else { return }
                apply(setting, choice)
            })) {
                ForEach(Self.offered(setting), id: \.value) { choice in
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

    private func apply(_ setting: RemoteSetting, _ choice: RemoteSetting.Choice) {
        isApplying = true
        refusal = nil
        Task {
            refusal = await session.setTaskSetting(taskID, setting: setting.id, value: choice.value)
            isApplying = false
        }
    }

    /// The choices the phone offers: those the Mac does not ask to confirm, and the one the task uses now.
    static func offered(_ setting: RemoteSetting) -> [RemoteSetting.Choice] {
        setting.choices.filter { $0.confirm == nil || $0.value == setting.value }
    }

    /// "Opus 5.5 · High · Manual": the row's values in its order. Plan mode has a chip of its own.
    static func summary(_ settings: [RemoteSetting]) -> String {
        settings.filter { shownRoles.contains($0.role ?? "") && $0.role != "plan" }.map { setting in
            setting.choices.first { $0.value == setting.value }?.name ?? setting.title ?? setting.value
        }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
