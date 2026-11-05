import Foundation
import WinUI

/// A task's conversation as the engine lays it out for every harness (`ConversationPresentation`), drawn turn by
/// turn: what was sent, a line for each step of the work, the answers, the requests waiting and how the turn
/// ended. A turn that did not change keeps what it drew, so an answer streaming in redraws its own turn and
/// nothing else, and the view stays at the end while it was there. A host's conversation
/// (`RemoteConversationModel`) draws through it; so will a task's own.
@MainActor
final class ConversationTimeline {
    let view = ScrollViewer()
    private let stack = StackPanel()
    private var drawn: [String: (turn: ConversationTurn, element: StackPanel)] = [:]
    private var order: [String] = []
    private var placeholder: String?

    init() {
        stack.spacing = 20
        view.padding = Thickness(left: 28, top: 20, right: 28, bottom: 12)
        view.content = stack
    }

    /// The conversation, or `placeholder` in its place while there is none. `requestNote` says where a request
    /// waiting in it is answered, for a conversation that cannot answer it here.
    func show(_ presentation: ConversationPresentation?, placeholder: String? = nil, requestNote: String? = nil) {
        guard let presentation, !presentation.turns.isEmpty else {
            guard self.placeholder != placeholder || !order.isEmpty else { return }
            stack.children.clear()
            drawn = [:]
            order = []
            self.placeholder = placeholder
            if let placeholder { stack.children.append(Self.text(placeholder, muted: true)) }
            return
        }
        if self.placeholder != nil || order.isEmpty {
            stack.children.clear()
            self.placeholder = nil
        }
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
                if let element = next[id]?.element { stack.children.setAt(UInt32(index), element) }
            }
            for id in ids.dropFirst(order.count) {
                if let element = next[id]?.element { stack.children.append(element) }
            }
        } else {
            stack.children.clear()
            for id in ids {
                if let element = next[id]?.element { stack.children.append(element) }
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
            if let element = Self.element(for: item, harness: harness) { panel.children.append(element) }
        }
        for request in turn.requests where request.state == .pending {
            panel.children.append(Self.text(request.title))
            if let detail = request.detail ?? request.command { panel.children.append(Self.text(detail, muted: true)) }
            if let requestNote { panel.children.append(Self.text(requestNote, muted: true)) }
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

    private static func element(for item: ConversationItem, harness: HarnessKind) -> UIElement? {
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
            return text(body)
        case let .reasoning(summary, _, _):
            return text(summary ?? L10n.string("Thinking"), muted: true)
        case let .command(command):
            let words = ConversationLineWording.command(command, phase: item.phase, harness: harness).map(\.text)
            return words.isEmpty ? nil : text(words.joined(separator: ", "), muted: true)
        case let .tool(tool):
            return text(ConversationLineWording.tool(tool, phase: item.phase, harness: harness, workspaceURL: nil).text, muted: true)
        case .fileChange:
            return ConversationLiveWork.words(for: item, harness: harness, workspaceURL: nil).map { text($0.text, muted: true) }
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
