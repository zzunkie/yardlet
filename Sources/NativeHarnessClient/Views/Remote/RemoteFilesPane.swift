import SwiftUI

/// The same Files panel, with all file access supplied by the host. Key the wrapper by task ID.
struct RemoteFilesPane: View {
    let workspaceURL: URL
    let onClose: () -> Void
    @State private var state: WorkspaceFilesState

    init(model: RemoteHostModel, taskID: String, workspaceURL: URL, onClose: @escaping () -> Void) {
        self.workspaceURL = workspaceURL
        self.onClose = onClose
        _state = State(initialValue: WorkspaceFilesState(provider: RemoteWorkspaceFiles(model: model, taskID: taskID)))
    }

    var body: some View {
        FilesPane(workspaceURL: workspaceURL, state: state, onClose: onClose)
    }
}
