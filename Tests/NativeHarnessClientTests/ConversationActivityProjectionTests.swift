import Foundation
import XCTest
@testable import NativeHarnessClient

/// Plan M12b: each harness's calls projected onto the cards they converge on, the file changes in
/// the Codex card's rows, Claude Code's edits carrying their change from its own frames, and a
/// transcript's latest turn as the review panel's Last turn (D8).
final class ConversationActivityProjectionTests: XCTestCase {
    private let workspace = URL(filePath: "/tmp/yardlet-activity-fixture", directoryHint: .isDirectory)

    // MARK: - Cards

    func testClaudeCallsProjectToTheirCards() throws {
        let path = workspace.appending(path: "calc.py").path(percentEncoded: false)
        let bash = HarnessActivity(id: "bash", kind: "Bash", title: "Bash", detail: "python3 test_calc.py",
                                   input: "python3 test_calc.py\n\ndescription: Run the calc tests",
                                   output: "Ran 3 tests")
        let edit = HarnessActivity(id: "edit", kind: "Edit", title: "Edit", input: path,
                                   diff: HarnessActivityDiff(path: path, oldText: "return a - b", newText: "return a + b"))
        let write = HarnessActivity(id: "write", kind: "Write", title: "Write", input: path,
                                    diff: HarnessActivityDiff(path: path, newText: "one\ntwo\n"))
        let read = HarnessActivity(id: "read", kind: "Read", title: "Read", input: "calc.py", output: "import sys")
        let agent = HarnessActivity(id: "agent", kind: "Agent", title: "Review the fix", input: "Review calc.py",
                                    output: "Looks right", subtask: HarnessSubtaskReference(taskID: "t1", taskType: "local_agent"))
        let allowed = PermissionRequest(id: "allow", title: "Bash", detail: nil, command: "python3 test_calc.py",
                                        toolCallID: "bash")
        let entries: [TranscriptEntry] = [
            TranscriptEntry(content: .user(text: "Fix calc.py")),
            TranscriptEntry(content: .activity(bash, state: .completed)),
            TranscriptEntry(content: .permission(allowed, state: .allowed)),
            TranscriptEntry(content: .activity(edit, state: .completed)),
            TranscriptEntry(content: .activity(write, state: .running)),
            TranscriptEntry(content: .activity(read, state: .failed)),
            TranscriptEntry(content: .activity(agent, state: .running))
        ]
        let turn = try XCTUnwrap(TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .running, latestTurnIsComplete: false
        ).turns.first)
        XCTAssertEqual(turn.work.count, 5, "the allowed request is the command card's mark")

        guard case let .command(command) = turn.work[0].kind else { return XCTFail("\(turn.work[0].kind)") }
        XCTAssertEqual(command.command, "python3 test_calc.py")
        XCTAssertEqual(command.status, "completed")
        XCTAssertEqual(command.output, "Ran 3 tests")
        XCTAssertNil(command.exitCode)
        XCTAssertTrue(command.isApproved)

        guard case let .fileChange(change) = turn.work[1].kind else { return XCTFail("\(turn.work[1].kind)") }
        XCTAssertTrue(change.placesRowsInWorkspace)
        let row = try XCTUnwrap(change.rows.first)
        XCTAssertEqual(row.kind, .update)
        XCTAssertEqual(row.state, .applied)
        XCTAssertEqual(row.verb, L10n.string("Edited"))
        XCTAssertEqual(row.lineCounts, .init(additions: 1, deletions: 1))
        XCTAssertEqual(row.previewLines.lines.map(\.kind), [.deletion, .addition])
        XCTAssertEqual(row.previewLines.lines.map(\.number), [nil, nil], "the call does not say where the text was")
        XCTAssertEqual(row.displayPath, path, "a transcript does not know the task's folder")
        let placed = row.placed(in: workspace)
        XCTAssertEqual(placed.displayPath, "calc.py")
        XCTAssertEqual(placed.fileName, "calc.py")
        XCTAssertEqual(placed.fileURL?.path(percentEncoded: false), path)

        guard case let .fileChange(created) = turn.work[2].kind else { return XCTFail("\(turn.work[2].kind)") }
        XCTAssertEqual(created.rows.first?.kind, .add)
        XCTAssertEqual(created.rows.first?.state, .inProgress)
        XCTAssertEqual(created.rows.first?.verb, L10n.string("Creating"))
        XCTAssertEqual(created.rows.first?.lineCounts, .init(additions: 2, deletions: 0))

        guard case let .tool(tool) = turn.work[3].kind else { return XCTFail("\(turn.work[3].kind)") }
        XCTAssertEqual(tool.kind, .activity("Read"))
        XCTAssertEqual(tool.name, "Read")
        XCTAssertEqual(tool.input, "calc.py")
        XCTAssertEqual(tool.output, "import sys")
        XCTAssertEqual(turn.work[3].phase, .failed)

        guard case let .subagent(subagent) = turn.work[4].kind else { return XCTFail("\(turn.work[4].kind)") }
        XCTAssertEqual(subagent.title, "Review the fix")
        XCTAssertEqual(subagent.kind, "Agent")
        XCTAssertEqual(subagent.input, "Review calc.py")
        XCTAssertEqual(subagent.output, "Looks right")
        XCTAssertEqual(subagent.routes, [.harnessSubtask(agent.subtask!, activityID: "agent")])

        for item in turn.work {
            XCTAssertNotNil(item.copyDetails, "\(item.kind)")
        }
        XCTAssertEqual(turn.work[0].copyDetails, "Bash\npython3 test_calc.py\n\ndescription: Run the calc tests\nRan 3 tests")
    }

    /// Only Claude Code's Bash call names its command apart from its arguments; another harness's
    /// call of the same name stays a tool card. Every harness's file change is the file change card.
    func testOtherHarnessesKeepTheToolCardAndShareTheFileChangeCard() throws {
        let bash = HarnessActivity(id: "bash", kind: "Bash", title: "Bash", detail: "ls", input: "ls")
        let edit = HarnessActivity(id: "edit", kind: "edit", title: "Apply the patch",
                                   diff: HarnessActivityDiff(path: "/tmp/README.md", oldText: "# A\n", newText: "# B\n"))
        let turn = try XCTUnwrap(TranscriptConversationProjection.presentation(
            from: [TranscriptEntry(content: .user(text: "Go")),
                   TranscriptEntry(content: .activity(bash, state: .completed)),
                   TranscriptEntry(content: .activity(edit, state: .completed))],
            harness: .openCode, status: .running, latestTurnIsComplete: false
        ).turns.first)
        guard case .tool = turn.work[0].kind else { return XCTFail("\(turn.work[0].kind)") }
        guard case let .fileChange(change) = turn.work[1].kind else { return XCTFail("\(turn.work[1].kind)") }
        XCTAssertEqual(change.rows.first?.lineCounts, .init(additions: 1, deletions: 1))
    }

    func testAnEditsStateReadsAsTheCodexCardsVerb() {
        let diff = HarnessActivityDiff(path: "/tmp/a.swift", oldText: "a", newText: "b")
        let cases: [(ConversationItemPhase, CodexFileChangeCardProjection.State, String)] = [
            (.running, .inProgress, "Editing"), (.stopped, .stopped, "Stopped editing"),
            (.completed, .applied, "Edited"), (.failed, .rejected, "Rejected")
        ]
        for (phase, state, verb) in cases {
            let row = ConversationFileChangeProjection.row(for: diff, phase: phase, workspaceURL: nil)
            XCTAssertEqual(row.state, state, "\(phase)")
            XCTAssertEqual(row.verb, L10n.string(verb), "\(phase)")
        }
        let failed = HarnessActivity(id: "e", kind: "Edit", title: "Edit", outcome: .failed,
                                     output: "String to replace not found", diff: diff)
        guard case let .fileChange(change) = ConversationActivityProjection.kind(
            failed, harness: .claudeCode, phase: .failed, isApproved: false
        ) else { return XCTFail("not a file change") }
        XCTAssertEqual(change.errorMessage, "String to replace not found")
    }

    /// An applied Claude edit carries the hunks its result named; the card reads them as Codex reads
    /// a patch, with their line numbers.
    func testHunksKeepTheirLineNumbers() throws {
        let diff = HarnessActivityDiff(
            path: "/tmp/calc.py",
            unified: "@@ -10,3 +10,3 @@\n def add(a, b):\n-    return a - b\n+    return a + b\n     # done\n"
        )
        let row = ConversationFileChangeProjection.row(for: diff, phase: .completed, workspaceURL: nil)
        XCTAssertNil(row.precomputedPreview)
        XCTAssertEqual(row.lineCounts, .init(additions: 1, deletions: 1))
        XCTAssertEqual(row.previewLines.lines.map(\.number), [10, 11, 11, 12])
        XCTAssertEqual(row.previewLines.firstChangedLine, 11)
    }

    func testLargeContentsAreLeftToTheChangesPanel() {
        let large = String(repeating: "x", count: CodexFileChangeCardProjection.fileByteLimit + 1)
        let row = ConversationFileChangeProjection.row(
            for: HarnessActivityDiff(path: "/tmp/big.txt", newText: large), phase: .completed, workspaceURL: nil
        )
        XCTAssertEqual(row.preview, .tooLarge)
        XCTAssertNil(row.lineCounts)
    }

    func testTextFileChangeDefersPreviewLinesUntilRequestedAndPreservesExactCountsAndLines() {
        let prefix = (1...600).map { "let line\($0) = \"unchanged payload \($0)\"" }.joined(separator: "\n")
        let suffix = (602...1200).map { "let tail\($0) = \"unchanged tail \($0)\"" }.joined(separator: "\n")
        let oldText = prefix + "\nlet changed = 1\n" + suffix + "\n"
        let newText = prefix + "\nlet changed = 2\nlet added = 3\n" + suffix + "\n"

        let diff = HarnessActivityDiff(path: "/tmp/Big.swift", oldText: oldText, newText: newText)
        let row = ConversationFileChangeProjection.row(for: diff, phase: .completed, workspaceURL: nil)
        XCTAssertNil(row.precomputedPreview, "Folded row should defer preview line construction until opened")
        XCTAssertEqual(row.preview, .available)
        XCTAssertEqual(row.lineCounts, .init(additions: 2, deletions: 1))

        let placed = row.placed(in: workspace)
        XCTAssertNil(placed.precomputedPreview)
        let preview = placed.previewLines
        XCTAssertEqual(preview.lines.filter { $0.kind == .deletion }.map(\.text), ["let changed = 1"])
        XCTAssertEqual(preview.lines.filter { $0.kind == .addition }.map(\.text), ["let changed = 2", "let added = 3"])
        XCTAssertEqual(preview.lines.filter { $0.kind == .context }.count, 6)

        // CRLF, trailing newline, add-only, delete-only, and identical edge cases match exact line counts.
        let crlf = ConversationFileChangeProjection.row(
            for: HarnessActivityDiff(path: "/tmp/win.txt", oldText: "a\r\nb\r\n", newText: "a\r\nc\r\nd\r\n"),
            phase: .completed, workspaceURL: nil
        )
        XCTAssertEqual(crlf.lineCounts, .init(additions: 2, deletions: 1))
        let addOnly = ConversationFileChangeProjection.row(
            for: HarnessActivityDiff(path: "/tmp/new.txt", newText: "one\ntwo\n"),
            phase: .completed, workspaceURL: nil
        )
        XCTAssertEqual(addOnly.lineCounts, .init(additions: 2, deletions: 0))
        XCTAssertEqual(addOnly.previewLines.lines.map(\.text), ["one", "two"])
        let deleteOnly = ConversationFileChangeProjection.row(
            for: HarnessActivityDiff(path: "/tmp/old.txt", oldText: "one\ntwo"),
            phase: .completed, workspaceURL: nil
        )
        XCTAssertEqual(deleteOnly.lineCounts, .init(additions: 0, deletions: 2))
        let unchanged = ConversationFileChangeProjection.row(
            for: HarnessActivityDiff(path: "/tmp/same.txt", oldText: "same\n", newText: "same"),
            phase: .completed, workspaceURL: nil
        )
        XCTAssertNil(unchanged.lineCounts)

        // Large LF <-> CRLF file over maxDiffLines agrees with changedLines (0 changes, not +2500 -2500).
        let manyLF = (1...2500).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let manyCRLF = (1...2500).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n"
        let eolOnly = ConversationFileChangeProjection.row(
            for: HarnessActivityDiff(path: "/tmp/eol.txt", oldText: manyLF, newText: manyCRLF),
            phase: .completed, workspaceURL: nil
        )
        XCTAssertNil(eolOnly.lineCounts)
        XCTAssertTrue(eolOnly.previewLines.lines.isEmpty)
    }

    // MARK: - Codex

    func testCodexToolsAndSubagentsCarryWhatTheirCardsShow() throws {
        let decoder = CodexTaskDecoder()
        func item(_ value: JSONValue) -> ConversationItem {
            CodexConversationProjection.item(
                decoder.item(from: value, fallbackID: "x", lifecycle: .completed), turnID: "turn-1",
                isTurnFinished: true, workspaceURL: workspace, changes: [], isHistoryMatch: false
            )
        }
        let dynamic = item(.object([
            "id": .string("d1"), "type": .string("dynamicToolCall"), "tool": .string("lookup"),
            "status": .string("failed"), "arguments": .object(["q": .string("calc")]),
            "contentItems": .array([.object(["type": .string("inputText"), "text": .string("No result")])])
        ]))
        guard case let .tool(tool) = dynamic.kind else { return XCTFail("\(dynamic.kind)") }
        XCTAssertEqual(tool.kind, .dynamic)
        XCTAssertEqual(tool.input, JSONValue.object(["q": .string("calc")]).readableText)
        XCTAssertEqual(tool.output, "No result")
        XCTAssertEqual(dynamic.phase, .failed)
        XCTAssertNotNil(dynamic.copyDetails)

        let collaboration = item(.object([
            "id": .string("c1"), "type": .string("collabAgentToolCall"), "tool": .string("spawn_agent"),
            "status": .string("completed"), "senderThreadId": .string("thread-1"),
            "receiverThreadIds": .array([.string("child-1")]), "prompt": .string("Review the diff"),
            "agentsStates": .object([:])
        ]))
        guard case let .subagent(subagent) = collaboration.kind else { return XCTFail("\(collaboration.kind)") }
        XCTAssertEqual(subagent.routes, [.codexThread("child-1")])
        XCTAssertEqual(subagent.input, "Review the diff")

        let message = item(.object([
            "id": .string("m1"), "type": .string("agentMessage"), "text": .string("Done"), "phase": .string("final_answer")
        ]))
        // A message offers its item details in its context menu (M12f), beside its own copy button.
        XCTAssertEqual(message.copyDetails?.contains("Done"), true, "\(String(describing: message.copyDetails))")
    }

    // MARK: - Claude Code frames

    func testClaudeEditAndWriteCallsCarryTheirChange() throws {
        let edit = try decode(##"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"edit-1","name":"Edit","input":{"file_path":"/tmp/calc.py","old_string":"a - b","new_string":"a + b"}},{"type":"tool_use","id":"write-1","name":"Write","input":{"file_path":"/tmp/notes.md","content":"# Notes\n"}},{"type":"tool_use","id":"bash-1","name":"Bash","input":{"command":"ls"}}]}}"##)
        let started = ClaudeEventProjector().payloads(from: edit).compactMap { payload -> HarnessActivity? in
            if case let .activityStarted(activity) = payload { return activity }
            return nil
        }
        XCTAssertEqual(started.map(\.diff), [
            HarnessActivityDiff(path: "/tmp/calc.py", oldText: "a - b", newText: "a + b"),
            HarnessActivityDiff(path: "/tmp/notes.md", newText: "# Notes\n"),
            nil
        ])
    }

    /// The result's typed form names the hunks the edit applied; they replace the call's text. A new
    /// file's result names none, and a result that is not the frame's only one is not read.
    func testAnAppliedClaudeEditCarriesTheHunksItsResultNamed() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Fix it")
        let frames = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"edit-1","name":"Edit","input":{"file_path":"/tmp/calc.py","old_string":"    return a - b","new_string":"    return a + b"}}]}}"#,
            #"{"type":"user","tool_use_result":{"filePath":"/tmp/calc.py","oldString":"    return a - b","newString":"    return a + b","structuredPatch":[{"oldStart":10,"oldLines":2,"newStart":10,"newLines":2,"lines":[" def add(a, b):","-    return a - b","+    return a + b"]}]},"message":{"content":[{"type":"tool_result","tool_use_id":"edit-1","content":"The file has been updated."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"write-1","name":"Write","input":{"file_path":"/tmp/new.md","content":"hello\n"}}]}}"#,
            #"{"type":"user","tool_use_result":{"type":"create","filePath":"/tmp/new.md","content":"hello\n","structuredPatch":[]},"message":{"content":[{"type":"tool_result","tool_use_id":"write-1","content":"File created"}]}}"#
        ]
        for json in frames {
            for payload in projection.payloads(from: try decode(json)) { builder.apply(payload) }
        }
        let activities = builder.entries.compactMap { entry -> (HarnessActivity, TranscriptActivityState)? in
            if case let .activity(activity, state) = entry.content { return (activity, state) }
            return nil
        }
        XCTAssertEqual(activities.map(\.1), [.completed, .completed])
        XCTAssertEqual(activities[0].0.diff, HarnessActivityDiff(
            path: "/tmp/calc.py", unified: "@@ -10,2 +10,2 @@\n def add(a, b):\n-    return a - b\n+    return a + b\n"
        ))
        XCTAssertEqual(activities[1].0.diff, HarnessActivityDiff(path: "/tmp/new.md", newText: "hello\n"))
    }

    // MARK: - Last turn (D8)

    func testWholeFileContentsBecomeNumberedHunks() {
        let old = (1...10).map { "line \($0)" }
        var new = old
        new[4] = "LINE 5"
        XCTAssertEqual(ConversationFileChangeProjection.hunks(old: old, new: new), [
            "@@ -2,7 +2,7 @@", " line 2", " line 3", " line 4", "-line 5", "+LINE 5", " line 6", " line 7", " line 8"
        ])
        XCTAssertEqual(ConversationFileChangeProjection.hunks(old: ["a"], new: ["a", "b"]), ["@@ -1,1 +1,2 @@", " a", "+b"])
        XCTAssertEqual(ConversationFileChangeProjection.hunks(old: [], new: ["a"]), ["@@ -0,0 +1,1 @@", "+a"])
        XCTAssertEqual(ConversationFileChangeProjection.hunks(old: ["a"], new: ["a"]), [])

        let text = ConversationFileChangeProjection.unifiedDiff(
            for: HarnessActivityDiff(path: workspace.appending(path: "a.txt").path(percentEncoded: false),
                                     oldText: old.joined(separator: "\n"), newText: new.joined(separator: "\n")),
            workspaceURL: workspace
        )
        let snapshot = UnifiedDiffParser().parse(text ?? "")
        XCTAssertEqual(snapshot.files.map(\.path), ["a.txt"])
        XCTAssertEqual(snapshot.lines.first { $0.kind == .addition }?.newLine, 5)
        XCTAssertEqual(snapshot.lines.first { $0.kind == .deletion }?.oldLine, 5)
    }

    func testLastTurnReadsTheLatestTurnsAppliedChanges() throws {
        func file(_ name: String) -> String { workspace.appending(path: name).path(percentEncoded: false) }
        func call(_ id: String, _ diff: HarnessActivityDiff, _ state: TranscriptActivityState) -> TranscriptEntry {
            TranscriptEntry(content: .activity(HarnessActivity(id: id, kind: "Edit", title: "Edit", diff: diff), state: state))
        }
        let hunk = "@@ -1,1 +1,1 @@\n-a\n+b\n"
        let latest = TranscriptEntry(content: .user(text: "Second"))
        let entries: [TranscriptEntry] = [
            TranscriptEntry(content: .user(text: "First")),
            call("earlier", HarnessActivityDiff(path: file("earlier.txt"), unified: hunk), .completed),
            latest,
            call("applied", HarnessActivityDiff(path: file("applied.txt"), unified: hunk), .completed),
            call("running", HarnessActivityDiff(path: file("running.txt"), unified: hunk), .running),
            call("failed", HarnessActivityDiff(path: file("failed.txt"), unified: hunk), .failed),
            call("unplaced", HarnessActivityDiff(path: file("unplaced.txt"), oldText: "a", newText: "b"), .completed),
            call("created", HarnessActivityDiff(path: file("created.txt"), newText: "new\n"), .completed),
            TranscriptEntry(content: .user(text: ClaudeBashMessage.text(command: "ls", stdout: "a.txt")))
        ]
        XCTAssertTrue(ConversationFileChangeProjection.carriesFileChanges(entries))
        let diff = try XCTUnwrap(ConversationFileChangeProjection.lastTurnDiff(
            entries: entries, harness: .claudeCode, isRunning: false, workspaceURL: workspace
        ))
        XCTAssertEqual(diff.turnID, latest.id.uuidString, "a bash command runs no turn of the model's")
        let files = UnifiedDiffParser().parse(diff.text).files
        XCTAssertEqual(files.map(\.path), ["applied.txt", "created.txt"],
                       "an Edit call's text alone does not say where in the file it landed")
        XCTAssertEqual(files.map(\.status), [L10n.string("Modified"), L10n.string("Added")])

        // Another harness's old and new contents are the whole file. (Its tasks have no bash
        // commands; the last entry would be a request of its own.)
        let other = try XCTUnwrap(ConversationFileChangeProjection.lastTurnDiff(
            entries: Array(entries.dropLast()), harness: .openCode, isRunning: true, workspaceURL: workspace
        ))
        XCTAssertEqual(UnifiedDiffParser().parse(other.text).files.map(\.path), ["applied.txt", "unplaced.txt", "created.txt"])
        XCTAssertTrue(other.isRunning)

        XCTAssertNil(ConversationFileChangeProjection.lastTurnDiff(
            entries: [], harness: .claudeCode, isRunning: false, workspaceURL: workspace
        ))
        XCTAssertFalse(ConversationFileChangeProjection.carriesFileChanges([latest]))
    }

    /// D8: the review panel offers Last turn to a harness other than Codex once its calls report
    /// the file changes they made, and not before.
    func testLastTurnIsOfferedOnceCallsReportFileChanges() {
        let request = TranscriptEntry(content: .user(text: "Fix it"))
        let read = TranscriptEntry(content: .activity(HarnessActivity(id: "r", kind: "Read", title: "Read"),
                                                      state: .completed))
        XCTAssertEqual(ReviewLastTurn.transcript([request, read], harness: .claudeCode, isRunning: false,
                                                 workspaceURL: workspace), .notOffered)
        let edit = TranscriptEntry(content: .activity(HarnessActivity(
            id: "e", kind: "Write", title: "Write",
            diff: HarnessActivityDiff(path: workspace.appending(path: "a.txt").path(percentEncoded: false), newText: "a\n")
        ), state: .completed))
        let offered = ReviewLastTurn.transcript([request, read, edit], harness: .claudeCode, isRunning: true,
                                                workspaceURL: workspace)
        XCTAssertTrue(offered.isOffered)
        XCTAssertEqual(offered.diff?.turnID, request.id.uuidString)
        XCTAssertEqual(offered.diff?.isRunning, true)
        XCTAssertEqual(UnifiedDiffParser().parse(offered.diff?.text ?? "").files.map(\.path), ["a.txt"])
        // A later request with no changes yet reads as an empty last turn, which the panel names.
        let next = TranscriptEntry(content: .user(text: "Now the tests"))
        XCTAssertEqual(ReviewLastTurn.transcript([request, read, edit, next], harness: .claudeCode, isRunning: true,
                                                 workspaceURL: workspace).diff?.text, "")
    }

    private func decode(_ json: String) throws -> JSONValue {
        try ClaudeWireCodec().decodeLine(Data(json.utf8))
    }
}
