import Foundation
import Observation

/// An archived task's conversation shown read-only, as the Codex app previews an archived chat and
/// the Claude app opens an archived session: read from the provider's own history with the task's
/// provider session ID, account and storage scope, the way opening a detached task reads it
/// (`AppModel.readArchivedConversation`). Nothing resumes, attaches, sends or saves, and the task
/// stays archived until the person unarchives it. The window that shows it holds it, and nothing of
/// it is left once the window lets it go.
@MainActor
@Observable
final class ArchivedTaskReading {
    enum Outcome: Equatable {
        case reading
        case shown
        /// Yardlet does not read this harness's saved conversations.
        case unsupported
        /// Nothing could be read: the history, its runtime or its account is gone.
        case unavailable
    }

    let record: ArchivedSessionRecord
    private(set) var transcript = TranscriptTurns.empty
    private(set) var codexState: CodexTaskState?
    private(set) var outcome: Outcome
    /// What the reads of a Claude transcript covered, from which earlier turns are read
    /// (`ClaudeTranscriptWindow`).
    var claudeWindow: ClaudeTranscriptWindow?
    /// Earlier turns are being read, so a second scroll to the top waits for them.
    var isReadingEarlier = false

    var session: SessionRecord { record.session }

    init(record: ArchivedSessionRecord) {
        self.record = record
        outcome = AppModel.readsSavedConversation(of: record.session.harness) ? .reading : .unsupported
    }

    /// The provider's history holds turns before the ones read.
    var hasEarlierHistory: Bool {
        if let thread = codexState?.thread { return thread.turnsNextCursor != nil }
        return claudeWindow?.hasEarlierRecords ?? false
    }

    func show(_ entries: [TranscriptEntry]) {
        transcript = transcript.entries.isEmpty ? TranscriptTurns(entries) : transcript.updated(to: entries, change: .unknown)
    }

    func show(_ state: CodexTaskState) {
        codexState = state
    }

    /// The first read is over: the conversation shows what it found, or says it found nothing.
    func finishReading() {
        guard outcome == .reading else { return }
        let hasTurns = codexState?.thread?.turns.isEmpty == false || !transcript.entries.isEmpty
        outcome = hasTurns ? .shown : .unavailable
    }
}
