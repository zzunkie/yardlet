import Foundation
import YardletRemote

/// The JSON a `mail` call carries each way (docs/REMOTE_PROTOCOL.md §15.38), in the mailbox's own shapes, which both Macs
/// build from the same code. A draft's files travel as uploads (§15.20), never as paths.
enum RemoteMailWire {
    /// `accounts`: the host's mail accounts.
    struct Accounts: Codable, Equatable {
        var accounts: [MailAccount]
    }

    /// What is being written, as `saveDraft` takes it: a `MailComposition` without its files, which come as uploads.
    struct Composition: Codable, Equatable {
        var kind: MailComposition.Kind
        var threadID: String?
        var draftID: String?
        var to: String
        var cc: String
        var bcc: String
        var subject: String
        var body: String
        var replyToMessageID: String?
        var inReplyTo: String?
        var references: String?
        var forwardedMessageID: String?
        var keepsDraftFiles: Bool

        init(_ composition: MailComposition) {
            kind = composition.kind
            threadID = composition.threadID
            draftID = composition.draftID
            to = composition.to
            cc = composition.cc
            bcc = composition.bcc
            subject = composition.subject
            body = composition.body
            replyToMessageID = composition.replyToMessageID
            inReplyTo = composition.inReplyTo
            references = composition.references
            forwardedMessageID = composition.forwardedMessageID
            keepsDraftFiles = composition.keepsDraftFiles
        }

        /// The composition on the host, its files the uploads it came with.
        func composition(accountID: UUID, files: [URL]) -> MailComposition {
            var composition = MailComposition(accountID: accountID, kind: kind, threadID: threadID, draftID: draftID, to: to,
                                              cc: cc, bcc: bcc, subject: subject, body: body, inReplyTo: inReplyTo,
                                              references: references, attachments: files,
                                              forwardedMessageID: forwardedMessageID)
            composition.replyToMessageID = replyToMessageID
            composition.keepsDraftFiles = keepsDraftFiles
            return composition
        }
    }

    /// The arguments of every call but `accounts`.
    struct Call: Codable, Equatable {
        var accountID: UUID
        var pageToken: String? = nil
        var folder: MailFolder? = nil
        var query: String? = nil
        var threadID: String? = nil
        var change: MailThreadChange? = nil
        var draftID: String? = nil
        var messageID: String? = nil
        var cursor: String? = nil
        var composition: Composition? = nil
    }

    /// The answer of `saveDraft`, `draftID` and `changeCursor`.
    struct Value: Codable, Equatable {
        var value: String
    }

    static func encode<Value: Encodable>(_ value: Value) -> Data { RemoteCalendarWire.encode(value) }

    static func decode<Value: Decodable>(_ type: Value.Type, _ data: Data?) throws -> Value {
        try RemoteCalendarWire.decode(type, data)
    }
}
