import Foundation

// The wire contract of the phone remote (docs/REMOTE_PROTOCOL.md): JSON inside a Noise channel (§11–§13).
// Client requests are `{id, type, ...}`, responses `{re, ok, error?, ...}`, events `{event, seq, ...}`.
// Everything here is plain data, so it encodes and decodes without a connection.

public enum RemoteProtocol {
    /// The largest message a phone may send before it is a device (a link request waiting); a larger one
    /// closes the connection (1009).
    public static let maxClientFrameBytes = 65_536
    /// The longest message `sendMessage` takes, in characters.
    public static let maxMessageCharacters = 32_000
    /// The QR code's URL scheme.
    public static let pairingScheme = "yardlet-remote"
    /// The protocol: messages inside a Noise channel, over any path (§11). Protocol 1 has been removed.
    public static let secureVersion = 2
    /// The port the Mac's v2 listener tries first, on every interface.
    public static let securePort: UInt16 = 47616
    /// The Bonjour service a v2 listener advertises (§11.3).
    public static let bonjourType = "_yardlet._tcp"
    /// The largest message the Mac sends a phone over v2, before chunking (§13.2).
    public static let maxServerMessageBytes = 8 * 1024 * 1024
    /// Answers an approval item may offer beside `RemoteApprovalAnswer`'s, to v2 phones only (§15.2).
    public static let answerOption = "answer"
    public static let approvePlanOption = "approvePlan"
    public static let keepPlanningOption = "keepPlanning"
    /// A question form with a secret answer, which only a phone that masks it is offered (§15.19).
    public static let answerSecretOption = "answerSecret"
    /// The longest own-words answer or plan feedback a phone sends.
    public static let maxAnswerCharacters = 4_000
    /// The largest message a phone sends over v2 once its chunks are joined (§13.2): room for images.
    public static let maxSecureClientMessageBytes = 8 * 1024 * 1024
    /// Images a message carries at most, and the largest one, decoded (§15.14).
    public static let maxImages = 4
    public static let maxImageBytes = 3 * 1024 * 1024
    /// Files a message carries at most, the largest one, and the largest part of one (§15.20).
    public static let maxFiles = 20
    public static let maxFileBytes = 500 * 1024 * 1024
    public static let maxUploadPartBytes = 4 * 1024 * 1024
    /// The most schedules `scheduledTasks` lists (§15.21).
    public static let maxSchedules = 200
    /// The most outputs `taskOutputs` lists, the largest file `readFile` serves and the most one part of it holds
    /// (§15.22).
    public static let maxOutputs = 50
    public static let maxReadFileBytes = 100 * 1024 * 1024
    public static let maxReadPartBytes = 4 * 1024 * 1024
    /// What one device's `readFile` answers may carry in all: up to 32 MiB at once, then 32 MiB per 10 s (§15.22).
    public static let readFileBudgetBytes = 32 * 1024 * 1024
    public static let readFileBudgetWindow: TimeInterval = 10
    /// What the Mac may have handed a connection's transport that its phone has not taken yet; past it the connection
    /// closes, so a phone that asks and never reads cannot fill the Mac's memory (§7).
    public static let maxUnsentBytes = 32 * 1024 * 1024
    /// The longest ID a request may carry: one of Yardlet's own (a task, project, schedule or account), and one a
    /// harness made (a request, an item, a suggestion, an answer's choice) (§7).
    public static let maxOwnIDBytes = 64
    public static let maxProviderIDBytes = 256
    /// Where a device's pushes go (§15.6): FCM, or APNs for an iOS build signed for production or for development.
    public static let pushProviders: Set<String> = ["fcm", "apns", "apns-sandbox"]
}

// MARK: - Errors

public enum RemoteErrorCode: String, Codable, Sendable, CaseIterable {
    case badRequest
    case unknownType
    case unsupportedVersion
    case unauthenticated
    case pairingUnavailable
    case pairingInvalid
    case notFound
    case notSubscribed
    case invalidCursor
    case tooManySubscriptions
    case requestNotFound
    case notAllowed
    case unavailable
    case notRunning
    case emptyMessage
    case tooLarge
    case unsupportedCommand
    case busy
    case rateLimited
    case `internal`
    /// v2 handshake: the phone's key is not paired, or the device was removed.
    case unknownDevice
    /// v2 handshake: a link request to a Mac that is not signed in to an account (§12.1).
    case linkUnavailable
}

public struct RemoteError: Error, Codable, Equatable, Sendable {
    public var code: RemoteErrorCode
    /// An English diagnostic for logs, not for the phone's UI.
    public var message: String

    public init(_ code: RemoteErrorCode, _ message: String = "") {
        self.code = code
        self.message = message.isEmpty ? code.rawValue : message
    }
}

/// WebSocket close codes the server uses (§8).
public enum RemoteCloseCode: UInt16, Sendable {
    case normal = 1000
    case unsupportedData = 1003
    case messageTooBig = 1009
    case unauthenticated = 4401
    case revoked = 4403
    case idle = 4408
    case macOffline = 4404
    case unsupportedVersion = 4426
    case replaced = 4409
    case rateLimited = 4429
    case unavailable = 4503
}

// MARK: - Tasks

/// A project the sidebar lists tasks under.
public struct RemoteProject: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case project
        case folder
        case chats
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// `createTask` may start a task here (v2, §15.1).
    public var canCreateTask: Bool?

    public init(id: String, name: String, kind: Kind, canCreateTask: Bool? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.canCreateTask = canCreateTask
    }
}

/// What a task the phone starts runs on: the Mac's new-task composer as it is now (§15.1).
public struct RemoteNewTask: Codable, Equatable, Sendable {
    public var harness: String
    public var harnessName: String

    public init(harness: String, harnessName: String) {
        self.harness = harness
        self.harnessName = harnessName
    }
}

/// The sidebar's one attention state (`TaskAttentionProjection.state` on the Mac).
public enum RemoteAttention: String, Codable, Sendable {
    case waiting
    case unread
    case active
    case idle
}

/// The mark a sidebar row ends with (`SidebarTaskIndicatorProjection.status` on the Mac).
public enum RemoteIndicator: String, Codable, Sendable {
    case awaitingApproval
    case needsInput
    case failed
    case usageLimit
    case running
    case unread
}

public enum RemotePendingRequest: String, Codable, Sendable {
    case approval
    case input
}

public struct RemoteTask: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var harness: String
    public var harnessName: String
    public var projectId: String?
    public var attention: RemoteAttention
    public var indicator: RemoteIndicator?
    public var pendingRequest: RemotePendingRequest?
    public var unread: Bool
    public var running: Bool
    public var pinned: Bool
    public var lastActivityAt: Int64
    public var parentTaskId: String?
    /// While `waiting`: the newest request's one line (as the `attention` event's `summary`) and its
    /// kind (`approval`, `question`, `planReview`, `form`), so a list can say what waits (§15.1).
    public var pendingSummary: String?
    public var pendingKind: String?
    /// A message to the task can carry images (§15.14).
    public var acceptsImages: Bool?
    /// A message sent while its turn runs can go into that turn now (§15.15).
    public var steers: Bool?
    /// A message to the task can carry files (§15.20).
    public var acceptsFiles: Bool?

    public init(
        id: String, title: String, harness: String, harnessName: String, projectId: String?,
        attention: RemoteAttention, indicator: RemoteIndicator? = nil, pendingRequest: RemotePendingRequest? = nil,
        unread: Bool = false, running: Bool = false, pinned: Bool = false, lastActivityAt: Int64,
        parentTaskId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.harness = harness
        self.harnessName = harnessName
        self.projectId = projectId
        self.attention = attention
        self.indicator = indicator
        self.pendingRequest = pendingRequest
        self.unread = unread
        self.running = running
        self.pinned = pinned
        self.lastActivityAt = lastActivityAt
        self.parentTaskId = parentTaskId
    }
}

/// What `snapshot` answers, and what attention events are read from.
public struct RemoteSnapshot: Equatable, Sendable {
    public var projects: [RemoteProject]
    public var tasks: [RemoteTask]
    /// The newest request each waiting task waits on, so a second request in a waiting task is an
    /// attention event too. Not sent with the task.
    public var newestRequestIDs: [String: String]
    /// A one-line summary of that request for the attention event (`RemoteSummary.line`): what the
    /// call is or the question's first line, capped and with secrets masked. Not sent with the task.
    public var requestSummaries: [String: String]
    /// What `createTask` would start on, or nil when the Mac cannot start a task.
    public var newTask: RemoteNewTask?
    /// What Return does on the Mac while a turn runs (§15.15).
    public var followUp: RemoteFollowUpMode?
    /// The bridge answers `scheduledTasks` (§15.21).
    public var scheduledTasks: Bool
    /// The bridge answers `taskOutputs` and `readFile` (§15.22).
    public var taskFiles: Bool
    /// The bridge answers a task's settings, slash commands, edit and fork (§15.23).
    public var taskControls: Bool
    /// The bridge answers `subscribeTask` with `"detail": "full"` (§15.24).
    public var fullConversation: Bool

    public init(projects: [RemoteProject] = [], tasks: [RemoteTask] = [], newestRequestIDs: [String: String] = [:],
                requestSummaries: [String: String] = [:], newTask: RemoteNewTask? = nil,
                followUp: RemoteFollowUpMode? = nil, scheduledTasks: Bool = false, taskFiles: Bool = false,
                taskControls: Bool = false, fullConversation: Bool = false) {
        self.projects = projects
        self.tasks = tasks
        self.newestRequestIDs = newestRequestIDs
        self.requestSummaries = requestSummaries
        self.newTask = newTask
        self.followUp = followUp
        self.scheduledTasks = scheduledTasks
        self.taskFiles = taskFiles
        self.taskControls = taskControls
        self.fullConversation = fullConversation
    }

    public static let empty = RemoteSnapshot()
}

// MARK: - Conversation items

/// One question of a pending question request, as the phone answers it (§15.2).
public struct RemoteQuestionStep: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public var label: String
        public var description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public var id: String
    public var header: String?
    public var text: String?
    public var options: [Option]
    public var multiple: Bool
    public var custom: Bool
    public var skippable: Bool
    /// The answer is a secret: mask it and never keep it (§15.19).
    public var secret: Bool?

    public init(id: String, header: String? = nil, text: String? = nil, options: [Option], multiple: Bool = false,
                custom: Bool = false, skippable: Bool = false, secret: Bool? = nil) {
        self.id = id
        self.header = header
        self.text = text
        self.options = options
        self.multiple = multiple
        self.custom = custom
        self.skippable = skippable
        self.secret = secret
    }
}

/// A phone's answer to one question step (§15.3).
public struct RemoteQuestionAnswer: Codable, Equatable, Sendable {
    public var questionId: String
    public var options: [String]?
    public var text: String?
    public var skipped: Bool?

    public init(questionId: String, options: [String]? = nil, text: String? = nil, skipped: Bool? = nil) {
        self.questionId = questionId
        self.options = options
        self.text = text
        self.skipped = skipped
    }
}

public enum RemotePlanDecision: String, Codable, Sendable {
    case approve
    case keepPlanning
}

public struct RemotePlanStep: Codable, Equatable, Sendable {
    public var text: String
    public var status: String

    public init(text: String, status: String) {
        self.text = text
        self.status = status
    }
}

/// One item of a conversation as the phone draws it (§6). One shape for every kind; each kind fills
/// the fields its section of the protocol names and leaves the rest nil, which is not encoded.
public struct RemoteItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case turn
        case user
        case assistant
        case activity
        case approval
        case plan
        case error
        case notice
    }

    public var id: String
    public var turnId: String
    public var kind: Kind
    public var inWork: Bool?

    // turn
    public var status: String?
    public var startedAt: Int64?
    public var completedAt: Int64?
    public var durationMs: Int64?
    public var approximate: Bool?
    public var foldsWork: Bool?
    public var workCount: Int?
    public var progress: String?
    public var progressText: String?

    // text
    public var text: String?
    public var truncated: Bool?
    public var imageCount: Int?
    public var scheduled: Bool?
    public var shell: Bool?
    public var diffCommentCount: Int?
    /// A message waiting in the task's follow-up queue, not yet taken by the provider.
    public var queued: Bool?
    /// Sending the queued message failed; it waits on the Mac.
    public var queueFailed: Bool?
    public var role: String?
    public var streaming: Bool?

    // activity
    public var activity: String?
    public var title: String?
    public var detail: String?
    public var exitCode: Int64?
    public var additions: Int?
    public var deletions: Int?
    public var approved: Bool?
    /// `itemDetail` has more for this line: output or diffs (v2, §15.8).
    public var hasDetail: Bool?
    /// The line's words, one entry per line the Mac draws (§6.4); `title` is them joined.
    public var words: [RemoteLineWords]?
    // suggested task (v2, §15.9)
    public var suggestionId: String?
    public var suggestionState: String?
    public var startedTaskId: String?

    // approval
    public var requestId: String?
    public var requestKind: String?
    public var command: String?
    public var questions: [String]?
    /// A pending question's steps, which a v2 phone answers (§15.2).
    public var questionSteps: [RemoteQuestionStep]?
    public var options: [String]?
    public var moreOnMac: Bool?
    /// The Mac card's words for options whose meaning is the provider's (`allowForSession`, §15.13).
    public var optionTitles: [String: String]?
    /// What only the Mac's card does, in one line, beside `moreOnMac` (§15.13).
    public var macNote: String?
    /// A plan limit's automatic continue is armed (§15.17).
    public var autoContinue: Bool?
    /// Every answer the Mac's card gives, in its order (§15.19).
    public var choices: [RemoteChoice]?
    /// An MCP form's fields (§15.19).
    public var formFields: [RemoteFormField]?

    // plan
    public var explanation: String?
    public var steps: [RemotePlanStep]?

    // error
    public var errorKind: String?
    /// An error's message, or the words a request's card shows above its form or answers (§6.5).
    public var message: String?
    public var recoverable: Bool?
    public var resetsAt: Int64?

    // A subscription's full detail only (§15.24): what the Mac's own cards draw beyond the phone's line.
    /// A sent message's images, as small previews.
    public var images: [RemoteImagePreview]?
    /// Who sent a `user` item that is not the person's.
    public var sender: RemoteSender?
    /// A subagent's card.
    public var subagent: RemoteSubagent?
    /// A context compaction's marker.
    public var compaction: RemoteCompaction?
    /// A provider's notice row.
    public var providerNotice: RemoteProviderNotice?
    /// A schedule an agent created, as its row.
    public var schedule: RemoteScheduleCreation?
    /// A plan limit's card.
    public var limit: RemoteLimit?

    public init(id: String, turnId: String, kind: Kind) {
        self.id = id
        self.turnId = turnId
        self.kind = kind
    }
}

/// Text cut to what the protocol allows for a field.
public enum RemoteText {
    /// The text and whether it was cut. Cuts at a character boundary.
    public static func capped(_ text: String, _ limit: Int) -> (text: String, truncated: Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }

    /// Optional text cut to the limit, nil when empty.
    public static func short(_ text: String?, _ limit: Int) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return capped(text, limit).text
    }

    public static let userLimit = 16_000
    public static let assistantLimit = 32_000
    public static let titleLimit = 300
    public static let detailLimit = 500
    public static let requestDetailLimit = 1_000
    public static let commandLimit = 2_000
    public static let planTextLimit = 8_000
    public static let questionLimit = 500
    public static let errorLimit = 2_000
    public static let stepLimit = 500
    public static let stepCount = 50
    /// What a subscription's full detail allows a message's, an answer's, a request's or an error's text (§15.24).
    public static let fullTextLimit = 200_000
    /// A subagent's input and output in full detail, as a line's output (§15.8).
    public static let fullSubagentLimit = 64_000
}

/// How much of a conversation a subscription asks for (§4.2): the phone's projection, or what the Mac's own
/// timeline draws (`"full"`, §15.24).
public enum RemoteConversationDetail: String, Codable, Sendable {
    case basic
    case full
}

/// A sent image as a small preview (§15.24): JPEG bytes and the name it was sent under.
public struct RemoteImagePreview: Codable, Equatable, Sendable {
    public var type: String
    public var data: Data
    public var name: String?

    public init(type: String = "image/jpeg", data: Data, name: String? = nil) {
        self.type = type
        self.data = data
        self.name = name
    }
}

/// Who sent a `user` item other than the person (§15.24); its words are the item's `text`.
public struct RemoteSender: Codable, Equatable, Sendable {
    /// One of the person's own messages the sending task passed on, and when the person sent it (ISO 8601).
    public struct Quote: Codable, Equatable, Sendable {
        public var text: String
        public var sentAt: String?

        public init(text: String, sentAt: String? = nil) {
            self.text = text
            self.sentAt = sentAt
        }
    }

    /// `task` (another task's message), `backgroundTask` (a background command's or agent's notice that opened the
    /// turn) or `claudeSchedule` (a prompt Claude Code's own schedule sent).
    public var kind: String
    /// The sending task's name, or a named schedule's.
    public var name: String?
    /// For `task`: `task`, `parent` (the task this one was started from) or `itself`.
    public var relation: String?
    /// For `backgroundTask`: its status.
    public var status: String?
    public var quotes: [Quote]?

    public init(kind: String, name: String? = nil, relation: String? = nil, status: String? = nil, quotes: [Quote]? = nil) {
        self.kind = kind
        self.name = name
        self.relation = relation
        self.status = status
        self.quotes = quotes
    }
}

/// A subagent as the Mac's card draws it (§15.24); its title and status are the item's.
public struct RemoteSubagent: Codable, Equatable, Sendable {
    /// The provider's own name for the call (`Agent`, `Task`, `spawn_agent`).
    public var kind: String?
    /// What the card shows beside its title: the threads it reached, or the agent's path.
    public var detail: String?
    public var input: String?
    public var output: String?
    public var model: String?
    /// The harness and model in full ("Codex · gpt-5.5") for a subagent on another harness than its task.
    public var harnessLabel: String?
    public var background: Bool?
    /// The listed tasks its child threads run in, which "Open child task" opens.
    public var taskIds: [String]?
    /// What the card's copy button takes.
    public var copyText: String?

    public init(kind: String? = nil, detail: String? = nil, input: String? = nil, output: String? = nil,
                model: String? = nil, harnessLabel: String? = nil, background: Bool? = nil, taskIds: [String]? = nil,
                copyText: String? = nil) {
        self.kind = kind
        self.detail = detail
        self.input = input
        self.output = output
        self.model = model
        self.harnessLabel = harnessLabel
        self.background = background
        self.taskIds = taskIds
        self.copyText = copyText
    }
}

/// The provider summarizing earlier conversation (§15.24).
public struct RemoteCompaction: Codable, Equatable, Sendable {
    /// `started`, `completed` or `failed`.
    public var phase: String
    public var tokensBefore: UInt64?
    public var tokensAfter: UInt64?
    /// Why it failed, in the provider's words.
    public var message: String?

    public init(phase: String, tokensBefore: UInt64? = nil, tokensAfter: UInt64? = nil, message: String? = nil) {
        self.phase = phase
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.message = message
    }
}

/// A provider's notice beside a turn (§15.24): a model reroute or a warning.
public struct RemoteProviderNotice: Codable, Equatable, Sendable {
    /// `modelRerouted`, `warning`, `configWarning` or `deprecationNotice`.
    public var kind: String
    /// The model the request went to, or the notice's text.
    public var message: String
    public var details: String?
    public var fromModel: String?
    public var reason: String?
    public var path: String?

    public init(kind: String, message: String, details: String? = nil, fromModel: String? = nil, reason: String? = nil,
                path: String? = nil) {
        self.kind = kind
        self.message = message
        self.details = details
        self.fromModel = fromModel
        self.reason = reason
        self.path = path
    }
}

/// A schedule an agent created (§15.24): the schedule's ID (§15.21) and the name the call gave.
public struct RemoteScheduleCreation: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A plan limit as the provider reported it (§15.24); when it resets is the item's `resetsAt`.
public struct RemoteLimit: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        /// `session`, `weekly`, `model` or `overage`.
        public var window: String
        public var model: String?
        /// The share of the window used; above 1 past the cap.
        public var usedFraction: Double
        public var resetsAt: Int64?

        public init(window: String, model: String? = nil, usedFraction: Double, resetsAt: Int64? = nil) {
            self.window = window
            self.model = model
            self.usedFraction = usedFraction
            self.resetsAt = resetsAt
        }
    }

    /// `allowed`, `warning` or `rejected`.
    public var status: String
    /// The window that limits the account now.
    public var window: String?
    public var model: String?
    public var usedFraction: Double?
    /// Paid extra usage covers the requests.
    public var overage: Bool?
    public var windows: [Window]?
    /// The provider's own words for the request it stopped.
    public var message: String?

    public init(status: String, window: String? = nil, model: String? = nil, usedFraction: Double? = nil,
                overage: Bool? = nil, windows: [Window]? = nil, message: String? = nil) {
        self.status = status
        self.window = window
        self.model = model
        self.usedFraction = usedFraction
        self.overage = overage
        self.windows = windows
        self.message = message
    }
}

/// A turn of a conversation as the bridge hands it to the server: its ID and its items in order.
public struct RemoteTurn: Equatable, Sendable {
    public var id: String
    public var items: [RemoteItem]

    public init(id: String, items: [RemoteItem]) {
        self.id = id
        self.items = items
    }
}

/// A task's conversation as loaded on the Mac.
public struct RemoteConversation: Equatable, Sendable {
    public var turns: [RemoteTurn]
    /// The provider holds turns before the loaded ones (a Codex cursor, a Claude file read from its end).
    public var hasEarlier: Bool

    public init(turns: [RemoteTurn], hasEarlier: Bool = false) {
        self.turns = turns
        self.hasEarlier = hasEarlier
    }
}

/// One change of a `conversation` event.
public struct RemoteChange: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable {
        case upsert
        case remove
    }

    public var op: Op
    /// `remove`: the item to drop.
    public var id: String?
    /// `upsert`: the item to insert after; nil inserts at the start.
    public var after: String?
    public var item: RemoteItem?

    public static func remove(_ id: String) -> RemoteChange { RemoteChange(op: .remove, id: id) }
    public static func upsert(_ item: RemoteItem, after: String?) -> RemoteChange {
        RemoteChange(op: .upsert, after: after, item: item)
    }
}

// MARK: - Requests

public enum RemoteApprovalAnswer: String, Codable, Sendable {
    case allowOnce
    case deny
    /// The narrowest allow that lasts for the task's session (§15.13).
    case allowForSession
}

/// Where a message sent while a turn runs goes (§15.15).
public enum RemoteFollowUpMode: String, Codable, Sendable {
    case steer
    case queue
}

/// The queue chip's actions on a queued message (§15.15).
public enum RemoteQueuedAction: String, Codable, Sendable, CaseIterable {
    case sendNow
    case stopAndSend
    case remove
}

/// The answers a browser handoff's bar gives (§15.18).
public enum RemoteHandoffAnswer: String, Codable, Sendable {
    case done
    case decline
}

/// An image a phone sends with a message (§15.14): the type it names and its bytes.
public struct RemoteImage: Equatable, Sendable {
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }

    /// The format the bytes are, read from their signature rather than the label: `png` or `jpeg`.
    public var format: String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        return nil
    }
}

/// One answer of a request as the Mac's card gives it (§15.19).
public struct RemoteChoice: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// `primary`, `secondary` or `destructive`.
    public var role: String
    /// It leaves a rule beyond this task; the phone asks once more.
    public var standing: Bool?
    /// The catalog key `title` was made from, for a client that shows it in its own language (§15.19).
    public var text: RemoteLocalizedText?

    public init(id: String, title: String, role: String, standing: Bool? = nil, text: RemoteLocalizedText? = nil) {
        self.id = id
        self.title = title
        self.role = role
        self.standing = standing
        self.text = text
    }
}

/// Words given as the Mac's catalog key and the arguments filled into it, each again a key or words as they
/// are (`text`), so a client with the same catalog shows them in its own language (§15.19).
public struct RemoteLocalizedText: Codable, Equatable, Sendable {
    public var key: String?
    /// Words as they are (a path, a host name), when there is no key.
    public var text: String?
    public var args: [RemoteLocalizedText]?

    public init(key: String? = nil, text: String? = nil, args: [RemoteLocalizedText]? = nil) {
        self.key = key
        self.text = text
        self.args = args
    }
}

/// One line's words as the Mac draws them (§6.4): what was done (`verb`, drawn muted) and what it was done
/// to, before and after it, in the order the Mac's language puts them.
public struct RemoteLineWords: Codable, Equatable, Sendable {
    public var leading: String?
    public var verb: String
    public var trailing: String?

    public init(leading: String? = nil, verb: String, trailing: String? = nil) {
        self.leading = leading
        self.verb = verb
        self.trailing = trailing
    }
}

/// An MCP form's field as the phone draws it (§15.19).
public struct RemoteFormField: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public var value: String
        public var title: String

        public init(value: String, title: String) {
            self.value = value
            self.title = title
        }
    }

    public var id: String
    public var label: String
    public var description: String?
    /// `text`, `number`, `integer`, `boolean`, `choice` or `choices`.
    public var type: String
    public var required: Bool?
    public var format: String?
    public var minLength: Int?
    public var maxLength: Int?
    public var minimum: Double?
    public var maximum: Double?
    public var minItems: Int?
    public var maxItems: Int?
    public var options: [Option]?
    public var `default`: RemoteFormValue?

    public init(id: String, label: String, type: String) {
        self.id = id
        self.label = label
        self.type = type
    }
}

/// A value a phone enters in an MCP form field (§15.19): words, a number, a switch, or the options picked.
public enum RemoteFormValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Double)
    case flag(Bool)
    case list([String])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .list(try container.decode([String].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(text): try container.encode(text)
        case let .number(number): try container.encode(number)
        case let .flag(flag): try container.encode(flag)
        case let .list(list): try container.encode(list)
        }
    }
}

/// One part of a file a phone sends (§15.20).
public struct RemoteUploadPart: Equatable, Sendable {
    public var uploadID: String
    /// The first part's: what the file is called, its type and its whole size.
    public var name: String?
    public var mediaType: String?
    public var size: Int?
    public var offset: Int
    public var data: Data

    public init(uploadID: String, name: String? = nil, mediaType: String? = nil, size: Int? = nil, offset: Int, data: Data) {
        self.uploadID = uploadID
        self.name = name
        self.mediaType = mediaType
        self.size = size
        self.offset = offset
        self.data = data
    }
}

/// A file a phone sent, as the Mac holds it for a message (§15.20).
public struct RemoteFile: Equatable, Sendable {
    public var url: URL
    public var name: String
    public var mediaType: String?

    public init(url: URL, name: String, mediaType: String? = nil) {
        self.url = url
        self.name = name
        self.mediaType = mediaType
    }
}

/// A task a phone starts (§15.5, §15.16): where, the first message, and what it runs on. Absent
/// choices are the Mac's new-task composer's own.
public struct RemoteTaskStart: Equatable, Sendable {
    public var projectID: String
    public var text: String
    public var harness: String?
    /// Setting IDs and values from `newTaskOptions`.
    public var settings: [String: String]
    public var worktree: Bool?
    public var images: [RemoteImage]
    /// The uploads it carries (§15.20), and once the server found them, the files.
    public var files: [String]
    public var attachedFiles: [RemoteFile] = []

    public init(projectID: String, text: String, harness: String? = nil, settings: [String: String] = [:],
                worktree: Bool? = nil, images: [RemoteImage] = [], files: [String] = []) {
        self.projectID = projectID
        self.text = text
        self.harness = harness
        self.settings = settings
        self.worktree = worktree
        self.images = images
        self.files = files
    }
}

public enum RemoteSuggestionAction: String, Codable, Sendable, CaseIterable {
    case start
    case here
    case dismiss
}

/// A request a client sends, after decoding.
public enum RemoteRequest: Equatable, Sendable {
    case snapshot
    /// `detail` `full` is v2's, to a Mac that announces it (§15.24).
    case subscribeTask(taskID: String, detail: RemoteConversationDetail = .basic)
    case loadOlder(taskID: String, cursor: String)
    case unsubscribeTask(taskID: String)
    case ping
    /// `images` and `followUp` are v2's (§15.14, §15.15).
    case sendMessage(taskID: String, text: String, images: [RemoteImage] = [], followUp: RemoteFollowUpMode? = nil,
                     files: [String] = [])
    /// `note` goes with a denial, and `allowForSession` is v2's (§15.13).
    case answerApproval(taskID: String, requestID: String, answer: RemoteApprovalAnswer, note: String? = nil)
    case stopTurn(taskID: String)
    case markRead(taskID: String)
    // v2 (§15)
    case answerQuestion(taskID: String, requestID: String, answers: [RemoteQuestionAnswer])
    case reviewPlan(taskID: String, requestID: String, decision: RemotePlanDecision, reason: String?)
    case createTask(RemoteTaskStart)
    /// `settings` already picked, so a menu that depends on another (an effort on its model) answers as it would
    /// after those picks (§15.16).
    case newTaskOptions(projectID: String?, harness: String?, settings: [String: String] = [:])
    case limitAccounts(taskID: String)
    case continueWithAccount(taskID: String, accountID: String)
    case setAutoContinue(taskID: String, enabled: Bool)
    case actOnQueued(taskID: String, itemID: String, action: RemoteQueuedAction)
    case answerHandoff(taskID: String, requestID: String, answer: RemoteHandoffAnswer)
    case chooseAnswer(taskID: String, requestID: String, choice: String, note: String? = nil,
                      values: [String: RemoteFormValue] = [:])
    case uploadFile(RemoteUploadPart)
    case registerPush(provider: String, token: String)
    case unregisterPush
    case forgetDevice
    case itemDetail(taskID: String, itemID: String)
    case actOnSuggestion(taskID: String, suggestionID: String, action: RemoteSuggestionAction)
    case setPinned(taskID: String, pinned: Bool)
    case archiveTask(taskID: String)
    case answerLink(requestID: String, approve: Bool)
    /// A link request's first message: the nonce message 1 committed to (§12.1).
    case revealLink(nonce: Data)
    /// The Mac's Scheduled tasks list, Run now, and Pause or Resume (§15.21).
    case scheduledTasks
    case runScheduledTask(scheduleID: String)
    case setScheduledTaskEnabled(scheduleID: String, enabled: Bool)
    /// What a task made, and a part of one of its files (§15.22).
    case taskOutputs(taskID: String)
    case readFile(taskID: String, path: String, offset: Int)
    /// A desktop in use, or no longer (§18): the Mac holds phone pushes meanwhile.
    case presence(active: Bool)
    /// A task's composer controls, its slash commands, and the edit and fork of its turns (§15.23). `prepare` reads
    /// the choices first, as opening the Mac's menu does.
    case taskSettings(taskID: String, prepare: Bool = false)
    case setTaskSetting(taskID: String, setting: String, value: String, confirmed: Bool = false)
    case composerCommands(taskID: String)
    case runComposerCommand(taskID: String, command: String, arguments: String? = nil)
    case editMessage(taskID: String, turnID: String, text: String)
    case forkTask(taskID: String, turnID: String?)

    public var type: String {
        switch self {
        case .snapshot: "snapshot"
        case .subscribeTask: "subscribeTask"
        case .loadOlder: "loadOlder"
        case .unsubscribeTask: "unsubscribeTask"
        case .ping: "ping"
        case .sendMessage: "sendMessage"
        case .answerApproval: "answerApproval"
        case .stopTurn: "stopTurn"
        case .markRead: "markRead"
        case .answerQuestion: "answerQuestion"
        case .reviewPlan: "reviewPlan"
        case .createTask: "createTask"
        case .newTaskOptions: "newTaskOptions"
        case .limitAccounts: "limitAccounts"
        case .continueWithAccount: "continueWithAccount"
        case .setAutoContinue: "setAutoContinue"
        case .actOnQueued: "actOnQueued"
        case .answerHandoff: "answerHandoff"
        case .chooseAnswer: "chooseAnswer"
        case .uploadFile: "uploadFile"
        case .registerPush: "registerPush"
        case .unregisterPush: "unregisterPush"
        case .forgetDevice: "forgetDevice"
        case .itemDetail: "itemDetail"
        case .actOnSuggestion: "actOnSuggestion"
        case .setPinned: "setPinned"
        case .archiveTask: "archiveTask"
        case .answerLink: "answerLink"
        case .revealLink: "revealLink"
        case .scheduledTasks: "scheduledTasks"
        case .runScheduledTask: "runScheduledTask"
        case .setScheduledTaskEnabled: "setScheduledTaskEnabled"
        case .taskOutputs: "taskOutputs"
        case .readFile: "readFile"
        case .presence: "presence"
        case .taskSettings: "taskSettings"
        case .setTaskSetting: "setTaskSetting"
        case .composerCommands: "composerCommands"
        case .runComposerCommand: "runComposerCommand"
        case .editMessage: "editMessage"
        case .forkTask: "forkTask"
        }
    }

    /// The task a request names.
    public var taskID: String? {
        switch self {
        case let .subscribeTask(id, _), let .loadOlder(id, _), let .unsubscribeTask(id), let .sendMessage(id, _, _, _, _),
             let .answerApproval(id, _, _, _), let .stopTurn(id), let .markRead(id), let .answerQuestion(id, _, _),
             let .reviewPlan(id, _, _, _), let .itemDetail(id, _), let .actOnSuggestion(id, _, _), let .setPinned(id, _),
             let .archiveTask(id), let .limitAccounts(id), let .continueWithAccount(id, _), let .setAutoContinue(id, _),
             let .actOnQueued(id, _, _), let .answerHandoff(id, _, _), let .chooseAnswer(id, _, _, _, _),
             let .taskOutputs(id), let .readFile(id, _, _), let .taskSettings(id, _), let .setTaskSetting(id, _, _, _),
             let .composerCommands(id), let .runComposerCommand(id, _, _), let .editMessage(id, _, _), let .forkTask(id, _): id
        case .snapshot, .ping, .createTask, .newTaskOptions, .registerPush, .unregisterPush, .forgetDevice,
             .answerLink, .uploadFile, .revealLink, .scheduledTasks, .runScheduledTask, .setScheduledTaskEnabled,
             .presence: nil
        }
    }

    /// The schedule a request names (§15.21).
    public var scheduleID: String? {
        switch self {
        case let .runScheduledTask(id), let .setScheduledTaskEnabled(id, _): id
        default: nil
        }
    }

    /// A command acts on a task or a schedule through the Mac's own controls; its rate is limited apart and
    /// it is written to the audit log.
    public var isCommand: Bool {
        switch self {
        case .sendMessage, .answerApproval, .stopTurn, .markRead, .answerQuestion, .reviewPlan, .createTask,
             .actOnSuggestion, .setPinned, .archiveTask, .answerLink, .continueWithAccount, .setAutoContinue, .actOnQueued,
             .answerHandoff, .chooseAnswer, .runScheduledTask, .setScheduledTaskEnabled, .setTaskSetting, .runComposerCommand,
             .editMessage, .forkTask: true
        default: false
        }
    }
}

public struct RemoteRequestEnvelope: Equatable, Sendable {
    public var id: String
    public var request: RemoteRequest

    public init(id: String, request: RemoteRequest) {
        self.id = id
        self.request = request
    }

    /// A request that could not be read: its `id` when one was readable, and why.
    public struct DecodingFailure: Error, Equatable, Sendable {
        public var id: String?
        public var error: RemoteError
    }

    private struct Wire: Codable {
        var id: String?
        var type: String?
        var token: String?
        var taskId: String?
        var cursor: String?
        var text: String?
        var requestId: String?
        var answer: String?
        var answers: [RemoteQuestionAnswer]?
        var decision: String?
        var reason: String?
        var projectId: String?
        var provider: String?
        var itemId: String?
        var suggestionId: String?
        var action: String?
        var pinned: Bool?
        var approve: Bool?
        var note: String?
        var images: [WireImage]?
        var followUp: String?
        var harness: String?
        var settings: [String: String]?
        var worktree: Bool?
        var accountId: String?
        var enabled: Bool?
        var active: Bool?
        var choice: String?
        var values: [String: RemoteFormValue]?
        var files: [String]?
        var uploadId: String?
        var name: String?
        var mediaType: String?
        var size: Int?
        var offset: Int?
        var data: String?
        var nonce: String?
        var scheduleId: String?
        var path: String?
        var prepare: Bool?
        var setting: String?
        var value: String?
        var confirmed: Bool?
        var command: String?
        var arguments: String?
        var turnId: String?
        var detail: String?
    }

    private struct WireImage: Codable {
        var type: String
        var data: String
    }

    /// The images of a request, decoded, or nil when one is not base64.
    private static func images(_ wire: [WireImage]?) -> [RemoteImage]? {
        var images: [RemoteImage] = []
        for image in wire ?? [] {
            guard let data = Data(base64Encoded: image.data, options: .ignoreUnknownCharacters) else { return nil }
            images.append(RemoteImage(type: image.type, data: data))
        }
        return images
    }

    public static func decode(_ data: Data) -> Result<RemoteRequestEnvelope, DecodingFailure> {
        guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
            return .failure(DecodingFailure(id: nil, error: RemoteError(.badRequest, "Not a JSON object")))
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            let id = (object as? [String: Any])?["id"] as? String
            return .failure(DecodingFailure(id: id, error: RemoteError(.badRequest, "A field has the wrong type")))
        }
        guard let id = wire.id, !id.isEmpty, id.count <= 64 else {
            return .failure(DecodingFailure(id: nil, error: RemoteError(.badRequest, "Missing or invalid id")))
        }
        func fail(_ code: RemoteErrorCode, _ message: String) -> Result<RemoteRequestEnvelope, DecodingFailure> {
            .failure(DecodingFailure(id: id, error: RemoteError(code, message)))
        }
        func required(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        guard let type = wire.type else { return fail(.badRequest, "Missing type") }
        // Longer than any ID the Mac makes: refused before it reaches a lookup or the audit log.
        let identifiers: [(name: String, value: String?, limit: Int)] = [
            ("taskId", wire.taskId, RemoteProtocol.maxOwnIDBytes), ("projectId", wire.projectId, RemoteProtocol.maxOwnIDBytes),
            ("scheduleId", wire.scheduleId, RemoteProtocol.maxOwnIDBytes), ("accountId", wire.accountId, RemoteProtocol.maxOwnIDBytes),
            ("requestId", wire.requestId, RemoteProtocol.maxProviderIDBytes), ("itemId", wire.itemId, RemoteProtocol.maxProviderIDBytes),
            ("suggestionId", wire.suggestionId, RemoteProtocol.maxProviderIDBytes),
            ("choice", wire.choice, RemoteProtocol.maxProviderIDBytes), ("setting", wire.setting, RemoteProtocol.maxProviderIDBytes),
            ("value", wire.value, RemoteProtocol.maxProviderIDBytes), ("command", wire.command, RemoteProtocol.maxProviderIDBytes),
            ("turnId", wire.turnId, RemoteProtocol.maxProviderIDBytes)
        ]
        if let long = identifiers.first(where: { ($0.value?.utf8.count ?? 0) > $0.limit }) {
            return fail(.badRequest, "\(long.name) is too long")
        }
        let request: RemoteRequest
        switch type {
        case "snapshot":
            request = .snapshot
        case "ping":
            request = .ping
        case "subscribeTask", "unsubscribeTask", "stopTurn", "markRead", "loadOlder", "sendMessage", "answerApproval":
            guard let taskID = required(wire.taskId) else { return fail(.badRequest, "Missing taskId") }
            switch type {
            // A detail the Mac does not know reads as the phone's (§2).
            case "subscribeTask": request = .subscribeTask(taskID: taskID, detail: wire.detail == "full" ? .full : .basic)
            case "unsubscribeTask": request = .unsubscribeTask(taskID: taskID)
            case "stopTurn": request = .stopTurn(taskID: taskID)
            case "markRead": request = .markRead(taskID: taskID)
            case "loadOlder":
                guard let cursor = required(wire.cursor) else { return fail(.badRequest, "Missing cursor") }
                request = .loadOlder(taskID: taskID, cursor: cursor)
            case "sendMessage":
                let attached = wire.images?.isEmpty == false || wire.files?.isEmpty == false
                guard let text = wire.text ?? (attached ? "" : nil) else {
                    return fail(.badRequest, "Missing text")
                }
                guard let images = images(wire.images) else { return fail(.badRequest, "An image is not base64") }
                var followUp: RemoteFollowUpMode?
                if let value = wire.followUp {
                    guard let mode = RemoteFollowUpMode(rawValue: value) else {
                        return fail(.badRequest, "followUp must be steer or queue")
                    }
                    followUp = mode
                }
                request = .sendMessage(taskID: taskID, text: text, images: images, followUp: followUp, files: wire.files ?? [])
            default:
                guard let requestID = required(wire.requestId) else {
                    return fail(.badRequest, "Missing requestId")
                }
                guard let answer = wire.answer.flatMap(RemoteApprovalAnswer.init(rawValue:)) else {
                    return fail(.badRequest, "answer must be allowOnce, allowForSession or deny")
                }
                let note = wire.note?.trimmingCharacters(in: .whitespacesAndNewlines)
                if note?.isEmpty == false, answer != .deny { return fail(.badRequest, "A note goes with deny only") }
                request = .answerApproval(taskID: taskID, requestID: requestID, answer: answer,
                                          note: note?.isEmpty == false ? note : nil)
            }
        case "answerQuestion", "reviewPlan":
            guard let taskID = required(wire.taskId) else { return fail(.badRequest, "Missing taskId") }
            guard let requestID = required(wire.requestId) else { return fail(.badRequest, "Missing requestId") }
            if type == "answerQuestion" {
                guard let answers = wire.answers else { return fail(.badRequest, "Missing answers") }
                request = .answerQuestion(taskID: taskID, requestID: requestID, answers: answers)
            } else {
                guard let decision = wire.decision.flatMap(RemotePlanDecision.init(rawValue:)) else {
                    return fail(.badRequest, "decision must be approve or keepPlanning")
                }
                request = .reviewPlan(taskID: taskID, requestID: requestID, decision: decision, reason: wire.reason)
            }
        case "createTask":
            guard let projectID = required(wire.projectId) else { return fail(.badRequest, "Missing projectId") }
            // A new task starts with words, as on the Mac, images or not.
            guard let text = wire.text else { return fail(.badRequest, "Missing text") }
            guard let images = images(wire.images) else { return fail(.badRequest, "An image is not base64") }
            request = .createTask(RemoteTaskStart(projectID: projectID, text: text, harness: required(wire.harness),
                                                  settings: wire.settings ?? [:], worktree: wire.worktree, images: images,
                                                  files: wire.files ?? []))
        case "newTaskOptions":
            request = .newTaskOptions(projectID: required(wire.projectId), harness: required(wire.harness),
                                      settings: wire.settings ?? [:])
        case "limitAccounts":
            guard let taskID = required(wire.taskId) else { return fail(.badRequest, "Missing taskId") }
            request = .limitAccounts(taskID: taskID)
        case "continueWithAccount":
            guard let taskID = required(wire.taskId), let accountID = required(wire.accountId) else {
                return fail(.badRequest, "Missing taskId or accountId")
            }
            request = .continueWithAccount(taskID: taskID, accountID: accountID)
        case "setAutoContinue":
            guard let taskID = required(wire.taskId), let enabled = wire.enabled else {
                return fail(.badRequest, "Missing taskId or enabled")
            }
            request = .setAutoContinue(taskID: taskID, enabled: enabled)
        case "actOnQueued":
            guard let taskID = required(wire.taskId), let itemID = required(wire.itemId) else {
                return fail(.badRequest, "Missing taskId or itemId")
            }
            guard let action = wire.action.flatMap(RemoteQueuedAction.init(rawValue:)) else {
                return fail(.badRequest, "action must be sendNow, stopAndSend or remove")
            }
            request = .actOnQueued(taskID: taskID, itemID: itemID, action: action)
        case "answerHandoff":
            guard let taskID = required(wire.taskId), let requestID = required(wire.requestId) else {
                return fail(.badRequest, "Missing taskId or requestId")
            }
            guard let answer = wire.answer.flatMap(RemoteHandoffAnswer.init(rawValue:)) else {
                return fail(.badRequest, "answer must be done or decline")
            }
            request = .answerHandoff(taskID: taskID, requestID: requestID, answer: answer)
        case "chooseAnswer":
            guard let taskID = required(wire.taskId), let requestID = required(wire.requestId),
                  let choice = required(wire.choice) else { return fail(.badRequest, "Missing taskId, requestId or choice") }
            let note = wire.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            request = .chooseAnswer(taskID: taskID, requestID: requestID, choice: choice,
                                    note: note?.isEmpty == false ? note : nil, values: wire.values ?? [:])
        case "uploadFile":
            guard let uploadID = required(wire.uploadId), UUID(uuidString: uploadID) != nil else {
                return fail(.badRequest, "uploadId must be a UUID")
            }
            guard let offset = wire.offset, offset >= 0, let encoded = wire.data,
                  let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
                return fail(.badRequest, "Missing offset or base64 data")
            }
            request = .uploadFile(RemoteUploadPart(uploadID: uploadID.uppercased(), name: wire.name, mediaType: wire.mediaType,
                                                   size: wire.size, offset: offset, data: data))
        case "registerPush":
            guard let provider = required(wire.provider), let token = required(wire.token) else {
                return fail(.badRequest, "Missing provider or token")
            }
            guard RemoteProtocol.pushProviders.contains(provider) else { return fail(.badRequest, "Unknown push provider") }
            request = .registerPush(provider: provider, token: token)
        case "unregisterPush":
            request = .unregisterPush
        case "forgetDevice":
            request = .forgetDevice
        case "itemDetail":
            guard let taskID = required(wire.taskId), let itemID = required(wire.itemId) else {
                return fail(.badRequest, "Missing taskId or itemId")
            }
            request = .itemDetail(taskID: taskID, itemID: itemID)
        case "actOnSuggestion":
            guard let taskID = required(wire.taskId), let suggestionID = required(wire.suggestionId) else {
                return fail(.badRequest, "Missing taskId or suggestionId")
            }
            guard let action = wire.action.flatMap(RemoteSuggestionAction.init(rawValue:)) else {
                return fail(.badRequest, "action must be start, here or dismiss")
            }
            request = .actOnSuggestion(taskID: taskID, suggestionID: suggestionID, action: action)
        case "setPinned":
            guard let taskID = required(wire.taskId), let pinned = wire.pinned else {
                return fail(.badRequest, "Missing taskId or pinned")
            }
            request = .setPinned(taskID: taskID, pinned: pinned)
        case "archiveTask":
            guard let taskID = required(wire.taskId) else { return fail(.badRequest, "Missing taskId") }
            request = .archiveTask(taskID: taskID)
        case "answerLink":
            guard let requestID = required(wire.requestId), let approve = wire.approve else {
                return fail(.badRequest, "Missing requestId or approve")
            }
            request = .answerLink(requestID: requestID, approve: approve)
        case "revealLink":
            guard let nonce = wire.nonce.flatMap(RemoteEncoding.data(base64url:)), nonce.count == RemoteLinkCode.nonceLength else {
                return fail(.badRequest, "Missing or invalid nonce")
            }
            request = .revealLink(nonce: nonce)
        case "scheduledTasks":
            request = .scheduledTasks
        case "presence":
            guard let active = wire.active else { return fail(.badRequest, "Missing active") }
            request = .presence(active: active)
        case "runScheduledTask":
            guard let scheduleID = required(wire.scheduleId) else { return fail(.badRequest, "Missing scheduleId") }
            request = .runScheduledTask(scheduleID: scheduleID)
        case "setScheduledTaskEnabled":
            guard let scheduleID = required(wire.scheduleId), let enabled = wire.enabled else {
                return fail(.badRequest, "Missing scheduleId or enabled")
            }
            request = .setScheduledTaskEnabled(scheduleID: scheduleID, enabled: enabled)
        case "taskOutputs":
            guard let taskID = required(wire.taskId) else { return fail(.badRequest, "Missing taskId") }
            request = .taskOutputs(taskID: taskID)
        case "readFile":
            guard let taskID = required(wire.taskId), let path = required(wire.path) else {
                return fail(.badRequest, "Missing taskId or path")
            }
            guard let offset = wire.offset, offset >= 0 else { return fail(.badRequest, "Missing or negative offset") }
            request = .readFile(taskID: taskID, path: path, offset: offset)
        case "taskSettings", "composerCommands", "forkTask":
            guard let taskID = required(wire.taskId) else { return fail(.badRequest, "Missing taskId") }
            switch type {
            case "taskSettings": request = .taskSettings(taskID: taskID, prepare: wire.prepare == true)
            case "composerCommands": request = .composerCommands(taskID: taskID)
            default: request = .forkTask(taskID: taskID, turnID: required(wire.turnId))
            }
        case "setTaskSetting":
            guard let taskID = required(wire.taskId), let setting = required(wire.setting), let value = wire.value else {
                return fail(.badRequest, "Missing taskId, setting or value")
            }
            request = .setTaskSetting(taskID: taskID, setting: setting, value: value, confirmed: wire.confirmed == true)
        case "runComposerCommand":
            guard let taskID = required(wire.taskId), let command = required(wire.command) else {
                return fail(.badRequest, "Missing taskId or command")
            }
            let arguments = wire.arguments?.trimmingCharacters(in: .whitespacesAndNewlines)
            request = .runComposerCommand(taskID: taskID, command: command, arguments: arguments?.isEmpty == false ? arguments : nil)
        case "editMessage":
            guard let taskID = required(wire.taskId), let turnID = required(wire.turnId), let text = wire.text else {
                return fail(.badRequest, "Missing taskId, turnId or text")
            }
            request = .editMessage(taskID: taskID, turnID: turnID, text: text)
        default:
            return fail(.unknownType, "Unknown type \(type)")
        }
        return .success(RemoteRequestEnvelope(id: id, request: request))
    }

    /// The request as a client writes it.
    public func encoded() -> Data {
        var wire = Wire(id: id, type: request.type)
        switch request {
        case .snapshot, .ping:
            break
        case let .subscribeTask(taskID, detail):
            wire.taskId = taskID
            wire.detail = detail == .full ? detail.rawValue : nil
        case let .unsubscribeTask(taskID), let .stopTurn(taskID), let .markRead(taskID):
            wire.taskId = taskID
        case let .loadOlder(taskID, cursor):
            wire.taskId = taskID
            wire.cursor = cursor
        case let .sendMessage(taskID, text, images, followUp, files):
            wire.taskId = taskID
            wire.text = text
            wire.images = Self.wire(images)
            wire.followUp = followUp?.rawValue
            wire.files = files.isEmpty ? nil : files
        case let .answerApproval(taskID, requestID, answer, note):
            wire.taskId = taskID
            wire.requestId = requestID
            wire.answer = answer.rawValue
            wire.note = note
        case let .answerQuestion(taskID, requestID, answers):
            wire.taskId = taskID
            wire.requestId = requestID
            wire.answers = answers
        case let .reviewPlan(taskID, requestID, decision, reason):
            wire.taskId = taskID
            wire.requestId = requestID
            wire.decision = decision.rawValue
            wire.reason = reason
        case let .createTask(start):
            wire.projectId = start.projectID
            wire.text = start.text
            wire.harness = start.harness
            wire.settings = start.settings.isEmpty ? nil : start.settings
            wire.worktree = start.worktree
            wire.images = Self.wire(start.images)
            wire.files = start.files.isEmpty ? nil : start.files
        case let .newTaskOptions(projectID, harness, settings):
            wire.projectId = projectID
            wire.harness = harness
            wire.settings = settings.isEmpty ? nil : settings
        case let .limitAccounts(taskID):
            wire.taskId = taskID
        case let .continueWithAccount(taskID, accountID):
            wire.taskId = taskID
            wire.accountId = accountID
        case let .setAutoContinue(taskID, enabled):
            wire.taskId = taskID
            wire.enabled = enabled
        case let .actOnQueued(taskID, itemID, action):
            wire.taskId = taskID
            wire.itemId = itemID
            wire.action = action.rawValue
        case let .answerHandoff(taskID, requestID, answer):
            wire.taskId = taskID
            wire.requestId = requestID
            wire.answer = answer.rawValue
        case let .chooseAnswer(taskID, requestID, choice, note, values):
            wire.taskId = taskID
            wire.requestId = requestID
            wire.choice = choice
            wire.note = note
            wire.values = values.isEmpty ? nil : values
        case let .uploadFile(part):
            wire.uploadId = part.uploadID
            wire.name = part.name
            wire.mediaType = part.mediaType
            wire.size = part.size
            wire.offset = part.offset
            wire.data = part.data.base64EncodedString()
        case let .registerPush(provider, token):
            wire.provider = provider
            wire.token = token
        case .unregisterPush, .forgetDevice:
            break
        case let .itemDetail(taskID, itemID):
            wire.taskId = taskID
            wire.itemId = itemID
        case let .actOnSuggestion(taskID, suggestionID, action):
            wire.taskId = taskID
            wire.suggestionId = suggestionID
            wire.action = action.rawValue
        case let .setPinned(taskID, pinned):
            wire.taskId = taskID
            wire.pinned = pinned
        case let .archiveTask(taskID):
            wire.taskId = taskID
        case let .answerLink(requestID, approve):
            wire.requestId = requestID
            wire.approve = approve
        case let .revealLink(nonce):
            wire.nonce = RemoteEncoding.base64url(nonce)
        case .scheduledTasks:
            break
        case let .presence(active):
            wire.active = active
        case let .runScheduledTask(scheduleID):
            wire.scheduleId = scheduleID
        case let .setScheduledTaskEnabled(scheduleID, enabled):
            wire.scheduleId = scheduleID
            wire.enabled = enabled
        case let .taskOutputs(taskID):
            wire.taskId = taskID
        case let .readFile(taskID, path, offset):
            wire.taskId = taskID
            wire.path = path
            wire.offset = offset
        case let .taskSettings(taskID, prepare):
            wire.taskId = taskID
            wire.prepare = prepare ? true : nil
        case let .setTaskSetting(taskID, setting, value, confirmed):
            wire.taskId = taskID
            wire.setting = setting
            wire.value = value
            wire.confirmed = confirmed ? true : nil
        case let .composerCommands(taskID):
            wire.taskId = taskID
        case let .runComposerCommand(taskID, command, arguments):
            wire.taskId = taskID
            wire.command = command
            wire.arguments = arguments
        case let .editMessage(taskID, turnID, text):
            wire.taskId = taskID
            wire.turnId = turnID
            wire.text = text
        case let .forkTask(taskID, turnID):
            wire.taskId = taskID
            wire.turnId = turnID
        }
        return (try? RemoteJSON.encoder.encode(wire)) ?? Data()
    }

    private static func wire(_ images: [RemoteImage]) -> [WireImage]? {
        images.isEmpty ? nil : images.map { WireImage(type: $0.type, data: $0.data.base64EncodedString()) }
    }
}

// MARK: - Responses and events

public struct RemoteServerInfo: Codable, Equatable, Sendable {
    public var name: String
    public var app: String
    public var appVersion: String
    public var protocolVersion: Int

    public init(name: String, app: String = "Yardlet", appVersion: String, protocolVersion: Int = RemoteProtocol.secureVersion) {
        self.name = name
        self.app = app
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
    }
}

/// A response to one request. Each request fills the result fields its section names.
public struct RemoteResponse: Codable, Equatable, Sendable {
    public var re: String
    public var ok: Bool
    public var error: RemoteError?

    public var deviceId: String?
    public var server: RemoteServerInfo?
    public var projects: [RemoteProject]?
    public var tasks: [RemoteTask]?
    public var taskId: String?
    public var items: [RemoteItem]?
    public var cursor: String?
    public var hasOlder: Bool?
    public var pong: Bool?
    public var serverTime: Int64?
    /// `snapshot` on v2 (§15.1).
    public var newTask: RemoteNewTask?
    /// `registerPush` (§15.6).
    public var pushKey: String?
    public var pushKeyId: String?
    /// `itemDetail` (§15.8).
    public var itemId: String?
    public var output: String?
    public var outputTruncated: Bool?
    public var diffs: [RemoteDiff]?
    /// `snapshot` on v2 (§15.15).
    public var followUp: RemoteFollowUpMode?
    /// `newTaskOptions` (§15.16).
    public var harness: String?
    public var harnessName: String?
    public var harnesses: [RemoteHarnessOption]?
    public var settings: [RemoteSetting]?
    public var worktree: Bool?
    /// `limitAccounts` (§15.17).
    public var accounts: [RemoteAccount]?
    /// `uploadFile` (§15.20).
    public var uploadId: String?
    public var received: Int?
    /// `snapshot` on v2: the Mac answers `scheduledTasks` (§15.21).
    public var scheduledTasks: Bool?
    /// `snapshot` (§18): the Mac takes `presence` and holds phone pushes while a desktop is in use.
    public var presence: Bool?
    /// `scheduledTasks` (§15.21).
    public var schedules: [RemoteSchedule]?
    /// `snapshot` on v2: the Mac answers `taskOutputs` and `readFile` (§15.22).
    public var taskFiles: Bool?
    /// `snapshot` on v2: the Mac answers `subscribeTask` with `"detail": "full"` (§15.24).
    public var fullConversation: Bool?
    /// `taskOutputs` (§15.22).
    public var outputs: [RemoteOutput]?
    /// `readFile` (§15.22): the absolute path the Mac read, the file's name, type, size and modification time, and
    /// the bytes from `offset` (base64).
    public var path: String?
    public var name: String?
    public var mediaType: String?
    public var size: Int?
    public var offset: Int?
    public var data: Data?
    public var modifiedAt: Int64?
    /// `snapshot` on v2: the Mac answers a task's settings, slash commands, edit and fork (§15.23).
    public var taskControls: Bool?
    /// `composerCommands` (§15.23).
    public var commands: [RemoteComposerCommand]?

    public init(re: String, ok: Bool = true, error: RemoteError? = nil) {
        self.re = re
        self.ok = ok
        self.error = error
    }

    public static func failure(_ id: String, _ error: RemoteError) -> RemoteResponse {
        RemoteResponse(re: id, ok: false, error: error)
    }
}

/// One file's change for `itemDetail` (§15.8).
public struct RemoteDiff: Codable, Equatable, Sendable {
    public var path: String
    public var patch: String
    public var additions: Int?
    public var deletions: Int?
    public var truncated: Bool?

    public init(path: String, patch: String, additions: Int? = nil, deletions: Int? = nil, truncated: Bool? = nil) {
        self.path = path
        self.patch = patch
        self.additions = additions
        self.deletions = deletions
        self.truncated = truncated
    }
}

/// A harness a phone may start a task on (§15.16).
public struct RemoteHarnessOption: Codable, Equatable, Sendable {
    public var harness: String
    public var harnessName: String
    public var acceptsImages: Bool?
    public var acceptsFiles: Bool?

    public init(harness: String, harnessName: String, acceptsImages: Bool? = nil, acceptsFiles: Bool? = nil) {
        self.harness = harness
        self.harnessName = harnessName
        self.acceptsImages = acceptsImages
        self.acceptsFiles = acceptsFiles
    }
}

/// One of the new-task screen's settings, its value now and its choices (§15.16).
public struct RemoteSetting: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Sendable {
        public var value: String
        public var name: String
        public var description: String?
        /// The Mac's menu asks before it applies this choice, in these words (§15.23).
        public var confirm: Confirmation?

        public init(value: String, name: String, description: String? = nil, confirm: Confirmation? = nil) {
            self.value = value
            self.name = name
            self.description = description
            self.confirm = confirm
        }
    }

    /// What the Mac asks before a choice that lifts the sandbox or skips asking (§15.23).
    public struct Confirmation: Codable, Equatable, Sendable {
        public var title: String
        public var message: String
        public var button: String

        public init(title: String, message: String, button: String) {
            self.title = title
            self.message = message
            self.button = button
        }
    }

    public var id: String
    public var name: String
    public var value: String
    public var choices: [Choice]
    /// Where the Mac's task composer shows it (§15.23): `mode`, `plan`, `permission`, `model`, `effort` or `speed`.
    public var role: String?
    /// The Mac's menu reads its choices first when it opens: ask `taskSettings` with `prepare` (§15.23).
    public var prepare: Bool?
    /// The value now lifts the sandbox or skips asking (drawn in orange on the Mac).
    public var elevated: Bool?
    /// The control's words when no choice names its value, and what its menu says when there is nothing to choose.
    public var title: String?
    public var note: String?

    public init(id: String, name: String, value: String, choices: [Choice], role: String? = nil) {
        self.id = id
        self.name = name
        self.value = value
        self.choices = choices
        self.role = role
    }
}

/// A slash command a task's composer offers that may run from another device (§15.23).
public struct RemoteComposerCommand: Codable, Equatable, Sendable {
    /// Typed as `/name`.
    public var name: String
    /// The list's own title where it shows one in place of `/name` (Codex).
    public var title: String?
    public var description: String?
    /// The words it takes after its name, as the list hints them; absent when it takes none.
    public var argumentHint: String?
    public var group: String?
    /// Choosing it runs it at once (the Codex app's commands); otherwise it is typed into the draft and runs when sent.
    public var runs: Bool?

    public init(name: String, title: String? = nil, description: String? = nil, argumentHint: String? = nil,
                group: String? = nil, runs: Bool? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.argumentHint = argumentHint
        self.group = group
        self.runs = runs
    }
}

/// What `newTaskOptions` answers with (§15.16).
public struct RemoteNewTaskOptions: Equatable, Sendable {
    public var harness: RemoteHarnessOption
    public var harnesses: [RemoteHarnessOption]
    public var settings: [RemoteSetting]
    public var worktree: Bool?

    public init(harness: RemoteHarnessOption, harnesses: [RemoteHarnessOption], settings: [RemoteSetting] = [],
                worktree: Bool? = nil) {
        self.harness = harness
        self.harnesses = harnesses
        self.settings = settings
        self.worktree = worktree
    }
}

/// An account of a limit card's list (§15.17), with its limit windows as the list shows them.
public struct RemoteAccount: Codable, Equatable, Sendable {
    public struct Usage: Codable, Equatable, Sendable {
        public var label: String
        public var usedPercent: Int?
        public var resetsAt: Int64?

        public init(label: String, usedPercent: Int? = nil, resetsAt: Int64? = nil) {
            self.label = label
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    public var id: String
    public var name: String
    public var detail: String?
    public var usage: [Usage]
    /// The task runs under it now.
    public var current: Bool?
    /// The task may move to it now.
    public var available: Bool?

    public init(id: String, name: String, detail: String? = nil, usage: [Usage] = [], current: Bool? = nil,
                available: Bool? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.usage = usage
        self.current = current
        self.available = available
    }
}

/// A schedule of the Mac's Scheduled tasks list (§15.21), with its words as the Mac shows them.
public struct RemoteSchedule: Codable, Equatable, Sendable {
    /// Its latest run.
    public struct Run: Codable, Equatable, Sendable {
        public enum Outcome: String, Codable, Sendable {
            case started
            case skipped
            case failed

            /// An outcome this side does not know reads as `failed`.
            public init(from decoder: any Decoder) throws {
                self = Outcome(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
            }
        }

        public var at: Int64
        public var outcome: Outcome
        /// The task it started or continued, when the snapshot lists it.
        public var taskId: String?
        /// The Mac's line for it.
        public var line: String

        public init(at: Int64, outcome: Outcome, taskId: String? = nil, line: String) {
            self.at = at
            self.outcome = outcome
            self.taskId = taskId
            self.line = line
        }
    }

    public var id: String
    public var name: String
    /// When it runs, in the Mac's words.
    public var when: String
    /// Off while paused, and once it stopped itself.
    public var enabled: Bool
    /// The task its latest run started or continued is working or waiting on the person.
    public var running: Bool
    public var nextRunAt: Int64?
    /// The Mac's status line.
    public var status: String?
    /// Nil for a chat.
    public var projectName: String?
    public var harnessName: String
    public var lastRun: Run?
    /// It is off and Resume turns it on again (a one-off that ran or whose time passed is not resumed).
    public var canResume: Bool?

    public init(id: String, name: String, when: String, enabled: Bool, running: Bool = false, nextRunAt: Int64? = nil,
                status: String? = nil, projectName: String? = nil, harnessName: String, lastRun: Run? = nil,
                canResume: Bool? = nil) {
        self.id = id
        self.name = name
        self.when = when
        self.enabled = enabled
        self.running = running
        self.nextRunAt = nextRunAt
        self.status = status
        self.projectName = projectName
        self.harnessName = harnessName
        self.lastRun = lastRun
        self.canResume = canResume
    }
}

/// A file of the Mac's Outputs card for a task (§15.22).
public struct RemoteOutput: Codable, Equatable, Sendable {
    /// Absolute.
    public var path: String
    public var name: String
    /// Absent for a file that is gone.
    public var size: Int?
    public var writtenAt: Int64?

    public init(path: String, name: String, size: Int? = nil, writtenAt: Int64? = nil) {
        self.path = path
        self.name = name
        self.size = size
        self.writtenAt = writtenAt
    }
}

/// What `itemDetail` answers with.
public struct RemoteItemDetail: Equatable, Sendable {
    public var output: String?
    public var outputTruncated = false
    public var diffs: [RemoteDiff] = []

    public init(output: String? = nil, outputTruncated: Bool = false, diffs: [RemoteDiff] = []) {
        self.output = output
        self.outputTruncated = outputTruncated
        self.diffs = diffs
    }

    public static let outputLimit = 64_000
    public static let diffLimit = 100_000
    public static let diffCount = 50
}

/// An event the server pushes.
public struct RemoteEvent: Codable, Equatable, Sendable {
    public enum Name: String, Codable, Sendable {
        case tasksChanged
        case attention
        case conversation
        case conversationReset
        case conversationEnded
        case revoked
        case closing
        // v2 (§12.1, §15.11)
        case linked
        case linkRefused
        case linkRequest
        case linkResolved
        // §15.21
        case schedulesChanged
        // §15.23
        case taskSettingsChanged
    }

    public var event: Name
    public var seq: Int?

    // tasksChanged
    public var tasks: [RemoteTask]?
    public var removedTaskIds: [String]?
    public var projects: [RemoteProject]?

    // attention
    public var taskId: String?
    public var title: String?
    public var projectName: String?
    public var harnessName: String?
    public var state: RemoteAttention?
    public var previousState: RemoteAttention?
    public var indicator: RemoteIndicator?
    public var pendingRequest: RemotePendingRequest?
    public var requestId: String?
    /// One line about the request waited on (≤ 120 characters, secrets masked), for a notification.
    public var summary: String?
    /// While `waiting`, what kind of request it is, as the task's `pendingKind` (§15.1, §15.18).
    public var pendingKind: String?

    // conversation
    public var changes: [RemoteChange]?
    public var items: [RemoteItem]?
    public var cursor: String?
    public var hasOlder: Bool?
    public var reason: String?

    // links
    public var deviceId: String?
    public var name: String?
    public var platform: String?
    public var code: String?
    public var expiresAt: Int64?
    public var approved: Bool?
    /// Push payloads (§16): the Mac's name and when the push was sent.
    public var macName: String?
    public var sentAt: Int64?

    public init(_ event: Name) {
        self.event = event
    }
}

public enum RemoteJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func string<Value: Encodable>(_ value: Value) -> String {
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

// MARK: - v2 handshake payloads (§13.1)

/// Message 1's payload.
public struct RemoteHandshakeHello: Codable, Equatable, Sendable {
    public var v: Int
    public var name: String?
    public var platform: String?
    public var appVersion: String?
    /// The pairing secret from the QR code.
    public var pair: String?
    /// Asks to link through the account (§12.1).
    public var link: Bool?
    /// With `link`: the commitment to the nonce the phone reveals once message 2 is in (§12.1), base64url.
    public var linkCommit: String?

    public init(v: Int = RemoteProtocol.secureVersion, name: String? = nil, platform: String? = nil,
                appVersion: String? = nil, pair: String? = nil, link: Bool? = nil, linkCommit: String? = nil) {
        self.v = v
        self.name = name
        self.platform = platform
        self.appVersion = appVersion
        self.pair = pair
        self.link = link
        self.linkCommit = linkCommit
    }
}

/// Message 2's payload.
public struct RemoteHandshakeReply: Codable, Equatable, Sendable {
    public struct Relay: Codable, Equatable, Sendable {
        public var url: String
        public var room: String

        public init(url: String, room: String) {
            self.url = url
            self.room = room
        }
    }

    public var ok: Bool
    public var error: RemoteError?
    public var deviceId: String?
    public var serverTime: Int64?
    public var paired: Bool?
    public var pending: Bool?
    /// With `pending`: the Mac's nonce for the link code (§12.1), base64url.
    public var linkNonce: String?
    public var server: RemoteServerInfo?
    public var direct: [String]?
    public var relay: Relay?

    public init(ok: Bool, error: RemoteError? = nil) {
        self.ok = ok
        self.error = error
    }
}
