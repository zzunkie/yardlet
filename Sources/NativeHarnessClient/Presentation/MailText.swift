import Foundation

/// How the mailbox words names, subjects and times.
enum MailText {
    /// The thread's senders, newest first: the first two names, and how many messages when more than one.
    static func senders(_ thread: MailThreadSummary, me: String? = nil) -> String {
        let names = thread.senders.prefix(2).map { name($0, me: me) }.joined(separator: ", ")
        return thread.messageCount > 1 ? "\(names) (\(thread.messageCount))" : names
    }

    /// "me" for the account's own address, else the name the message gave, else the address.
    static func name(_ address: MailAddress, me: String?) -> String {
        if let me, address.address.caseInsensitiveCompare(me) == .orderedSame { return L10n.string("Mail me") }
        return address.displayName
    }

    static func subject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.string("(No subject)") : trimmed
    }

    /// Today's time, else this week's day, else the date, with the year only for another year.
    static func listTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: now)).day, days < 7, days > 0 {
            return days == 1 ? L10n.string("Yesterday") : date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// A message's full time, as a thread shows it.
    static func messageTime(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().weekday(.abbreviated).hour().minute())
    }
}
