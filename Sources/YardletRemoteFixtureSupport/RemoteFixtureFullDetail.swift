import Foundation
import YardletRemote

/// What the fixture's conversations hold in full detail (docs/REMOTE_PROTOCOL.md §15.24, §15.31), beyond the phone's
/// projection a basic subscription reads: the pictures a message sent and a tool made, the release build's output
/// while it runs, a thought process, two subagents' cards, a compaction, a provider's notice and a plan limit's windows.
enum RemoteFixtureFullDetail {
    /// An item as a basic subscription carries it (§6): without what only full detail reads, and a subagent's card only
    /// as far as its Stop and Open child task go, which every subscription carries.
    static func basic(_ item: RemoteItem) -> RemoteItem {
        guard item.images != nil || item.body != nil || item.compaction != nil || item.providerNotice != nil
            || item.limit != nil || item.subagent != nil else { return item }
        var item = item
        item.images = nil
        item.body = nil
        item.compaction = nil
        item.providerNotice = nil
        item.limit = nil
        if let card = item.subagent {
            var kept = RemoteSubagent(taskIds: card.taskIds)
            kept.activityId = card.activityId
            kept.canStop = card.canStop
            item.subagent = kept == RemoteSubagent() ? nil : kept
        }
        return item
    }

    // MARK: - Pictures

    /// A page with the site's footer at a phone's width in points, as a screenshot's small preview: at 320 points
    /// Privacy and Terms wrap to a second line.
    static func footer(width points: Int) -> RemoteImagePreview {
        let width = points * 2 / 3
        let height = 400
        var picture = RemoteFixturePicture(width: width, height: height, palette: palette)
        picture.fill(x: 0, y: 0, width: width, height: 30, color: Color.header.rawValue)
        picture.text("Website", x: 10, y: 11, scale: 1, color: Color.white.rawValue)
        for (index, line) in [0.8, 0.6, 0.7, 0.45, 0.75, 0.5].enumerated() {
            picture.fill(x: 12, y: 50 + index * 26, width: Int(Double(width - 24) * line), height: 10, color: Color.line.rawValue)
        }
        // The footer's links, as many to a line as fit.
        var lines: [String] = []
        for link in ["Docs", "Blog", "Privacy", "Terms"] {
            if let last = lines.last, RemoteFixturePicture.width(of: last + "   " + link, scale: 1) <= width - 24 {
                lines[lines.count - 1] = last + "   " + link
            } else {
                lines.append(link)
            }
        }
        let top = height - 22 - lines.count * 14
        picture.fill(x: 0, y: top, width: width, height: height - top, color: Color.footer.rawValue)
        picture.fill(x: 0, y: top, width: width, height: 1, color: Color.line.rawValue)
        for (index, line) in lines.enumerated() {
            picture.text(line, x: 12, y: top + 11 + index * 14, scale: 1, color: Color.accent.rawValue)
        }
        return RemoteImagePreview(type: "image/png", data: picture.png, name: "footer-\(points).png")
    }

    private enum Color: UInt8 {
        case white, header, line, footer, accent
    }

    private static let palette: [(UInt8, UInt8, UInt8)] = [
        (0xFF, 0xFF, 0xFF), (0x24, 0x29, 0x2F), (0xD1, 0xD9, 0xE0), (0xF6, 0xF8, 0xFA), (0x09, 0x69, 0xDA)
    ]

    // MARK: - Lines

    /// The release build's command, and what it prints a line at a time while it runs.
    static let buildCommand = "swift build -c release"
    static let buildOutput = ["Fetching dependencies", "Computing version for swift-collections"]
        + ["Collections", "Remote", "Conversation", "Sidebar", "MenuBar", "Settings", "Review", "Terminal", "Browser",
           "Updates"].enumerated().map { index, module in "[\(index + 1)/12] Compiling Yardlet\(module)" }
        + ["[11/12] Linking Yardlet", "[12/12] Applying Yardlet", "Build complete! (128.4s)"]

    static func build(_ command: inout RemoteItem, output: String) {
        var body = command.body ?? RemoteConversationBody()
        body.command = buildCommand
        body.output = output
        command.body = body
    }

    /// The ID the approval task's subagent reads and stops by (§15.31 `subtask`).
    static let reviewerID = "agent_fixture_review"

    /// A Claude Code subagent reviewing the migration in the background while the approval waits; it can be stopped.
    static func reviewer(_ turnID: String) -> RemoteItem {
        var item = RemoteItem(id: "i:\(turnID)-reviewer", turnId: turnID, kind: .activity)
        item.inWork = true
        item.activity = "subagent"
        item.title = "Review the migration for data loss"
        item.status = "running"
        var card = RemoteSubagent(kind: "Agent", input: "Read the new migration in SessionRepository.swift and tell me "
                                  + "whether any path can drop a session row.", model: "claude-haiku-4-5", background: true)
        card.activityId = reviewerID
        card.canStop = true
        item.subagent = card
        return item
    }

    /// The reviewer once stopped, with what it said before.
    static func stopped(_ reviewer: RemoteItem) -> RemoteItem {
        var item = reviewer
        item.status = "stopped"
        item.subagent?.canStop = nil
        item.subagent?.output = "Stopped before it finished. So far no path drops a row."
        return item
    }

    /// The reviewer's own conversation, as the Mac's subtask pane reads it.
    static func reviewTranscript() -> RemoteSubtaskTranscript {
        let turnID = "review-1"
        var prompt = RemoteItem(id: "i:\(turnID)-user", turnId: turnID, kind: .user)
        prompt.text = "Read the new migration in SessionRepository.swift and tell me whether any path can drop a session row."
        var read = RemoteItem(id: "i:\(turnID)-read", turnId: turnID, kind: .activity)
        read.activity = "tool"
        read.title = "Read SessionRepository.swift"
        read.status = "completed"
        var search = RemoteItem(id: "i:\(turnID)-grep", turnId: turnID, kind: .activity)
        search.activity = "command"
        search.title = "Ran grep -n \"DELETE\" Sources/Index"
        search.status = "completed"
        search.exitCode = 0
        var note = RemoteItem(id: "i:\(turnID)-note", turnId: turnID, kind: .assistant)
        note.role = "commentary"
        note.text = "The migration copies each row before it drops the old table. Checking the rollback next."
        return RemoteSubtaskTranscript(items: [prompt, read, search, note])
    }

    /// A Codex subagent the footer task ran, whose child thread is "Check the footer on mobile".
    static func mobileChecker(_ turnID: String, childTask: String) -> RemoteItem {
        var item = RemoteItem(id: "i:\(turnID)-agent", turnId: turnID, kind: .activity)
        item.inWork = true
        item.activity = "subagent"
        item.title = "Check the footer on mobile"
        item.status = "completed"
        item.subagent = RemoteSubagent(
            kind: "spawn_agent", input: "Check the footer at 375 pt and at 320 pt, and tell me which links wrap.",
            output: "At 375 pt the footer fits on one line. At 320 pt **Privacy** and **Terms** wrap to a second line.",
            model: "gpt-5.5", harnessLabel: "Codex · gpt-5.5", taskIds: [childTask])
        return item
    }

    /// A screenshot tool line with the picture it took, and the tool's words and picture as its result.
    static func screenshot(_ turnID: String) -> RemoteItem {
        let picture = footer(width: 320)
        var item = RemoteItem(id: "i:\(turnID)-screenshot", turnId: turnID, kind: .activity)
        item.inWork = true
        item.activity = "tool"
        item.title = "Took a screenshot at 320 pt"
        item.status = "completed"
        item.imageCount = 1
        item.images = [picture]
        var body = RemoteConversationBody()
        body.toolName = "browser_screenshot"
        body.mcp = [.init(kind: "text", text: "Privacy and Terms wrap to a second line at 320 pt."),
                    .init(kind: "image", image: picture)]
        item.body = body
        return item
    }

    /// The last crash summary's thought process, the compaction before it and the model its request went to.
    static func crashNotes(_ turnID: String) -> (notices: [RemoteItem], reasoning: RemoteItem) {
        var compaction = RemoteItem(id: "i:\(turnID)-compacted", turnId: turnID, kind: .notice)
        compaction.text = "Compacted session · saved 138K tokens"
        compaction.compaction = RemoteCompaction(phase: "completed", tokensBefore: 180_000, tokensAfter: 42_000)
        var rerouted = RemoteItem(id: "i:\(turnID)-rerouted", turnId: turnID, kind: .notice)
        rerouted.text = "Your request was routed to gpt-5.5."
        rerouted.providerNotice = RemoteProviderNotice(kind: "modelRerouted", message: "gpt-5.5", fromModel: "gpt-6",
                                                       reason: "highRiskCyberActivity")
        var reasoning = RemoteItem(id: "i:\(turnID)-reasoning", turnId: turnID, kind: .activity)
        reasoning.inWork = true
        reasoning.activity = "reasoning"
        reasoning.title = "Thought process"
        reasoning.status = "completed"
        reasoning.detail = "Grouping the crashes by their top frame"
        var body = RemoteConversationBody()
        body.reasoning = """
        **Grouping the crashes by their top frame**

        All thirty reports stop in `TaskSidebar.row(for:)`. The ones from this week have `archiveTask` on the stack \
        right below it, so the row is read after its task left the list. That points at the archive animation, not \
        the index.
        """
        reasoning.body = body
        return ([compaction, rerouted], reasoning)
    }

    /// The session limit that stopped the migration guide, with the account's other window.
    static func limit(now: Date) -> RemoteLimit {
        RemoteLimit(status: "rejected", window: "session", usedFraction: 1, windows: [
            .init(window: "session", usedFraction: 1, resetsAt: RemoteJSON.milliseconds(now.addingTimeInterval(2 * 3600))),
            .init(window: "weekly", usedFraction: 0.62,
                  resetsAt: RemoteJSON.milliseconds(now.addingTimeInterval(3 * 86_400 + 5 * 3600)))
        ])
    }
}
