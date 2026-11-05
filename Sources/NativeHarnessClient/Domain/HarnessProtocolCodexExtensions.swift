import Foundation

struct HarnessProtocolCodexPresentationReadParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let refresh: Bool
    /// `true` asks an adapter that advertises `yardlet.codex.presentation.patches` to restart
    /// this session's live chain: its next live update is a complete `presentation.updated`
    /// with a `revision`, and the ones after it are `presentation.patched`. Absent leaves the
    /// session's live updates as they are; an older adapter ignores the field.
    var livePatches: Bool? = nil
}

extension HarnessCapabilityID {
    /// The adapter can send a session's live Codex presentation as revisioned patches once the
    /// host asks for them with `livePatches` on `yardlet.codex.presentation.read`.
    static let codexPresentationPatches = Self(rawValue: "yardlet.codex.presentation.patches")
}

/// `yardlet.codex` extension event names of the live presentation.
enum HarnessProtocolCodexPresentationEvent {
    /// A complete `HarnessProtocolCodexPresentationSnapshot`.
    static let updated = "presentation.updated"
    /// A `HarnessProtocolCodexPresentationPatch` against the previous revision.
    static let patched = "presentation.patched"
    /// The place of an update a later complete snapshot replaced, kept in replay history.
    static let superseded = "presentation.superseded"
}

enum HarnessProtocolCodexSubmissionKind: String, Codable, Equatable, Sendable {
    case start
    case steer
}

/// Codex composer inputs stay as their complete provider-owned JSON envelopes. This preserves
/// text elements, image detail, audio, skills, mentions, and unknown future variants without
/// forcing them through the smaller canonical content-block vocabulary.
struct HarnessProtocolCodexComposerSubmitParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let clientTurnID: String
    let inputs: [JSONValue]
    let submission: HarnessProtocolCodexSubmissionKind
    let expectedTurnID: String?
}

struct HarnessProtocolCodexComposerState: Codable, Equatable, Sendable {
    let activeTurnID: String?
}

struct HarnessProtocolCodexTurnsLoadParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let cursor: String?
    let limit: Int64?
}

struct HarnessProtocolCodexItemsLoadParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let turnID: String?
    let cursor: String?
    let limit: Int64?
}

struct HarnessProtocolCodexPlanStep: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let status: String
}

struct HarnessProtocolCodexPlan: Codable, Equatable, Sendable {
    let explanation: String?
    let steps: [HarnessProtocolCodexPlanStep]
}

struct HarnessProtocolCodexTokenUsage: Codable, Equatable, Sendable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64
}

struct HarnessProtocolCodexThreadTokenUsage: Codable, Equatable, Sendable {
    let total: HarnessProtocolCodexTokenUsage
    let last: HarnessProtocolCodexTokenUsage
    let modelContextWindow: Int64?
}

struct HarnessProtocolCodexItem: Codable, Equatable, Sendable {
    let id: String
    let lifecycle: Int
    let type: String
    let startedAt: Date?
    let completedAt: Date?
    let raw: JSONValue
    /// Current render payload after streamed deltas; raw retains the original provider frame.
    var rendered: JSONValue? = nil
}

struct HarnessProtocolCodexTurn: Codable, Equatable, Sendable {
    let id: String
    let status: String
    let startedAt: Date?
    let completedAt: Date?
    let durationMilliseconds: Int64?
    let itemsView: String
    let items: [HarnessProtocolCodexItem]
    let itemsNextCursor: String?
    let plan: HarnessProtocolCodexPlan?
    let tokenUsage: HarnessProtocolCodexThreadTokenUsage?
    let error: JSONValue?
    let raw: JSONValue
    /// The live turn's aggregated diff (`turn/diff/updated`); absent from older peers.
    var diff: String? = nil
    /// The live turn's reconnecting stream error (`error` with `willRetry`); absent from older peers.
    var retryingError: JSONValue? = nil
}

struct HarnessProtocolCodexThread: Codable, Equatable, Sendable {
    let id: String
    let sessionID: String?
    let name: String?
    let preview: String
    let workspacePath: String?
    let cliVersion: String?
    let modelProvider: String?
    let parentThreadID: String?
    let forkedFromID: String?
    let status: String
    let activeFlags: [String]
    let canAcceptDirectInput: Bool?
    let createdAt: Date?
    let updatedAt: Date?
    let turns: [HarnessProtocolCodexTurn]
    let turnsNextCursor: String?
    let turnsBackwardsCursor: String?
    let itemsBackwardsCursor: String?
    let raw: JSONValue
}

struct HarnessProtocolCodexServerRequest: Codable, Equatable, Sendable {
    let id: String
    let method: String
    let kind: String
    let threadID: String?
    let turnID: String?
    let itemID: String?
    let params: JSONValue?
    let resolution: String
    let result: JSONValue?
    let rejectionCode: Int64?
    let rejectionMessage: String?
}

struct HarnessProtocolCodexApproval: Codable, Equatable, Sendable {
    let id: String
    let method: String
    let threadID: String
    let turnID: String?
    let itemID: String?
    let resolution: String
    let result: JSONValue?
    let raw: JSONValue?
}

struct HarnessProtocolCodexPresentationSnapshot: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let activeTurnID: String?
    let thread: HarnessProtocolCodexThread?
    let approvals: [HarnessProtocolCodexApproval]
    let serverRequests: [HarnessProtocolCodexServerRequest]
    let answerableServerRequestIDs: [String]
    let lastAppliedSequence: UInt64?
    /// Set on a live `presentation.updated` that starts a patch chain; absent everywhere else.
    var revision: UInt64? = nil
}

/// What changed in a session's live Codex presentation since revision `baseRevision`. Applying it
/// to the presentation at `baseRevision` gives the complete presentation at `revision`; a host
/// holding any other revision asks for a complete snapshot again instead of applying it.
///
/// Turns and items are named by their IDs, which are unique within their thread and turn. An
/// adapter whose presentation has repeated IDs sends complete snapshots instead.
struct HarnessProtocolCodexPresentationPatch: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let revision: UInt64
    let baseRevision: UInt64
    let activeTurnID: String?
    let lastAppliedSequence: UInt64?
    /// Complete, like the snapshot's.
    let answerableServerRequestIDs: [String]
    /// Absent when nothing in the thread changed. The thread itself never appears, disappears,
    /// or changes identity in a patch; that is a complete snapshot.
    let thread: HarnessProtocolCodexThreadPatch?
    /// Added or changed approvals and server requests, whole.
    let approvals: [HarnessProtocolCodexApproval]
    let removedApprovalIDs: [String]
    let serverRequests: [HarnessProtocolCodexServerRequest]
    let removedServerRequestIDs: [String]
}

struct HarnessProtocolCodexThreadPatch: Codable, Equatable, Sendable {
    /// The thread's own fields when any changed. Its `turns` is empty and carries nothing.
    let fields: HarnessProtocolCodexThread?
    /// Every turn ID in order, when a turn was added, removed, or moved. A turn absent from it
    /// is gone; a listed turn the base lacks arrives in `turns` with its fields.
    let turnIDs: [String]?
    /// Turns that were added or changed.
    let turns: [HarnessProtocolCodexTurnPatch]
}

struct HarnessProtocolCodexTurnPatch: Codable, Equatable, Sendable {
    let id: String
    /// The turn's own fields when any changed, and always for an added turn. Its `items` is
    /// empty and carries nothing.
    let fields: HarnessProtocolCodexTurn?
    /// Every item ID in order, when an item was added, removed, or moved, and always for an
    /// added turn.
    let itemIDs: [String]?
    /// Items that were added or changed, whole.
    let items: [HarnessProtocolCodexItem]
}

struct HarnessProtocolCodexTurnPage: Codable, Equatable, Sendable {
    let turns: [HarnessProtocolCodexTurn]
    let nextCursor: String?
    let backwardsCursor: String?
}

struct HarnessProtocolCodexItemPageEntry: Codable, Equatable, Sendable {
    let turnID: String
    let item: HarnessProtocolCodexItem
}

struct HarnessProtocolCodexItemPage: Codable, Equatable, Sendable {
    let entries: [HarnessProtocolCodexItemPageEntry]
    let nextCursor: String?
    let backwardsCursor: String?
}

/// A saved thread to read for display, by its provider ID. No session is named: reading loads
/// nothing and resumes nothing.
struct HarnessProtocolCodexThreadReadParams: Codable, Equatable, Sendable {
    let threadID: String
    /// Read the thread without its turns and then only its newest `newestTurns`, with the cursor
    /// for the ones before them (`turnsNextCursor`). Absent reads every turn, as an older peer does.
    var newestTurns: Int64? = nil
}

struct HarnessProtocolCodexThreadReadResult: Codable, Equatable, Sendable {
    let thread: HarnessProtocolCodexThread
}

/// A page of a saved thread's turns, newest first from `cursor` (nil: the newest), read for display
/// without loading or resuming the thread. The page's turns are oldest first.
struct HarnessProtocolCodexThreadTurnsReadParams: Codable, Equatable, Sendable {
    let threadID: String
    let cursor: String?
    let limit: Int64
}

struct HarnessProtocolCodexHistoryParams: Codable, Equatable, Sendable {
    let workspacePath: String
    let cursor: String?
    let limit: Int64
}

/// A page of every folder's threads a person started, for importing them all at once.
struct HarnessProtocolCodexHistoryPageParams: Codable, Equatable, Sendable {
    let cursor: String?
    let limit: Int64
    /// Only the archived threads. Absent, as from callers before it existed, the open ones.
    var archived: Bool? = nil
}

struct HarnessProtocolCodexHistorySearchParams: Codable, Equatable, Sendable {
    let workspacePath: String
    let query: String
    let cursor: String?
    let limit: Int64
}

/// A provider thread named by its ID, for actions on a thread no session has attached.
struct HarnessProtocolCodexThreadReference: Codable, Equatable, Sendable {
    let providerSessionID: String
}

struct HarnessProtocolCodexHistoryOccurrencesParams: Codable, Equatable, Sendable {
    let providerSessionID: String
    let query: String
    let cursor: String?
    let limit: Int64
}

struct HarnessProtocolCodexThreadSummary: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let preview: String
    let workspacePath: String
    let updatedAt: Date
    let forkedFromID: String?
    /// `CodexThreadSummary.recencyAt`; absent from peers before it existed.
    var recencyAt: Date? = nil
}

struct HarnessProtocolCodexRecentThreadsPage: Codable, Equatable, Sendable {
    let threads: [HarnessProtocolCodexThreadSummary]
    let nextCursor: String?
}

struct HarnessProtocolCodexThreadSearchMatch: Codable, Equatable, Sendable {
    let thread: HarnessProtocolCodexThreadSummary
    let snippet: String?
}

struct HarnessProtocolCodexThreadSearchPage: Codable, Equatable, Sendable {
    let matches: [HarnessProtocolCodexThreadSearchMatch]
    let nextCursor: String?
}

struct HarnessProtocolCodexSearchOccurrence: Codable, Equatable, Sendable {
    let turnID: String
    let itemID: String
    let snippet: String
    let snippetMatchRange: CodexTextRange
    let turnCursor: String
}

struct HarnessProtocolCodexSearchOccurrencesPage: Codable, Equatable, Sendable {
    let occurrences: [HarnessProtocolCodexSearchOccurrence]
    let nextCursor: String?
}

struct HarnessProtocolCodexCollaborationMode: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let mode: String
    let model: String?
    let reasoningEffort: String?
}

struct HarnessProtocolCodexRunLocation: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
}

struct HarnessProtocolCodexControlsCatalog: Codable, Equatable, Sendable {
    let collaborationModes: [HarnessProtocolCodexCollaborationMode]
    let runLocations: [HarnessProtocolCodexRunLocation]
}

struct HarnessProtocolCodexWorkspaceParams: Codable, Equatable, Sendable {
    let workspacePath: String
}

struct HarnessProtocolCodexSkill: Codable, Equatable, Sendable {
    let name: String
    let displayName: String
    let description: String
    let enabled: Bool
    let scope: String
    let path: String
}

struct HarnessProtocolCodexSkillsCatalog: Codable, Equatable, Sendable {
    let skills: [HarnessProtocolCodexSkill]
}

struct HarnessProtocolCodexPlugin: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let displayName: String
    let description: String?
    let installed: Bool
    let enabled: Bool
    let availability: String
    let marketplace: String
}

struct HarnessProtocolCodexPluginsCatalog: Codable, Equatable, Sendable {
    let plugins: [HarnessProtocolCodexPlugin]
}

struct HarnessProtocolCodexControlsReadParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
}

struct HarnessProtocolCodexCollaborationSetParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let modeID: String?
}

struct HarnessProtocolCodexRunLocationSetParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let runLocationID: String
}

struct HarnessProtocolCodexForkParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let newLocalSessionID: UUID
    var throughTurnID: String? = nil
}

struct HarnessProtocolCodexConversationEditParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let edit: ConversationEditState
}

struct HarnessProtocolCodexTurnRetryParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let expectedTurnID: String
}

/// Continues the turn Yardlet's quit or a lost connection cut off (`HarnessInterruptedTurnContinuing`).
/// `started` is false when the thread's own record says that turn had not ended that way. A peer
/// that sends no `cut` means the quit.
struct HarnessProtocolCodexTurnContinueParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    var cut: TurnCut? = nil
}

struct HarnessProtocolCodexTurnContinueResult: Codable, Equatable, Sendable {
    let started: Bool
    let activeTurnID: String?
}

struct HarnessProtocolCodexReviewStartParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let clientTurnID: String
    var target: CodexReviewTarget? = nil
}

struct HarnessProtocolCodexCompactParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
}

struct HarnessProtocolCodexThreadRenameParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let name: String
}

/// A name for a task from its recent conversation (`HarnessTaskTitleSuggesting`); no session is needed.
struct HarnessProtocolCodexTaskTitleSuggestParams: Codable, Equatable, Sendable {
    let excerpt: String
}

struct HarnessProtocolCodexTaskTitleSuggestResult: Codable, Equatable, Sendable {
    let title: String
}

enum HarnessProtocolCodexServerResponseKind: String, Codable, Equatable, Sendable {
    case command
    case fileChange = "file_change"
    case permissions
    case toolUserInput = "tool_user_input"
    case mcpElicitation = "mcp_elicitation"
    case dynamicToolCall = "dynamic_tool_call"
    case legacyReview = "legacy_review"
}

struct HarnessProtocolCodexServerResponse: Codable, Equatable, Sendable {
    let kind: HarnessProtocolCodexServerResponseKind
    let decision: JSONValue?
    let permissions: JSONValue?
    let scope: String?
    let strictAutoReview: Bool?
    let answers: [String: [String]]?
    let action: String?
    let content: JSONValue?
    let contentItems: [JSONValue]?
    let success: Bool?
    /// An MCP elicitation answer's `_meta` (Computer Use reads `persist` there).
    var meta: JSONValue? = nil
}

struct HarnessProtocolCodexServerRequestRespondParams: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let requestID: String
    let response: HarnessProtocolCodexServerResponse
}
