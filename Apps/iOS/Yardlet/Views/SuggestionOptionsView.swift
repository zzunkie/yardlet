import SwiftUI
import YardletRemote

/// A suggested task's Options (docs/REMOTE_PROTOCOL.md §15.9), as the Mac's chip opens them: the project it starts in,
/// the agent, its model, effort and permission mode, and the worktree, from the Mac's choices for what the chip's Start
/// starts with, read again after each pick as the Mac's menus take it. The picks stay on the phone until Start, which
/// starts the suggestion with what the sheet shows; the Mac checks them as it checks a new task's (§15.16).
struct SuggestionOptionsView: View {
    let session: HostSession
    let taskID: String
    let suggestionID: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    /// The Mac's last answer: what the chip starts with after the picks so far.
    @State private var answer: RemoteResponse?
    /// The person's own picks, over the chip's; nil and empty keep the chip's.
    @State private var harness: String?
    @State private var projectID: String?
    @State private var picks: [String: String] = [:]
    @State private var worktree: Bool?
    /// The read in flight; an answer to an older one is let go.
    @State private var readID: UUID?
    @State private var isStarting = false
    @State private var error: String?

    private var projects: [RemoteProject] { session.projects.filter { $0.canCreateTask == true } }
    private var settings: [RemoteSetting] { answer?.settings ?? [] }
    /// Where it starts: the person's pick, else the Mac's answer; empty for a folder no listed project holds.
    private var place: String { projectID ?? answer?.projectId ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let answer {
                        Picker("Project", selection: Binding(get: { place }, set: { choose(place: $0) })) {
                            if !projects.contains(where: { $0.id == place }) {
                                Text(answer.placeName ?? "").tag(place)
                            }
                            ForEach(projects, id: \.id) { project in
                                Text(project.name).tag(project.id)
                            }
                        }
                        if let harnesses = answer.harnesses, harnesses.count > 1 {
                            Picker("Agent", selection: Binding(get: { harness ?? answer.harness ?? "" },
                                                               set: { choose(harness: $0) })) {
                                ForEach(harnesses, id: \.harness) { Text($0.harnessName).tag($0.harness) }
                            }
                        }
                        ForEach(settings.filter { !$0.choices.isEmpty }, id: \.id) { setting in
                            Picker(setting.name, selection: Binding(get: { picks[setting.id] ?? setting.value },
                                                                    set: { pick(setting.id, $0) })) {
                                ForEach(setting.choices, id: \.value) { Text($0.name).tag($0.value) }
                            }
                        }
                        if let offered = answer.worktree {
                            Toggle("New Worktree", isOn: Binding(get: { worktree ?? offered }, set: {
                                worktree = $0
                                error = nil
                            }))
                        }
                    } else if error == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } header: {
                    Text(title).textCase(nil)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else if readID != nil {
                        Text("Reading what \(session.name) offers…")
                    }
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }
                        .disabled(answer == nil || readID != nil || isStarting || !session.isConnected)
                }
            }
            .disabled(isStarting)
            .task { await read() }
        }
        .presentationDetents([.medium, .large])
    }

    private func choose(place id: String) {
        guard id != place else { return }
        projectID = id
        worktree = nil
        reread()
    }

    private func choose(harness id: String) {
        guard id != (harness ?? answer?.harness) else { return }
        harness = id
        picks = [:]
        reread()
    }

    private func pick(_ setting: String, _ value: String) {
        picks[setting] = value
        // A setting may depend on another (an effort on its model): read the menus again after the pick.
        reread()
    }

    private func reread() {
        error = nil
        Task { await read() }
    }

    /// Reads the Mac's choices after the picks so far. A pick its menus no longer take (an effort the model just
    /// picked does not offer) is let go, all of them when the Mac does not name it.
    private func read() async {
        let id = UUID()
        readID = id
        defer { if readID == id { readID = nil } }
        var response = await session.response(to: request)
        if !response.ok, response.error?.reason == .setting, !picks.isEmpty {
            if let named = response.error?.setting, picks[named] != nil {
                picks[named] = nil
            } else {
                picks = [:]
            }
            response = await session.response(to: request)
        }
        guard readID == id else { return }
        guard response.ok else {
            error = HostSession.message(for: response.error, host: session.name)
            return
        }
        answer = response
        if response.worktree == nil { worktree = nil }
    }

    private var request: RemoteRequest {
        .suggestionOptions(taskID: taskID, suggestionID: suggestionID, harness: harness, settings: picks,
                           projectID: projectID)
    }

    /// Start with what the sheet shows: every setting's value, and the place and worktree the person chose.
    private func start() {
        guard let answer else { return }
        var values = picks
        for setting in settings where values[setting.id] == nil { values[setting.id] = setting.value }
        let choice = RemoteSuggestionStart(harness: harness ?? answer.harness, settings: values, projectID: projectID,
                                           worktree: worktree)
        isStarting = true
        error = nil
        Task {
            let response = await session.response(to: .actOnSuggestion(taskID: taskID, suggestionID: suggestionID,
                                                                       action: .start, start: choice))
            isStarting = false
            if response.ok {
                dismiss()
                return
            }
            let harnessName = answer.harnesses?.first { $0.harness == choice.harness }?.harnessName
            error = NewTaskView.message(for: response.error, host: session.name, harnessName: harnessName,
                                        settings: settings)
            // A choice the Mac does not take now: read what it offers again.
            if response.error?.code == .notAllowed { await read() }
        }
    }
}
