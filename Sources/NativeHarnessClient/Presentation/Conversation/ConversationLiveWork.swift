import Foundation

/// The one line under a running turn that says what the provider is doing now (decision of
/// 2026-10-16: tool lines piled up too much, the progress line was unclear, and a running call
/// should not open), as the Codex app's activity header shows only its current item
/// ("Running swift test", "Thinking") and the Claude app's working line its state and time
/// ("Working… · 12s"). It tells thinking, running a call and waiting on the person apart; it counts
/// the turn's calls and how long the turn has run, which the turn header does not read while the
/// turn runs.
///
/// The calls of the turn's last run, while one of them runs, are this line's: they are not also
/// listed above it, and they open under it on a click. Every other run stays folded on its summary
/// line (`ConversationWorkDisclosure`), so a running turn reads as its words, folded summaries and
/// this one line. Requests waiting on the person stay pinned under the turn, as before. What the
/// person opened or folded under the line stays so when its run settles into the listed work
/// (`ConversationDisclosureChoices`).
struct ConversationLiveWork: Equatable {
    enum Activity: Equatable {
        /// The provider is working with no call running: its answer or its next step.
        case working
        /// The provider is thinking (Claude Code's thinking stream, Codex's reasoning).
        case thinking
        /// A call runs, in its line's own words ("Running swift test", "Reading Parser.swift").
        case running(ConversationLineWords)
        /// A request waits for the person to allow it.
        case waitingForApproval
        /// A question or plan waits for the person's answer.
        case waitingForAnswer
        /// The provider's stream is reconnecting or retrying, in its own words.
        case reconnecting(String)

        /// What the line says.
        var text: String {
            switch self {
            case .working: L10n.string("Working")
            case .thinking: L10n.string("Thinking")
            case let .running(words): words.text
            case .waitingForApproval: L10n.string("Awaiting approval")
            case .waitingForAnswer: L10n.string("Waiting for your answer")
            case let .reconnecting(status): status
            }
        }

        /// The provider is the one at work: the line shimmers, as both apps' working lines do.
        var isProviderWorking: Bool {
            switch self {
            case .working, .thinking, .running: true
            case .waitingForApproval, .waitingForAnswer, .reconnecting: false
            }
        }

        /// The person is the one who has to act.
        var isWaitingOnPerson: Bool {
            self == .waitingForApproval || self == .waitingForAnswer
        }

        /// The mark the line leads with, one for each kind of state so that thinking, a running
        /// call and waiting on the person read apart before their words do.
        var mark: Mark {
            switch self {
            case .thinking: .thinking
            case .working, .running: .working
            case .waitingForApproval, .waitingForAnswer: .waitingOnPerson
            case .reconnecting: .reconnecting
            }
        }
    }

    enum Mark: Equatable {
        case thinking
        case working
        case waitingOnPerson
        case reconnecting
    }

    let activity: Activity
    /// The turn's calls so far.
    let steps: Int
    /// The calls the line stands for and opens into: the turn's last run while one of its calls runs.
    let items: [ConversationItem]

    /// The live line of a running turn; nil for a turn that is not running.
    static func make(_ turn: ConversationTurn, harness: HarnessKind, workspaceURL: URL?) -> ConversationLiveWork? {
        guard turn.status == .running else { return nil }
        let runs = ConversationWorkGrouping.runs(turn.work)
        let live = liveRun(runs)
        let steps = turn.work.filter { ConversationWorkSummary.category(of: $0) != nil }.count
        return ConversationLiveWork(activity: activity(turn, liveItems: live, harness: harness, workspaceURL: workspaceURL),
                                    steps: steps, items: live)
    }

    /// The runs listed above the live line: all of the turn's runs but the one the line stands for.
    static func listedRuns(_ turn: ConversationTurn) -> [ConversationWorkGrouping.Run] {
        let runs = ConversationWorkGrouping.runs(turn.work)
        guard turn.status == .running, !liveRun(runs).isEmpty else { return runs }
        return Array(runs.dropLast())
    }

    /// The calls of the last run when one of them runs, or the thinking that streams now.
    private static func liveRun(_ runs: [ConversationWorkGrouping.Run]) -> [ConversationItem] {
        switch runs.last {
        case let .single(item)? where item.phase == .running && ConversationWorkSummary.category(of: item) != nil:
            [item]
        case let .single(item)? where isStreamingThought(item):
            [item]
        case let .group(items)? where items.contains(where: { $0.phase == .running }):
            items
        default:
            []
        }
    }

    private static func activity(
        _ turn: ConversationTurn, liveItems: [ConversationItem], harness: HarnessKind, workspaceURL: URL?
    ) -> Activity {
        if !turn.requests.isEmpty {
            let asksForAnswer = turn.requests.contains { request in
                switch request.form {
                case .choices, .freeText, .planReview, .mcpForm: true
                case nil: false
                }
            }
            return asksForAnswer ? .waitingForAnswer : .waitingForApproval
        }
        if case let .reconnecting(status) = turn.progress { return .reconnecting(status) }
        if let running = liveItems.last(where: { $0.phase == .running }),
           let words = words(for: running, harness: harness, workspaceURL: workspaceURL) {
            return .running(words)
        }
        if turn.progress == .thinking { return .thinking }
        if let last = turn.work.last, isStreamingThought(last) { return .thinking }
        return .working
    }

    private static func isStreamingThought(_ item: ConversationItem) -> Bool {
        if case let .reasoning(_, _, isStreaming) = item.kind { return isStreaming }
        return false
    }

    /// The running call's words, as its own line reads them.
    static func words(for item: ConversationItem, harness: HarnessKind, workspaceURL: URL?) -> ConversationLineWords? {
        switch item.kind {
        case let .command(command):
            ConversationLineWording.command(command, phase: .running, harness: harness).first
        case let .tool(tool):
            ConversationLineWording.tool(tool, phase: .running, harness: harness, workspaceURL: workspaceURL)
        case .fileChange:
            ConversationWorkSummary.header(for: [item], harness: harness)
        default:
            nil
        }
    }

    /// "Running swift test · 5 steps · 1m 5s": the line's words after the activity, the step count
    /// and the elapsed time.
    static func detail(steps: Int, elapsed: String?) -> String {
        var parts: [String] = []
        if steps > 0 { parts.append(steps == 1 ? L10n.string("1 step") : L10n.format("%lld steps", steps)) }
        if let elapsed { parts.append(elapsed) }
        return parts.joined(separator: " · ")
    }
}
