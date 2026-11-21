import Foundation
import YardletRemote

/// The host's calendar in this window (docs/REMOTE_PROTOCOL.md §15.38): this Mac's own calendar views over a calendar
/// whose accounts are the host's, each call made through the host's connection to the host's own transport.
extension RemoteHostModel {
    /// Whether the host's calendar is on and this device may read it, then the host's accounts; told again by
    /// `mailCalendarChanged` while the window is open.
    func readMailCalendarState() async {
        guard offersHostCalendar || offersHostMail, isConnected else {
            if !offersHostCalendar && !offersHostMail {
                mailCalendarState = nil
                calendar.setEnabled(false)
                mailbox.setEnabled(false)
            }
            return
        }
        let answer = await response(to: .mailCalendarState(watching: true))
        guard answer.ok, let state = answer.mailCalendarState else { return }
        mailCalendarState = state
        await followHostCalendar()
        await followHostMail()
    }

    /// The calendar shows while the host's is on; it holds the host's accounts while this device may read them, and
    /// none otherwise, so the window says where the permission is.
    private func followHostCalendar() async {
        guard offersHostCalendar, let state = mailCalendarState, state.calendar else {
            calendar.setEnabled(false)
            return
        }
        let wasEnabled = calendar.isEnabled
        calendar.setEnabled(true)
        guard state.permitted else {
            if !calendar.accounts.isEmpty { calendar.setAccounts([]) }
            return
        }
        let answer = await response(to: .calendar(action: "accounts", data: nil))
        guard answer.ok, let read = try? RemoteCalendarWire.decode(RemoteCalendarWire.Accounts.self, answer.data),
              calendar.isEnabled else { return }
        if !wasEnabled { calendar.adopt(choices: read.choices, showsSchedules: read.showsSchedules) }
        guard read.accounts != calendar.accounts else { return }
        calendar.setAccounts(read.accounts.map { account in
            (account, RemoteCalendarTransport(accountID: account.id) { [weak self] action, data in
                guard let self else { throw CalendarFailure(kind: .unavailable, message: "") }
                return try await self.calendarCall(action, data)
            })
        })
    }

    /// The host's calendar is on but this device may not read it.
    var needsMailCalendarPermission: Bool { mailCalendarState.map { !$0.permitted } ?? false }

    /// One call of the host's calendar; a refusal in the calendar's own words.
    func calendarCall(_ action: String, _ data: Data?) async throws -> Data {
        let answer = await response(to: .calendar(action: action, data: data))
        if answer.ok { return answer.data ?? Data() }
        switch answer.error?.reason {
        case .signIn?:
            throw CalendarFailure(kind: .signInRequired,
                                  message: L10n.format("Sign in to this account again in %@'s Settings › Connectors.", name))
        case .failed?:
            throw CalendarFailure(kind: .unavailable, message: answer.error?.message ?? "")
        default:
            throw CalendarFailure(kind: .unavailable, message: Self.message(for: answer.error, host: name))
        }
    }
}

/// One of the host's calendar accounts, reached through the host (§15.38).
struct RemoteCalendarTransport: CalendarAccountTransport {
    let accountID: UUID
    let call: @Sendable (String, Data?) async throws -> Data

    func calendars() async throws -> [CalendarInfo] {
        try decode([CalendarInfo].self, try await call("calendars", RemoteCalendarWire.encode(RemoteCalendarWire.Call(accountID: accountID))))
    }

    func events(in calendar: CalendarInfo, from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let arguments = RemoteCalendarWire.Call(accountID: accountID, calendar: calendar, from: start, to: end)
        return try decode([CalendarEvent].self, try await call("events", RemoteCalendarWire.encode(arguments)))
    }

    func respond(to event: CalendarEvent, _ response: CalendarResponse) async throws {
        _ = try await call("respond", RemoteCalendarWire.encode(RemoteCalendarWire.Call(accountID: accountID, event: event,
                                                                                        response: response)))
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
        do { return try RemoteCalendarWire.decode(type, data) } catch {
            throw CalendarFailure(kind: .unavailable, message: L10n.string("The calendar's answer could not be read."))
        }
    }
}
