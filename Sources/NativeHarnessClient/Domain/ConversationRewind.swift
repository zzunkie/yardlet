import Foundation

struct ConversationEditState: Codable, Equatable, Sendable {
    let id: UUID
    let harness: HarnessKind
    let originalProviderSessionID: String
    let scope: SessionEnvironmentScope
    let connection: ProviderConnection?
    let workspaceURL: URL
    let targetID: String
    let previousID: String?
    let originalText: String
    let previousDraftText: String
    let previousDraftAttachments: [CodexUserInput]
    let originalEntries: [TranscriptEntry]
    var preparedProviderSessionID: String?
    var plannedProviderSessionID: String?
    var originalInputFingerprint: String?
    /// A Codex request the Codex app wrote its context around: the composer edits the request alone,
    /// and the edit sends this context and marker again before it (`CodexUserPrompt`).
    var codexRequestPrefix: String?

    init(session: SessionRecord, targetID: String, previousID: String?, originalText: String,
         draft: TaskDraftSnapshot, entries: [TranscriptEntry]) {
        id = UUID()
        harness = session.harness
        originalProviderSessionID = session.providerSessionID ?? ""
        scope = session.environmentScope
        connection = session.connection
        workspaceURL = session.workspaceURL
        self.targetID = targetID
        self.previousID = previousID
        self.originalText = originalText
        previousDraftText = draft.text
        previousDraftAttachments = draft.attachments
        originalEntries = Array(entries.suffix(500))
    }

    func matches(_ session: SessionRecord) -> Bool {
        session.harness == harness && session.environmentScope == scope && session.connection == connection
            && session.workspaceURL == workspaceURL
            && (session.providerSessionID == (preparedProviderSessionID ?? originalProviderSessionID)
                || (preparedProviderSessionID == nil && plannedProviderSessionID.map { session.providerSessionID == $0 } == true))
    }
}

protocol CodexConversationEditing: Actor {
    /// Only the latest native user turn can be replaced. A prepared prefix is recognized on
    /// retry, so a lost acknowledgement cannot cause a second history deletion.
    func prepareConversationEdit(_ edit: ConversationEditState, in session: HarnessSessionHandle) async throws
}

struct ClaudeConversationPoint: Equatable, Identifiable, Sendable {
    let id: String
    let text: String
    let previousAssistantID: String?
    let hasAttachments: Bool
    let precedingEntries: [TranscriptEntry]
    var imageInputs: [CodexUserInput]? = []
    var inputFingerprint: String? = nil
}

struct HarnessFileRewindResult: Codable, Equatable, Sendable {
    let canRewind: Bool
    let error: String?
    let filesChanged: [String]?
    let insertions: Int?
    let deletions: Int?
    let skippedLinks: Int?
    let inFlight: Bool?
}

typealias HarnessFileRestoreAuthorization = @Sendable () throws -> Void

protocol HarnessFileRewinding: Actor {
    func previewFileRewind(userMessageID: String, in session: HarnessSessionHandle) async throws -> HarnessFileRewindResult
    func restoreFiles(userMessageID: String, expecting preview: HarnessFileRewindResult,
        in session: HarnessSessionHandle, authorizing: HarnessFileRestoreAuthorization?) async throws -> HarnessFileRewindResult
}

extension HarnessFileRewinding {
    func restoreFiles(userMessageID: String, expecting preview: HarnessFileRewindResult,
                      in session: HarnessSessionHandle) async throws -> HarnessFileRewindResult {
        try await restoreFiles(userMessageID: userMessageID, expecting: preview, in: session, authorizing: nil)
    }
}

protocol HarnessConversationQuiescing: Actor {
    func requireReadyForRewind(in session: HarnessSessionHandle) async throws
}

/// Local receipt for the user's reviewed provider preview. Not a permission or model message.
struct FileRewindPreview: Equatable, Identifiable, Sendable {
    let id: UUID
    let session: SessionRecord
    let point: ClaudeConversationPoint
    let result: HarnessFileRewindResult
    let fileFingerprints: [String: String]
}
