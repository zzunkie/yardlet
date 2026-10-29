import Foundation

struct CodexTaskState: Equatable, Sendable {
    var thread: CodexThreadState?
    var approvalsByID: [String: CodexApprovalState] = [:]
    var serverRequestsByID: [String: CodexServerRequestState] = [:]
    var lastAppliedSequence: UInt64?
    /// Notices that arrived while no turn was running, shown at the top of the next turn. They are
    /// reducer bookkeeping and are not part of the published presentation.
    var pendingNotices: [JSONValue] = []

    static let empty = CodexTaskState()
}

extension CodexTaskState {
    /// The only turn identity that may be used for an explicit steer action.
    /// A running session without a typed in-progress turn is intentionally not steerable;
    /// callers must fail closed instead of inventing a turn identity.
    var activeTurnID: String? {
        thread?.turns.last(where: { $0.status == .inProgress })?.id
    }

    /// Whether this presentation can say which turn is active, given the turn the provider last
    /// reported active. One without that turn predates it: a read sent before the turn started, an
    /// event published before the start was answered, or any state from before `turn/started`
    /// arrived. The reported turn stands until a presentation that has it shows it ended.
    func knowsActiveTurn(_ reportedTurnID: String?) -> Bool {
        guard let reportedTurnID else { return true }
        return thread?.turns.contains { $0.id == reportedTurnID } == true
    }
}

struct CodexThreadState: Equatable, Identifiable, Sendable {
    let id: String
    var sessionID: String?
    var name: String?
    var preview: String
    var workspacePath: String?
    var cliVersion: String?
    var modelProvider: String?
    var parentThreadID: String?
    var forkedFromID: String?
    var status: CodexThreadRuntimeStatus
    var canAcceptDirectInput: Bool?
    var createdAt: Date?
    var updatedAt: Date?
    var turns: [CodexTurnState]
    var turnsNextCursor: String?
    /// Head cursors returned by `thread/resume` for reversing a paginated history walk.
    /// They remain provider-owned state even when the current UI walks forward from the
    /// bootstrap page.
    var turnsBackwardsCursor: String?
    var itemsBackwardsCursor: String?
    var raw: JSONValue
}

enum CodexThreadRuntimeStatus: Equatable, Sendable {
    case notLoaded
    case idle
    case active(flags: [String])
    case systemError
    case unknown(JSONValue?)

    /// A loaded thread with no turn running, which takes a new turn: idle, or ended on an error. The
    /// App Server reports `systemError` from a turn's failure (a busy server, a lost connection)
    /// until the next turn starts, and a `turn/start` continues the thread from it.
    var isSettled: Bool { self == .idle || self == .systemError }
}

enum CodexThreadStatusTone: Equatable, Sendable {
    case neutral
    case active
    case warning
    case error
}

struct CodexThreadStatusPresentation: Equatable, Sendable {
    let title: String
    let accessibilityValue: String
    let symbolName: String
    let tone: CodexThreadStatusTone
}

enum CodexThreadStatusProjection {
    static func presentation(for status: CodexThreadRuntimeStatus) -> CodexThreadStatusPresentation {
        switch status {
        case .notLoaded:
            return CodexThreadStatusPresentation(
                title: L10n.string("Not loaded"),
                accessibilityValue: L10n.string("Not loaded"),
                symbolName: "arrow.down.circle",
                tone: .neutral
            )
        case .idle:
            return CodexThreadStatusPresentation(
                title: L10n.string("Ready"),
                accessibilityValue: L10n.string("Ready"),
                symbolName: "checkmark.circle",
                tone: .neutral
            )
        case let .active(flags):
            let normalizedFlags = flags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let detail = normalizedFlags.isEmpty
                ? nil
                : L10n.format("Active flags: %@", normalizedFlags.joined(separator: ", "))
            return CodexThreadStatusPresentation(
                title: L10n.string("Running"),
                accessibilityValue: [L10n.string("Running"), detail]
                    .compactMap { $0 }
                    .joined(separator: ", "),
                symbolName: "circle.dotted",
                tone: .active
            )
        case .systemError:
            return CodexThreadStatusPresentation(
                title: L10n.string("Runtime error"),
                accessibilityValue: L10n.string("Runtime error"),
                symbolName: "exclamationmark.triangle",
                tone: .error
            )
        case .unknown:
            return CodexThreadStatusPresentation(
                title: L10n.string("Unknown"),
                accessibilityValue: L10n.string("Unknown"),
                symbolName: "questionmark.circle",
                tone: .warning
            )
        }
    }
}

struct CodexTurnState: Equatable, Identifiable, Sendable {
    let id: String
    var status: CodexTurnStatus
    var startedAt: Date?
    var completedAt: Date?
    var durationMilliseconds: Int64?
    var itemsView: CodexItemsView
    var items: [CodexItemState]
    var itemsNextCursor: String?
    var plan: CodexPlanState?
    var tokenUsage: CodexThreadTokenUsage?
    var error: JSONValue?
    var raw: JSONValue
    /// The turn's aggregated unified diff from `turn/diff/updated`, replaced as the turn edits
    /// files. Only a live turn has it: saved turns carry their file change items instead.
    var diff: String? = nil
    /// The `TurnError` of the latest `error` notification with `willRetry` while the provider
    /// reconnects this turn. The next progress on the turn clears it; history never has it.
    var retryingError: JSONValue? = nil
}

enum CodexTurnStatus: Equatable, Sendable {
    case inProgress
    case completed
    case interrupted
    case failed
    case unknown(String)

    var isTerminal: Bool {
        switch self {
        case .completed, .interrupted, .failed:
            true
        case .inProgress, .unknown:
            false
        }
    }
}

enum CodexItemsView: Equatable, Sendable {
    case notLoaded
    case summary
    case full
    case unknown(String)
}

struct CodexItemState: Equatable, Identifiable, Sendable {
    let id: String
    var lifecycle: CodexItemLifecycle
    var startedAt: Date?
    var completedAt: Date?
    var content: CodexItemContent
    var raw: JSONValue
}

enum CodexItemLifecycle: Int, Equatable, Comparable, Sendable {
    case historical = 0
    case inProgress = 1
    case completed = 2

    static func < (lhs: CodexItemLifecycle, rhs: CodexItemLifecycle) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum CodexItemContent: Equatable, Sendable {
    case userMessage(CodexUserMessageItem)
    case hookPrompt(fragments: [JSONValue])
    case agentMessage(CodexAgentMessageItem)
    case plan(text: String)
    case reasoning(summary: [JSONValue], content: [JSONValue])
    case commandExecution(CodexCommandItem)
    case fileChange(CodexFileChangeItem)
    case mcpToolCall(CodexMCPToolItem)
    case dynamicToolCall(CodexDynamicToolItem)
    case collaboration(CodexCollaborationItem)
    case subagentActivity(CodexSubagentActivityItem)
    case webSearch(query: String, action: JSONValue?, results: [JSONValue]?)
    case imageView(path: String)
    case sleep(durationMilliseconds: Int64)
    case imageGeneration(CodexImageGenerationItem)
    case enteredReviewMode(review: String)
    case exitedReviewMode(review: String)
    case contextCompaction
    case notice(CodexNoticeItem)
    case unknown(type: String?, raw: JSONValue)

    var typeName: String {
        switch self {
        case .userMessage: "userMessage"
        case .hookPrompt: "hookPrompt"
        case .agentMessage: "agentMessage"
        case .plan: "plan"
        case .reasoning: "reasoning"
        case .commandExecution: "commandExecution"
        case .fileChange: "fileChange"
        case .mcpToolCall: "mcpToolCall"
        case .dynamicToolCall: "dynamicToolCall"
        case .collaboration: "collabAgentToolCall"
        case .subagentActivity: "subAgentActivity"
        case .webSearch: "webSearch"
        case .imageView: "imageView"
        case .sleep: "sleep"
        case .imageGeneration: "imageGeneration"
        case .enteredReviewMode: "enteredReviewMode"
        case .exitedReviewMode: "exitedReviewMode"
        case .contextCompaction: "contextCompaction"
        case .notice: CodexNoticeItem.itemType
        case let .unknown(type, _): type ?? "unknown"
        }
    }

    var shouldPersistAcrossResume: Bool {
        switch self {
        case .userMessage, .hookPrompt, .agentMessage, .plan, .reasoning:
            return false
        case .commandExecution, .fileChange, .mcpToolCall, .dynamicToolCall,
             .collaboration, .subagentActivity, .webSearch, .imageView, .sleep,
             .imageGeneration, .enteredReviewMode, .exitedReviewMode, .contextCompaction,
             .notice:
            return true
        case let .unknown(type, _):
            guard let type = type?.lowercased() else { return false }
            return type.contains("command") || type.contains("tool") || type.contains("filechange")
        }
    }
}

extension CodexItemState {
    /// Provider item shape carrying the text streamed after `item/started`. `raw` keeps the
    /// original provider frame, so a consumer that rebuilds typed items from JSON reads this
    /// instead. Items without streamed text return `raw` unchanged.
    var renderedPayload: JSONValue {
        var fields = raw.objectValue ?? [:]
        switch content {
        case let .agentMessage(message):
            fields["id"] = .string(id)
            fields["type"] = .string("agentMessage")
            fields["text"] = .string(message.text)
            switch message.phase {
            case .commentary: fields["phase"] = .string("commentary")
            case .finalAnswer: fields["phase"] = .string("final_answer")
            case let .unknown(value): fields["phase"] = value.map(JSONValue.string)
            }
            fields["memoryCitation"] = message.memoryCitation
        case let .plan(text):
            fields["text"] = .string(text)
        case let .reasoning(summary, content):
            fields["summary"] = .array(summary)
            fields["content"] = .array(content)
        case let .commandExecution(command):
            guard let output = command.aggregatedOutput else { return raw }
            fields["aggregatedOutput"] = .string(output)
        case let .fileChange(change):
            fields["changes"] = .array(change.changes)
        default:
            return raw
        }
        return .object(fields)
    }
}

/// Reasoning parts as the timeline shows them. A summary part announced by
/// `item/reasoning/summaryPartAdded` stays empty until its text streams, and a provider that
/// withholds raw reasoning sends no content; neither adds a line or a block.
enum CodexReasoningProjection {
    static func text(from parts: [JSONValue]) -> String? {
        let lines = parts
            .compactMap(\.stringValue)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// App-local fallback for provider timeline items that current Codex history endpoints omit.
/// Retains activity items and observed partial answers from interrupted turns. Provider items
/// remain authoritative whenever they are present on resume.
struct CodexPersistedTimelineItem: Codable, Equatable, Sendable, Identifiable {
    let turnID: String
    let id: String
    let lifecycleRawValue: Int
    let startedAt: Date?
    let completedAt: Date?
    let raw: JSONValue

    init(turnID: String, item: CodexItemState) {
        self.turnID = turnID
        id = item.id
        if case .agentMessage = item.content { lifecycleRawValue = CodexItemLifecycle.historical.rawValue }
        else { lifecycleRawValue = item.lifecycle.rawValue }
        startedAt = item.startedAt
        completedAt = item.completedAt
        if case let .agentMessage(message) = item.content {
            // Token deltas update typed content; item.raw still contains the initial empty text.
            var fields = item.raw.objectValue ?? [:]
            fields["id"] = .string(item.id)
            fields["type"] = .string("agentMessage")
            fields["text"] = .string(message.text)
            switch message.phase {
            case .finalAnswer: fields["phase"] = .string("final_answer")
            case .commentary: fields["phase"] = .string("commentary")
            case let .unknown(value): if let value { fields["phase"] = .string(value) }
            }
            raw = .object(fields)
        } else {
            // Output streamed into a command that never completed exists only in typed content.
            raw = item.renderedPayload
        }
    }

    var pageEntry: CodexItemPageEntry {
        var item = CodexTaskDecoder().item(
            from: raw,
            fallbackID: id,
            lifecycle: CodexItemLifecycle(rawValue: lifecycleRawValue) ?? .historical
        )
        item.startedAt = startedAt
        item.completedAt = completedAt
        return CodexItemPageEntry(turnID: turnID, item: item)
    }
}

struct CodexUserMessageItem: Equatable, Sendable {
    let content: [JSONValue]
    let clientID: String?
}

struct CodexAgentMessageItem: Equatable, Sendable {
    var text: String
    var phase: CodexMessagePhase
    let memoryCitation: JSONValue?
    /// The questions Codex asked with this message (`request_user_input_async`): the message's text
    /// repeats each title and lists its options, and the Codex app shows the titles and answers
    /// with the options instead.
    var questions: [CodexAsyncQuestion] = []
    /// How Codex delivered the message (`delivery`): "async" for one it sent while its work went on.
    var delivery: String? = nil

    /// Codex sent the message while its work went on (`delivery: "async"`), as it sends a question it
    /// asks with `request_user_input_async`: the turn goes on past it, so it is never the turn's answer,
    /// as the Codex app never draws it as one.
    var isDeliveredAsync: Bool { delivery == "async" || !questions.isEmpty }

    /// Working notes (`commentary`), which the turn's work folds. Anything else Codex writes is said to
    /// the person: its answer, or a question it asked while it worked.
    var isCommentary: Bool { phase == .commentary && !isDeliveredAsync }
}

/// A question a Codex message asks the person (`agentMessage.questions`), answered with one of its
/// options or the person's own words in the reply message (`CodexAsyncQuestionReply`).
struct CodexAsyncQuestion: Equatable, Sendable {
    let title: String
    let options: [String]
    /// The Codex app's ID for the question, which its reply names (`questionItemId`): the message
    /// and the question's place in it.
    var itemID: String = ""

    /// - Parameter messageID: the asking message's item ID.
    static func parse(_ value: JSONValue?, messageID: String? = nil) -> [CodexAsyncQuestion] {
        (value?.arrayValue ?? []).enumerated().compactMap { index, question in
            guard let title = question["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let options = (question["options"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
            return CodexAsyncQuestion(title: title, options: options,
                                      itemID: CodexAsyncQuestionReply.itemID(messageID: messageID ?? "", index: index))
        }
    }
}

/// The Codex app's reply to a message's questions (`request_user_input_async`): one message, its
/// whole text `<send_user_message_question_reply>`, the answers as a JSON array of
/// `{questionItemId, question, answer}`, and the closing tag. Codex's own TUI knows the same
/// envelope. The Codex app sends only the questions answered, and reads a reply back to show each
/// question's answer instead of the reply's text.
enum CodexAsyncQuestionReply {
    static let opening = "<send_user_message_question_reply>"
    static let closing = "</send_user_message_question_reply>"

    struct Answer: Equatable, Sendable {
        let questionItemID: String
        let question: String
        let answer: String
    }

    /// The question's ID as the Codex app writes it: `["request_user_input_async", messageID, index]`
    /// as compact JSON.
    static func itemID(messageID: String, index: Int) -> String {
        "[\"request_user_input_async\",\(json(messageID)),\(index)]"
    }

    /// The reply message for `answers`, as the Codex app writes it.
    static func message(_ answers: [Answer]) -> String {
        let entries = answers.map { answer in
            "{\"questionItemId\":\(json(answer.questionItemID)),\"question\":\(json(answer.question)),\"answer\":\(json(answer.answer))}"
        }
        return "\(opening)\n[\(entries.joined(separator: ","))]\n\(closing)"
    }

    /// The answers a message's text holds when the whole text is a reply; nil otherwise. A reply may
    /// hold one answer object instead of an array.
    static func answers(in text: String) -> [Answer]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(opening), trimmed.hasSuffix(closing),
              trimmed.count >= opening.count + closing.count else { return nil }
        let body = trimmed.dropFirst(opening.count).dropLast(closing.count)
        guard let data = String(body).data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        let entries: [JSONValue] = value.arrayValue ?? (value.objectValue != nil ? [value] : [])
        let answers = entries.compactMap { entry -> Answer? in
            guard let id = entry["questionItemId"]?.stringValue, let question = entry["question"]?.stringValue,
                  let answer = entry["answer"]?.stringValue else { return nil }
            return Answer(questionItemID: id, question: question, answer: answer)
        }
        return answers.isEmpty || answers.count != entries.count ? nil : answers
    }

    /// A reply as the person's message reads: the one answer, or each question over its answer.
    static func readableText(_ answers: [Answer]) -> String {
        guard answers.count > 1 else { return answers.first?.answer ?? "" }
        return answers.map { "\($0.question)\n\($0.answer)" }.joined(separator: "\n\n")
    }

    /// `text` as a JSON string, as JavaScript's `JSON.stringify` writes it (no escaped slashes).
    private static func json(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded
    }
}

enum CodexMessagePhase: Equatable, Sendable {
    case commentary
    case finalAnswer
    case unknown(String?)
}

struct CodexCommandItem: Equatable, Sendable {
    let command: String
    let workspacePath: String
    let status: String
    /// Grows with `item/commandExecution/outputDelta` while the command runs; `item/completed`
    /// replaces it with the provider's aggregated value.
    var aggregatedOutput: String?
    let exitCode: Int64?
    let durationMilliseconds: Int64?
    let processID: String?
    let source: String?
    let actions: [JSONValue]
    /// Set once live output outgrows its buffer: `aggregatedOutput` then holds this many bytes of
    /// the command's first output, the truncation line, and its latest output.
    var liveOutputHeadByteCount: Int? = nil
}

/// A provider notification shown inline in its turn. The App Server sends these beside a turn's
/// items rather than as items, so the reducer records each as an app-local item of this type.
struct CodexNoticeItem: Equatable, Sendable {
    static let itemType = "yardletNotice"

    enum Kind: String, Equatable, Sendable {
        case modelRerouted
        case warning
        case configWarning
        case deprecationNotice
    }

    let kind: Kind
    /// The model the request went to, or the notice's text.
    let message: String
    let details: String?
    let fromModel: String?
    /// `model/rerouted`'s reason, such as `highRiskCyberActivity`.
    let reason: String?
    let path: String?
}

struct CodexFileChangeItem: Equatable, Sendable {
    /// Replaced wholesale by `item/fileChange/patchUpdated` while the provider writes the patch;
    /// `item/completed` carries the final value.
    var changes: [JSONValue]
    let status: String
}

struct CodexMCPToolItem: Equatable, Sendable {
    let server: String
    let tool: String
    let status: String
    let arguments: JSONValue
    let result: JSONValue?
    let error: JSONValue?
    let pluginID: String?
    let durationMilliseconds: Int64?
}

struct CodexDynamicToolItem: Equatable, Sendable {
    let tool: String
    let namespace: String?
    let status: String
    let arguments: JSONValue
    let contentItems: [JSONValue]
    let succeeded: Bool?
    let durationMilliseconds: Int64?
}

struct CodexCollaborationItem: Equatable, Sendable {
    let tool: String
    let status: String
    let senderThreadID: String
    let receiverThreadIDs: [String]
    let prompt: String?
    let model: String?
    let reasoningEffort: String?
    let agentStates: [String: JSONValue]
}

struct CodexSubagentActivityItem: Equatable, Sendable {
    let agentThreadID: String
    let agentPath: String
    let kind: String
}

struct CodexImageGenerationItem: Equatable, Sendable {
    let status: String
    let result: String
    let revisedPrompt: String?
    let savedPath: String?
    let failure: JSONValue?
}

struct CodexPlanState: Equatable, Sendable {
    var explanation: String?
    var steps: [CodexPlanStep]
}

struct CodexPlanStep: Equatable, Identifiable, Sendable {
    let id: String
    let text: String
    let status: CodexPlanStepStatus
}

enum CodexPlanStepStatus: Equatable, Sendable {
    case pending
    case inProgress
    case completed
    case unknown(String)
}

struct CodexThreadTokenUsage: Codable, Equatable, Sendable {
    let total: CodexTokenUsageBreakdown
    let last: CodexTokenUsageBreakdown
    let modelContextWindow: Int64?
}

struct CodexTokenUsageBreakdown: Codable, Equatable, Sendable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64

    /// OpenAI reports cached input as a subset of input tokens. Keep the raw provider counts
    /// authoritative and expose a ratio only when that invariant makes the calculation honest.
    var cacheHitFraction: Double? {
        guard inputTokens > 0,
              cachedInputTokens >= 0,
              cachedInputTokens <= inputTokens else { return nil }
        return Double(cachedInputTokens) / Double(inputTokens)
    }
}

struct CodexApprovalState: Equatable, Identifiable, Sendable {
    let id: String
    let method: String
    let threadID: String
    let turnID: String?
    let itemID: String?
    var resolution: CodexApprovalResolution
    let raw: JSONValue?
}

struct CodexServerRequestState: Equatable, Identifiable, Sendable {
    let id: String
    let method: String
    let kind: CodexServerRequestKind
    let threadID: String?
    let turnID: String?
    let itemID: String?
    let params: JSONValue?
    var resolution: CodexServerRequestResolution
}

enum CodexServerRequestKind: Equatable, Sendable {
    case commandExecutionApproval
    case fileChangeApproval
    case toolUserInput
    case mcpElicitation
    case permissionsApproval
    case dynamicToolCall
    case authenticationRefresh
    case attestation
    case currentTime
    case applyPatchApproval
    case execCommandApproval
    case unknown(String)

    var wireName: String {
        switch self {
        case .commandExecutionApproval: "commandExecutionApproval"
        case .fileChangeApproval: "fileChangeApproval"
        case .toolUserInput: "toolUserInput"
        case .mcpElicitation: "mcpElicitation"
        case .permissionsApproval: "permissionsApproval"
        case .dynamicToolCall: "dynamicToolCall"
        case .authenticationRefresh: "authenticationRefresh"
        case .attestation: "attestation"
        case .currentTime: "currentTime"
        case .applyPatchApproval: "applyPatchApproval"
        case .execCommandApproval: "execCommandApproval"
        case let .unknown(value): value
        }
    }

    init(wireName: String) {
        switch wireName {
        case "commandExecutionApproval": self = .commandExecutionApproval
        case "fileChangeApproval": self = .fileChangeApproval
        case "toolUserInput": self = .toolUserInput
        case "mcpElicitation": self = .mcpElicitation
        case "permissionsApproval": self = .permissionsApproval
        case "dynamicToolCall": self = .dynamicToolCall
        case "authenticationRefresh": self = .authenticationRefresh
        case "attestation": self = .attestation
        case "currentTime": self = .currentTime
        case "applyPatchApproval": self = .applyPatchApproval
        case "execCommandApproval": self = .execCommandApproval
        default: self = .unknown(wireName)
        }
    }

    var isApproval: Bool {
        switch self {
        case .commandExecutionApproval, .fileChangeApproval, .permissionsApproval,
             .applyPatchApproval, .execCommandApproval:
            true
        case .toolUserInput, .mcpElicitation, .dynamicToolCall, .authenticationRefresh,
             .attestation, .currentTime, .unknown:
            false
        }
    }
}

/// Safe app-local metadata used to reconstruct a server-request card after the provider process
/// is resumed. Resolution is retained because provider history does not include completed
/// approval requests. It intentionally stores request shape/identity, never credentials.
struct CodexPendingServerRequest: Codable, Equatable, Sendable, Identifiable {
    static let expiredRuntimeCode: Int64 = -32002

    let id: String
    let method: String
    let kind: String
    let threadID: String?
    let turnID: String?
    let itemID: String?
    let params: JSONValue?
    let resolutionKind: String?
    let resolvedResult: JSONValue?
    let rejectionCode: Int64?
    let rejectionMessage: String?

    init(_ request: CodexServerRequestState) {
        id = request.id
        method = request.method
        kind = request.kind.wireName
        threadID = request.threadID
        turnID = request.turnID
        itemID = request.itemID
        params = request.params
        switch request.resolution {
        case .pending:
            resolutionKind = "pending"
            resolvedResult = nil
            rejectionCode = nil
            rejectionMessage = nil
        case let .resolved(result):
            resolutionKind = "resolved"
            resolvedResult = result
            rejectionCode = nil
            rejectionMessage = nil
        case let .rejected(code, message):
            resolutionKind = "rejected"
            resolvedResult = nil
            rejectionCode = code
            rejectionMessage = message
        }
    }

    var isPending: Bool {
        if case .pending = state.resolution { return true }
        return false
    }

    var state: CodexServerRequestState {
        CodexServerRequestState(
            id: id,
            method: method,
            kind: CodexServerRequestKind(wireName: kind),
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            params: params,
            resolution: resolution
        )
    }

    private var resolution: CodexServerRequestResolution {
        switch resolutionKind {
        case "resolved":
            return .resolved(resolvedResult)
        case "rejected":
            return .rejected(
                code: rejectionCode ?? -1,
                message: rejectionMessage ?? "Request rejected"
            )
        default:
            // Records written before resolved-request history was introduced contain no kind.
            return .pending
        }
    }
}

enum CodexServerRequestResolution: Equatable, Sendable {
    case pending
    case resolved(JSONValue?)
    case rejected(code: Int64, message: String)
}

enum CodexCommandApprovalDecision: Equatable, Sendable {
    case accept
    case acceptForSession
    case acceptWithExecpolicyAmendment([String])
    case applyNetworkPolicyAmendment(host: String, action: CodexNetworkPolicyAction)
    case decline
    case cancel

    var rawValue: JSONValue {
        switch self {
        case .accept: .string("accept")
        case .acceptForSession: .string("acceptForSession")
        case let .acceptWithExecpolicyAmendment(amendment):
            .object(["acceptWithExecpolicyAmendment": .object([
                "execpolicy_amendment": .array(amendment.map(JSONValue.string))
            ])])
        case let .applyNetworkPolicyAmendment(host, action):
            .object(["applyNetworkPolicyAmendment": .object([
                "network_policy_amendment": .object([
                    "host": .string(host),
                    "action": .string(action.rawValue)
                ])
            ])])
        case .decline: .string("decline")
        case .cancel: .string("cancel")
        }
    }
}

enum CodexFileChangeApprovalDecision: String, Equatable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

enum CodexLegacyReviewDecision: Equatable, Sendable {
    case approved
    case approvedExecpolicyAmendment([String])
    case approvedForSession
    case approvedMCPPolicyAmendment
    case networkPolicyAmendment(host: String, action: CodexNetworkPolicyAction)
    case denied(rejection: String)
    case timedOut
    case abort

    var rawValue: JSONValue {
        switch self {
        case .approved: .string("approved")
        case let .approvedExecpolicyAmendment(amendment):
            .object(["approved_execpolicy_amendment": .object([
                "proposed_execpolicy_amendment": .array(amendment.map(JSONValue.string))
            ])])
        case .approvedForSession: .string("approved_for_session")
        case .approvedMCPPolicyAmendment: .string("approved_mcp_policy_amendment")
        case let .networkPolicyAmendment(host, action):
            .object(["network_policy_amendment": .object([
                "network_policy_amendment": .object([
                    "host": .string(host),
                    "action": .string(action.rawValue)
                ])
            ])])
        case let .denied(rejection):
            .object(["denied": .object(["rejection": .string(rejection)])])
        case .timedOut: .string("timed_out")
        case .abort: .string("abort")
        }
    }
}

enum CodexNetworkPolicyAction: String, Equatable, Sendable {
    case allow
    case deny
}

enum CodexPermissionGrantScope: String, Equatable, Sendable {
    case turn
    case session
}

enum CodexMCPElicitationAction: String, Equatable, Sendable {
    case accept
    case decline
    case cancel
}

enum CodexServerRequestResponse: Equatable, Sendable {
    case command(CodexCommandApprovalDecision)
    case fileChange(CodexFileChangeApprovalDecision)
    case permissions(permissions: JSONValue, scope: CodexPermissionGrantScope, strictAutoReview: Bool?)
    case toolUserInput(answers: [String: [String]])
    /// `meta` is the answer's `_meta`: `{"persist": "session" | "always"}` keeps an MCP tool
    /// approval for the conversation or for good, as the Codex app's cards send it.
    case mcpElicitation(action: CodexMCPElicitationAction, content: JSONValue? = nil, meta: JSONValue? = nil)
    case dynamicToolCall(contentItems: [JSONValue], success: Bool)
    case legacyReview(CodexLegacyReviewDecision)

    func result(for method: String) -> JSONValue? {
        switch (method, self) {
        case ("item/commandExecution/requestApproval", let .command(decision)):
            return .object(["decision": decision.rawValue])
        case ("item/fileChange/requestApproval", let .fileChange(decision)):
            return .object(["decision": .string(decision.rawValue)])
        case let ("item/permissions/requestApproval", .permissions(permissions, scope, strict)):
            var result: [String: JSONValue] = [
                "permissions": permissions,
                "scope": .string(scope.rawValue)
            ]
            if let strict {
                result["strictAutoReview"] = .bool(strict)
            }
            return .object(result)
        case let ("item/tool/requestUserInput", .toolUserInput(answers)):
            return .object([
                "answers": .object(answers.mapValues { .object(["answers": .array($0.map(JSONValue.string))]) })
            ])
        case let ("mcpServer/elicitation/request", .mcpElicitation(action, content, meta)):
            var result: [String: JSONValue] = ["action": .string(action.rawValue)]
            if let content {
                result["content"] = content
            }
            if let meta {
                result["_meta"] = meta
            }
            return .object(result)
        case let ("item/tool/call", .dynamicToolCall(contentItems, success)):
            return .object([
                "contentItems": .array(contentItems),
                "success": .bool(success)
            ])
        case let ("applyPatchApproval", .legacyReview(decision)),
             let ("execCommandApproval", .legacyReview(decision)):
            return .object(["decision": decision.rawValue])
        default:
            return nil
        }
    }
}

enum CodexApprovalResolution: Equatable, Sendable {
    case pending
    case resolved(JSONValue?)
}

struct CodexTurnPage: Equatable, Sendable {
    let turns: [CodexTurnState]
    let nextCursor: String?
    let backwardsCursor: String?
}

struct CodexItemPageEntry: Equatable, Sendable {
    let turnID: String
    let item: CodexItemState
}

struct CodexItemPage: Equatable, Sendable {
    let entries: [CodexItemPageEntry]
    let nextCursor: String?
    let backwardsCursor: String?
}
