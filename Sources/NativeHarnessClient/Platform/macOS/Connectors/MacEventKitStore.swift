import AppKit
import Contacts
import EventKit
import Foundation

/// The Mac's calendars and reminders through EventKit, and its contacts through Contacts
/// (`MacDataStoring`). macOS asks the person once per kind, when they turn its connector on
/// (`requestAccess`); everything else only reads whether it may. A build without the usage
/// strings in its Info.plist never asks, since macOS ends an app that asks without one.
final class MacEventKitStore: MacDataStoring, @unchecked Sendable {
    static let shared = MacEventKitStore()

    private let lock = NSLock()
    /// Made when first used, not with this store: making one reaches the Mac's calendar or contacts service, which
    /// nothing should do until a connector of theirs, or the calendar reading Apple Calendar, uses it.
    private var eventStore: EKEventStore?
    private var contactStore: CNContactStore?
    private let info: [String: Any]

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        self.info = info
    }

    /// The usage string macOS shows in the kind's prompt.
    static func usageKey(_ kind: MacDataKind) -> String {
        switch kind {
        case .calendars: "NSCalendarsFullAccessUsageDescription"
        case .reminders: "NSRemindersFullAccessUsageDescription"
        case .contacts: "NSContactsUsageDescription"
        }
    }

    // MARK: Access

    func access(_ kind: MacDataKind) -> MacDataAccess {
        let access: MacDataAccess = switch kind {
        case .calendars: Self.access(EKEventStore.authorizationStatus(for: .event))
        case .reminders: Self.access(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts: Self.access(CNContactStore.authorizationStatus(for: .contacts))
        }
        return access == .notDetermined && (info[Self.usageKey(kind)] as? String)?.isEmpty != false ? .unavailable : access
    }

    func requestAccess(_ kind: MacDataKind) async throws -> Bool {
        switch access(kind) {
        case .granted: return true
        case .notDetermined: break
        case let other: throw MacDataError.notAllowed(kind, other)
        }
        let granted: Bool = switch kind {
        case .calendars: try await currentEventStore().requestFullAccessToEvents()
        case .reminders: try await currentEventStore().requestFullAccessToReminders()
        case .contacts: try await currentContactStore().requestAccess(for: .contacts)
        }
        // A store made before the grant may not see the data yet: the next use makes another.
        if granted, kind != .contacts { lock.withLock { eventStore = nil } }
        return granted
    }

    private static func access(_ status: EKAuthorizationStatus) -> MacDataAccess {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .writeOnly: .writeOnly
        case .denied: .denied
        @unknown default: .denied
        }
    }

    private static func access(_ status: CNAuthorizationStatus) -> MacDataAccess {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .granted
        }
    }

    private func currentEventStore() -> EKEventStore {
        lock.withLock { madeEventStore() }
    }

    /// The event store, made now if it was not; called with `lock` held.
    private func madeEventStore() -> EKEventStore {
        if let eventStore { return eventStore }
        let store = EKEventStore()
        eventStore = store
        return store
    }

    private func currentContactStore() -> CNContactStore {
        lock.withLock {
            if let contactStore { return contactStore }
            let store = CNContactStore()
            contactStore = store
            return store
        }
    }

    /// Runs `body` on the store once macOS lets Yardlet reach the kind.
    private func withStore<T>(_ kind: MacDataKind, _ body: (EKEventStore) throws -> T) throws -> T {
        let access = access(kind)
        guard access == .granted else { throw MacDataError.notAllowed(kind, access) }
        return try lock.withLock { try body(madeEventStore()) }
    }

    // MARK: Calendars

    func calendars(_ kind: MacDataKind) throws -> [MacCalendarInfo] {
        try withStore(kind) { store in
            let entity: EKEntityType = kind == .reminders ? .reminder : .event
            let preferred = kind == .reminders ? store.defaultCalendarForNewReminders() : store.defaultCalendarForNewEvents
            return store.calendars(for: entity).map { calendar in
                MacCalendarInfo(id: calendar.calendarIdentifier, title: calendar.title, account: calendar.source?.title ?? "",
                                color: Self.hex(calendar.cgColor), allowsChanges: calendar.allowsContentModifications,
                                isDefault: calendar.calendarIdentifier == preferred?.calendarIdentifier)
            }
        }
    }

    func events(from start: Date, to end: Date, calendarIDs: [String]?) throws -> [MacEvent] {
        try withStore(.calendars) { store in
            let calendars = try calendarIDs.map { ids in try ids.map { try Self.calendar($0, in: store, entity: .event) } }
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
            return store.events(matching: predicate).map(Self.event)
        }
    }

    func event(id: String, occurrence: Date?) throws -> MacEvent? {
        try withStore(.calendars) { store in try Self.ekEvent(id, occurrence, in: store).map(Self.event) }
    }

    func saveEvent(_ change: MacEventChange) throws -> MacEvent {
        try withStore(.calendars) { store in
            let event: EKEvent
            if let id = change.id {
                guard let found = try Self.ekEvent(id, change.occurrence, in: store) else { throw MacDataError.notFound(id) }
                event = found
            } else {
                event = EKEvent(eventStore: store)
                guard let calendar = store.defaultCalendarForNewEvents else { throw MacDataError.failed("This Mac has no calendar.") }
                event.calendar = calendar
            }
            if let id = change.calendarID { event.calendar = try Self.calendar(id, in: store, entity: .event) }
            guard event.calendar?.allowsContentModifications != false else {
                throw MacDataError.readOnly(event.calendar?.title ?? "The calendar")
            }
            if let title = change.title { event.title = title }
            if let allDay = change.allDay { event.isAllDay = allDay }
            if let zone = change.timeZone { event.timeZone = event.isAllDay ? nil : zone }
            if let start = change.start { event.startDate = start }
            if let end = change.end { event.endDate = end }
            if let location = change.location { event.location = location }
            if let notes = change.notes { event.notes = notes }
            if let url = change.url { event.url = url }
            if let minutes = change.alarmMinutes { event.alarms = minutes.map { EKAlarm(relativeOffset: -Double($0) * 60) } }
            do {
                try store.save(event, span: change.futureEvents ? .futureEvents : .thisEvent, commit: true)
            } catch {
                throw MacDataError.failed(error.localizedDescription)
            }
            return Self.event(event)
        }
    }

    func deleteEvent(id: String, occurrence: Date?, futureEvents: Bool) throws {
        try withStore(.calendars) { store in
            guard let event = try Self.ekEvent(id, occurrence, in: store) else { throw MacDataError.notFound(id) }
            guard event.calendar?.allowsContentModifications != false else {
                throw MacDataError.readOnly(event.calendar?.title ?? "The calendar")
            }
            do {
                try store.remove(event, span: futureEvents ? .futureEvents : .thisEvent, commit: true)
            } catch {
                throw MacDataError.failed(error.localizedDescription)
            }
        }
    }

    private static func calendar(_ id: String, in store: EKEventStore, entity: EKEntityType) throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: id), calendar.allowedEntityTypes.contains(entity == .event ? .event : .reminder)
        else { throw MacDataError.notFound(id) }
        return calendar
    }

    /// The event, or the occurrence of a recurring one that falls at `occurrence`.
    private static func ekEvent(_ id: String, _ occurrence: Date?, in store: EKEventStore) throws -> EKEvent? {
        guard let first = store.event(withIdentifier: id) else { return nil }
        guard let occurrence else { return first }
        let around = store.predicateForEvents(withStart: occurrence.addingTimeInterval(-86_400),
                                              end: occurrence.addingTimeInterval(86_400), calendars: [first.calendar])
        return store.events(matching: around).first { $0.eventIdentifier == id && $0.occurrenceDate == occurrence }
    }

    private static func event(_ event: EKEvent) -> MacEvent {
        let recurring = event.hasRecurrenceRules || event.isDetached
        return MacEvent(
            id: event.eventIdentifier ?? event.calendarItemIdentifier,
            occurrence: recurring ? event.occurrenceDate : nil,
            calendarID: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "",
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            allDay: event.isAllDay,
            timeZone: event.isAllDay ? nil : event.timeZone,
            location: event.location,
            notes: event.notes,
            url: event.url,
            isRecurring: recurring,
            attendees: (event.attendees ?? []).map(person),
            organizer: event.organizer.map(person),
            availability: availability(event.availability),
            alarmMinutes: (event.alarms ?? []).filter { $0.absoluteDate == nil }.map { Int(-$0.relativeOffset / 60) }
        )
    }

    private static func person(_ participant: EKParticipant) -> MacEvent.Person {
        let address = participant.url.absoluteString
        let email = address.lowercased().hasPrefix("mailto:") ? String(address.dropFirst("mailto:".count)) : nil
        let status: String? = switch participant.participantStatus {
        case .accepted: "accepted"
        case .declined: "declined"
        case .tentative: "tentative"
        case .pending: "pending"
        case .delegated: "delegated"
        case .completed: "completed"
        case .inProcess: "inProcess"
        case .unknown: nil
        @unknown default: nil
        }
        return MacEvent.Person(name: participant.name, email: email, status: status)
    }

    private static func availability(_ availability: EKEventAvailability) -> String? {
        switch availability {
        case .busy: "busy"
        case .free: "free"
        case .tentative: "tentative"
        case .unavailable: "unavailable"
        case .notSupported: nil
        @unknown default: nil
        }
    }

    private static func hex(_ color: CGColor?) -> String? {
        guard let color = color.flatMap({ NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }) else { return nil }
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255),
                      Int(color.blueComponent * 255))
    }

    // MARK: Reminders

    func reminders(_ query: MacReminderQuery) async throws -> [MacReminder] {
        let predicate = try withStore(.reminders) { store -> NSPredicate in
            let lists = try query.listIDs.map { ids in try ids.map { try Self.calendar($0, in: store, entity: .reminder) } }
            return switch query.status {
            case .incomplete: store.predicateForIncompleteReminders(withDueDateStarting: query.from, ending: query.to, calendars: lists)
            case .completed: store.predicateForCompletedReminders(withCompletionDateStarting: query.from, ending: query.to, calendars: lists)
            case .all: store.predicateForReminders(in: lists)
            }
        }
        let store = currentEventStore()
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: (found ?? []).map(Self.reminder))
            }
        }
    }

    func saveReminder(_ change: MacReminderChange) throws -> MacReminder {
        try withStore(.reminders) { store in
            let reminder: EKReminder
            if let id = change.id {
                guard let found = store.calendarItem(withIdentifier: id) as? EKReminder else { throw MacDataError.notFound(id) }
                reminder = found
            } else {
                reminder = EKReminder(eventStore: store)
                guard let list = store.defaultCalendarForNewReminders() else { throw MacDataError.failed("This Mac has no reminder list.") }
                reminder.calendar = list
            }
            if let id = change.listID { reminder.calendar = try Self.calendar(id, in: store, entity: .reminder) }
            guard reminder.calendar?.allowsContentModifications != false else {
                throw MacDataError.readOnly(reminder.calendar?.title ?? "The list")
            }
            if let title = change.title { reminder.title = title }
            if let notes = change.notes { reminder.notes = notes }
            if let due = change.due { reminder.dueDateComponents = due }
            if let priority = change.priority { reminder.priority = priority }
            if let completed = change.completed { reminder.isCompleted = completed }
            do {
                try store.save(reminder, commit: true)
            } catch {
                throw MacDataError.failed(error.localizedDescription)
            }
            return Self.reminder(reminder)
        }
    }

    private static func reminder(_ reminder: EKReminder) -> MacReminder {
        MacReminder(id: reminder.calendarItemIdentifier, listID: reminder.calendar?.calendarIdentifier ?? "",
                    listTitle: reminder.calendar?.title ?? "", title: reminder.title ?? "", notes: reminder.notes,
                    due: reminder.dueDateComponents, priority: reminder.priority, completed: reminder.isCompleted,
                    completionDate: reminder.completionDate, url: reminder.url)
    }

    // MARK: Contacts

    private static var contactKeys: [CNKeyDescriptor] {
        [
        CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
        CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
        CNContactPostalAddressesKey, CNContactBirthdayKey
        ] as [CNKeyDescriptor]
    }

    func contacts(matching text: String, limit: Int) throws -> [MacContact] {
        let access = access(.contacts)
        guard access == .granted else { throw MacDataError.notAllowed(.contacts, access) }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = value.filter(\.isNumber)
        let predicate: NSPredicate
        if value.contains("@") {
            predicate = CNContact.predicateForContacts(matchingEmailAddress: value)
        } else if digits.count >= 4, value.allSatisfy({ $0.isNumber || "+-() .".contains($0) }) {
            predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: value))
        } else {
            predicate = CNContact.predicateForContacts(matchingName: value)
        }
        do {
            return try currentContactStore().unifiedContacts(matching: predicate, keysToFetch: Self.contactKeys).prefix(limit).map(Self.contact)
        } catch {
            throw MacDataError.failed(error.localizedDescription)
        }
    }

    func contact(id: String) throws -> MacContact? {
        let access = access(.contacts)
        guard access == .granted else { throw MacDataError.notAllowed(.contacts, access) }
        do {
            return Self.contact(try currentContactStore().unifiedContact(withIdentifier: id, keysToFetch: Self.contactKeys))
        } catch let error as CNError where error.code == .recordDoesNotExist {
            return nil
        } catch {
            throw MacDataError.failed(error.localizedDescription)
        }
    }

    private static func contact(_ contact: CNContact) -> MacContact {
        func label(_ raw: String?) -> String? {
            raw.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) }
        }
        let formatter = CNPostalAddressFormatter()
        return MacContact(
            id: contact.identifier,
            givenName: contact.givenName,
            familyName: contact.familyName,
            nickname: contact.nickname.isEmpty ? nil : contact.nickname,
            organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
            jobTitle: contact.jobTitle.isEmpty ? nil : contact.jobTitle,
            emails: contact.emailAddresses.map { .init(label: label($0.label), value: $0.value as String) },
            phones: contact.phoneNumbers.map { .init(label: label($0.label), value: $0.value.stringValue) },
            addresses: contact.postalAddresses.map {
                .init(label: label($0.label), value: formatter.string(from: $0.value).replacingOccurrences(of: "\n", with: ", "))
            },
            birthday: contact.birthday
        )
    }
}

extension MacDataKind {
    /// The pane of Privacy & Security in System Settings that lists it.
    var privacySettingsURL: URL {
        let anchor = switch self {
        case .calendars: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .contacts: "Privacy_Contacts"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}
