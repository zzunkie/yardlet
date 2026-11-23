import Foundation
import Observation
import SwiftUI
import YardletRemote

// MARK: - Composite Keys

extension RemoteMailV2ThreadSummary {
    /// Globally unique key across accounts so `ForEach` never sees duplicate IDs.
    var compositeKey: String { "\(accountId):\(threadId)" }
}

extension RemoteMailV2Thread {
    var compositeKey: String { "\(accountId):\(threadId)" }
}

extension RemoteCalendarV2Calendar {
    var compositeKey: String { "\(accountId):\(id)" }
}

extension RemoteCalendarV2Event {
    var compositeKey: String { "\(accountId):\(calendarId):\(id):\(occurrenceMs ?? startMs)" }
}

// MARK: - Mail & Calendar V2 In-Memory Store

/// Strictly memory-only store driving the iOS Mail and Calendar tabs over `mailCalendarV2`.
///
/// Nothing read from Mail or Calendar (subjects, bodies, senders, threads, events, calendars) is ever
/// written to disk or `UserDefaults`. All cached data is cleared immediately on disconnect, Mac switch,
/// or permission revocation (`!permitted` or `.notAllowed`).
@MainActor
@Observable
final class MailCalendarStore {
    enum MailFolder: String, CaseIterable, Identifiable {
        case inbox
        case unread
        case starred
        case sent

        var id: String { rawValue }

        var remoteFolder: RemoteMailV2Folder {
            switch self {
            case .inbox: .inbox
            case .unread: .unread
            case .starred: .starred
            case .sent: .sent
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .inbox: "Inbox"
            case .unread: "Unread"
            case .starred: "Starred"
            case .sent: "Sent"
            }
        }
    }

    struct ReplyPreview: Equatable {
        let recipientsDisplay: String
        let subjectDisplay: String
        let replyToMessageId: String?
    }

    let session: HostSession

    // MARK: - Shared V2 State

    private(set) var v2State: RemoteMailCalendarV2State?
    private(set) var stateLoading = false
    private(set) var stateError: String?

    // MARK: - Mail State

    private(set) var folder: MailFolder = .inbox
    private(set) var selectedMailAccountId: String?
    private(set) var mailQuery = ""
    private(set) var threads: [RemoteMailV2ThreadSummary] = []
    private(set) var nextPageToken: String?
    private(set) var openThread: RemoteMailV2Thread?
    private(set) var openThreadKey: String?
    private(set) var openThreadLoading = false
    private(set) var openThreadError: String?
    private(set) var mailLoading = false
    private(set) var mailLoadingMore = false
    private(set) var mailError: String?
    private(set) var mailBusy = false
    var mailActionError: String?
    var mailBanner: String?

    // MARK: - Calendar State

    private(set) var selectedDate: Date
    private(set) var weekStartDate: Date
    private(set) var selectedCalendarKey: String?
    private(set) var calendars: [RemoteCalendarV2Calendar] = []
    private(set) var events: [RemoteCalendarV2Event] = []
    private(set) var eventsTruncated = false
    private(set) var calendarLoading = false
    private(set) var calendarError: String?
    private(set) var rsvpBusyKey: String?
    var calendarActionError: String?

    // MARK: - Private Task Handles & Generations

    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var mailTask: Task<Void, Never>?
    @ObservationIgnored private var openThreadTask: Task<Void, Never>?
    @ObservationIgnored private var calendarTask: Task<Void, Never>?

    @ObservationIgnored private var mailGeneration = 0
    @ObservationIgnored private var openThreadGeneration = 0
    @ObservationIgnored private var calendarGeneration = 0
    @ObservationIgnored private var hasLoadedMailOnce = false
    @ObservationIgnored private var hasLoadedCalendarOnce = false

    init(session: HostSession, now: Date = Date()) {
        self.session = session
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        self.selectedDate = today
        self.weekStartDate = Self.startOfWeek(containing: today, calendar: cal)
        self.v2State = session.mailCalendarV2State
    }

    // MARK: - Readiness

    var isPermitted: Bool { v2State?.permitted == true }

    var mailReady: Bool {
        session.isConnected
            && session.capabilities.mailCalendarV2
            && v2State?.permitted == true
            && v2State?.mailEnabled == true
            && v2State?.mailConnected == true
    }

    var calendarReady: Bool {
        session.isConnected
            && session.capabilities.mailCalendarV2
            && v2State?.permitted == true
            && v2State?.calendarEnabled == true
            && v2State?.calendarConnected == true
    }

    var mailAccounts: [RemoteMailV2Account] {
        v2State?.mailAccounts ?? []
    }

    /// Pagination tokens are only valid when targeting a single account (`accountId != nil` or only 1 connected account).
    var canLoadMoreThreads: Bool {
        nextPageToken != nil && effectivePaginationAccountId != nil
    }

    private var effectivePaginationAccountId: String? {
        if let selectedMailAccountId { return selectedMailAccountId }
        if mailAccounts.count == 1 { return mailAccounts[0].id }
        return nil
    }

    // MARK: - Lifecycle & Host Event Sync

    func cancelAllTasks() {
        stateTask?.cancel()
        stateTask = nil
        mailTask?.cancel()
        mailTask = nil
        openThreadTask?.cancel()
        openThreadTask = nil
        calendarTask?.cancel()
        calendarTask = nil
    }

    func handleConnectionChanged(isConnected: Bool) {
        if !isConnected {
            cancelAllTasks()
            clearAllData()
            v2State = nil
            stateLoading = false
            stateError = nil
        }
    }

    func syncHostState(_ next: RemoteMailCalendarV2State?) {
        guard let next else {
            cancelAllTasks()
            clearAllData()
            v2State = nil
            return
        }
        applyV2State(next)
    }

    func handleHostDataChanged(activeTab: MobileTab) {
        guard session.isConnected, session.capabilities.mailCalendarV2 else { return }
        switch activeTab {
        case .mail:
            if mailReady {
                loadThreads(clearExisting: false)
                if let current = openThread {
                    reloadOpenThread(accountId: current.accountId, threadId: current.threadId, clearExisting: false)
                }
            }
        case .calendar:
            if calendarReady {
                loadCalendar(clearEvents: false)
            }
        case .tasks:
            break
        }
    }

    func refreshState() async {
        guard session.isConnected, session.capabilities.mailCalendarV2 else { return }
        stateTask?.cancel()
        stateLoading = true
        stateError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await session.fetchMailCalendarV2State(watching: true)
                guard !Task.isCancelled else { return }
                self.stateLoading = false
                self.applyV2State(state)
            } catch {
                guard !Task.isCancelled else { return }
                self.stateLoading = false
                self.stateError = self.handleError(error)
            }
        }
        stateTask = task
        await task.value
    }

    private func applyV2State(_ state: RemoteMailCalendarV2State) {
        stateError = nil
        if !state.permitted {
            revokePermissionAndClearAll(updatingState: state)
            return
        }
        v2State = state
        if !state.mailEnabled || !state.mailConnected {
            clearMailData()
        } else if let selectedId = selectedMailAccountId,
                  !state.mailAccounts.contains(where: { $0.id == selectedId }) {
            selectedMailAccountId = nil
        }
        if !state.calendarEnabled || !state.calendarConnected {
            clearCalendarData()
        } else if let selectedKey = selectedCalendarKey,
                  !calendars.isEmpty,
                  !calendars.contains(where: { $0.compositeKey == selectedKey }) {
            selectedCalendarKey = nil
        }
    }

    private func revokePermissionAndClearAll(updatingState nextState: RemoteMailCalendarV2State? = nil) {
        cancelAllTasks()
        clearAllData()
        session.revokeMailCalendarV2PermissionLocally()
        if let nextState {
            var sanitized = nextState
            sanitized.permitted = false
            sanitized.mailAccounts = []
            sanitized.calendarAccounts = []
            v2State = sanitized
        } else if var existing = v2State {
            existing.permitted = false
            existing.mailAccounts = []
            existing.calendarAccounts = []
            v2State = existing
        } else {
            v2State = RemoteMailCalendarV2State(permitted: false)
        }
    }

    private func clearAllData() {
        clearMailData()
        clearCalendarData()
    }

    private func clearMailData() {
        mailTask?.cancel()
        mailTask = nil
        openThreadTask?.cancel()
        openThreadTask = nil
        mailGeneration += 1
        openThreadGeneration += 1
        threads = []
        nextPageToken = nil
        openThread = nil
        openThreadKey = nil
        openThreadLoading = false
        openThreadError = nil
        mailLoading = false
        mailLoadingMore = false
        mailError = nil
        mailBusy = false
        mailActionError = nil
        mailBanner = nil
        hasLoadedMailOnce = false
    }

    private func clearCalendarData() {
        calendarTask?.cancel()
        calendarTask = nil
        calendarGeneration += 1
        calendars = []
        events = []
        eventsTruncated = false
        selectedCalendarKey = nil
        calendarLoading = false
        calendarError = nil
        rsvpBusyKey = nil
        calendarActionError = nil
        hasLoadedCalendarOnce = false
    }

    // MARK: - Mail Actions

    func activateMailTab() {
        guard session.isConnected, session.capabilities.mailCalendarV2 else { return }
        if v2State == nil {
            guard !stateLoading else { return }
            Task {
                await refreshState()
                if mailReady && !hasLoadedMailOnce && !mailLoading {
                    loadThreads(clearExisting: true)
                }
            }
        } else if mailReady && !hasLoadedMailOnce && !mailLoading {
            loadThreads(clearExisting: true)
        }
    }

    func selectFolder(_ newFolder: MailFolder) {
        guard newFolder != folder else { return }
        folder = newFolder
        loadThreads(clearExisting: true)
    }

    func selectMailAccount(_ accountId: String?) {
        guard accountId != selectedMailAccountId else { return }
        selectedMailAccountId = accountId
        loadThreads(clearExisting: true)
    }

    func submitMailSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > RemoteMailCalendarV2Limits.maxQueryCharacters {
            mailTask?.cancel()
            mailGeneration += 1
            threads = []
            nextPageToken = nil
            mailLoading = false
            mailLoadingMore = false
            mailError = String(localized: "Search query must be \(RemoteMailCalendarV2Limits.maxQueryCharacters) characters or fewer.")
            return
        }
        mailQuery = trimmed
        loadThreads(clearExisting: true)
    }

    func clearMailSearch() {
        guard !mailQuery.isEmpty || mailError != nil else { return }
        mailQuery = ""
        loadThreads(clearExisting: true)
    }

    func refreshMail() async {
        guard session.isConnected, session.capabilities.mailCalendarV2 else { return }
        await refreshState()
        guard mailReady else { return }
        await performLoadThreads(clearExisting: false)
    }

    func loadThreads(clearExisting: Bool) {
        guard mailReady else { return }
        mailTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoadThreads(clearExisting: clearExisting)
        }
        mailTask = task
    }

    private func performLoadThreads(clearExisting: Bool) async {
        guard mailReady else { return }
        mailGeneration += 1
        let generation = mailGeneration
        let activeFolder = folder
        let activeAccountId = selectedMailAccountId
        let activeQuery = mailQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        if activeQuery.count > RemoteMailCalendarV2Limits.maxQueryCharacters {
            threads = []
            nextPageToken = nil
            mailLoading = false
            mailLoadingMore = false
            mailError = String(localized: "Search query must be \(RemoteMailCalendarV2Limits.maxQueryCharacters) characters or fewer.")
            return
        }

        if clearExisting {
            threads = []
            nextPageToken = nil
        }
        mailError = nil
        mailLoading = true
        mailLoadingMore = false

        let request = RemoteMailCalendarV2Request(
            action: .listThreads,
            accountId: activeAccountId,
            folder: activeFolder.remoteFolder,
            query: activeQuery.isEmpty ? nil : activeQuery,
            limit: RemoteMailCalendarV2Limits.defaultListLimit
        )

        do {
            let response = try await session.sendMailCalendarV2(request)
            guard !Task.isCancelled, mailGeneration == generation else { return }
            let incoming = Self.deduplicateThreads(response.threads ?? [])
            threads = incoming
            // Only keep nextPageToken when pagination targets a single account.
            nextPageToken = effectivePaginationAccountId != nil ? Self.nonEmpty(response.nextPageToken) : nil
            mailLoading = false
            hasLoadedMailOnce = true
        } catch {
            guard !Task.isCancelled, mailGeneration == generation else { return }
            mailLoading = false
            mailError = handleError(error)
        }
    }

    func loadMoreThreads() {
        guard mailReady,
              !mailLoading,
              !mailLoadingMore,
              let token = nextPageToken, !token.isEmpty,
              let paginationAccountId = effectivePaginationAccountId else { return }

        mailTask?.cancel()
        mailGeneration += 1
        let generation = mailGeneration
        let activeFolder = folder
        let activeQuery = mailQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        mailLoadingMore = true
        mailError = nil

        let request = RemoteMailCalendarV2Request(
            action: .listThreads,
            accountId: paginationAccountId,
            folder: activeFolder.remoteFolder,
            query: activeQuery.isEmpty ? nil : activeQuery,
            limit: RemoteMailCalendarV2Limits.defaultListLimit,
            pageToken: token
        )

        mailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await session.sendMailCalendarV2(request)
                guard !Task.isCancelled, self.mailGeneration == generation else { return }
                let merged = Self.deduplicateThreads(self.threads + (response.threads ?? []))
                self.threads = merged
                self.nextPageToken = Self.nonEmpty(response.nextPageToken)
                self.mailLoadingMore = false
            } catch {
                guard !Task.isCancelled, self.mailGeneration == generation else { return }
                self.mailLoadingMore = false
                self.mailError = self.handleError(error)
            }
        }
    }

    // MARK: - Open Thread & Thread Mutations

    func loadThread(accountId: String, threadId: String) {
        reloadOpenThread(accountId: accountId, threadId: threadId, clearExisting: true)
    }

    private func reloadOpenThread(accountId: String, threadId: String, clearExisting: Bool) {
        guard mailReady else { return }
        openThreadTask?.cancel()
        openThreadGeneration += 1
        let generation = openThreadGeneration
        let key = "\(accountId):\(threadId)"
        openThreadKey = key
        if clearExisting {
            openThread = nil
        }
        openThreadError = nil
        openThreadLoading = true
        mailActionError = nil

        let request = RemoteMailCalendarV2Request(
            action: .readThread,
            accountId: accountId,
            threadId: threadId
        )

        openThreadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await session.sendMailCalendarV2(request)
                guard !Task.isCancelled, self.openThreadGeneration == generation else { return }
                self.openThreadLoading = false
                if let thread = response.thread {
                    self.openThread = thread
                } else {
                    self.openThreadError = String(localized: "Couldn't load this conversation.")
                }
            } catch {
                guard !Task.isCancelled, self.openThreadGeneration == generation else { return }
                self.openThreadLoading = false
                self.openThreadError = self.handleError(error)
            }
        }
    }

    func closeThread() {
        openThreadTask?.cancel()
        openThreadTask = nil
        openThreadGeneration += 1
        openThread = nil
        openThreadKey = nil
        openThreadLoading = false
        openThreadError = nil
        mailActionError = nil
    }

    @discardableResult
    func updateOpenThread(action: RemoteMailV2MessageAction) async -> Bool {
        guard mailReady, !mailBusy, let thread = openThread else { return false }
        mailBusy = true
        mailActionError = nil
        defer { mailBusy = false }

        let request = RemoteMailCalendarV2Request(
            action: .updateMessage,
            accountId: thread.accountId,
            threadId: thread.threadId,
            messageAction: action
        )

        do {
            _ = try await session.sendMailCalendarV2(request)
            applyThreadUpdateLocally(accountId: thread.accountId, threadId: thread.threadId, action: action)
            return true
        } catch {
            mailActionError = handleError(error)
            return false
        }
    }

    private func applyThreadUpdateLocally(accountId: String, threadId: String, action: RemoteMailV2MessageAction) {
        let targetKey = "\(accountId):\(threadId)"
        switch action {
        case .archive, .trash:
            threads.removeAll { $0.compositeKey == targetKey }
            mailBanner = String(localized: "Conversation archived")
        case .star:
            if var open = openThread, open.compositeKey == targetKey {
                open.starred = true
                openThread = open
            }
            if let index = threads.firstIndex(where: { $0.compositeKey == targetKey }) {
                threads[index].starred = true
            }
        case .unstar:
            if var open = openThread, open.compositeKey == targetKey {
                open.starred = false
                openThread = open
            }
            if folder == .starred {
                threads.removeAll { $0.compositeKey == targetKey }
            } else if let index = threads.firstIndex(where: { $0.compositeKey == targetKey }) {
                threads[index].starred = false
            }
        case .markRead:
            if var open = openThread, open.compositeKey == targetKey {
                open.unread = false
                openThread = open
            }
            if folder == .unread {
                threads.removeAll { $0.compositeKey == targetKey }
            } else if let index = threads.firstIndex(where: { $0.compositeKey == targetKey }) {
                threads[index].unread = false
            }
        case .markUnread:
            if var open = openThread, open.compositeKey == targetKey {
                open.unread = true
                openThread = open
            }
            if let index = threads.firstIndex(where: { $0.compositeKey == targetKey }) {
                threads[index].unread = true
            }
        }
    }

    // MARK: - Reply & Compose

    static func replyTargetMessage(in thread: RemoteMailV2Thread) -> RemoteMailV2Message? {
        thread.messages.last(where: { !$0.isDraft }) ?? thread.messages.last
    }

    /// Resolves the exact reply recipient(s) and subject matching Mac `MailComposition.answering`.
    func replyPreview(for thread: RemoteMailV2Thread) -> ReplyPreview {
        let target = Self.replyTargetMessage(in: thread)
        let accountEmail = mailAccounts.first(where: {
            $0.id.caseInsensitiveCompare(thread.accountId) == .orderedSame
        })?.email
        let isMe: (String) -> Bool = { email in
            guard let accountEmail, !accountEmail.isEmpty else { return false }
            return email.caseInsensitiveCompare(accountEmail) == .orderedSame
        }

        let recipients: [RemoteMailV2Address]
        if let target {
            if isMe(target.from.email) {
                var seen: Set<String> = []
                let nonSelfTo = target.to.filter { addr in
                    !isMe(addr.email) && seen.insert(addr.email.lowercased()).inserted
                }
                recipients = nonSelfTo.isEmpty ? target.to : nonSelfTo
            } else {
                recipients = [target.from]
            }
        } else {
            recipients = []
        }

        let formattedRecipients = recipients.map(Self.formattedAddress).joined(separator: ", ")
        let baseSubject = (target?.subject.isEmpty == false ? target?.subject : nil) ?? thread.subject
        return ReplyPreview(
            recipientsDisplay: formattedRecipients,
            subjectDisplay: Self.prefixedReplySubject(baseSubject),
            replyToMessageId: target?.id
        )
    }

    @discardableResult
    func sendReply(body: String) async -> Bool {
        guard mailReady, !mailBusy, let thread = openThread else { return false }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            mailActionError = String(localized: "Write a reply first.")
            return false
        }
        guard body.count <= RemoteMailCalendarV2Limits.maxSendBodyCharacters else {
            mailActionError = String(localized: "Message body must be \(RemoteMailCalendarV2Limits.maxSendBodyCharacters) characters or fewer.")
            return false
        }

        let target = Self.replyTargetMessage(in: thread)
        let request = RemoteMailCalendarV2Request(
            action: .replyMessage,
            accountId: thread.accountId,
            body: body,
            replyToThreadId: thread.threadId,
            replyToMessageId: target?.id
        )
        if let validationError = request.validationError {
            mailActionError = handleError(validationError)
            return false
        }

        mailBusy = true
        mailActionError = nil
        defer { mailBusy = false }

        do {
            _ = try await session.sendMailCalendarV2(request)
            mailBanner = String(localized: "Reply sent")
            reloadOpenThread(accountId: thread.accountId, threadId: thread.threadId, clearExisting: false)
            loadThreads(clearExisting: false)
            return true
        } catch {
            mailActionError = handleError(error)
            return false
        }
    }

    static func parseRecipients(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func validateCompose(accountId: String?, toRaw: String, ccRaw: String, subject: String, body: String) -> String? {
        guard let accountId, !accountId.isEmpty else {
            return String(localized: "Choose an account to send from.")
        }
        let toList = Self.parseRecipients(toRaw)
        guard !toList.isEmpty else {
            return String(localized: "Add at least one recipient.")
        }
        if toList.count > RemoteMailCalendarV2Limits.maxSendRecipients {
            return String(localized: "You can send to at most \(RemoteMailCalendarV2Limits.maxSendRecipients) recipients.")
        }
        let ccList = Self.parseRecipients(ccRaw)
        if ccList.count > RemoteMailCalendarV2Limits.maxSendRecipients {
            return String(localized: "You can include at most \(RemoteMailCalendarV2Limits.maxSendRecipients) CC recipients.")
        }
        if subject.count > RemoteMailCalendarV2Limits.maxSubjectCharacters {
            return String(localized: "Subject must be \(RemoteMailCalendarV2Limits.maxSubjectCharacters) characters or fewer.")
        }
        if body.count > RemoteMailCalendarV2Limits.maxSendBodyCharacters {
            return String(localized: "Message body must be \(RemoteMailCalendarV2Limits.maxSendBodyCharacters) characters or fewer.")
        }
        let request = RemoteMailCalendarV2Request(
            action: .sendMessage,
            accountId: accountId,
            to: toList,
            cc: ccList.isEmpty ? nil : ccList,
            subject: subject,
            body: body
        )
        if let validationError = request.validationError {
            return HostSession.message(for: validationError, host: session.name)
        }
        return nil
    }

    @discardableResult
    func sendNewMessage(accountId: String, toRaw: String, ccRaw: String, subject: String, body: String) async -> Bool {
        guard mailReady, !mailBusy else { return false }
        if let validationMessage = validateCompose(accountId: accountId, toRaw: toRaw, ccRaw: ccRaw, subject: subject, body: body) {
            mailActionError = validationMessage
            return false
        }
        let toList = Self.parseRecipients(toRaw)
        let ccList = Self.parseRecipients(ccRaw)
        let request = RemoteMailCalendarV2Request(
            action: .sendMessage,
            accountId: accountId,
            to: toList,
            cc: ccList.isEmpty ? nil : ccList,
            subject: subject,
            body: body
        )

        mailBusy = true
        mailActionError = nil
        defer { mailBusy = false }

        do {
            _ = try await session.sendMailCalendarV2(request)
            mailBanner = String(localized: "Message sent")
            loadThreads(clearExisting: false)
            return true
        } catch {
            mailActionError = handleError(error)
            return false
        }
    }

    // MARK: - Calendar Actions

    var weekDays: [Date] {
        let cal = Calendar.current
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStartDate) }
    }

    func activateCalendarTab() {
        guard session.isConnected, session.capabilities.mailCalendarV2 else { return }
        if v2State == nil {
            guard !stateLoading else { return }
            Task {
                await refreshState()
                if calendarReady && !hasLoadedCalendarOnce && !calendarLoading {
                    loadCalendar(clearEvents: true)
                }
            }
        } else if calendarReady && !hasLoadedCalendarOnce && !calendarLoading {
            loadCalendar(clearEvents: true)
        }
    }

    func selectDate(_ date: Date) {
        let cal = Calendar.current
        let normalized = cal.startOfDay(for: date)
        selectedDate = normalized
        let targetWeekStart = Self.startOfWeek(containing: normalized, calendar: cal)
        if !cal.isDate(targetWeekStart, inSameDayAs: weekStartDate) {
            weekStartDate = targetWeekStart
            loadCalendar(clearEvents: true)
        }
    }

    func moveWeek(by delta: Int) {
        let cal = Calendar.current
        guard let nextWeek = cal.date(byAdding: .day, value: delta * 7, to: weekStartDate),
              let nextSelected = cal.date(byAdding: .day, value: delta * 7, to: selectedDate) else { return }
        weekStartDate = cal.startOfDay(for: nextWeek)
        selectedDate = cal.startOfDay(for: nextSelected)
        loadCalendar(clearEvents: true)
    }

    func selectToday() {
        selectDate(Date())
    }

    func selectCalendar(_ key: String?) {
        guard key != selectedCalendarKey else { return }
        selectedCalendarKey = key
        loadCalendar(clearEvents: true)
    }

    func refreshCalendar() async {
        guard session.isConnected, session.capabilities.mailCalendarV2 else { return }
        await refreshState()
        guard calendarReady else { return }
        await performLoadCalendar(clearEvents: false)
    }

    func loadCalendar(clearEvents: Bool) {
        guard calendarReady else { return }
        calendarTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoadCalendar(clearEvents: clearEvents)
        }
        calendarTask = task
    }

    private func performLoadCalendar(clearEvents: Bool) async {
        guard calendarReady else { return }
        calendarGeneration += 1
        let generation = calendarGeneration

        if clearEvents {
            events = []
            eventsTruncated = false
        }
        calendarError = nil
        calendarLoading = true

        // 1. Load calendars (needed for filter chips and resolving selectedCalendarKey -> accountId/calendarId).
        var currentCalendars = calendars
        do {
            let calResponse = try await session.sendMailCalendarV2(
                RemoteMailCalendarV2Request(action: .listCalendars)
            )
            guard !Task.isCancelled, calendarGeneration == generation else { return }
            currentCalendars = Self.deduplicateCalendars(calResponse.calendars ?? [])
            calendars = currentCalendars
            if let key = selectedCalendarKey, !currentCalendars.contains(where: { $0.compositeKey == key }) {
                selectedCalendarKey = nil
            }
        } catch {
            guard !Task.isCancelled, calendarGeneration == generation else { return }
            calendarLoading = false
            calendarError = handleError(error)
            return
        }

        // 2. Load events for the visible week padded by 1 day on each edge to avoid timezone boundary misses
        // for all-day events while remaining well within the 62-day protocol limit.
        let localCal = Calendar.current
        let windowStart = localCal.date(byAdding: .day, value: -1, to: weekStartDate) ?? weekStartDate
        let windowEnd = localCal.date(byAdding: .day, value: 8, to: weekStartDate) ?? weekStartDate.addingTimeInterval(8 * 86_400)
        let startMs = Int64((windowStart.timeIntervalSince1970 * 1_000).rounded(.down))
        let endMs = Int64((windowEnd.timeIntervalSince1970 * 1_000).rounded(.down))

        let selectedCalendar = selectedCalendarKey.flatMap { key in
            currentCalendars.first(where: { $0.compositeKey == key })
        }

        let eventsRequest = RemoteMailCalendarV2Request(
            action: .listEvents,
            accountId: selectedCalendar?.accountId,
            startMs: startMs,
            endMs: endMs,
            calendarId: selectedCalendar?.id
        )

        do {
            let response = try await session.sendMailCalendarV2(eventsRequest)
            guard !Task.isCancelled, calendarGeneration == generation else { return }
            events = Self.deduplicateEvents(response.events ?? [])
            eventsTruncated = response.eventsTruncated == true
            calendarLoading = false
            hasLoadedCalendarOnce = true
        } catch {
            guard !Task.isCancelled, calendarGeneration == generation else { return }
            calendarLoading = false
            calendarError = handleError(error)
        }
    }

    @discardableResult
    func respondToEvent(_ event: RemoteCalendarV2Event, response invitationResponse: RemoteCalendarV2InvitationResponse) async -> Bool {
        guard calendarReady, event.canRespond, rsvpBusyKey == nil else { return false }
        let key = event.compositeKey
        rsvpBusyKey = key
        calendarActionError = nil
        defer { rsvpBusyKey = nil }

        let request = RemoteMailCalendarV2Request(
            action: .respondEvent,
            accountId: event.accountId,
            calendarId: event.calendarId,
            eventId: event.id,
            occurrenceMs: event.occurrenceMs,
            response: invitationResponse
        )

        do {
            _ = try await session.sendMailCalendarV2(request)
            let updatedStatus: RemoteCalendarV2ResponseStatus = switch invitationResponse {
            case .accepted: .accepted
            case .tentative: .tentative
            case .declined: .declined
            }
            if let index = events.firstIndex(where: { $0.compositeKey == key }) {
                events[index].responseStatus = updatedStatus
            }
            loadCalendar(clearEvents: false)
            return true
        } catch {
            calendarActionError = handleError(error)
            return false
        }
    }

    // MARK: - Calendar Date Bucketing

    /// Events overlapping `day`: Gregorian ISO `"YYYY-MM-DD"` (`startDate` inclusive, `endDate` exclusive)
    /// for all-day events, and local timezone day overlap (including 0-duration events `endMs <= startMs`
    /// at exact midnight) for timed events.
    func events(on day: Date) -> [RemoteCalendarV2Event] {
        Self.events(events, on: day)
    }

    func hasEvents(on day: Date) -> Bool {
        !events(on: day).isEmpty
    }

    static func events(
        _ allEvents: [RemoteCalendarV2Event],
        on day: Date,
        calendar: Calendar = .current
    ) -> [RemoteCalendarV2Event] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let dayStartMs = Int64((dayStart.timeIntervalSince1970 * 1_000).rounded(.down))
        let dayEndMs = Int64((dayEnd.timeIntervalSince1970 * 1_000).rounded(.down))
        let dayISO = localISODateString(dayStart, timeZone: calendar.timeZone)

        return allEvents
            .filter { event in
                if event.allDay, let startISO = event.startDate, !startISO.isEmpty {
                    if let endISO = event.endDate, !endISO.isEmpty, endISO > startISO {
                        return dayISO >= startISO && dayISO < endISO
                    }
                    return dayISO == startISO
                }
                if event.endMs <= event.startMs {
                    return event.startMs >= dayStartMs && event.startMs < dayEndMs
                }
                return event.startMs < dayEndMs && event.endMs > dayStartMs
            }
            .sorted { lhs, rhs in
                if lhs.allDay != rhs.allDay { return lhs.allDay }
                if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    static func localISODateString(_ date: Date, timeZone: TimeZone = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Formats an all-day event's ISO date span (`startDate` inclusive, `endDate` exclusive) for display.
    static func allDayRangeLabel(startDate: String?, endDate: String?) -> String {
        let allDay = String(localized: "All day")
        guard let startDate, !startDate.isEmpty else { return allDay }
        if let endDate, !endDate.isEmpty, endDate > startDate,
           let inclusiveEnd = previousISODate(endDate), inclusiveEnd > startDate {
            return "\(startDate) – \(inclusiveEnd) · \(allDay)"
        }
        return "\(startDate) · \(allDay)"
    }

    private static func previousISODate(_ iso: String) -> String? {
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let date = gregorian.date(from: DateComponents(year: year, month: month, day: day)),
              let previous = gregorian.date(byAdding: .day, value: -1, to: date) else { return nil }
        let prevParts = gregorian.dateComponents([.year, .month, .day], from: previous)
        return String(format: "%04d-%02d-%02d", prevParts.year ?? year, prevParts.month ?? month, prevParts.day ?? day)
    }

    static func startOfWeek(containing date: Date, calendar: Calendar = .current) -> Date {
        if let interval = calendar.dateInterval(of: .weekOfYear, for: date) {
            return calendar.startOfDay(for: interval.start)
        }
        return calendar.startOfDay(for: date)
    }

    // MARK: - Safe Meeting URL Validation

    /// Strictly validates meeting URLs: `https://` with non-empty host and no embedded credentials.
    static func safeMeetingURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return components.url
    }

    // MARK: - Formatting & Helpers

    static func formattedAddress(_ address: RemoteMailV2Address) -> String {
        let name = address.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty && !address.email.isEmpty {
            return "\(name) <\(address.email)>"
        }
        return !name.isEmpty ? name : address.email
    }

    static func senderDisplayName(name: String?, email: String) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? email : trimmed
    }

    static func prefixedReplySubject(_ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return String(localized: "(No subject)") }
        if trimmed.lowercased().hasPrefix("re:") { return trimmed }
        return "Re: \(trimmed)"
    }

    static func formatAttachmentSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .file)
    }

    static func calendarColor(hex: String?) -> Color {
        guard var cleaned = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else {
            return YardletPalette.onSurfaceVariant
        }
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return YardletPalette.onSurfaceVariant
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    // MARK: - Deduplication & Error Handling

    private static func deduplicateThreads(_ list: [RemoteMailV2ThreadSummary]) -> [RemoteMailV2ThreadSummary] {
        var seen: Set<String> = []
        var result: [RemoteMailV2ThreadSummary] = []
        result.reserveCapacity(list.count)
        for item in list where seen.insert(item.compositeKey).inserted {
            result.append(item)
        }
        return result
    }

    private static func deduplicateCalendars(_ list: [RemoteCalendarV2Calendar]) -> [RemoteCalendarV2Calendar] {
        var seen: Set<String> = []
        var result: [RemoteCalendarV2Calendar] = []
        result.reserveCapacity(list.count)
        for item in list where seen.insert(item.compositeKey).inserted {
            result.append(item)
        }
        return result
    }

    private static func deduplicateEvents(_ list: [RemoteCalendarV2Event]) -> [RemoteCalendarV2Event] {
        var seen: Set<String> = []
        var result: [RemoteCalendarV2Event] = []
        result.reserveCapacity(list.count)
        for item in list where seen.insert(item.compositeKey).inserted {
            result.append(item)
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func handleError(_ error: Error) -> String {
        if let remoteError = error as? RemoteError {
            if remoteError.code == .notAllowed {
                revokePermissionAndClearAll()
            }
            return HostSession.message(for: remoteError, host: session.name)
        }
        return HostSession.message(for: nil, host: session.name)
    }
}
