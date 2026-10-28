import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The decided differences the conversation renderer draws (plan A10, M12): each test draws a
/// conversation in an unshown window and checks the decision in the accessibility list. Review
/// images go to `.build/conversation-m12-qa/`.
@MainActor
final class ConversationIntendedDifferenceTests: XCTestCase {
    private let decoder = CodexTaskDecoder()
    private let workspace = URL(filePath: "/tmp/yardlet-m12")

    // MARK: - M12a: one request card, D1

    /// A Codex thread with requests in every state. The renderer pins only waiting requests
    /// under their turn, in one order, with the one request card's answers; an answered request is
    /// in the work where it happened, so a finished turn folds it.
    func testCodexRequestsUseTheOneCardAndOnlyWaitingOnesStayUnderTheTurn() throws {
        let state = codexRequestsFixture()
        let actions = ConversationActions(retryTurn: { _ in }, forkCodexTurn: { _ in }, implementCodexPlan: { _ in })
        let size = NSSize(width: 760, height: 1_400)
        let directory = try WindowlessRender.directory("conversation-m12-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let new = try ConversationDrawing.draw(ConversationTimeline(
                source: .codex(state, workspaceURL: workspace, historySelection: nil), actions: actions
            ), size: size, appearance: appearance)
            try WindowlessRender.writePNG(new.capture.bitmap,
                                          to: directory.appending(path: "codex-requests-\(appearance.suffix).png"))
            guard appearance == .light else { continue }
            let text = new.elements.map(\.description)

            // The finished turn's answered approval folds with its work.
            XCTAssertFalse(text.contains { $0.contains("answered-reason") }, text.joined(separator: "\n"))
            // The running turn: its command, then its refused request in the work, then the waiting
            // ones by the item they ask about (the command first), then by ID.
            let command = try XCTUnwrap(text.firstIndex { $0.contains("rm -rf .build") && $0.hasPrefix("AXStaticText") })
            let refused = try XCTUnwrap(text.firstIndex { $0.contains("refused-reason") })
            let shared = try XCTUnwrap(text.firstIndex { $0.contains("shared-reason") })
            let alone = try XCTUnwrap(text.firstIndex { $0.contains("alone-reason") })
            XCTAssertLessThan(command, refused)
            XCTAssertLessThan(refused, shared)
            XCTAssertLessThan(shared, alone)
            XCTAssertTrue(text.contains("AXStaticText = “\(L10n.string("Rejected"))”"))
            // The command approval offers its three answers in the card's one order.
            let buttons = text[shared...].filter { $0.hasPrefix("AXButton") }.prefix(3)
            XCTAssertEqual(Array(buttons), [L10n.string("Deny"), L10n.string("Allow for session"), L10n.string("Allow")]
                .map { "AXButton “\($0)”" })
            // A request Yardlet cannot answer fails closed in the card's words.
            XCTAssertTrue(text.contains { $0.contains(L10n.string("This Codex request needs a structured response.")) })
        }
    }

    /// A Claude request waiting in the middle of a turn is pinned under the turn, after the answer
    /// (D1).
    func testAClaudeRequestWaitingMidTurnIsPinnedUnderTheTurn() throws {
        let entries = [
            TranscriptEntry(content: .user(text: "Check it")),
            TranscriptEntry(content: .permission(PermissionRequest(
                id: "run", title: "Run", detail: nil, command: "pwd"
            ), state: .pending)),
            TranscriptEntry(content: .assistant(text: "Waiting for you.", isStreaming: false))
        ]
        let actions = ConversationActions(chooseOption: { _, _ in }, answer: { _, _ in })
        let size = NSSize(width: 760, height: 700)
        let directory = try WindowlessRender.directory("conversation-m12-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(ConversationTimeline(
                source: .transcript(entries: entries, harness: .claudeCode, status: .waitingForApproval,
                                    latestTurnIsComplete: false),
                actions: actions
            ), size: size, appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "claude-request-pinned-\(appearance.suffix).png"))
            guard appearance == .light else { continue }
            let new = drawing.elements.map(\.description)
            func position(_ list: [String], _ text: String) throws -> Int {
                try XCTUnwrap(list.firstIndex { $0.contains(text) }, "\(text) is not listed:\n\(list.joined(separator: "\n"))")
            }
            XCTAssertGreaterThan(try position(new, "pwd"), try position(new, "Waiting for you."))
            XCTAssertEqual(new.filter { $0.hasPrefix("AXButton") && ($0.contains(L10n.string("Deny")) || $0.contains(L10n.string("Allow"))) },
                           ["AXButton “\(L10n.string("Deny"))”", "AXButton “\(L10n.string("Allow"))”"])
        }
    }

    // MARK: - M12d: notices (B7, D6, D7)

    /// Claude Code retrying its request reads on the running turn's status line, as Codex's
    /// reconnects do, instead of above the composer (D6).
    func testAClaudeRetryReadsOnTheRunningTurnsStatusLine() throws {
        let retry = HarnessProviderRetry(attempt: 3, maxRetries: 10, cause: .overloaded)
        let notices = TaskProviderNotices(retry: retry)
        let entries = [
            TranscriptEntry(content: .user(text: "Fix the tests")),
            TranscriptEntry(content: .assistant(text: "Running them first.", isStreaming: false))
        ]
        let text = ProviderNoticeText.retry(retry)
        let directory = try WindowlessRender.directory("conversation-m12-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(ConversationTimeline(
                source: .transcript(entries: entries, harness: .claudeCode, status: .running, latestTurnIsComplete: false),
                actions: ConversationActions(providerNotices: notices)
            ), size: NSSize(width: 720, height: 420), appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "claude-retry-\(appearance.suffix).png"))
            let listed = drawing.elements.map(\.description)
            let retryLine = try XCTUnwrap(listed.firstIndex { $0.contains(text) }, listed.joined(separator: "\n"))
            XCTAssertGreaterThan(retryLine, try XCTUnwrap(listed.firstIndex { $0.contains("Running them first.") }))
        }
        // The lines above the composer leave the retry out.
        XCTAssertFalse(ProviderNoticeLines.showsAnything(notices))
        // A finished turn has no status line, and a limit warning still reads above the composer.
        let finished = ConversationTimeline(
            source: .transcript(entries: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true),
            actions: ConversationActions(providerNotices: notices)
        )
        let idle = try ConversationDrawing.draw(finished, size: NSSize(width: 720, height: 420), appearance: .light)
        XCTAssertFalse(idle.elements.contains { $0.label.contains(text) || $0.value.contains(text) })
        let warning = TaskProviderNotices(limitWarning: HarnessRateLimit(status: .warning, window: .weekly, usedFraction: 0.9))
        XCTAssertTrue(ProviderNoticeLines.showsAnything(warning))
    }

    /// A Codex plan limit reads as the limit card every harness shows (D7): the provider's words, no
    /// automatic continue (the turn error names no reset) and no other account. A Codex compaction
    /// reads as the compaction marker.
    func testACodexLimitUsesTheLimitCardAndACompactionTheMarker() throws {
        let message = "You've hit your usage limit. Try again later."
        var limited = turn("limited", status: "failed", durationMs: 3_000, items: [user("u1", "Fix the tests")], error: .object([
            "message": .string(message), "codexErrorInfo": .string("usageLimitExceeded")
        ]))
        limited.status = .failed
        let compacting = turn("compacting", status: "inProgress", items: [
            user("u2", "Go on"), .object(["id": .string("x1"), "type": .string("contextCompaction")])
        ])
        var state = thread([limited, compacting])
        state.thread?.turns[1].items[1].lifecycle = .completed
        let actions = ConversationActions(retryTurn: { _ in }, forkCodexTurn: { _ in }, implementCodexPlan: { _ in },
                                          restoreDraft: { _ in })
        let size = NSSize(width: 760, height: 900)
        let directory = try WindowlessRender.directory("conversation-m12-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(ConversationTimeline(
                source: .codex(state, workspaceURL: workspace, historySelection: nil), actions: actions
            ), size: size, appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "codex-limit-compaction-\(appearance.suffix).png"))
            guard appearance == .light else { continue }
            let new = drawing.elements.map(\.description)
            let listed = new.joined(separator: "\n")
            XCTAssertTrue(new.contains { $0.contains(ProviderNoticeText.limitHeadline(HarnessRateLimit(status: .rejected))) }, listed)
            XCTAssertTrue(new.contains { $0.contains(message) }, listed)
            for absent in [L10n.string("Continue with another account"), L10n.string("Auto-continue when limits reset"),
                           L10n.string("Retry")] {
                XCTAssertFalse(new.contains { $0.contains(absent) }, "\(absent) is offered:\n\(listed)")
            }
            XCTAssertFalse(drawing.elements.contains { $0.role == "AXCheckBox" }, listed)
            XCTAssertTrue(new.contains { $0.contains(L10n.string("Compacted session")) }, listed)
        }

        // The card's ID names the turn's limit the same way every time.
        let first = CodexConversationProjection.outcome(limited)
        guard case let .usageLimit(limit, entryID)? = first, case let .usageLimit(_, again)? = CodexConversationProjection.outcome(limited)
        else { return XCTFail("the limit is not a limit card") }
        XCTAssertEqual(entryID, again)
        XCTAssertNil(limit.resetsAt)
        XCTAssertEqual(limit.message, message)
    }

    // MARK: - M12e: the turn header (D4) and the turn's actions on its messages (D10, 2026-10-23)

    /// Two finished Claude Code turns: the first worked for twelve seconds by its entries' times, the
    /// second's entries share one second. Every harness draws the same header: the work time where
    /// the times give one (D4), and no menu. What the turn offers to do with its messages sits under
    /// them beside their copy, shown on hover (here always, as `revealsSentMessageActions` shows it),
    /// as the Claude app's Code tab and the Codex app put it: Claude Code's latest request offers its
    /// edit and the restore of its files, its answer the fork of the latest turn (D10). A harness that
    /// offers none draws none.
    func testTheTurnHeaderReadsTheWorkTimeAndTheMessagesHoldTheProvidersActions() throws {
        let entries = timedTurns()
        var actions = ClaudeConversationFixture.actions()
        actions.branch = { _ in }
        let worked = L10n.format("Worked for %lld seconds", Int64(12))
        let size = NSSize(width: 720, height: 900)
        let directory = try WindowlessRender.directory("conversation-m12-qa")
        let edit = "AXButton “\(L10n.string("Edit message"))”"
        let restore = "AXButton “\(L10n.string("Restore files…"))”"
        let fork = "AXButton “\(L10n.string("Fork from here"))”"
        for (harness, name) in [(HarnessKind.claudeCode, "claude-turn-header"), (.openCode, "opencode-turn-header")] {
            for appearance in WindowlessRender.Appearance.allCases {
                let drawing = try ConversationDrawing.draw(ConversationTimeline(
                    source: .transcript(entries: entries, harness: harness, status: .ready, latestTurnIsComplete: true),
                    actions: actions
                ).environment(\.revealsSentMessageActions, true), size: size, appearance: appearance)
                try WindowlessRender.writePNG(drawing.capture.bitmap,
                                              to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
                let new = drawing.elements.map(\.description)
                let listed = new.joined(separator: "\n")
                // The first turn reads its work time; the second, whose entries share one second, none.
                XCTAssertEqual(new.filter { ConversationDrawing.isWorkTime(drawingLabel($0)) }, ["AXButton “\(worked)”"], listed)
                XCTAssertFalse(drawing.elements.contains { $0.role == "AXMenuButton" }, listed)
                if harness == .claudeCode {
                    // The latest request's edit and restore right under it, then its answer and the fork.
                    for action in [edit, restore, fork] {
                        XCTAssertEqual(new.filter { $0.hasPrefix(action) }.count, 1, listed)
                    }
                    let order = try ["Now check the docs", edit, restore, "The docs are current.", fork].map { text in
                        try XCTUnwrap(new.firstIndex { $0.contains(text) }, text)
                    }
                    XCTAssertEqual(order, order.sorted(), listed)
                } else {
                    XCTAssertFalse(new.contains { $0.hasPrefix(edit) || $0.hasPrefix(restore) || $0.hasPrefix(fork) }, listed)
                }
            }
        }

        // The turn's items per provider.
        let claude = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        ).turns
        var handlers = ConversationTurnHandlers(edit: { _ in }, fork: {}, editMessage: { _ in }, restoreFiles: {})
        XCTAssertEqual(ConversationTurnAction.items(for: claude[0].actions, handlers: handlers), [])
        XCTAssertEqual(ConversationTurnAction.items(for: claude[1].actions, handlers: handlers),
                       [.fork, .editMessage, .restoreFiles])
        let running = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .running, latestTurnIsComplete: false
        ).turns
        XCTAssertFalse(running[1].actions.canFork, "Claude forks only while idle")
        XCTAssertNil(running[1].timing.durationMilliseconds, "a running turn reads no work time")
        let openCode = TranscriptConversationProjection.presentation(
            from: entries, harness: .openCode, status: .ready, latestTurnIsComplete: true
        ).turns
        XCTAssertFalse(openCode.contains { $0.actions.canFork })
        // Codex keeps its own items: the fork on every finished turn, and the edit of its latest request.
        let codex = CodexConversationProjection.presentation(
            thread([turn("t1", status: "completed", durationMs: 2_000, items: [user("u1", "Go"), answer("a1", "Done")])]),
            workspaceURL: workspace, historySelection: nil
        ).turns[0]
        handlers.editMessage = nil
        XCTAssertEqual(ConversationTurnAction.items(for: codex.actions, handlers: handlers), [.fork, .editTurn])
    }

    /// The transcript draws a turn in the same order as Codex (plan A5.1): a failed turn's error card
    /// after its work, where the turn ended (it was under the header, above the work, until 2026-10-28).
    func testATranscriptTurnPutsItsOutcomeAfterItsWork() throws {
        let entries = ClaudeConversationFixture.failed()
        let size = NSSize(width: 760, height: 1_300)
        let actions = ClaudeConversationFixture.actions()
        let new = try ConversationDrawing.draw(ConversationTimeline(
            source: .transcript(entries: entries, harness: .claudeCode, status: .failed, latestTurnIsComplete: false),
            actions: actions
        ), size: size, appearance: .light).elements.map(\.description)
        func position(_ list: [String], _ matches: (String) -> Bool) throws -> Int {
            try XCTUnwrap(list.lastIndex(where: matches), list.joined(separator: "\n"))
        }
        // The read is its status line, or inside the summary line of the calls around it (2026-10-15).
        let readCard: (String) -> Bool = { $0.contains("“Read") || $0.contains(L10n.string("Read a file")) }
        let error: (String) -> Bool = { $0.contains("Internal server error") }
        XCTAssertLessThan(try position(new, readCard), try position(new, error))
    }

    /// The decided differences in one place for review: a Codex thread, a Claude Code task waiting on
    /// its requests, a failed Claude Code task, and an ACP harness (OpenCode), each in both
    /// appearances (`.build/conversation-m12-qa/`).
    func testReviewRenders() throws {
#if DEBUG
        let directory = try WindowlessRender.directory("conversation-m12-qa")
        var actions = ClaudeConversationFixture.actions()
        actions.branch = { _ in }
        let opencode = ConversationFixtures.harnessTranscripts()
        let opencodeSession = try XCTUnwrap(opencode.sessions.first { $0.harness == .openCode })
        let opencodeEntries = try XCTUnwrap(opencode.transcripts[opencodeSession.id])
        let renders: [(String, AnyView, CGFloat)] = [
            ("codex", AnyView(ConversationTimeline(
                source: .codex(ConversationFixtures.codexTimeline(), workspaceURL: ConversationFixtures.workspace,
                               historySelection: nil),
                actions: ConversationActions(retryTurn: { _ in }, forkCodexTurn: { _ in }, implementCodexPlan: { _ in })
            )), 1_600),
            ("claude-code", AnyView(TaskConversationView(
                harness: .claudeCode, workspaceURL: ClaudeConversationFixture.workspace,
                entries: ClaudeConversationFixture.waiting(), sessionStatus: .waitingForApproval, actions: actions
            ).environment(\.claudeShellCommands, ClaudeConversationFixture.shellCommands())), 3_000),
            ("claude-code-failed", AnyView(TaskConversationView(
                harness: .claudeCode, workspaceURL: ClaudeConversationFixture.workspace,
                entries: ClaudeConversationFixture.failed(), sessionStatus: .failed, actions: actions
            )), 1_300),
            ("opencode", AnyView(TaskConversationView(
                harness: .openCode, workspaceURL: ConversationFixtures.workspace, entries: opencodeEntries,
                sessionStatus: opencodeSession.status,
                latestTurnIsComplete: opencodeSession.completionState == .completed,
                actions: ConversationActions(chooseOption: { _, _ in }, answer: { _, _ in })
            )), 1_600)
        ]
        for (name, view, height) in renders {
            for appearance in WindowlessRender.Appearance.allCases {
                let drawing = try ConversationDrawing.draw(
                    view.environment(\.transcriptWorkspaceURL, ClaudeConversationFixture.workspace),
                    size: NSSize(width: 760, height: height), appearance: appearance
                )
                try WindowlessRender.writePNG(drawing.capture.bitmap,
                                              to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
                XCTAssertFalse(drawing.elements.isEmpty, name)
            }
        }
#endif
    }

    /// Two finished turns: twelve seconds of work, then a request and its answer in one second.
    private func timedTurns() -> [TranscriptEntry] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ seconds: Double, _ content: TranscriptEntryContent) -> TranscriptEntry {
            TranscriptEntry(createdAt: start.addingTimeInterval(seconds), content: content)
        }
        return [
            at(0, .user(text: "Fix the build")),
            at(3, .assistant(text: "Reading the error.", isStreaming: false)),
            at(5, .activity(HarnessActivity(id: "toolu_read", kind: "Read", title: "Read", input: "Package.swift",
                                            output: "// swift-tools-version"), state: .completed)),
            at(12, .assistant(text: "Fixed the import.", isStreaming: false)),
            at(20, .user(text: "Now check the docs")),
            at(20.5, .assistant(text: "The docs are current.", isStreaming: false))
        ]
    }

    private func drawingLabel(_ description: String) -> String {
        guard let start = description.range(of: "“"), let end = description.range(of: "”", range: start.upperBound..<description.endIndex)
        else { return "" }
        return String(description[start.upperBound..<end.lowerBound])
    }

    // MARK: - Fixtures

    /// Two turns: a finished one with an answered approval and an expired question, and a running
    /// one with a waiting command approval (also an approval), a waiting approval of its own, a
    /// refused elicitation, and a request without a turn, which is never drawn.
    func codexRequestsFixture() -> CodexTaskState {
        var state = thread([
            // The finished turn answered, so its work folds (`ConversationTurnLayout`).
            turn("turn-1", status: "completed", durationMs: 4_000, items: [user("u1", "First"),
                command("c1", "swift test", status: "completed", output: "ok\n", exitCode: 0), answer("a1", "Tests pass.")]),
            turn("turn-2", status: "inProgress", items: [user("u2", "Second"),
                command("c2", "rm -rf .build", status: "inProgress", output: nil)])
        ])
        state.approvalsByID["shared"] = approval("shared", turnID: "turn-2", itemID: "c2", resolution: .pending)
        state.serverRequestsByID["shared"] = serverRequest("shared", kind: .commandExecutionApproval, turnID: "turn-2",
                                                           itemID: "c2", resolution: .pending)
        state.approvalsByID["alone"] = approval("alone", turnID: "turn-2", itemID: nil, resolution: .pending)
        state.approvalsByID["answered"] = approval("answered", turnID: "turn-1", itemID: "c1",
                                                   resolution: .resolved(.object(["decision": .string("accept")])))
        state.serverRequestsByID["expired"] = serverRequest(
            "expired", kind: .toolUserInput, turnID: "turn-1", itemID: nil,
            resolution: .rejected(code: CodexPendingServerRequest.expiredRuntimeCode, message: "The runtime ended")
        )
        state.serverRequestsByID["refused"] = serverRequest("refused", kind: .mcpElicitation, turnID: "turn-2",
                                                            itemID: nil, resolution: .rejected(code: -1, message: "No"))
        state.serverRequestsByID["future"] = serverRequest("future", kind: .unknown("future/request"), turnID: "turn-2",
                                                           itemID: nil, resolution: .pending)
        state.serverRequestsByID["no-turn"] = serverRequest("no-turn", kind: .authenticationRefresh, turnID: nil,
                                                            itemID: nil, resolution: .pending)
        return state
    }

    func thread(_ turns: [CodexTurnState]) -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string("thread-m12")]))!
        thread.turns = turns
        return CodexTaskState(thread: thread)
    }

    func turn(
        _ id: String, status: String, durationMs: Int64? = nil, items: [JSONValue], error: JSONValue? = nil
    ) -> CodexTurnState {
        var value: [String: JSONValue] = ["id": .string(id), "status": .string(status), "items": .array(items)]
        if let durationMs { value["durationMs"] = .integer(durationMs) }
        if let error { value["error"] = error }
        return decoder.turn(from: .object(value), fallbackID: id)!
    }

    func user(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("userMessage"),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    func answer(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string("final_answer")])
    }

    func command(_ id: String, _ command: String, status: String, output: String?, exitCode: Int64? = nil) -> JSONValue {
        .object([
            "id": .string(id), "type": .string("commandExecution"), "command": .string(command),
            "cwd": .string("/tmp/yardlet-m12"), "status": .string(status), "commandActions": .array([]),
            "aggregatedOutput": output.map(JSONValue.string) ?? .null,
            "exitCode": exitCode.map(JSONValue.integer) ?? .null
        ])
    }

    private func approval(
        _ id: String, turnID: String?, itemID: String?, resolution: CodexApprovalResolution
    ) -> CodexApprovalState {
        CodexApprovalState(id: id, method: "item/commandExecution/requestApproval", threadID: "thread-m12",
                           turnID: turnID, itemID: itemID, resolution: resolution,
                           raw: .object(["reason": .string("\(id)-reason")]))
    }

    private func serverRequest(
        _ id: String, kind: CodexServerRequestKind, turnID: String?, itemID: String?,
        resolution: CodexServerRequestResolution
    ) -> CodexServerRequestState {
        CodexServerRequestState(id: id, method: kind.wireName, kind: kind, threadID: "thread-m12", turnID: turnID,
                                itemID: itemID, params: .object(["message": .string("\(id)-reason")]), resolution: resolution)
    }
}
