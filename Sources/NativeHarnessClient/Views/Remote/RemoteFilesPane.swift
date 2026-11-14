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
        _state = State(initialValue: model.filesPanel(for: taskID))
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

extension RemoteHostModel {
    /// The task's Files panel as it was left, with the local panel's reader, editor and drafts, whose changes the window
    /// keeps (`RemoteHostFiles.keep`).
    func filesPanel(for taskID: String) -> WorkspaceFilesState {
        let state = WorkspaceFilesState(preferences: files.panel(for: taskID),
                                        provider: RemoteWorkspaceFiles(model: self, taskID: taskID))
        state.onChange = { [weak files = self.files, weak state] in
            guard let files, let state else { return }
            files.keep(state.preferences, for: taskID)
        }
        return state
    }
}
