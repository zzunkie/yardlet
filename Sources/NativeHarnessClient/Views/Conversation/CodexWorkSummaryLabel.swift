import SwiftUI

struct CodexWorkSummaryLabel: View {
    /// The turn is still running, and counts its seconds.
    let isRunning: Bool
    let startedAt: Date?
    /// What a finished turn reads: how long it worked, or that it was stopped.
    let finishedTitle: String
    let isExpanded: Bool
    let canExpand: Bool

    @State private var firstObservedAt = Date()

    init(turn: CodexTurnState, isExpanded: Bool, canExpand: Bool) {
        isRunning = turn.status == .inProgress
        startedAt = turn.startedAt
        finishedTitle = CodexTurnProgressProjection.finishedTitle(
            status: turn.status,
            duration: CodexTurnProgressProjection.completedDuration(
                durationMilliseconds: turn.durationMilliseconds,
                startedAt: turn.startedAt,
                completedAt: turn.completedAt
            )
        )
        self.isExpanded = isExpanded
        self.canExpand = canExpand
    }

    /// A conversation turn whose times the provider reported.
    init(turn: ConversationTurn, isExpanded: Bool, canExpand: Bool) {
        isRunning = turn.status == .running
        startedAt = turn.timing.startedAt
        finishedTitle = turn.workTimeTitle
        self.isExpanded = isExpanded
        self.canExpand = canExpand
    }

    /// The header's words, which its caret is set on.
    static let fontSize: CGFloat = 11.5

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsedSeconds = CodexTurnProgressProjection.elapsedSeconds(
                        startedAt: startedAt ?? firstObservedAt,
                        now: context.date
                    )
                    Text(L10n.format("Working for %lld seconds", elapsedSeconds))
                        .monospacedDigit()
                }
            } else {
                Text(finishedTitle)
                    .conversationSelectionText(finishedTitle)
            }

            if canExpand {
                DisclosureCaret(isOpen: isExpanded)
                    .centeredOnCapHeight(ofTextSize: Self.fontSize)
            }
        }
        .font(.system(size: Self.fontSize))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
