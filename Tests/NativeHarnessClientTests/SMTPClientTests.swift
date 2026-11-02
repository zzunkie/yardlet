import Foundation
import XCTest
@testable import NativeHarnessClient

/// The SMTP client against submissions as servers answer them: STARTTLS before signing in, AUTH PLAIN,
/// the envelope, a message whose lines starting with a dot are doubled, a check that signs in and sends
/// nothing, and a sign-in refused with 535.
final class SMTPClientTests: XCTestCase {
    func testSubmissionStartsTLSSignsInAndStuffsDotsAsAServerExpects() async throws {
        let socket = ScriptedMailSocket(#"""
        S: 220 smtp.example.com ESMTP ready
        C: EHLO [127.0.0.1]
        S: 250-smtp.example.com
        S: 250-PIPELINING
        S: 250-SIZE 36700160
        S: 250-STARTTLS
        S: 250 8BITMIME
        C: STARTTLS
        S: 220 2.0.0 Ready to start TLS
        T: STARTTLS
        C: EHLO [127.0.0.1]
        S: 250-smtp.example.com
        S: 250-SIZE 36700160
        S: 250-AUTH PLAIN LOGIN
        S: 250 8BITMIME
        C: AUTH PLAIN AGRhbmFAZXhhbXBsZS5jb20AY29ycmVjdCBob3JzZQ==
        S: 235 2.7.0 Authentication successful
        C: MAIL FROM:<dana@example.com>
        S: 250 2.1.0 Ok
        C: RCPT TO:<haneul@example.com>
        S: 250 2.1.5 Ok
        C: RCPT TO:<min@example.com>
        S: 250 2.1.5 Ok
        C: DATA
        S: 354 End data with <CR><LF>.<CR><LF>
        C: From: Dana <dana@example.com>
        C: To: Haneul <haneul@example.com>
        C: Subject: Notes
        C:
        C: Line one
        C: ..
        C: ..dot first
        C: Last line
        C: .
        S: 250 2.0.0 Ok: queued as 4FQ2x
        C: QUIT
        S: 221 2.0.0 Bye
        """#, chunkSize: 1)
        let opener = ScriptedMailOpener(socket)
        let client = SMTPClient(opener: opener, host: "smtp.example.com", port: 587, security: .startTLS,
                                username: "dana@example.com", password: "correct horse")

        let message = "From: Dana <dana@example.com>\nTo: Haneul <haneul@example.com>\nSubject: Notes\n\nLine one\n.\n.dot first\nLast line"
        try await client.send(message: Data(message.utf8), from: "dana@example.com",
                              recipients: ["haneul@example.com", "min@example.com"])

        XCTAssertEqual(opener.opened, ["smtp.example.com:587 plain"])
        XCTAssertEqual(socket.failures, [])
        XCTAssertTrue(socket.isFinished)
        XCTAssertTrue(socket.isClosed)
    }

    func testCheckSignsInAndQuitsWithoutSendingAnything() async throws {
        let socket = ScriptedMailSocket(#"""
        S: 220 smtp.example.com ESMTP ready
        C: EHLO [127.0.0.1]
        S: 250-smtp.example.com
        S: 250 AUTH=PLAIN LOGIN
        C: AUTH PLAIN AGRhbmFAZXhhbXBsZS5jb20AY29ycmVjdCBob3JzZQ==
        S: 235 2.7.0 Authentication successful
        C: QUIT
        S: 221 2.0.0 Bye
        """#)
        let client = SMTPClient(opener: ScriptedMailOpener(socket), host: "smtp.example.com", port: 465,
                                security: .tls, username: "dana@example.com", password: "correct horse")
        try await client.check()
        XCTAssertEqual(socket.failures, [])
        XCTAssertTrue(socket.isFinished)
        XCTAssertTrue(socket.isClosed)
    }

    func testRefusedSignInIsItsOwnFailureAndNoMessageFollows() async throws {
        let socket = ScriptedMailSocket(#"""
        S: 220 smtp.example.com ESMTP ready
        C: EHLO [127.0.0.1]
        S: 250-smtp.example.com
        S: 250 AUTH LOGIN
        C: AUTH LOGIN
        S: 334 VXNlcm5hbWU6
        C: ZGFuYUBleGFtcGxlLmNvbQ==
        S: 334 UGFzc3dvcmQ6
        C: d3JvbmcgaG9yc2U=
        S: 535 5.7.8 Error: authentication failed: d3JvbmcgaG9yc2U=
        C: QUIT
        S: 221 2.0.0 Bye
        """#)
        let opener = ScriptedMailOpener(socket)
        let client = SMTPClient(opener: opener, host: "smtp.example.com", port: 465, security: .tls,
                                username: "dana@example.com", password: "wrong horse")

        do {
            try await client.send(message: Data("Subject: Hi\r\n\r\nHi\r\n".utf8), from: "dana@example.com",
                                  recipients: ["haneul@example.com"])
            XCTFail("A refused sign-in sends nothing")
        } catch {
            XCTAssertEqual(error as? SMTPFailure,
                           .signInRefused(code: 535, text: "5.7.8 Error: authentication failed: ••••"),
                           "The server's words, without the password it repeated")
        }
        XCTAssertEqual(opener.opened, ["smtp.example.com:465 tls"])
        XCTAssertEqual(socket.failures, [])
        XCTAssertTrue(socket.isFinished)

        do {
            try await client.send(message: Data(), from: "dana@example.com",
                                  recipients: ["haneul@example.com>\r\nRCPT TO:<eve@example.com"])
            XCTFail("An address that would end the command line is refused")
        } catch {
            XCTAssertEqual(error as? SMTPFailure, .invalidAddress("haneul@example.com>\r\nRCPT TO:<eve@example.com"))
        }
        XCTAssertEqual(opener.opened.count, 1, "Refused before connecting")
    }
}
