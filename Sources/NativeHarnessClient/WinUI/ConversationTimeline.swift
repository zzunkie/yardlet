import Foundation
import WinUI

/// A task's conversation as the engine lays it out for every harness (`ConversationPresentation`), drawn turn by
/// turn: what was sent, a line for each step of the work (a change to files opens to its diff, `FileChangeView`), the
/// answers with their Markdown (`MarkdownView`), the requests waiting and how the turn ended. A turn that did not
/// change keeps what it drew, so an answer streaming in
/// redraws its own turn and nothing else, and the view stays at the end while it was there. As on the Mac, only the
/// latest turns are drawn (`ConversationTurnWindow`, 10 at first) and Load more history above them draws 10 more,
/// so what an update compares and draws is bounded by the window, however long the conversation is. A host's
/// conversation (`RemoteConversationModel`) and a task's own draw through it.
@MainActor
final class ConversationTimeline {
    let view = ScrollViewer()
    private let stack = StackPanel()
    private let turnsPanel = StackPanel()
    private let loadMore = Button()
    private var window = ConversationTurnWindow()
    private var conversationID: String?
    private var shown: (presentation: ConversationPresentation, requestNote: String?)?
    private var drawn: [String: (turn: ConversationTurn, element: StackPanel)] = [:]
    private var order: [String] = []
    private var placeholder: String?
    /// Carries out the answer a request's button chose, where the conversation can be answered here; without it a
    /// request shows `requestNote` instead of its buttons.
    var respond: ((ConversationRequest, ConversationRequestResponse) -> Void)?
    /// Asks the provider or the host for the turns before the loaded ones, once the window shows every loaded turn.
    var loadEarlier: (() -> Void)?
    /// The task's folder, which a file change's paths are read against; nil for another computer's task.
    var workspaceURL: URL?

    init() {
        stack.spacing = 20
        turnsPanel.spacing = 20
        view.padding = Thickness(left: 28, top: 20, right: 28, bottom: 12)
        loadMore.content = L10n.string("Load more history")
        loadMore.visibility = .collapsed
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
        }
        guard let presentation, !presentation.turns.isEmpty else {
            shown = nil
            loadMore.visibility = .collapsed
            guard self.placeholder != placeholder || !order.isEmpty else { return }
            turnsPanel.children.clear()
            drawn = [:]
            order = []
            self.placeholder = placeholder
            if let placeholder { turnsPanel.children.append(Self.text(placeholder, muted: true)) }
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
        var next: [String: (turn: ConversationTurn, element: StackPanel)] = [:]
        for turn in presentation.turns {
            if let earlier = drawn[turn.id], turn.isUnchanged(from: earlier.turn) || turn == earlier.turn {
                next[turn.id] = (turn, earlier.element)
            } else {
                next[turn.id] = (turn, draw(turn, harness: presentation.harness, requestNote: requestNote))
            }
        }
        let ids = presentation.turns.map(\.id)
        if ids.starts(with: order) {
            // Turns only came after the ones shown: replace the ones that changed, add the new ones.
            for (index, id) in order.enumerated() where next[id]?.element !== drawn[id]?.element {
                if let element = next[id]?.element { turnsPanel.children.setAt(UInt32(index), element) }
            }
            for id in ids.dropFirst(order.count) {
                if let element = next[id]?.element { turnsPanel.children.append(element) }
            }
        } else {
            turnsPanel.children.clear()
            for id in ids {
                if let element = next[id]?.element { turnsPanel.children.append(element) }
            }
        }
        drawn = next
        order = ids
        if followsEnd { _ = try? view.changeView(nil, 1_000_000, nil) }
    }

    private var isAtEnd: Bool {
        view.verticalOffset >= view.scrollableHeight - 48
    }

    private func draw(_ turn: ConversationTurn, harness: HarnessKind, requestNote: String?) -> StackPanel {
        let panel = StackPanel()
        panel.spacing = 8
        for item in turn.prompt + turn.notices + turn.work + turn.answers {
            if let element = Self.element(for: item, harness: harness, workspaceURL: workspaceURL) {
                panel.children.append(element)
            }
        }
        for request in turn.requests where request.state == .pending {
            panel.children.append(Self.text(request.title))
            if let detail = request.detail ?? request.command { panel.children.append(Self.text(detail, muted: true)) }
            // A form's answers (questions, a plan's review) are not drawn here yet; the card's buttons are.
            let answers = request.responses.filter {
                switch $0.route {
                case .decision, .providerAction, .codex: true
                case .structured, .answer: false
                }
            }
            if let respond, !answers.isEmpty {
                let row = StackPanel()
                row.orientation = .horizontal
                row.spacing = 8
                for response in answers {
                    let button = Button()
                    button.content = response.title
                    button.click.addHandler { [weak row] _, _ in
                        // One answer per request: the row stops taking clicks, and the card redraws once the task
                        // takes the answer.
                        row?.isHitTestVisible = false
                        row?.opacity = 0.6
                        respond(request, response)
                    }
                    row.children.append(button)
                }
                panel.children.append(row)
            } else if let requestNote {
                panel.children.append(Self.text(requestNote, muted: true))
            }
        }
        if case let .error(error) = turn.outcome {
            panel.children.append(Self.text([error.title, error.summary].compactMap { $0 }.joined(separator: "\n")))
        }
        switch turn.progress {
        case .thinking: panel.children.append(Self.text(L10n.string("Thinking"), muted: true))
        case let .reconnecting(message): panel.children.append(Self.text(message, muted: true))
        case .none: break
        }
        return panel
    }

    private static func element(for item: ConversationItem, harness: HarnessKind, workspaceURL: URL?) -> UIElement? {
        switch item.kind {
        case let .userMessage(message, _):
            let block = StackPanel()
            block.spacing = 4
            block.children.append(text(L10n.string("You"), muted: true, size: 12))
            block.children.append(text(message))
            return block
        case let .scheduledTaskMessage(message):
            return text(message.instructions)
        case let .answer(body, _), let .commentary(body, _), let .proposedPlan(body, _):
            return MarkdownView.element(body)
        case let .reasoning(summary, _, _):
            return text(summary ?? L10n.string("Thinking"), muted: true)
        case let .command(command):
            let words = ConversationLineWording.command(command, phase: item.phase, harness: harness).map(\.text)
            return words.isEmpty ? nil : text(words.joined(separator: ", "), muted: true)
        case let .tool(tool):
            let words = ConversationLineWording.tool(tool, phase: item.phase, harness: harness, workspaceURL: workspaceURL).text
            let diffs = tool.diff.map { [$0] } ?? tool.diffs
            if diffs.isEmpty { return text(words, muted: true) }
            return FileChangeView.element(words: words, diffs: diffs, phase: item.phase, workspaceURL: workspaceURL)
        case let .fileChange(change):
            return FileChangeView.element(item, change: change, harness: harness, workspaceURL: workspaceURL)
        default:
            return nil
        }
    }

    private static func text(_ string: String, muted: Bool = false, size: Double = 14) -> TextBlock {
        let block = TextBlock()
        block.text = string
        block.fontSize = size
        block.textWrapping = .wrap
        block.isTextSelectionEnabled = true
        if muted { block.opacity = 0.6 }
        return block
    }
}

private extension ConversationEarlierTurns {
    /// Loaded turns the window leaves out, which widening it shows.
    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
}
