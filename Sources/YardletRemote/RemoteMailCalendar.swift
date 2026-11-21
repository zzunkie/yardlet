import Foundation

/// Whether the host's mail and calendar are turned on there, and whether this device may use them (§15.38). It holds
/// no account, address or event: a device without the permission reads it too, to say where the permission is.
public struct RemoteMailCalendarState: Codable, Equatable, Sendable {
    public var calendar: Bool
    public var mailbox: Bool
    /// The device has its Mail and Calendar permission (§15.28).
    public var permitted: Bool

    public init(calendar: Bool = false, mailbox: Bool = false, permitted: Bool = false) {
        self.calendar = calendar
        self.mailbox = mailbox
        self.permitted = permitted
    }
}

extension RemoteProtocol {
    /// The calls `calendar` takes (§15.38): the accounts and the host's choices, an account's calendars, a calendar's
    /// events over a range, and an answer to an invitation.
    public static let calendarActions: Set<String> = ["accounts", "calendars", "events", "respond"]
    /// The calls that change something on the service, which are commands (§4.4).
    public static let calendarCommands: Set<String> = ["respond"]
    /// The calls `mail` takes (§15.38), one for each of the mailbox's own requests of a service.
    public static let mailActions: Set<String> = ["accounts", "folders", "inbox", "list", "search", "thread", "change",
                                                  "saveDraft", "sendDraft", "discardDraft", "draftID", "changeCursor",
                                                  "changes"]
    public static let mailCommands: Set<String> = ["change", "saveDraft", "sendDraft", "discardDraft"]
    /// A call's JSON arguments, at most.
    public static let maxMailCalendarCallBytes = 1_048_576
}
