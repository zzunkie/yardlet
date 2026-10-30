import Foundation

extension AppModel {
    /// The task the new-task screen started takes over the screen's side panel, its terminal's shell
    /// and its browser tabs, which go on as they were: the Codex app's thread takes over its draft's
    /// tabs under the draft's id (`thread-workspace-draft-tabs-v1`). Called as soon as the task exists,
    /// before the window shows it, so the screen's shell is never left without a panel to show it. The
    /// browser engine's tabs keep their side-panel keys, so the task's panel tabs are the same tabs.
    func handOffDraftWorkspace(to taskID: UUID) {
        let client = taskWorkspaces.draft.browserClient
        taskWorkspaces.handOffDraft(to: taskID)
        client?.moveTabs(fromSession: TaskWorkspaceStore.draftID, toSession: taskID)
    }
}
