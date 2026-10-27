import AppKit
import SwiftUI

/// A turn drawn in a hosting view of its own (`ConversationTurnHosting`). The window's view graph
/// then holds one platform view for the turn instead of every view inside it: a streamed fragment
/// updates the running turn's own graph and display list, and laying out and drawing the window
/// costs the same whether the conversation is short or long. A turn's hosting is kept with its task
/// (`ConversationRenderState`), so a task opened again shows its turns without building them anew.
struct ConversationTurnHost: NSViewRepresentable, Equatable {
    let turn: ConversationTurn
    let context: ConversationItemContext
    let handlers: ConversationTurnHandlers
    /// Where the task keeps its turns' hostings; nil draws the turn in one of its own.
    let renderState: ConversationRenderState?
    fileprivate let offers: ConversationTurnOffers

    init(turn: ConversationTurn, context: ConversationItemContext, handlers: ConversationTurnHandlers,
         renderState: ConversationRenderState?) {
        self.turn = turn
        self.context = context
        self.handlers = handlers
        self.renderState = renderState
        offers = ConversationTurnOffers(context: context, handlers: handlers)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.turn == rhs.turn && lhs.offers == rhs.offers && lhs.renderState === rhs.renderState
    }

    final class Coordinator {
        var hosting: ConversationTurnHosting?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The turn's own hosting view, kept with the task or made for it, in a view that takes the presses
    /// the turn's content hands on (`ConversationPressSurface`). A kept one is not in a window (another
    /// conversation view showing the same turn makes its own).
    func makeNSView(context: Context) -> NSView {
        let hosting = renderState?.hosting(for: turn.id) ?? ConversationTurnHosting(turnID: turn.id)
        context.coordinator.hosting = hosting
        let view = ConversationPressSurface()
        let content = hosting.controller.view
        content.frame = view.bounds
        content.autoresizingMask = [.width, .height]
        view.addSubview(content)
        hosting.onResize = { [weak view] in view?.invalidateIntrinsicContentSize() }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.hosting?.show(self, environment: context.environment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        context.coordinator.hosting?.size(forWidth: proposal.width ?? nsView.bounds.width)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.hosting?.onResize = {}
    }
}

/// One turn's hosting controller, what it last drew, and its heights by width.
@MainActor
final class ConversationTurnHosting {
    let turnID: String
    let controller = NSHostingController(rootView: AnyView(EmptyView()))
    /// The text of the turn's streaming message since the turn was last drawn whole.
    private let streamedText = ConversationStreamedText()
    private var shown: ConversationTurnHost?
    private var shownLook: ConversationTurnLook?
    private var heights: [CGFloat: CGFloat] = [:]
    private var reportedHeight: CGFloat?
    /// The turn view grew or shrank on its own, or with a new turn.
    var onResize: () -> Void = {}

    init(turnID: String) {
        self.turnID = turnID
        controller.sizingOptions = []
#if DEBUG
        ViewBodyCensus.note(.conversationTurnHosting)
#endif
    }

    /// Draws `host` again only when its turn, what the task offers it, or how the conversation looks
    /// changed: the timeline's views are made afresh with each update, and the turns it did not
    /// change keep their graphs untouched. A fragment that changed only the text of the message the
    /// turn streams goes to that message alone (`ConversationTurn.streamedTextChange(from:)`): the
    /// rest of the turn, which drawing it whole compared, laid out and gave the conversation's
    /// environment again, is what it was.
    func show(_ host: ConversationTurnHost, environment: EnvironmentValues) {
        let look = ConversationTurnLook(environment)
        if let shown, shown == host, look == shownLook { return }
        if let shown, look == shownLook, shown.offers == host.offers, shown.renderState === host.renderState,
           let change = host.turn.streamedTextChange(from: shown.turn) {
            self.shown = host
            streamedText.set(change.message, for: change.itemID)
            heights = [:]
            return
        }
        shown = host
        shownLook = look
#if DEBUG
        ViewBodyCensus.note(.conversationTurn)
#endif
        heights = [:]
        streamedText.clear()
        controller.rootView = AnyView(
            ConversationTurnView(turn: host.turn, context: host.context, handlers: host.handlers)
                .equatable()
                .environment(\.conversationStreamedText, streamedText)
                .fixedSize(horizontal: false, vertical: true)
                // A turn grows and shrinks on its own too: a fold opens, a card waits, a line streams.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                    self?.contentHeightChanged(height)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .environment(\.self, environment)
        )
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height != reportedHeight else { return }
        reportedHeight = height
        heights = [:]
        onResize()
    }

    func size(forWidth width: CGFloat) -> CGSize {
        if let height = heights[width] { return CGSize(width: width, height: height) }
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = ceil(size.height)
        heights[width] = height
        return CGSize(width: width, height: height)
    }
}

/// The text of a message a turn streams, as fragments arrive between the times the turn is drawn
/// whole. The message reads it in place of the text the turn was drawn with; drawing the turn whole
/// again clears it.
@MainActor
@Observable
final class ConversationStreamedText {
    /// A message's words so far, and what "Copy item details" copies of it with them.
    struct Message: Equatable {
        var text: String
        var copyDetails: String?
    }

    private var messages: [String: Message] = [:]

    func message(for itemID: String) -> Message? { messages[itemID] }

    func set(_ message: Message, for itemID: String) {
        if messages[itemID] != message { messages[itemID] = message }
    }

    func clear() {
        if !messages.isEmpty { messages = [:] }
    }
}

private struct ConversationStreamedTextKey: EnvironmentKey {
    static let defaultValue: ConversationStreamedText? = nil
}

extension EnvironmentValues {
    /// The streamed text of the turn being drawn (`ConversationStreamedText`).
    var conversationStreamedText: ConversationStreamedText? {
        get { self[ConversationStreamedTextKey.self] }
        set { self[ConversationStreamedTextKey.self] = newValue }
    }
}

extension ConversationTurn {
    /// The message whose text is all that changed from `previous`, and its text now: the turn's last
    /// answer or last item of work, streaming before and after, from a transcript entry or a Codex
    /// agent message, with words before and after (so whether it answers, and so the fold, stays as it
    /// was). Put back to its earlier text, the message and the whole turn must equal `previous`;
    /// anything else that changed with it, in the message or elsewhere in the turn, draws the turn
    /// whole.
    func streamedTextChange(from previous: ConversationTurn)
        -> (itemID: String, message: ConversationStreamedText.Message)? {
        guard id == previous.id, work.count == previous.work.count, answers.count == previous.answers.count
        else { return nil }
        var restored = self
        let new: ConversationItem
        let old: ConversationItem
        if let last = answers.last, let earlier = previous.answers.last, last != earlier {
            (new, old) = (last, earlier)
            restored.answers[answers.count - 1] = earlier
        } else if let last = work.last, let earlier = previous.work.last, last != earlier {
            (new, old) = (last, earlier)
            restored.work[work.count - 1] = earlier
        } else {
            return nil
        }
        guard new.id == old.id, let text = Self.streamingText(of: new), let earlierText = Self.streamingText(of: old),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !earlierText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.item(new, withTextOf: old) == old, restored == previous
        else { return nil }
        return (new.id, ConversationStreamedText.Message(text: text, copyDetails: new.copyDetails))
    }

    /// The text of a message being written: a transcript entry's, or a Codex agent message's as the
    /// conversation shows it.
    private static func streamingText(of item: ConversationItem) -> String? {
        let text: String
        switch item.kind {
        case let .answer(words, true), let .commentary(words, true): text = words
        default: return nil
        }
        switch item.source {
        case let .transcript(entry):
            guard case let .assistant(entryText, true) = entry.content, entryText == text else { return nil }
        case let .codex(codexItem, _):
            guard case .agentMessage = codexItem.content else { return nil }
        }
        return text
    }

    /// `item` with the text `earlier`, the same message before, had: the text shown, its record's,
    /// and for Codex what its details copy, which are made from the record.
    private static func item(_ item: ConversationItem, withTextOf earlier: ConversationItem) -> ConversationItem {
        guard let text = streamingText(of: earlier) else { return item }
        var item = item
        switch item.kind {
        case .answer: item.kind = .answer(text: text, isStreaming: true)
        case .commentary: item.kind = .commentary(text: text, isStreaming: true)
        default: break
        }
        switch (item.source, earlier.source) {
        case (.transcript(var entry), .transcript):
            entry.content = .assistant(text: text, isStreaming: true)
            item.source = .transcript(entry)
        case (.codex(var codexItem, let turnID), .codex(let earlierItem, _)):
            guard case var .agentMessage(message) = codexItem.content,
                  case let .agentMessage(earlierMessage) = earlierItem.content else { break }
            message.text = earlierMessage.text
            codexItem.content = .agentMessage(message)
            item.source = .codex(codexItem, turnID: turnID)
            item.copyDetails = earlier.copyDetails
        default:
            break
        }
        return item
    }
}

/// The environment a turn's views read that changes how they draw. A turn whose content did not
/// change is drawn again only when one of these did; the rest of the environment (actions, closures)
/// is what the turn was last drawn with, as an unchanged `.equatable()` turn kept it before. The
/// system's values are here too, since the turn's hosting view takes the conversation's environment
/// whole: an assistive app starting, the window going inactive, another display.
struct ConversationTurnLook: @MainActor Equatable {
    // The system's.
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast
    let controlActiveState: ControlActiveState
    let displayScale: CGFloat
    let layoutDirection: LayoutDirection
    let locale: Locale
    let isEnabled: Bool
    let accessibilityEnabled: Bool
    let voiceOverEnabled: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let differentiateWithoutColor: Bool
    let invertColors: Bool
    let showButtonShapes: Bool
    // The conversation's.
    let scale: CGFloat
    let workspaceURL: URL?
    let revealsActions: Bool
    let opensDetailsForReview: Bool
    let find: ObjectIdentifier?
    /// A bash row's actions: whether a command runs, and the task they are bound to (they read the
    /// task's record afresh when used).
    let shellCommandRunning: Bool?
    let shellCommandTask: UUID?
    let modelNames: HarnessModelNames?

    @MainActor
    init(_ environment: EnvironmentValues) {
        colorScheme = environment.colorScheme
        contrast = environment.colorSchemeContrast
        controlActiveState = environment.controlActiveState
        displayScale = environment.displayScale
        layoutDirection = environment.layoutDirection
        locale = environment.locale
        isEnabled = environment.isEnabled
        accessibilityEnabled = environment.accessibilityEnabled
        voiceOverEnabled = environment.accessibilityVoiceOverEnabled
        reduceMotion = environment.accessibilityReduceMotion
        reduceTransparency = environment.accessibilityReduceTransparency
        differentiateWithoutColor = environment.accessibilityDifferentiateWithoutColor
        invertColors = environment.accessibilityInvertColors
        showButtonShapes = environment.accessibilityShowButtonShapes
        scale = environment.yardletInterfaceScale
        workspaceURL = environment.transcriptWorkspaceURL
        revealsActions = environment.revealsSentMessageActions
        opensDetailsForReview = environment.opensDetailsForReview
        find = environment.conversationFind.map(ObjectIdentifier.init)
        shellCommandRunning = environment.claudeShellCommands?.isRunning
        shellCommandTask = environment.claudeShellCommands?.task?.id
        modelNames = environment.harnessModelNames
    }
}

/// What a task's conversation keeps between the times it is shown: its projection (so an unchanged
/// conversation is not projected again) and its turns' hostings (so they are not built again). The
/// most recently shown conversations keep their hostings (`recentLimit`); the others let theirs go
/// and build them again when shown.
@MainActor
final class ConversationRenderState {
    static let recentLimit = 4
    private static var recent: [ObjectIdentifier: (state: ConversationRenderState, shown: UInt64)] = [:]
    private static var clock: UInt64 = 0

    let projection = ConversationProjectionCache()
    private var hostings: [String: ConversationTurnHosting] = [:]

    init() {}

    /// The turn's hosting, kept unless another conversation view shows it now.
    func hosting(for turnID: String) -> ConversationTurnHosting {
        Self.touch(self)
        if let hosting = hostings[turnID], hosting.controller.view.window == nil {
            return hosting
        }
        let hosting = ConversationTurnHosting(turnID: turnID)
        if hostings[turnID] == nil { hostings[turnID] = hosting }
        return hosting
    }

    /// Lets go of the hostings of turns the conversation no longer draws.
    func keep(turnIDs: some Sequence<String>) {
        let kept = Set(turnIDs)
        if hostings.keys.contains(where: { !kept.contains($0) }) {
            hostings = hostings.filter { kept.contains($0.key) }
        }
    }

    private func releaseHostings() {
        hostings = hostings.filter { $0.value.controller.view.window != nil }
    }

    private static func touch(_ state: ConversationRenderState) {
        clock += 1
        recent[ObjectIdentifier(state)] = (state, clock)
        guard recent.count > recentLimit else { return }
        let stale = recent.values.sorted { $0.shown < $1.shown }.prefix(recent.count - recentLimit)
        for entry in stale {
            entry.state.releaseHostings()
            recent[ObjectIdentifier(entry.state)] = nil
        }
    }
}
