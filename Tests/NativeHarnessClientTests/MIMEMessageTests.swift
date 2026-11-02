import Foundation
import XCTest
@testable import NativeHarnessClient

/// Mail read over IMAP arrives as raw RFC 5322 messages, in the charsets and encodings each service and
/// mailer writes; the mailbox reads its subject, body, attachments and list snippet from them.
final class MIMEMessageTests: XCTestCase {
    /// A Korean webmail message: the subject in `ks_c_5601-1987` encoded words split in the middle of a
    /// character, and an `euc-kr` quoted-printable body with a character only code page 949 has.
    func testKoreanMessageReadsInCodePage949() {
        let message = MIMEMessage.parse(crlf("""
        Return-Path: <sales@example.co.kr>
        Received: from mail.example.co.kr (mail.example.co.kr [192.0.2.10])
        \tby mx.example.com; Mon, 2 Nov 2026 09:30:00 +0900
        Date: Mon, 2 Nov 2026 09:30:00 +0900
        From: =?ks_c_5601-1987?B?sN/A+8bA?= <sales@example.co.kr>
        To: buyer@example.com
        Subject: =?ks_c_5601-1987?B?sN/A+7w=?=
         =?ks_c_5601-1987?B?rSC6uLO7teW4s7TPtNk=?=
        MIME-Version: 1.0
        Content-Type: text/plain;
        \tcharset="euc-kr"
        Content-Transfer-Encoding: quoted-printable

        =BE=C8=B3=E7=C7=CF=BC=BC=BF=E4.
        =bf=e4=c3=bb=c7=cf=bd=c5 =b0=df=c0=fb=bc=ad=b8=a6 =ba=b8=b3=bb=b5=e5=b8=
        =b3=B4=CF=B4=D9.
        =C1=A1=BD=C9=C0=BA =8Cc=BE=E7=B2=E1 =BE=EE=B6=B0=BC=BC=BF=E4?
        """))

        XCTAssertEqual(message.header("content-type"), "text/plain;\tcharset=\"euc-kr\"")
        XCTAssertEqual(message.header("Received"),
                       "from mail.example.co.kr (mail.example.co.kr [192.0.2.10])\tby mx.example.com; Mon, 2 Nov 2026 09:30:00 +0900")
        XCTAssertEqual(MIMEWords.decode(message.header("Subject") ?? ""), "견적서 보내드립니다")
        XCTAssertEqual(MIMEWords.decode(message.header("From") ?? ""), "견적팀 <sales@example.co.kr>")
        XCTAssertEqual(message.parameters["charset"], "euc-kr")
        XCTAssertEqual(message.bodyText, "안녕하세요.\n요청하신 견적서를 보내드립니다.\n점심은 똠양꿍 어떠세요?")
        XCTAssertTrue(message.attachments.isEmpty)
    }

    func testEncodedWordsAsMailersWriteThem() {
        XCTAssertEqual(MIMEWords.decode("=?UTF-8?Q?Caf=c3=a9_menu?="), "Café menu")
        XCTAssertEqual(MIMEWords.decode("Re: [notice] =?UTF-8?B?7ZWc6riA?= update"), "Re: [notice] 한글 update")
        XCTAssertEqual(MIMEWords.decode("=?utf-8?b?7ZU=?= =?UTF-8?B?nOq4gA==?="), "한글", "A character split between two words")
        XCTAssertEqual(MIMEWords.decode("=?ks_c_5601-1987?Q?=C1=A6=C7=B0_list?="), "제품 list")
        XCTAssertEqual(MIMEWords.decode("=?x-windows-949?B?wabHsA==?="), "제품")
        XCTAssertEqual(MIMEWords.decode("=?ISO-2022-JP?B?GyRCJDMkcyRLJEEkTxsoQg==?="), "こんにちは")
        XCTAssertEqual(MIMEWords.decode("=?shift_jis?B?gqKC64LNh0A=?="), "いろは①")
        XCTAssertEqual(MIMEWords.decode("=?gb2312?B?xOO6ww==?="), "你好")
        XCTAssertEqual(MIMEWords.decode("=?windows-1252?Q?=93quoted=94?= =?iso-8859-1?Q?caf=E9?="), "“quoted”café")
        let malformed = "=?x-unknown?B?AAAA?= and =?UTF-8?B?/w==?="
        XCTAssertEqual(MIMEWords.decode(malformed), malformed)
    }

    /// LF line endings, as some servers and saved files have them.
    func testAlternativeReadsBothBodiesWithLFLineEndings() {
        let message = MIMEMessage.parse(Data("""
        From: Example Shop <news@example.com>
        To: buyer@example.com
        Subject: =?UTF-8?Q?Your_order_is_on_its_way_=E2=80=94_#1024?=
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="=_alt_7f3a"

        This is a multi-part message in MIME format.

        --=_alt_7f3a
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64

        7KO866y47ZWY7IugIOyDge2SiOydtCDstpzrsJztlojsirXri4jri6QuCuuwsOyGoSDsobDtmow6
        IGh0dHBzOi8vZXhhbXBsZS5jb20vdHJhY2svMTAyNAo
        --=_alt_7f3a
        Content-Type: text/html; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable

        <html><body><p>=EC=A3=BC=EB=AC=B8=ED=95=98=EC=8B=A0 =EC=83=81=ED=92=88=EC=
        =9D=B4 <b>=EC=B6=9C=EB=B0=9C</b>=ED=96=88=EC=8A=B5=EB=8B=88=EB=8B=A4.</p></=
        body></html>
        --=_alt_7f3a--
        """.utf8))

        XCTAssertEqual(MIMEWords.decode(message.header("Subject") ?? ""), "Your order is on its way — #1024")
        XCTAssertEqual(message.contentType, "multipart/alternative")
        XCTAssertEqual(message.children.map(\.contentType), ["text/plain", "text/html"])
        XCTAssertEqual(message.plainText, "주문하신 상품이 출발했습니다.\n배송 조회: https://example.com/track/1024\n")
        XCTAssertEqual(message.html, "<html><body><p>주문하신 상품이 <b>출발</b>했습니다.</p></body></html>")
        XCTAssertEqual(message.bodyText, message.plainText)
        XCTAssertTrue(message.attachments.isEmpty)
    }

    /// File names as mailers write them: RFC 2231 in UTF-8, RFC 2231 continuations in a Korean charset,
    /// and RFC 2047 words in a quoted `name`; an inline image with a name is an attachment too.
    func testAttachmentsKeepTheirNamesAndBytes() {
        let message = MIMEMessage.parse(crlf("""
        From: Example Sales <sales@example.co.kr>
        To: buyer@example.com
        Subject: Quote
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="mixed-01"

        --mixed-01
        Content-Type: multipart/related; boundary="related-01"; type="text/html"

        --related-01
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: 7bit

        <p>Quote attached.</p><img src="cid:logo@example.com">
        --related-01
        Content-Type: image/png; name="logo.png"
        Content-Disposition: inline; filename="logo.png"
        Content-ID: <logo@example.com>
        Content-Transfer-Encoding: base64

        iVBORw0KGgo=
        --related-01--

        --mixed-01
        Content-Type: application/pdf; name="quote.pdf"
        Content-Disposition: attachment;
         filename*=UTF-8''%EA%B2%AC%EC%A0%81%EC%84%9C.pdf
        Content-Transfer-Encoding: base64

        JVBERi0xLjQKJeLjz9MKMSAwIG9iago8PD4+
        CmVuZG9iagolJUVPRgo
        --mixed-01
        Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document;
         name="=?UTF-8?B?7ZWc6riAIOusuOyEnC5kb2N4?="
        Content-Disposition: attachment
        Content-Transfer-Encoding: base64

        UEsDBBQAAAAIAA==
        --mixed-01
        Content-Type: text/csv; charset=euc-kr
        Content-Disposition: attachment;
         filename*0*=ks_c_5601-1987''%C1%A6%C7%B0; filename*1=" list.csv"

        item,qty
        --mixed-01--
        """))

        XCTAssertNil(message.plainText, "An attached text file is not the body")
        XCTAssertEqual(message.bodyText, "Quote attached.")
        let attachments = message.attachments
        XCTAssertEqual(attachments.map(\.filename), ["logo.png", "견적서.pdf", "한글 문서.docx", "제품 list.csv"])
        XCTAssertEqual(attachments.map(\.contentType), [
            "image/png", "application/pdf", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "text/csv",
        ])
        XCTAssertEqual(attachments[0].disposition, "inline")
        XCTAssertEqual(attachments[0].header("Content-ID"), "<logo@example.com>")
        XCTAssertEqual(attachments[0].body, Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertEqual(attachments[1].body, Data("%PDF-1.4\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3])
            + Data("\n1 0 obj\n<<>>\nendobj\n%%EOF\n".utf8))
        XCTAssertEqual(attachments[3].text, "item,qty")
    }

    /// A message forwarded as `message/rfc822` is one child holding the whole message, and one attachment.
    func testForwardedMessageIsOneChild() throws {
        let message = MIMEMessage.parse(crlf("""
        From: Support <support@example.com>
        To: team@example.com
        Subject: Fwd: =?UTF-8?B?7ZmY67aIIOusuOydmA==?=
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="fwd-boundary"

        --fwd-boundary
        Content-Type: text/plain; charset=utf-8

        See the customer's message below.
        --fwd-boundary
        Content-Type: message/rfc822

        From: Customer <customer@example.org>
        To: support@example.com
        Subject: =?UTF-8?B?7ZmY67aIIOusuOydmA==?=
        MIME-Version: 1.0
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        <p>Order #1024 arrived damaged.<br>Could you refund it?</p>
        --fwd-boundary--
        """))

        XCTAssertEqual(message.plainText, "See the customer's message below.")
        XCTAssertEqual(message.attachments.map(\.contentType), ["message/rfc822"])
        let forwarded = message.children[1]
        let inner = try XCTUnwrap(forwarded.children.first)
        XCTAssertEqual(forwarded.children.count, 1)
        XCTAssertEqual(MIMEWords.decode(inner.header("Subject") ?? ""), "환불 문의")
        XCTAssertEqual(inner.bodyText, "Order #1024 arrived damaged.\nCould you refund it?")
        XCTAssertEqual(forwarded.bodyText, inner.bodyText)
        XCTAssertEqual(MIMEMessage.parse(forwarded.body).header("From"), "Customer <customer@example.org>")
    }

    /// The first 2048 bytes a list fetches stop anywhere: inside base64, inside a character, inside a tag
    /// or a style block.
    func testSnippetFromPartialBodies() throws {
        let text = crlf("""
        This is a multi-part message in MIME format.

        --snippet-b
        Content-Type: text/plain; charset="UTF-8"
        Content-Transfer-Encoding: base64

        7JWI64WV7ZWY7IS47JqULAoK7J2067KIIOyjvCDtmozsnZgg7J6Q66OM66W8IOqzteycoOuTnOumveuLiOuLpC4K7ZmV7J24IOu2gO2DgeuTnOumveuLiOuLpC4K
        --snippet-b
        Content-Type: text/html; charset="UTF-8"
        """)
        // Cut 46 characters into the base64: inside the third byte group of "의".
        let base64 = try XCTUnwrap(text.range(of: Data("7JWI".utf8)))
        let cut = text[..<(base64.lowerBound + 46)]
        XCTAssertEqual(MIMESnippet.text(fromPartial: cut, transferEncoding: "7bit", charset: nil,
                                        contentType: "multipart/alternative", boundary: "snippet-b"),
                       "안녕하세요, 이번 주 회")

        let html = Data(#"<html><head><style>p { color: red; }</style></head><body><p>Hello&nbsp;there&zwnj;</p>\#r\#n<p>Second line <a href="https://exa"#.utf8)
        XCTAssertEqual(MIMESnippet.text(fromPartial: html, transferEncoding: nil, charset: "utf-8",
                                        contentType: "text/html", boundary: nil), "Hello there Second line")
        let style = Data("<html><head><style>body { font-family: sans-serif; }".utf8)
        XCTAssertEqual(MIMESnippet.text(fromPartial: style, transferEncoding: nil, charset: nil,
                                        contentType: "text/html", boundary: nil), "")

        let long = Data(String(repeating: "Weekly report line=20\r\n", count: 40).utf8)
        let snippet = MIMESnippet.text(fromPartial: long, transferEncoding: "quoted-printable", charset: "us-ascii",
                                       contentType: "text/plain", boundary: nil)
        XCTAssertEqual(snippet.count, 200)
        XCTAssertTrue(snippet.hasPrefix("Weekly report line Weekly report line "))
    }

    private func crlf(_ text: String) -> Data {
        Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }
}
