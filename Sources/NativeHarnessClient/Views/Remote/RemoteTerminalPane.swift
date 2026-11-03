import SwiftUI

/// The same tab, split, close and restart controls, supplied with a remote shell factory.
struct RemoteTerminalPane: View {
    let workspace: TaskWorkspaceState
    let workspaceURL: URL
    let onClose: () -> Void
    let onAttachSelection: ((String, String) -> Void)?

    init(model: RemoteHostModel, taskID: String, workspaceURL: URL? = nil,
         onAttachSelection: ((String, String) -> Void)? = nil, onOpenLink: ((URL) -> Void)? = nil, onClose: @escaping () -> Void) {
        let owner = model.terminals
        let state = owner.workspaces[taskID] ?? TaskWorkspaceState()
        state.terminalFactory = { [weak owner, weak state] folder, launch, _ in
            // The owner outlives its window's panels. A missing owner supplies a closed stream.
            let stream = owner?.makeStream(taskID: taskID) ?? RemoteTerminalStream(owner: nil, taskID: taskID)
            let session = NativeTerminalSession(workspaceURL: folder, launch: launch, hosting: RemoteTerminalHosting(stream: stream))
            session.disableClipboardAccess()
            session.onOpenLink = onOpenLink
            session.onExit = { [weak session] _ in
                Task { @MainActor in
                    if let session, !session.hasVisiblePanel { session.end() }
                }
            }
            session.onStop = { [weak owner, weak state] in
                Task { @MainActor in
                    if let state, state.terminals.isEmpty, owner?.workspaces[taskID] === state {
                        owner?.workspaces[taskID] = nil
                    }
                }
            }
            return session
        }
        for session in state.terminals { session.onOpenLink = onOpenLink }
        owner.workspaces[taskID] = state
        workspace = state
        self.workspaceURL = workspaceURL ?? URL(string: "yardlet-remote://terminal/" + taskID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!
        self.onClose = onClose
        self.onAttachSelection = onAttachSelection
    }

    var body: some View {
        let _ = workspace.terminalRevision
        let session = workspace.terminal(in: workspaceURL, launch: .userLoginShell(), taskID: nil)
        VStack(spacing: 0) {
            TerminalPane(session: session, tabs: TerminalTabsContext(workspace: workspace, folder: session.workspaceURL,
                launch: .userLoginShell(), taskID: nil), onAttachSelection: onAttachSelection,
                isInSidePanel: true, onClose: onClose)
            Text(L10n.string("Closing this window or losing the connection ends its terminals."))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}
