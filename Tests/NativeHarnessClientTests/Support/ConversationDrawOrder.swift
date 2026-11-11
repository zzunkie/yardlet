import Foundation
@testable import NativeHarnessClient

/// A turn's parts in the order `ConversationTurnView` draws them, one row each: what was sent, the
/// notices, the work (listed while it shows; once it folds, what stays in view, with a fold row where
/// a message sent into the turn parts it), the answers, the live line and the requests still waiting.
/// For listing a turn as the person reads it.
enum ConversationDrawOrder {
    struct Row: CustomStringConvertible {
        /// Where the turn draws it: prompt, notice, work, kept (in view over folded work), fold (the
        /// fold of the work after a message sent into the turn, its ID the stretch's), answer, live
        /// (the live line's own call) or request.
        let part: String
        let id: String
        /// The item's shape: message, commentary, answer, call, reasoning, request, …
        let shape: String
        let text: String

        var description: String {
            "\(part.padding(toLength: 7, withPad: " ", startingAt: 0)) \(shape.padding(toLength: 20, withPad: " ", startingAt: 0)) \(text)"
        }
    }

    /// `folded` nil draws the turn as it starts: folded once its work folds.
    static func rows(_ turn: ConversationTurn, harness: HarnessKind, folded: Bool? = nil) -> [Row] {
        let folds = folded ?? turn.foldsWork
        var rows: [Row] = []
        func add(_ part: String, _ items: [ConversationItem]) {
            rows += items.map { Row(part: part, id: $0.id, shape: shape(of: $0), text: text(of: $0)) }
        }
        add("prompt", turn.prompt)
        add("notice", turn.notices)
        if !folds {
            add("work", ConversationLiveWork.listedRuns(turn).flatMap(items))
        } else {
            for stretch in stretches(turn, harness: harness) {
                add("kept", [stretch.message].compactMap { $0 })
                if stretch.message != nil, stretch.hidesWork {
                    rows.append(Row(part: "fold", id: stretch.id, shape: "fold", text: L10n.string("Work details")))
                }
                add("kept", ConversationWorkGrouping.runs(stretch.kept).flatMap(items))
            }
        }
        add("answer", turn.answers)
        if let live = ConversationLiveWork.make(turn, harness: harness, workspaceURL: nil) {
            rows.append(Row(part: "live", id: "live", shape: "line", text: live.activity.text))
            add("live", live.items)
        }
        rows += turn.requests.map { Row(part: "request", id: $0.id, shape: "request", text: $0.title) }
        return rows
    }

    static func listing(_ turn: ConversationTurn, harness: HarnessKind, folded: Bool? = nil) -> String {
        rows(turn, harness: harness, folded: folded).map(\.description).joined(separator: "\n")
    }

    /// The stretches a folded turn draws, the live line's calls left out.
    static func stretches(_ turn: ConversationTurn, harness: HarnessKind) -> [ConversationWorkStretch] {
        ConversationWorkGrouping.stretchesWhenFolded(
            turn, live: ConversationLiveWork.make(turn, harness: harness, workspaceURL: nil)
        )
    }

    /// What a folded turn keeps in view of its work, in the runs it draws.
    static func keptRuns(_ turn: ConversationTurn, harness: HarnessKind) -> [ConversationWorkGrouping.Run] {
        stretches(turn, harness: harness).flatMap { ConversationWorkGrouping.runs([$0.message].compactMap { $0 } + $0.kept) }
    }

    private static func items(_ run: ConversationWorkGrouping.Run) -> [ConversationItem] {
        switch run {
        case let .single(item): [item]
        case let .group(items), let .suggestions(items): items
        }
    }

    static func shape(of item: ConversationItem) -> String {
        switch item.kind {
        case .userMessage: item.taskMessage == nil ? "message" : "task message"
        case .scheduledTaskMessage: "scheduled message"
        case .shellCommand: "shell command"
        case let .answer(_, isStreaming): isStreaming ? "answer (streaming)" : "answer"
        case let .commentary(_, isStreaming): isStreaming ? "commentary (streaming)" : "commentary"
        case .reasoning: "reasoning"
        case .proposedPlan: "plan"
        case .command, .fileChange, .tool, .subagent: item.phase == .running ? "call (running)" : "call"
        case .taskSuggestion: "suggestion"
        case .scheduleCreated: "schedule"
        case .settingChanged: "setting"
        case .notice: "notice"
        case .compaction: "compaction"
        case .request: "request"
        case .outcome: "outcome"
        }
    }

    static func text(of item: ConversationItem) -> String {
        let text: String = switch item.kind {
        case let .userMessage(text, _), let .answer(text, _), let .commentary(text, _), let .proposedPlan(text, _): text
        case let .scheduledTaskMessage(message): message.instructions
        case let .command(command): command.command
        case let .tool(tool): tool.name
        case let .subagent(subagent): subagent.title
        case let .reasoning(summary, detail, _): summary ?? detail ?? ""
        case let .request(request): request.title
        default: ""
        }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 70 ? String(line.prefix(69)) + "…" : line
    }
}
