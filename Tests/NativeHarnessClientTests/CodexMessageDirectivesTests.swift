import Foundation
import XCTest
@testable import NativeHarnessClient

/// The directives the Codex app draws in a Codex message (`CodexMessageDirectives`): file citations as
/// links to the file at its line, follow-ups as their phrase, review comments, a suggested task, a
/// disclosure and a visualization as cards — in a Codex message only, never in code, and only once a
/// directive is whole. The fixtures are made up in the shapes the real threads hold.
@MainActor
final class CodexMessageDirectivesTests: XCTestCase {
    private let decoder = CodexTaskDecoder()

    // MARK: - File citations

    func testAFileCitationIsALinkNamedForTheFileAndItsLines() throws {
        let cases: [(attributes: String, label: String, link: String)] = [
            (#"path="/work/app/Sources/App.swift" line_range_start=12 line_range_end=20"#,
             "App.swift (\(lines(12, 20)))", "/work/app/Sources/App.swift#L12-L20"),
            (#"path="/work/app/Sources/App.swift" line_range_start="12""#, "App.swift (\(line(12)))",
             "/work/app/Sources/App.swift#L12"),
            (#"path="/work/app/Sources/App.swift" line_range_start=7 line_range_end=7"#, "App.swift (\(line(7)))",
             "/work/app/Sources/App.swift#L7"),
            // Line 1 is named for code only, as the app names it.
            (#"path="/work/app/tool.py" line_range_start=1"#, "tool.py (\(line(1)))", "/work/app/tool.py#L1"),
            (#"path="/work/app/README.md" line_range_start=1"#, "README.md", "/work/app/README.md#L1"),
            (#"path="/work/app/README.md""#, "README.md", "/work/app/README.md"),
            // The shape the real threads hold: an output document and its page.
            (#"path="/work/out/report.pdf" artifact_kind="document" page_number="3" purpose="output""#,
             "report.pdf (\(L10n.format("page %lld", 3)))", "/work/out/report.pdf"),
            (#"path="/work/out/deck.pptx" artifact_kind="presentation" slide_number="2" purpose="source""#,
             "deck.pptx (\(L10n.format("slide %lld", 2)))", "/work/out/deck.pptx"),
            (#"path="/work/out/sheet.xlsx" artifact_kind="workbook" sheet="Q3" range="A1:B9""#,
             "sheet.xlsx (Q3!A1:B9)", "/work/out/sheet.xlsx"),
            // Spaces, parentheses and a hash in a file's name are part of its path.
            (#"path="/work/My Docs/notes (draft)#2.md" line_range_start=4"#, "notes (draft)#2.md (\(line(4)))",
             "/work/My%20Docs/notes%20%28draft%29%232.md#L4"),
            (#"path="Sources/App.swift" line_range_start=3"#, "App.swift (\(line(3)))", "Sources/App.swift#L3")
        ]
        for (attributes, label, link) in cases {
            let text = "See :codex-file-citation{\(attributes)} for it."
            let markdown = CodexMessageDirectives.inlineMarkdown(text)
            XCTAssertEqual(markdown, "See [\(CodexMessageDirectives.escaped(label))](\(link)) for it.", attributes)
            let paragraph = try inline(text)
            XCTAssertEqual(paragraph.plainText, "See \(label) for it.", attributes)
            XCTAssertEqual(links(in: paragraph).map(\.relativeString), [link], attributes)
        }
    }

    func testABracketCitationIsALinkToo() throws {
        XCTAssertEqual(try inline("Read 【F:/work/app/a.swift†L3-L5】 first.").plainText, "Read a.swift (\(lines(3, 5))) first.")
        XCTAssertEqual(links(in: try inline("Read 【F:/work/app/a.swift†L3-L5】 first.")).map(\.relativeString),
                       ["/work/app/a.swift#L3-L5"])
        XCTAssertEqual(try inline("Read 【/work/app/b.swift†L9】.").plainText, "Read b.swift (\(line(9))).")
        // Without `F:` the path must be absolute; a range must read `L3-L5`.
        XCTAssertEqual(try inline("Read 【b.swift†L9】.").plainText, "Read 【b.swift†L9】.")
        XCTAssertEqual(try inline("Read 【F:/a.swift†L3-5】.").plainText, "Read 【F:/a.swift†L3-5】.")
    }

    func testAWebOrLiveCitationAndOneWithoutAPath() throws {
        let web = try inline(#"Docs: :codex-file-citation{path="https://example.test/spec(v2)" label="Spec"}."#)
        XCTAssertEqual(web.plainText, "Docs: Spec.")
        XCTAssertEqual(links(in: web).map(\.absoluteString), ["https://example.test/spec%28v2%29"])
        XCTAssertEqual(try inline(#"Docs: :codex-file-citation{path="https://example.test/a"}."#).plainText,
                       "Docs: https://example.test/a.")
        // A live document of the Codex app has nothing Yardlet can open: its name stays, unlinked.
        let live = try inline(#"Deck: :codex-file-citation{path="deck-1" mode="live" artifact_kind="presentation" title="Plan"}."#)
        XCTAssertEqual(live.plainText, "Deck: Plan.")
        XCTAssertTrue(links(in: live).isEmpty)
        // The app draws nothing for a citation it cannot read.
        XCTAssertEqual(try inline(#"Gone: :codex-file-citation{line_range_start=3}."#).plainText, "Gone: .")
    }

    func testCodeAndMalformedOrUnknownDirectivesStayText() throws {
        let literal = [
            "Write `:codex-file-citation{path=\"/a.swift\"}` to cite.",
            "Open :codex-file-citation{path=\"/a.swift\" and more",
            "Not one ::codex-file-citation{path=\"/a.swift\"} here",
            "An :other-directive{path=\"/a.swift\"} stays",
            "A :codex-followup without anything"
        ]
        for text in literal {
            XCTAssertEqual(CodexMessageDirectives.inlineMarkdown(text), text, text)
        }
        let fenced = "```swift\nlet cite = \":codex-file-citation{path=\\\"/a.swift\\\"}\"\n::code-comment{title=\"t\" body=\"b\" file=\"a\"}\n:::task-stub{title=\"x\"}\nDo it\n:::\n```"
        XCTAssertEqual(CodexMessageDirectives.blocks(fenced), [.markdown(fenced)])
        guard case let .code(_, code) = try XCTUnwrap(TranscriptMarkdownDocument(fenced, dialect: .codex).blocks.first) else {
            return XCTFail("the fence is not code")
        }
        XCTAssertTrue(code.contains(":codex-file-citation{") && code.contains("::code-comment{"))
    }

    func testAFollowUpReadsAsItsPhrase() throws {
        let text = """
        Next you could:
        - :codex-followup[Make the chart bigger]{prompt="Make the revenue chart twice as tall"}
        - :codex-followup[Add **totals**]{prompt="Add a totals row"}
        - :codex-followup{prompt="No phrase"}
        """
        XCTAssertEqual(CodexMessageDirectives.inlineMarkdown(text),
                       "Next you could:\n- Make the chart bigger\n- Add **totals**\n- ")
    }

    // MARK: - Cards

    func testReviewCommentsInARowAreOneCard() {
        let text = """
        Two problems.

        ::code-comment{title="[P1] Off by one" body="The loop stops one short." file="/work/app/Sources/Loop.swift" start=10 end=12}

        ::code-comment{title="Missing check" body="Guard the empty list." file="app/Sources/List.swift" start=4 priority=2 confidence=0.8}
        ::code-comment{title="No body" file="/work/app/a.swift"}

        One more, later:
        ::code-comment{title="Typo" body="Spelled wrong." file="/work/app/README.md" start=7 end=3}
        ::code-comment{title="Unreadable"}
        """
        let blocks = CodexMessageDirectives.blocks(text)
        XCTAssertEqual(blocks.count, 4, "\(blocks)")
        XCTAssertEqual(blocks.first, .markdown("Two problems.\n"))
        guard case let .reviewComments(first) = blocks[1], case let .reviewComments(second) = blocks[3] else {
            return XCTFail("\(blocks)")
        }
        XCTAssertEqual(first.map(\.title), ["Off by one", "Missing check"])
        XCTAssertEqual(first.map(\.priority), ["P1", "P2"])
        XCTAssertEqual(first[0].body, "The loop stops one short.")
        let workspace = URL(filePath: "/work/app", directoryHint: .isDirectory)
        XCTAssertEqual(first.map { $0.location(relativeTo: workspace) }, ["Sources/Loop.swift:10-12", "Sources/List.swift:4"])
        XCTAssertEqual(first[0].link(relativeTo: workspace)?.absoluteString, "file:///work/app/Sources/Loop.swift#L10-L12")
        // A path in the task folder may begin with the folder's own name.
        XCTAssertEqual(first[1].link(relativeTo: workspace)?.absoluteString, "file:///work/app/Sources/List.swift#L4")
        XCTAssertEqual(second.map(\.title), ["Typo"])
        XCTAssertEqual(second.first?.location(relativeTo: workspace), "README.md:7", "an end before the start is the start")
        XCTAssertEqual(blocks[2], .markdown("\nOne more, later:"))
        // A run of comments none of which can be read draws nothing.
        XCTAssertEqual(CodexMessageDirectives.blocks("Done.\n::code-comment{title=\"Only\"}"), [.markdown("Done.")])
    }

    func testASuggestedTaskADisclosureAndAVisualization() {
        let text = """
        Here is what I found.

        :::task-stub{title="Add tests for the parser"}
        Write unit tests for the parser's error paths.
        Cover empty input.
        :::

        ::task-stub[Rename the module]{title="Rename"}

        :::github-details{summary="Build log" open="true"}
        The build failed in **two** places:

        ```text
        :::
        not a close
        ```

        :::note
        an inner container
        :::
        :::

        ::codex-inline-vis{file="revenue-chart.html"}
        ::codex-inline-vis{path="/tmp/viz/growth.html" title="Growth by month" mode="wide"}
        ::codex-inline-vis{title="No file"}
        """
        let blocks = CodexMessageDirectives.blocks(text)
        XCTAssertEqual(blocks.count, 7, "\(blocks)")
        XCTAssertEqual(blocks[0], .markdown("Here is what I found.\n"))
        XCTAssertEqual(blocks[1], .suggestedTask(CodexSuggestedTask(
            title: "Add tests for the parser", prompt: "Write unit tests for the parser's error paths.\nCover empty input."
        )))
        XCTAssertEqual(blocks[2], .suggestedTask(CodexSuggestedTask(title: "Rename", prompt: "Rename the module")))
        guard case let .details(summary, isOpen, body) = blocks[3] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(summary, "Build log")
        XCTAssertTrue(isOpen)
        XCTAssertTrue(body.hasPrefix("The build failed") && body.hasSuffix(":::note\nan inner container\n:::"), body)
        XCTAssertEqual(blocks[4], .visualization(CodexVisualization(title: "revenue-chart", file: "revenue-chart.html")))
        XCTAssertEqual(blocks[5], .visualization(CodexVisualization(title: "Growth by month", file: "/tmp/viz/growth.html",
                                                                    isWide: true)))
        // A visualization naming no file is no card.
        XCTAssertEqual(blocks[6], .markdown("::codex-inline-vis{title=\"No file\"}"))

        // The disclosure's Markdown is a Codex message's Markdown too.
        let document = TranscriptMarkdownDocument(text, dialect: .codex)
        guard case let .details(_, _, inside) = document.blocks.first(where: {
            if case .details = $0 { true } else { false }
        }) else { return XCTFail("\(document.blocks)") }
        XCTAssertTrue(inside.contains { if case .code = $0 { true } else { false } })
    }

    func testAContainerWithoutItsClosingLineAndOtherNamesStayText() {
        let unclosed = ":::github-details{summary=\"Log\"}\nline one\nline two"
        XCTAssertEqual(CodexMessageDirectives.blocks(unclosed), [.markdown(unclosed)])
        for text in ["::writing{id=\"a\"}", ":::writing{id=\"a\" variant=\"email\"}\nHi\n:::", "::task-stub{title=\"a\"} trailing words",
                     "    ::code-comment{title=\"t\" body=\"b\" file=\"a\"}", "::code-comment"] {
            XCTAssertEqual(CodexMessageDirectives.blocks(text), [.markdown(text)], text)
        }
    }

    func testAnotherHarnessReadsTheSameTextAsText() {
        let text = "See :codex-file-citation{path=\"/a.swift\" line_range_start=2}.\n\n::code-comment{title=\"t\" body=\"b\" file=\"/a.swift\"}"
        let standard = TranscriptMarkdownDocument(text).blocks
        XCTAssertEqual(standard.count, 2)
        guard case let .paragraph(first) = standard[0] else { return XCTFail("\(standard)") }
        XCTAssertTrue(first.plainText.contains(":codex-file-citation{"))
        let codex = TranscriptMarkdownDocument(text, dialect: .codex).blocks
        guard case .reviewComments = codex.last else { return XCTFail("\(codex)") }
    }

    // MARK: - While a message is written

    func testADrawnDirectiveIsLeftOutUntilItIsWhole() {
        func shown(_ text: String) -> String { CodexDirectiveMarkup.displayText(text, isStreaming: true) }
        XCTAssertEqual(shown("See :codex-file-citation{path=\"/work/a.sw"), "See")
        XCTAssertEqual(shown("See :codex-file-citation{path=\"/work/a.swift\"} and :codex-followup[Make it"),
                       "See :codex-file-citation{path=\"/work/a.swift\"} and")
        XCTAssertEqual(shown("Done.\n::task-st"), "Done.")
        XCTAssertEqual(shown("Done.\n:::github-det"), "Done.")
        XCTAssertEqual(shown("Done.\n::codex-inline-vis{file=\"a"), "Done.")
        XCTAssertEqual(shown("Done.\n::code-comment{title=\"t\" body=\"b\" file=\"a\"}\nMore"), "Done.\nMore")
        // A card still waiting for its closing line reads as its Markdown until it closes.
        XCTAssertEqual(shown("Logs:\n:::github-details{summary=\"Build\"}\nline one\nline two"), "Logs:\nline one\nline two")
        let closed = "Logs:\n:::github-details{summary=\"Build\"}\nline one\n:::\nAfter"
        XCTAssertEqual(shown(closed), closed)
        // A finished message keeps them all for the renderer.
        let finished = "See :codex-file-citation{path=\"/work/a.sw"
        XCTAssertEqual(CodexDirectiveMarkup.displayText(finished, isStreaming: false), finished)
        XCTAssertNil(ConversationAutomationText.agentMessage(":codex-file-citation{path=\"/a", harness: .codex,
                                                             inHeartbeatTurn: false, isStreaming: true))
        // Another harness's message is its own text.
        XCTAssertEqual(ConversationAutomationText.agentMessage("See :codex-file-citation{path=\"/a", harness: .claudeCode,
                                                               inHeartbeatTurn: false, isStreaming: true),
                       "See :codex-file-citation{path=\"/a")
    }

    /// A model writes a visualization as the `visualize` skill teaches: a JSON reference in private-use marks, on a
    /// line of its own or inside one, or the same without the marks on a line of its own. Each is the card the
    /// directive draws, and copying leaves it out, as the app does.
    func testAModelsVisualizationReferenceIsItsCard() {
        let path = "/Users/me/.codex/visualizations/2026/11/19/01a1f000/layouts.html"
        let text = "Two layouts, side by side.\n\n\u{E200}visualize\u{E202}{\"path\":\"\(path)\",\"title\":\"첫 화면 배치\","
            + "\"mode\":\"wide\"}\u{E201}\n\nThe steps one fits a first launch. "
            + "Then: \u{E200}visualize\u{E202}{\"path\":\"chart.html\"}\u{E201} and more.\n\nvisualize{\"path\":\"plain.html\"}"
        XCTAssertEqual(CodexMessageDirectives.blocks(text), [
            .markdown("Two layouts, side by side.\n"),
            .visualization(CodexVisualization(title: "첫 화면 배치", file: path, isWide: true)),
            .markdown("\nThe steps one fits a first launch. Then: "),
            .visualization(CodexVisualization(title: "chart", file: "chart.html")),
            .markdown(" and more.\n"),
            .visualization(CodexVisualization(title: "plain", file: "plain.html"))
        ])
        XCTAssertEqual(CodexMessageDirectives.copyText(text),
                       "Two layouts, side by side.\n\n\nThe steps one fits a first launch. Then: \n and more.\n")
        // Not a reference: no HTML file, or words around it on its line.
        XCTAssertEqual(CodexMessageDirectives.blocks("visualize{\"path\":\"a.png\"}"), [.markdown("visualize{\"path\":\"a.png\"}")])
        XCTAssertEqual(CodexMessageDirectives.blocks("Call visualize{\"path\":\"a.html\"} here"),
                       [.markdown("Call visualize{\"path\":\"a.html\"} here")])
    }

    // MARK: - Copy

    func testCopyingAMessageCopiesWhatTheAppCopies() {
        let text = """
        Built the chart. See 【F:/work/a.swift†L3-L5】 and 【F:/work/b.md†L1】 and :codex-file-citation{path="/work/c.swift"}.

        ::codex-inline-vis{file="chart.html"}

        - :codex-followup[Make it taller]{prompt="Make the chart taller"}

        ```
        :codex-followup[kept]{prompt="code"}
        ```
        """
        XCTAssertEqual(CodexMessageDirectives.copyText(text), """
        Built the chart. See /work/a.swift:3-5 and /work/b.md and :codex-file-citation{path="/work/c.swift"}.


        - Make it taller

        ```
        :codex-followup[kept]{prompt="code"}
        ```
        """)
        XCTAssertEqual(CodexMessageDirectives.copyText("Plain words."), "Plain words.")
    }

    // MARK: - Projection and find

    func testACodexConversationKeepsItsDirectivesForTheRendererAndFindReadsWhatIsDrawn() {
        let answer = """
        The fix is in :codex-file-citation{path="/work/app/Sources/Parser.swift" line_range_start=42}.

        :::github-details{summary="Why it failed"}
        The tokenizer dropped the last byte.
        :::

        ::code-comment{title="[P2] Unchecked index" body="Index can run past the end." file="/work/app/Sources/Parser.swift" start=40}
        ::git-push{cwd="/work/app" branch="fix/parser"}
        """
        let state = codexThread(turns: [turn("turn-1", items: [user("u1", "Fix the parser"), agent("a1", "final_answer", answer)])])
        let presentation = CodexConversationProjection.presentation(state, workspaceURL: URL(filePath: "/work/app"),
                                                                    historySelection: nil)
        guard case let .answer(text, _) = presentation.turns[0].answers.first?.kind else {
            return XCTFail("\(presentation.turns)")
        }
        XCTAssertTrue(text.contains(":codex-file-citation{") && text.contains("::code-comment{"), text)
        XCTAssertFalse(text.contains("::git-push"), text)

        let units = ConversationFindSource.conversation(presentation).units
        XCTAssertEqual(units.last?.body, .markdown(text, dialect: .codex))
        let segments = ConversationFindEngine.segments(for: .markdown(text, dialect: .codex)).map(\.text)
        XCTAssertEqual(segments, ["The fix is in Parser.swift (\(line(42))).", "Why it failed", "The tokenizer dropped the last byte."])

        // The same message in a detached Codex task's transcript reads the same way; Claude's does not.
        let entries = [TranscriptEntry(content: .user(text: "Fix the parser")),
                       TranscriptEntry(content: .assistant(text: answer, isStreaming: false))]
        let detached = TranscriptConversationProjection.presentation(from: entries, harness: .codex, status: .ready,
                                                                     latestTurnIsComplete: true)
        guard case let .markdown(_, dialect)? = ConversationFindSource.conversation(detached).units.last?.body else {
            return XCTFail("no answer")
        }
        XCTAssertEqual(dialect, .codex)
        let claude = TranscriptConversationProjection.presentation(from: entries, harness: .claudeCode, status: .ready,
                                                                   latestTurnIsComplete: true)
        XCTAssertEqual(ConversationFindSource.conversation(claude).units.last?.body, .markdown(answer))
    }

    // MARK: - Opening a citation

    func testACitationOpensItsFileAtItsLineInTheFileViewer() throws {
        let workspace = FileManager.default.temporaryDirectory.appending(path: "yardlet-citation-\(UUID().uuidString)",
                                                                           directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace.appending(path: "Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appending(path: "Sources/App.swift")
        try (1...30).map { "line \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        for text in [
            "See :codex-file-citation{path=\"\(file.path(percentEncoded: false))\" line_range_start=12 line_range_end=14}.",
            "See :codex-file-citation{path=\"Sources/App.swift\" line_range_start=12}.",
            "See 【F:\(file.path(percentEncoded: false))†L12】."
        ] {
            // The link the paragraph draws, as the conversation resolves it against the task's folder.
            let resolved = try inline(text).resolved(relativeTo: workspace)
            let link = try XCTUnwrap(resolved.runs.compactMap(\.link).first, text)
            let location = try WorkspaceFileLocation.resolve(link, in: workspace)
            XCTAssertEqual(location.relativePath, "Sources/App.swift", text)
            XCTAssertEqual(location.line, 12, text)
            // The file viewer the window hands file links to goes to that line.
            let files = WorkspaceFilesState()
            files.open(link, in: workspace)
            XCTAssertEqual(files.requestedLocation, location, text)
            XCTAssertEqual(files.preferences.selectedPath, "Sources/App.swift", text)
        }
    }

    // MARK: - A heartbeat's turn

    func testAHeartbeatTurnOffersNoEditOfItsXML() {
        let heartbeat = """
        <heartbeat>
          <automation_id>nightly</automation_id>
          <current_time_iso>2026-10-13T09:00:00Z</current_time_iso>
          <instructions>Check the build.</instructions>
        </heartbeat>
        """
        let state = codexThread(turns: [
            turn("turn-1", items: [user("u1", "Set up the check"), agent("a1", "final_answer", "Done.")]),
            turn("turn-2", items: [user("u2", heartbeat), agent("a2", "final_answer", "Green.")])
        ])
        let turns = CodexConversationProjection.presentation(state, workspaceURL: URL(filePath: "/work"),
                                                             historySelection: nil).turns
        let handlers = ConversationTurnHandlers(edit: { _ in }, fork: {})
        XCTAssertNil(turns[1].actions.editDraft)
        XCTAssertFalse(turns[1].actions.canEdit)
        XCTAssertNil(turns[1].actions.failedRequestDraft)
        XCTAssertEqual(ConversationTurnAction.items(for: turns[1].actions, handlers: handlers), [.fork])
        // A request the person wrote still edits, but only the latest: this one offers none.
        XCTAssertEqual(ConversationTurnAction.items(for: turns[0].actions, handlers: handlers), [.fork])
        XCTAssertTrue(turns[0].actions.editsTurnInComposer)

        // Claude's "Edit message" never takes a heartbeat either.
        let entries = [TranscriptEntry(content: .user(text: heartbeat)),
                       TranscriptEntry(content: .assistant(text: "Green.", isStreaming: false))]
        let claude = TranscriptConversationProjection.presentation(from: entries, harness: .claudeCode, status: .ready,
                                                                   latestTurnIsComplete: true)
        XCTAssertNil(claude.turns.last?.actions.editLatest)
        let written = TranscriptConversationProjection.presentation(
            from: [TranscriptEntry(content: .user(text: "Check the build")),
                   TranscriptEntry(content: .assistant(text: "Green.", isStreaming: false))],
            harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        )
        XCTAssertNotNil(written.turns.last?.actions.editLatest)
    }

    func testTheKoreanWordsAreTheCodexApps() {
        let pairs = [
            ("line %lld", "%lld번째 줄"), ("lines %lld-%lld", "%lld-%lld줄"), ("page %lld", "%lld페이지"),
            ("Suggested task", "제안된 작업"), ("Use suggestion", "제안 사용"), ("%lld comments", "댓글 %lld개"),
            ("Collapse comments", "댓글 접기"), ("View %@ in %@", "%2$@에서 %1$@ 보기")
        ]
        for (key, korean) in pairs {
            XCTAssertEqual(L10n.string(key, languageCode: "ko"), korean, key)
            XCTAssertNotEqual(L10n.string(key, languageCode: "en"), "", key)
        }
        XCTAssertEqual(String(format: L10n.string("View %@ in %@", languageCode: "ko"), "Typo", "README.md:7"),
                       "README.md:7에서 Typo 보기")
    }

    // MARK: - Helpers

    private func line(_ number: Int) -> String { L10n.format("line %lld", number) }
    private func lines(_ start: Int, _ end: Int) -> String { L10n.format("lines %lld-%lld", start, end) }

    /// The first paragraph `text` draws as a Codex message.
    private func inline(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> TranscriptInlineContent {
        let blocks = TranscriptMarkdownDocument(text, dialect: .codex).blocks
        guard case let .paragraph(content) = try XCTUnwrap(blocks.first, file: file, line: line) else {
            XCTFail("no paragraph: \(blocks)", file: file, line: line)
            return TranscriptInlineContent(plainText: "")
        }
        return content
    }

    private func links(in content: TranscriptInlineContent) -> [URL] {
        content.attributed.runs.compactMap(\.link)
    }

    private func user(_ id: String, _ text: String) -> CodexItemState {
        decoder.item(from: .object([
            "id": .string(id), "type": .string("userMessage"),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])])
        ]), fallbackID: id, lifecycle: .completed)
    }

    private func agent(_ id: String, _ phase: String, _ text: String) -> CodexItemState {
        decoder.item(from: .object([
            "id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string(phase)
        ]), fallbackID: id, lifecycle: .completed)
    }

    private func turn(_ id: String, items: [CodexItemState]) -> CodexTurnState {
        var turn = decoder.turn(from: .object(["id": .string(id), "status": .string("completed"), "items": .array([])]),
                                fallbackID: id)!
        turn.items = items
        return turn
    }

    private func codexThread(turns: [CodexTurnState]) -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string("thread-directives")]))!
        thread.turns = turns
        return CodexTaskState(thread: thread)
    }
}
