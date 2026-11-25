import Foundation

/// When a provider that keeps its own queue of user messages reads one sent while its turn runs.
/// The raw values are Claude Code's stream-json `priority`.
enum HarnessFollowUpPriority: String, Codable, Equatable, Sendable {
    /// Read at the running turn's next step, after the tool calls in flight finish, or as the next
    /// turn when the current one ends first.
    case next
    /// Stops the running turn and is read at once.
    case now
}

/// What became of a follow-up the provider held under its message ID.
struct HarnessFollowUpDelivery: Codable, Equatable, Sendable {
    enum State: String, Codable, Equatable, Sendable {
        /// The provider took it into the conversation, here in the event stream.
        case read
        /// The provider let it go without reading it: its session ended or it refused it.
        case dropped
        /// The provider gave it back unread because its turn ended first (Antigravity's live steer).
        /// Yardlet holds it again, and it starts the next turn.
        case returned
    }

    let messageID: String
    let state: State
    /// The provider read it into the turn that was running, at the turn's next step, rather than
    /// starting a turn with it (D13). Nil where the provider does not say.
    var joinsRunningTurn: Bool? = nil
}

/// What the provider did when asked to read a follow-up it holds at once. The raw values are
/// Claude Code's `send_now` answer to an `interrupt` that carries `send_now: true`.
enum HarnessFollowUpSendNow: String, Codable, Equatable, Sendable {
    /// Nothing stopped: the provider moves what the running turn waits on (a running command) to
    /// the background so the turn reads the message now, or the message is already on its way in.
    case delivering
    /// The running turn was stopped for the message, which starts the next turn.
    case stopped
    /// The provider held no such message: it had already taken it into a turn.
    case nothingWaiting = "nothing_waiting"
}

/// The provider cannot take a message into its running turn now (Antigravity's live steer outside a
/// streamed prompt, or a message with images): Yardlet keeps it for the turn's end instead of failing it.
struct HarnessFollowUpNotNow: Error {}

/// A provider that queues user messages sent while its turn runs and can withdraw one it has not
/// read yet (Claude Code's `uuid`/`priority` user messages and `cancel_async_message`).
protocol HarnessFollowUpQueueing: Actor {
    /// Writes a message under `messageID` without starting a turn of Yardlet's own. The provider
    /// reports when it reads it with a `followUpDelivery` event.
    func sendFollowUp(
        _ input: HarnessUserInput,
        messageID: String,
        priority: HarnessFollowUpPriority,
        to session: HarnessSessionHandle
    ) async throws

    /// Withdraws a follow-up the provider has not read. False when it already took it.
    func cancelFollowUp(messageID: String, in session: HarnessSessionHandle) async throws -> Bool

    /// Whether the running provider can be asked to read a follow-up it holds at once and decide
    /// itself how its running turn makes way (Claude Code's `interrupt_send_now_v1`).
    func canSendFollowUpNow(in session: HarnessSessionHandle) async -> Bool

    /// Asks the provider to read a follow-up it holds now. Nil when it answered without saying
    /// what it did. The read itself is still reported with a `followUpDelivery` event.
    func sendFollowUpNow(messageID: String, in session: HarnessSessionHandle) async throws -> HarnessFollowUpSendNow?
}

extension CodexComposerDraft {
    /// The composer draft a submission came from, so a queued message can go back into the
    /// composer as it was typed.
    init(_ input: HarnessUserInput) {
        let text: [CodexUserInput] = input.text.isEmpty ? [] : [.text(input.text)]
        let images = input.images.map { image -> CodexUserInput in
            image.url.scheme == "data" ? .image(image.url) : .localImage(image.url)
        }
        self.init(inputs: text + images + input.mentions.compactMap(CodexUserInput.localMention(for:)))
    }
}
