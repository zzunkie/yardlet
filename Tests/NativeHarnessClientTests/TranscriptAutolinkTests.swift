import XCTest
@testable import NativeHarnessClient

/// GFM's extended autolinks, as the Codex app reads them (`gfmAutolinkLiteral`): a bare address in a
/// message is a link, its trailing punctuation is not, and code and existing links stay as they are.
final class TranscriptAutolinkTests: XCTestCase {
    private func links(_ markdown: String) -> [(text: String, url: String)] {
        let content = TranscriptInlineContent(stringLiteral: markdown)
        return content.attributed.runs.compactMap { run in
            run.link.map { (String(content.attributed[run.range].characters), $0.absoluteString) }
        }
    }

    func testABareAddressOnItsOwnLineAndInASentenceIsALink() {
        XCTAssertEqual(links("https://claude.ai/artifact/UxpAUa6dQghc2QHX29KqZR").map(\.url),
                       ["https://claude.ai/artifact/UxpAUa6dQghc2QHX29KqZR"])
        let sentence = links("시안은 https://claude.ai/artifact/abc 에 있습니다.")
        XCTAssertEqual(sentence.map(\.text), ["https://claude.ai/artifact/abc"])
    }

    func testTrailingPunctuationAndAnUnmatchedParenthesisStayOutside() {
        XCTAssertEqual(links("See https://example.com/a.").map(\.text), ["https://example.com/a"])
        XCTAssertEqual(links("(see https://example.com/a)").map(\.text), ["https://example.com/a"])
        XCTAssertEqual(links("https://en.wikipedia.org/wiki/Swift_(language)").map(\.text),
                       ["https://en.wikipedia.org/wiki/Swift_(language)"])
        XCTAssertEqual(links("Is it https://example.com/q?").map(\.text), ["https://example.com/q"])
    }

    /// Korean puts no space after an address: a `)` closing a `(` written before it, a parenthesis right
    /// after the domain and CJK punctuation are the sentence's, as a space would be.
    func testAnAddressEndsWhereTheSentenceAroundItGoesOn() {
        XCTAssertEqual(links("PR #403(https://github.com/owner/repo/pull/403)을 열었습니다.").map(\.url),
                       ["https://github.com/owner/repo/pull/403"])
        XCTAssertEqual(links("미리보기(http://127.0.0.1:5188/)는 켜 두었습니다.").map(\.text), ["http://127.0.0.1:5188/"])
        XCTAssertEqual(links("임대(2026-09-01, https://example.com/news/1088003)가 없습니다.").map(\.text),
                       ["https://example.com/news/1088003"])
        XCTAssertEqual(links("(https://en.wikipedia.org/wiki/Swift_(language))를 보세요").map(\.text),
                       ["https://en.wikipedia.org/wiki/Swift_(language)"])
        XCTAssertEqual(links("[위키](https://en.wikipedia.org/wiki/Swift_(language))를 보세요").map(\.url),
                       ["https://en.wikipedia.org/wiki/Swift_(language)"])
        XCTAssertEqual(links("주소: https://example.com(고객 전용)").map(\.text), ["https://example.com"])
        XCTAssertEqual(links("URL（https://example.com/reel/abc）をコピーします。").map(\.text), ["https://example.com/reel/abc"])
        XCTAssertEqual(links("地圖：https://example.com/5iTRY8MW）。").map(\.text), ["https://example.com/5iTRY8MW"])
        // With no `(` before it, GFM's own example keeps the `)` inside.
        XCTAssertEqual(links("www.google.com/search?q=(business))+ok").map(\.text), ["www.google.com/search?q=(business))+ok"])
    }

    func testWWWLocalhostAndEmail() {
        XCTAssertEqual(links("www.commonmark.org/help").map(\.url), ["http://www.commonmark.org/help"])
        XCTAssertEqual(links("open http://localhost:5173/admin/chat-history now").map(\.text),
                       ["http://localhost:5173/admin/chat-history"])
        XCTAssertEqual(links("mail developer@example.com.").map(\.url), ["mailto:developer@example.com"])
    }

    func testAnAddressCmarkSplitsAtUnderscoresIsOneLink() {
        XCTAssertEqual(links("https://example.com/a_b_c/d*e").map(\.text), ["https://example.com/a_b_c/d*e"])
    }

    func testCodeExistingLinksAndWordsGluedBeforeStayAsTheyAre() {
        XCTAssertTrue(links("`https://example.com/in-code`").isEmpty)
        XCTAssertEqual(links("[docs](https://example.com/docs) and https://example.com/bare").map(\.url),
                       ["https://example.com/docs", "https://example.com/bare"])
        XCTAssertEqual(links("[docs](https://example.com/docs)").map(\.text), ["docs"])
        XCTAssertTrue(links("abchttps://example.com").isEmpty)
        XCTAssertTrue(links("not.a.link and www.x").isEmpty)
    }

    func testABoldAddressKeepsItsWeightAndLinks() {
        let content = TranscriptInlineContent(stringLiteral: "**https://example.com/bold**")
        let run = try? XCTUnwrap(content.attributed.runs.first)
        XCTAssertEqual(run?.link?.absoluteString, "https://example.com/bold")
        XCTAssertEqual(run?.inlinePresentationIntent, .stronglyEmphasized)
    }

    func testANonASCIIPathIsEscapedForTheLink() {
        let found = links("https://example.com/문서/한글")
        XCTAssertEqual(found.map(\.text), ["https://example.com/문서/한글"])
        XCTAssertEqual(found.first?.url, "https://example.com/%EB%AC%B8%EC%84%9C/%ED%95%9C%EA%B8%80")
        XCTAssertEqual(links("출처: https://example.com/법령/도로교통법/제96조 , https://example.com/case/대법원/2011다18802").map(\.text),
                       ["https://example.com/법령/도로교통법/제96조", "https://example.com/case/대법원/2011다18802"])
    }
}
