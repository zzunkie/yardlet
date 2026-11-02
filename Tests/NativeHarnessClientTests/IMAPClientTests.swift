import Foundation
import XCTest
@testable import NativeHarnessClient

/// The IMAP client against exchanges as servers send them: a greeting with capabilities, AUTHENTICATE
/// PLAIN through a continuation, folders with special-use attributes and Korean names in modified UTF-7,
/// a message's envelope and MIME structure, a body part as a literal among other untagged responses, a
/// search in Korean, APPEND through a continuation, MOVE done by hand where the server lacks it, and
/// CREATE of a folder that is already there.
final class IMAPClientTests: XCTestCase {
    func testSessionReadsFoldersAndMessagesAndFilesAReplyAsAServerSendsThem() async throws {
        try await runSession(chunkSize: nil)
    }

    func testSessionReadsTheSameWhenTheServerArrivesOneByteAtATime() async throws {
        try await runSession(chunkSize: 1)
    }

    func testRefusedLoginAfterSTARTTLSCarriesTheServersWordsAndClosesTheConnection() async throws {
        let socket = ScriptedMailSocket(#"""
        S: * OK IMAP server ready
        C: A1 CAPABILITY
        S: * CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED
        S: A1 OK Capability completed
        C: A2 STARTTLS
        S: A2 OK Begin TLS negotiation now
        T: STARTTLS
        C: A3 CAPABILITY
        S: * CAPABILITY IMAP4rev1 IDLE
        S: A3 OK Capability completed
        C: A4 LOGIN "dana@example.com" "pa\"ss\\word"
        S: A4 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)
        """#)
        let opener = ScriptedMailOpener(socket)
        let client = IMAPClient(opener: opener, host: "imap.example.com", port: 143, security: .startTLS,
                                username: "dana@example.com", password: #"pa"ss\word"#)
        do {
            try await client.connect()
            XCTFail("A refused LOGIN does not connect")
        } catch {
            XCTAssertEqual(error as? IMAPFailure, .signInRefused("[AUTHENTICATIONFAILED] Invalid credentials (Failure)"))
        }
        XCTAssertEqual(opener.opened, ["imap.example.com:143 plain"])
        XCTAssertEqual(socket.failures, [])
        XCTAssertTrue(socket.isFinished)
        XCTAssertTrue(socket.isClosed)
    }

    func testCreatingAFolderThatAlreadyExistsIsNoFailure() async throws {
        let socket = ScriptedMailSocket(#"""
        S: * OK [CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN] IMAP server ready
        C: A1 AUTHENTICATE PLAIN AGRhbmFAZXhhbXBsZS5jb20AY29ycmVjdCBob3JzZQ==
        S: A1 OK [CAPABILITY IMAP4rev1 UIDPLUS] Authenticated
        C: A2 CREATE "Archive"
        S: A2 NO [ALREADYEXISTS] Mailbox already exists
        C: A3 CREATE "Archive/2026"
        S: A3 NO [OVERQUOTA] Too many folders
        """#)
        let client = IMAPClient(opener: ScriptedMailOpener(socket), host: "imap.example.com", port: 993,
                                security: .tls, username: "dana@example.com", password: "correct horse")
        try await client.connect()
        try await client.create("Archive")
        do {
            try await client.create("Archive/2026")
            XCTFail("Another refusal is a failure")
        } catch {
            XCTAssertEqual(error as? IMAPFailure, .refused("[OVERQUOTA] Too many folders"))
        }
        XCTAssertEqual(socket.failures, [])
        XCTAssertTrue(socket.isFinished)
    }

    private func runSession(chunkSize: Int?) async throws {
        let socket = ScriptedMailSocket(Self.session, chunkSize: chunkSize)
        let opener = ScriptedMailOpener(socket)
        let client = IMAPClient(opener: opener, host: "imap.example.com", port: 993, security: .tls,
                                username: "dana@example.com", password: "correct horse")

        try await client.connect()
        XCTAssertEqual(opener.opened, ["imap.example.com:993 tls"])
        let capabilities = await client.capabilities
        XCTAssertTrue(capabilities.isSuperset(of: ["SPECIAL-USE", "UIDPLUS"]), "Read again from the sign-in's answer")
        XCTAssertFalse(capabilities.contains("AUTH=PLAIN"))

        let folders = try await client.list()
        XCTAssertEqual(folders.map(\.name), ["INBOX", "보낸편지함", "Q&A", "Archive"])
        XCTAssertEqual(folders.map(\.rawName), ["INBOX", "&vPSwuNO4ycDVaA-", "Q&-A", "Archive"])
        XCTAssertEqual(folders[1].attributes, [#"\hasnochildren"#, #"\sent"#])
        XCTAssertEqual(folders[1].delimiter, "/")
        XCTAssertEqual(IMAPModifiedUTF7.encode("보낸편지함"), "&vPSwuNO4ycDVaA-")
        XCTAssertEqual(IMAPModifiedUTF7.encode("Q&A"), "Q&-A")

        let inbox = try await client.select("INBOX", readOnly: false)
        XCTAssertEqual(inbox, IMAPSelection(exists: 3, uidValidity: 1_730_000_000, uidNext: 104))

        let messages = try await client.fetch(uids: [103, 101], items: "UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE")
        XCTAssertEqual(messages.map(\.uid), [101, 103], "Another message's flag change is no result")
        let ci = messages[0]
        XCTAssertEqual(ci.flags, [#"\Seen"#])
        XCTAssertEqual(ci.internalDate, Date(timeIntervalSince1970: 1_793_556_134))
        XCTAssertEqual(ci.envelope?.subject, "CI is green")
        XCTAssertEqual(ci.envelope?.from, [IMAPAddress(name: "Build Bot", mailbox: "ci", host: "example.com")])
        XCTAssertEqual(ci.bodyStructure?.firstPart(type: "text", subtype: "plain")?.section, "1")
        XCTAssertEqual(ci.bodyStructure?.hasAttachments, false)

        let quote = messages[1]
        XCTAssertEqual(quote.sequence, 3)
        XCTAssertEqual(quote.flags, ["$Forwarded"])
        XCTAssertEqual(quote.size, 48213)
        XCTAssertEqual(quote.internalDate, Date(timeIntervalSince1970: 1_793_578_504), "09:15:04 at +0900")
        let envelope = try XCTUnwrap(quote.envelope)
        XCTAssertEqual(envelope.subject, "=?UTF-8?B?6rKs7KCB7IScIOuztOuCtOuTnOumveuLiOuLpA==?=", "Left raw, from a literal")
        XCTAssertEqual(envelope.from.first?.name, "=?UTF-8?B?6rmA7ZWY64qY?=")
        XCTAssertEqual(envelope.from.first?.address, "haneul@example.com")
        XCTAssertEqual(envelope.cc.map(\.address), ["team@example.com", "min@example.com"])
        XCTAssertEqual(envelope.inReplyTo, "<prev-1@example.com>")
        XCTAssertEqual(envelope.messageID, "<quote-2@example.com>")
        let structure = try XCTUnwrap(quote.bodyStructure)
        XCTAssertEqual(structure.subtype, "mixed")
        XCTAssertEqual(structure.parts.map(\.section), ["1", "2"])
        let plain = try XCTUnwrap(structure.firstPart(type: "text", subtype: "plain"))
        XCTAssertEqual(plain.section, "1.1")
        XCTAssertEqual(plain.encoding, "base64")
        XCTAssertEqual(plain.charset, "UTF-8")
        XCTAssertEqual(structure.firstPart(type: "text", subtype: "html")?.section, "1.2")
        XCTAssertEqual(structure.firstPart(type: "text", subtype: "html")?.encoding, "quoted-printable")
        XCTAssertTrue(structure.hasAttachments)
        XCTAssertEqual(structure.parts[1].filename, "quote-v3.pdf")
        XCTAssertEqual(structure.parts[1].disposition, "attachment")
        XCTAssertEqual(structure.parts[1].size, 45120)

        let body = try await client.fetch(uids: [101], items: "BODY.PEEK[1]<0.2048> BODY.PEEK[HEADER.FIELDS (REFERENCES)]")
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body.first?.sections["1"], Data("All checks passed.\r\nRun 4182 took 6 min.\r\n".utf8))
        XCTAssertEqual(body.first?.sections["HEADER.FIELDS (REFERENCES)"], Data("\r\n".utf8))
        let afterNewMail = await client.selection?.exists
        XCTAssertEqual(afterNewMail, 4, "EXISTS among the FETCH responses")

        let found = try await client.uidSearch("SUBJECT \(IMAPClient.quoted("견적"))")
        XCTAssertEqual(found, [103])

        let reply = "From: Dana <dana@example.com>\nTo: =?UTF-8?B?6rmA7ZWY64qY?= <haneul@example.com>\nSubject: Re: quote\n\nThanks, I'll reply by Thursday.\n"
        let filed = try await client.append("&vPSwuNO4ycDVaA-", message: Data(reply.utf8), flags: [#"\Seen"#],
                                            date: Date(timeIntervalSince1970: 1_793_579_400))
        XCTAssertEqual(filed, 12)

        try await client.uidMove([101], to: "Archive")
        let afterMove = await client.selection?.exists
        XCTAssertEqual(afterMove, 3)

        await client.logout()
        XCTAssertEqual(socket.failures, [])
        XCTAssertTrue(socket.isFinished)
        XCTAssertTrue(socket.isClosed)
    }

    private static let session = #"""
    S: * OK [CAPABILITY IMAP4rev1 ID AUTH=PLAIN] IMAP server ready
    C: A1 AUTHENTICATE PLAIN
    S: +
    C: AGRhbmFAZXhhbXBsZS5jb20AY29ycmVjdCBob3JzZQ==
    S: A1 OK [CAPABILITY IMAP4rev1 ID IDLE NAMESPACE SPECIAL-USE UIDPLUS] Authenticated
    C: A2 LIST "" "*" RETURN (SPECIAL-USE)
    S: * LIST (\HasNoChildren) "/" INBOX
    S: * LIST (\HasNoChildren \Sent) "/" "&vPSwuNO4ycDVaA-"
    S: * LIST (\HasNoChildren) "/" {4}
    S: Q&-A
    S: * LIST (\HasNoChildren \Archive) "/" Archive
    S: A2 OK List completed
    C: A3 SELECT "INBOX"
    S: * FLAGS (\Answered \Flagged \Deleted \Seen \Draft $Forwarded)
    S: * OK [PERMANENTFLAGS (\Answered \Flagged \Deleted \Seen \Draft $Forwarded \*)] Flags permitted
    S: * 3 EXISTS
    S: * 0 RECENT
    S: * OK [UIDVALIDITY 1730000000] UIDs valid
    S: * OK [UIDNEXT 104] Predicted next UID
    S: A3 OK [READ-WRITE] Select completed
    C: A4 UID FETCH 101,103 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE)
    S: * 1 FETCH (UID 101 FLAGS (\Seen) INTERNALDATE "01-Nov-2026 18:02:14 +0000" RFC822.SIZE 1204 ENVELOPE ("Sun, 1 Nov 2026 18:02:11 +0000" "CI is green" (("Build Bot" NIL "ci" "example.com")) (("Build Bot" NIL "ci" "example.com")) (("Build Bot" NIL "ci" "example.com")) ((NIL NIL "dana" "example.com")) NIL NIL NIL "<ci-4182@example.com>") BODYSTRUCTURE ("TEXT" "PLAIN" ("CHARSET" "utf-8") NIL NIL "7BIT" 42 2 NIL NIL NIL NIL))
    S: * 2 FETCH (FLAGS (\Seen \Flagged))
    S: * 3 FETCH (UID 103 FLAGS ($Forwarded) INTERNALDATE " 2-Nov-2026 09:15:04 +0900" RFC822.SIZE 48213 ENVELOPE ("Mon, 2 Nov 2026 09:15:01 +0900" {52}
    S: =?UTF-8?B?6rKs7KCB7IScIOuztOuCtOuTnOumveuLiOuLpA==?= (("=?UTF-8?B?6rmA7ZWY64qY?=" NIL "haneul" "example.com")) (("=?UTF-8?B?6rmA7ZWY64qY?=" NIL "haneul" "example.com")) (("=?UTF-8?B?6rmA7ZWY64qY?=" NIL "haneul" "example.com")) ((NIL NIL "dana" "example.com")) ((NIL NIL "team" "example.com")("Min Park" NIL "min" "example.com")) NIL "<prev-1@example.com>" "<quote-2@example.com>") BODYSTRUCTURE ((("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "BASE64" 284 4 NIL NIL NIL NIL)("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "QUOTED-PRINTABLE" 1022 21 NIL NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "alt-1") NIL NIL NIL)("APPLICATION" "PDF" ("NAME" "quote-v3.pdf") NIL NIL "BASE64" 45120 NIL ("ATTACHMENT" ("FILENAME" "quote-v3.pdf")) NIL NIL) "MIXED" ("BOUNDARY" "mix-1") NIL NIL NIL))
    S: A4 OK Fetch completed
    C: A5 UID FETCH 101 (BODY.PEEK[1]<0.2048> BODY.PEEK[HEADER.FIELDS (REFERENCES)])
    S: * 4 EXISTS
    S: * 1 FETCH (UID 101 BODY[1]<0> {42}
    S: All checks passed.
    S: Run 4182 took 6 min.
    S:  BODY[HEADER.FIELDS (REFERENCES)] {2}
    S:
    S: )
    S: A5 OK Fetch completed
    C: A6 UID SEARCH CHARSET UTF-8 SUBJECT {6}
    S: + Ready for literal data
    C: 견적
    S: * SEARCH 103
    S: A6 OK Search completed
    C: A7 APPEND "&vPSwuNO4ycDVaA-" (\Seen) "02-Nov-2026 00:30:00 +0000" {137}
    S: + Ready for literal data
    C: From: Dana <dana@example.com>
    C: To: =?UTF-8?B?6rmA7ZWY64qY?= <haneul@example.com>
    C: Subject: Re: quote
    C:
    C: Thanks, I'll reply by Thursday.
    C:
    S: A7 OK [APPENDUID 1730000002 12] Append completed
    C: A8 UID COPY 101 "Archive"
    S: A8 OK [COPYUID 1730000003 101 7] Copy completed
    C: A9 UID STORE 101 +FLAGS.SILENT (\Deleted)
    S: A9 OK Store completed
    C: A10 UID EXPUNGE 101
    S: * 1 EXPUNGE
    S: A10 OK Expunge completed
    C: A11 LOGOUT
    S: * BYE Logging out
    S: A11 OK Logout completed
    """#
}
