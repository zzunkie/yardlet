import Foundation
import Observation
import YardletRemote

/// What a device follows of the host's mail and calendar (§15.38): whether each is on, and which accounts it holds.
struct MailCalendarSignature: Equatable {
    var calendar: Bool
    var calendarAccounts: [CalendarAccount]
    var mailbox: Bool
}

/// Another Mac's window reads the host's own calendar through the accounts and transports the host's calendar holds
/// (docs/REMOTE_PROTOCOL.md §15.38): the same requests the host's calendar makes, from the same code, while the host's
/// calendar is on. The client keeps what it reads in memory; the host keeps nothing more for it.
extension AppModelRemoteBridge {
    func mailCalendarState() -> RemoteMailCalendarState {
        guard let model else { return RemoteMailCalendarState() }
        let signature = observeMailCalendarIfNeeded(in: model)
        answeredMailCalendar = signature
        return RemoteMailCalendarState(calendar: signature.calendar, mailbox: signature.mailbox)
    }

    func setWatchingMailCalendar(_ watching: Bool) {
        watchesMailCalendar = watching
        if watching, let model { answeredMailCalendar = observeMailCalendarIfNeeded(in: model) }
    }

    private func observeMailCalendarIfNeeded(in model: AppModel) -> MailCalendarSignature {
        guard watchesMailCalendar, !isObservingMailCalendar else { return Self.mailCalendarSignature(of: model) }
        isObservingMailCalendar = true
        return withObservationTracking {
            Self.mailCalendarSignature(of: model)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isObservingMailCalendar = false
                self.mailCalendarMayHaveChanged()
            }
        }
    }

    private func mailCalendarMayHaveChanged() {
        guard watchesMailCalendar, let model else { return }
        let next = observeMailCalendarIfNeeded(in: model)
        guard next != answeredMailCalendar else { return }
        answeredMailCalendar = next
        changeHandler?(.mailCalendar)
    }

    private static func mailCalendarSignature(of model: AppModel) -> MailCalendarSignature {
        MailCalendarSignature(calendar: model.calendar.isEnabled, calendarAccounts: model.calendar.accounts,
                              mailbox: model.mailbox.isEnabled)
    }

    func calendar(action: String, data: Data?) async -> Result<Data, RemoteError> {
        guard let center = model?.calendar, center.isEnabled else {
            return .failure(RemoteError(.unavailable, "The calendar is off on this Mac"))
        }
        do {
            if action == "accounts" {
                return .success(RemoteCalendarWire.encode(RemoteCalendarWire.Accounts(
                    accounts: center.accounts, choices: center.choices, showsSchedules: center.showsSchedules)))
            }
            let call = try RemoteCalendarWire.decode(RemoteCalendarWire.Call.self, data)
            guard let account = center.account(call.accountID), let transport = center.transport(for: account.id) else {
                return .failure(RemoteError(.notFound, "No such calendar account"))
            }
            switch action {
            case "calendars":
                return .success(RemoteCalendarWire.encode(try await transport.calendars()))
            case "events":
                guard let calendar = call.calendar, calendar.id.accountID == account.id, let from = call.from, let to = call.to,
                      from < to, to.timeIntervalSince(from) <= RemoteCalendarWire.maxRange else {
                    return .failure(RemoteError(.badRequest, "events takes one of the account's calendars and a range"))
                }
                return .success(RemoteCalendarWire.encode(try await transport.events(in: calendar, from: from, to: to)))
            case "respond":
                guard let event = call.event, event.id.calendar.accountID == account.id, let response = call.response,
                      response != .needsAction, account.provider.answersInvitations else {
                    return .failure(RemoteError(.badRequest, "respond takes an invitation of the account and an answer"))
                }
                try await center.respond(to: event, response)
                return .success(Data("{}".utf8))
            default:
                return .failure(RemoteError(.unknownType, "Unknown calendar action"))
            }
        } catch let error as RemoteError {
            return .failure(error)
        } catch {
            // The host's own words, as its calendar shows them; a refused sign-in is the client's to word.
            let failure = CalendarCenter.failure(error)
            return .failure(RemoteError(.unavailable, failure.message, reason: failure.kind == .signInRequired ? .signIn : .failed))
        }
    }
}
