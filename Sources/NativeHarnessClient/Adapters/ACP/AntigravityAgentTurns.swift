import Foundation

/// The turns Antigravity starts on its own, read from the conversation's log.
///
/// When a subagent or a background task the agent left running ends, the CLI writes a system message
/// into the conversation and the agent answers it, with no request from anyone. `agy acp` streams a
/// conversation only while a `session/prompt` runs, so no client hears of that turn until its next
/// prompt, and then the steps it held come first on that prompt's stream. The conversation's log has
/// them as they happen (`AntigravityConversationStore`), so between prompts the adapter reads what
/// is added to it, and an agent's turn runs, answers and ends in Yardlet as any turn does. The
/// repeat on the next prompt's stream is dropped (`AntigravityRedelivery`).
struct AntigravityAgentTurnFollower: Sendable {
    /// How long a running turn may add nothing to the log before the task goes back to ready. A step
    /// that waits for an approval reaches no client between prompts either, and a next prompt is what
    /// lets it be answered, so a queued message must not wait on it for ever: a turn whose last tool
    /// call has no result by then ends, saying so, where a step can wait for approval. A tool that is
    /// merely slow loses nothing: what it adds later runs the turn again.
    static let quietLimit: Duration = .seconds(300)

    /// What a turn that ended on a step with no result says.
    static var waitingStepNotice: String {
        L10n.string("A step may be waiting for approval. Antigravity asks only while it answers a message, so send a message to continue.")
    }

    private let store: AntigravityConversationStore
    private let conversationID: String
    private let quietLimit: Duration
    /// Whether a step can wait for an approval: not on a process that approves for itself
    /// (`ACPProcessLane`).
    var stepsWaitForApproval: Bool
    /// The last response's step, and its tool calls the log has no result of yet: the CLI writes
    /// each call's result as the step after the response, in call order, once the call has run.
    private var responseStep: Int64?
    private var callsWithoutResult: [String] = []
    /// The end of what has been read of the log.
    private var position: UInt64
    /// The agent woke since the last prompt: a system message is what wakes it, and any line before
    /// one belongs to the turn that just ended.
    private var isAwake = false
    /// The running turn's lines, which the log's parser reads as one, since a failed call's line
    /// refers to the response before it, and what of them has been shown.
    private var turnLines = Data()
    private var shown: [UUID: TranscriptEntryContent] = [:]
    private var isRunning = false
    private var lastLine: ContinuousClock.Instant
    /// What was shown from the log, which the next prompt's stream repeats.
    private(set) var redelivery: AntigravityRedelivery

    /// Follows from the log's current end: what is there already reached the client on its prompt's
    /// stream. `redelivery` is what an earlier prompt's stream had not repeated yet.
    init(
        store: AntigravityConversationStore,
        conversationID: String,
        redelivery: AntigravityRedelivery = AntigravityRedelivery(),
        quietLimit: Duration = Self.quietLimit,
        stepsWaitForApproval: Bool = true
    ) {
        self.store = store
        self.conversationID = conversationID
        self.quietLimit = quietLimit
        self.stepsWaitForApproval = stepsWaitForApproval
        self.redelivery = redelivery
        lastLine = .now
        position = store.transcriptURL(conversationID: conversationID).flatMap(Self.size(of:)) ?? 0
    }

    /// What the log added, as the events of the agent's turn.
    mutating func read(at now: ContinuousClock.Instant = .now) -> [HarnessEventPayload] {
        let lines = newLines()
        guard !lines.isEmpty else { return settleIfQuiet(at: now) }
        var atRest: Bool?
        for line in lines {
            guard let record = try? JSONDecoder().decode(JSONValue.self, from: line),
                  let type = record["type"]?.stringValue else { continue }
            isAwake = isAwake || type == "SYSTEM_MESSAGE"
            guard isAwake else { continue }
            turnLines.append(line)
            turnLines.append(0x0A)
            guard type != "CHECKPOINT" else { continue }
            let calls = record["tool_calls"]?.arrayValue ?? []
            if type == "PLANNER_RESPONSE" {
                responseStep = record["step_index"]?.integerValue
                callsWithoutResult = calls.map { $0["name"]?.stringValue ?? "" }
            } else if type == "GENERIC", !callsWithoutResult.isEmpty {
                callsWithoutResult.removeFirst()
            }
            atRest = type == "PLANNER_RESPONSE" && calls.isEmpty
        }
        guard let atRest else { return [] }
        lastLine = now
        var payloads: [HarnessEventPayload] = isRunning ? [] : [.sessionStatusChanged(.running)]
        isRunning = true
        for entry in AntigravityTranscriptParser.entries(conversationID: conversationID, jsonl: turnLines)
        where shown[entry.id] != entry.content {
            let isNew = shown[entry.id] == nil
            shown[entry.id] = entry.content
            switch entry.content {
            case let .reasoning(text, _):
                redelivery.expect(thought: text)
                payloads.append(.reasoningCompleted(text))
            case let .assistant(text, _):
                redelivery.expect(answer: text)
                payloads.append(.assistantMessageCompleted(text))
            case let .activity(activity, _):
                if isNew { redelivery.expectToolCall() }
                payloads.append(.activityCompleted(activity))
            default:
                break
            }
        }
        return atRest ? payloads + endTurn() : payloads
    }

    /// Ends a running turn the person stopped.
    mutating func stop() -> [HarnessEventPayload] {
        isRunning ? endTurn() : []
    }

    private mutating func endTurn() -> [HarnessEventPayload] {
        isRunning = false
        turnLines = Data()
        shown = [:]
        return [.turnCompleted, .sessionStatusChanged(.ready)]
    }

    /// A turn quiet for `quietLimit` leaves the task ready. One stopped on a tool call that has no
    /// result, where a step can wait for approval, ends as any turn does, which also tells a task
    /// waiting on this one that it has stopped, with a row saying why, as print mode lists what it
    /// could not ask about (`denied_actions`). It is no failure: the step may only be slow.
    private mutating func settleIfQuiet(at now: ContinuousClock.Instant) -> [HarnessEventPayload] {
        guard isRunning, lastLine.duration(to: now) >= quietLimit else { return [] }
        guard stepsWaitForApproval, let call = callsWithoutResult.first else {
            isRunning = false
            return [.sessionStatusChanged(.ready)]
        }
        let row = HarnessActivity(
            id: "\(conversationID)-\(responseStep.map(String.init) ?? "step")-waiting",
            kind: "wait",
            title: L10n.string("Waiting for approval or still running"),
            detail: call.replacingOccurrences(of: "_", with: " "),
            outcome: .stopped,
            output: Self.waitingStepNotice)
        return [.activityCompleted(row)] + endTurn()
    }

    /// The whole lines past `position`. The CLI only adds to the log; a line still being written waits
    /// for the next read.
    private mutating func newLines() -> [Data] {
        guard let url = store.transcriptURL(conversationID: conversationID),
              let size = Self.size(of: url), size > position,
              let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: position)) != nil,
              let data = try? handle.readToEnd(),
              let end = data.lastIndex(of: 0x0A) else { return [] }
        let whole = data[..<end]
        position += UInt64(whole.count + 1)
        return whole.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    private static func size(of url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.uint64Value
    }
}

/// What the log showed of an agent's turn and the next prompt's stream sends again, before that
/// prompt's own steps. Thoughts and answers are the log's words exactly, and tool calls come in the
/// log's order under IDs the log does not have, so each is recognised as the next one expected.
/// Anything else ends the matching: a repeat that is not recognised shows twice, and the turn's own
/// steps are never dropped.
struct AntigravityRedelivery: Equatable, Sendable {
    private var thoughts: [String] = []
    private var answers: [String] = []
    private var toolCalls = 0
    private var dropped: Set<String> = []

    mutating func expect(thought: String) { thoughts.append(thought) }
    mutating func expect(answer: String) { answers.append(answer) }
    mutating func expectToolCall() { toolCalls += 1 }

    /// Whether `update` repeats what was shown, and goes no further.
    mutating func absorbs(_ update: JSONValue) -> Bool {
        switch update["sessionUpdate"]?.stringValue {
        case "agent_thought_chunk":
            return Self.take(update["content"]?["text"]?.stringValue, from: &thoughts) || giveUp()
        case "agent_message_chunk":
            return Self.take(update["content"]?["text"]?.stringValue, from: &answers) || giveUp()
        case "tool_call":
            guard toolCalls > 0, let id = update["toolCallId"]?.stringValue else { return giveUp() }
            toolCalls -= 1
            dropped.insert(id)
            return true
        case "tool_call_update":
            return update["toolCallId"]?.stringValue.map(dropped.contains) ?? false
        default:
            return false
        }
    }

    /// Takes `chunk` off the first expected text. A completed step comes as one chunk and a text may
    /// come in several; the log's words are trimmed where the stream's may not be.
    private static func take(_ chunk: String?, from expected: inout [String]) -> Bool {
        guard let chunk, let first = expected.first else { return false }
        let text = first.hasPrefix(chunk) ? chunk : chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard first.hasPrefix(text) else { return false }
        let rest = String(first.dropFirst(text.count))
        if rest.isEmpty { expected.removeFirst() } else { expected[0] = rest }
        return true
    }

    private mutating func giveUp() -> Bool {
        self = AntigravityRedelivery()
        return false
    }
}
