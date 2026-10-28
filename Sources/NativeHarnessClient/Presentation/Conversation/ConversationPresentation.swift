import Foundation

// The one model a conversation renderer reads, whatever the harness: turns, and in each turn what
// the person sent, the provider's notices, the work, the answers and the requests waiting on the
// person.
//
// It is projected from a provider's own record and never stored: Codex from `CodexTaskState`
// (`CodexConversationProjection`), every other harness from `[TranscriptEntry]`. Nothing here
// changes either record. Positions, shapes and controls are shared; the provider's option names,
// effects, IDs and storage stay its own.
//
// Items and requests keep their `source`: the record a card reads where only one provider sends
// that kind of item (a Codex proposed plan or notice), and where a saved reading place names a
// record's ID. Every other item is drawn from its normalized fields (M12).

struct ConversationPresentation: Equatable, Sendable {
    let harness: HarnessKind
    var turns: [ConversationTurn]
    var earlier: ConversationEarlierTurns = .none
    /// Requests still waiting for an answer, which auto-follow and the permission control read.
    var pendingRequestIDs: Set<String> = []
    /// The latest turn's token usage (Codex only, for now).
    var tokenUsage: CodexThreadTokenUsage? = nil
}

/// Turns before the first one shown.
enum ConversationEarlierTurns: Equatable, Sendable {
    case none
    /// The provider holds earlier turns behind a cursor (Codex `thread/turns/list`).
    case provider(cursor: String)
    /// The provider's saved file holds earlier turns than the part of it read (a Claude transcript
    /// read from its end, `ClaudeTranscriptTail`); a read further back brings them in, until the
    /// file's start.
    case providerFile
    /// Loaded turns left out of the local window.
    case local(hiddenCount: Int)
}

struct ConversationTurn: Identifiable, Equatable, Sendable {
    /// Codex `turn.id`; for the shared transcript, the UUID of the entry that opened the turn.
    let id: String
    var status: ConversationTurnStatus
    var timing: ConversationTurnTiming
    /// What the person sent: messages, and Claude bash commands.
    var prompt: [ConversationItem] = []
    /// The provider's notices beside the turn, such as a model reroute.
    var notices: [ConversationItem] = []
    var plan: ConversationPlan? = nil
    /// Everything after the request in the order it happened, but the closing answer
    /// (`ConversationTurnLayout`): what the provider did and said, the requests it asked and the person
    /// answered, and the messages the person sent into the running turn (D13). It folds by one rule for
    /// every harness (`foldsWork`, `workKeptWhenFolded`).
    var work: [ConversationItem] = []
    /// The answer that closes the turn, and a proposed plan.
    var answers: [ConversationItem] = []
    /// Requests waiting for an answer, pinned under the turn. An answered request is a `.request`
    /// item in the work, where it happened, and folds with it (D1).
    var requests: [ConversationRequest] = []
    var outcome: ConversationTurnOutcome? = nil
    var progress: ConversationTurnProgress = .none
    /// The turn has work to fold: its plan, work items, or items still to load.
    var hasWorkDetails: Bool = false
    /// The provider holds more of this turn's items behind a cursor.
    var hasMoreItems: Bool = false
    /// The turn draws its header (work time, fold control, turn menu). Codex draws one for a turn
    /// with a label, a sent request, work or timing; a shared transcript for a finished turn with a
    /// work time or folded work, or a turn whose menu offers something (D3, D4).
    var showsHeader: Bool = false
    var actions: ConversationTurnActions = ConversationTurnActions()
    /// The IDs of the turn's parts in the order its record holds them: a shared transcript's
    /// entries, whatever part each became (prompt, work, answer, request, plan or outcome). Empty
    /// where the parts have no order beyond the turn's own (Codex). Since M12e every turn is drawn
    /// in the turn order (plan A5.1); the record order stays for reading a turn back as its record.
    var recordOrder: [String] = []

    /// Every part compared, the ones a streaming turn changes and the sizes of its long parts first:
    /// views compare a turn on every update, and a running turn with many calls was told apart from
    /// its previous version only after comparing every call. Each stored property is compared;
    /// `ConversationTurnEqualityTests` fails when one is added and this is not updated.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.progress == rhs.progress
            && lhs.outcome == rhs.outcome
            && lhs.hasWorkDetails == rhs.hasWorkDetails && lhs.hasMoreItems == rhs.hasMoreItems
            && lhs.showsHeader == rhs.showsHeader
            && lhs.work.count == rhs.work.count && lhs.answers.count == rhs.answers.count
            && lhs.prompt.count == rhs.prompt.count && lhs.notices.count == rhs.notices.count
            && lhs.requests.count == rhs.requests.count && lhs.recordOrder.count == rhs.recordOrder.count
            && lhs.answers == rhs.answers && lhs.requests == rhs.requests && lhs.timing == rhs.timing
            && lhs.work.last == rhs.work.last && lhs.prompt == rhs.prompt && lhs.notices == rhs.notices
            && lhs.plan == rhs.plan && lhs.actions == rhs.actions
            && lhs.work == rhs.work && lhs.recordOrder == rhs.recordOrder
    }

    /// The stored properties `==` compares, for the test that keeps it whole.
    static let comparedPropertyCount = 16
}

enum ConversationTurnStatus: Equatable, Sendable {
    case running
    case completed
    case interrupted
    case failed
    case unknown(String?)

    var isTerminal: Bool {
        switch self {
        case .completed, .interrupted, .failed: true
        case .running, .unknown: false
        }
    }
}

struct ConversationTurnTiming: Equatable, Sendable {
    var startedAt: Date? = nil
    var completedAt: Date? = nil
    var durationMilliseconds: Int64? = nil
    /// The times are read from the items' own times rather than reported by the provider.
    var isApproximate: Bool = false
}

/// The status line under a running turn's work.
enum ConversationTurnProgress: Equatable, Sendable {
    case none
    case thinking
    /// The provider is retrying its response stream, in its own words.
    case reconnecting(String)
}

enum ConversationTurnOutcome: Equatable, Sendable {
    case error(ConversationTurnError)
    /// A plan limit stopped the turn. Continuing automatically reads the entry's ID.
    case usageLimit(HarnessRateLimit, entryID: UUID)
}

struct ConversationTurnError: Equatable, Sendable {
    /// A plain headline for a category the person acts on differently, above the provider's text.
    var title: String?
    /// The provider's whole diagnostic text, which the card's details and copy keep.
    var message: String
    var isRecoverable: Bool
    /// The shared transcript's error entry; nil for a Codex turn error.
    var entryID: UUID? = nil

    var summary: String { TranscriptRecoveryProjection.errorSummary(message) }
}

/// What a turn offers, and on what. A control is drawn only when the turn offers it and the
/// task's `ConversationActions` can carry it out.
struct ConversationTurnActions: Equatable, Sendable {
    /// The request the turn sent, as the composer reads it back. Codex draws the turn menu only
    /// for a turn that has one.
    var editDraft: CodexComposerDraft? = nil
    /// The request can be edited now. Codex allows it on the latest turn with a sent message,
    /// once every turn has finished.
    var canEdit: Bool = false
    /// Fork from this turn. Codex allows it once the turn has finished; Claude Code only on its
    /// latest turn while idle, as a fork of the whole saved conversation (D10).
    var canFork: Bool = false
    /// Retry the latest turn, which an error its provider says can pass ended: a busy server, a rate
    /// limit or a lost connection (`CodexTurnRecoveryProjection.canRetry`, `HarnessEventPayload.error`).
    var canRetry: Bool = false
    /// The proposed plan the turn asks to implement.
    var planToImplement: String? = nil
    /// The questions the latest finished turn ended on, answered with one of their options or the
    /// person's own words (Codex `request_user_input_async`).
    var questionsToAnswer: [CodexAsyncQuestion] = []
    /// The questions the turn ended on that the person answered, with the answers the reply message
    /// recorded, by each question's `itemID`.
    var answeredQuestions: ConversationAnsweredAsyncQuestions? = nil
    /// The turn's message the provider can rewind to and edit (Claude's "Edit message"), unlike
    /// `canEdit`, which puts a request back in the composer.
    var editLatest: ConversationMessageTarget? = nil
    /// The message whose file changes the provider can restore (Claude's "Restore files…").
    var restoreFiles: ConversationMessageTarget? = nil
    /// The request's "Edit message" puts it back in the composer (Codex), offered while `canEdit`
    /// (`ConversationTurnAction.editTurn`).
    var editsTurnInComposer: Bool = false

    /// What "Edit request" on the turn's error card puts back: an editable turn's request.
    var failedRequestDraft: CodexComposerDraft? { canEdit ? editDraft : nil }
}

/// A sent message a turn action works on: the transcript entry and its text.
struct ConversationMessageTarget: Equatable, Sendable {
    let entryID: UUID
    let text: String
}

/// A step plan, from Codex `turn/plan/updated` or a harness's plan text.
struct ConversationPlan: Equatable, Sendable {
    struct Step: Identifiable, Equatable, Sendable {
        let id: String
        var text: String
        var status: StepStatus
    }

    enum StepStatus: Equatable, Sendable {
        case pending
        case inProgress
        case completed
        case unknown(String)
    }

    var explanation: String?
    var steps: [Step]
    /// The shared transcript's plan entry, which today's plan card draws; nil for Codex.
    var source: ConversationItemSource? = nil
}

// MARK: - Items

struct ConversationItem: Identifiable, Equatable, Sendable {
    /// Codex `item.id`, or the transcript entry's UUID.
    let id: String
    var kind: ConversationItemKind
    var phase: ConversationItemPhase
    /// The item matches the history result the task was opened from.
    var isHistoryMatch: Bool = false
    var source: ConversationItemSource
    /// What "Copy item details" puts on the clipboard for an activity: what it ran and returned.
    var copyDetails: String? = nil
    /// A sent message the Codex app wrote around the person's request: the context it attached,
    /// which the message draws around the request (`CodexUserPrompt`). Nil when it has none to draw.
    var promptAttachments: CodexPromptAttachments? = nil
    /// A message another task sent with the `send_message` session tool (`TaskMessage`): the item is
    /// its body, drawn under "Sent from {task}" rather than as the person's message. Nil otherwise.
    var taskMessage: TaskMessage? = nil
    /// The notice of a background command or agent that ended, which Claude Code wrote to start this
    /// turn (`ClaudeTaskNotification`): the item is its summary, drawn as the notice, not the person's.
    var backgroundTaskNotice: ClaudeTaskNotification? = nil
    /// What the provider said to the person while its work went on (Codex `delivery: "async"`, a
    /// question it asked with `request_user_input_async`): an answer in shape, but the turn goes on
    /// past it, so it never closes the turn and folds with the work (`ConversationTurnLayout`).
    var isSentWhileWorking: Bool = false
    /// What the provider wrote reached Yardlet only as a summary: a note Claude wrote between tool
    /// calls, which the API sent back as thinking (`TranscriptEntry.isProgressUpdate`). The message
    /// says so, as Claude Code's terminal marks it "summarized".
    var isSummary: Bool = false
}

enum ConversationItemPhase: Equatable, Sendable {
    case running
    case completed
    case failed
    /// It was still running, or was interrupted, when its turn ended.
    case stopped
}

/// The record an item was projected from: what a Codex proposed plan or notice card draws, and what a
/// saved reading place names.
enum ConversationItemSource: Equatable, Sendable {
    case codex(CodexItemState, turnID: String)
    case transcript(TranscriptEntry)
}

enum ConversationItemKind: Equatable, Sendable {
    case userMessage(text: String, images: [TranscriptImageAttachment])
    /// A message a Codex app automation sent on its schedule in the person's place (a heartbeat),
    /// drawn as its instructions under "Sent by scheduled task", as the Codex app draws it.
    case scheduledTaskMessage(ConversationScheduledTaskMessage)
    case shellCommand(ClaudeBashMessage, entryID: UUID)
    case answer(text: String, isStreaming: Bool)
    case commentary(text: String, isStreaming: Bool)
    case reasoning(summary: String?, detail: String?, isStreaming: Bool)
    case proposedPlan(text: String, isWriting: Bool)
    case command(ConversationCommand)
    case fileChange(ConversationFileChange)
    case tool(ConversationTool)
    case subagent(ConversationSubagent)
    /// Yardlet's `spawn_task` call: a suggested task, drawn as a chip where the call happened.
    case taskSuggestion(ConversationTaskSuggestion)
    /// Yardlet's `create_scheduled_task` call: the schedule it made, drawn as one row where the call
    /// happened.
    case scheduleCreated(ConversationScheduleCreation)
    case notice(CodexNoticeItem)
    case compaction(HarnessContextCompaction)
    /// A request already answered, kept with the work.
    case request(ConversationRequest)
    /// An error or limit the turn went on past. The turn's `outcome` is its last one; an earlier one
    /// stays in the work where it happened (the shared transcript).
    case outcome(ConversationTurnOutcome)
}

struct ConversationCommand: Equatable, Sendable {
    var command: String
    var workingDirectory: String?
    /// The provider's own status word.
    var status: String
    var output: String?
    var exitCode: Int64?
    var durationMilliseconds: Int64?
    /// While a Codex command runs: the bytes of `output` that are its first lines, kept ahead of
    /// its latest lines.
    var liveOutputHeadByteCount: Int?
    /// An allowed request for this command, folded into the card.
    var isApproved: Bool = false
    /// The provider keeps the command running after the turn.
    var isBackground: Bool = false
    /// What the Codex App Server parsed the command into (`commandActions`), which its line is
    /// worded from. Empty for any other harness, and when the server sent none.
    var actions: [ConversationCommandAction] = []
    /// What the call said the command does (Claude Code's Bash `description`), which its line reads.
    var description: String? = nil
    /// The provider's task for the command (Claude Code's `local_bash`), which its line stops while
    /// it runs, as the subagent card stops a task. Nil when the provider tracks none.
    var task: ConversationCommandTask? = nil
}

/// A provider task that runs a command: the activity that started it and the provider's reference
/// to the task, which stopping it names.
struct ConversationCommandTask: Equatable, Sendable {
    var activityID: String
    var reference: HarnessSubtaskReference
}

struct ConversationFileChange: Equatable, Sendable {
    /// One row per file, as the Codex file change card lists a patch.
    var rows: [CodexFileChangeCardProjection.Row]
    /// The files the change names, verified to lie inside the task's folder, for opening them.
    var handoffs: [CodexChangeHandoff]
    /// Why a harness's edit did not apply, in the provider's words.
    var errorMessage: String? = nil
    /// An allowed request for the edit, folded into the card.
    var isApproved: Bool = false
    /// The rows name their files as the provider did: a shared transcript does not know the task's
    /// folder, so the card reads them against it (`CodexFileChangeCardProjection.Row.placed(in:)`).
    var placesRowsInWorkspace: Bool = false
}

struct ConversationTool: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A shared-transcript activity, by the provider's own kind.
        case activity(String)
        case mcp
        case dynamic
        case webSearch
        case imageView
        case imageGeneration
        case sleep
        case review
        case hook
        case unknown(type: String?)
    }

    var kind: Kind
    /// What the call is about: the tool's name, a search query or a path.
    var name: String
    /// The provider's own status word, when it sent one.
    var status: String? = nil
    var input: String? = nil
    var output: String? = nil
    var diff: HarnessActivityDiff? = nil
    var errorMessage: String? = nil
    /// The provider keeps the call running after the turn.
    var isBackground: Bool = false
    /// An allowed request for this call, folded into the card.
    var isApproved: Bool = false
    /// The provider's one text for a call it sent no separate input and output for (an activity
    /// from an adapter that predates them).
    var detail: String? = nil
    /// An MCP call's result: its text and images.
    var mcpResult: CodexMCPResultProjection? = nil
    /// The images the call looked at, made or returned, apart from an MCP result's: a Codex image
    /// view's file, a generated image, a Claude Code result's screenshot. The line previews them.
    var images: [TranscriptImageAttachment] = []
    /// The Yardlet connector whose tool this is, for its name and icon on the row.
    var connector: ConnectorToolLabels.Label? = nil
}

struct ConversationSubagent: Equatable, Sendable {
    /// The tool or activity that started or reported the subagent.
    var title: String
    var status: String?
    /// What the card shows beside the title: the threads it reached, or the agent's path.
    var detail: String?
    var routes: [ConversationSubagentRoute]
    /// An allowed request for the call that started it, folded into the card.
    var isApproved: Bool = false
    /// The provider's own name for the call (Claude's Agent or Task); nil where the card names it.
    var kind: String? = nil
    /// The task the subagent was given.
    var input: String? = nil
    /// What the subagent reported back.
    var output: String? = nil
    /// The provider keeps the subagent running after the turn.
    var isBackground: Bool = false
    /// The model the provider reported the subagent runs on; nil until it does, or for a Codex
    /// child thread that runs on its parent thread's model (`HarnessModelNames`).
    var model: String? = nil
    /// The harness and model in full ("Codex · gpt-5.5") for a subagent that may run on another
    /// harness than its task (`run_agent`); nil names the task's harness with `model`.
    var harnessLabel: String? = nil

    /// A subagent's name as both its card and the rail's Agents card show it: the first line of
    /// what it was asked, as Claude Code names a subagent by its description and the Codex app by
    /// its own name, cut to a line's length.
    static func name(asked prompt: String?) -> String? {
        guard let line = prompt?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { return nil }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }
}

/// Where opening a subagent goes; each provider keeps its own way.
enum ConversationSubagentRoute: Equatable, Sendable {
    /// The child thread, opened as its own Yardlet task.
    case codexThread(String)
    /// The provider's subtask, read in the panel beside the task.
    case harnessSubtask(HarnessSubtaskReference, activityID: String)
    /// A subagent Yardlet's `run_agent` ran on a harness (`AgentRun`): by the agent ID its answer
    /// named, else by its prompt while the call still runs.
    case yardletAgent(agentID: String?, prompt: String)
}

// MARK: - Requests

struct ConversationRequest: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var detail: String? = nil
    /// The command the request would run, as the provider sent it.
    var command: String? = nil
    var preview: PermissionRequestPreview? = nil
    var form: ConversationRequestForm? = nil
    var state: ConversationRequestState
    /// The answers the card offers while the request waits, in the order the card draws them,
    /// for a host that can carry every route (`offeredResponses(canChooseOption:canAnswer:)`).
    var responses: [ConversationRequestResponse] = []
    var toolCallID: String? = nil
    /// The provider's own approval options, which a host that cannot return a form's answer
    /// offers instead (the shared transcript's `PermissionRequest.actions`).
    var providerActions: [PermissionRequestAction] = []
    /// Why a waiting request offers no answer: a kind Yardlet does not answer, in the card's
    /// own words. The request fails closed: nothing is sent for it.
    var unanswerableReason: String? = nil
    /// The provider's method for the request (Codex), which the card names on hover.
    var method: String? = nil
    /// What each question of the form was answered with, as the provider recorded it (Claude's
    /// `AskUserQuestion` result, Codex's response), by `ConversationQuestionStep.id`; a question
    /// left out was not answered. Nil when the provider's record is not known here.
    var recordedAnswers: [String: ConversationQuestionAnswer]? = nil
    var source: ConversationRequestSource

    /// It asks the person questions rather than for an approval (a plan review is an approval).
    var asksForAnswer: Bool {
        switch form {
        case .choices, .freeText, .mcpForm: true
        case .planReview, nil: false
        }
    }

    /// A question form the person answered: its card reads as the answers.
    var isAnsweredQuestion: Bool {
        switch form {
        case .choices, .freeText: state == .answered || state == .allowed
        case .planReview, .mcpForm, nil: false
        }
    }

    /// The decision context a Codex request carries: its messages and fields.
    var codexContext: CodexRequestContextProjection? {
        switch source {
        case let .codexApproval(approval): CodexRequestContextProjection(params: approval.raw)
        case let .codexServerRequest(request): CodexRequestContextProjection(params: request.params)
        case .transcript: nil
        }
    }
}

enum ConversationRequestState: Equatable, Sendable {
    case pending
    case allowed
    case denied
    /// Answered in a way the card does not name as allowed or denied.
    case answered
    /// The provider stopped waiting for an answer.
    case expired(message: String?)
    case rejected(message: String)
}

enum ConversationRequestForm: Equatable, Sendable {
    /// Questions with the provider's own choices.
    case choices([PermissionQuestion])
    /// A plan submitted for review.
    case planReview(String)
    /// Questions each answered under the provider's ID for it, with one of its options or in the
    /// person's own words (Codex `item/tool/requestUserInput`).
    case freeText([ConversationRequestQuestion])
    /// An MCP elicitation's form, filled in field by field (Codex `mcpServer/elicitation/request`).
    case mcpForm(CodexMCPElicitationForm)
}

/// A question a request asks in its provider's words, answered under the provider's ID for it:
/// with one of its options, or with free text where it has none or takes an answer besides them.
struct ConversationRequestQuestion: Identifiable, Equatable, Sendable {
    let id: String
    /// The provider's question; nil when it sent none.
    var text: String?
    /// The provider's short label for the question.
    var header: String? = nil
    var options: [PermissionQuestionOption] = []
    /// The question takes the person's own words besides its options (Codex `isOther`); one
    /// without options is answered only that way.
    var allowsCustomAnswer: Bool = true
    /// The answer is a secret the field hides (Codex `isSecret`).
    var isSecret: Bool = false
}

/// What one question was answered with: the options picked, in the provider's order, and the
/// person's own words.
struct ConversationQuestionAnswer: Equatable, Sendable {
    var options: [String] = []
    var custom: String? = nil

    var values: [String] { options + (custom.map { [$0] } ?? []) }
}

/// The questions a Codex turn ended on (`request_user_input_async`) once the person answered them,
/// with what the reply recorded by each question's `itemID`; a question left out was not answered.
struct ConversationAnsweredAsyncQuestions: Equatable, Sendable {
    let questions: [CodexAsyncQuestion]
    let answers: [String: ConversationQuestionAnswer]
}

struct ConversationRequestResponse: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case primary
        case secondary
        case destructive
    }

    var title: String
    var role: Role
    var route: ConversationRequestRoute
}

/// How an answer reaches the provider.
enum ConversationRequestRoute: Equatable, Sendable {
    /// `AppModel.respond(to:decision:)`
    case decision(PermissionDecision)
    /// `AppModel.respond(to:action:)`
    case providerAction(PermissionRequestAction)
    /// What the card's form collects, which becomes one of the other routes when it is sent
    /// (`ConversationRequest.route(for:input:)`): an `answer`, a plain deny, or a Codex answer.
    case structured
    /// The answer a question form or plan review collected, `AppModel.respond(to:answer:)`.
    case answer(PermissionStructuredAnswer)
    /// `AppModel.respondCodex(to:response:)`
    case codex(CodexServerRequestResponse)
}

/// The record a request was projected from, which today's cards draw until the cards converge.
enum ConversationRequestSource: Equatable, Sendable {
    case codexApproval(CodexApprovalState)
    case codexServerRequest(CodexServerRequestState)
    case transcript(TranscriptEntry)
}

extension ConversationItem {
    /// The words a sent bubble shows: what the person sent, or what a scheduled task asked for.
    var sentText: String? {
        switch kind {
        case let .userMessage(text, _): text
        case let .scheduledTaskMessage(message): message.instructions
        default: nil
        }
    }

    /// A provider's answer, working note or proposed plan with words in it: a running turn reads
    /// "Thinking" until it has one.
    var isVisibleAgentOutput: Bool {
        switch kind {
        case let .answer(text, _), let .commentary(text, _), let .proposedPlan(text, _):
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            false
        }
    }
}

// MARK: - Record order

/// A part of a turn, named by the record it came from, for drawing a turn in its record's order.
enum ConversationTurnPart: Identifiable, Equatable, Sendable {
    case item(ConversationItem)
    case request(ConversationRequest)
    case plan(ConversationPlan)
    case outcome(ConversationTurnOutcome)

    /// The record's ID for the part: a transcript entry's UUID, or a Codex item's or request's ID.
    var id: String {
        switch self {
        case let .item(item): item.id
        case let .request(request): request.recordID
        case let .plan(plan): plan.recordID ?? "plan"
        case let .outcome(outcome): outcome.recordID ?? "outcome"
        }
    }
}

extension ConversationTurn {
    /// The turn's parts in `recordOrder`. The order names every part a transcript turn draws; a
    /// turn without one (Codex) has no parts in record order.
    var partsInRecordOrder: [ConversationTurnPart] {
        guard !recordOrder.isEmpty else { return [] }
        var parts: [String: ConversationTurnPart] = [:]
        for item in prompt + notices + work + answers { parts[item.id] = .item(item) }
        for request in requests { parts[request.recordID] = .request(request) }
        if let plan, let id = plan.recordID { parts[id] = .plan(plan) }
        if let outcome, let id = outcome.recordID { parts[id] = .outcome(outcome) }
        return recordOrder.compactMap { parts[$0] }
    }
}

extension ConversationRequest {
    /// The transcript entry the request came from, or the provider's request ID.
    var recordID: String {
        if case let .transcript(entry) = source { return entry.id.uuidString }
        return id
    }
}

extension ConversationPlan {
    /// The transcript entry the plan came from; nil for a Codex plan.
    var recordID: String? {
        if case let .transcript(entry)? = source { return entry.id.uuidString }
        return nil
    }
}

extension ConversationTurnOutcome {
    /// The transcript entry the outcome came from; nil for a Codex turn error.
    var recordID: String? {
        switch self {
        case let .error(error): error.entryID?.uuidString
        case let .usageLimit(_, entryID): entryID.uuidString
        }
    }
}
