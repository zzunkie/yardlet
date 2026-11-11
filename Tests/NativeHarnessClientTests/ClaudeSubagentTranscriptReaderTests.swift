import AppKit
import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

final class ClaudeSubagentTranscriptReaderTests: XCTestCase {
    private let parent = "11111111-2222-4333-8444-555555555555"

    func testOriginalConversationUsesAgentMetadataAndActiveChainWithoutWrites() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try fixture(root, agent: "actual", text: "Live child")
        let original = try Data(contentsOf: agent)
        let reference = HarnessSubtaskReference(taskID: "different-task-id", toolUseID: "tool", taskType: "local_agent")
        let reader = ClaudeSubagentTranscriptReader(configDirectory: root)
        let first = try reader.read(parentSessionID: parent, reference: reference)
        let text = first.entries.compactMap { entry -> String? in
            switch entry.content { case let .assistant(value, _), let .user(value, _): return value; default: return nil }
        }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Child request"))
        XCTAssertTrue(text.contains("Live child"))
        XCTAssertFalse(text.contains("Abandoned child"))
        XCTAssertFalse(first.isTruncated)
        let second = try reader.read(parentSessionID: parent, reference: reference)
        XCTAssertEqual(first.entries, second.entries, "Original UUID-derived identities preserve reading on refresh")
        XCTAssertEqual(try Data(contentsOf: agent), original)
    }

    func testSavedAccountHomeIsAuthoritative() throws {
        let a = try directory(), b = try directory()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        _ = try fixture(a, agent: "same", text: "Account A")
        _ = try fixture(b, agent: "same", text: "Account B")
        let binding = ProviderConnection(id: "saved-a", name: "A", harness: .claudeCode,
            providerID: nil, homePath: a.path, credentialSelector: nil)
        let selected = ClaudeSubagentTranscriptReader.configDirectory(connection: binding,
            environment: ["CLAUDE_CONFIG_DIR": b.path, "HOME": b.path])
        XCTAssertEqual(selected.path, a.path)
        let snapshot = try ClaudeSubagentTranscriptReader(configDirectory: selected).read(parentSessionID: parent,
            reference: .init(agentID: "same", taskType: "local_agent"))
        XCTAssertTrue(snapshot.entries.contains { if case let .assistant(text, _) = $0.content { text.contains("Account A") } else { false } })
        XCTAssertFalse(snapshot.entries.contains { if case let .assistant(text, _) = $0.content { text.contains("Account B") } else { false } })
    }

    func testSymlinkedChildAndDirectoryAndFifoCannotEscapeOrBlock() throws {
        let root = try directory(), outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let file = try fixture(root, agent: "linked", text: "Local")
        let privateFile = try fixture(outside, agent: "private", text: "Outside")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: privateFile)
        let reader = ClaudeSubagentTranscriptReader(configDirectory: root)
        XCTAssertTrue(try reader.read(parentSessionID: parent, reference: .init(agentID: "linked")).entries.isEmpty)
        let fifo = file.deletingLastPathComponent().appending(path: "agent-fifo.jsonl")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertTrue(try reader.read(parentSessionID: parent, reference: .init(agentID: "fifo")).entries.isEmpty)
        let subagents = file.deletingLastPathComponent()
        try FileManager.default.removeItem(at: subagents)
        try FileManager.default.createSymbolicLink(at: subagents, withDestinationURL: privateFile.deletingLastPathComponent())
        XCTAssertTrue(try reader.read(parentSessionID: parent, reference: .init(agentID: "private")).entries.isEmpty)
    }

    func testAccountFolderSharingProjectsThroughOneLinkReadsSharedHistory() throws {
        let shared = try directory(), account = try directory()
        defer { try? FileManager.default.removeItem(at: shared); try? FileManager.default.removeItem(at: account) }
        _ = try fixture(shared, agent: "shared", text: "Shared child")
        try FileManager.default.createSymbolicLink(at: account.appending(path: "projects"),
            withDestinationURL: shared.appending(path: "projects"))
        let snapshot = try ClaudeSubagentTranscriptReader(configDirectory: account)
            .read(parentSessionID: parent, reference: .init(agentID: "shared"))
        XCTAssertTrue(snapshot.entries.contains { if case let .assistant(text, _) = $0.content { text.contains("Shared child") } else { false } })
    }

    func testClaudeMillisecondTimestampsAreRead() {
        XCTAssertEqual(ClaudeSubagentTranscriptReader.timestamp("2026-10-07T18:38:17.123Z")?.timeIntervalSince1970 ?? 0,
            1_791_398_297.123, accuracy: 0.001)
        XCTAssertEqual(ClaudeSubagentTranscriptReader.timestamp("2026-10-07T18:38:17Z")?.timeIntervalSince1970, 1_791_398_297)
        XCTAssertNil(ClaudeSubagentTranscriptReader.timestamp("not a date"))
    }

    func testAmbiguousParentAndAgentMappingFailClosed() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixture(root, agent: "first", text: "First")
        _ = try fixture(root, agent: "second", text: "Second")
        let reader = ClaudeSubagentTranscriptReader(configDirectory: root)
        XCTAssertThrowsError(try reader.read(parentSessionID: parent, reference: .init(toolUseID: "tool", taskType: "local_agent")))
        let duplicate = root.appending(path: "projects/other")
        try FileManager.default.createDirectory(at: duplicate, withIntermediateDirectories: true)
        try Data().write(to: duplicate.appending(path: "\(parent).jsonl"))
        XCTAssertThrowsError(try reader.read(parentSessionID: parent, reference: .init(agentID: "first")))
    }

    func testWrongParentIdentityAndCyclesFailClosed() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, agent: "wrong", text: "Wrong")
        let other = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: parent, with: other)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let reader = ClaudeSubagentTranscriptReader(configDirectory: root)
        XCTAssertThrowsError(try reader.read(parentSessionID: parent, reference: .init(agentID: "wrong")))
        let cycle = try lines([message("loop", parentUUID: "loop", text: "Cycle")])
        XCTAssertThrowsError(try reader.project(cycle, parentSessionID: parent))
        XCTAssertThrowsError(try reader.read(parentSessionID: "../wrong", reference: .init(agentID: "wrong")))
    }

    func testPartialWritesAndGapsAreNotInventedAndLimitsAreVisible() throws {
        let reader = ClaudeSubagentTranscriptReader(configDirectory: URL(filePath: "/unused"), maximumEntries: 2)
        let data = try lines([message("one", parentUUID: "missing", text: "One"), message("two", parentUUID: "one", text: "Two")])
            + Data("{\"unfinished\":".utf8)
        let snapshot = try reader.project(data, parentSessionID: parent)
        XCTAssertTrue(snapshot.isTruncated)
        XCTAssertFalse(snapshot.entries.contains { if case let .assistant(text, _) = $0.content { text.contains("unfinished") } else { false } })
    }

    func testParallelToolResultsOffTheAncestryWalkStillCompleteTheirCalls() throws {
        // Modelled on a saved Claude turn: two parallel Edit calls, each result parented on its
        // own call, and the conversation continuing from the second result only.
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try mainLog(root, [
            #"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"Fix calc.py"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"id":"m1","role":"assistant","content":[{"type":"thinking","thinking":"Two fixes"}]}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"a1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"edit-1","name":"Edit","input":{"file_path":"calc.py","old_string":"a - b","new_string":"a + b"}}]}}"#,
            #"{"type":"assistant","uuid":"a3","parentUuid":"a2","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"edit-2","name":"Edit","input":{"file_path":"calc.py","old_string":"/ n","new_string":"/ max(n, 1)"}}]}}"#,
            #"{"type":"user","uuid":"r1","parentUuid":"a2","sourceToolAssistantUUID":"a2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"edit-1","content":"Updated add"}]}}"#,
            #"{"type":"user","uuid":"r2","parentUuid":"a3","sourceToolAssistantUUID":"a3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"edit-2","content":"Updated mean"}]}}"#,
            #"{"type":"user","uuid":"dup","parentUuid":"a3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"edit-2","content":"Duplicate"}]}}"#,
            #"{"type":"user","uuid":"ghost","parentUuid":"a2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"elsewhere","content":"Ghost"}]}}"#,
            #"{"type":"user","uuid":"rewound","parentUuid":"a2","message":{"role":"user","content":"Abandoned request"}}"#,
            #"{"type":"assistant","uuid":"a4","parentUuid":"r2","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"bash","name":"Bash","input":{"command":"python3 test_calc.py"}}]}}"#
        ])
        let snapshot = try XCTUnwrap(ClaudeSubagentTranscriptReader(configDirectory: root).readConversation(sessionID: parent))
        let cards = snapshot.entries.compactMap { entry -> (HarnessActivity, TranscriptActivityState)? in
            if case let .activity(activity, state) = entry.content { return (activity, state) }
            return nil
        }
        XCTAssertEqual(cards.map(\.0.id), ["edit-1", "edit-2", "bash"])
        XCTAssertEqual(cards.map(\.1), [.completed, .completed, .stopped], "A call with no saved result is not completed")
        XCTAssertEqual(cards.map(\.0.output), ["Updated add", "Updated mean", nil])
        XCTAssertFalse(snapshot.entries.contains { $0.content == .user(text: "Abandoned request") })
    }

    func testSavedAgentCallRestoresAsItsSubagentCard() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try mainLog(root, [
            #"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":"Summarize the README with an agent"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_agent","name":"Agent","input":{"description":"Summarize README","prompt":"Read README.md","subagent_type":"Explore","run_in_background":false}}]}}"#,
            #"{"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_agent","content":[{"type":"text","text":"[Subagent hand-back] Framing for the model. The report follows:\n  A small sandbox."}]}]},"toolUseResult":{"status":"completed","agentId":"child-1","agentType":"Explore","content":[{"type":"text","text":"A small sandbox."}],"totalDurationMs":3190,"totalTokens":15383,"totalToolUseCount":1}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"r1","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"The agent summarized it."}]}}"#
        ])
        let agents = root.appending(path: "projects/project/\(parent)/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try lines([message("child", parentUUID: "start", text: "Child read the README")])
            .write(to: agents.appending(path: "agent-child-1.jsonl"))

        let reader = ClaudeSubagentTranscriptReader(configDirectory: root)
        let snapshot = try XCTUnwrap(reader.readConversation(sessionID: parent))
        let card = try XCTUnwrap(snapshot.entries.lazy.compactMap { entry -> (HarnessActivity, TranscriptActivityState)? in
            if case let .activity(activity, state) = entry.content { return (activity, state) }
            return nil
        }.first)
        XCTAssertEqual(card.0.kind, "Agent")
        XCTAssertEqual(card.0.title, "Summarize README")
        XCTAssertEqual(card.1, .completed)
        XCTAssertEqual(card.0.output, "A small sandbox.\n" + L10n.format("%@ tool uses · %@ tokens · %@ s", "1", "15383", "3.2"))
        XCTAssertEqual(card.0.subtask, HarnessSubtaskReference(agentID: "child-1", toolUseID: "toolu_agent", taskType: "local_agent"))
        let child = try reader.read(parentSessionID: parent, reference: XCTUnwrap(card.0.subtask))
        XCTAssertTrue(child.entries.contains { $0.content == .assistant(text: "Child read the README", isStreaming: false) })
    }

    func testSavedRequestsKeepTheirAttachedImages() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).base64EncodedString()
        try mainLog(root, [
            #"{"type":"user","uuid":"u1","parentUuid":null,"message":{"role":"user","content":[{"type":"text","text":"What is wrong here?"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}]}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"The margin."}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"a1","message":{"role":"user","content":[{"type":"image","source":{"type":"url","url":"https://example.invalid/a.png"}}]}}"#
        ])
        let snapshot = try XCTUnwrap(ClaudeSubagentTranscriptReader(configDirectory: root).readConversation(sessionID: parent))
        let requests = snapshot.entries.compactMap { entry -> TranscriptEntryContent? in
            if case .user = entry.content { return entry.content }
            return nil
        }
        XCTAssertEqual(requests, [
            .user(text: "What is wrong here?", images: [
                TranscriptImageAttachment(url: InlineImageInput.url(mimeType: "image/png", base64: png), name: nil)
            ]),
            // An image Claude did not save inline is still shown as sent, without being fetched.
            .user(text: "", images: [TranscriptImageAttachment(url: nil, name: nil)])
        ])
    }

    /// Claude saves a message sent while a turn ran as the `queued_command` it read into the turn,
    /// on the conversation's chain. Rereading the saved conversation keeps it in that turn (D13),
    /// with the same identity each time; commands Claude queued itself are not messages.
    func testAMessageReadIntoARunningTurnStaysInThatTurnWhenReread() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try mainLog(root, [
            #"{"type":"user","uuid":"u1","parentUuid":null,"timestamp":"2026-10-12T08:24:01.967Z","message":{"role":"user","content":"Write the file."}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/tmp/x.txt","content":"ok\n"}}]}}"#,
            #"{"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"File created"}]}}"#,
            #"{"type":"attachment","uuid":"q1","parentUuid":"r1","timestamp":"2026-10-12T08:24:23.383Z","attachment":{"type":"queued_command","prompt":"Answer in one line.","commandMode":"prompt","origin":{"kind":"human"},"humanTurn":true}}"#,
            #"{"type":"attachment","uuid":"q2","parentUuid":"q1","attachment":{"type":"queued_command","prompt":"<task-notification>done</task-notification>","commandMode":"task-notification","origin":{"kind":"task-notification"}}}"#,
            #"{"type":"attachment","uuid":"o1","parentUuid":"q2","attachment":{"type":"output_style","style":"default"}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"o1","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Created."}]}}"#
        ])
        let reader = ClaudeSubagentTranscriptReader(configDirectory: root)
        let snapshot = try XCTUnwrap(reader.readConversation(sessionID: parent))
        let users = snapshot.entries.filter { if case .user = $0.content { true } else { false } }
        XCTAssertEqual(users.map(\.content), [.user(text: "Write the file.", images: nil),
                                              .user(text: "Answer in one line.", images: nil)])
        XCTAssertEqual(users.map(\.joinsRunningTurn), [nil, true])
        XCTAssertEqual(users[1].createdAt, ClaudeSubagentTranscriptReader.timestamp("2026-10-12T08:24:23.383Z"))
        XCTAssertEqual(try XCTUnwrap(reader.readConversation(sessionID: parent)).entries.map(\.id),
                       snapshot.entries.map(\.id), "A reread names the same entries")
        if case let .assistant(text, _)? = snapshot.entries.last?.content {
            XCTAssertEqual(text, "Created.")
        } else {
            XCTFail("The answer follows the message read into the turn")
        }
    }

    /// When a background command or agent finishes after a turn ended, Claude Code starts the next
    /// turn with a `user` record of its own (`origin.kind` "task-notification"). Read again, that
    /// notice is not one of the person's messages, nor a point to edit from; what Claude answered
    /// reads on in the turn before. A message from another session (`peer`) still reads as one.
    func testClaudesOwnNoticeOfAFinishedTaskIsNotReadAsThePersonsMessage() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notice = #"<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n<summary>Agent \"Review\" finished</summary>\n</task-notification>"#
        try mainLog(root, [
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000001","parentUuid":null,"timestamp":"2026-10-16T08:00:00.000Z","origin":{"kind":"human"},"message":{"role":"user","content":"Start the review agent."}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000002","parentUuid":"00000000-0000-4000-8000-000000000001","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Started it."}]}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000003","parentUuid":"00000000-0000-4000-8000-000000000002","timestamp":"2026-10-16T08:05:00.000Z","origin":{"kind":"task-notification","producer":"session-task"},"promptSource":"system","turnOrigin":"task_notification","message":{"role":"user","content":"\#(notice)"}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000004","parentUuid":"00000000-0000-4000-8000-000000000003","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"The review found nothing."}]}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000005","parentUuid":"00000000-0000-4000-8000-000000000004","origin":{"kind":"peer"},"promptSource":"system","message":{"role":"user","content":"From the other session: rebase first."}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000006","parentUuid":"00000000-0000-4000-8000-000000000005","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"Rebased."}]}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000007","parentUuid":"00000000-0000-4000-8000-000000000006","origin":{"kind":"human"},"message":{"role":"user","content":"Ship it."}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000008","parentUuid":"00000000-0000-4000-8000-000000000007","message":{"id":"m4","role":"assistant","content":[{"type":"text","text":"Shipped."}]}}"#
        ])
        let reader = ClaudeSubagentTranscriptReader(configDirectory: root)
        let snapshot = try XCTUnwrap(reader.readConversation(sessionID: parent))
        let shown = snapshot.entries.compactMap { entry -> String? in
            switch entry.content {
            case let .user(text, _):
                ClaudeTaskNotification.parse(text).map { "notice: \($0.summary)" } ?? "user: \(text)"
            case let .assistant(text, _): "assistant: \(text)"
            default: nil
            }
        }
        // The notice opens the turn Claude answered it in, apart from the turn before, whose answer
        // stays its answer; it is no point to rewind or edit to.
        XCTAssertEqual(shown, ["user: Start the review agent.", "assistant: Started it.",
                               "notice: Agent \"Review\" finished", "assistant: The review found nothing.",
                               "user: From the other session: rebase first.", "assistant: Rebased.",
                               "user: Ship it.", "assistant: Shipped."])
        XCTAssertEqual(try reader.conversationPoints(sessionID: parent).map(\.text),
                       ["Start the review agent.", "From the other session: rebase first.", "Ship it."])
        let turns = TranscriptConversationProjection.presentation(
            from: snapshot.entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true).turns
        func answers(_ turn: ConversationTurn) -> [String] {
            turn.answers.compactMap { if case let .answer(text, _) = $0.kind { text } else { nil } }
        }
        XCTAssertEqual(turns.map(answers), [["Started it."], ["The review found nothing."], ["Rebased."], ["Shipped."]])
        XCTAssertEqual(turns[1].prompt.first?.backgroundTaskNotice?.summary, "Agent \"Review\" finished",
                       "drawn as the notice, not the person's message")
        XCTAssertNil(turns[1].actions.editLatest, "no edit of Claude's own notice")
    }

    /// A prompt Claude Code's own schedule sent opens the turn Claude answered it in (2026-10-22: a user
    /// reported that a task woken by a schedule had its work hidden as progress commentary). The records
    /// follow the CLI's saved shape (2.1.299): a `CronCreate` job's or `/loop` wakeup's prompt is a meta
    /// `user` record with `turnOrigin` "scheduled" and a prompt ID of its own; the CLI's note that an
    /// answer was cut off is a meta companion with that same prompt ID; a Claude app scheduled task is
    /// a `task-notification` of subkind `scheduled-trigger` around a `<scheduled-task>` block.
    func testAScheduledPromptOpensATurnOfItsOwnAndTheAnswerBeforeItStays() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cutOff = "Your response above was cut off mid-stream. Continue from where it stopped."
        let task = "<scheduled-task name=\"morning-brief\" file=\"/Users/qa/.claude/scheduled-tasks/morning-brief/SKILL.md\">\nSummarize the new tickets.\n</scheduled-task>"
        let taskJSON = try XCTUnwrap(String(data: JSONEncoder().encode(task), encoding: .utf8))
        try mainLog(root, [
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000001","parentUuid":null,"timestamp":"2026-10-22T11:35:00.000Z","promptId":"p1","promptSource":"sdk","turnOrigin":"human","origin":{"kind":"human"},"turnPosition":{"promptIndex":1,"turnIndex":1},"message":{"role":"user","content":"Some files came in by message."}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000002","parentUuid":"00000000-0000-4000-8000-000000000001","timestamp":"2026-10-22T11:35:10.000Z","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"read-1","name":"Read","input":{"file_path":"inbox.txt"}}]}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000003","parentUuid":"00000000-0000-4000-8000-000000000002","timestamp":"2026-10-22T11:35:12.000Z","promptId":"p1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"read-1","content":"two files"}]}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000004","parentUuid":"00000000-0000-4000-8000-000000000003","timestamp":"2026-10-22T11:35:47.000Z","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Handled both files and filed them."}],"stop_reason":"end_turn"}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000005","parentUuid":"00000000-0000-4000-8000-000000000004","timestamp":"2026-10-22T11:38:44.000Z","promptId":"p2","isMeta":true,"promptSource":"system","turnOrigin":"scheduled","turnPosition":{"promptIndex":1,"turnIndex":2},"queueSkipAttachments":true,"queueSkipSlashCommands":true,"message":{"role":"user","content":"[Inbox check] Look for new messages and handle them."}}"#,
            #"{"type":"attachment","uuid":"00000000-0000-4000-8000-000000000006","parentUuid":"00000000-0000-4000-8000-000000000005","attachment":{"type":"output_style","style":"default"}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000007","parentUuid":"00000000-0000-4000-8000-000000000006","timestamp":"2026-10-22T11:38:50.000Z","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"Answering the new message"}]}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000008","parentUuid":"00000000-0000-4000-8000-000000000007","timestamp":"2026-10-22T11:46:06.000Z","promptId":"p2","isMeta":true,"turnCompanion":true,"message":{"role":"user","content":"\#(cutOff)"}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000009","parentUuid":"00000000-0000-4000-8000-000000000008","timestamp":"2026-10-22T11:46:20.000Z","message":{"id":"m4","role":"assistant","content":[{"type":"text","text":"Replied to the new message."}],"stop_reason":"end_turn"}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-00000000000a","parentUuid":"00000000-0000-4000-8000-000000000009","timestamp":"2026-10-22T11:53:44.000Z","promptId":"p3","isMeta":true,"promptSource":"system","turnOrigin":"scheduled","turnPosition":{"promptIndex":1,"turnIndex":3},"queueSkipAttachments":true,"message":{"role":"user","content":"[Inbox check] Look for new messages and handle them."}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-00000000000b","parentUuid":"00000000-0000-4000-8000-00000000000a","timestamp":"2026-10-22T11:53:50.000Z","message":{"id":"m5","role":"assistant","content":[{"type":"text","text":"No change."}],"stop_reason":"end_turn"}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-00000000000c","parentUuid":"00000000-0000-4000-8000-00000000000b","timestamp":"2026-10-22T12:00:00.000Z","promptId":"p4","promptSource":"system","origin":{"kind":"task-notification","subkind":"scheduled-trigger","fireReason":"scheduled"},"turnOrigin":"scheduled","message":{"role":"user","content":\#(taskJSON)}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-00000000000d","parentUuid":"00000000-0000-4000-8000-00000000000c","timestamp":"2026-10-22T12:00:30.000Z","message":{"id":"m6","role":"assistant","content":[{"type":"text","text":"Brief sent."}],"stop_reason":"end_turn"}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-00000000000e","parentUuid":"00000000-0000-4000-8000-00000000000d","timestamp":"2026-10-22T12:05:00.000Z","promptId":"p5","promptSource":"sdk","turnOrigin":"sdk","turnPosition":{"promptIndex":2,"turnIndex":5},"message":{"role":"user","content":"Thanks, that is all."}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-00000000000f","parentUuid":"00000000-0000-4000-8000-00000000000e","timestamp":"2026-10-22T12:05:05.000Z","message":{"id":"m7","role":"assistant","content":[{"type":"text","text":"You're welcome."}],"stop_reason":"end_turn"}}"#
        ])
        let reader = ClaudeSubagentTranscriptReader(configDirectory: root)
        let snapshot = try XCTUnwrap(reader.readConversation(sessionID: parent))
        let shown = snapshot.entries.compactMap { entry -> String? in
            switch entry.content {
            case let .user(text, _): entry.origin == .scheduled ? "scheduled: \(text)" : "user: \(text)"
            case let .assistant(text, _): "assistant: \(text)"
            default: nil
            }
        }
        XCTAssertEqual(shown, [
            "user: Some files came in by message.", "assistant: Handled both files and filed them.",
            "scheduled: [Inbox check] Look for new messages and handle them.",
            "assistant: Answering the new message", "assistant: Replied to the new message.",
            "scheduled: [Inbox check] Look for new messages and handle them.", "assistant: No change.",
            "scheduled: \(task)",
            "assistant: Brief sent.",
            "user: Thanks, that is all.", "assistant: You're welcome."
        ], "the cut-off note stays out, in the turn it continues")
        // Neither a schedule's prompt nor the cut-off note is a point to edit or rewind to.
        XCTAssertEqual(try reader.conversationPoints(sessionID: parent).map(\.text),
                       ["Some files came in by message.", "Thanks, that is all."])

        let presentation = TranscriptConversationProjection.presentation(
            from: snapshot.entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true)
        let turns = presentation.turns
        func answers(_ turn: ConversationTurn) -> [String] {
            turn.answers.compactMap { if case let .answer(text, _) = $0.kind { text } else { nil } }
        }
        XCTAssertEqual(turns.map(answers), [["Handled both files and filed them."], ["Replied to the new message."],
                                            ["No change."], ["Brief sent."], ["You're welcome."]],
                       "each turn keeps its own answer; the report before a check is no note in the check's turn")
        func scheduled(_ turn: ConversationTurn) -> ConversationScheduledTaskMessage? {
            guard case let .scheduledTaskMessage(message) = turn.prompt.first?.kind else { return nil }
            return message
        }
        XCTAssertEqual(scheduled(turns[1])?.instructions, "[Inbox check] Look for new messages and handle them.")
        XCTAssertEqual(scheduled(turns[1])?.claudeSchedule, .checkIn, "drawn as the check-in, not the person's bubble")
        XCTAssertEqual(scheduled(turns[3])?.instructions, "Summarize the new tickets.")
        XCTAssertEqual(scheduled(turns[3])?.claudeSchedule, .task(name: "morning-brief"))
        XCTAssertNil(scheduled(turns[0]))
        XCTAssertNil(scheduled(turns[4]))
        // Files restore to the person's latest message, never to a schedule's.
        XCTAssertEqual(turns[4].actions.restoreFiles?.text, "Thanks, that is all.")
        for turn in turns[1...3] {
            XCTAssertNil(turn.actions.restoreFiles)
            XCTAssertNil(turn.actions.editLatest)
        }

        // `read_task` names who sent each request.
        let text = try XCTUnwrap(SessionToolText.conversation(presentation, workspaceURL: nil, turns: 10, cursor: nil)).text
        XCTAssertTrue(text.contains("Person: Some files came in by message."), text)
        XCTAssertTrue(text.contains("Scheduled task: [Inbox check] Look for new messages and handle them."), text)
        XCTAssertTrue(text.contains("Scheduled task: Summarize the new tickets."), text)
        XCTAssertFalse(text.contains("Person: [Inbox check]"), text)
        XCTAssertFalse(text.contains("Note: Handled both files"), "the report reads as its turn's answer:\n\(text)")
        XCTAssertTrue(text.contains("Answer: Handled both files and filed them."), text)
    }

    /// A Claude app scheduled task's block reads as the app reads it (`yc`); anything else is a
    /// check-in's own prompt, word for word.
    func testAScheduledTaskBlockIsReadAsTheClaudeAppReadsIt() {
        let file = "/Users/qa/.claude/scheduled-tasks/daily-digest/SKILL.md"
        XCTAssertEqual(ClaudeScheduledPrompt.reading("<scheduled-task name=\"daily-digest\" file=\"\(file)\">\nWrite the digest.\nKeep it short.\n</scheduled-task>"),
                       ClaudeScheduledPrompt(kind: .task(name: "daily-digest"), instructions: "Write the digest.\nKeep it short."))
        for text in [
            "<scheduled-task name=\"Daily Digest\" file=\"\(file)\">\nWrite the digest.\n</scheduled-task>",
            "<scheduled-task name=\"a\" file=\"\(file)\">\n<scheduled-task name=\"b\" file=\"\(file)\">\nx\n</scheduled-task>\n</scheduled-task>",
            "Check the inbox <scheduled-task name=\"a\" file=\"\(file)\">\nx\n</scheduled-task>",
            "[Inbox check] Look again."
        ] {
            XCTAssertEqual(ClaudeScheduledPrompt.reading(text), ClaudeScheduledPrompt(kind: .checkIn, instructions: text), text)
        }
        // A record carrying the turn's origin on is no prompt of its own.
        let summary: JSONValue = .object(["type": .string("user"), "turnOrigin": .string("scheduled"),
            "isCompactSummary": .bool(true), "isVisibleInTranscriptOnly": .bool(true),
            "message": .object(["role": .string("user"), "content": .string("Summary of the conversation so far.")])])
        XCTAssertNil(ClaudeScheduledPrompt.text(of: summary))
    }

    /// A last scheduled turn offers no edit: its prompt is the schedule's, not the person's.
    func testALastScheduledTurnOffersNoEdit() {
        let entries = [
            TranscriptEntry(content: .user(text: "Watch the inbox.")),
            TranscriptEntry(content: .assistant(text: "Watching.", isStreaming: false)),
            TranscriptEntry(content: .user(text: "[Inbox check] Look again."), origin: .scheduled),
            TranscriptEntry(content: .assistant(text: "Nothing new.", isStreaming: false))
        ]
        let turns = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true).turns
        XCTAssertEqual(turns.count, 2)
        XCTAssertNil(turns[1].actions.editLatest)
        XCTAssertNil(turns[1].actions.restoreFiles)
        XCTAssertEqual(turns[0].actions.restoreFiles?.text, "Watch the inbox.", "the person's latest message")
        XCTAssertTrue(turns[1].actions.canFork, "the latest turn still forks the whole conversation")
    }

    /// The Claude app's notices of a session it started: put before the person's text in a second
    /// block, and sent alone to wake the parent. Its own screen shows neither, and neither does Yardlet.
    /// The Claude app's notices, and the CLI's note that a turn stopped (here a quit ended it while a
    /// question waited: `interruptedByShutdown`), are not the person's text, as the Claude app reads them.
    func testTheClaudeAppsSessionNoticesAndTheCLIsInterruptionNoteAreNotShownAsThePersonsText() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reminder = #"<system-reminder>\nThe session \"0V8CFF\" you started (local_1) finished a turn.\n</system-reminder>\n<side-sessions-event>None of the sessions you started is working now.</side-sessions-event>"#
        try mainLog(root, [
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000001","parentUuid":null,"origin":{"kind":"human"},"message":{"role":"user","content":"Open the CS sessions."}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000002","parentUuid":"00000000-0000-4000-8000-000000000001","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Opened."}]}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000003","parentUuid":"00000000-0000-4000-8000-000000000002","message":{"role":"user","content":"\#(reminder)"}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000004","parentUuid":"00000000-0000-4000-8000-000000000003","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"0V8CFF is done."}]}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000005","parentUuid":"00000000-0000-4000-8000-000000000004","origin":{"kind":"human"},"message":{"role":"user","content":[{"type":"text","text":"\#(reminder)"},{"type":"text","text":"Anything else?"}]}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000006","parentUuid":"00000000-0000-4000-8000-000000000005","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"Nothing else."}]}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000007","parentUuid":"00000000-0000-4000-8000-000000000006","message":{"id":"m4","role":"assistant","content":[{"type":"tool_use","id":"toolu_ask","name":"AskUserQuestion","input":{"questions":[{"question":"Which first?","header":"First","multiSelect":false,"options":[{"label":"A"},{"label":"B"}]}]}}]}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000008","parentUuid":"00000000-0000-4000-8000-000000000007","interruptedByShutdown":true,"toolUseResult":"User rejected tool use","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_ask","is_error":true,"content":"The user doesn't want to proceed with this tool use."}]}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000009","parentUuid":"00000000-0000-4000-8000-000000000008","interruptedByShutdown":true,"message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        ])
        let reader = ClaudeSubagentTranscriptReader(configDirectory: root)
        let snapshot = try XCTUnwrap(reader.readConversation(sessionID: parent))
        let shown = snapshot.entries.compactMap { entry -> String? in
            switch entry.content {
            case let .user(text, _): "user: \(text)"
            case let .assistant(text, _): "assistant: \(text)"
            default: nil
            }
        }
        XCTAssertEqual(shown, ["user: Open the CS sessions.", "assistant: Opened.", "assistant: 0V8CFF is done.",
                               "user: Anything else?", "assistant: Nothing else."])
        XCTAssertEqual(try reader.conversationPoints(sessionID: parent).map(\.text), ["Open the CS sessions.", "Anything else?"])
        XCTAssertEqual(ClaudeHostNotice.stripped("Plain <b>text</b>"), "Plain <b>text</b>")
        XCTAssertFalse(ClaudeHostNotice.isOnlyNotice("Anything else?"))

        // A slash command, as 2.1.322 saves the `/compact` Yardlet sends: the compaction first, then the
        // command and what it printed as records of their own. They read as the live stream showed them:
        // the request, its compaction's marker, the output's card; and none is a request to edit.
        let caveat = "<local-command-caveat>The command below was run directly in Claude Code.</local-command-caveat>"
        let command = #"<command-name>/compact</command-name>\n            <command-message>compact</command-message>\n            <command-args></command-args>"#
        try mainLog(root, [
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000011","parentUuid":null,"origin":{"kind":"human"},"message":{"role":"user","content":"Run the tests."}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000012","parentUuid":"00000000-0000-4000-8000-000000000011","message":{"id":"m5","role":"assistant","content":[{"type":"text","text":"All green."}]}}"#,
            #"{"type":"system","subtype":"compact_boundary","uuid":"00000000-0000-4000-8000-000000000013","parentUuid":null,"logicalParentUuid":"00000000-0000-4000-8000-000000000012","content":"Conversation compacted","compactMetadata":{"trigger":"manual","preTokens":254503,"postTokens":20114}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000014","parentUuid":"00000000-0000-4000-8000-000000000013","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"This session is being continued from a previous conversation."}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000015","parentUuid":"00000000-0000-4000-8000-000000000014","isMeta":true,"message":{"role":"user","content":"\#(caveat)"}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000016","parentUuid":"00000000-0000-4000-8000-000000000015","message":{"role":"user","content":"\#(command)"}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000017","parentUuid":"00000000-0000-4000-8000-000000000016","message":{"role":"user","content":"<local-command-stdout>Compacted </local-command-stdout>"}}"#,
            #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000018","parentUuid":"00000000-0000-4000-8000-000000000017","origin":{"kind":"human"},"message":{"role":"user","content":"Now the docs."}}"#,
            #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000019","parentUuid":"00000000-0000-4000-8000-000000000018","message":{"id":"m6","role":"assistant","content":[{"type":"text","text":"Updated."}]}}"#
        ])
        let compacted = try XCTUnwrap(reader.readConversation(sessionID: parent)).entries.compactMap { entry -> String? in
            switch entry.content {
            case let .user(text, _): "user: \(text)"
            case let .assistant(text, _): "assistant: \(text)"
            case let .compaction(compaction): "compaction: \(compaction.tokensBefore ?? 0) → \(compaction.tokensAfter ?? 0)"
            case let .activity(activity, _): "\(activity.title): \(activity.output ?? "")"
            default: nil
            }
        }
        XCTAssertEqual(compacted, ["user: Run the tests.", "assistant: All green.", "user: /compact",
                                   "compaction: 254503 → 20114", "\(L10n.string("Command output")): Compacted",
                                   "user: Now the docs.", "assistant: Updated."])
        XCTAssertEqual(try reader.conversationPoints(sessionID: parent).map(\.text), ["Now the docs."],
                       "Neither the compaction's summary nor the command or its output is a request to edit")
        XCTAssertEqual(ClaudeLocalCommand.parse(#"<command-name>/compact</command-name><command-args> keep the API notes </command-args>"#),
                       .request("/compact keep the API notes"))
        XCTAssertNil(ClaudeLocalCommand.parse("<command-name>/compact</command-name> and more words"), "Words of the person's own")
    }

    /// A child conversation as the reader reads it draws in the subtask panel (plan M8): its request,
    /// thinking, tools with their output and diff, and its answer, read only. Written to
    /// `.build/subtask-panel-qa/subtask-panel-*`.
    @MainActor
    func testTheChildConversationDrawsInTheSubtaskPanel() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try agentLog(root, agent: "child-qa", [
            #"{"type":"user","uuid":"c0","parentUuid":null,"isSidechain":true,"message":{"role":"user","content":"Read README.md and fix the title"}}"#,
            #"{"type":"assistant","uuid":"c1","parentUuid":"c0","isSidechain":true,"message":{"id":"m1","role":"assistant","content":[{"type":"thinking","thinking":"The title is in the first line."}]}}"#,
            #"{"type":"assistant","uuid":"c2","parentUuid":"c1","isSidechain":true,"message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"read-1","name":"Bash","input":{"command":"head -3 README.md","description":"Show the title"}}]}}"#,
            #"{"type":"user","uuid":"c3","parentUuid":"c2","isSidechain":true,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"read-1","content":"Yardlet\n\nA workbench."}]}}"#,
            #"{"type":"assistant","uuid":"c4","parentUuid":"c3","isSidechain":true,"message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"The title needs one more word."}]}}"#,
            #"{"type":"assistant","uuid":"c5","parentUuid":"c4","isSidechain":true,"message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"edit-1","name":"Edit","input":{"file_path":"README.md","old_string":"Yardlet","new_string":"Yardlet workbench"}}]}}"#,
            #"{"type":"user","uuid":"c6","parentUuid":"c5","isSidechain":true,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"edit-1","content":"Updated README.md"}]}}"#,
            #"{"type":"assistant","uuid":"c7","parentUuid":"c6","isSidechain":true,"message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"The title now reads **Yardlet workbench**."}]}}"#,
            #"{"type":"user","uuid":"c8","parentUuid":"c7","isSidechain":true,"message":{"role":"user","content":"Also check the license line"}}"#,
            #"{"type":"assistant","uuid":"c9","parentUuid":"c8","isSidechain":true,"message":{"id":"m4","role":"assistant","content":[{"type":"tool_use","id":"grep-1","name":"Grep","input":{"pattern":"License"}}]}}"#
        ])
        let reference = HarnessSubtaskReference(agentID: "child-qa", toolUseID: "toolu_agent", taskType: "local_agent")
        let child = try ClaudeSubagentTranscriptReader(configDirectory: root).read(parentSessionID: parent,
                                                                                    reference: reference)
        XCTAssertGreaterThan(child.entries.count, 6)

        let session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet-subtask-qa"),
                                    runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Parent",
                                    providerSessionID: parent)
        let activity = HarnessActivity(id: "toolu_agent", kind: "Agent", title: "Fix the README title",
                                       detail: nil, subtask: reference)
        let directory = try WindowlessRender.directory("subtask-panel-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                HarnessSubtaskPane(activity: activity, session: session, readingPosition: TranscriptReadingPosition(),
                                   actions: ConversationActions().readOnlyChild, load: { child }, onClose: {}),
                size: NSSize(width: 560, height: 900), appearance: appearance
            )
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "subtask-panel-\(appearance.suffix).png"))
            let labels = drawing.elements.flatMap { [$0.label, $0.value] }
            XCTAssertTrue(labels.contains("Read README.md and fix the title"), "the child's request is drawn")
            XCTAssertTrue(labels.contains(L10n.string("Work details")), "the finished turn folds its work")
            XCTAssertTrue(labels.contains("Also check the license line"), "the running turn is drawn")
            // Read only: no message menu, no subtask controls.
            XCTAssertFalse(drawing.elements.contains { $0.role == "AXMenuButton" })
            XCTAssertFalse(labels.contains(L10n.string("Open child task")))
        }
    }

    private func agentLog(_ root: URL, agent: String, _ entries: [String]) throws {
        let project = root.appending(path: "projects/project")
        let agents = project.appending(path: "\(parent)/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data().write(to: project.appending(path: "\(parent).jsonl"))
        let text = entries.map { $0.replacingOccurrences(of: #""uuid":"#, with: #""sessionId":"\#(parent)","uuid":"#) }
            .joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: agents.appending(path: "agent-\(agent).jsonl"))
    }

    private func mainLog(_ root: URL, _ entries: [String]) throws {
        let project = root.appending(path: "projects/project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let text = entries.map { $0.replacingOccurrences(of: #""uuid":"#, with: #""sessionId":"\#(parent)","uuid":"#) }
            .joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: project.appending(path: "\(parent).jsonl"))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-child-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(_ root: URL, agent: String, text: String) throws -> URL {
        let project = root.appending(path: "projects/project")
        let agents = project.appending(path: "\(parent)/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data().write(to: project.appending(path: "\(parent).jsonl"))
        let file = agents.appending(path: "agent-\(agent).jsonl")
        let request = JSONValue.object(["type": .string("user"), "uuid": .string("u"), "parentUuid": .null,
            "sessionId": .string(parent), "isSidechain": .bool(true), "message": .object(["content": .string("Child request")])])
        try lines([request, message("dead", parentUUID: "u", text: "Abandoned child"),
                   message("live", parentUUID: "u", text: text)]).write(to: file)
        try lines([.object(["toolUseId": .string("tool")])]).write(to: agents.appending(path: "agent-\(agent).meta.json"))
        return file
    }

    private func message(_ id: String, parentUUID: String, text: String) -> JSONValue {
        .object(["type": .string("assistant"), "uuid": .string(id), "parentUuid": .string(parentUUID),
            "sessionId": .string(parent), "parent_tool_use_id": .string("tool"),
            "message": .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])])])
    }
    private func lines(_ values: [JSONValue]) throws -> Data {
        try values.reduce(into: Data()) { result, value in
            result.append(try JSONEncoder().encode(value)); result.append(10)
        }
    }
}
