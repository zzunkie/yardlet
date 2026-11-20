import SwiftUI

/// The line under a running turn's work that says what the provider is doing when its output does
/// not (B7): retrying its response stream — Codex's reconnects, and Claude Code's `api_retry`, which
/// moved here from above the composer (D6) — or thinking before its first output.
///
/// Where notices go, for every harness:
/// - this status line: reconnecting, retrying, thinking;
/// - the turn's cards: errors and plan limits (`TranscriptErrorCard`, `UsageLimitCard`), compactions
///   (`CompactionMarker`), and the provider's own notices (`CodexNoticeRow`);
/// - above the composer (`TaskDetail`): the limit warning, the edit banner, the Codex status panel;
/// - at the bottom of the window: the worktree notice and the bootstrap error.
struct ConversationTurnStatusLine: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let progress: ConversationTurnProgress

    var body: some View {
        switch progress {
        case let .reconnecting(status):
            Label(status, systemImage: "arrow.clockwise")
                .font(.system(size: 12 * interfaceScale))
                .foregroundStyle(.secondary)
        case .thinking:
            Text(L10n.string("Thinking"))
                .font(.system(size: 12 * interfaceScale))
                .foregroundStyle(.tertiary)
        case .none:
            EmptyView()
        }
    }
}
