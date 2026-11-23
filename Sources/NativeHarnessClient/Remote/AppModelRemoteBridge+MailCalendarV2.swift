import Foundation
import YardletRemote

/// Cross-platform `mailCalendarV2` host bridge handlers.
///
/// Serves structured JSON DTOs (Unix epoch millisecond `Int64` timestamps and explicit string enums) for mobile and
/// non-Mac remote clients while leaving the legacy Mac-to-Mac `mail`/`calendar` wire format intact.
extension AppModelRemoteBridge {
    func mailCalendarV2State(permitted: Bool) -> RemoteMailCalendarV2State {
        guard let model else { return RemoteMailCalendarV2State() }
        // Reuse the existing observation wiring so `mailCalendarChanged` fires on enablement or account changes.
        _ = mailCalendarState()
        let mailEnabled = model.mailbox.isEnabled
        let calendarEnabled = model.calendar.isEnabled
        let mailConnected = mailEnabled && !model.mailbox.accounts.isEmpty
        let calendarConnected = calendarEnabled && !model.calendar.accounts.isEmpty

        guard permitted else {
            return RemoteMailCalendarV2State(
                mailConnected: mailConnected,
                calendarConnected: calendarConnected,
                mailEnabled: mailEnabled,
                calendarEnabled: calendarEnabled,
                permitted: false,
                mailAccounts: [],
                calendarAccounts: []
            )
        }

        let mailAccounts: [RemoteMailV2Account] = mailEnabled
            ? model.mailbox.accounts.map { account in
                let unread = model.mailbox.folders[account.id]?.first(where: { $0.role == .inbox })?.unreadCount
                    ?? model.mailbox.inboxes[account.id]?.filter(\.isUnread).count
                return Self.mapMailAccount(account, unreadCount: unread)
            }
            : []

        let calendarAccounts: [RemoteCalendarV2Account] = calendarEnabled
            ? model.calendar.accounts.map(Self.mapCalendarAccount)
            : []

        return RemoteMailCalendarV2State(
            mailConnected: mailConnected,
            calendarConnected: calendarConnected,
            mailEnabled: mailEnabled,
            calendarEnabled: calendarEnabled,
            permitted: true,
            mailAccounts: mailAccounts,
            calendarAccounts: calendarAccounts
        )
    }

    func mailCalendarV2(_ request: RemoteMailCalendarV2Request) async -> Result<RemoteMailCalendarV2Response, RemoteError> {
        if let error = request.validationError {
            return .failure(error)
        }
        switch request.action {
        case .listThreads:
            return await mailV2ListThreads(request)
        case .readThread:
            return await mailV2ReadThread(request)
        case .readMessage:
            return await mailV2ReadMessage(request)
        case .updateMessage:
            return await mailV2UpdateMessage(request)
        case .sendMessage:
            return await mailV2SendMessage(request)
        case .replyMessage:
            return await mailV2ReplyMessage(request)
        case .listCalendars:
            return await calendarV2ListCalendars(request)
        case .listEvents:
            return await calendarV2ListEvents(request)
        case .respondEvent:
            return await calendarV2RespondEvent(request)
        }
    }

    // MARK: - Mail V2 Operations

    private func mailV2ListThreads(_ request: RemoteMailCalendarV2Request) async -> Result<RemoteMailCalendarV2Response, RemoteError> {
        guard let center = model?.mailbox, center.isEnabled else {
            return .failure(RemoteError(.unavailable, "The mailbox is off on this Mac"))
        }
        let limit = min(max(request.limit ?? RemoteMailCalendarV2Limits.defaultListLimit, 1), RemoteMailCalendarV2Limits.maxListLimit)
        let folder = request.folder ?? .inbox
        let trimmedQuery = request.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = trimmedQuery?.isEmpty == false ? trimmedQuery : nil

        let targets: [(MailAccount, any MailAccountTransport)]
        if let accountIdString = request.accountId {
            guard let uuid = UUID(uuidString: accountIdString),
                  let account = center.account(uuid),
                  let transport = center.transport(for: uuid) else {
                return .failure(RemoteError(.notFound, "No such mail account"))
            }
            targets = [(account, transport)]
        } else {
            targets = center.accounts.compactMap { account in
                center.transport(for: account.id).map { (account, $0) }
            }
        }

        if targets.isEmpty {
            return .success(RemoteMailCalendarV2Response(threads: [], nextPageToken: nil))
        }

        if targets.count == 1 {
            let (account, transport) = targets[0]
            let cachedFolders = center.folders[account.id]
            do {
                let page = try await Self.fetchMailPage(
                    transport: transport,
                    cachedFolders: cachedFolders,
                    folder: folder,
                    query: query,
                    pageToken: Self.nonEmpty(request.pageToken)
                )
                let summaries = page.threads.prefix(limit).map(Self.mapThreadSummary)
                // Never emit a transport pageToken that skips past items truncated by `limit`.
                let nextToken = page.threads.count > limit ? nil : page.nextPageToken
                return .success(RemoteMailCalendarV2Response(threads: Array(summaries), nextPageToken: nextToken))
            } catch let error as RemoteError {
                return .failure(error)
            } catch is CancellationError {
                return .failure(RemoteError(.unavailable, "Request cancelled"))
            } catch {
                return .failure(Self.mapMailError(error))
            }
        }

        if Self.nonEmpty(request.pageToken) != nil {
            return .failure(RemoteError(.badRequest, "pageToken requires accountId when multiple accounts are connected"))
        }

        // Multiple accounts: fetch in parallel, merge newest-first, and slice to `limit`.
        let cachedByAccount = center.folders
        let merged = await Self.fetchMultiAccountMailPages(
            targets: targets,
            cachedByAccount: cachedByAccount,
            folder: folder,
            query: query,
            limit: limit
        )
        if !merged.anySucceeded, let firstError = merged.firstError {
            if firstError is CancellationError {
                return .failure(RemoteError(.unavailable, "Request cancelled"))
            }
            return .failure(Self.mapMailError(firstError))
        }
        return .success(RemoteMailCalendarV2Response(threads: merged.summaries, nextPageToken: nil))
    }

    private nonisolated static func fetchMultiAccountMailPages(
        targets: [(MailAccount, any MailAccountTransport)],
        cachedByAccount: [UUID: [MailFolder]],
        folder: RemoteMailV2Folder,
        query: String?,
        limit: Int
    ) async -> (summaries: [RemoteMailV2ThreadSummary], firstError: Error?, anySucceeded: Bool) {
        var allSummaries: [MailThreadSummary] = []
        var firstError: Error?
        var anySucceeded = false
        await withTaskGroup(of: Result<MailPage, Error>.self) { group in
            for (account, transport) in targets {
                let cachedFolders = cachedByAccount[account.id]
                group.addTask {
                    do {
                        return .success(try await Self.fetchMailPage(
                            transport: transport,
                            cachedFolders: cachedFolders,
                            folder: folder,
                            query: query,
                            pageToken: nil
                        ))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case let .success(page):
                    anySucceeded = true
                    allSummaries += page.threads
                case let .failure(error):
                    if firstError == nil { firstError = error }
                }
            }
        }
        allSummaries.sort { $0.date > $1.date }
        return (allSummaries.prefix(limit).map(Self.mapThreadSummary), firstError, anySucceeded)
    }

    private nonisolated static func fetchMailPage(
        transport: any MailAccountTransport,
        cachedFolders: [MailFolder]?,
        folder: RemoteMailV2Folder,
        query: String?,
        pageToken: String?
    ) async throws -> MailPage {
        if let query {
            var page = try await transport.search(query, pageToken: pageToken)
            switch folder {
            case .unread:
                page.threads = page.threads.filter(\.isUnread)
            case .starred:
                page.threads = page.threads.filter(\.isStarred)
            default:
                break
            }
            return page
        }
        switch folder {
        case .inbox:
            return try await transport.inbox(pageToken: pageToken)
        case .unread:
            var page = try await transport.inbox(pageToken: pageToken)
            page.threads = page.threads.filter(\.isUnread)
            return page
        case .starred, .sent, .drafts, .archive, .trash, .spam:
            let role = Self.mapFolderRole(folder)
            let folders: [MailFolder]
            if let cachedFolders, !cachedFolders.isEmpty {
                folders = cachedFolders
            } else {
                folders = try await transport.folders()
            }
            guard let targetFolder = folders.first(where: { $0.role == role }) else {
                return MailPage(threads: [], nextPageToken: nil)
            }
            return try await transport.list(targetFolder, pageToken: pageToken)
        }
    }

    private func mailV2ReadThread(_ request: RemoteMailCalendarV2Request) async -> Result<RemoteMailCalendarV2Response, RemoteError> {
        guard let center = model?.mailbox, center.isEnabled else {
            return .failure(RemoteError(.unavailable, "The mailbox is off on this Mac"))
        }
        guard let accountIdString = request.accountId,
              let accountID = UUID(uuidString: accountIdString),
              let transport = center.account(accountID).flatMap({ center.transport(for: $0.id) }) else {
            return .failure(RemoteError(.notFound, "No such mail account"))
        }
        guard let threadID = request.threadId, !threadID.isEmpty else {
            return .failure(RemoteError(.badRequest, "Missing threadId"))
        }
        do {
            let thread = try await transport.thread(threadID)
            return .success(RemoteMailCalendarV2Response(thread: Self.mapThread(thread)))
        } catch let error as RemoteError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(RemoteError(.unavailable, "Request cancelled"))
        } catch {
            return .failure(Self.mapMailError(error))
        }
    }

    private func mailV2ReadMessage(_ request: RemoteMailCalendarV2Request) async -> Result<RemoteMailCalendarV2Response, RemoteError> {
        guard let center = model?.mailbox, center.isEnabled else {
            return .failure(RemoteError(.unavailable, "The mailbox is off on this Mac"))
        }
        guard let accountIdString = request.accountId,
              let accountID = UUID(uuidString: accountIdString),
              let transport = center.account(accountID).flatMap({ center.transport(for: $0.id) }) else {
            return .failure(RemoteError(.notFound, "No such mail account"))
        }
        let requestedThreadID = Self.nonEmpty(request.threadId)
        let requestedMessageID = Self.nonEmpty(request.messageId)
        guard let targetThreadID = requestedThreadID ?? requestedMessageID else {
            return .failure(RemoteError(.badRequest, "Missing threadId or messageId"))
        }
        do {
            let thread = try await transport.thread(targetThreadID)
            let mappedThread = Self.mapThread(thread)
            let targetMessage: RemoteMailV2Message?
            if let messageId = requestedMessageID {
                if let matched = thread.messages.first(where: { $0.id == messageId }) {
                    targetMessage = Self.mapMessage(matched, accountID: accountID, threadID: thread.summary.id.threadID)
                } else if requestedThreadID != nil {
                    return .failure(RemoteError(.notFound, "No such message in thread"))
                } else {
                    targetMessage = mappedThread.messages.last(where: { !$0.isDraft }) ?? mappedThread.messages.last
                }
            } else {
                targetMessage = mappedThread.messages.last(where: { !$0.isDraft }) ?? mappedThread.messages.last
            }
            guard let targetMessage else {
                return .failure(RemoteError(.notFound, "Thread has no messages"))
            }
            return .success(RemoteMailCalendarV2Response(thread: mappedThread, message: targetMessage))
        } catch let error as RemoteError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(RemoteError(.unavailable, "Request cancelled"))
        } catch {
            return .failure(Self.mapMailError(error))
        }
    }

    private func mailV2UpdateMessage(_ request: RemoteMailCalendarV2Request) async -> Result<RemoteMailCalendarV2Response, RemoteError> {
        guard let center = model?.mailbox, center.isEnabled else {
            return .failure(RemoteError(.unavailable, "The mailbox is off on this Mac"))
        }
        guard let accountIdString = request.accountId,
              let accountID = UUID(uuidString: accountIdString),
              center.account(accountID) != nil,
              center.transport(for: accountID) != nil else {
            return .failure(RemoteError(.notFound, "No such mail account"))
        }
        guard let threadID = Self.nonEmpty(request.threadId), let action = request.messageAction else {
            return .failure(RemoteError(.badRequest, "Missing threadId or messageAction"))
        }
        let change: MailThreadChange
        switch action {
        case .markRead: change = .read(true)
        case .markUnread: change = .read(false)
        case .archive: change = .archived
        case .star: change = .starred(true)
        case .unstar: change = .starred(false)
        case .trash:
            return .failure(RemoteError(.unsupportedCommand, "Moving threads to Trash is not supported by this host yet"))
        }
        do {
            try await center.apply(change, to: MailThreadKey(accountID: accountID, threadID: threadID))
            return .success(RemoteMailCalendarV2Response(updated: true, threadId: threadID))
        } catch let error as RemoteError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(RemoteError(.unavailable, "Request cancelled"))
        } catch {
            return .failure(Self.mapMailError(error))
        }
    }

    private func mailV2SendMessage(_ request: RemoteMailCalendarV2Request) async -> Result<RemoteMailCalendarV2Response, RemoteError> {
        guard let center = model?.mailbox, center.isEnabled else {
            return .failure(RemoteError(.unavailable, "The mailbox is off on this Mac"))
        }
        guard let accountIdString = request.accountId,
              let accountID = UUID(uuidString: accountIdString),
              center.account(accountID) != nil,
              let transport = center.transport(for: accountID) else {
            return .failure(RemoteError(.notFound, "No such mail account"))
        }
        let toList = (request.to ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !toList.isEmpty else {
            return .failure(RemoteError(.badRequest, "Missing recipients in to"))
        }
        let ccList = (request.cc ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let bccList = (request.bcc ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        let replyThreadID = Self.nonEmpty(request.replyToThreadId) ?? Self.nonEmpty(request.threadId)
        var inReplyTo: String?
        var references: String?
        var replyToMessageID = Self.nonEmpty(request.replyToMessageId)

        do {
            if let replyThreadID {
                let thread = try await transport.thread(replyThreadID)
                let target: MailMessage?
                if let explicitMessageID = replyToMessageID {
                    guard let matched = thread.messages.first(where: { $0.id == explicitMessageID }) else {
                        return .failure(RemoteError(.notFound, "No such message in thread"))
                    }
                    target = matched
                } else {
                    target = thread.messages.last(where: { !$0.isDraft }) ?? thread.messages.last
                }
                if let target {
                    replyToMessageID = replyToMessageID ?? target.id
                    inReplyTo = target.messageID
                    let refs = [target.references, target.messageID].compactMap { $0 }.joined(separator: " ")
                    references = refs.isEmpty ? nil : refs
                }
            }

            let isReply = replyThreadID != nil || replyToMessageID != nil
            var composition = MailComposition(
                accountID: accountID,
                kind: isReply ? .reply : .new,
                threadID: replyThreadID,
                to: toList.joined(separator: ", "),
                cc: ccList.joined(separator: ", "),
                bcc: bccList.joined(separator: ", "),
                subject: request.subject ?? "",
                body: request.body ?? "",
                inReplyTo: inReplyTo,
                references: references
            )
            composition.replyToMessageID = replyToMessageID

            let draftID = try await transport.saveDraft(composition)
            try await transport.sendDraft(draftID)
            await center.afterWriting(composition)
            return .success(RemoteMailCalendarV2Response(sent: true, threadId: replyThreadID))
        } catch let error as RemoteError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(RemoteError(.unavailable, "Request cancelled"))
        } catch {
            return .failure(Self.mapMailError(error))
        }
    }

    private func mailV2ReplyMessage(_ request: RemoteMailCalendarV2Request) async -> Result<RemoteMailCalendarV2Response, RemoteError> {
        guard let center = model?.mailbox, center.isEnabled else {
            return .failure(RemoteError(.unavailable, "The mailbox is off on this Mac"))
        }
        guard let accountIdString = request.accountId,
              let accountID = UUID(uuidString: accountIdString),
              let account = center.account(accountID),
              let transport = center.transport(for: accountID) else {
            return .failure(RemoteError(.notFound, "No such mail account"))
        }
        guard let threadID = Self.nonEmpty(request.replyToThreadId) ?? Self.nonEmpty(request.threadId) else {
            return .failure(RemoteError(.badRequest, "Missing replyToThreadId"))
        }
        guard let body = request.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(RemoteError(.badRequest, "Missing reply body"))
        }
        do {
            let thread = try await transport.thread(threadID)
            let target: MailMessage
            if let messageId = Self.nonEmpty(request.replyToMessageId) {
                guard let found = thread.messages.first(where: { $0.id == messageId }) else {
                    return .failure(RemoteError(.notFound, "No such message in thread"))
                }
                target = found
            } else if let latest = thread.messages.last(where: { !$0.isDraft }) ?? thread.messages.last {
                target = latest
            } else {
                return .failure(RemoteError(.notFound, "Thread has no messages to reply to"))
            }

            var composition = MailComposition.answering(target, in: thread, as: .reply, from: account)
            if let to = request.to {
                let cleaned = to.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !cleaned.isEmpty { composition.to = cleaned.joined(separator: ", ") }
            }
            if let cc = request.cc {
                let cleaned = cc.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                composition.cc = cleaned.joined(separator: ", ")
            }
            if let bcc = request.bcc {
                let cleaned = bcc.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                composition.bcc = cleaned.joined(separator: ", ")
            }
            if let subject = request.subject?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty {
                composition.subject = subject
            }
            composition.body = body

            guard !composition.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(RemoteError(.badRequest, "Reply has no recipients"))
            }

            let draftID = try await transport.saveDraft(composition)
            try await transport.sendDraft(draftID)
            await center.afterWriting(composition)
            return .success(RemoteMailCalendarV2Response(sent: true, threadId: threadID))
        } catch let error as RemoteError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(RemoteError(.unavailable, "Request cancelled"))
        } catch {
            return .failure(Self.mapMailError(error))
        }
    }

    // MARK: - Calendar V2 Operations

    private func calendarV2ListCalendars(_ request: RemoteMailCalendarV2Request) async -> Result<RemoteMailCalendarV2Response, RemoteError> {
        guard let center = model?.calendar, center.isEnabled else {
            return .failure(RemoteError(.unavailable, "The calendar is off on this Mac"))
        }
        let targetAccounts: [(CalendarAccount, any CalendarAccountTransport)]
        if let accountIdString = request.accountId {
            guard let uuid = UUID(uuidString: accountIdString),
                  let account = center.account(uuid),
                  let transport = center.transport(for: uuid) else {
                return .failure(RemoteError(.notFound, "No such calendar account"))
            }
            targetAccounts = [(account, transport)]
        } else {
            targetAccounts = center.accounts.compactMap { account in
                center.transport(for: account.id).map { (account, $0) }
            }
        }

        if targetAccounts.isEmpty {
            return .success(RemoteMailCalendarV2Response(calendars: []))
        }

        let (calendarsByAccount, failedAccounts, firstError) = await Self.loadCalendars(
            for: targetAccounts,
            cached: center.accountCalendars
        )
        if calendarsByAccount.isEmpty, let firstError {
            return .failure(Self.mapCalendarError(firstError))
        }

        let copies = CalendarCenter.copies(in: targetAccounts.map(\.0), calendars: calendarsByAccount)
        var result: [RemoteCalendarV2Calendar] = []
        for (account, _) in targetAccounts {
            for cal in calendarsByAccount[account.id] ?? [] {
                if let direct = copies[cal.id], !failedAccounts.contains(direct.accountID) { continue }
                result.append(Self.mapCalendar(cal, account: account, visible: center.isShown(cal)))
            }
        }
        return .success(RemoteMailCalendarV2Response(calendars: result))
    }

    private func calendarV2ListEvents(_ request: RemoteMailCalendarV2Request) async -> Result<RemoteMailCalendarV2Response, RemoteError> {
        guard let center = model?.calendar, center.isEnabled else {
            return .failure(RemoteError(.unavailable, "The calendar is off on this Mac"))
        }
        guard let startMs = request.startMs, let endMs = request.endMs, startMs < endMs else {
            return .failure(RemoteError(.badRequest, "listEvents requires startMs < endMs"))
        }
        let startDate = Date(timeIntervalSince1970: Double(startMs) / 1_000.0)
        let endDate = Date(timeIntervalSince1970: Double(endMs) / 1_000.0)
        let range = DateInterval(start: startDate, end: endDate)

        let targetAccounts: [(CalendarAccount, any CalendarAccountTransport)]
        if let accountIdString = request.accountId {
            guard let uuid = UUID(uuidString: accountIdString),
                  let account = center.account(uuid),
                  let transport = center.transport(for: uuid) else {
                return .failure(RemoteError(.notFound, "No such calendar account"))
            }
            targetAccounts = [(account, transport)]
        } else {
            targetAccounts = center.accounts.compactMap { account in
                center.transport(for: account.id).map { (account, $0) }
            }
        }

        if targetAccounts.isEmpty {
            return .success(RemoteMailCalendarV2Response(events: []))
        }

        let (calendarsByAccount, failedAccounts, firstCalendarError) = await Self.loadCalendars(
            for: targetAccounts,
            cached: center.accountCalendars
        )
        if calendarsByAccount.isEmpty, let firstCalendarError {
            return .failure(Self.mapCalendarError(firstCalendarError))
        }

        let copies = CalendarCenter.copies(in: targetAccounts.map(\.0), calendars: calendarsByAccount)
        let requestedCalendarID = Self.nonEmpty(request.calendarId)

        var targetCalendars: [(CalendarAccount, CalendarInfo, any CalendarAccountTransport)] = []
        for (account, transport) in targetAccounts {
            for cal in calendarsByAccount[account.id] ?? [] {
                if let requestedCalendarID {
                    guard cal.id.calendarID == requestedCalendarID else { continue }
                    targetCalendars.append((account, cal, transport))
                } else {
                    if let direct = copies[cal.id], !failedAccounts.contains(direct.accountID) { continue }
                    guard center.isShown(cal) else { continue }
                    targetCalendars.append((account, cal, transport))
                }
            }
        }

        if requestedCalendarID != nil, targetCalendars.isEmpty {
            return .failure(RemoteError(.notFound, "No such calendar"))
        }
        if targetCalendars.isEmpty {
            return .success(RemoteMailCalendarV2Response(events: []))
        }

        let result = await Self.fetchCalendarEvents(
            targetCalendars: targetCalendars,
            range: range,
            hostCalendar: Calendar.autoupdatingCurrent
        )
        if !result.anySucceeded, let firstEventError = result.firstError {
            if firstEventError is CancellationError {
                return .failure(RemoteError(.unavailable, "Request cancelled"))
            }
            return .failure(Self.mapCalendarError(firstEventError))
        }
        return .success(RemoteMailCalendarV2Response(
            events: result.events,
            eventsTruncated: result.truncated ? true : nil
        ))
    }

    private nonisolated static func fetchCalendarEvents(
        targetCalendars: [(CalendarAccount, CalendarInfo, any CalendarAccountTransport)],
        range: DateInterval,
        hostCalendar: Calendar
    ) async -> (events: [RemoteCalendarV2Event], truncated: Bool, firstError: Error?, anySucceeded: Bool) {
        var collected: [RemoteCalendarV2Event] = []
        var firstEventError: Error?
        var anySucceeded = false
        await withTaskGroup(of: Result<[RemoteCalendarV2Event], Error>.self) { group in
            for (account, info, transport) in targetCalendars {
                group.addTask {
                    do {
                        let events = try await transport.events(in: info, from: range.start, to: range.end)
                        let mapped = events
                            .filter { $0.overlaps(range) }
                            .map { Self.mapEvent($0, calendar: info, account: account, hostCalendar: hostCalendar) }
                        return .success(mapped)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case let .success(events):
                    anySucceeded = true
                    collected += events
                case let .failure(error):
                    if firstEventError == nil { firstEventError = error }
                }
            }
        }
        collected.sort { lhs, rhs in
            if lhs.startMs != rhs.startMs { return lhs.startMs < rhs.startMs }
            if lhs.allDay != rhs.allDay { return lhs.allDay }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        let truncated = collected.count > RemoteMailCalendarV2Limits.maxEvents
        let bounded = truncated ? Array(collected.prefix(RemoteMailCalendarV2Limits.maxEvents)) : collected
        return (bounded, truncated, firstEventError, anySucceeded)
    }

    private func calendarV2RespondEvent(_ request: RemoteMailCalendarV2Request) async -> Result<RemoteMailCalendarV2Response, RemoteError> {
        guard let center = model?.calendar, center.isEnabled else {
            return .failure(RemoteError(.unavailable, "The calendar is off on this Mac"))
        }
        guard let calendarID = Self.nonEmpty(request.calendarId),
              let eventID = Self.nonEmpty(request.eventId),
              let response = request.response else {
            return .failure(RemoteError(.badRequest, "respondEvent requires calendarId, eventId and response"))
        }

        let targetAccount: CalendarAccount
        if let accountIdString = Self.nonEmpty(request.accountId) {
            guard let uuid = UUID(uuidString: accountIdString), let account = center.account(uuid) else {
                return .failure(RemoteError(.notFound, "No such calendar account"))
            }
            targetAccount = account
        } else {
            let candidates = center.accounts.compactMap { account in
                center.transport(for: account.id).map { (account, $0) }
            }
            let (calendarsByAccount, _, firstError) = await Self.loadCalendars(
                for: candidates,
                cached: center.accountCalendars
            )
            let matchingAccounts = center.accounts.filter { account in
                (calendarsByAccount[account.id] ?? []).contains(where: { $0.id.calendarID == calendarID })
            }
            if matchingAccounts.isEmpty {
                if let firstError {
                    if firstError is CancellationError {
                        return .failure(RemoteError(.unavailable, "Request cancelled"))
                    }
                    return .failure(Self.mapCalendarError(firstError))
                }
                return .failure(RemoteError(.notFound, "No calendar found with that calendarId"))
            }
            if matchingAccounts.count > 1 {
                return .failure(RemoteError(.badRequest, "Multiple accounts have that calendarId; specify accountId"))
            }
            targetAccount = matchingAccounts[0]
        }

        guard targetAccount.provider.answersInvitations else {
            return .failure(RemoteError(.badRequest, "This calendar account does not support answering invitations"))
        }

        let occurrence = request.occurrenceMs.map { Date(timeIntervalSince1970: Double($0) / 1_000.0) }
        let placeholderDate = occurrence ?? Date()
        let event = CalendarEvent(
            id: CalendarEventKey(
                calendar: CalendarKey(accountID: targetAccount.id, calendarID: calendarID),
                eventID: eventID,
                occurrence: occurrence
            ),
            title: "",
            start: placeholderDate,
            end: placeholderDate,
            isAllDay: false
        )
        let mappedResponse: CalendarResponse = switch response {
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        }
        do {
            try await center.respond(to: event, mappedResponse)
            return .success(RemoteMailCalendarV2Response(responded: true))
        } catch let error as RemoteError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(RemoteError(.unavailable, "Request cancelled"))
        } catch {
            return .failure(Self.mapCalendarError(error))
        }
    }

    private nonisolated static func loadCalendars(
        for accounts: [(CalendarAccount, any CalendarAccountTransport)],
        cached: [UUID: [CalendarInfo]]
    ) async -> (calendars: [UUID: [CalendarInfo]], failed: Set<UUID>, firstError: Error?) {
        var result: [UUID: [CalendarInfo]] = [:]
        var toFetch: [(CalendarAccount, any CalendarAccountTransport)] = []
        for (account, transport) in accounts {
            if let existing = cached[account.id], !existing.isEmpty {
                result[account.id] = existing
            } else {
                toFetch.append((account, transport))
            }
        }
        if toFetch.isEmpty { return (result, [], nil) }

        var failed: Set<UUID> = []
        var firstError: Error?
        await withTaskGroup(of: (UUID, Result<[CalendarInfo], Error>).self) { group in
            for (account, transport) in toFetch {
                group.addTask {
                    do {
                        return (account.id, .success(try await transport.calendars()))
                    } catch {
                        return (account.id, .failure(error))
                    }
                }
            }
            for await (id, outcome) in group {
                switch outcome {
                case let .success(list):
                    result[id] = list
                case let .failure(error):
                    failed.insert(id)
                    if firstError == nil { firstError = error }
                }
            }
        }
        return (result, failed, firstError)
    }

    // MARK: - DTO Mapping

    nonisolated static func mapMailAccount(_ account: MailAccount, unreadCount: Int?) -> RemoteMailV2Account {
        RemoteMailV2Account(
            id: account.id.uuidString,
            provider: account.provider.rawValue,
            email: account.address,
            displayName: account.shortName,
            unreadCount: unreadCount
        )
    }

    nonisolated static func mapCalendarAccount(_ account: CalendarAccount) -> RemoteCalendarV2Account {
        RemoteCalendarV2Account(
            id: account.id.uuidString,
            provider: account.provider.rawValue,
            email: account.address,
            displayName: account.displayName,
            canRespond: account.provider.answersInvitations
        )
    }

    nonisolated static func mapThreadSummary(_ summary: MailThreadSummary) -> RemoteMailV2ThreadSummary {
        let sender = summary.senders.first
        return RemoteMailV2ThreadSummary(
            id: summary.id.threadID,
            threadId: summary.id.threadID,
            accountId: summary.id.accountID.uuidString,
            fromName: sender?.name,
            fromEmail: sender?.address ?? "",
            subject: RemoteText.capped(summary.subject, RemoteMailCalendarV2Limits.maxSubjectCharacters).text,
            snippet: RemoteText.capped(summary.snippet, RemoteMailCalendarV2Limits.maxSnippetCharacters).text,
            dateMs: RemoteJSON.milliseconds(summary.date),
            unread: summary.isUnread,
            starred: summary.isStarred,
            hasAttachments: summary.hasAttachments,
            hasDraft: summary.hasDraft,
            messageCount: summary.messageCount
        )
    }

    nonisolated static func mapMessage(_ message: MailMessage, accountID: UUID, threadID: String) -> RemoteMailV2Message {
        let textCapped = RemoteText.capped(message.text, RemoteMailCalendarV2Limits.maxTextBodyCharacters)
        let htmlCapped: (text: String, truncated: Bool)? = message.html.map {
            RemoteText.capped($0, RemoteMailCalendarV2Limits.maxHtmlBodyCharacters)
        }
        let bodyTruncated = textCapped.truncated || (htmlCapped?.truncated == true)
        let attachments = message.attachments.prefix(RemoteMailCalendarV2Limits.maxAttachments).map {
            RemoteMailV2Attachment(id: $0.id, name: $0.name, size: $0.size, mimeType: $0.mimeType)
        }
        return RemoteMailV2Message(
            id: message.id,
            threadId: threadID,
            accountId: accountID.uuidString,
            from: RemoteMailV2Address(name: message.from.name, email: message.from.address),
            to: message.to.map { RemoteMailV2Address(name: $0.name, email: $0.address) },
            cc: message.cc.map { RemoteMailV2Address(name: $0.name, email: $0.address) },
            subject: RemoteText.capped(message.subject, RemoteMailCalendarV2Limits.maxSubjectCharacters).text,
            snippet: RemoteText.capped(message.snippet, RemoteMailCalendarV2Limits.maxSnippetCharacters).text,
            dateMs: RemoteJSON.milliseconds(message.date),
            unread: message.isUnread,
            isDraft: message.isDraft,
            textBody: textCapped.text,
            htmlBody: htmlCapped?.text,
            bodyTruncated: bodyTruncated,
            attachments: Array(attachments)
        )
    }

    nonisolated static func mapThread(_ thread: MailThread) -> RemoteMailV2Thread {
        let summary = thread.summary
        let truncated = thread.messages.count > RemoteMailCalendarV2Limits.maxThreadMessages
        let slice = truncated ? Array(thread.messages.suffix(RemoteMailCalendarV2Limits.maxThreadMessages)) : thread.messages
        let messages = slice.map {
            mapMessage($0, accountID: summary.id.accountID, threadID: summary.id.threadID)
        }
        return RemoteMailV2Thread(
            id: summary.id.threadID,
            threadId: summary.id.threadID,
            accountId: summary.id.accountID.uuidString,
            subject: RemoteText.capped(summary.subject, RemoteMailCalendarV2Limits.maxSubjectCharacters).text,
            snippet: RemoteText.capped(summary.snippet, RemoteMailCalendarV2Limits.maxSnippetCharacters).text,
            dateMs: RemoteJSON.milliseconds(summary.date),
            unread: summary.isUnread,
            starred: summary.isStarred,
            hasAttachments: summary.hasAttachments,
            hasDraft: summary.hasDraft,
            messageCount: summary.messageCount,
            webUrl: thread.webURL?.absoluteString,
            messages: messages,
            messagesTruncated: truncated ? true : nil
        )
    }

    nonisolated static func mapCalendar(_ info: CalendarInfo, account: CalendarAccount, visible: Bool) -> RemoteCalendarV2Calendar {
        RemoteCalendarV2Calendar(
            id: info.id.calendarID,
            accountId: account.id.uuidString,
            name: info.name,
            color: info.color,
            isPrimary: info.isPrimary,
            visible: visible,
            canRespond: account.provider.answersInvitations,
            provider: account.provider.rawValue
        )
    }

    nonisolated static func mapEvent(
        _ event: CalendarEvent,
        calendar info: CalendarInfo,
        account: CalendarAccount,
        hostCalendar: Calendar = .autoupdatingCurrent
    ) -> RemoteCalendarV2Event {
        let responseStatus = mapResponseStatus(event.response)
        let isOrganizer: Bool
        if let organizerEmail = event.organizer?.email, let accountEmail = account.address {
            isOrganizer = organizerEmail.caseInsensitiveCompare(accountEmail) == .orderedSame
        } else {
            isOrganizer = event.response == nil && event.organizer == nil
        }
        let attendeesTruncated = event.attendees.count > RemoteMailCalendarV2Limits.maxEventAttendees
        let attendees = event.attendees.prefix(RemoteMailCalendarV2Limits.maxEventAttendees).map { person in
            RemoteCalendarV2Person(
                name: person.name,
                email: person.email,
                responseStatus: person.response.map(mapResponseStatus)
            )
        }
        let organizer = event.organizer.map { person in
            RemoteCalendarV2Person(
                name: person.name,
                email: person.email,
                responseStatus: person.response.map(mapResponseStatus)
            )
        }
        let notes = event.notes.map { RemoteText.capped($0, RemoteMailCalendarV2Limits.maxEventNotesCharacters).text }
        let startDateString = event.isAllDay ? isoDateString(event.start, calendar: hostCalendar) : nil
        let endDateString = event.isAllDay ? isoDateString(event.end, calendar: hostCalendar) : nil

        return RemoteCalendarV2Event(
            id: event.id.eventID,
            calendarId: info.id.calendarID,
            accountId: account.id.uuidString,
            calendarName: info.name,
            calendarColor: info.color,
            title: event.title,
            startMs: RemoteJSON.milliseconds(event.start),
            endMs: RemoteJSON.milliseconds(event.end),
            allDay: event.isAllDay,
            startDate: startDateString,
            endDate: endDateString,
            occurrenceMs: event.id.occurrence.map(RemoteJSON.milliseconds),
            location: event.location,
            notes: notes,
            meetingUrl: event.conferenceURL?.absoluteString,
            webUrl: event.webURL?.absoluteString,
            responseStatus: responseStatus,
            isOrganizer: isOrganizer,
            canRespond: account.provider.answersInvitations && !isOrganizer && event.response != nil,
            organizer: organizer,
            attendees: Array(attendees),
            attendeesTruncated: attendeesTruncated ? true : nil
        )
    }

    private nonisolated static func mapResponseStatus(_ response: CalendarResponse?) -> RemoteCalendarV2ResponseStatus {
        guard let response else { return .none }
        switch response {
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        case .needsAction: return .needsAction
        }
    }

    private nonisolated static func mapFolderRole(_ folder: RemoteMailV2Folder) -> MailFolderRole {
        switch folder {
        case .inbox, .unread: .inbox
        case .starred: .starred
        case .sent: .sent
        case .drafts: .drafts
        case .archive: .archive
        case .trash: .trash
        case .spam: .spam
        }
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private nonisolated static func isoDateString(_ date: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func mapMailError(_ error: Error) -> RemoteError {
        if MailboxCenter.isSignInRefusal(error) {
            return RemoteError(.unavailable, "Sign in again", reason: .signIn)
        }
        return RemoteError(.unavailable, MailboxCenter.failure(error).message, reason: .failed)
    }

    private static func mapCalendarError(_ error: Error) -> RemoteError {
        let failure = CalendarCenter.failure(error)
        return RemoteError(.unavailable, failure.message, reason: failure.kind == .signInRequired ? .signIn : .failed)
    }
}
