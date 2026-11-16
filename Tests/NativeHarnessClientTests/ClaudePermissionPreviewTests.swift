import Foundation
import XCTest
@testable import NativeHarnessClient

/// The change a Claude tool request would make, read from the tool inputs a real Claude Code
/// 2.1.291 task sent (Edit, Bash) and the documented MultiEdit and Write shapes.
final class ClaudePermissionPreviewTests: XCTestCase {
    private let calcPath = "/Users/someone/Desktop/workspace/yardlet-sandbox/calc.py"

    private var editInput: JSONValue {
        .object([
            "replace_all": .bool(false),
            "file_path": .string(calcPath),
            "old_string": .string("def add(a, b):\n    return a - b"),
            "new_string": .string("def add(a, b):\n    return a + b")
        ])
    }

    // MARK: - Reading the tool input

    func testEditReadsAsOneReplacementInItsFile() throws {
        let preview = try XCTUnwrap(ClaudeProtocol.preview(toolName: "Edit", input: editInput))
        guard case let .edits(path, edits, omitted) = preview else { return XCTFail("not an edit preview") }
        XCTAssertEqual(path, calcPath)
        XCTAssertEqual(omitted, 0)
        XCTAssertEqual(edits, [PermissionEditPreview(
            oldText: PermissionPreviewText(text: "def add(a, b):\n    return a - b", omittedLineCount: 0),
            newText: PermissionPreviewText(text: "def add(a, b):\n    return a + b", omittedLineCount: 0),
            replacesAll: false
        )])
    }

    func testMultiEditWriteAndBashReadTheirOwnInputs() throws {
        let multi = try XCTUnwrap(ClaudeProtocol.preview(toolName: "MultiEdit", input: .object([
            "file_path": .string(calcPath),
            "edits": .array([
                .object(["old_string": .string("a - b"), "new_string": .string("a + b")]),
                .object(["old_string": .string("x"), "new_string": .string("y"), "replace_all": .bool(true)])
            ])
        ])))
        guard case let .edits(_, edits, _) = multi else { return XCTFail("not an edit preview") }
        XCTAssertEqual(edits.map(\.replacesAll), [false, true])

        let write = try XCTUnwrap(ClaudeProtocol.preview(toolName: "Write", input: .object([
            "file_path": .string("/tmp/new.py"), "content": .string("print('hi')\n")
        ])))
        XCTAssertEqual(write, .write(path: "/tmp/new.py", content: PermissionPreviewText(text: "print('hi')\n", omittedLineCount: 0)))

        let bash = try XCTUnwrap(ClaudeProtocol.preview(toolName: "Bash", input: .object([
            "command": .string("python3 test_calc.py -v 2>&1"),
            "description": .string("Rerun the calc tests after the fix")
        ])))
        XCTAssertEqual(bash, .command(
            PermissionPreviewText(text: "python3 test_calc.py -v 2>&1", omittedLineCount: 0),
            description: "Rerun the calc tests after the fix"
        ))
    }

    func testOtherToolsAndIncompleteInputsKeepTheRequestsOwnSummary() {
        XCTAssertNil(ClaudeProtocol.preview(toolName: "Read", input: .object(["file_path": .string(calcPath)])))
        XCTAssertNil(ClaudeProtocol.preview(toolName: "WebFetch", input: .object(["url": .string("https://example.com")])))
        XCTAssertNil(ClaudeProtocol.preview(toolName: "Edit", input: .object(["file_path": .string(calcPath)])))
        XCTAssertNil(ClaudeProtocol.preview(toolName: "Bash", input: .object(["command": .string("")])))
        XCTAssertNil(ClaudeProtocol.preview(toolName: nil, input: editInput))
    }

    func testLongTextKeepsItsFirstLinesAndCountsTheRest() {
        let source = (1...250).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let bounded = PermissionPreviewText(bounding: source)
        XCTAssertEqual(bounded.text.split(separator: "\n").count, 200)
        XCTAssertEqual(bounded.omittedLineCount, 50)

        // Stopping at the final newline leaves nothing out.
        let exact = (1...200).map { "line \($0)" }.joined(separator: "\n") + "\n"
        XCTAssertEqual(PermissionPreviewText(bounding: exact), PermissionPreviewText(text: exact, omittedLineCount: 0))

        // A line cut by the character bound is not shown in full, so it counts as left out.
        let wide = String(repeating: "x", count: 30) + "\nsecond"
        let cut = PermissionPreviewText(bounding: wide, characterLimit: 10)
        XCTAssertEqual(cut.text, String(repeating: "x", count: 10))
        XCTAssertEqual(cut.omittedLineCount, 2)

        let manyEdits = (0..<25).map { index in
            JSONValue.object(["old_string": .string("a\(index)"), "new_string": .string("b\(index)")])
        }
        let preview = ClaudeProtocol.preview(toolName: "MultiEdit", input: .object([
            "file_path": .string(calcPath), "edits": .array(manyEdits)
        ]))
        guard case let .edits(_, edits, omitted)? = preview else { return XCTFail("not an edit preview") }
        XCTAssertEqual(edits.count, PermissionRequestPreview.editLimit)
        XCTAssertEqual(omitted, 5)
    }

    // MARK: - Diff lines

    func testTheRealEditsReadAsCompactDiffs() throws {
        guard case let .edits(_, edits, _)? = ClaudeProtocol.preview(toolName: "Edit", input: editInput) else {
            return XCTFail("not an edit preview")
        }
        let diff = PermissionRequestPreviewProjection.diff(edits: edits)
        XCTAssertEqual(diff.lines.map(\.kind), [.context, .deletion, .addition])
        XCTAssertEqual(diff.lines.map(\.text), ["def add(a, b):", "    return a - b", "    return a + b"])
        XCTAssertEqual(diff.lines.map(\.number), [nil, nil, nil])
        XCTAssertEqual([diff.additions, diff.deletions, diff.hiddenLineCount], [1, 1, 0])

        let guardEdit = PermissionEditPreview(
            oldText: PermissionPreviewText(bounding: "def mean(values):\n    return sum(values) / len(values)"),
            newText: PermissionPreviewText(bounding:
                "def mean(values):\n    if not values:\n        return 0\n    return sum(values) / len(values)"),
            replacesAll: false
        )
        let added = PermissionRequestPreviewProjection.diff(edits: [guardEdit])
        XCTAssertEqual(added.lines.map(\.kind), [.context, .addition, .addition, .context])
        XCTAssertEqual([added.additions, added.deletions], [2, 0])
    }

    func testUnchangedLinesAwayFromAChangeFoldIntoARule() {
        let old = (1...40).map { "line \($0)" }
        var new = old
        new[4] = "changed 5"
        new[34] = "changed 35"
        let rows = PermissionRequestPreviewProjection.changedLines(from: old, to: new)
        // Three lines each side of each change, and one rule for the long unchanged run between.
        XCTAssertEqual(rows.map(\.kind), [.context, .context, .context, .deletion, .addition, .context, .context, .context,
                                          .separator,
                                          .context, .context, .context, .deletion, .addition, .context, .context, .context])
        XCTAssertEqual(rows.first?.text, "line 2")
        XCTAssertEqual(rows.last?.text, "line 38")
    }

    func testSeveralEditsAndEveryOccurrenceAreCaptioned() {
        let first = PermissionEditPreview(oldText: .init(bounding: "a - b"), newText: .init(bounding: "a + b"), replacesAll: false)
        let second = PermissionEditPreview(oldText: .init(bounding: "x"), newText: .init(bounding: "y"), replacesAll: true)
        let diff = PermissionRequestPreviewProjection.diff(edits: [first, second], omittedEditCount: 1)
        let captions = diff.lines.filter { $0.kind == .separator }.map(\.text)
        XCTAssertEqual(captions, [
            L10n.format("Edit %lld of %lld", Int64(1), Int64(3)),
            L10n.format("Edit %lld of %lld", Int64(2), Int64(3)) + " · " + L10n.string("Replaces every occurrence")
        ])
        XCTAssertEqual(diff.omittedEditCount, 1)

        let single = PermissionRequestPreviewProjection.diff(edits: [second])
        XCTAssertEqual(single.lines.first?.kind, .separator)
        XCTAssertEqual(single.lines.first?.text, L10n.string("Replaces every occurrence"))

        let unchanged = PermissionEditPreview(oldText: .init(bounding: "same"), newText: .init(bounding: "same"), replacesAll: false)
        XCTAssertEqual(PermissionRequestPreviewProjection.diff(edits: [unchanged]).lines, [])
    }

    func testAWriteDrawsItsContentAsAddedLinesWithinTheBound() {
        let content = PermissionPreviewText(bounding: (1...450).map { "row \($0)" }.joined(separator: "\n"))
        let diff = PermissionRequestPreviewProjection.content(content)
        XCTAssertEqual(diff.lines.count, 200)
        XCTAssertTrue(diff.lines.allSatisfy { $0.kind == .addition })
        XCTAssertEqual(diff.hiddenLineCount, 250)

        let manyLines = PermissionEditPreview(
            oldText: .init(text: "", omittedLineCount: 0),
            newText: .init(text: (1...500).map { "n\($0)" }.joined(separator: "\n"), omittedLineCount: 0),
            replacesAll: false
        )
        let drawn = PermissionRequestPreviewProjection.diff(edits: [manyLines])
        XCTAssertEqual(drawn.lines.count, PermissionRequestPreviewProjection.lineLimit)
        XCTAssertEqual(drawn.hiddenLineCount, 100)
        XCTAssertEqual(drawn.additions, 500)
    }

    func testTheCardsOwnSummaryIsHiddenOnlyWhenThePreviewRepeatsIt() {
        let edit = PermissionRequestPreview.edits(path: calcPath, edits: [], omittedEditCount: 0)
        XCTAssertTrue(edit.repeats("calc.py"))
        XCTAssertTrue(edit.repeats(calcPath))
        XCTAssertFalse(edit.repeats("Claude wants to edit a file outside the project"))
        let bash = PermissionRequestPreview.command(.init(bounding: "ls"), description: "List files")
        XCTAssertTrue(bash.repeats("List files"))
        XCTAssertFalse(bash.repeats("Network access"))
    }

    // MARK: - Saved transcripts

    func testThePreviewAndToolCallSurviveASavedTranscriptAndOldCardsKeepDecoding() throws {
        let request = PermissionRequest(
            id: "permission-1", title: "Edit", detail: "calc.py", command: nil,
            toolCallID: "toolu_01", preview: ClaudeProtocol.preview(toolName: "Edit", input: editInput)
        )
        let decoded = try JSONDecoder().decode(PermissionRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)

        let legacy = try JSONDecoder().decode(PermissionRequest.self, from: Data(
            #"{"id":"permission-1","title":"Run command","command":"git status"}"#.utf8))
        XCTAssertNil(legacy.toolCallID)
        XCTAssertNil(legacy.preview)

        let unreadable = try JSONDecoder().decode(PermissionRequest.self, from: Data(
            #"{"id":"permission-2","title":"Edit","toolCallID":"toolu_02","preview":{"notebook":{}}}"#.utf8))
        XCTAssertEqual(unreadable.toolCallID, "toolu_02")
        XCTAssertNil(unreadable.preview)
    }

    // MARK: - Folding an answered request into its tool card

    func testAnAllowedRequestReadsOnItsToolCardWhileOthersKeepTheirCards() {
        let user = TranscriptEntry(content: .user(text: "Fix the tests"))
        func tool(_ id: String) -> TranscriptEntry {
            TranscriptEntry(content: .activity(HarnessActivity(id: id, kind: "Edit", title: "Edit"), state: .completed))
        }
        func request(_ id: String, tool: String?, _ state: TranscriptPermissionState,
                     structured: PermissionRequestStructure? = nil) -> TranscriptEntry {
            TranscriptEntry(content: .permission(PermissionRequest(
                id: id, title: "Edit", detail: nil, command: nil, structured: structured, toolCallID: tool
            ), state: state))
        }
        let allowed = request("p1", tool: "toolu_1", .allowed)
        let denied = request("p2", tool: "toolu_2", .denied)
        let pending = request("p3", tool: "toolu_3", .pending)
        let orphan = request("p4", tool: "toolu_gone", .allowed)
        let unlinked = request("p5", tool: nil, .allowed)
        let answered = request("p6", tool: "toolu_6", .allowed, structured: .plan("## Plan"))
        let editTool = tool("toolu_1")
        let entries = [user, editTool, allowed, tool("toolu_2"), denied, tool("toolu_3"), pending,
                       orphan, unlinked, tool("toolu_6"), answered]

        XCTAssertEqual(TranscriptConversationProjection.approvedToolCallIDs(in: entries), ["toolu_1"])
        let turn = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .waitingForApproval, latestTurnIsComplete: false
        ).turns[0]
        var shown = Set((turn.prompt + turn.work + turn.answers).map(\.id))
        for request in turn.requests {
            if case let .transcript(entry) = request.source { shown.insert(entry.id.uuidString) }
        }
        XCTAssertFalse(shown.contains(allowed.id.uuidString))
        for kept in [denied, pending, orphan, unlinked, answered] {
            XCTAssertTrue(shown.contains(kept.id.uuidString))
        }

        // Folded inside a finished turn's work details as well.
        let final = TranscriptEntry(content: .assistant(text: "Done", isStreaming: false))
        let finished = TranscriptConversationProjection.presentation(
            from: [user, editTool, allowed, final], harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        ).turns[0]
        XCTAssertTrue(finished.foldsWork, "the finished turn's work was not folded")
        XCTAssertEqual(finished.work.map(\.id), [editTool.id.uuidString])
    }

    // MARK: - The route the app ships

    func testThePreviewAndToolCallCrossTheYHPRouteTheAppShips() async throws {
        let transport = FakeClaudeTransport()
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport }),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let handle = try await routed.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil
        ))
        let recorder = PreviewEventRecorder()
        let collector = Task {
            for await event in await routed.events(for: handle) { await recorder.append(event.payload) }
        }
        defer { collector.cancel() }

        await transport.emit(.object([
            "type": .string("control_request"),
            "request_id": .string("edit-1"),
            "request": .object([
                "subtype": .string("can_use_tool"),
                "tool_name": .string("Edit"),
                "display_name": .string("Edit"),
                "description": .string("calc.py"),
                "tool_use_id": .string("toolu_01Edit"),
                "input": editInput
            ])
        ]))
        let deadline = ContinuousClock.now + testWaitLimit
        var request: PermissionRequest?
        while request == nil, ContinuousClock.now < deadline {
            request = await recorder.permission()
            try await Task.sleep(for: .milliseconds(20))
        }
        let received = try XCTUnwrap(request)
        XCTAssertEqual(received.toolCallID, "toolu_01Edit")
        XCTAssertEqual(received.preview, ClaudeProtocol.preview(toolName: "Edit", input: editInput))
        await routed.close(handle)
    }
}

private actor PreviewEventRecorder {
    private var payloads: [HarnessEventPayload] = []

    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }

    func permission() -> PermissionRequest? {
        payloads.compactMap { payload -> PermissionRequest? in
            guard case let .permissionRequested(request) = payload else { return nil }
            return request
        }.last
    }
}
