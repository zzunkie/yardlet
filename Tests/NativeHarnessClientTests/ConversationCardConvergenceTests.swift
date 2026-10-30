import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The converged cards (plan M12): every harness's calls, plans and usage drawn with the same cards.
/// Each conversation is drawn in an unshown window, and the checks name what it lists.
///
/// Review images: `.build/conversation-m12-qa/<name>-{light,dark}.png` for a Codex thread, a Claude
/// Code task and an OpenCode (ACP) task, and every drawing's element list in `<name>-ax.txt`.
@MainActor
final class ConversationCardConvergenceTests: XCTestCase {
    static let workspace = URL(filePath: "/tmp/yardlet-m12-fixture", directoryHint: .isDirectory)

    // MARK: - M12b: calls

    /// Claude Code: the Bash call, Edit and Write (with the Codex diff box) and any other call are
    /// status lines (2026-10-15), the run of calls folded into a summary line that opens when a call in
    /// it fails; a failed edit reads "Rejected" and opens on its reason; a running call starts folded,
    /// and the running command is the live line's (2026-10-16); the subagent's open and stop controls
    /// show without opening its details. A finished turn folds its failed call with the rest of its
    /// work (D2).
    func testClaudeCallsDrawTheConvergedCards() throws {
        let drawn = try drawTranscript(ConvergenceFixtures.claude(), harness: .claudeCode, name: "claude",
                                       height: 1_500)
        let new = drawn
        // Claude Code counts the files edited by their paths: calc.py twice is one file.
        let summary = ["Edited a file", "Created a file", "Read a file"].map { L10n.string($0) }.enumerated()
            .map { index, phrase in
                index > 0 && phrase.first?.isASCII == true ? phrase.prefix(1).lowercased() + phrase.dropFirst() : phrase
            }
        XCTAssertTrue(new.contains(label: summary.joined(separator: ", "), value: L10n.string("Expanded")), "\(new)")
        let npm = ConversationLineWording.command(ConversationCommand(command: "npm test", status: ""), phase: .running,
                                                  harness: .claudeCode).map(\.text).joined(separator: ", ")
        XCTAssertTrue(new.contains { $0.label.hasPrefix(npm + ", ") && $0.value == L10n.string("Collapsed") },
                      "the running command is the live line's: \(new)")
        XCTAssertTrue(new.contains(L10n.string("File change"), followedBy: [L10n.string("Edited") + " calc.py"]), "\(new)")
        XCTAssertTrue(new.contains(L10n.string("File change"), followedBy: [L10n.string("Created") + " notes.md"]), "\(new)")
        XCTAssertTrue(new.contains(L10n.string("File change"), followedBy: [L10n.string("Rejected") + " calc.py",
                                                                           "String to replace not found in file."]),
                      "\(new)")
        XCTAssertFalse(new.contains("Read", followedBy: [L10n.string("Input")]), "a running call starts folded: \(new)")
        XCTAssertTrue(new.contains("Review the fix", followedBy: [L10n.string("Open child task"), L10n.string("Stop task")]),
                      "the controls show while the subagent's details are folded: \(new)")
        XCTAssertTrue(new.contains(label: L10n.string("Copy item details")))
        XCTAssertFalse(new.contains(text: "No matches found"), "the finished turn folds its failed call (D2)")
        XCTAssertFalse(new.contains(text: "Grep"))
        // The fold reads the turn's work time when its entries give one (D4, M12e), else "Work details".
        let workTimes = ["Worked for %lld seconds", "Worked for %lld minutes"].map { format in
            NSRegularExpression.escapedPattern(for: L10n.format(format, 7)).replacingOccurrences(of: "7", with: "\\d+")
        }
        XCTAssertTrue(new.contains { element in
            element.label == L10n.string("Work details")
                || workTimes.contains { element.label.range(of: "^\($0)$", options: .regularExpression) != nil }
        }, "\(new)")
    }

    /// Codex: commands, file changes and every other call are the same status lines (2026-10-15), a
    /// finished command folded on its output, a failed call open on what it was given; a child thread
    /// is the shared subagent card, which still opens the child as its own task.
    func testCodexCallsDrawTheConvergedCards() throws {
        let state = ConvergenceFixtures.codex()
        let drawn = try draw(name: "codex", height: 1_500) {
            TaskConversationView(
                harness: .codex, workspaceURL: Self.workspace, entries: [], sessionStatus: .running,
                codexTaskState: state, actions: ConversationActions(openCodexSubagent: { _ in })
            )
        }
        let new = drawn
        // The Codex app's words for a command it ran ("Ran …", with the verb last in Korean).
        let ran = ConversationLineWording.codex(.unknown(command: "swift test --filter Reducer"), phase: .completed).text
        XCTAssertTrue(new.contains(L10n.string("Command"), followedBy: [ran]), "\(new)")
        XCTAssertTrue(new.contains(label: ran, value: L10n.string("Collapsed")), "\(new)")
        XCTAssertTrue(new.contains(L10n.string("File change"), followedBy: [L10n.string("Edited") + " A.swift"]), "\(new)")
        // A failed call opens itself and shows what it was given.
        XCTAssertTrue(new.contains("lookup", followedBy: [L10n.string("Tool call") + " lookup", L10n.string("Input")]),
                      "\(new)")
        XCTAssertTrue(new.contains { $0.label.hasSuffix("codex app server") || $0.value.hasSuffix("codex app server") }
                      && new.contains { $0.label.hasPrefix(L10n.string("Web search")) || $0.value.hasPrefix(L10n.string("Web search")) },
                      "\(new)")
        // A spawned agent is named by what it was asked; the call's name is its kind.
        XCTAssertTrue(new.contains("Check the docs", followedBy: ["spawn_agent", L10n.string("Completed"),
                                                                  L10n.string("Open child task")]), "\(new)")
    }

    /// OpenCode (ACP): a call that reports its file change is the file change card, its old and new
    /// contents diffed line by line. While the turn runs its calls stay folded in their summary
    /// (2026-10-16), which opens on them.
    func testACPCallsDrawTheConvergedCards() throws {
        let drawn = try drawTranscript(ConvergenceFixtures.openCode(), harness: .openCode, name: "opencode",
                                       height: 1_100)
        let summary = try XCTUnwrap(drawn.first { $0.role == NSAccessibility.Role.button.rawValue
            && $0.value == L10n.string("Collapsed") && $0.label.contains(L10n.string("Read a file")) }, "\(drawn)")
        let size = NSSize(width: 760, height: 1_100)
        let host = WindowlessRender.Host(
            TaskConversationView(harness: .openCode, workspaceURL: Self.workspace, entries: ConvergenceFixtures.openCode(),
                                 sessionStatus: .running, latestTurnIsComplete: false, actions: ConvergenceFixtures.actions())
                .environment(\.transcriptWorkspaceURL, Self.workspace)
                .frame(width: size.width, height: size.height),
            size: size, appearance: .light)
        defer { host.close() }
        host.settle()
        XCTAssertTrue(host.hosting.pressButton(labeled: summary.label))
        host.settle()
        let opened = host.accessibilityElements()
        XCTAssertTrue(opened.contains(L10n.string("File change"), followedBy: [L10n.string("Edited") + " README.md"]),
                      "\(opened)")
        XCTAssertTrue(opened.contains("Inspect provider output", followedBy: ["read Inspect provider output"]), "\(opened)")
    }

    /// Opening a file change's line draws the Codex diff box: a Claude edit's applied hunks with
    /// their line numbers, the same box as a Codex patch.
    func testAnOpenedClaudeEditShowsTheDiffBox() throws {
        let diff = HarnessActivityDiff(
            path: Self.workspace.appending(path: "calc.py").path(percentEncoded: false),
            unified: "@@ -10,2 +10,2 @@\n def add(a, b):\n-    return a - b\n+    return a + b\n"
        )
        let change = ConversationFileChange(
            rows: [ConversationFileChangeProjection.row(for: diff, phase: .completed, workspaceURL: nil)],
            handoffs: [], placesRowsInWorkspace: true
        )
        let item = ConversationItem(id: "edit", kind: .fileChange(change), phase: .completed,
                                    source: .transcript(TranscriptEntry(content: .plan(""))))
        let host = WindowlessRender.Host(
            ConversationWorkLine(item: item, harness: .claudeCode, workspaceURL: Self.workspace)
                .frame(width: 560, height: 220, alignment: .top),
            size: NSSize(width: 560, height: 220), appearance: .light
        )
        defer { host.close() }
        host.settle()
        let toggle = L10n.string("Edited") + " calc.py"
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: toggle), "the line's toggle")
        host.settle()
        let elements = host.accessibilityElements()
        XCTAssertTrue(elements.contains(label: toggle, value: L10n.string("Expanded")), "\(elements)")
        // The box names the file by its path and opens it.
        XCTAssertTrue(elements.contains(label: "calc.py", value: L10n.string("Open file")), "\(elements)")
        XCTAssertTrue(elements.contains { $0.value == "    return a + b" }, "\(elements)")
        XCTAssertTrue(elements.contains { $0.value == "11" }, "the applied hunk keeps its line numbers: \(elements)")
        try WindowlessRender.writePNG(host.capture().bitmap,
                                      to: WindowlessRender.directory("conversation-m12-qa").appending(path: "claude-edit-diff-box.png"))
    }

    // MARK: - M12c: plans

    /// Every harness's plan is the Codex step card: Claude Code's task list (☑/◉/☐) and an ACP
    /// plan (`[status] content`) as steps with their status marks, text that is not steps as one
    /// block in the same card.
    func testEveryHarnessPlanIsTheStepCard() throws {
        let cases: [(String, HarnessKind, String, [String])] = [
            ("plan-claude", .claudeCode, "☑ Run the tests\n◉ Fix add\n☐ Run them again",
             ["Run the tests", "Fix add", "Run them again"]),
            ("plan-opencode", .openCode, "[completed] Read the README\n[in_progress] Retitle it\n[pending] Check the links",
             ["Read the README", "Retitle it", "Check the links"]),
            ("plan-text", .grokBuild, "1. Preserve event order\n2. Group completed work", [])
        ]
        for (name, harness, text, steps) in cases {
            let drawn = try drawTranscript(ConvergenceFixtures.plan(text), harness: harness, name: name, height: 500)
            XCTAssertTrue(drawn.contains(label: L10n.string("Plan")), "\(name): \(drawn)")
            if steps.isEmpty {
                XCTAssertTrue(drawn.contains(text: text), "\(name) stays one block: \(drawn)")
            } else {
                XCTAssertTrue(drawn.contains(L10n.string("Plan"), followedBy: steps), "\(name): \(drawn)")
                XCTAssertFalse(drawn.contains(text: text))
            }
        }
    }

    // MARK: - M12g: context and usage

    /// A Codex thread's usage is in the context ring's details (D5), the same details every
    /// harness's ring opens onto.
    func testCodexUsageIsInTheContextRing() throws {
        let usage = CodexThreadTokenUsage(
            total: CodexTokenUsageBreakdown(inputTokens: 182_000, cachedInputTokens: 120_000, cacheWriteInputTokens: 0,
                                            outputTokens: 9_400, reasoningOutputTokens: 2_100, totalTokens: 191_400),
            last: CodexTokenUsageBreakdown(inputTokens: 61_000, cachedInputTokens: 48_000, cacheWriteInputTokens: 0,
                                           outputTokens: 3_000, reasoningOutputTokens: 800, totalTokens: 64_000),
            modelContextWindow: 256_000
        )
        let directory = try WindowlessRender.directory("conversation-m12-qa")
        let cases: [(String, HarnessProtocolUsage?, [ComposerUsageBreakdown], [String])] = [
            ("ring-codex", ComposerSessionOptionsProjection.codexContextUsage(usage), ComposerUsageBreakdown.codex(usage),
             [L10n.string("Last turn"), L10n.string("Cache write"), L10n.string("Cache hit"), L10n.string("Cumulative")]),
            ("ring-claude", HarnessProtocolUsage(inputTokens: 81_000, cachedInputTokens: 60_000, outputTokens: 2_400,
                                                 reasoningTokens: nil, totalCostUSD: 0.42, contextWindowTokens: 200_000,
                                                 contextUsedTokens: 81_000, extensionValues: [:]), [],
             [L10n.string("Usage"), L10n.string("Cost")])
        ]
        for (name, contextUsage, breakdowns, expected) in cases {
            let breakdowns = breakdowns.isEmpty ? ComposerUsageBreakdown.provider(contextUsage) : breakdowns
            for appearance in WindowlessRender.Appearance.allCases {
                let host = WindowlessRender.Host(
                    ComposerContextUsageDetails(
                        summary: try XCTUnwrap(ComposerContextSummary.make(usage: contextUsage, reportsContextWindow: true)),
                        usage: contextUsage, breakdowns: breakdowns)
                        .environment(\.colorScheme, appearance.colorScheme)
                        .frame(width: 260, height: 420, alignment: .top),
                    size: NSSize(width: 260, height: 420), appearance: appearance
                )
                defer { host.close() }
                host.settle()
                try WindowlessRender.writePNG(host.capture().bitmap,
                                              to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
                let elements = host.accessibilityElements()
                for text in expected {
                    XCTAssertTrue(elements.contains(text: text), "\(name) lists no \(text): \(elements)")
                }
            }
        }
    }

    // MARK: - Drawing

    /// Draws a task's transcript, writes the review images and element list, and returns the light
    /// drawing's elements.
    func drawTranscript(
        _ entries: [TranscriptEntry], harness: HarnessKind, name: String, height: CGFloat,
        status: SessionStatus = .running
    ) throws -> [WindowlessRender.AccessibilityElement] {
        try draw(name: name, height: height) {
            TaskConversationView(
                harness: harness, workspaceURL: Self.workspace, entries: entries, sessionStatus: status,
                latestTurnIsComplete: false, actions: ConvergenceFixtures.actions()
            )
        }
    }

    func draw<Content: View>(
        name: String, height: CGFloat, _ content: () -> Content
    ) throws -> [WindowlessRender.AccessibilityElement] {
        let directory = try WindowlessRender.directory("conversation-m12-qa")
        var drawn: [WindowlessRender.AccessibilityElement]?
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                content().environment(\.transcriptWorkspaceURL, Self.workspace),
                size: NSSize(width: 760, height: height), appearance: appearance
            )
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
            if appearance == .light { drawn = drawing.elements }
        }
        let elements = try XCTUnwrap(drawn)
        try (elements.map(\.description).joined(separator: "\n") + "\n").write(
            to: directory.appending(path: "\(name)-ax.txt"), atomically: true, encoding: .utf8
        )
        return elements
    }
}

extension [WindowlessRender.AccessibilityElement] {
    func contains(label: String, value: String? = nil) -> Bool {
        contains { $0.label == label && (value == nil || $0.value == value) }
    }

    /// An element labelled `label` with `texts` (labels or values) after it in reading order, within
    /// the next dozen elements: what one card lists. A container's own value is not listed.
    func contains(_ label: String, followedBy texts: [String]) -> Bool {
        indices.contains { start in
            guard self[start].label == label else { return false }
            var position = start
            for text in texts {
                let window = self[(position + 1)..<Swift.min(endIndex, start + 13)]
                guard let found = window.firstIndex(where: { $0.label == text || $0.value == text }) else { return false }
                position = found
            }
            return true
        }
    }

    func contains(text: String) -> Bool {
        contains { $0.label == text || $0.value == text }
    }
}

/// Conversations that reach every converged card, for each kind of harness.
@MainActor
enum ConvergenceFixtures {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func actions() -> ConversationActions {
        var actions = ClaudeConversationFixture.actions()
        actions.subtaskControls = HarnessActivityActions(open: { _ in }, stop: { _ in }, isStopping: { _ in false },
                                                         error: { _ in nil })
        return actions
    }

    private static func entries(_ contents: [TranscriptEntryContent]) -> [TranscriptEntry] {
        contents.enumerated().map { index, content in
            TranscriptEntry(createdAt: start.addingTimeInterval(Double(index) * 6), content: content)
        }
    }

    private static func path(_ name: String) -> String {
        ConversationCardConvergenceTests.workspace.appending(path: name).path(percentEncoded: false)
    }

    /// A Claude Code task: a finished turn whose Bash call was allowed and whose Grep failed, and a
    /// running turn with an applied edit (its hunks from the result), a new file, a rejected edit, a
    /// call in progress, a running subagent and a running command.
    static func claude() -> [TranscriptEntry] {
        let bash = HarnessActivity(id: "toolu_bash", kind: "Bash", title: "Bash", detail: "python3 test_calc.py",
                                   input: "python3 test_calc.py\n\ndescription: Run the calc tests",
                                   output: "Ran 3 tests\nFAILED (failures=1)")
        return entries([
            .user(text: "Fix the calc.py tests"),
            .activity(bash, state: .completed),
            .permission(PermissionRequest(id: "bash-1", title: "Bash", detail: "Run the calc tests",
                                          command: "python3 test_calc.py", toolCallID: "toolu_bash"), state: .allowed),
            .activity(HarnessActivity(id: "toolu_grep", kind: "Grep", title: "Grep", outcome: .failed,
                                      input: "License", output: "No matches found"), state: .failed),
            .plan("☑ Run the tests\n◉ Fix add\n☐ Run them again"),
            .assistant(text: "`add` subtracts; the fix is one line.", isStreaming: false),
            .user(text: "Apply the fix"),
            .activity(HarnessActivity(
                id: "toolu_edit", kind: "Edit", title: "Edit", input: path("calc.py"),
                diff: HarnessActivityDiff(path: path("calc.py"),
                                          unified: "@@ -10,2 +10,2 @@\n def add(a, b):\n-    return a - b\n+    return a + b\n")
            ), state: .completed),
            .activity(HarnessActivity(
                id: "toolu_write", kind: "Write", title: "Write", input: path("notes.md"),
                diff: HarnessActivityDiff(path: path("notes.md"), newText: "# Notes\n- add is fixed\n")
            ), state: .completed),
            .activity(HarnessActivity(
                id: "toolu_edit2", kind: "Edit", title: "Edit", outcome: .failed, input: path("calc.py"),
                output: "String to replace not found in file.",
                diff: HarnessActivityDiff(path: path("calc.py"), oldText: "return a * b", newText: "return a + b")
            ), state: .failed),
            .activity(HarnessActivity(id: "toolu_read", kind: "Read", title: "Read", input: path("test_calc.py")),
                      state: .running),
            .activity(HarnessActivity(
                id: "toolu_agent", kind: "Agent", title: "Review the fix", input: "Review calc.py",
                subtask: HarnessSubtaskReference(taskID: "task-1", agentID: "agent-1", taskType: "local_agent")
            ), state: .running),
            .activity(HarnessActivity(id: "toolu_npm", kind: "Bash", title: "Bash", detail: "npm test", input: "npm test"),
                      state: .running)
        ])
    }

    /// An OpenCode task: a call that read output, and an edit reporting the file's old and new
    /// contents, in a running turn.
    static func openCode() -> [TranscriptEntry] {
        entries([
            .user(text: "Retitle the README"),
            .activity(HarnessActivity(id: "read", kind: "read", title: "Inspect provider output",
                                      input: #"{"path":"README.md"}"#, output: "# Yardlet\n\nA workbench."),
                      state: .completed),
            .plan("[completed] Read the README\n[in_progress] Retitle it\n[pending] Check the links"),
            .activity(HarnessActivity(
                id: "edit", kind: "edit", title: "Apply the title", input: #"{"path":"README.md"}"#,
                diff: HarnessActivityDiff(path: path("README.md"), oldText: "# Yardlet\n\nA workbench.\n",
                                          newText: "# Yardlet workbench\n\nA workbench.\n")
            ), state: .completed),
            .assistant(text: "Retitling the README.", isStreaming: true)
        ])
    }

    /// A running turn that has made a plan.
    static func plan(_ text: String) -> [TranscriptEntry] {
        entries([
            .user(text: "Make a plan first"),
            .plan(text),
            .assistant(text: "Starting with the first step.", isStreaming: true)
        ])
    }

    /// A Codex thread with a command, a patch, a failed dynamic tool, a web search and a child
    /// thread, in a finished turn and a running one.
    static func codex() -> CodexTaskState {
        let decoder = CodexTaskDecoder()
        func turn(_ id: String, _ status: String, _ items: [JSONValue]) -> CodexTurnState {
            decoder.turn(from: .object(["id": .string(id), "status": .string(status), "items": .array(items),
                                        "durationMs": .integer(12_000)]), fallbackID: id)!
        }
        func user(_ id: String, _ text: String) -> JSONValue {
            .object(["id": .string(id), "type": .string("userMessage"),
                     "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
        }
        let workspace = ConversationCardConvergenceTests.workspace.path(percentEncoded: false)
        var thread = decoder.thread(from: .object(["id": .string("thread-m12")]))!
        thread.turns = [
            turn("turn-1", "completed", [
                user("u1", "Run the reducer tests"),
                .object(["id": .string("a0"), "type": .string("agentMessage"), "text": .string("They pass."),
                         "phase": .string("final_answer")])
            ]),
            turn("turn-2", "inProgress", [
                user("u2", "Fix the title bar and check the docs"),
                .object(["id": .string("c1"), "type": .string("commandExecution"),
                         "command": .string("swift test --filter Reducer"), "cwd": .string(workspace),
                         "status": .string("completed"), "commandActions": .array([]),
                         "aggregatedOutput": .string("All 30 tests passed.\n"), "exitCode": .integer(0)]),
                .object(["id": .string("f1"), "type": .string("fileChange"), "status": .string("completed"),
                         "changes": .array([.object([
                            "path": .string(workspace + "/Sources/A.swift"),
                            "kind": .object(["type": .string("update")]), "diff": .string("@@ -1 +1 @@\n-a\n+b\n")
                         ])])]),
                .object(["id": .string("d1"), "type": .string("dynamicToolCall"), "tool": .string("lookup"),
                         "status": .string("failed"), "arguments": .object(["q": .string("title bar")]),
                         "contentItems": .array([])]),
                .object(["id": .string("w1"), "type": .string("webSearch"), "query": .string("codex app server")]),
                .object(["id": .string("s1"), "type": .string("collabAgentToolCall"), "tool": .string("spawn_agent"),
                         "status": .string("completed"), "senderThreadId": .string("thread-m12"),
                         "receiverThreadIds": .array([.string("child-1")]), "prompt": .string("Check the docs"),
                         "agentsStates": .object([:])])
            ])
        ]
        return CodexTaskState(thread: thread)
    }
}
