import Foundation
import Observation

// The follow-up queue that Codex and Claude Code tasks share (plan B1): messages sent while a turn
// runs, held by Yardlet until they go or, for Claude Code, by the provider until it reads them.
// The queue's state and its saved copies live in `FollowUpQueueStore`; what differs between the
// providers is their `FollowUpPolicy` and how their `FollowUpDelivery` reaches them.

// MARK: - The queued message

/// What an automatic send (Return) does while a turn runs; ⌘Return does the other. The Codex app
/// steers the running turn by default and offers queueing as its General setting; the composer's
/// Queue and Steer stay explicit. Steering never stops the turn: Codex's `turn/steer` adds the
/// message to the running turn, and Claude Code is written it to read at its next step (`next`),
/// or once its answer ends when it is writing that answer. A harness that takes no message while
/// its turn runs holds both in Yardlet until the turn ends (`FollowUpPolicy.afterTurn`).
enum FollowUpMode: String, CaseIterable, Identifiable, Sendable {
    case queue
    case steer

    /// Codex tasks, where the setting began, and Claude Code tasks read the same value.
    static let preferenceKey = "YardletFollowUpMode"

    static func current(in defaults: UserDefaults = .yardlet) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .steer
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .queue: L10n.string("Queue")
        case .steer: L10n.string("Steer")
        }
    }

    /// What ⌘Return does while a turn runs.
    var other: Self {
        switch self {
        case .queue: .steer
        case .steer: .queue
        }
    }

    /// This mode as the composer's explicit action.
    var action: CodexComposerAction {
        switch self {
        case .queue: .queue
        case .steer: .steer
        }
    }
}

typealias CodexFollowUpMode = FollowUpMode

enum QueuedFollowUpState: String, Codable, Equatable, Sendable {
    case pending
    case failed
    /// Written to a provider that keeps its own queue (Claude Code) and not read by it yet. Only
    /// the provider can still withdraw it.
    case sent
}

typealias CodexQueuedSubmissionState = QueuedFollowUpState

/// One message in a task's follow-up queue. The saved form is the one Codex's queue has always
/// had, so a queue saved by an earlier launch reads as it was (plan A8).
struct QueuedFollowUp: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var draft: CodexComposerDraft
    let enqueuedAt: Date
    var state: QueuedFollowUpState
    var failureMessage: String?
    /// The ID the provider holds a sent message under. Every write takes a new one, because the
    /// provider drops a second message with an ID it has already seen.
    var providerMessageID: String?
    /// Steered: it goes into the running turn, not after it. While Yardlet still holds such a message
    /// (one sent before it is not written yet, or the provider lost it unread with its runtime), it
    /// is written into the next running turn in its place, ahead of anything sent after it
    /// (`AppModel.steerInOrder`). Nil for a queued message, and left out of the saved shape then.
    var steered: Bool?

    init(
        id: UUID = UUID(),
        draft: CodexComposerDraft,
        enqueuedAt: Date = Date(),
        state: QueuedFollowUpState = .pending,
        failureMessage: String? = nil,
        providerMessageID: String? = nil,
        steered: Bool? = nil
    ) {
        self.id = id
        self.draft = draft
        self.enqueuedAt = enqueuedAt
        self.state = state
        self.failureMessage = failureMessage
        self.providerMessageID = providerMessageID
        self.steered = steered
    }

    /// Yardlet holds it, on its way into the running turn.
    var waitsToBeSteered: Bool { state == .pending && steered == true }

    /// Another task sent it (`TaskMessage`). It waits in the queue as the person's messages do, but it
    /// is not the person's to manage: the composer lists only the person's, and a pause holds the
    /// queue only while one of theirs waits.
    var isFromAnotherTask: Bool { TaskMessage.parse(draft.text) != nil }

    /// The message held by Yardlet again, unsent: the provider that held it let it go unread. It
    /// was written to be read in the running turn, and keeps that place (2026-10-23: after an update
    /// restart, a message another task sent before the quit reached its parent after one sent after).
    var heldAgain: QueuedFollowUp {
        guard state == .sent else { return self }
        var held = self
        held.state = .pending
        held.providerMessageID = nil
        held.steered = true
        return held
    }
}

typealias CodexQueuedSubmission = QueuedFollowUp

// MARK: - Saved copies

/// Where a task's queue, its pause and its unsent bash output are saved. The keys predate the
/// shared queue and keep their Codex names (plan A8).
protocol CodexQueueRepository {
    func load(for sessionID: UUID) -> [QueuedFollowUp]
    func save(_ queue: [QueuedFollowUp], for sessionID: UUID)
    /// Removes the queue and its pause.
    func remove(for sessionID: UUID)
    /// A queue the user paused by interrupting stays paused across launches until resumed.
    func isPaused(for sessionID: UUID) -> Bool
    func setPaused(_ paused: Bool, for sessionID: UUID)
    /// A Claude task's finished bash-mode commands not yet sent, oldest first. Kept apart from the
    /// queue: they wait behind it and are not shown in it.
    func loadShellDeliveries(for sessionID: UUID) -> [ClaudeShellDelivery]
    /// Saving none removes them.
    func saveShellDeliveries(_ deliveries: [ClaudeShellDelivery], for sessionID: UUID)
}

/// `NativeHarnessClient.codexQueue.<task>`, `….paused.<task>` and `….shell.<task>`.
struct UserDefaultsCodexQueueRepository: CodexQueueRepository {
    let defaults: UserDefaults
    let keyPrefix: String

    init(defaults: UserDefaults = .yardlet, keyPrefix: String = "NativeHarnessClient.codexQueue.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func load(for sessionID: UUID) -> [QueuedFollowUp] {
        guard let data = defaults.data(forKey: keyPrefix + sessionID.uuidString) else { return [] }
        return (try? JSONDecoder().decode([QueuedFollowUp].self, from: data)) ?? []
    }

    func save(_ queue: [QueuedFollowUp], for sessionID: UUID) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        defaults.set(data, forKey: keyPrefix + sessionID.uuidString)
    }

    func remove(for sessionID: UUID) {
        defaults.removeObject(forKey: keyPrefix + sessionID.uuidString)
        setPaused(false, for: sessionID)
    }

    func isPaused(for sessionID: UUID) -> Bool {
        defaults.bool(forKey: pausedKey(for: sessionID))
    }

    func setPaused(_ paused: Bool, for sessionID: UUID) {
        if paused {
            defaults.set(true, forKey: pausedKey(for: sessionID))
        } else {
            defaults.removeObject(forKey: pausedKey(for: sessionID))
        }
    }

    func loadShellDeliveries(for sessionID: UUID) -> [ClaudeShellDelivery] {
        guard let data = defaults.data(forKey: shellDeliveriesKey(for: sessionID)) else { return [] }
        return (try? JSONDecoder().decode([ClaudeShellDelivery].self, from: data)) ?? []
    }

    func saveShellDeliveries(_ deliveries: [ClaudeShellDelivery], for sessionID: UUID) {
        guard !deliveries.isEmpty, let data = try? JSONEncoder().encode(deliveries) else {
            defaults.removeObject(forKey: shellDeliveriesKey(for: sessionID))
            return
        }
        defaults.set(data, forKey: shellDeliveriesKey(for: sessionID))
    }

    private func pausedKey(for sessionID: UUID) -> String {
        keyPrefix + "paused." + sessionID.uuidString
    }

    private func shellDeliveriesKey(for sessionID: UUID) -> String {
        keyPrefix + "shell." + sessionID.uuidString
    }
}

// MARK: - What differs between providers

/// What one provider's follow-up queue does its own way. The chips' place, shape and actions are
/// the same for every provider; whether a sent message stays the provider's until it reads it, and
/// the words for sending one, are the provider's.
enum FollowUpPolicy: Equatable, Sendable {
    /// Messages wait in Yardlet; Steer adds one to the running turn (`turn/steer`).
    case codex
    /// A steered message is written to Claude Code to read at its next step (`next`); Claude Code
    /// holds it until it reads it. Only "Stop and send" asks it to stop the turn for one.
    case claudeCode
    /// The harness takes one message per turn and nothing while it runs (Antigravity's `agy`, the
    /// ACP and other headless harnesses): every message sent meanwhile waits in Yardlet and starts
    /// the next turn when this one ends.
    case afterTurn

    /// Every harness keeps a follow-up queue: Codex and Claude Code their own ways, the others
    /// until the turn ends.
    init?(harness: HarnessKind) {
        switch harness {
        case .codex: self = .codex
        case .claudeCode: self = .claudeCode
        default: self = .afterTurn
        }
    }

    /// The provider takes a message into its running turn.
    var steers: Bool { self != .afterTurn }

    /// The provider keeps what Yardlet writes it in a queue of its own until it reads it
    /// (`QueuedFollowUpState.sent`). Yardlet takes such a message back before changing it, and holds
    /// it again when the runtime that had it ends.
    var holdsSentMessages: Bool { self == .claudeCode }

    /// Whether a message the provider holds can change places. Claude Code reads what it holds in
    /// order, so those stay ahead of the messages Yardlet holds.
    var canReorderSent: Bool { !holdsSentMessages }

    // The words for where a message goes, shared by the composer's placeholder, its menu and the
    // queue's chips (2026-10-16: the person could not tell whether a message went now or after
    // the turn). Return never stops a turn; only Stop and "Stop and send" do.

    /// Where a steered message goes: Codex adds it to the running turn (`turn/steer`, the Codex
    /// app's Steer); Claude Code reads it at its next step. Nil for a harness that cannot take one.
    var steerPhrase: String? {
        switch self {
        case .codex: L10n.string("Add to the running task")
        case .claudeCode: L10n.string("Deliver at the next step")
        case .afterTurn: nil
        }
    }

    /// Where a queued message goes: it waits in Yardlet for the turn to end.
    static var afterTurnPhrase: String { L10n.string("Send when this turn ends") }

    /// The words for a way of sending while a turn runs; queueing for a harness that cannot steer.
    func phrase(for mode: FollowUpMode) -> String {
        switch mode {
        case .steer: steerPhrase ?? Self.afterTurnPhrase
        case .queue: Self.afterTurnPhrase
        }
    }

    /// The send action on a message Yardlet holds, which never stops the turn: "Send now" (2026-10-16
    /// user decision), what the Codex app's Steer on a queued message does ("Submit without
    /// interrupting the model"). A harness that cannot steer sends it when the turn ends, on its own.
    var sendLabel: String? {
        steers ? L10n.string("Send now") : nil
    }

    /// Where "Send now" puts the message: Codex adds it to the running task, Claude Code reads it at
    /// its next step; neither stops the turn.
    var sendHelp: String? {
        switch self {
        case .codex: L10n.string("Send now: add it to the running task without stopping it")
        case .claudeCode: L10n.string("Send now: Claude reads it at its next step without stopping")
        case .afterTurn: nil
        }
    }

    /// The action that stops the running turn for a message: Claude Code's Send now, named for what
    /// it does. Nil where the provider has none.
    var stopAndSendLabel: String? {
        self == .claudeCode ? L10n.string("Stop and send") : nil
    }

    /// What a message the provider holds says about itself: it is delivered now, and Claude Code
    /// reads it at its next step.
    var heldStatus: String { L10n.string("Delivered · Claude reads it at its next step") }

    /// The hint on a message Yardlet holds: it goes when the turn ends.
    var pendingHelp: String { Self.afterTurnPhrase }

    var removeLabel: String {
        switch self {
        case .codex: L10n.string("Delete queued message")
        case .claudeCode, .afterTurn: L10n.string("Remove from queue")
        }
    }

    /// What the composer says in place of its placeholder while a turn runs, as the Claude app's
    /// does ("⏎ to send, ⌘⏎ to queue for later"): where Return sends a message (the follow-up
    /// setting, `preferred`) and where ⌘Return sends it (the other). A harness that cannot steer
    /// names Return alone.
    func runningPlaceholder(preferred: FollowUpMode) -> String {
        guard steers else { return L10n.format("↩ %@", Self.afterTurnPhrase) }
        return L10n.format("↩ %@ · ⌘↩ %@", phrase(for: preferred), phrase(for: preferred.other))
    }

    /// `runningPlaceholder` with the keys in words, for VoiceOver.
    func returnHint(preferred: FollowUpMode) -> String {
        guard steers else { return L10n.format("Return: %@.", Self.afterTurnPhrase) }
        return L10n.format("Return: %@. Command-Return: %@.", phrase(for: preferred), phrase(for: preferred.other))
    }

    /// Why a message the provider let go unread failed.
    var droppedMessage: String { L10n.string("Claude Code did not take this message.") }

    /// Whether a queued message is already in the conversation. Codex's conversation records
    /// every submitted draft, queued or not; the others show a message once the provider has it.
    var recordsMessagesWhenQueued: Bool { self == .codex }

    /// How an attached runtime of this provider takes follow-ups. Nil when the runtime cannot take
    /// them the provider's way.
    @MainActor
    func delivery(adapter: any HarnessAdapter, handle: HarnessSessionHandle) -> (any FollowUpDelivery)? {
        switch self {
        case .codex: CodexFollowUpDelivery(adapter: adapter, handle: handle)
        case .claudeCode: ClaudeFollowUpDelivery(adapter: adapter, handle: handle)
        case .afterTurn: TurnByTurnFollowUpDelivery(adapter: adapter, handle: handle)
        }
    }
}

// MARK: - How a message reaches the provider

/// The running turn a follow-up can join, as the provider names it.
struct FollowUpTurn: Equatable, Sendable {
    /// Codex's active turn, which `turn/steer` names. A Claude Code turn has no ID to name.
    var providerTurnID: String?
}

/// A provider's side of the follow-up queue: how a message Yardlet holds starts the next turn or
/// joins the running one, and how one the provider holds is taken back or read at once. The app
/// model keeps the task's own steps (attaching, the running state, the conversation, errors) and
/// the queue's state; a delivery only speaks to the provider.
@MainActor
protocol FollowUpDelivery {
    var policy: FollowUpPolicy { get }

    /// The turn a message can join now. Codex asks its App Server for the active turn; Claude
    /// Code's stream has no such question, so the status Yardlet keeps (`reportedRunning`) answers.
    func runningTurn(reportedRunning: Bool) async -> FollowUpTurn?

    /// Starts the next turn with a message, in the shape this provider takes a first message.
    /// `contextualize` puts a new task's inherited context in front of what is sent.
    func start(
        _ draft: CodexComposerDraft,
        contextualize: (CodexComposerDraft) throws -> CodexComposerDraft
    ) async throws

    /// Sends a message into the running turn. Codex steers its active turn and has the message at
    /// once. Claude Code is written it under the message's `providerMessageID`, to read at its
    /// next step (`next`) or at once (`now`), and holds it until it reports reading it.
    func steer(_ item: QueuedFollowUp, into turn: FollowUpTurn, priority: HarnessFollowUpPriority) async throws

    /// Takes back a message the provider holds. True when it holds none of it any more.
    func withdraw(_ item: QueuedFollowUp) async throws -> Bool

    /// Whether the provider can be asked to read a message it holds at once and decide itself how
    /// its running turn makes way.
    func canSendHeldNow() async -> Bool

    /// Asks the provider to read a message it holds now. The read itself arrives as the provider's
    /// report that it took the message.
    func sendHeldNow(_ item: QueuedFollowUp) async throws
}

/// Codex keeps nothing it is sent: a held message starts the next turn (`turn/start`) or steers the
/// active one (`turn/steer`).
struct CodexFollowUpDelivery: FollowUpDelivery {
    let adapter: any HarnessAdapter
    let handle: HarnessSessionHandle

    var policy: FollowUpPolicy { .codex }

    private var composer: (any CodexComposerProviding)? { adapter as? any CodexComposerProviding }

    func runningTurn(reportedRunning: Bool) async -> FollowUpTurn? {
        guard let composer, let turnID = await composer.activeTurnID(for: handle) else { return nil }
        return FollowUpTurn(providerTurnID: turnID)
    }

    func start(
        _ draft: CodexComposerDraft,
        contextualize: (CodexComposerDraft) throws -> CodexComposerDraft
    ) async throws {
        // Codex's typed envelopes (skills, mentions, images) travel as they are.
        if let composer {
            try await composer.submit(contextualize(draft), submission: .start, to: handle)
        } else {
            try await adapter.send(contextualize(draft).text, to: handle)
        }
    }

    func steer(_ item: QueuedFollowUp, into turn: FollowUpTurn, priority: HarnessFollowUpPriority) async throws {
        guard let composer else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Codex steer is unavailable for this runtime"))
        }
        guard let turnID = turn.providerTurnID else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Codex steer requires an active turn"))
        }
        try await composer.submit(item.draft, submission: .steer(expectedTurnID: turnID), to: handle)
    }

    func withdraw(_ item: QueuedFollowUp) async throws -> Bool { true }

    func canSendHeldNow() async -> Bool { false }

    func sendHeldNow(_ item: QueuedFollowUp) async throws {}
}

/// Claude Code keeps its own queue of user messages (`uuid` and `priority` on a stream-json user
/// message). It reports reading one with `command_lifecycle`, which reaches the queue as a
/// `followUpDelivery` event; it gives back one it has not read on `cancel_async_message`; and where
/// it advertises `interrupt_send_now_v1` it reads one it holds at once on `interrupt{send_now}`,
/// moving a running command to the background. An older CLI is written the message again with
/// priority `now` instead, after it has been withdrawn.
struct ClaudeFollowUpDelivery: FollowUpDelivery {
    let adapter: any HarnessAdapter
    let provider: any HarnessFollowUpQueueing
    let handle: HarnessSessionHandle

    /// Nil for a runtime that does not keep follow-ups; messages to it wait for its turn to end.
    init?(adapter: any HarnessAdapter, handle: HarnessSessionHandle) {
        guard let provider = adapter as? any HarnessFollowUpQueueing else { return nil }
        self.adapter = adapter
        self.provider = provider
        self.handle = handle
    }

    var policy: FollowUpPolicy { .claudeCode }

    func runningTurn(reportedRunning: Bool) async -> FollowUpTurn? {
        reportedRunning ? FollowUpTurn() : nil
    }

    func start(
        _ draft: CodexComposerDraft,
        contextualize: (CodexComposerDraft) throws -> CodexComposerDraft
    ) async throws {
        // Mentions go as prompt lines, as every message to Claude Code does; images stay attached.
        let input = HarnessUserInput.projecting(draft).input
        var outgoing = input
        outgoing.text = try contextualize(CodexComposerDraft(inputs: [.text(input.promptText)])).text
        outgoing.mentions = []
        try await adapter.send(outgoing, to: handle)
    }

    func steer(_ item: QueuedFollowUp, into turn: FollowUpTurn, priority: HarnessFollowUpPriority) async throws {
        guard let messageID = item.providerMessageID else {
            throw HarnessAdapterError.invalidProviderEvent(L10n.string("Claude Code did not take this message."))
        }
        try await provider.sendFollowUp(HarnessUserInput.projecting(item.draft).input, messageID: messageID,
                                        priority: priority, to: handle)
    }

    func withdraw(_ item: QueuedFollowUp) async throws -> Bool {
        guard let messageID = item.providerMessageID else { return true }
        return try await provider.cancelFollowUp(messageID: messageID, in: handle)
    }

    func canSendHeldNow() async -> Bool {
        await provider.canSendFollowUpNow(in: handle)
    }

    func sendHeldNow(_ item: QueuedFollowUp) async throws {
        guard let messageID = item.providerMessageID else { return }
        _ = try await provider.sendFollowUpNow(messageID: messageID, in: handle)
    }
}

/// A harness that takes one message per turn (`FollowUpPolicy.afterTurn`): a message sent while
/// its turn runs waits in Yardlet, and starts the next turn as a typed message does once this one
/// ends. Nothing is written to the provider meanwhile, so nothing can stop or cut short its turn.
struct TurnByTurnFollowUpDelivery: FollowUpDelivery {
    let adapter: any HarnessAdapter
    let handle: HarnessSessionHandle

    var policy: FollowUpPolicy { .afterTurn }

    func runningTurn(reportedRunning: Bool) async -> FollowUpTurn? {
        reportedRunning ? FollowUpTurn() : nil
    }

    func start(
        _ draft: CodexComposerDraft,
        contextualize: (CodexComposerDraft) throws -> CodexComposerDraft
    ) async throws {
        // As `AppModel.send` sends a typed message: mentions as prompt lines, images attached.
        let input = HarnessUserInput.projecting(draft).input
        var outgoing = input
        outgoing.text = try contextualize(CodexComposerDraft(inputs: [.text(input.promptText)])).text
        outgoing.mentions = []
        try await adapter.send(outgoing, to: handle)
    }

    func steer(_ item: QueuedFollowUp, into turn: FollowUpTurn, priority: HarnessFollowUpPriority) async throws {
        throw HarnessAdapterError.capabilityUnavailable(L10n.string("Send when this turn ends"))
    }

    func withdraw(_ item: QueuedFollowUp) async throws -> Bool { true }

    func canSendHeldNow() async -> Bool { false }

    func sendHeldNow(_ item: QueuedFollowUp) async throws {}
}

// MARK: - The store

/// Every task's follow-up queue: one list per task in the order it goes, the tasks the user paused
/// by interrupting, the messages an action is working on, and their saved copies. Each change is
/// saved as it is made; a queue left with none of the person's messages takes its pause with it.
///
/// The app model owns the one store and acts on it for the composer's queue actions; views read it.
@MainActor
@Observable
final class FollowUpQueueStore {
    private var queues: [UUID: [QueuedFollowUp]] = [:]
    /// Queues the user paused by interrupting. They wait for Resume instead of the next ready
    /// state, also across launches.
    private var pausedSessionIDs = Set<UUID>()
    /// Messages being sent, withdrawn or edited, so no two actions act on one at once.
    @ObservationIgnored private var claimed = Set<UUID>()
    @ObservationIgnored private let repository: any CodexQueueRepository
    /// Called when a task's queue empties: what waits behind it (a finished bash command) may go.
    @ObservationIgnored var queueDidEmpty: (@MainActor (UUID) -> Void)?
    /// Called when a pause ends because the person's last message left the queue: what other tasks
    /// sent goes on as after Resume.
    @ObservationIgnored var pauseDidEnd: (@MainActor (UUID) -> Void)?

    init(repository: any CodexQueueRepository = UserDefaultsCodexQueueRepository()) {
        self.repository = repository
    }

    // MARK: Reading

    func queue(for sessionID: UUID) -> [QueuedFollowUp] {
        queues[sessionID] ?? []
    }

    func item(_ itemID: UUID, in sessionID: UUID) -> QueuedFollowUp? {
        queues[sessionID]?.first { $0.id == itemID }
    }

    /// The message the provider holds under this ID.
    func sentItem(messageID: String, in sessionID: UUID) -> QueuedFollowUp? {
        queues[sessionID]?.first { $0.state == .sent && $0.providerMessageID == messageID }
    }

    func isPaused(_ sessionID: UUID) -> Bool {
        pausedSessionIDs.contains(sessionID)
    }

    // MARK: Messages an action is working on

    /// Claims a message for one send, withdrawal or edit. False while another action has it.
    func claim(_ itemID: UUID) -> Bool {
        claimed.insert(itemID).inserted
    }

    func finish(_ itemID: UUID) {
        claimed.remove(itemID)
    }

    func isClaimed(_ itemID: UUID) -> Bool {
        claimed.contains(itemID)
    }

    // MARK: Loading

    /// Reads these tasks' saved queues and pauses, replacing what the store held. A message a
    /// provider held went unread with the runtime that ended with the last launch, so Yardlet holds
    /// it again (plan A8), still on its way into the running turn (`heldAgain`). A pause saved over
    /// a queue with none of the person's messages left, which earlier builds kept, is let go.
    func load(for sessionIDs: some Sequence<UUID>) {
        queues = Dictionary(uniqueKeysWithValues: sessionIDs.compactMap { sessionID in
            let queue = repository.load(for: sessionID).map(\.heldAgain)
            return queue.isEmpty ? nil : (sessionID, queue)
        })
        pausedSessionIDs = Set(queues.keys.filter { repository.isPaused(for: $0) })
        for sessionID in pausedSessionIDs where !holdsPersonsMessage(sessionID) {
            pausedSessionIDs.remove(sessionID)
            repository.setPaused(false, for: sessionID)
        }
    }

    /// Queues a fixture or test starts with, as they are; nothing is saved.
    func seed(_ queues: [UUID: [QueuedFollowUp]]) {
        self.queues = queues.filter { !$0.value.isEmpty }
    }

    // MARK: Changes

    func append(_ item: QueuedFollowUp, to sessionID: UUID) {
        queues[sessionID, default: []].append(item)
        save(sessionID)
    }

    @discardableResult
    func remove(_ itemID: UUID, from sessionID: UUID) -> QueuedFollowUp? {
        guard let index = queues[sessionID]?.firstIndex(where: { $0.id == itemID }) else { return nil }
        let item = queues[sessionID]?.remove(at: index)
        save(sessionID)
        return item
    }

    /// Moves a message to `index`, unless an action is working on it. Under a policy whose sent
    /// messages cannot move, those stay where they are and the others stay behind them.
    @discardableResult
    func move(_ itemID: UUID, in sessionID: UUID, to index: Int, policy: FollowUpPolicy) -> Bool {
        guard var queue = queues[sessionID], let source = queue.firstIndex(where: { $0.id == itemID }),
              policy.canReorderSent || queue[source].state != .sent, !claimed.contains(itemID) else { return false }
        let item = queue.remove(at: source)
        let firstMovable = policy.canReorderSent ? 0 : (queue.lastIndex { $0.state == .sent } ?? -1) + 1
        queue.insert(item, at: min(max(index, firstMovable), queue.count))
        queues[sessionID] = queue
        save(sessionID)
        return true
    }

    /// Replaces only a held message's text; its host-owned attachment inputs and queue position stay intact.
    @discardableResult
    func editText(_ itemID: UUID, in sessionID: UUID, text: String) -> Bool {
        guard let index = queues[sessionID]?.firstIndex(where: { $0.id == itemID }),
              let item = queues[sessionID]?[index], item.state != .sent,
              !claimed.contains(itemID), !item.isFromAnotherTask else { return false }
        let attachments = item.draft.inputs.filter { if case .text = $0 { return false }; return true }
        queues[sessionID]?[index].draft = CodexComposerDraft(inputs: [.text(text)] + attachments)
        save(sessionID)
        return true
    }

    /// A failed message waits to be sent again.
    @discardableResult
    func retry(_ itemID: UUID, in sessionID: UUID) -> Bool {
        guard let index = queues[sessionID]?.firstIndex(where: { $0.id == itemID }),
              queues[sessionID]?[index].state == .failed else { return false }
        queues[sessionID]?[index].state = .pending
        queues[sessionID]?[index].failureMessage = nil
        save(sessionID)
        return true
    }

    /// The message could not be sent, or the provider let it go: it stays, failed, with the reason.
    /// Sent again, it goes when no turn runs.
    @discardableResult
    func markFailed(_ itemID: UUID, message: String, in sessionID: UUID) -> Bool {
        guard let index = queues[sessionID]?.firstIndex(where: { $0.id == itemID }) else { return false }
        queues[sessionID]?[index].state = .failed
        queues[sessionID]?[index].failureMessage = message
        queues[sessionID]?[index].providerMessageID = nil
        queues[sessionID]?[index].steered = nil
        save(sessionID)
        return true
    }

    /// Written to a provider that holds it under `messageID`, placed where the provider reads it:
    /// after the others it holds, or first when it stops the turn for it.
    func markSent(_ itemID: UUID, messageID: String, first: Bool, in sessionID: UUID) {
        guard var queue = queues[sessionID], let index = queue.firstIndex(where: { $0.id == itemID }) else { return }
        var item = queue.remove(at: index)
        item.state = .sent
        item.failureMessage = nil
        item.providerMessageID = messageID
        queue.insert(item, at: first ? 0 : (queue.lastIndex { $0.state == .sent } ?? -1) + 1)
        queues[sessionID] = queue
        save(sessionID)
    }

    /// Yardlet holds a message again, unsent, because the person took it back (an interrupt or an
    /// edit): it waits with the queue for the turn's end, no longer steered.
    func hold(_ itemID: UUID, in sessionID: UUID) {
        guard let index = queues[sessionID]?.firstIndex(where: { $0.id == itemID }) else { return }
        queues[sessionID]?[index].state = .pending
        queues[sessionID]?[index].providerMessageID = nil
        queues[sessionID]?[index].steered = nil
        save(sessionID)
    }

    /// The runtime that held this task's sent messages is gone, and they went with it unread.
    /// Yardlet holds them again, ahead of the rest, for the next running turn (`heldAgain`).
    func holdAllSent(in sessionID: UUID) {
        guard let queue = queues[sessionID], queue.contains(where: { $0.state == .sent }) else { return }
        queues[sessionID] = queue.map(\.heldAgain)
        save(sessionID)
    }

    // MARK: Pause

    /// Holds a task's queue until Resume. Only a queue with a message of the person's pauses, since
    /// only theirs show with the pause; true when this paused it.
    @discardableResult
    func pause(_ sessionID: UUID) -> Bool {
        guard holdsPersonsMessage(sessionID), !pausedSessionIDs.contains(sessionID) else { return false }
        pausedSessionIDs.insert(sessionID)
        repository.setPaused(true, for: sessionID)
        return true
    }

    /// True when the queue was paused.
    @discardableResult
    func resume(_ sessionID: UUID) -> Bool {
        guard pausedSessionIDs.contains(sessionID) else { return false }
        pausedSessionIDs.remove(sessionID)
        repository.setPaused(false, for: sessionID)
        return true
    }

    // MARK: A task that goes away

    /// Forgets a task's queue, its pause and the bash output saved with them.
    func discard(_ sessionID: UUID) {
        if queues[sessionID] != nil { queues.removeValue(forKey: sessionID) }
        if pausedSessionIDs.contains(sessionID) { pausedSessionIDs.remove(sessionID) }
        repository.remove(for: sessionID)
        repository.saveShellDeliveries([], for: sessionID)
    }

    // MARK: Bash output saved with the queue

    func savedShellDeliveries(for sessionID: UUID) -> [ClaudeShellDelivery] {
        repository.loadShellDeliveries(for: sessionID)
    }

    func saveShellDeliveries(_ deliveries: [ClaudeShellDelivery], for sessionID: UUID) {
        repository.saveShellDeliveries(deliveries, for: sessionID)
    }

    private func save(_ sessionID: UUID) {
        let queue = queues[sessionID] ?? []
        guard queue.isEmpty else {
            repository.save(queue, for: sessionID)
            // The pause held the person's messages; with none of theirs left, what other tasks sent
            // goes on as after Resume instead of waiting behind a pause with nothing to show.
            if pausedSessionIDs.contains(sessionID), !holdsPersonsMessage(sessionID), resume(sessionID) {
                pauseDidEnd?(sessionID)
            }
            return
        }
        // Nothing is left to hold back; the next queued message starts a fresh queue.
        if queues[sessionID] != nil { queues.removeValue(forKey: sessionID) }
        if pausedSessionIDs.contains(sessionID) { pausedSessionIDs.remove(sessionID) }
        repository.remove(for: sessionID)
        queueDidEmpty?(sessionID)
    }

    private func holdsPersonsMessage(_ sessionID: UUID) -> Bool {
        queues[sessionID]?.contains { !$0.isFromAnotherTask } == true
    }
}
