import Foundation

/// The task's last error, shown under its conversation where the conversation does not draw it.
///
/// A conversation drawn from the shared transcript shows Yardlet's own failures inline, so only an
/// empty one needs the card. A Codex thread is drawn from the provider's turns instead, which
/// carry the provider's turn errors but none of Yardlet's: a refused `thread/resume`, `turn/start`
/// or `turn/steer`, a reply that could not be used, an App Server that ended or did not answer. Those
/// show here. A turn's own error is already on that turn and is not repeated, also while a later
/// turn runs: a retry, or a turn Codex started itself.
enum TaskErrorNotice {
    static func message(
        _ error: String?,
        harness: HarnessKind,
        entries: [TranscriptEntry],
        codexTaskState: CodexTaskState?
    ) -> String? {
        guard let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if entries.isEmpty { return error }
        guard HarnessPresentationPolicy(harness: harness).usesCodexTimeline,
              let turns = codexTaskState?.thread?.turns, !turns.isEmpty else { return nil }
        if turns.contains(where: { CodexTurnErrorPresentation($0.error)?.text == error }) { return nil }
        return error
    }
}
