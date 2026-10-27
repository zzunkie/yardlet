import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A fragment that changes only the words of the message a running turn writes, a transcript's or a
/// Codex thread's, goes to that message alone (`ConversationTurn.streamedTextChange(from:)`,
/// `ConversationStreamedText`): the message reads its latest words, what the person opened in the
/// turn stays open, and anything else that changes with it, or the message finishing, draws the turn
/// whole again.
@MainActor
final class StreamedTextTests: XCTestCase {
    private let user = TranscriptEntry(content: .user(text: "Fix the failing tests"))
    private let build = TranscriptEntry(content: .activity(HarnessActivity(
        id: "build", kind: "Bash", title: "Bash", detail: "swift build",
        input: #"{"command":"swift build","description":"Build the app"}"#, output: "Build complete!"
    ), state: .completed))
    private let test = TranscriptEntry(content: .activity(HarnessActivity(
        id: "test", kind: "Bash", title: "Bash", detail: "swift test",
        input: #"{"command":"swift test","description":"Run the tests"}"#, output: "Executed 3 tests"
    ), state: .completed))
    private let words = TranscriptEntry(content: .assistant(text: "Checking", isStreaming: true))

    private func writing(_ text: String, isStreaming: Bool = true) -> TranscriptEntry {
        TranscriptEntry(id: words.id, createdAt: words.createdAt, content: .assistant(text: text, isStreaming: isStreaming))
    }

    private func turn(_ entries: [TranscriptEntry]) throws -> ConversationTurn {
        try XCTUnwrap(TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .running, latestTurnIsComplete: false
        ).turns.last)
    }

    // MARK: - The rule

    func testOnlyTheWordsOfAMessageBeingWrittenAreAStreamedFragment() throws {
        let before = try turn([user, build, test, writing("Checking")])
        let itemID = try XCTUnwrap(before.work.last?.id)

        let grown = try turn([user, build, test, writing("Checking the build")])
        XCTAssertEqual(grown.streamedTextChange(from: before)?.itemID, itemID)
        XCTAssertEqual(grown.streamedTextChange(from: before)?.message.text, "Checking the build")

        // Words to none or none to words decide whether the provider began to answer, and so the fold.
        let blank = try turn([user, build, test, writing("  \n")])
        XCTAssertNil(blank.streamedTextChange(from: before))
        XCTAssertNil(before.streamedTextChange(from: blank))
        // The message finishing, a call after it, and a call changing with it each draw the turn whole.
        XCTAssertNil(try turn([user, build, test, writing("Checking the build", isStreaming: false)])
            .streamedTextChange(from: before))
        let next = TranscriptEntry(content: .activity(HarnessActivity(
            id: "run", kind: "Bash", title: "Bash", detail: "swift run", input: #"{"command":"swift run"}"#
        ), state: .running))
        XCTAssertNil(try turn([user, build, test, writing("Checking the build"), next]).streamedTextChange(from: before))
        let failed = TranscriptEntry(id: test.id, createdAt: test.createdAt, content: .activity(HarnessActivity(
            id: "test", kind: "Bash", title: "Bash", detail: "swift test",
            outcome: .failed, input: #"{"command":"swift test","description":"Run the tests"}"#, output: "1 failure"
        ), state: .failed))
        XCTAssertNil(try turn([user, build, failed, writing("Checking the build")]).streamedTextChange(from: before))
        // The same turn is no change at all.
        XCTAssertNil(before.streamedTextChange(from: before))

        // A Codex message the same way, with what its details copy.
        let codexBefore = try codexTurn("Checking")
        let change = try XCTUnwrap(try codexTurn("Checking the build").streamedTextChange(from: codexBefore))
        XCTAssertEqual(change.message.text, "Checking the build")
        XCTAssertEqual(change.message.copyDetails?.contains("Checking the build"), true, "Its details copy its latest words")
        // Working notes becoming the answer, and the message finishing, draw the turn whole.
        XCTAssertNil(try codexTurn("Checking the build", phase: .commentary).streamedTextChange(from: codexBefore))
        XCTAssertNil(try codexTurn("Checking the build", lifecycle: .completed).streamedTextChange(from: codexBefore))
    }

    /// A running Codex turn of three commands and the message it writes after them.
    private func codexTurn(_ text: String, phase: CodexMessagePhase = .finalAnswer,
                           lifecycle: CodexItemLifecycle = .inProgress) throws -> ConversationTurn {
        var state = LongConversationFixture.codex(threadID: "thread-words", turns: [
            LongConversationFixture.runningCodexTurn(0, request: "Fix the failing tests", calls: 3, paragraphs: 1)
        ])
        let index = state.thread!.turns[0].items.count - 1
        guard case var .agentMessage(message) = state.thread!.turns[0].items[index].content else {
            throw XCTSkip("The fixture's last item is not a message")
        }
        message.text = text
        message.phase = phase
        state.thread!.turns[0].items[index].content = .agentMessage(message)
        state.thread!.turns[0].items[index].lifecycle = lifecycle
        return try XCTUnwrap(CodexConversationProjection.presentation(
            state, workspaceURL: LongConversationFixture.workspace, historySelection: nil
        ).turns.last)
    }

    // MARK: - Drawn

    private func view(_ entries: [TranscriptEntry], scheme: ColorScheme = .light) -> some View {
        ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .running,
                                                 latestTurnIsComplete: false),
                             actions: ConversationActions())
            .environment(\.colorScheme, scheme)
            .frame(width: 760, height: 700, alignment: .top)
    }

    func testAStreamingMessageReadsItsLatestWordsAndTheTurnKeepsWhatThePersonOpened() throws {
        let host = WindowlessRender.Host(view([user, build, test, writing("Checking")]),
                                         size: NSSize(width: 760, height: 700), appearance: .light)
        ViewBodyCensus.isEnabled = true
        defer {
            ViewBodyCensus.isEnabled = false
            ViewBodyCensus.reset()
            host.close()
        }
        host.settle()
        let calls = try turn([user, build, test, writing("Checking")]).work.prefix(2)
        let summary = ConversationWorkSummary.title(for: Array(calls), harness: .claudeCode)
        func summaryValue() -> String? {
            host.accessibilityElements().first { $0.label == summary && $0.role == NSAccessibility.Role.button.rawValue }?.value
        }
        XCTAssertEqual(summaryValue(), L10n.string("Collapsed"), "\(host.accessibilityElements())")
        XCTAssertTrue(host.hosting.pressButton(labelled: summary))
        host.settle()
        XCTAssertEqual(summaryValue(), L10n.string("Expanded"))

        // Fragments: the message alone takes them.
        ViewBodyCensus.reset()
        var text = "Checking"
        for fragment in 0..<12 {
            text += " word\(fragment)"
            host.hosting.rootView = view([user, build, test, writing(text)])
            host.settle(passes: 1, interval: 0.005)
        }
        host.settle(passes: 2)
        XCTAssertEqual(ViewBodyCensus[.conversationTurn], 0, "A fragment of words drew the whole turn again")
        XCTAssertEqual(summaryValue(), L10n.string("Expanded"), "What the person opened stays open")
        let message = try XCTUnwrap(TranscriptProseRenderingTests.proseTextViews(in: host.hosting)
            .first { $0.string.hasPrefix("Checking") })
        XCTAssertEqual(message.string, text)
        XCTAssertEqual(Self.copy(message), text, "A copy of the message gives its latest words")

        // How the conversation looks changing draws the turn whole, with its latest words.
        host.hosting.rootView = view([user, build, test, writing(text)], scheme: .dark)
        host.settle()
        XCTAssertEqual(ViewBodyCensus[.conversationTurn], 1)
        XCTAssertEqual(TranscriptProseRenderingTests.proseTextViews(in: host.hosting)
            .first { $0.string.hasPrefix("Checking") }?.string, text)

        // A call after the message draws the turn whole; the message keeps its words.
        let next = TranscriptEntry(content: .activity(HarnessActivity(
            id: "run", kind: "Bash", title: "Bash", detail: "swift run",
            input: #"{"command":"swift run","description":"Run the app"}"#
        ), state: .running))
        host.hosting.rootView = view([user, build, test, writing(text), next], scheme: .dark)
        host.settle()
        XCTAssertEqual(ViewBodyCensus[.conversationTurn], 2)
        XCTAssertEqual(summaryValue(), L10n.string("Expanded"))

        // The message finished: drawn whole, its final words, the summary still open.
        let final = text + " Done."
        host.hosting.rootView = view([user, build, test, writing(final, isStreaming: false), next], scheme: .dark)
        host.settle()
        XCTAssertEqual(ViewBodyCensus[.conversationTurn], 3)
        XCTAssertEqual(TranscriptProseRenderingTests.proseTextViews(in: host.hosting)
            .first { $0.string.hasPrefix("Checking") }?.string, final)
        XCTAssertEqual(summaryValue(), L10n.string("Expanded"))
    }

    /// What copying all of `text` gives, on a pasteboard of the test's own.
    private static func copy(_ text: TranscriptProseTextView) -> String? {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("yardlet-streamed-text-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        text.selectAll(nil)
        defer { text.setSelectedRange(NSRange(location: 0, length: 0)) }
        guard text.writeSelection(to: pasteboard, type: .string) else { return nil }
        return pasteboard.string(forType: .string)
    }
}

private extension NSView {
    /// Presses the first button under the view with this label, as an assistive app would
    /// (`CommandDisclosureTests` presses a summary the same way).
    func pressButton(labelled label: String) -> Bool {
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        let previous = (app.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?
            .takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                        with: attribute)
        defer {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                            with: NSNumber(value: previous), with: attribute)
        }
        func visit(_ node: AnyObject) -> AnyObject? {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if let found = child.accessibilityLabel?() ?? nil, found == label,
                   (child.accessibilityRole?() ?? nil) == NSAccessibility.Role.button { return child }
                if let found = visit(child) { return found }
            }
            return nil
        }
        return visit(self)?.accessibilityPerformPress?() ?? false
    }
}
