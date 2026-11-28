import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders a running turn without a provider into `.build/composer-stream-qa/`, light and dark.
@MainActor
final class RunningTurnRenderingTests: XCTestCase {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let size = NSSize(width: 820, height: 560)

    private static func tool(_ id: String, _ kind: String, _ title: String, detail: String? = nil,
                             output: String? = nil) -> HarnessActivity {
        HarnessActivity(id: id, kind: kind, title: title, detail: detail, input: detail, output: output)
    }

    private static func bash(_ id: String, _ command: String, _ description: String, output: String? = nil) -> HarnessActivity {
        HarnessActivity(id: id, kind: "Bash", title: "Bash", detail: command,
                        input: command + "\n\ndescription: " + description, output: output)
    }

    /// Reads, a search and an edit, then commands, the last still running.
    static func mixedEntries(last: TranscriptEntryContent? = nil) -> [TranscriptEntry] {
        var contents: [TranscriptEntryContent] = [
            .user(text: "Find out why the parser tests sometimes fail and fix it"),
            .activity(tool("toolu_read1", "Read", "Read", detail: "Sources/Parser/Parser.swift"), state: .completed),
            .activity(tool("toolu_grep", "Grep", "Grep", detail: "pending"), state: .completed),
            .activity(tool("toolu_read2", "Read", "Read", detail: "Tests/ParserTests.swift"), state: .completed),
            .assistant(text: "The test reads a shared cache before the parser fills it. Fixing the order.",
                       isStreaming: false),
            .activity(tool("toolu_edit", "Edit", "Edit", detail: "Sources/Parser/Parser.swift"), state: .completed),
            .activity(bash("toolu_status", "git status --short", "Show changed files", output: " M Parser.swift"),
                      state: .completed),
            .activity(bash("toolu_test", "swift test --filter ParserTests", "Run the parser tests",
                           output: "Test Suite 'ParserTests' started"), state: .running)
        ]
        if let last { contents.append(last) }
        return contents.enumerated().map { index, content in
            TranscriptEntry(createdAt: start.addingTimeInterval(Double(index) * 3), content: content)
        }
    }

    private func timeline(_ entries: [TranscriptEntry]) -> some View {
        ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .running,
                                                 latestTurnIsComplete: false),
                             actions: ConversationActions(chooseOption: { _, _ in }, answer: { _, _ in }))
    }

    func testARunningTurnReadsAsFoldedSummariesAndOneLiveLine() throws {
        let directory = try WindowlessRender.directory("composer-stream-qa")
        let entries = Self.mixedEntries()
        var light: [WindowlessRender.AccessibilityElement] = []
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(timeline(entries), size: Self.size, appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "running-turn-\(appearance.suffix).png"))
            if appearance == .light { light = drawing.elements }
        }
        let labels = light.map(\.label)
        let texts = light.map { [$0.label, $0.value].joined(separator: " ") }.joined(separator: "\n")
        // The running command is the live line's, with the turn's steps; it is not also listed above.
        let running = ConversationLineWording.command(
            ConversationCommand(command: "swift test --filter ParserTests", status: "",
                                description: "Run the parser tests"), phase: .running, harness: .claudeCode)[0].text
        XCTAssertTrue(labels.contains { $0.hasPrefix(running) && $0.contains(L10n.format("%lld steps", Int64(6))) },
                      texts)
        XCTAssertEqual(labels.filter { $0 == running }.count, 0, "Not listed above the live line: \(texts)")
        // Nothing is open: no call's output or detail shows while the turn runs.
        XCTAssertFalse(texts.contains("Test Suite 'ParserTests' started"), texts)
        XCTAssertFalse(texts.contains(" M Parser.swift"), texts)
        XCTAssertFalse(light.contains { $0.value == L10n.string("Expanded") }, texts)
    }

    func testTheLiveLineTellsThinkingFromWaitingOnThePerson() throws {
        let directory = try WindowlessRender.directory("composer-stream-qa")
        let thinking = Self.mixedEntries(last: nil).dropLast()
            + [TranscriptEntry(createdAt: Self.start.addingTimeInterval(30),
                               content: .reasoning(text: "The cache is filled lazily…", isStreaming: true))]
        let waiting = Self.mixedEntries(last: .permission(
            PermissionRequest(id: "clean", title: "Bash", detail: "Remove the build folder", command: "rm -rf .build",
                              toolCallID: "toolu_clean"), state: .pending))
        for (name, entries, expected) in [("thinking", Array(thinking), L10n.string("Thinking")),
                                          ("waiting", waiting, L10n.string("Awaiting approval"))] {
            var light: [WindowlessRender.AccessibilityElement] = []
            for appearance in WindowlessRender.Appearance.allCases {
                let drawing = try ConversationDrawing.draw(timeline(entries), size: Self.size, appearance: appearance)
                try WindowlessRender.writePNG(drawing.capture.bitmap,
                                              to: directory.appending(path: "running-turn-\(name)-\(appearance.suffix).png"))
                if appearance == .light { light = drawing.elements }
            }
            XCTAssertTrue(light.contains { $0.label.hasPrefix(expected) }, "\(name): \(light.map(\.label))")
        }
    }

    func testTheLiveWorkProjection() {
        func item(_ id: String, _ kind: ConversationItemKind, _ phase: ConversationItemPhase) -> ConversationItem {
            ConversationItem(id: id, kind: kind, phase: phase, source: .transcript(TranscriptEntry(content: .plan(""))))
        }
        let read = item("r", .tool(ConversationTool(kind: .activity("Read"), name: "Parser.swift")), .completed)
        let test = item("t", .command(ConversationCommand(command: "swift test", status: "inProgress")), .running)
        let answer = item("a", .commentary(text: "Checking.", isStreaming: false), .completed)
        var turn = ConversationTurn(id: "turn", status: .running, timing: ConversationTurnTiming())
        turn.work = [read, answer, read, test]
        let live = ConversationLiveWork.make(turn, harness: .codex, workspaceURL: nil)
        XCTAssertEqual(live?.items.map(\.id), ["r", "t"], "The last run, with the running call")
        XCTAssertEqual(live?.steps, 3)
        if case .running = live?.activity {} else { XCTFail("\(String(describing: live?.activity))") }
        XCTAssertEqual(ConversationLiveWork.listedRuns(turn).count, 2, "The read and the words above it")

        turn.work = [read, answer]
        XCTAssertEqual(ConversationLiveWork.make(turn, harness: .codex, workspaceURL: nil)?.activity, .working)
        XCTAssertEqual(ConversationLiveWork.listedRuns(turn).count, 2)

        // The line names what the oldest request waits for, the one in front of the dock.
        let source = ConversationRequestSource.transcript(TranscriptEntry(content: .plan("")))
        let approval = ConversationRequest(id: "approval", title: "Bash", state: .pending, source: source)
        let question = ConversationRequest(
            id: "question", title: "Ask",
            form: .choices([PermissionQuestion(question: "Which?", options: [PermissionQuestionOption(label: "A")])]),
            state: .pending, source: source)
        turn.requests = [approval, question]
        XCTAssertEqual(ConversationLiveWork.make(turn, harness: .claudeCode, workspaceURL: nil)?.activity, .waitingForApproval)
        turn.requests = [question, approval]
        XCTAssertEqual(ConversationLiveWork.make(turn, harness: .claudeCode, workspaceURL: nil)?.activity, .waitingForAnswer)
        turn.requests = []

        turn.status = .completed
        XCTAssertNil(ConversationLiveWork.make(turn, harness: .codex, workspaceURL: nil), "No live line after the turn")
        XCTAssertEqual(ConversationLiveWork.detail(steps: 1, elapsed: "12s"), L10n.string("1 step") + " · 12s")
    }

    func testLiveThinkingPreviewAndCompletedSummaryAcrossMultiStepRun() throws {
        // Excerpt extraction: short text, tail tracking past maxLines, and long single-line tail clipping.
        XCTAssertNil(ConversationLiveWork.thinkingExcerpt(from: "   \n\n  "))
        XCTAssertEqual(ConversationLiveWork.thinkingExcerpt(from: "Checking Parser.swift"), "Checking Parser.swift")
        let multiLine = "Line 1\n\nLine 2\nLine 3\nLine 4\nLine 5"
        XCTAssertEqual(ConversationLiveWork.thinkingExcerpt(from: multiLine), "Line 3\nLine 4\nLine 5")
        let longLine = (1...60).map { "token\($0)" }.joined(separator: " ")
        let clipped = try XCTUnwrap(ConversationLiveWork.thinkingExcerpt(from: longLine, maxLines: 3, maxCharacters: 80))
        XCTAssertTrue(clipped.hasPrefix("…"), clipped)
        XCTAssertTrue(clipped.hasSuffix("token60"), clipped)
        XCTAssertLessThanOrEqual(clipped.count, 81)

        // Wide Korean single-line thought stays tightly bounded so 3-line wrapping keeps the tail visible.
        let koreanLong = String(repeating: "파서 상태를 확인하면서 스트리밍 출력을 검토하고 있습니다. ", count: 8) + "마지막 단계입니다."
        let koreanExcerpt = try XCTUnwrap(ConversationLiveWork.thinkingExcerpt(from: koreanLong))
        XCTAssertTrue(koreanExcerpt.hasPrefix("…"), koreanExcerpt)
        XCTAssertTrue(koreanExcerpt.hasSuffix("마지막 단계입니다."), koreanExcerpt)
        XCTAssertLessThanOrEqual(koreanExcerpt.count, 105)

        // Bounded O(1) tail scan on a very large thought string.
        let hugeThought = String(repeating: "Earlier reasoning paragraph that must not be scanned.\n", count: 4_000)
            + "Final line A\nFinal line B\nFinal line C"
        XCTAssertEqual(ConversationLiveWork.thinkingExcerpt(from: hugeThought),
                       "Final line A\nFinal line B\nFinal line C")

        // Antigravity-style multi-step run with no intermediate commentary: completed calls stay
        // summarized above the live line while a new thought streams with a compact preview below it.
        let entries: [TranscriptEntry] = [
            TranscriptEntry(createdAt: Self.start, content: .user(text: "Fix the parser")),
            TranscriptEntry(createdAt: Self.start.addingTimeInterval(1),
                            content: .reasoning(text: "First inspect the parser.", isStreaming: false)),
            TranscriptEntry(createdAt: Self.start.addingTimeInterval(2),
                            content: .activity(Self.tool("r1", "Read", "Read", detail: "Parser.swift"), state: .completed)),
            TranscriptEntry(createdAt: Self.start.addingTimeInterval(4),
                            content: .activity(Self.tool("e1", "Edit", "Edit", detail: "Parser.swift"), state: .completed)),
            TranscriptEntry(createdAt: Self.start.addingTimeInterval(6),
                            content: .reasoning(text: "Line 1\nLine 2\nLine 3\nNow checking the test suite.", isStreaming: true))
        ]
        let turn = try XCTUnwrap(TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .running, latestTurnIsComplete: false
        ).turns.first)
        let live = try XCTUnwrap(ConversationLiveWork.make(turn, harness: .claudeCode, workspaceURL: nil))
        XCTAssertEqual(live.activity, .thinking)
        XCTAssertEqual(live.steps, 2)
        XCTAssertEqual(live.completedSummary,
                       ConversationWorkSummary.title(for: Array(turn.work[1...2]), harness: .claudeCode))
        XCTAssertEqual(live.thinkingPreview?.itemID, entries.last?.id.uuidString)
        XCTAssertEqual(live.thinkingPreview.flatMap { ConversationLiveWork.thinkingExcerpt(from: $0.text) },
                       "Line 2\nLine 3\nNow checking the test suite.")

        let drawing = try ConversationDrawing.draw(timeline(entries), size: Self.size, appearance: .light)
        let texts = drawing.elements.map { [$0.label, $0.value].joined(separator: " ") }.joined(separator: "\n")
        XCTAssertTrue(texts.contains(try XCTUnwrap(live.completedSummary)), texts)
        XCTAssertTrue(texts.contains("Now checking the test suite."), texts)
        XCTAssertFalse(texts.contains("Line 1"), "Only the tail excerpt shows in the compact preview:\n\(texts)")
    }
}
