import SwiftUI

/// The account a working task moves to when its turn ends (`AppModel.chooseAccount`), and the way
/// to keep it where it is.
struct TaskAccountMoveNotice {
    let accountName: String
    /// The task is still in its turn; after it, the move waits for the background work left.
    var isInTurn = true
    let cancel: @MainActor () -> Void
}

private struct TaskAccountMoveNoticeKey: EnvironmentKey {
    static let defaultValue: TaskAccountMoveNotice? = nil
}

extension EnvironmentValues {
    /// The shown task moves to another account when its turn ends. Its composer queues what Return
    /// sends meanwhile, which goes after the move.
    var taskAccountMove: TaskAccountMoveNotice? {
        get { self[TaskAccountMoveNoticeKey.self] }
        set { self[TaskAccountMoveNoticeKey.self] = newValue }
    }
}

/// A line just above the composer, with the provider's notices (`ProviderNoticeLines`), in the words
/// the Claude app uses for a task that moves to another computer after its turn.
struct TaskAccountMoveLine: View {
    let notice: TaskAccountMoveNotice

    var body: some View {
        HStack(spacing: 8) {
            Label(L10n.format(notice.isInTurn ? "Moving to %@ after this turn" : "Moving to %@ when its background work ends",
                              notice.accountName), systemImage: "person.crop.circle")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(L10n.string("Cancel"), action: notice.cancel)
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
                .fixedSize()
                .parityPointer()
                .accessibilityLabel(L10n.string("Cancel account change"))
            Spacer(minLength: 0)
        }
        .font(.caption)
        .frame(maxWidth: ParityTheme.contentWidth, alignment: .leading)
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity)
    }
}
