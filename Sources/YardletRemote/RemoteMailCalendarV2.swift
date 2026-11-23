import Foundation

/// Cross-platform JSON DTOs and bounds for `mailCalendarV2` (mobile and non-Mac remote clients).
///
/// Every timestamp is an explicit Unix epoch millisecond `Int64` (`...Ms`), all-day dates additionally carry
/// `"YYYY-MM-DD"` strings, and every enum uses explicit string raw values so Swift (iOS/macOS) and Kotlin (Android)
/// decode the exact same JSON without platform-specific `Date` epochs or synthesized associated-value wrappers.
public enum RemoteMailCalendarV2Limits {
    public static let defaultListLimit = 25
    public static let maxListLimit = 50
    public static let maxThreadMessages = 50
    public static let maxTextBodyCharacters = 32_000
    public static let maxHtmlBodyCharacters = 64_000
    public static let maxSnippetCharacters = 500
    public static let maxSubjectCharacters = 500
    public static let maxAttachments = 50
    public static let maxEvents = 200
    public static let maxEventNotesCharacters = 4_000
    public static let maxEventAttendees = 50
    public static let maxCalendarRangeMs: Int64 = 62 * 86_400 * 1_000
    public static let maxQueryCharacters = 500
    public static let maxSendBodyCharacters = 32_000
    public static let maxSendRecipients = 50
    public static let maxIdentifierBytes = 256
    public static let maxPageTokenBytes = 4_096
}

// MARK: - State Snapshot

/// Summary of Mail and Calendar availability and connected accounts on the host (`mailCalendarV2State`).
/// When `permitted` is false, `mailAccounts` and `calendarAccounts` are always empty.
public struct RemoteMailCalendarV2State: Codable, Equatable, Sendable {
    public var mailConnected: Bool
    public var calendarConnected: Bool
    public var mailEnabled: Bool
    public var calendarEnabled: Bool
    public var permitted: Bool
    public var mailAccounts: [RemoteMailV2Account]
    public var calendarAccounts: [RemoteCalendarV2Account]

    public init(
        mailConnected: Bool = false,
        calendarConnected: Bool = false,
        mailEnabled: Bool = false,
        calendarEnabled: Bool = false,
        permitted: Bool = false,
        mailAccounts: [RemoteMailV2Account] = [],
        calendarAccounts: [RemoteCalendarV2Account] = []
    ) {
        self.mailConnected = mailConnected
        self.calendarConnected = calendarConnected
        self.mailEnabled = mailEnabled
        self.calendarEnabled = calendarEnabled
        self.permitted = permitted
        self.mailAccounts = mailAccounts
        self.calendarAccounts = calendarAccounts
    }
}

public struct RemoteMailV2Account: Codable, Equatable, Sendable {
    public var id: String
    /// Lowercase provider key: `"gmail"`, `"outlook"`, or `"imap"`.
    public var provider: String
    public var email: String
    public var displayName: String
    public var unreadCount: Int?

    public init(id: String, provider: String, email: String, displayName: String, unreadCount: Int? = nil) {
        self.id = id
        self.provider = provider
        self.email = email
        self.displayName = displayName
        self.unreadCount = unreadCount
    }
}

public struct RemoteCalendarV2Account: Codable, Equatable, Sendable {
    public var id: String
    /// Lowercase provider key: `"google"`, `"outlook"`, or `"apple"`.
    public var provider: String
    public var email: String?
    public var displayName: String
    public var canRespond: Bool

    public init(id: String, provider: String, email: String? = nil, displayName: String, canRespond: Bool) {
        self.id = id
        self.provider = provider
        self.email = email
        self.displayName = displayName
        self.canRespond = canRespond
    }
}

// MARK: - Enums

public enum RemoteMailCalendarV2Action: String, Codable, Equatable, Sendable, CaseIterable {
    case listThreads
    case readThread
    case readMessage
    case updateMessage
    case sendMessage
    case replyMessage
    case listCalendars
    case listEvents
    case respondEvent

    /// Mutations are rate-limited and recorded in the host audit log.
    public var isCommand: Bool {
        switch self {
        case .updateMessage, .sendMessage, .replyMessage, .respondEvent: true
        case .listThreads, .readThread, .readMessage, .listCalendars, .listEvents: false
        }
    }
}

public enum RemoteMailV2Folder: String, Codable, Equatable, Sendable, CaseIterable {
    case inbox
    case unread
    case starred
    case sent
    case drafts
    case archive
    case trash
    case spam
}

public enum RemoteMailV2MessageAction: String, Codable, Equatable, Sendable, CaseIterable {
    case markRead
    case markUnread
    case archive
    case star
    case unstar
    case trash
}

public enum RemoteCalendarV2ResponseStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case accepted
    case declined
    case tentative
    case needsAction
    case none
}

public enum RemoteCalendarV2InvitationResponse: String, Codable, Equatable, Sendable, CaseIterable {
    case accepted
    case declined
    case tentative
}

// MARK: - Mail DTOs

public struct RemoteMailV2Address: Codable, Equatable, Sendable {
    public var name: String?
    public var email: String

    public init(name: String? = nil, email: String) {
        self.name = name
        self.email = email
    }
}

public struct RemoteMailV2Attachment: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var size: Int
    public var mimeType: String

    public init(id: String, name: String, size: Int, mimeType: String) {
        self.id = id
        self.name = name
        self.size = size
        self.mimeType = mimeType
    }
}

public struct RemoteMailV2ThreadSummary: Codable, Equatable, Sendable {
    public var id: String
    public var threadId: String
    public var accountId: String
    public var fromName: String?
    public var fromEmail: String
    public var subject: String
    public var snippet: String
    public var dateMs: Int64
    public var unread: Bool
    public var starred: Bool
    public var hasAttachments: Bool
    public var hasDraft: Bool
    public var messageCount: Int

    public init(
        id: String,
        threadId: String,
        accountId: String,
        fromName: String? = nil,
        fromEmail: String,
        subject: String,
        snippet: String,
        dateMs: Int64,
        unread: Bool,
        starred: Bool,
        hasAttachments: Bool,
        hasDraft: Bool = false,
        messageCount: Int = 1
    ) {
        self.id = id
        self.threadId = threadId
        self.accountId = accountId
        self.fromName = fromName
        self.fromEmail = fromEmail
        self.subject = subject
        self.snippet = snippet
        self.dateMs = dateMs
        self.unread = unread
        self.starred = starred
        self.hasAttachments = hasAttachments
        self.hasDraft = hasDraft
        self.messageCount = messageCount
    }
}

public struct RemoteMailV2Message: Codable, Equatable, Sendable {
    public var id: String
    public var threadId: String
    public var accountId: String
    public var from: RemoteMailV2Address
    public var to: [RemoteMailV2Address]
    public var cc: [RemoteMailV2Address]
    public var subject: String
    public var snippet: String
    public var dateMs: Int64
    public var unread: Bool
    public var isDraft: Bool
    public var textBody: String
    public var htmlBody: String?
    public var bodyTruncated: Bool
    public var attachments: [RemoteMailV2Attachment]

    public init(
        id: String,
        threadId: String,
        accountId: String,
        from: RemoteMailV2Address,
        to: [RemoteMailV2Address] = [],
        cc: [RemoteMailV2Address] = [],
        subject: String,
        snippet: String,
        dateMs: Int64,
        unread: Bool,
        isDraft: Bool = false,
        textBody: String,
        htmlBody: String? = nil,
        bodyTruncated: Bool = false,
        attachments: [RemoteMailV2Attachment] = []
    ) {
        self.id = id
        self.threadId = threadId
        self.accountId = accountId
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.snippet = snippet
        self.dateMs = dateMs
        self.unread = unread
        self.isDraft = isDraft
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.bodyTruncated = bodyTruncated
        self.attachments = attachments
    }
}

public struct RemoteMailV2Thread: Codable, Equatable, Sendable {
    public var id: String
    public var threadId: String
    public var accountId: String
    public var subject: String
    public var snippet: String
    public var dateMs: Int64
    public var unread: Bool
    public var starred: Bool
    public var hasAttachments: Bool
    public var hasDraft: Bool
    public var messageCount: Int
    public var webUrl: String?
    public var messages: [RemoteMailV2Message]
    public var messagesTruncated: Bool?

    public init(
        id: String,
        threadId: String,
        accountId: String,
        subject: String,
        snippet: String,
        dateMs: Int64,
        unread: Bool,
        starred: Bool,
        hasAttachments: Bool,
        hasDraft: Bool = false,
        messageCount: Int,
        webUrl: String? = nil,
        messages: [RemoteMailV2Message],
        messagesTruncated: Bool? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.accountId = accountId
        self.subject = subject
        self.snippet = snippet
        self.dateMs = dateMs
        self.unread = unread
        self.starred = starred
        self.hasAttachments = hasAttachments
        self.hasDraft = hasDraft
        self.messageCount = messageCount
        self.webUrl = webUrl
        self.messages = messages
        self.messagesTruncated = messagesTruncated
    }
}

// MARK: - Calendar DTOs

public struct RemoteCalendarV2Calendar: Codable, Equatable, Sendable {
    public var id: String
    public var accountId: String
    public var name: String
    public var color: String?
    public var isPrimary: Bool
    public var visible: Bool
    public var canRespond: Bool
    public var provider: String

    public init(
        id: String,
        accountId: String,
        name: String,
        color: String? = nil,
        isPrimary: Bool = false,
        visible: Bool = true,
        canRespond: Bool = false,
        provider: String
    ) {
        self.id = id
        self.accountId = accountId
        self.name = name
        self.color = color
        self.isPrimary = isPrimary
        self.visible = visible
        self.canRespond = canRespond
        self.provider = provider
    }
}

public struct RemoteCalendarV2Person: Codable, Equatable, Sendable {
    public var name: String?
    public var email: String?
    public var responseStatus: RemoteCalendarV2ResponseStatus?

    public init(name: String? = nil, email: String? = nil, responseStatus: RemoteCalendarV2ResponseStatus? = nil) {
        self.name = name
        self.email = email
        self.responseStatus = responseStatus
    }
}

public struct RemoteCalendarV2Event: Codable, Equatable, Sendable {
    public var id: String
    public var calendarId: String
    public var accountId: String
    public var calendarName: String
    public var calendarColor: String?
    public var title: String
    public var startMs: Int64
    public var endMs: Int64
    public var allDay: Bool
    /// Date-only ISO string (`"YYYY-MM-DD"`) for all-day events.
    public var startDate: String?
    /// Exclusive end date-only ISO string (`"YYYY-MM-DD"`) for all-day events.
    public var endDate: String?
    /// Occurrence start in epoch milliseconds for recurring events when provided by the host.
    public var occurrenceMs: Int64?
    public var location: String?
    public var notes: String?
    public var meetingUrl: String?
    public var webUrl: String?
    public var responseStatus: RemoteCalendarV2ResponseStatus
    public var isOrganizer: Bool
    public var canRespond: Bool
    public var organizer: RemoteCalendarV2Person?
    public var attendees: [RemoteCalendarV2Person]
    public var attendeesTruncated: Bool?

    public init(
        id: String,
        calendarId: String,
        accountId: String,
        calendarName: String,
        calendarColor: String? = nil,
        title: String,
        startMs: Int64,
        endMs: Int64,
        allDay: Bool,
        startDate: String? = nil,
        endDate: String? = nil,
        occurrenceMs: Int64? = nil,
        location: String? = nil,
        notes: String? = nil,
        meetingUrl: String? = nil,
        webUrl: String? = nil,
        responseStatus: RemoteCalendarV2ResponseStatus = .none,
        isOrganizer: Bool = false,
        canRespond: Bool = false,
        organizer: RemoteCalendarV2Person? = nil,
        attendees: [RemoteCalendarV2Person] = [],
        attendeesTruncated: Bool? = nil
    ) {
        self.id = id
        self.calendarId = calendarId
        self.accountId = accountId
        self.calendarName = calendarName
        self.calendarColor = calendarColor
        self.title = title
        self.startMs = startMs
        self.endMs = endMs
        self.allDay = allDay
        self.startDate = startDate
        self.endDate = endDate
        self.occurrenceMs = occurrenceMs
        self.location = location
        self.notes = notes
        self.meetingUrl = meetingUrl
        self.webUrl = webUrl
        self.responseStatus = responseStatus
        self.isOrganizer = isOrganizer
        self.canRespond = canRespond
        self.organizer = organizer
        self.attendees = attendees
        self.attendeesTruncated = attendeesTruncated
    }
}

// MARK: - Request & Response

public struct RemoteMailCalendarV2Request: Codable, Equatable, Sendable {
    public var action: RemoteMailCalendarV2Action

    // Shared
    public var accountId: String?

    // Mail list / search
    public var folder: RemoteMailV2Folder?
    public var query: String?
    public var limit: Int?
    public var pageToken: String?

    // Mail read / update
    public var threadId: String?
    public var messageId: String?
    public var messageAction: RemoteMailV2MessageAction?

    // Mail send / reply
    public var to: [String]?
    public var cc: [String]?
    public var bcc: [String]?
    public var subject: String?
    public var body: String?
    public var replyToThreadId: String?
    public var replyToMessageId: String?

    // Calendar list / respond
    public var startMs: Int64?
    public var endMs: Int64?
    public var calendarId: String?
    public var eventId: String?
    public var occurrenceMs: Int64?
    public var response: RemoteCalendarV2InvitationResponse?

    public init(
        action: RemoteMailCalendarV2Action,
        accountId: String? = nil,
        folder: RemoteMailV2Folder? = nil,
        query: String? = nil,
        limit: Int? = nil,
        pageToken: String? = nil,
        threadId: String? = nil,
        messageId: String? = nil,
        messageAction: RemoteMailV2MessageAction? = nil,
        to: [String]? = nil,
        cc: [String]? = nil,
        bcc: [String]? = nil,
        subject: String? = nil,
        body: String? = nil,
        replyToThreadId: String? = nil,
        replyToMessageId: String? = nil,
        startMs: Int64? = nil,
        endMs: Int64? = nil,
        calendarId: String? = nil,
        eventId: String? = nil,
        occurrenceMs: Int64? = nil,
        response: RemoteCalendarV2InvitationResponse? = nil
    ) {
        self.action = action
        self.accountId = accountId
        self.folder = folder
        self.query = query
        self.limit = limit
        self.pageToken = pageToken
        self.threadId = threadId
        self.messageId = messageId
        self.messageAction = messageAction
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.replyToThreadId = replyToThreadId
        self.replyToMessageId = replyToMessageId
        self.startMs = startMs
        self.endMs = endMs
        self.calendarId = calendarId
        self.eventId = eventId
        self.occurrenceMs = occurrenceMs
        self.response = response
    }
}

public struct RemoteMailCalendarV2Response: Codable, Equatable, Sendable {
    public var threads: [RemoteMailV2ThreadSummary]?
    public var nextPageToken: String?
    public var thread: RemoteMailV2Thread?
    public var message: RemoteMailV2Message?
    public var updated: Bool?
    public var sent: Bool?
    public var threadId: String?
    public var calendars: [RemoteCalendarV2Calendar]?
    public var events: [RemoteCalendarV2Event]?
    public var eventsTruncated: Bool?
    public var responded: Bool?

    public init(
        threads: [RemoteMailV2ThreadSummary]? = nil,
        nextPageToken: String? = nil,
        thread: RemoteMailV2Thread? = nil,
        message: RemoteMailV2Message? = nil,
        updated: Bool? = nil,
        sent: Bool? = nil,
        threadId: String? = nil,
        calendars: [RemoteCalendarV2Calendar]? = nil,
        events: [RemoteCalendarV2Event]? = nil,
        eventsTruncated: Bool? = nil,
        responded: Bool? = nil
    ) {
        self.threads = threads
        self.nextPageToken = nextPageToken
        self.thread = thread
        self.message = message
        self.updated = updated
        self.sent = sent
        self.threadId = threadId
        self.calendars = calendars
        self.events = events
        self.eventsTruncated = eventsTruncated
        self.responded = responded
    }
}

extension RemoteMailCalendarV2Request {
    /// Validates identifiers, bounds, and action-specific required fields before reaching the host bridge.
    public var validationError: RemoteError? {
        if let accountId {
            guard !accountId.isEmpty, UUID(uuidString: accountId) != nil else {
                return RemoteError(.badRequest, "accountId must be a valid UUID")
            }
        }
        let ids: [(String, String?)] = [
            ("threadId", threadId),
            ("messageId", messageId),
            ("replyToThreadId", replyToThreadId),
            ("replyToMessageId", replyToMessageId),
            ("calendarId", calendarId),
            ("eventId", eventId),
        ]
        for (name, value) in ids {
            if let value, value.utf8.count > RemoteMailCalendarV2Limits.maxIdentifierBytes {
                return RemoteError(.badRequest, "\(name) is too long")
            }
        }
        if let pageToken, pageToken.utf8.count > RemoteMailCalendarV2Limits.maxPageTokenBytes {
            return RemoteError(.badRequest, "pageToken is too long")
        }
        if let query, query.count > RemoteMailCalendarV2Limits.maxQueryCharacters {
            return RemoteError(.tooLarge, "query is too long")
        }
        if let limit, limit <= 0 {
            return RemoteError(.badRequest, "limit must be positive")
        }
        if let subject, subject.count > RemoteMailCalendarV2Limits.maxSubjectCharacters {
            return RemoteError(.tooLarge, "subject is too long")
        }
        if let body, body.count > RemoteMailCalendarV2Limits.maxSendBodyCharacters {
            return RemoteError(.tooLarge, "body is too long")
        }
        for (name, list) in [("to", to), ("cc", cc), ("bcc", bcc)] {
            if let list {
                guard list.count <= RemoteMailCalendarV2Limits.maxSendRecipients else {
                    return RemoteError(.tooLarge, "\(name) has too many recipients")
                }
                guard list.allSatisfy({ $0.utf8.count <= RemoteMailCalendarV2Limits.maxIdentifierBytes }) else {
                    return RemoteError(.badRequest, "\(name) contains an address that is too long")
                }
            }
        }

        switch action {
        case .listThreads, .listCalendars:
            return nil
        case .readThread:
            guard accountId != nil, let threadId, !threadId.isEmpty else {
                return RemoteError(.badRequest, "readThread requires accountId and threadId")
            }
            return nil
        case .readMessage:
            let hasTarget = (threadId?.isEmpty == false) || (messageId?.isEmpty == false)
            guard accountId != nil, hasTarget else {
                return RemoteError(.badRequest, "readMessage requires accountId and threadId or messageId")
            }
            return nil
        case .updateMessage:
            guard accountId != nil, let threadId, !threadId.isEmpty, messageAction != nil else {
                return RemoteError(.badRequest, "updateMessage requires accountId, threadId and messageAction")
            }
            return nil
        case .sendMessage:
            let recipients = (to ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard accountId != nil, !recipients.isEmpty else {
                return RemoteError(.badRequest, "sendMessage requires accountId and at least one recipient in to")
            }
            return nil
        case .replyMessage:
            let targetThread = replyToThreadId ?? threadId
            guard accountId != nil, let targetThread, !targetThread.isEmpty else {
                return RemoteError(.badRequest, "replyMessage requires accountId and replyToThreadId")
            }
            guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return RemoteError(.badRequest, "replyMessage requires a non-empty body")
            }
            return nil
        case .listEvents:
            guard let startMs, let endMs, startMs < endMs else {
                return RemoteError(.badRequest, "listEvents requires startMs < endMs")
            }
            let span = endMs.subtractingReportingOverflow(startMs)
            guard !span.overflow, span.partialValue <= RemoteMailCalendarV2Limits.maxCalendarRangeMs else {
                return RemoteError(.badRequest, "listEvents range exceeds 62 days")
            }
            return nil
        case .respondEvent:
            guard let calendarId, !calendarId.isEmpty, let eventId, !eventId.isEmpty, response != nil else {
                return RemoteError(.badRequest, "respondEvent requires calendarId, eventId and response")
            }
            return nil
        }
    }
}
