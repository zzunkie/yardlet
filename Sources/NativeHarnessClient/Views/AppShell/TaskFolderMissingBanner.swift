import SwiftUI

/// What a task whose folder is gone shows above its composer (`TaskFolderMissing`):
/// the fact and the folder, as the Codex app's "Current working directory missing" banner and the
/// Claude app's "Working folder no longer exists" say it, and, when its worktree's branch is still
/// there, the way back in the same place, as the Codex app's "Restore worktree".
struct TaskFolderMissingNotice {
    let missing: TaskFolderMissing
    let isRecreating: Bool
    let recreateWorktree: @MainActor () -> Void
}

private struct TaskFolderMissingNoticeKey: EnvironmentKey {
    static let defaultValue: TaskFolderMissingNotice? = nil
}

extension EnvironmentValues {
    /// The shown task's folder is gone.
    var taskFolderMissing: TaskFolderMissingNotice? {
        get { self[TaskFolderMissingNoticeKey.self] }
        set { self[TaskFolderMissingNoticeKey.self] = newValue }
    }
}

struct TaskFolderMissingBanner: View {
    let notice: TaskFolderMissingNotice

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Task folder not found"))
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if notice.missing.worktreeBranch != nil {
                Button(L10n.string("Recreate worktree"), action: notice.recreateWorktree)
                    .controlSize(.small)
                    .disabled(notice.isRecreating)
                    .parityPointer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(ParityTheme.separator, lineWidth: 1)
        }
        // The composer's column, so the fact sits over the message it keeps.
        .conversationColumn()
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        if let branch = notice.missing.worktreeBranch {
            L10n.format("This task's worktree %@ was removed. Its branch %@ is still there.", notice.missing.path, branch)
        } else {
            L10n.format("This task's folder %@ no longer exists.", notice.missing.path)
        }
    }
}
