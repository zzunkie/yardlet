import SwiftUI

/// The account a working task moves to when its turn ends (`AppModel.chooseAccount`), and the way
/// to keep it where it is.
struct TaskAccountMoveNotice {
    let accountName: String
    /// What the move waits for: the task's turn, and after it what still keeps the task busy
    /// (`AccountMoveHold`).
    var waitsFor: AccountMoveBlocker = .turn
    let cancel: @MainActor () -> Void
}

private struct TaskAccountMoveNoticeKey: EnvironmentKey {
    static let defaultValue: TaskAccountMoveNotice? = nil
}

extension EnvironmentValues {
    /// The shown task moves to another account when its turn ends. Its composer queues what Return
    /// sends during the turn, which goes after the move.
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
            Label(text, systemImage: "person.crop.circle")
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

    private var text: String {
        let name = notice.accountName
        return switch notice.waitsFor {
        case .turn: L10n.format("Moving to %@ after this turn", name)
        case .request: L10n.format("Moving to %@ once its request is answered", name)
        case .messages: L10n.format("Moving to %@ once the message on its way is delivered", name)
        case .shellCommand: L10n.format("Moving to %@ when its shell command ends", name)
        case .backgroundWork: L10n.format("Moving to %@ when its background work ends", name)
        case .agents: L10n.format("Moving to %@ when the agents it runs finish", name)
        case .edit: L10n.format("Moving to %@ once you finish editing the message", name)
        case .otherChange: L10n.format("Moving to %@ when the change under way ends", name)
        }
    }
}
