import AppKit
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Find in conversation (⌘F), after the Codex app's find-in-thread: what is searched and in which
/// order, how Return and ⌘G move, what folded work opens, how the marks touch only the messages
/// they change, and how a long conversation stays quick. Renders go to `.build/find-qa`.
@MainActor
final class ConversationFindTests: XCTestCase {
    fileprivate let decoder = CodexTaskDecoder()

    // MARK: - Codex cases

    func checkCodexMessagesFollowTheTimelineOrderAndCommentaryOpensItsTurn() throws {
        let turn = turn("turn-1", status: "completed", items: [
            userItem("u1", "Find the title bar"),
            agentItem("m1", "Checking the title bar layout.", phase: "commentary"),
            commandItem("c1", "grep -rn 'title bar' Sources"),
            userItem("u2", "Also the title bar height"),
            agentItem("a1", "The title bar is fixed.", phase: "final_answer")
        ])
        let units = codexFindSource(thread([turn])).units
        XCTAssertEqual(units.map(\.scrollID), ["turn-1", "turn-1", "turn-1", "turn-1"])
        // A message steered in after the turn's work began is in the work where it was taken (D13), and
        // folds with it once the answer follows, so finding it opens the turn (2026-10-23, the Codex app's fold).
        XCTAssertEqual(units.map(\.id), ["u1", "m1", "u2", "a1"])
        XCTAssertEqual(units.map(\.revealID), [nil, "turn-1", "turn-1", nil])
    }

    /// The second match is commentary in the first turn's folded work: going there opens it.
    func renderTheCodexCommentaryMatch() async throws {
        let codexState = thread([
            turn("turn-1", status: "completed", items: [
                userItem("u1", "The title bar overlaps the toolbar"),
                agentItem("m1", "Checking how the title bar measures its height.", phase: "commentary"),
                commandItem("c1", "grep -rn 'titleBarHeight' Sources"),
                agentItem("a1", """
                The **title bar** keeps a fixed height while the toolbar grows.

                ```swift
                static let titleBarHeight: CGFloat = 50 // title bar
                ```

                | Area | Title bar |
                | --- | --- |
                | Sidebar | fixed |
                """, phase: "final_answer")
            ]),
            turn("turn-2", status: "completed", items: [
                userItem("u2", "Make the title bar follow the toolbar"),
                agentItem("a2", "Done: the title bar now follows the toolbar height.", phase: "final_answer")
            ])
        ])
        let codex = TaskConversationView(
            harness: .codex, workspaceURL: URL(filePath: "/Users/me/yardlet"), entries: [], codexTaskState: codexState,
            actions: ConversationActions(retryTurn: { _ in })
        )
        try await render(codex, height: 760, name: "codex-commentary-match",
                         source: codexFindSource(codexState), query: "title bar", moves: 1) { find in
            XCTAssertEqual(find.activeMatch?.unitID, "m1")
            XCTAssertEqual(find.currentResult?.matches.count, 7)
        }
    }

    // MARK: - Fixtures

    fileprivate func openFind(_ texts: [String], returnFocus: Bool = false) -> (ConversationFindModel, [TranscriptEntry]) {
        let entries = texts.enumerated().map { index, text in
            TranscriptEntry(content: index.isMultiple(of: 2)
                ? .user(text: text) : .assistant(text: text, isStreaming: false))
        }
        let find = ConversationFindModel()
        find.debounce = .zero
        var restore: (@MainActor () -> Bool)?
        if returnFocus { restore = { true } }
        find.open(returnFocus: restore)
        find.updateSource(.transcript(entries, latestTurnIsComplete: true))
        return (find, entries)
    }

    /// The slots whose marks changed, recorded from Observation's change callback.
    fileprivate final class Touched: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Set<String> = []
        var names: Set<String> { lock.withLock { stored } }
        func insert(_ name: String) { lock.withLock { _ = stored.insert(name) } }
    }

    /// What the conversation hands find: the conversation model.
    fileprivate func codexFindSource(_ state: CodexTaskState) -> ConversationFindSource {
        .conversation(CodexConversationProjection.presentation(
            state, workspaceURL: URL(filePath: "/Users/me/yardlet"), historySelection: nil
        ))
    }

    fileprivate func thread(_ turns: [CodexTurnState]) -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string("thread-qa")]))!
        thread.turns = turns
        return CodexTaskState(thread: thread)
    }

    fileprivate func turn(_ id: String, status: String, items: [JSONValue]) -> CodexTurnState {
        decoder.turn(from: .object([
            "id": .string(id), "status": .string(status), "durationMs": .integer(12_000), "items": .array(items)
        ]), fallbackID: id)!
    }

    fileprivate func userItem(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("userMessage"),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    fileprivate func agentItem(_ id: String, _ text: String, phase: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string(phase)])
    }

    fileprivate func commandItem(_ id: String, _ command: String) -> JSONValue {
        .object([
            "id": .string(id), "type": .string("commandExecution"), "command": .string(command),
            "cwd": .string("/Users/me/yardlet"), "status": .string("completed"), "commandActions": .array([]),
            "aggregatedOutput": .string("Sources/AppTitleBar.swift: title bar\n"), "exitCode": .integer(0)
        ])
    }

    /// Lays the conversation out in an offscreen window with the find bar over it, searches and moves
    /// once it is on screen (as a person would), lets it scroll and open what it needs, and saves
    /// light and dark images.
    fileprivate func render<Content: View>(
        _ content: Content, height: CGFloat, name: String, source: ConversationFindSource, query: String,
        moves: Int, check: (ConversationFindModel) -> Void,
        drawn: ([WindowlessRender.AccessibilityElement]) -> Void = { _ in }
    ) async throws {
        let directory = try WindowlessRender.directory("find-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let find = ConversationFindModel()
            find.debounce = .zero
            let view = content
                .environment(\.conversationFind, find)
                .overlay(alignment: .topTrailing) {
                    ConversationFindBar(find: find).padding(.top, 8).padding(.horizontal, 16)
                }
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: 760, height: height, alignment: .top)
                .background(ParityTheme.canvas)
            let host = WindowlessRender.Host(view, size: NSSize(width: 760, height: height), appearance: appearance)
            defer { host.close() }
            func settle(_ passes: Int) async throws {
                for _ in 0..<passes {
                    host.hosting.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(40))
                }
            }
            try await settle(6)
            find.open()
            find.updateSource(source)
            try await settle(2)
            find.query = query
            await find.waitForSearch()
            for _ in 0..<moves { find.next() }
            try await settle(12)
            check(find)
            // What the conversation shows once find has moved, the find bar left out.
            drawn(host.accessibilityElements(visibleOnly: true))
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
        }
    }

    // MARK: - A long Claude conversation

    /// Forty requests with the one that matches far above the latest output, its match in commentary
    /// that its finished turn folds.
    fileprivate func longClaudeConversation() -> (entries: [TranscriptEntry], request: TranscriptEntry, reading: TranscriptEntry) {
        var entries: [TranscriptEntry] = []
        func filler(_ range: Range<Int>) {
            for index in range {
                entries.append(TranscriptEntry(content: .user(text: "Request \(index)")))
                entries.append(TranscriptEntry(content: .assistant(text: "Answer \(index) without it.", isStreaming: false)))
            }
        }
        filler(0..<15)
        let request = TranscriptEntry(content: .user(text: "Why is the Title Bar clipped?"))
        let reading = TranscriptEntry(content: .assistant(
            text: "Reading `AppTitleBar.swift`: the title bar uses a fixed frame.", isStreaming: false
        ))
        let tool = TranscriptEntry(content: .activity(
            HarnessActivity(id: "t1", kind: "command", title: "rg 'title bar'", detail: nil), state: .completed
        ))
        let answer = TranscriptEntry(content: .assistant(text: "The title bar now grows with the toolbar.", isStreaming: false))
        entries += [request, reading, tool, answer]
        filler(15..<40)
        return (entries, request, reading)
    }

    /// The current match is far above the latest output and inside a completed turn's folded work:
    /// going there opens the work and shows the match. The work folds in its turn, which every match
    /// scrolls to.
    func renderTheLongClaudeConversationMatch() async throws {
        let (entries, request, reading) = longClaudeConversation()
        let transcript = TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/Users/me/yardlet"),
                                              entries: entries, latestTurnIsComplete: true)
        let source = ConversationFindSource.transcript(entries, latestTurnIsComplete: true)
        let folded = request.id.uuidString
        try await render(transcript, height: 560, name: "claude-folded-match",
                         source: source, query: "title bar", moves: 1) { find in
            XCTAssertEqual(find.activeMatch?.unitID, reading.id.uuidString)
            XCTAssertEqual(find.activeMatch?.revealID, folded)
        } drawn: { elements in
            let text = elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(text.contains("the title bar uses a fixed frame"), "the match is shown:\n\(text)")
        }
        try await render(transcript, height: 220, name: "claude-no-results",
                         source: source, query: "no such words", moves: 0) { find in
            XCTAssertEqual(find.currentResult?.matches.count, 0)
        }
    }
}

extension ConversationFindTests {
    // MARK: - Matching

    func testHitsAreCaseInsensitiveAndDoNotOverlapAsInTheCodexApp() {
        XCTAssertEqual(ConversationFindEngine.occurrences(of: "aa", in: "aaaa").count, 2)
        XCTAssertEqual(ConversationFindEngine.occurrences(of: "hello", in: "Hello hello HELLO").count, 3)
        XCTAssertEqual(ConversationFindEngine.occurrences(of: "제목", in: "제목 표시줄과 제목").map(\.location), [0, 8])
        XCTAssertEqual(ConversationFindEngine.occurrences(of: "😀", in: "a😀b😀").count, 2)
        XCTAssertEqual(ConversationFindEngine.occurrences(of: "x", in: "xxxx", limit: 3).count, 3)
        XCTAssertTrue(ConversationFindEngine.occurrences(of: "", in: "anything").isEmpty)
        XCTAssertEqual(ConversationFindEngine.normalized("  title bar \n"), "title bar")
    }

    func testMarkdownIsSearchedAsItIsDrawnBlockByBlock() {
        let source = """
        # Title **bar**

        A `code` span and [a link](https://example.com).

        - first item
          - nested *item*
        > quoted text

        ```swift
        let title = "bar"
        ```

        | Name | Value |
        | --- | --- |
        | bar | 1 | extra |

        ---
        """
        let segments = ConversationFindEngine.markdownSegments(source)
        XCTAssertEqual(segments.map(\.key), [
            .block([0]), .block([1]),
            .block([2, 0, 0]), .block([2, 0, 1, 0, 0]),
            .block([3, 0]),
            .block([4]),
            .cell([5], row: nil, column: 0), .cell([5], row: nil, column: 1),
            .cell([5], row: 0, column: 0), .cell([5], row: 0, column: 1)
        ])
        XCTAssertEqual(segments.map(\.text), [
            "Title bar", "A code span and a link.", "first item", "nested item", "quoted text",
            "let title = \"bar\"", "Name", "Value", "bar", "1"
        ])
        // The keys name the same blocks the document view walks.
        let document = TranscriptMarkdownDocument(source)
        XCTAssertEqual(document.block(at: [2, 0, 1, 0, 0]), .paragraph("nested *item*"))
        XCTAssertEqual(document.block(at: [3, 0]), .paragraph("quoted text"))
    }

    func testOnlySentAndAssistantMessagesAreSearchedAndFoldedWorkIsNamed() throws {
        let user = TranscriptEntry(content: .user(text: "Fix the title bar"))
        let thought = TranscriptEntry(content: .reasoning(text: "title bar thinking", isStreaming: false))
        let tool = TranscriptEntry(content: .activity(
            HarnessActivity(id: "t1", kind: "command", title: "grep title bar", detail: "title bar"), state: .completed
        ))
        let note = TranscriptEntry(content: .assistant(text: "Looking at the title bar.", isStreaming: false))
        let final = TranscriptEntry(content: .assistant(text: "The title bar is fixed.", isStreaming: false))
        let units = ConversationFindSource.transcript(
            [user, thought, tool, note, final], latestTurnIsComplete: true
        ).units
        XCTAssertEqual(units.map(\.id), [user, note, final].map(\.id.uuidString))
        // Every match scrolls to its turn, named by its request; the commentary in the completed
        // turn's folded work opens the turn.
        XCTAssertEqual(units.map(\.scrollID), Array(repeating: user.id.uuidString, count: 3))
        XCTAssertEqual(units[1].revealID, user.id.uuidString)
        XCTAssertNil(units[0].revealID)
        XCTAssertNil(units[2].revealID)

        var cache = ConversationFindSegmentCache()
        let result = ConversationFindEngine.search("TITLE BAR", units: units, cache: &cache)
        XCTAssertEqual(result.matches.map(\.unitID), [user, note, final].map(\.id.uuidString))
    }

    func testCodexMessagesFollowTheTimelineOrderAndCommentaryOpensItsTurn() throws {
        try checkCodexMessagesFollowTheTimelineOrderAndCommentaryOpensItsTurn()
    }

    func testACappedSearchKeepsTheFirstMatchesAndSaysThereAreMore() {
        let units = (0..<5).map { index in
            ConversationFindUnit(id: "u\(index)", scrollID: "r\(index)", revealID: nil, body: .plain("bar bar"))
        }
        var cache = ConversationFindSegmentCache()
        let capped = ConversationFindEngine.search("bar", units: units, cache: &cache, limit: 4)
        XCTAssertEqual(capped.matches.count, 4)
        XCTAssertTrue(capped.isCapped)
        XCTAssertEqual(capped.matches.map(\.location.occurrence), [0, 1, 0, 1])
        let exact = ConversationFindEngine.search("bar", units: units, cache: &cache, limit: 10)
        XCTAssertEqual(exact.matches.count, 10)
        XCTAssertFalse(exact.isCapped)
    }

    // MARK: - Moving

    func testTypingFindsTheFirstMatchAndReturnAndGWrapAround() async {
        let (find, entries) = openFind(["title one", "nothing here", "Title two and TITLE three"])
        find.query = "title"
        await find.waitForSearch()
        XCTAssertEqual(find.currentResult?.matches.count, 3)
        XCTAssertEqual(find.activeIndex, 0)
        XCTAssertEqual(find.scrollRequest?.scrollID, entries[0].id.uuidString)

        find.submit()
        XCTAssertEqual(find.activeIndex, 1)
        XCTAssertEqual(find.scrollRequest?.scrollID, entries[2].id.uuidString)
        find.next()
        find.next()
        XCTAssertEqual(find.activeIndex, 0, "⌘G wraps past the last match")
        find.submit(backward: true)
        XCTAssertEqual(find.activeIndex, 2, "Shift-Return wraps to the last match")
        find.previous()
        XCTAssertEqual(find.activeIndex, 1)

        // A new query keeps the position while it still exists, as the Codex app does.
        find.query = "title t"
        await find.waitForSearch()
        XCTAssertEqual(find.currentResult?.matches.count, 2)
        XCTAssertEqual(find.activeIndex, 1)
        find.query = "nothing"
        await find.waitForSearch()
        XCTAssertEqual(find.activeIndex, 0)
        find.query = "absent"
        await find.waitForSearch()
        XCTAssertEqual(find.currentResult?.matches.count, 0)
        XCTAssertNil(find.activeIndex)
        let token = find.scrollRequest?.token
        find.next()
        XCTAssertEqual(find.scrollRequest?.token, token, "no match, nothing moves")
    }

    func testReturnBeforeTheSearchSettlesStartsAtTheFirstMatch() async {
        let (find, _) = openFind(["alpha beta", "beta gamma"])
        find.debounce = .seconds(30)
        find.query = "beta"
        XCTAssertNil(find.currentResult)
        find.submit()
        await find.waitForSearch()
        XCTAssertEqual(find.activeIndex, 0)
        XCTAssertEqual(find.currentResult?.matches.count, 2)
    }

    func testGoingToAMatchInFoldedWorkOpensIt() async {
        let user = TranscriptEntry(content: .user(text: "Fix it"))
        let note = TranscriptEntry(content: .assistant(text: "Reading the title bar code.", isStreaming: false))
        let final = TranscriptEntry(content: .assistant(text: "Done.", isStreaming: false))
        let find = ConversationFindModel()
        find.debounce = .zero
        find.open()
        find.updateSource(.transcript([user, note, final], latestTurnIsComplete: true))
        let container = find.slot(for: .container(user.id.uuidString))
        XCTAssertEqual(container.revealToken, 0)
        find.query = "title bar"
        await find.waitForSearch()
        XCTAssertEqual(find.activeMatch?.revealID, user.id.uuidString)
        XCTAssertEqual(container.revealToken, 1)
        find.next()
        XCTAssertEqual(container.revealToken, 2, "each visit opens it again if it was folded by hand")
        find.close()
        XCTAssertEqual(container.revealToken, 0)
    }

    func testConversationUpdatesKeepTheCurrentMatchWithoutMovingTheView() async {
        let first = TranscriptEntry(content: .user(text: "bar one"))
        let second = TranscriptEntry(content: .assistant(text: "bar two", isStreaming: false))
        let find = ConversationFindModel()
        find.debounce = .zero
        find.open()
        find.updateSource(.transcript([first, second], latestTurnIsComplete: true))
        find.query = "bar"
        await find.waitForSearch()
        find.next()
        XCTAssertEqual(find.activeMatch?.unitID, second.id.uuidString)
        let token = find.scrollRequest?.token

        // A streamed answer and an earlier message arriving do not take the reader elsewhere.
        let streamed = TranscriptEntry(content: .user(text: "bar three"))
        find.updateSource(.transcript([first, second, streamed], latestTurnIsComplete: false))
        await find.waitForSearch()
        XCTAssertEqual(find.currentResult?.matches.count, 3)
        XCTAssertEqual(find.activeMatch?.unitID, second.id.uuidString)
        XCTAssertEqual(find.scrollRequest?.token, token)
    }

    func testCloseClearsTheQueryAndMarksAndReturnsFocus() async {
        let (find, entries) = openFind(["bar"], returnFocus: true)
        find.query = "bar"
        await find.waitForSearch()
        let slot = find.slot(for: .unit(entries[0].id.uuidString))
        XCTAssertEqual(slot.query, "bar")
        XCTAssertNotNil(slot.active)
        XCTAssertTrue(find.close())
        XCTAssertFalse(find.isPresented)
        XCTAssertEqual(find.query, "")
        XCTAssertNil(slot.query)
        XCTAssertNil(slot.active)
        XCTAssertNil(find.result)
        XCTAssertFalse(find.close(), "closing twice does nothing")
    }

    func testASingleLineSelectionBecomesTheQuery() {
        let find = ConversationFindModel()
        find.debounce = .seconds(30)
        find.open(selection: "  title bar ")
        XCTAssertEqual(find.query, "title bar")
        XCTAssertEqual(find.focusRequest, 1)
        find.open(selection: "two\nlines")
        XCTAssertEqual(find.query, "title bar", "a selection across lines is not a query")
        XCTAssertEqual(find.focusRequest, 2, "⌘F again returns to the field")
    }

    // MARK: - Marks

    func testANewQueryRedrawsOnlyTheMessagesItMarks() async {
        let (find, entries) = openFind(["alpha", "beta", "gamma"])
        find.query = "alpha"
        await find.waitForSearch()
        let alpha = find.slot(for: .unit(entries[0].id.uuidString))
        let beta = find.slot(for: .unit(entries[1].id.uuidString))
        let gamma = find.slot(for: .unit(entries[2].id.uuidString))
        XCTAssertEqual(alpha.query, "alpha")
        XCTAssertNil(beta.query)

        let touched = Touched()
        for (name, slot) in [("alpha", alpha), ("beta", beta), ("gamma", gamma)] {
            withObservationTracking { _ = slot.query; _ = slot.active } onChange: { touched.insert(name) }
        }
        find.query = "beta"
        await find.waitForSearch()
        XCTAssertEqual(touched.names, ["alpha", "beta"], "gamma never held a match and is not redrawn")
        XCTAssertEqual(beta.active, ConversationFindLocation(key: .block([0]), occurrence: 0))
        XCTAssertNil(alpha.query)
    }

    func testMarksPaintEveryHitAndTheCurrentOneApart() {
        var text = AttributedString("bar foo BAR baz bar")
        let fraction = ConversationFindStyle.mark(
            &text, query: "bar", active: ConversationFindLocation(key: .text, occurrence: 1),
            key: .text, scheme: .light
        )
        let marked = text.runs.compactMap { run -> (String, Color)? in
            run[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self].map { (String(text[run.range].characters), $0) }
        }
        XCTAssertEqual(marked.map(\.0), ["bar", "BAR", "bar"])
        XCTAssertEqual(marked[1].1, ConversationFindStyle.activeColor(.light))
        XCTAssertEqual(marked[0].1, ConversationFindStyle.matchColor(.light))
        XCTAssertEqual(try XCTUnwrap(fraction), 9.5 / 19, accuracy: 0.001)

        var other = AttributedString("bar")
        XCTAssertNil(ConversationFindStyle.mark(&other, query: "bar", active: ConversationFindLocation(key: .block([1]), occurrence: 0),
                                                key: .block([0]), scheme: .dark),
                     "the current match is in another block")
        var code = AttributedString("one\ntwo\nbar\nfour")
        XCTAssertEqual(try XCTUnwrap(ConversationFindStyle.mark(
            &code, query: "bar", active: ConversationFindLocation(key: .block([0]), occurrence: 0),
            key: .block([0]), scheme: .dark, byLine: true
        )), 2.5 / 4, accuracy: 0.001)
    }

    func testALongMessageShowsAllOfItselfWhenTheMatchIsPastItsWindow() {
        let text = (1...400).map { "line \($0)" }.joined(separator: "\n")
        let limit = TranscriptRenderWindow.characterLimitShowingAll(of: text, initialCharacterLimit: 5_000)
        let window = TranscriptRenderWindow(
            text: text, characterLimit: limit, initialCharacterLimit: 5_000,
            lineLimit: TranscriptRenderWindow.chunkLineLimit * max(1, limit / 5_000)
        )
        XCTAssertFalse(window.hasMore)
        XCTAssertEqual(window.text, text)
    }

    // MARK: - Long conversations

    func testThousandsOfMessagesSearchQuicklyOnceParsed() async {
        var entries: [TranscriptEntry] = []
        for index in 0..<3_000 {
            entries.append(TranscriptEntry(content: .user(text: "Request \(index): check the build")))
            entries.append(TranscriptEntry(content: .assistant(text: """
            ## Result \(index)

            The **build** passed after `swift test` ran. See [the log](log-\(index).txt).

            - step one
            - step two with title bar \(index)

            ```sh
            swift build --build-system native
            ```
            """, isStreaming: false)))
        }
        let source = ConversationFindSource.transcript(entries, latestTurnIsComplete: true)
        let started = Date()
        let first = await ConversationFindEngine.search("title bar 2999", in: source, cache: ConversationFindSegmentCache())
        let parsed = Date().timeIntervalSince(started)
        XCTAssertEqual(first.result.matches.count, 1)
        XCTAssertEqual(first.cache.count, 6_000)

        let again = Date()
        let second = await ConversationFindEngine.search("build", in: source, cache: first.cache)
        let cached = Date().timeIntervalSince(again)
        XCTAssertEqual(second.result.matches.count, ConversationFindEngine.matchLimit)
        XCTAssertTrue(second.result.isCapped)
        print("find over 6,000 messages: first search \(Int(parsed * 1_000)) ms, cached \(Int(cached * 1_000)) ms")
        XCTAssertLessThan(cached, 2, "a search over parsed messages does not parse them again")
    }

    // MARK: - Renders

    func testRendersTheFindBarAndItsMarksInBothConversations() async throws {
        try await renderTheCodexCommentaryMatch()
        try await renderTheLongClaudeConversationMatch()
    }

    /// A match in a turn the window leaves out widens the window to it (plan A5.2): the turn is
    /// drawn, opened and brought into view.
    func testAMatchOutsideTheTurnWindowWidensItAndIsShown() async throws {
        let (entries, request, reading) = longClaudeConversation()
        let presentation = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        )
        let timeline = ConversationTimeline(
            source: .transcript(entries: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true),
            turnWindowCount: 5
        )
        XCTAssertTrue(ConversationTurnWindow(turnCount: 5).hides(request.id.uuidString, in: presentation))
        try await render(timeline, height: 560, name: "claude-windowed-match",
                         source: .conversation(presentation), query: "title bar", moves: 1) { find in
            XCTAssertEqual(find.activeMatch?.unitID, reading.id.uuidString)
            XCTAssertEqual(find.activeMatch?.scrollID, request.id.uuidString)
        } drawn: { elements in
            let text = elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(text.contains("the title bar uses a fixed frame"), "the match is drawn:\n\(text)")
            XCTAssertTrue(text.contains(L10n.string("Load more history")), "earlier turns stay out:\n\(text)")
        }
    }

    /// D11: a Codex thread draws its latest 40 loaded turns, and a match in an earlier one widens the
    /// window to it the same way: the turn is drawn and its folded commentary opened.
    func testACodexMatchOutsideTheTurnWindowWidensItAndIsShown() async throws {
        let turns = (0..<45).map { index in
            turn("turn-\(index)", status: "completed", items: index == 2 ? [
                userItem("u\(index)", "Why is it clipped?"),
                agentItem("m\(index)", "Measuring the title bar frame.", phase: "commentary"),
                agentItem("a\(index)", "Fixed.", phase: "final_answer")
            ] : [
                userItem("u\(index)", "Request \(index)"),
                agentItem("a\(index)", "Answer \(index)", phase: "final_answer")
            ])
        }
        let state = thread(turns)
        let presentation = CodexConversationProjection.presentation(
            state, workspaceURL: URL(filePath: "/Users/me/yardlet"), historySelection: nil
        )
        XCTAssertTrue(ConversationTurnWindow().hides("turn-2", in: presentation))
        let codex = TaskConversationView(harness: .codex, workspaceURL: URL(filePath: "/Users/me/yardlet"),
                                         entries: [], codexTaskState: state)
        try await render(codex, height: 560, name: "codex-windowed-match",
                         source: codexFindSource(state), query: "title bar", moves: 0) { find in
            XCTAssertEqual(find.activeMatch?.unitID, "m2")
            XCTAssertEqual(find.activeMatch?.scrollID, "turn-2")
        } drawn: { elements in
            let text = elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(text.contains("Measuring the title bar frame."), "the match is drawn:\n\(text)")
            XCTAssertTrue(text.contains(L10n.string("Load more history")), "earlier turns stay out:\n\(text)")
        }
    }
}

private extension ConversationFindSource {
    /// A shared transcript as its conversation hands it to find.
    static func transcript(_ entries: [TranscriptEntry], latestTurnIsComplete: Bool) -> Self {
        .conversation(TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: latestTurnIsComplete
        ))
    }
}
