import Foundation
import WinUI

/// A task's conversation as the engine lays it out for every harness (`ConversationPresentation`), in the Mac's
/// column: at most 768 wide and centered in a wider window, with a 32 gutter, 24 above the first turn and 28 under
/// the last, 15 between turns. Each turn is drawn as the Mac's (`ConversationTurnElement`). A turn that did not change
/// keeps what it drew, so an answer streaming in redraws its own turn and nothing else, and the view stays at the end
/// while it was there. As on the Mac, only the latest turns are drawn (`ConversationTurnWindow`, 10 at first) and Load
/// more history above them draws 10 more, so what an update compares and draws is bounded by the window, however
/// long the conversation is. A host's conversation (`RemoteConversationModel`) and a task's own draw through it.
@MainActor
final class ConversationTimeline {
    let view = ScrollViewer()
    private let stack = StackPanel()
    private let turnsPanel = StackPanel()
    private let loadMore = Button()
    private var window = ConversationTurnWindow()
    private var conversationID: String?
    private var shown: (presentation: ConversationPresentation, requestNote: String?)?
    private var drawn: [String: ConversationTurnElement] = [:]
    private var order: [String] = []
    private var placeholder: String?
    /// The request cards, by turn and request, so what a form holds stays while its turn redraws.
    private var cards: [String: RequestCard] = [:]
    private var requestNote: String?
    /// Carries out the answer a request's card sent, with the route its form made, where the conversation can be
    /// answered here; without it a request shows `requestNote` instead of its answers.
    var respond: ((ConversationRequest, ConversationRequestResponse) -> Void)?
    /// Asks the provider or the host for the turns before the loaded ones, once the window shows every loaded turn.
    var loadEarlier: (() -> Void)?
    /// Retries a turn by its ID, as the Mac's error card offers it for a turn its provider says can pass; without it
    /// the card offers no Retry.
    var retry: (@MainActor (String) -> Void)?
    /// Signs in to the harness of a turn that failed for its sign-in, as the Mac's error card offers it; without
    /// it the failure only says so.
    var signIn: HarnessSignIn?
    /// The task's folder, which a file change's paths are read against; nil for another computer's task.
    var workspaceURL: URL?

    init() {
        stack.spacing = ConversationStyle.turnSpacing
        stack.padding = Thickness(left: WindowsTheme.conversationInset, top: ConversationStyle.topPadding,
                                  right: WindowsTheme.conversationInset, bottom: ConversationStyle.bottomPadding)
        // The column's width is set from the view's rather than stretched up to a maximum: the scroll view places
        // its content by the width the content asks for, so a stretched column whose turns asked for less stood
        // to the right of the middle.
        stack.horizontalAlignment = .center
        view.sizeChanged.addHandler { [weak self] _, _ in self?.fitColumn() }
        turnsPanel.spacing = ConversationStyle.turnSpacing
        view.horizontalScrollBarVisibility = .disabled
        loadMore.content = L10n.string("Load more history")
        loadMore.visibility = .collapsed
        loadMore.horizontalAlignment = .center
        loadMore.click.addHandler { [weak self] _, _ in self?.showMore() }
        stack.children.append(loadMore)
        stack.children.append(turnsPanel)
        view.content = stack
    }

    /// The conversation `conversationID` names, or `placeholder` in its place while there is none. Another
    /// conversation starts again from its latest turns. `requestNote` says where a request waiting in it is
    /// answered, for a conversation that cannot answer it here.
    func show(_ presentation: ConversationPresentation?, conversationID: String?, placeholder: String? = nil,
              requestNote: String? = nil) {
        if conversationID != self.conversationID {
            self.conversationID = conversationID
            window = ConversationTurnWindow()
            turnsPanel.children.clear()
            drawn = [:]
            order = []
            cards = [:]
        }
        guard let presentation, !presentation.turns.isEmpty else {
            shown = nil
            loadMore.visibility = .collapsed
            guard self.placeholder != placeholder || !order.isEmpty else { return }
            turnsPanel.children.clear()
            drawn = [:]
            order = []
            self.placeholder = placeholder
            if let placeholder {
                turnsPanel.children.append(ConversationStyle.text(placeholder, tone: .secondary))
            }
            return
        }
        if self.placeholder != nil || order.isEmpty {
            turnsPanel.children.clear()
            self.placeholder = nil
        }
        shown = (presentation, requestNote)
        let windowed = window.apply(to: presentation)
        loadMore.visibility = windowed.earlier != .none && (loadEarlier != nil || windowed.earlier.isLocal) ? .visible : .collapsed
        draw(windowed, requestNote: requestNote)
    }

    /// The column as wide as the view, up to its widest, in the middle of a wider view.
    private func fitColumn() {
        stack.width = min(WindowsTheme.contentWidth, max(0, view.actualWidth))
    }

    /// Ten more of the loaded turns, or once every loaded turn shows, the ones before them.
    private func showMore() {
        guard let shown else { return }
        if window.apply(to: shown.presentation).earlier.isLocal {
            window = window.widened()
            show(shown.presentation, conversationID: conversationID, requestNote: shown.requestNote)
        } else {
            loadEarlier?()
        }
    }

    private func draw(_ presentation: ConversationPresentation, requestNote: String?) {
        let followsEnd = isAtEnd
        let noteChanged = requestNote != self.requestNote
        self.requestNote = requestNote
        let context = turnContext(harness: presentation.harness)
        var next: [String: ConversationTurnElement] = [:]
        for turn in presentation.turns {
            if let element = drawn[turn.id] {
                if noteChanged || !(turn.isUnchanged(from: element.turn) || turn == element.turn) {
                    element.update(turn, context: context)
                }
                next[turn.id] = element
            } else {
                next[turn.id] = ConversationTurnElement(turn: turn, context: context)
            }
        }
        let ids = presentation.turns.map(\.id)
        if ids.starts(with: order) {
            // Turns only came after the ones shown: the turns kept redraw in place, the new ones are added.
            for id in ids.dropFirst(order.count) {
                if let element = next[id] { turnsPanel.children.append(element.view) }
            }
        } else {
            turnsPanel.children.clear()
            for id in ids {
                if let element = next[id] { turnsPanel.children.append(element.view) }
            }
        }
        drawn = next
        order = ids
        if followsEnd { _ = try? view.changeView(nil, 1_000_000, nil) }
    }

    private var isAtEnd: Bool {
        view.verticalOffset >= view.scrollableHeight - 48
    }

    private func turnContext(harness: HarnessKind) -> ConversationTurnContext {
        ConversationTurnContext(
            harness: harness, workspaceURL: workspaceURL,
            card: { [weak self] request, turn in
                self?.card(for: request, in: turn) ?? RequestCard(request: request, respond: nil, note: nil)
            },
            retry: retry, signIn: signIn
        )
    }

    /// The card for `request` as it stands, the same one while the request is in the turn.
    private func card(for request: ConversationRequest, in turn: ConversationTurn) -> RequestCard {
        let key = turn.id + "\n" + request.id
        if let card = cards[key] {
            card.update(request, respond: respond, note: requestNote)
            return card
        }
        let card = RequestCard(request: request, respond: respond, note: requestNote, workspaceURL: workspaceURL)
        cards[key] = card
        return card
    }
}

private extension ConversationEarlierTurns {
    /// Loaded turns the window leaves out, which widening it shows.
    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
}
