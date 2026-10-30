import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A Codex answer's directives drawn the way the Codex app draws them, by the one renderer, with no
/// window on screen: citations as links named for the file and its place, follow-ups as their
/// phrase, review comments in one card that shows three, a suggested task, two disclosures and a
/// visualization card. The same words in a Claude conversation stay text. Review images go to
/// `.build/codex-directive-qa/` in both appearances.
@MainActor
final class CodexDirectiveRenderingTests: XCTestCase {
    private let decoder = CodexTaskDecoder()
    private static let workspace = URL(filePath: "/work/app", directoryHint: .isDirectory)

    func testACodexAnswerDrawsItsDirectivesAsTheCodexAppDoes() throws {
        let directory = try WindowlessRender.directory("codex-directive-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            // The window offers a new task, so the suggested task's card offers its suggestion.
            let drawing = try ConversationDrawing.draw(conversation().environment(\.startSuggestedTask, { _ in }),
                                                      size: NSSize(width: 760, height: 1_100), appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "codex-answer-\(appearance.suffix).png"))
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            for drawn in [
                "Parser.swift (\(L10n.format("lines %lld-%lld", 40, 44)))",
                "report.pdf (\(L10n.format("page %lld", 3)))", "Tokenizer.swift (\(L10n.format("line %lld", 12)))",
                "Add a regression test", "Profile the tokenizer",
                L10n.format("%lld comments", 4), "Off by one", "Unchecked index", "Missing doc comment",
                "Sources/Parser.swift:40-44", "Sources/Parser.swift:7",
                L10n.string("Show 1 more comment"), L10n.string("Suggested task"), "Add fuzz tests for the parser",
                L10n.string("Use suggestion"), "Build log", "Changed files", "Sources/Tokenizer.swift",
                "Parse time by input size", L10n.string("Visualization unavailable on this device.")
            ] {
                XCTAssertTrue(texts.contains(drawn), "\(drawn) is not drawn:\n\(texts)")
            }
            for markup in [":codex-file-citation", "【", ":codex-followup", "::code-comment", ":::task-stub",
                           ":::github-details", "::codex-inline-vis", "Long function",
                           "The build failed in", "random byte strings"] {
                XCTAssertFalse(texts.contains(markup), "\(markup) is drawn:\n\(texts)")
            }
        }
    }

    func testTheCardsAct() throws {
        let opened = Recorder()
        let view = conversation()
            .environment(\.openURL, OpenURLAction { url in
                opened.urls.append(url)
                return .handled
            })
            .environment(\.startSuggestedTask, { prompt in opened.prompts.append(prompt) })
            .environment(\.colorScheme, .light)
            .frame(width: 760, height: 1_700, alignment: .top)
            .background(ParityTheme.canvas)
        let host = WindowlessRender.Host(view, size: NSSize(width: 760, height: 1_700), appearance: .light)
        defer { host.close() }
        host.settle(passes: 10)
        func texts() -> String { host.accessibilityElements().map(\.description).joined(separator: "\n") }

        // "Use suggestion" hands the prompt to a new task.
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Use suggestion")))
        XCTAssertEqual(opened.prompts, ["Add fuzz tests for the parser that feed it random byte strings and check it never crashes."])

        // A comment opens its file at its line.
        let label = L10n.format("View %@ in %@", "Off by one", "Sources/Parser.swift:40-44")
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: label), texts())
        let commentLink = try XCTUnwrap(opened.urls.last)
        XCTAssertEqual(commentLink.path(percentEncoded: false), "/work/app/Sources/Parser.swift")
        XCTAssertEqual(commentLink.fragment, "L40-L44")

        // The fourth comment shows on request, and folds again.
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Show 1 more comment")))
        host.settle(passes: 8)
        XCTAssertTrue(texts().contains("Long function"), texts())
        XCTAssertTrue(texts().contains(L10n.string("Collapse comments")), texts())
        try WindowlessRender.writePNG(host.capture().bitmap, to: WindowlessRender.directory("codex-directive-qa")
            .appending(path: "codex-answer-comments-open-light.png"))
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Collapse comments")))
        host.settle(passes: 8)
        XCTAssertFalse(texts().contains("Long function"), texts())

        // A closed disclosure opens on its summary.
        XCTAssertFalse(texts().contains("The build failed in"))
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "Build log"))
        host.settle(passes: 8)
        XCTAssertTrue(texts().contains("The build failed in"), texts())
        try WindowlessRender.writePNG(host.capture().bitmap, to: WindowlessRender.directory("codex-directive-qa")
            .appending(path: "codex-answer-details-open-light.png"))
    }

    func testFindOpensAClosedDisclosureToItsMatch() async throws {
        let state = thread()
        let find = ConversationFindModel()
        find.debounce = .zero
        let view = conversation(state)
            .environment(\.conversationFind, find)
            .environment(\.colorScheme, .light)
            .frame(width: 760, height: 1_700, alignment: .top)
            .background(ParityTheme.canvas)
        let host = WindowlessRender.Host(view, size: NSSize(width: 760, height: 1_700), appearance: .light)
        defer { host.close() }
        func settle(_ passes: Int) async throws {
            for _ in 0..<passes {
                host.hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        try await settle(6)
        XCTAssertFalse(host.accessibilityElements().contains { $0.value.contains("The build failed in") })
        find.open()
        find.updateSource(.conversation(CodexConversationProjection.presentation(
            state, workspaceURL: Self.workspace, historySelection: nil
        )))
        find.query = "failed in"
        await find.waitForSearch()
        try await settle(10)
        XCTAssertEqual(find.currentResult?.matches.count, 1)
        let texts = host.accessibilityElements().map(\.description).joined(separator: "\n")
        XCTAssertTrue(texts.contains("The build failed in"), texts)
        try WindowlessRender.writePNG(host.capture().bitmap, to: WindowlessRender.directory("codex-directive-qa")
            .appending(path: "codex-answer-find-opened-light.png"))
    }

    /// Claude writing the same words gets no Codex cards: they are its text.
    func testAnotherHarnessDrawsTheDirectivesAsText() throws {
        let directory = try WindowlessRender.directory("codex-directive-qa")
        let entries = [TranscriptEntry(content: .user(text: "Fix the parser crash on empty input")),
                       TranscriptEntry(content: .assistant(text: Self.answer, isStreaming: false))]
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                         latestTurnIsComplete: true)),
                size: NSSize(width: 760, height: 1_400), appearance: appearance
            )
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "claude-same-text-\(appearance.suffix).png"))
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(":codex-file-citation{"), texts)
            XCTAssertFalse(texts.contains(L10n.string("Suggested task")), texts)
        }
    }

    // MARK: - Fixtures

    /// An answer in the shapes the real threads hold, with made-up words.
    private static let answer = """
    I fixed the parser. The bug was in :codex-file-citation{path="/work/app/Sources/Parser.swift" line_range_start=40 line_range_end=44}, \
    and the report is in :codex-file-citation{path="/work/app/out/report.pdf" artifact_kind="document" page_number="3" purpose="output"}. \
    The tokenizer change is at 【F:/work/app/Sources/Tokenizer.swift†L12】.

    Next you could:
    - :codex-followup[Add a regression test]{prompt="Add a regression test for the empty input"}
    - :codex-followup[Profile the tokenizer]{prompt="Profile the tokenizer on a large file"}

    ::code-comment{title="[P1] Off by one" body="The loop stops one byte short of the end." file="/work/app/Sources/Parser.swift" start=40 end=44}
    ::code-comment{title="Unchecked index" body="Index can run past the buffer." file="/work/app/Sources/Tokenizer.swift" start=12 priority=2}
    ::code-comment{title="Missing doc comment" body="Say what the function returns." file="app/Sources/Parser.swift" start=7 priority=3}
    ::code-comment{title="Long function" body="Split the scanner in two." file="/work/app/Sources/Scanner.swift" start=88 end=140 priority=3}

    :::task-stub{title="Add fuzz tests for the parser"}
    Add fuzz tests for the parser that feed it random byte strings and check it never crashes.
    :::

    :::github-details{summary="Build log"}
    The build failed in **two** tests before the fix.
    :::

    :::github-details{summary="Changed files" open="true"}
    - `Sources/Parser.swift`
    - `Sources/Tokenizer.swift`
    :::

    ::codex-inline-vis{file="parse-times.html" title="Parse time by input size"}
    ::git-push{cwd="/work/app" branch="fix/parser"}
    """

    private func conversation(_ state: CodexTaskState? = nil) -> some View {
        ConversationTimeline(source: .codex(state ?? thread(), workspaceURL: Self.workspace, historySelection: nil),
                             actions: ConversationActions(forkCodexTurn: { _ in }))
            .environment(\.transcriptWorkspaceURL, Self.workspace)
    }

    private func thread() -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string("thread-directives")]))!
        var turn = decoder.turn(from: .object(["id": .string("turn-1"), "status": .string("completed"),
                                               "durationMs": .integer(84_000), "items": .array([])]),
                                fallbackID: "turn-1")!
        turn.items = [
            decoder.item(from: .object([
                "id": .string("u1"), "type": .string("userMessage"),
                "content": .array([.object(["type": .string("text"), "text": .string("Fix the parser crash on empty input")])])
            ]), fallbackID: "u1", lifecycle: .completed),
            decoder.item(from: .object([
                "id": .string("a1"), "type": .string("agentMessage"), "text": .string(Self.answer),
                "phase": .string("final_answer")
            ]), fallbackID: "a1", lifecycle: .completed)
        ]
        thread.turns = [turn]
        return CodexTaskState(thread: thread)
    }

    /// What the cards asked the window to do. Only the main thread touches it.
    private final class Recorder: @unchecked Sendable {
        var urls: [URL] = []
        var prompts: [String] = []
    }
}
