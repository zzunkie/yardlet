import XCTest
@testable import NativeHarnessClient

final class TranscriptMarkdownDocumentTests: XCTestCase {
    func testPreservesGrokParagraphsAndProjectsMarkdownTable() {
        let document = TranscriptMarkdownDocument("""
            네. **Grok 쪽은 정상**입니다.

            이 레포 기준으로 보면:

            | 항목 | 상태 |
            |------|------|
            | Grok 도구 | 동작함 |
            | Git | `main` |

            다음 작업을 진행할 수 있습니다.
            """)

        XCTAssertEqual(document.blocks, [
            .paragraph("네. **Grok 쪽은 정상**입니다."),
            .paragraph("이 레포 기준으로 보면:"),
            .table(
                headers: ["항목", "상태"],
                rows: [["Grok 도구", "동작함"], ["Git", "`main`"]],
                alignments: [.leading, .leading]
            ),
            .paragraph("다음 작업을 진행할 수 있습니다.")
        ])
    }

    func testProjectsHeadingsListsQuotesCodeAndDividersAsBlocks() {
        let document = TranscriptMarkdownDocument("""
            ## Result

            - first
            - **second**

            1. one
            2. two

            > quoted

            ```swift
            print("hello")
            ```

            ---
            """)

        XCTAssertEqual(document.blocks, [
            .heading(level: 2, text: "Result"),
            .unorderedList(["first", "**second**"]),
            .orderedList(start: 1, items: ["one", "two"]),
            .blockQuote([.paragraph("quoted")]),
            .code(language: "swift", text: "print(\"hello\")"),
            .divider
        ])
    }

    func testPreservesExplicitLineBreaksInsideParagraph() {
        XCTAssertEqual(
            TranscriptMarkdownDocument("first line\nsecond line").blocks,
            [.paragraph("first line\nsecond line")]
        )
    }

    func testLooseOrderedListKeepsOneSequenceAndItsStartNumber() {
        XCTAssertEqual(TranscriptMarkdownDocument("3. **준비** 👩🏽‍💻\n\n1. 검토\n \t\n\n9. 완료").blocks, [
            .orderedList(start: 3, items: ["**준비** 👩🏽‍💻", "검토", "완료"], isLoose: true)
        ])
        XCTAssertEqual(TranscriptMarkdownDocument("0) zero\n1) one\n").blocks, [
            .orderedList(start: 0, items: ["zero", "one"])
        ])
    }

    func testListsStopAtParagraphsHeadingsFencesAndDifferentMarkers() {
        let source = "1. first\n\nParagraph.\n\n7. later\n\n## Heading\n\n9) next\n10. separate\n\n```text\n11. literal\n```"
        XCTAssertEqual(TranscriptMarkdownDocument(source).blocks, [
            .orderedList(start: 1, items: ["first"]),
            .paragraph("Paragraph."),
            .orderedList(start: 7, items: ["later"]),
            .heading(level: 2, text: "Heading"),
            .orderedList(start: 9, items: ["next"]),
            .orderedList(start: 10, items: ["separate"]),
            .code(language: "text", text: "11. literal")
        ])
    }

    func testLooseBulletsKeepThematicBreaksAndMarkerChangesSeparate() {
        XCTAssertEqual(TranscriptMarkdownDocument("- one\n\n- two\n\n* * *\n\n+ three\n- four").blocks, [
            .unorderedList(["one", "two"], isLoose: true),
            .divider,
            .unorderedList(["three"]),
            .unorderedList(["four"])
        ])
    }

    func testOrderedMarkersRequireBoundedASCIIDigitsAndWhitespace() {
        for text in ["1234567890. too long", "١. Unicode", "1.no space", "1.2 version"] {
            XCTAssertEqual(TranscriptMarkdownDocument(text).blocks, [.paragraph(TranscriptInlineContent(plainText: text))])
        }
        XCTAssertEqual(TranscriptMarkdownDocument("123456789. valid\n2.\ttab").blocks, [
            .orderedList(start: 123456789, items: ["valid", "tab"])
        ])
    }

    func testNestedListsAndContinuationParagraphsKeepTheirParentItem() {
        let source = "9. Parent\n   continued\n\n   - Child **one**\n   - Child two\n\n   Last paragraph.\n\n1. Next parent"
        XCTAssertEqual(TranscriptMarkdownDocument(source).blocks, [
            .orderedList(start: 9, items: [
                .init(blocks: [
                    .paragraph("Parent\ncontinued"),
                    .unorderedList(["Child **one**", "Child two"]),
                    .paragraph("Last paragraph.")
                ]),
                "Next parent"
            ], isLoose: true)
        ])
    }

    func testNestedQuotedCodeCopiesOnlyItsCodeWithOriginalLineEndings() {
        let source = "> 1. Code\r\n>\r\n>    ```swift\r\n>    let 한글 = \"👩🏽‍💻\"\r\n>      print(한글)\n>    \r\n>    ```\r\n>\r\n> 2. Done"
        XCTAssertEqual(TranscriptCopyPayload.code(in: source, blockPath: [0, 0, 0, 1]),
                       "let 한글 = \"👩🏽‍💻\"\r\n  print(한글)\n")
        XCTAssertNil(TranscriptCopyPayload.code(in: source, blockPath: [0, 0, 1, 0]))
        XCTAssertNil(TranscriptCopyPayload.code(in: source, blockPath: [0, 4, 1, 0]))
        XCTAssertEqual(TranscriptMarkdownDocument("> 1. First\n>\n> 2. Second").block(at: [0, 0]),
                       .orderedList(start: 1, items: ["First", "Second"], isLoose: true))
        XCTAssertEqual(TranscriptCopyPayload.code(
            in: "Before\u{2028}separator\r\n\r\n```text\r\none\r\ntwo\n```", blockIndex: 1), "one\r\ntwo")
    }

    func testTableEscapesAlignmentAndColumnCountFollowSourceStructure() throws {
        let source = "| Name | Count | State |\n| :--- | ---: | :---: |\n| left\\|right | 12 | `a\\|b` | ignored |\n| short | 3 |"
        guard case let .table(headers, rows, alignments) = try XCTUnwrap(TranscriptMarkdownDocument(source).blocks.first) else {
            return XCTFail("Expected a table")
        }
        XCTAssertEqual(headers, ["Name", "Count", "State"])
        XCTAssertEqual(rows, [["left|right", "12", "`a|b`"], ["short", "3", ""]])
        XCTAssertEqual(alignments, [.leading, .trailing, .center])
    }

    func testTableDoesNotConsumeFollowingHeadingListOrFencedCode() {
        let document = TranscriptMarkdownDocument("| A | B |\n| --- | --- |\n| 1 | 2 |\n## Heading | still a heading\n\n- Next | item\n\n```text\na | b\n```")
        XCTAssertEqual(document.blocks, [
            .table(headers: ["A", "B"], rows: [["1", "2"]], alignments: [.leading, .leading]),
            .heading(level: 2, text: "Heading | still a heading"),
            .unorderedList(["Next | item"]),
            .code(language: "text", text: "a | b")
        ])
    }

    func testNestedCodeCopyResolvesFullPayloadAfterRenderWindowEndsInsideFence() {
        let code = String(repeating: "  print(\"한글 👩🏽‍💻\")\r\n", count: 300) + "  // FULL-END\r\n"
        let source = "- Parent\r\n\r\n  ```swift\r\n" + code + "  ```\r\n\nAfter"
        let visible = TranscriptRenderWindow(text: source, characterLimit: 100)
        guard case .code = TranscriptMarkdownDocument(visible.text).block(at: [0, 0, 1]) else {
            return XCTFail("The visible nested fence must retain its path")
        }
        XCTAssertEqual(TranscriptCopyPayload.code(in: source, blockPath: [0, 0, 1]),
                       String(repeating: "print(\"한글 👩🏽‍💻\")\r\n", count: 300) + "// FULL-END")
    }

    /// A Mermaid block is a diagram once its closing fence has come, at the top or in a list or a quote; one still
    /// streaming, closed only by a fence shorter than its opening one, or empty, is code.
    func testAMermaidBlockIsADiagramOnceItsFenceCloses() {
        let flow = "flowchart LR\n  A --> B"
        XCTAssertEqual(TranscriptMarkdownDocument("Before\n\n```mermaid\n\(flow)\n```\n\nAfter").blocks,
                       [.paragraph("Before"), .mermaid(flow), .paragraph("After")])
        XCTAssertEqual(TranscriptMarkdownDocument("~~~ Mermaid\n\(flow)\n~~~~").blocks, [.mermaid(flow)])
        XCTAssertEqual(TranscriptMarkdownDocument("```mermaid\n\(flow)").blocks, [.code(language: "mermaid", text: flow)])
        XCTAssertEqual(TranscriptMarkdownDocument("````mermaid\n\(flow)\n```").blocks,
                       [.code(language: "mermaid", text: flow + "\n```")])
        XCTAssertEqual(TranscriptMarkdownDocument("```mermaid\n```").blocks, [.code(language: "mermaid", text: "")])
        let listed = "- Steps:\n\n  ```mermaid\n  \(flow.replacingOccurrences(of: "\n", with: "\n  "))\n  ```"
        XCTAssertEqual(TranscriptMarkdownDocument(listed).block(at: [0, 0, 1]), .mermaid(flow))
        XCTAssertEqual(TranscriptCopyPayload.code(in: listed, blockPath: [0, 0, 1]), flow)
        XCTAssertEqual(TranscriptMarkdownDocument("> ```mermaid\n> \(flow.replacingOccurrences(of: "\n", with: "\n> "))\n> ```")
            .block(at: [0, 0]), .mermaid(flow))
    }

    func testDeepContainersRemainBoundedAndKeepTheirContentVisible() {
        let source = String(repeating: "> ", count: 48) + "DEEP-END"
        let document = TranscriptMarkdownDocument(source)
        guard case let .paragraph(fallback) = document.block(at: Array(repeating: 0, count: 25)) else {
            return XCTFail("Deep content should fall back to visible source")
        }
        XCTAssertTrue(fallback.plainText.hasSuffix("DEEP-END"))
    }

    /// A paragraph's pictures stand where they are written, between its words; pictures with only white space
    /// between them are one block, a link around a picture alone keeps it a picture, and the same holds in a list.
    func testPicturesSplitTheirParagraphWhereTheyStand() {
        let document = TranscriptMarkdownDocument("""
            Before: ![chart](docs/a.png "Latency") after **it**.

            ![one](1.png)
            ![two](2.png) [![badge](b.svg)](https://example.com)

            - item ![shot](~/s.png)

            Empty ![nothing]() stays words.
            """)

        XCTAssertEqual(document.blocks, [
            .paragraph("Before:"),
            .pictures([TranscriptMarkdownPicture(source: "docs/a.png", alt: "chart", title: "Latency")]),
            .paragraph("after **it**."),
            .pictures([TranscriptMarkdownPicture(source: "1.png", alt: "one"), TranscriptMarkdownPicture(source: "2.png", alt: "two"),
                       TranscriptMarkdownPicture(source: "b.svg", alt: "badge", link: "https://example.com")]),
            .unorderedList([TranscriptMarkdownListItem(blocks: [
                .paragraph("item"), .pictures([TranscriptMarkdownPicture(source: "~/s.png", alt: "shot")])
            ])]),
            .paragraph("Empty nothing stays words.")
        ])
    }
}
