import SwiftUI
import YardletRemote

/// The same Files panel, bootstrapped from host metadata. Callers need only the task ID.
struct RemoteFilesPane: View {
    let model: RemoteHostModel
    let workspaceURL: URL?
    let taskID: String
    let onClose: () -> Void
    @State private var state: WorkspaceFilesState
    @State private var hasLoaded = false

    init(model: RemoteHostModel, taskID: String, workspaceURL: URL? = nil, onClose: @escaping () -> Void) {
        self.model = model
        self.taskID = taskID
        self.workspaceURL = workspaceURL
        self.onClose = onClose
        let state = WorkspaceFilesState(preferences: model.files.panels[taskID] ?? .init(),
                                        provider: RemoteWorkspaceFiles(model: model, taskID: taskID))
        state.onChange = { [weak model, weak state] in
            guard let model, let state else { return }
            model.files.panels[taskID] = state.preferences
        }
        _state = State(initialValue: state)
    }

    var body: some View {
        Group {
            if let root = state.resolvedWorkspace ?? workspaceURL {
                FilesPane(workspaceURL: root, state: state, onClose: onClose)
            } else if let error = state.indexError {
                WorkSurfaceEmptyState(title: L10n.string("Files unavailable"), message: error, systemName: "folder")
            } else if hasLoaded {
                WorkSurfaceEmptyState(title: L10n.string("Files unavailable"),
                    message: RemoteHostModel.message(for: RemoteError(.unavailable), host: model.name), systemName: "folder")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // An opaque provider identity, never a path on this Mac or a guessed host folder.
            let context = URL(string: "yardlet-remote://files/" + taskID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!
            await state.loadIndex(in: workspaceURL ?? context)
            hasLoaded = true
        }
    }
}
