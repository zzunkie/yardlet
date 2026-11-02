import Foundation

/// How the mailbox words names, subjects and times.
enum MailText {
    /// What "Ask an agent" puts in a new task's composer: the thread named so the agent can read it
    /// with the account's connector, and no body, so nobody else's words reach the prompt as the
    /// person's own. The person writes what to do after it.
    static func handoff(_ thread: MailThread, account: MailAccount) -> String {
        let sender = thread.summary.senders.first.map(MailComposition.formatted) ?? ""
        // Gmail's tools read a thread by its ID; Outlook's and an IMAP account's read a message, so the
        // newest is named (an IMAP thread is one message).
        let (id, tool) = switch account.provider {
        case .gmail: (thread.summary.id.threadID, "get_thread")
        case .outlook, .imap: (thread.messages.last { !$0.isDraft }?.id ?? thread.summary.id.threadID, "get_message")
        }
        let reads = account.connectorSlug.map { "`\($0)_\(tool)`" } ?? account.serviceName
        return [L10n.format("Mail subject %@", subject(thread.summary.subject)),
                L10n.format("Mail from %@", sender),
                L10n.format(account.provider == .gmail ? "Mail handoff %@ %@ %@" : "Mail handoff message %@ %@ %@",
                            account.address, id, reads)]
            .joined(separator: "\n") + "\n\n"
    }

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
