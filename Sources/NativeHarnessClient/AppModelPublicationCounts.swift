import Foundation

/// How often the app model handed new task state to its views. Plain counters the concurrent
/// streaming benchmark reads; the app itself never does.
struct AppModelPublicationCounts: Equatable, Sendable {
    /// Transcript arrays published for any task, and the part of them for tasks not shown.
    var transcripts = 0
    var backgroundTranscripts = 0
    /// Codex typed timeline states published for any task, and those for tasks not shown.
    var codexStates = 0
    var backgroundCodexStates = 0
    /// Provider events the main actor took, each a wake of the main thread (`AppModel.accept`).
    var events = 0
}
