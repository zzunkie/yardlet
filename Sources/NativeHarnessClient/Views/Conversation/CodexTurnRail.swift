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
    /// What a click on a mark does. A mark is drawn again only when what it shows changes, so it reads
    /// the rail's newest action when clicked rather than keeping the one of the rail it was drawn in.
    @State private var focusAction = FocusAction()

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

    /// The marks for a conversation's turns. Made once for the turns and handed to the rail as they are,
    /// so a rail made again for another focus compares the same marks at once.
    static func marks(for turns: [ConversationTurn]) -> [Turn] {
        turns.map { Turn(id: $0.id, status: status($0.status)) }
    }

    init(
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
        let _ = { focusAction.perform = onFocus }()
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
                            Mark(number: index + 1, count: turns.count, status: turn.status,
                                 isFocused: index == focusedIndex) { [focusAction] in
                                isFocused = true
                                focusAction.perform(turn.id)
                            }
                            .equatable()
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
        .onMacKeyPress(.previousItem) {
            moveFocus(by: -1)
            return .handled
        }
        .onMacKeyPress(.nextItem) {
            moveFocus(by: 1)
            return .handled
        }

    }

    /// One mark on the rail, drawn again only when what it shows changes: a new focus draws the mark it
    /// leaves and the one it reaches, not every turn's.
    private struct Mark: View, Equatable {
        let number: Int
        let count: Int
        let status: String
        let isFocused: Bool
        let action: () -> Void

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.number == rhs.number && lhs.count == rhs.count && lhs.status == rhs.status
                && lhs.isFocused == rhs.isFocused
        }

        var body: some View {
            Button(action: action) {
                Capsule()
                    .fill(isFocused ? Color.primary.opacity(0.72) : Color.secondary.opacity(0.38))
                    .frame(width: isFocused ? 7 : 5, height: isFocused ? 2 : 1)
                    .frame(width: 18, height: 7)
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(L10n.format("Turn %lld of %lld", Int64(number), Int64(count)))
            .accessibilityValue(status)
            .accessibilityAddTraits(isFocused ? .isSelected : [])
        }
    }

    @MainActor
    private final class FocusAction {
        var perform: (String) -> Void = { _ in }
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
