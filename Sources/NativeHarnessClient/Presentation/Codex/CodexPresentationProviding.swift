import Foundation

protocol CodexPresentationProviding: Actor {
    func presentationState(for session: HarnessSessionHandle) throws -> CodexTaskState
    func refreshPresentationState(for session: HarnessSessionHandle) async throws -> CodexTaskState
    func loadTurns(
        for session: HarnessSessionHandle,
        cursor: String?,
        limit: Int64?
    ) async throws -> CodexTurnPage
    func loadItems(
        for session: HarnessSessionHandle,
        turnID: String?,
        cursor: String?,
        limit: Int64?
    ) async throws -> CodexItemPage
    /// Ends when the session's events end: the protocol bridge closes a session's stream only after this one.
    func presentationStates(
        for session: HarnessSessionHandle
    ) async throws -> AsyncStream<CodexTaskState>
    func respond(
        to serverRequestID: String,
        response: CodexServerRequestResponse,
        in session: HarnessSessionHandle
    ) async throws
}

/// Reads a saved Codex thread for display without loading it: `thread/read` and
/// `thread/turns/list`, and no `thread/resume`, no turn and no session handle. A detached task shows
/// its newest turns this way when it is opened, before anything connects it, and brings in earlier
/// pages as the person scrolls up (docs/NATIVE_SESSION_STORAGE.md).
protocol CodexThreadReading: Actor {
    /// The thread without its turns, then its newest `newestTurns` with the cursor for the turns
    /// before them (`turnsNextCursor`). Nil reads every turn with the thread (`includeTurns`).
    func readThreadPresentation(threadID: String, newestTurns: Int64?) async throws -> CodexTaskState
    /// The page of `limit` turns before `cursor` (nil: the newest), oldest first, with the cursor for
    /// the turns before it.
    func readThreadTurns(threadID: String, cursor: String?, limit: Int64) async throws -> CodexTurnPage
}

/// How many turns a detached Codex task reads at a time (docs/NATIVE_SESSION_STORAGE.md).
enum CodexThreadPaging {
    /// The newest turns a detached task shows when it is opened, and reads again when its thread
    /// changes: enough to fill the conversation.
    static let newestTurns: Int64 = 5
    /// The turns each earlier page brings in as the person scrolls up, attached or not.
    static let earlierTurns: Int64 = 10
}
