import Foundation

struct HarnessSessionHandle: Codable, Equatable, Sendable {
    let harness: HarnessKind
    let localSessionID: UUID
    let providerSessionID: String
    let workspaceURL: URL
}

struct CreateHarnessSessionRequest: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let workspaceURL: URL
    let initialPrompt: String?
}

struct PermissionRequestAction: Codable, Equatable, Sendable {
    let id: String
    let label: String
    let decision: PermissionDecision
    let kind: String?
}

/// One choice the provider listed for a question it asked. Yardlet renders these and never
/// adds an option of its own.
struct PermissionQuestionOption: Codable, Equatable, Sendable {
    let label: String
    let description: String?

    init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

/// A question the provider sent with its request, exactly as it wrote it. The answer Yardlet
/// returns is the option labels the user picked, keyed by this same question text.
struct PermissionQuestion: Codable, Equatable, Sendable {
    let question: String
    /// The provider's own short chip label for the question, when it sent one.
    let header: String?
    let options: [PermissionQuestionOption]
    let allowsMultipleSelections: Bool
    /// The provider takes an answer in the person's own words besides its options (Claude Code's
    /// "Other"). A multiple-selection question takes it with the options picked.
    let allowsCustomAnswer: Bool
    /// The provider rejects an answer that leaves this question out (Muse), so it cannot be skipped.
    let requiresAnswer: Bool

    init(
        question: String,
        header: String? = nil,
        options: [PermissionQuestionOption],
        allowsMultipleSelections: Bool = false,
        allowsCustomAnswer: Bool = false,
        requiresAnswer: Bool = false
    ) {
        self.question = question
        self.header = header
        self.options = options
        self.allowsMultipleSelections = allowsMultipleSelections
        self.allowsCustomAnswer = allowsCustomAnswer
        self.requiresAnswer = requiresAnswer
    }

    /// A question saved before the last two fields existed takes neither.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decode(String.self, forKey: .question)
        header = try container.decodeIfPresent(String.self, forKey: .header)
        options = try container.decode([PermissionQuestionOption].self, forKey: .options)
        allowsMultipleSelections = try container.decode(Bool.self, forKey: .allowsMultipleSelections)
        allowsCustomAnswer = try container.decodeIfPresent(Bool.self, forKey: .allowsCustomAnswer) ?? false
        requiresAnswer = try container.decodeIfPresent(Bool.self, forKey: .requiresAnswer) ?? false
    }
}

/// Answerable content the provider attached to an approval request. An ordinary tool call
/// carries none and stays a plain allow or deny.
enum PermissionRequestStructure: Codable, Equatable, Sendable {
    /// Questions the provider asked, to be answered rather than merely approved.
    case questions([PermissionQuestion])
    /// A plan the provider submitted for approval, in its own markdown.
    case plan(String)
}

/// The option labels the user picked for one question, keyed by the provider's own question text,
/// and the answer they wrote in their own words where the question takes one.
struct PermissionQuestionAnswer: Codable, Equatable, Sendable {
    let question: String
    let selectedLabels: [String]
    var customAnswer: String? = nil

    init(question: String, selectedLabels: [String], customAnswer: String? = nil) {
        self.question = question
        self.selectedLabels = selectedLabels
        self.customAnswer = customAnswer
    }

    /// What the question was answered with, in the order the provider reads it: the options in
    /// their order, then the person's own words.
    var values: [String] { selectedLabels + (customAnswer.map { [$0] } ?? []) }
}

/// The questions a tool call asked and the answers its provider recorded for them, read from the
/// call's own result (Claude Code's `AskUserQuestion`), so the answered card reads the same live
/// and when the conversation is read back.
struct HarnessAnsweredQuestions: Codable, Equatable, Sendable {
    let questions: [PermissionQuestion]
    /// One entry per question answered, in the questions' order; a question left out was not.
    let answers: [PermissionQuestionAnswer]
}

/// An answer that carries more than allow or deny, for the requests whose provider asked for one.
enum PermissionStructuredAnswer: Equatable, Sendable {
    /// One entry per question the user answered; questions left alone are omitted.
    case questions([PermissionQuestionAnswer])
    /// A denial carrying the reason the user wrote in the provider's own deny option.
    case denial(reason: String)

    var decision: PermissionDecision {
        switch self {
        case .questions: .allow
        case .denial: .deny
        }
    }
}

struct PermissionRequest: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String?
    let command: String?
    let actions: [PermissionRequestAction]
    /// Provider-sent content the user answers instead of approving. Absent for every request
    /// whose provider offered only allow and deny.
    let structured: PermissionRequestStructure?
    /// The provider's id for the tool call this request asks about, the id of that call's
    /// activity card.
    let toolCallID: String?
    /// The change the tool call would make, when its input names one.
    let preview: PermissionRequestPreview?
    /// The provider holds the request for the person to answer on its card: a question or plan
    /// whose content the adapter could not read, or a call a safety check keeps for manual
    /// approval. A notification never answers it (`NotificationApprovalProjection`).
    let requiresInAppAnswer: Bool

    init(
        id: String,
        title: String,
        detail: String?,
        command: String?,
        actions: [PermissionRequestAction] = [],
        structured: PermissionRequestStructure? = nil,
        toolCallID: String? = nil,
        preview: PermissionRequestPreview? = nil,
        requiresInAppAnswer: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.command = command
        self.actions = actions
        self.structured = structured
        self.toolCallID = toolCallID
        self.preview = preview
        self.requiresInAppAnswer = requiresInAppAnswer
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case detail
        case command
        case actions
        case structured
        case toolCallID
        case preview
        case requiresInAppAnswer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        actions = try container.decodeIfPresent(
            [PermissionRequestAction].self,
            forKey: .actions
        ) ?? []
        // Saved transcripts written before answerable cards existed carry no key here.
        structured = try container.decodeIfPresent(
            PermissionRequestStructure.self,
            forKey: .structured
        )
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        // A preview is a convenience; one this build cannot read must not lose the transcript.
        preview = try? container.decodeIfPresent(PermissionRequestPreview.self, forKey: .preview)
        requiresInAppAnswer = try container.decodeIfPresent(Bool.self, forKey: .requiresInAppAnswer) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encode(actions, forKey: .actions)
        try container.encodeIfPresent(structured, forKey: .structured)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(preview, forKey: .preview)
        // Left out unless set, so saved transcripts keep the shape older builds read.
        if requiresInAppAnswer { try container.encode(true, forKey: .requiresInAppAnswer) }
    }
}

enum PermissionDecision: String, Codable, Equatable, Sendable {
    case allow
    case deny
}

enum HarnessActivityOutcome: String, Codable, Sendable {
    case failed
    case stopped
}

/// A provider-reported file change attached to a tool call. Yardlet renders what the provider
/// sent and never reconstructs a diff the provider did not supply.
struct HarnessActivityDiff: Codable, Equatable, Sendable {
    let path: String
    let oldText: String?
    let newText: String?
    let unified: String?

    init(
        path: String,
        oldText: String? = nil,
        newText: String? = nil,
        unified: String? = nil
    ) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
        self.unified = unified
    }
}

struct HarnessActivity: Codable, Equatable, Sendable {
    let id: String
    let kind: String
    let title: String
    /// Legacy single-slot text. Kept so saved transcript caches keep decoding and so adapters
    /// that were never migrated still render. New work belongs in `input`/`output`/`diff`.
    let detail: String?
    var outcome: HarnessActivityOutcome? = nil
    /// The command or arguments the provider sent with the call.
    var input: String? = nil
    /// The provider's tool result text.
    var output: String? = nil
    var diff: HarnessActivityDiff? = nil
    /// The provider explicitly kept this activity running after the foreground turn. Optional
    /// so older transcript caches still decode; only `true` survives a turn's completion.
    var isBackground: Bool? = nil
    var subtask: HarnessSubtaskReference? = nil
    /// The questions the call asked and the answers its result recorded, for a call that asks the
    /// person (Claude Code's `AskUserQuestion`). Optional so older transcript caches still decode.
    var answeredQuestions: HarnessAnsweredQuestions? = nil
    /// The images the provider's result carried (an image file the call read, a screenshot), which
    /// the call's line previews. Inline bytes stay out of the reading cache, as a sent image's do
    /// (`TranscriptImageAttachment`), and come back when the history is read again.
    var images: [TranscriptImageAttachment]? = nil

    init(
        id: String,
        kind: String,
        title: String,
        detail: String? = nil,
        outcome: HarnessActivityOutcome? = nil,
        input: String? = nil,
        output: String? = nil,
        diff: HarnessActivityDiff? = nil,
        isBackground: Bool? = nil,
        subtask: HarnessSubtaskReference? = nil,
        answeredQuestions: HarnessAnsweredQuestions? = nil,
        images: [TranscriptImageAttachment]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.outcome = outcome
        self.input = input
        self.output = output
        self.diff = diff
        self.isBackground = isBackground
        self.subtask = subtask
        self.answeredQuestions = answeredQuestions
        self.images = images
    }

    /// True when the card has nothing but the legacy slot to show.
    var hasSeparatedContent: Bool {
        input != nil || output != nil || diff != nil
    }
}

enum HarnessEventPayload: Codable, Equatable, Sendable {
    case sessionStarted(HarnessSessionHandle)
    case assistantDelta(String)
    case assistantMessageCompleted(String)
    case reasoningDelta(String)
    case reasoningCompleted(String)
    /// A thinking block that is what the model wrote between tool calls, not its reasoning
    /// (`TranscriptEntry.isProgressUpdate`). It streamed as reasoning, and completes it.
    case progressUpdateCompleted(String)
    case activityStarted(HarnessActivity)
    case activityUpdated(HarnessActivity)
    case activityCompleted(HarnessActivity)
    case permissionRequested(PermissionRequest)
    case permissionExpired(String)
    case planUpdated(String)
    case usageUpdated(HarnessProtocolUsage)
    case turnCompleted
    case sessionStatusChanged(SessionStatus)
    /// `transient` is true when the provider's own error says the same request can succeed later (a
    /// busy server, a rate limit, a lost connection), so the turn's card offers to retry it; nil when
    /// the error says no such thing, which keeps the saved shape of older entries.
    case error(message: String, recoverable: Bool, transient: Bool? = nil)
    /// The provider changed one of its session settings on its own, so the capability state the
    /// adapter reports is worth reading again. It carries no state; the adapter remains the one
    /// place that state is read from.
    case providerCapabilitiesChanged
    /// The provider reported its plan limits. Allowances and warnings are carried too, so the
    /// account's usage follows the session without waiting for a separate check.
    case rateLimitUpdated(HarnessRateLimit)
    /// A plan limit stopped the turn. It takes the place of a generic turn failure.
    case usageLimitReached(HarnessRateLimit)
    /// The provider is retrying a request it could not complete yet; the turn is still running.
    case providerRetrying(HarnessProviderRetry)
    /// The provider ended the turn on its own connection error (`TurnCut.connection` or `.sleep`),
    /// read from that error, not guessed: the turn continues once the network is back
    /// (`ConnectionResumePolicy`). It comes before the turn's end.
    case turnCutOff(TurnCut)
    case contextCompaction(HarnessContextCompaction)
    /// A follow-up the provider held was read or let go. A read one joins the conversation here.
    case followUpDelivery(HarnessFollowUpDelivery)
    /// The provider started a turn of its own with a command it queued itself, saved under
    /// `messageID`: Claude Code's schedule firing a prompt, another session's message. A command it
    /// queued under no uuid, a background task's notice, has none, and its saved request is the
    /// newest one. The stream carries no request for it; the conversation opens the turn here and
    /// reads its request from the provider's saved record.
    case providerStartedTurn(messageID: String?)
    /// What the provider predicts the person will send next, after a turn ended (Claude Code's
    /// `prompt_suggestion`). Shown above the composer only; it never joins the conversation or
    /// the agent's context unless the person takes it into the composer and sends it.
    case nextMessageSuggestion(String)
}

struct HarnessEventEnvelope: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let localSessionID: UUID
    let timestamp: Date
    let sequence: UInt64
    let payload: HarnessEventPayload
    let rawProviderEvent: Data?

    init(
        id: UUID = UUID(),
        localSessionID: UUID,
        timestamp: Date = Date(),
        sequence: UInt64,
        payload: HarnessEventPayload,
        rawProviderEvent: Data? = nil
    ) {
        self.id = id
        self.localSessionID = localSessionID
        self.timestamp = timestamp
        self.sequence = sequence
        self.payload = payload
        self.rawProviderEvent = rawProviderEvent
    }
}
