import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Sent Codex messages drawn the way the Codex app draws them, by the one renderer, with no window on
/// screen: the request in the bubble, the files mentioned or pasted as chips that open their lines,
/// counts of comments, annotations and selections, checks and conflicts as chips, the mode under the
/// bubble, and none of the context the app keeps for the model. A long request clips at 20 lines of
/// its own. Review images go to `.build/codex-prompt-qa/` in both appearances.
@MainActor
final class CodexPromptRenderingTests: XCTestCase {
    private let decoder = CodexTaskDecoder()
    private static let workspace = URL(filePath: "/work/app", directoryHint: .isDirectory)
    private static let size = NSSize(width: 760, height: 1_900)

    func testSentCodexMessagesShowTheirRequestAndAttachments() throws {
        let directory = try WindowlessRender.directory("codex-prompt-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let host = host(conversation(), appearance: appearance)
            defer { host.close() }
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "codex-prompts-\(appearance.suffix).png"))
            let texts = host.accessibilityElements().map(\.description).joined(separator: "\n")
            for drawn in [
                "Make the save button wider", "Fix the parser crash on empty input", "Address these",
                "Parser.swift", "40-44", "Tokenizer.swift", "a: b.txt", "shot.png", "Pasted text 1", "report.pdf",
                L10n.format("%lld attached comments", 2), L10n.string("1 annotation"), L10n.format("%lld selections", 2),
                L10n.format("%@ +%lld more", "build (macos)", 1), L10n.format("Merge conflicts - PR #%@", String(42)),
                "Review it", L10n.string("Review mode"), L10n.string("PR fix"),
                "Merge it", L10n.string("Previous context"), L10n.format("PR #%@", String(7)), L10n.string("Auto resolve conflicts")
            ] {
                XCTAssertTrue(texts.contains(drawn), "\(drawn) is not drawn:\n\(texts)")
            }
            for hidden in ["in-app-browser-context", "In app browser", "Current URL", "## My request",
                           "Context from my IDE setup", "Active file", "Open tabs", "Distinguish instructions",
                           "Files mentioned", "Diff comments", "Use a guard here", "Some selected words",
                           "Code review guidelines", "Prior conversation", "Repository:", "Resolve the conflicts"] {
                XCTAssertFalse(texts.contains(hidden), "\(hidden) is drawn:\n\(texts)")
            }
        }
    }

    func testAFileChipOpensItsFileAtItsLines() throws {
        let opened = Recorder()
        let host = host(conversation().environment(\.openURL, OpenURLAction { url in
            opened.urls.append(url)
            return .handled
        }), appearance: .light)
        defer { host.close() }
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "Parser.swift 40-44"),
                      host.accessibilityElements().map(\.description).joined(separator: "\n"))
        let link = try XCTUnwrap(opened.urls.last)
        XCTAssertEqual(link.path(percentEncoded: false), "/work/app/Sources/Parser.swift")
        XCTAssertEqual(link.fragment, "L40-L44")
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "a: b.txt"))
        XCTAssertEqual(opened.urls.last?.path(percentEncoded: false), "/work/app/notes/a: b.txt")
        XCTAssertNil(opened.urls.last?.fragment)
    }

    /// A long request clips at its own 20 lines, however long the context before it; a short request
    /// after a long context does not clip.
    func testALongRequestClipsAtItsOwnLines() throws {
        let directory = try WindowlessRender.directory("codex-prompt-qa")
        let longContext = "# Context from my IDE setup:\n\n## Active file: a.swift\n\n## Active selection of the file:\n"
            + (1...40).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n\n## My request for Codex:\n"
        let longRequest = (1...30).map { "Request line \($0)" }.joined(separator: "\n")
        let state = codexThread(turns: [
            turn("turn-1", items: [user("u1", longContext + "Short request after a long selection\n"), agent("a1", "Done.")]),
            turn("turn-2", items: [user("u2", CodexUserPromptTests.browserPrompt.replacingOccurrences(
                of: "Make the save button wider", with: longRequest)), agent("a2", "Done.")])
        ])
        for appearance in WindowlessRender.Appearance.allCases {
            let host = host(view(state), appearance: appearance)
            defer { host.close() }
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "codex-prompt-long-\(appearance.suffix).png"))
            let texts = host.accessibilityElements().map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains("Short request after a long selection"), texts)
            XCTAssertFalse(texts.contains("let value"), texts)
            XCTAssertTrue(texts.contains("Request line 19"), texts)
            XCTAssertFalse(texts.contains("Request line 21"), texts)
            // One message clips: its "Show more" is a button (the turn menu's "More" is a menu button).
            XCTAssertEqual(texts.components(separatedBy: "AXButton “\(L10n.string("Show more"))”").count - 1, 1, texts)
        }
    }

    /// Claude writing a message that merely holds the marker shows it whole.
    func testAnotherHarnessShowsAMessageThatMerelyHoldsTheMarker() throws {
        let entries = [TranscriptEntry(content: .user(text: "Notes first\n## My request:\nkeep all of this")),
                       TranscriptEntry(content: .assistant(text: "Kept.", isStreaming: false))]
        let directory = try WindowlessRender.directory("codex-prompt-qa")
        let host = host(ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                                 latestTurnIsComplete: true)), appearance: .light)
        defer { host.close() }
        try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "claude-marker-text-light.png"))
        let texts = host.accessibilityElements().map(\.description).joined(separator: "\n")
        XCTAssertTrue(texts.contains("Notes first"), texts)
        XCTAssertTrue(texts.contains("## My request:"), texts)
    }

    // MARK: - Fixtures

    private func conversation() -> some View { view(thread()) }

    private func view(_ state: CodexTaskState) -> some View {
        ConversationTimeline(source: .codex(state, workspaceURL: Self.workspace, historySelection: nil),
                             actions: ConversationActions(forkCodexTurn: { _ in }))
            .environment(\.transcriptWorkspaceURL, Self.workspace)
    }

    private func host(_ content: some View, appearance: WindowlessRender.Appearance) -> WindowlessRender.Host<AnyView> {
        let host = WindowlessRender.Host(
            AnyView(content
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
                .background(ParityTheme.canvas)),
            size: Self.size, appearance: appearance
        )
        host.settle(passes: 10)
        return host
    }

    private func thread() -> CodexTaskState {
        // A review reads its earlier context as part of itself, so only the merge shows "Previous context".
        let review = "## Code review guidelines:\nBe strict.\n\n## Prior conversation with Codex:\n{}\n\n## Pull request fix:\nFix CI.\n\n## My request:\nReview it\n"
        let merge = "\n## Prior conversation with Codex:\n{\"turns\":[]}\n## Pull request merge task:\nRepository: example/app\nPull request: #7\n\n## Auto resolve merge:\nResolve the conflicts.\n\n## My request:\nMerge it\n"
        return codexThread(turns: [
            turn("turn-1", items: [user("u1", CodexUserPromptTests.browserPrompt), agent("a1", "Wider now.")]),
            turn("turn-2", items: [user("u2", CodexUserPromptTests.filesPrompt), agent("a2", "Fixed.")]),
            turn("turn-3", items: [user("u3", CodexUserPromptTests.commentsPrompt), agent("a3", "Done.")]),
            turn("turn-4", items: [user("u4", review), agent("a4", "Reviewed.")]),
            turn("turn-5", items: [user("u5", merge), agent("a5", "Merged.")])
        ])
    }

    private func user(_ id: String, _ text: String) -> CodexItemState {
        decoder.item(from: .object([
            "id": .string(id), "type": .string("userMessage"),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])])
        ]), fallbackID: id, lifecycle: .completed)
    }

    private func agent(_ id: String, _ text: String) -> CodexItemState {
        decoder.item(from: .object([
            "id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string("final_answer")
        ]), fallbackID: id, lifecycle: .completed)
    }

    private func turn(_ id: String, items: [CodexItemState]) -> CodexTurnState {
        var turn = decoder.turn(from: .object(["id": .string(id), "status": .string("completed"), "items": .array([])]),
                                fallbackID: id)!
        turn.items = items
        return turn
    }

    private func codexThread(turns: [CodexTurnState]) -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string("thread-prompt-render")]))!
        thread.turns = turns
        return CodexTaskState(thread: thread)
    }

    /// What the chips asked the window to open. Only the main thread touches it.
    private final class Recorder: @unchecked Sendable {
        var urls: [URL] = []
    }
}
