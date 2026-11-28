import XCTest
@testable import NativeHarnessClient

final class MailServerPresetTests: XCTestCase {
    func testGmailAppPasswordSetup() throws {
        for domain in ["gmail.com", "GoogleMail.com"] {
            let address = "user@\(domain)"
            let gmail = try XCTUnwrap(MailServerPreset.matching(address))
            XCTAssertEqual(gmail.id, "gmail")
            XCTAssertEqual(gmail.imap, .init(host: "imap.gmail.com", port: 993, security: .tls))
            XCTAssertEqual(gmail.smtp, .init(host: "smtp.gmail.com", port: 465, security: .tls))
            XCTAssertEqual(gmail.settings(for: address).imapUsername, address)
            XCTAssertNil(MailServerPreset.connectorService(for: address))
            let groups = (0..<4).map { _ in String(UUID().uuidString.prefix(4)) }
            XCTAssertEqual(gmail.normalizedPassword(groups.joined(separator: " ")), groups.joined())
        }
        XCTAssertEqual(MailServerPreset.connectorService(for: "user@outlook.com"), .outlookMail)
        XCTAssertEqual(MailServerPreset.preset(id: "icloud")?.normalizedPassword("a b"), "a b")
    }
}
