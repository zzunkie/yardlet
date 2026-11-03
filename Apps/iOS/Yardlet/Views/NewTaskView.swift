import PhotosUI
import SwiftUI
import YardletRemote

/// Starts a task on the Mac, as its new-task composer would with a project chosen and the words typed: on the
/// harness, model, effort, permission mode and worktree the Mac offers now (docs/REMOTE_PROTOCOL.md §15.5, §15.16).
struct NewTaskView: View {
    let session: HostSession
    let onStarted: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var projectID = ""
    @State private var harness: String?
    @State private var harnesses: [RemoteHarnessOption] = []
    @State private var settings: [RemoteSetting] = []
    @State private var picks: [String: String] = [:]
    @State private var worktree: Bool?
    @State private var images: [PickedImage] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isLoading = false
    @State private var isStarting = false
    @State private var error: String?
    @FocusState private var isWriting: Bool

    private var projects: [RemoteProject] { session.projects.filter { $0.canCreateTask == true } }
    private var acceptsImages: Bool { harnesses.first { $0.harness == harness }?.acceptsImages == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should it do?", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($isWriting)
                    if acceptsImages {
                        let count = images.count
                        PhotosPicker(selection: $pickerItems, maxSelectionCount: RemoteProtocol.maxImages - count,
                                     matching: .images) {
                            Label(count == 0 ? "Add Photos" : "\(count) photos", systemImage: "photo")
                        }
                    }
                }
                Section {
                    Picker("Project", selection: $projectID) {
                        ForEach(projects, id: \.id) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    if harnesses.count > 1 {
                        Picker("Agent", selection: Binding(get: { harness ?? "" }, set: { choose(harness: $0) })) {
                            ForEach(harnesses, id: \.harness) { Text($0.harnessName).tag($0.harness) }
                        }
                    }
                    ForEach(settings, id: \.id) { setting in
                        Picker(setting.name, selection: Binding(get: { picks[setting.id] ?? setting.value },
                                                                set: { pick(setting.id, $0) })) {
                            ForEach(setting.choices, id: \.value) { Text($0.name).tag($0.value) }
                        }
                    }
                    if let worktree {
                        Toggle("New Worktree", isOn: Binding(get: { worktree }, set: { self.worktree = $0 }))
                    }
                } footer: {
                    if isLoading { Text("Reading what \(session.name) offers…") }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || projectID.isEmpty
                                  || isStarting || !session.isConnected)
                }
            }
            .disabled(isStarting)
            .onAppear {
                if projectID.isEmpty { projectID = projects.first?.id ?? "" }
                isWriting = true
            }
            .task(id: projectID) { await readOptions() }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                pickerItems = []
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let image = PickedImage(data: data),
                           images.count < RemoteProtocol.maxImages {
                            images.append(image)
                        }
                    }
                }
            }
        }
    }

    private func choose(harness: String) {
        self.harness = harness
        picks = [:]
        Task { await readOptions() }
    }

    private func pick(_ setting: String, _ value: String) {
        picks[setting] = value
        // A setting may depend on another (an effort on its model): read the menus again after the pick.
        Task { await readOptions() }
    }

    private func readOptions() async {
        guard !projectID.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        let response = await session.response(to: .newTaskOptions(projectID: projectID, harness: harness, settings: picks))
        guard response.ok else {
            if response.error?.code == .notAllowed { picks = [:] }
            return
        }
        harness = response.harness
        harnesses = response.harnesses ?? []
        settings = (response.settings ?? []).filter { !$0.choices.isEmpty }
        picks = Dictionary(uniqueKeysWithValues: settings.map { ($0.id, $0.value) })
        worktree = response.worktree
    }

    private func start() {
        let start = RemoteTaskStart(projectID: projectID, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                    harness: harness, settings: picks, worktree: worktree,
                                    images: images.map { RemoteImage(type: "image/jpeg", data: $0.jpeg) })
        isStarting = true
        error = nil
        Task {
            let response = await session.response(to: .createTask(start))
            isStarting = false
            if response.ok, let taskID = response.taskId {
                onStarted(taskID)
            } else {
                error = response.error?.code == .notAllowed
                    ? String(localized: "\(session.name) doesn't offer that choice now. Pick again.")
                    : HostSession.message(for: response.error, host: session.name)
                if response.error?.code == .notAllowed { await readOptions() }
            }
        }
    }
}
