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

    /// The thought currently streaming in the turn, shown as a compact muted excerpt under the live
    /// line while the line stays folded.
    struct ThinkingPreview: Equatable, Sendable {
        let itemID: String
        /// The thought's full text as last projected; the live line prefers `ConversationStreamedText`
        /// so streaming fragments update only the excerpt without redrawing the turn.
        let text: String
    }

    let activity: Activity
    /// The turn's calls so far.
    let steps: Int
    /// The calls the line stands for and opens into: the turn's last run while one of its calls runs.
    let items: [ConversationItem]
    /// Summary of completed calls already folded into `items`, kept visible above the live line so
    /// completed work does not vanish when a multi-step run grows past one call.
    var completedSummary: String? = nil
    /// The active streaming thought, when the provider is thinking with words to preview.
    var thinkingPreview: ThinkingPreview? = nil

    /// The live line of a running turn; nil for a turn that is not running.
    /// `stepsBefore` counts the calls of the turn's parts drawn before this one (`ConversationTurnRows`).
    static func make(_ turn: ConversationTurn, harness: HarnessKind, workspaceURL: URL?,
                     stepsBefore: Int = 0) -> ConversationLiveWork? {
        guard turn.status == .running else { return nil }
        let runs = ConversationWorkGrouping.runs(turn.work)
        let live = liveRun(runs)
        let steps = stepsBefore + turn.work.filter { ConversationWorkSummary.category(of: $0) != nil }.count
        let currentActivity = activity(turn, liveItems: live, harness: harness, workspaceURL: workspaceURL)
        return ConversationLiveWork(
            activity: currentActivity,
            steps: steps,
            items: live,
            completedSummary: completedSummary(for: live, harness: harness),
            thinkingPreview: thinkingPreview(turn, liveItems: live, activity: currentActivity)
        )
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

    /// Combined non-empty text of a reasoning item (summary before detail).
    static func thoughtText(of item: ConversationItem) -> String? {
        guard case let .reasoning(summary, detail, _) = item.kind else { return nil }
        let parts = [summary, detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Compact tail excerpt of a streaming thought: scans backwards from the end so work per
    /// streaming chunk stays O(1) regardless of total thought length. Wide CJK/Hangul characters
    /// count as two display units so Korean thoughts stay within the preview's three-line cap.
    static func thinkingExcerpt(from text: String, maxLines: Int = 3, maxCharacters: Int = 180) -> String? {
        guard maxLines > 0, maxCharacters > 0, !text.isEmpty else { return nil }
        var collectedLines: [Substring] = []
        var usedUnits = 0
        var clippedWithinLine = false
        var cursor = text.endIndex

        while cursor > text.startIndex, collectedLines.count < maxLines {
            // Skip trailing newlines.
            while cursor > text.startIndex {
                let prev = text.index(before: cursor)
                if text[prev].isNewline { cursor = prev } else { break }
            }
            guard cursor > text.startIndex else { break }

            let remainingUnits = maxCharacters - usedUnits - (collectedLines.isEmpty ? 0 : 1)
            guard remainingUnits > 0 else { break }

            // Walk backwards through this line, stopping at a newline or once the display-unit budget is exceeded.
            let lineEnd = cursor
            var trimmedEnd = lineEnd
            var foundNonWhitespace = false
            var lineUnits = 0
            var lineStart = lineEnd
            var hitBudget = false

            while lineStart > text.startIndex {
                let prev = text.index(before: lineStart)
                let character = text[prev]
                if character.isNewline { break }
                if !foundNonWhitespace {
                    if character.isWhitespace {
                        trimmedEnd = prev
                        lineStart = prev
                        continue
                    }
                    foundNonWhitespace = true
                }
                let weight = displayUnitWeight(of: character)
                if lineUnits + weight > remainingUnits {
                    hitBudget = hasEarlierContentOnLine(in: text, before: lineStart)
                    break
                }
                lineUnits += weight
                lineStart = prev
            }

            if !foundNonWhitespace {
                // Whitespace-only line; continue scanning earlier lines.
                cursor = lineStart
                continue
            }

            var slice = text[lineStart..<trimmedEnd]
            if hitBudget {
                if let boundary = slice.firstIndex(where: { $0.isWhitespace }),
                   slice.distance(from: slice.startIndex, to: boundary) <= 24 {
                    let after = slice.index(after: boundary)
                    if after < slice.endIndex { slice = slice[after...] }
                }
                slice = trimLeadingSpaces(slice)
                if !slice.isEmpty {
                    collectedLines.append(slice)
                    clippedWithinLine = true
                }
                break
            } else {
                slice = trimLeadingSpaces(slice)
                if !slice.isEmpty {
                    collectedLines.append(slice)
                    usedUnits += lineUnits + (collectedLines.count > 1 ? 1 : 0)
                }
                cursor = lineStart
            }
        }

        guard !collectedLines.isEmpty else { return nil }
        let joined = collectedLines.reversed().joined(separator: "\n")
        return clippedWithinLine ? "…" + joined : joined
    }

    private static func hasEarlierContentOnLine(in text: String, before index: String.Index) -> Bool {
        var cursor = index
        var inspected = 0
        while cursor > text.startIndex, inspected < 64 {
            let prev = text.index(before: cursor)
            let character = text[prev]
            if character.isNewline { return false }
            if !character.isWhitespace { return true }
            cursor = prev
            inspected += 1
        }
        return cursor > text.startIndex && inspected >= 64
    }

    private static func trimLeadingSpaces(_ substring: Substring) -> Substring {
        var start = substring.startIndex
        while start < substring.endIndex, substring[start].isWhitespace {
            start = substring.index(after: start)
        }
        return substring[start...]
    }

    private static func displayUnitWeight(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        switch scalar.value {
        case 0x1100...0x11FF, 0x2E80...0x9FFF, 0xAC00...0xD7AF,
             0xF900...0xFAFF, 0xFE10...0xFE6F, 0xFF00...0xFF60, 0x20000...0x2FA1F:
            return 2
        default:
            return 1
        }
    }

    private static func completedSummary(for liveItems: [ConversationItem], harness: HarnessKind) -> String? {
        let completedCalls = liveItems.filter {
            $0.phase != .running && ConversationWorkSummary.category(of: $0) != nil
        }
        guard !completedCalls.isEmpty else { return nil }
        let title = ConversationWorkSummary.title(for: completedCalls, harness: harness)
        return title.isEmpty ? nil : title
    }

    private static func thinkingPreview(
        _ turn: ConversationTurn, liveItems: [ConversationItem], activity: Activity
    ) -> ThinkingPreview? {
        guard activity == .thinking else { return nil }
        let candidate = liveItems.last(where: isStreamingThought)
            ?? turn.work.last.flatMap { isStreamingThought($0) ? $0 : nil }
        guard let candidate, let text = thoughtText(of: candidate) else { return nil }
        return ThinkingPreview(itemID: candidate.id, text: text)
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
