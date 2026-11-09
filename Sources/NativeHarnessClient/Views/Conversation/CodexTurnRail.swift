import SwiftUI

struct CodexTurnRail: View, Equatable {
    /// One mark on the rail: the turn it moves to and the status it reads out.
    struct Turn: Identifiable, Equatable, Sendable {
        let id: String
        let status: String
    }

    let turns: [Turn]
    let focusedTurnID: String?
    let onFocus: (String) -> Void
    let hasMoreTurns: Bool
    /// Where "Load more history" brings turns from, which its action reads. A rail compared
    /// `.equatable()` is drawn again only when its marks, focus or this change, not on every update
    /// of the conversation beside it.
    var moreTurns = ""
    let onLoadMore: () -> Void
    @FocusState private var isFocused: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.turns == rhs.turns && lhs.focusedTurnID == rhs.focusedTurnID && lhs.hasMoreTurns == rhs.hasMoreTurns
            && lhs.moreTurns == rhs.moreTurns
    }

    init(
        turns: [CodexTurnState], focusedTurnID: String?, onFocus: @escaping (String) -> Void,
        hasMoreTurns: Bool, onLoadMore: @escaping () -> Void
    ) {
        self.init(
            marks: turns.map { Turn(id: $0.id, status: Self.status($0.status)) }, focusedTurnID: focusedTurnID,
            onFocus: onFocus, hasMoreTurns: hasMoreTurns, onLoadMore: onLoadMore
        )
    }

    init(
        turns: [ConversationTurn], focusedTurnID: String?, onFocus: @escaping (String) -> Void,
        hasMoreTurns: Bool, moreTurns: String = "", onLoadMore: @escaping () -> Void
    ) {
        self.init(
            marks: turns.map { Turn(id: $0.id, status: Self.status($0.status)) }, focusedTurnID: focusedTurnID,
            onFocus: onFocus, hasMoreTurns: hasMoreTurns, moreTurns: moreTurns, onLoadMore: onLoadMore
        )
    }

    private init(
        marks: [Turn], focusedTurnID: String?, onFocus: @escaping (String) -> Void,
        hasMoreTurns: Bool, moreTurns: String = "", onLoadMore: @escaping () -> Void
    ) {
        turns = marks
        self.focusedTurnID = focusedTurnID
        self.onFocus = onFocus
        self.hasMoreTurns = hasMoreTurns
        self.moreTurns = moreTurns
        self.onLoadMore = onLoadMore
    }

    private var focusedIndex: Int? {
        CodexTimelineNavigation.focusedIndex(
            turnIDs: turns.map(\.id),
            focusedID: focusedTurnID
        )
    }

    var body: some View {
        let focusedIndex = focusedIndex
        VStack(spacing: 4) {
            if hasMoreTurns {
                Button {
                    onLoadMore()
                } label: {
                    // The rail's whole width takes the click, not the small chevron alone.
                    Image(systemName: "chevron.up")
                        .font(.system(size: 7, weight: .semibold))
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .parityPointer()
                .help(L10n.string("Load more history"))
                .accessibilityLabel(L10n.string("Load more history"))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                            Button {
                                isFocused = true
                                onFocus(turn.id)
                            } label: {
                                Capsule()
                                    .fill(index == focusedIndex ? Color.primary.opacity(0.72) : Color.secondary.opacity(0.38))
                                    .frame(
                                        width: index == focusedIndex ? 7 : 5,
                                        height: index == focusedIndex ? 2 : 1
                                    )
                                    .frame(width: 18, height: 7)
                            }
                            .buttonStyle(.plain)
                            .parityPointer()
                            .accessibilityLabel(
                                L10n.format("Turn %lld of %lld", Int64(index + 1), Int64(turns.count))
                            )
                            .accessibilityValue(turn.status)
                            .accessibilityAddTraits(index == focusedIndex ? .isSelected : [])
                            .id("rail-" + turn.id)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onChange(of: focusedTurnID) { _, id in
                    if let id { proxy.scrollTo("rail-" + id, anchor: .center) }
                }
                .onChange(of: turns.count) { _, _ in
                    if let id = focusedTurnID ?? turns.last?.id {
                        proxy.scrollTo("rail-" + id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 24)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 12)
        .focusable()
        .focused($isFocused)
        .focusSection()
        .onKeyPress(.upArrow) {
            moveFocus(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveFocus(by: 1)
            return .handled
        }

    }

    private func moveFocus(by offset: Int) {
        guard let targetID = CodexTimelineNavigation.targetID(
            turnIDs: turns.map(\.id),
            focusedID: focusedTurnID,
            offset: offset
        ) else { return }
        onFocus(targetID)
    }

    private static func status(_ status: CodexTurnStatus) -> String {
        switch status {
        case .inProgress: L10n.string("Running")
        case .completed: L10n.string("Completed")
        case .interrupted: L10n.string("Interrupted")
        case .failed: L10n.string("Failed")
        case .unknown: L10n.string("Unknown")
        }
    }

    private static func status(_ status: ConversationTurnStatus) -> String {
        switch status {
        case .running: L10n.string("Running")
        case .completed: L10n.string("Completed")
        case .interrupted: L10n.string("Interrupted")
        case .failed: L10n.string("Failed")
        case .unknown: L10n.string("Unknown")
        }
    }
}
