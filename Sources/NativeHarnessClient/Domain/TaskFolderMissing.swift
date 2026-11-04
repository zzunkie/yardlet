import Foundation

/// A task whose folder is gone — deleted, or the worktree it ran in removed — while its record and its
/// provider's conversation remain (2026-10-23). A harness starts in the task's
/// folder, so nothing is sent to the task while the folder is gone: what the person wrote stays in the
/// composer, which says so above it, as the Codex app's banner and the Claude app's notice say it. The
/// provider session ID and storage scope stay as they are. When the folder was a linked worktree whose
/// repository still has its branch, the worktree can be made again in the same place from that branch
/// (`worktreeBranch`), as the Codex app restores a worktree it cleaned up.
struct TaskFolderMissing: LocalizedError, Equatable, Sendable {
    let path: String
    /// The branch the task's worktree can be made again from, in the same place; nil when it cannot.
    var worktreeBranch: String? = nil

    init(path: String, worktreeBranch: String?) {
        self.path = path; self.worktreeBranch = worktreeBranch
    }

    /// Nil while the folder is there.
    init?(workspaceURL: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: workspaceURL.path(percentEncoded: false), isDirectory: &isDirectory),
           isDirectory.boolValue { return nil }
        path = ProjectSidebarPresentation.normalizedPath(for: workspaceURL)
    }

    var errorDescription: String? {
        L10n.format("This task's folder no longer exists: %@", path)
    }
}

/// Why a message for a task waits instead of going to it (`AppModel.sendRefusal`).
enum TaskSendRefusal: Equatable, Sendable {
    /// Another app's process holds the task's Claude conversation (`ConversationHeldElsewhere`).
    case heldElsewhere
    case folderMissing(TaskFolderMissing)

    /// What the composer says, kept with the message it did not send.
    var message: String {
        switch self {
        case .heldElsewhere: ConversationHeldElsewhere().localizedDescription
        case let .folderMissing(missing): missing.localizedDescription
        }
    }
}
