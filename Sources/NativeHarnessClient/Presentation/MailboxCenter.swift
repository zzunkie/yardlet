import Foundation
import Observation

/// Settings › Mailbox: off until the person turns it on.
enum MailboxPreference {
    static let key = "YardletMailbox"
    /// Settings › Notifications › New mail, on by default while the mailbox is on.
    static let notificationsKey = "YardletMailNotifications"
    /// Where each account's history was last read up to (`MailChanges.cursor`), so mail that came while
    /// Yardlet was closed is told once it opens. No message is kept; turning the mailbox off removes it.
    static let cursorsKey = "Yardlet.mailboxCursors"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? false
    }

    static func notifies(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: notificationsKey) as? Bool ?? true
    }
}

/// The app's one mailbox: the inboxes of the accounts it shows, read from each service and kept in
/// memory only. Nothing of a message is written to disk; turning the mailbox off forgets it all. Windows
/// keep their own selection and search (`MailWindowState`) and read threads through here, so a thread
/// opened in one window is not read again for another.
@MainActor @Observable
final class MailboxCenter {
    /// Whether the person turned the mailbox on (`MailboxPreference`); off, it holds nothing.
    private(set) var isEnabled = false
    /// The accounts shown, in the order the person connected them.
    private(set) var accounts: [MailAccount] = []
    /// Every account's inbox, newest first, merged.
    private(set) var threads: [MailThreadSummary] = []
    private(set) var isLoading = false
    /// Accounts whose inbox could not be read, with why.
    private(set) var failures: [UUID: MailFailure] = [:]
    /// Each account's folders and labels, as its service gives them.
    private(set) var folders: [UUID: [MailFolder]] = [:]
    /// Folders other than an inbox, read when a window shows them.
    private(set) var folderLists: [MailboxSelection: [MailThreadSummary]] = [:]
    private(set) var loadingFolders: Set<MailboxSelection> = []
    /// New mail arrived since a window last showed the mailbox; the sidebar's word reads only this.
    private(set) var hasUnseenMail = false

    /// Where each list goes on: each account's inbox, and each folder read.
    private(set) var inboxNextPages: [UUID: String] = [:]
    private(set) var folderNextPages: [MailboxSelection: String] = [:]
    @ObservationIgnored private var loadingMore: Set<MailboxSelection> = []
    @ObservationIgnored private var transports: [UUID: any MailAccountTransport] = [:]
    /// Each account's inbox as its service listed it, the first page and any read after it.
    private(set) var inboxes: [UUID: [MailThreadSummary]] = [:]
    /// Opened threads, the most recently opened last; the oldest go past `openedLimit`.
    @ObservationIgnored private var opened: [MailThreadKey: MailThread] = [:]
    @ObservationIgnored private var openedOrder: [MailThreadKey] = []
    @ObservationIgnored private var generation = 0
    /// Each account's watch for new mail, while `startWatching` has them run.
    @ObservationIgnored private var watches: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isWatching = false
    /// Windows that show the mailbox now.
    @ObservationIgnored private var visibleWindows: Set<UUID> = []
    @ObservationIgnored private let defaults: UserDefaults
    /// Told the threads new mail arrived in, newest first, after their inbox was read again.
    @ObservationIgnored var announce: (@MainActor ([MailThreadSummary]) -> Void)?
    /// How often each account is asked what changed (`MailAccountTransport.changes(since:)`).
    @ObservationIgnored var watchInterval: Duration = .seconds(60)

    static let openedLimit = 30
    static let longestWatchWait: Duration = .seconds(600)

    init(defaults: UserDefaults = .yardlet) {
        self.defaults = defaults
    }

    /// Whether a window shows the mailbox now.
    var isShown: Bool { !visibleWindows.isEmpty }

    func setVisible(_ visible: Bool, window: UUID) {
        if visible {
            visibleWindows.insert(window)
            noteShown()
        } else {
            visibleWindows.remove(window)
        }
    }

    /// Shows these accounts, read through their transports. Accounts no longer listed are forgotten
    /// with everything read from them.
    func setAccounts(_ entries: [(MailAccount, any MailAccountTransport)]) {
        generation += 1
        accounts = entries.map(\.0)
        transports = Dictionary(entries.map { ($0.0.id, $0.1) }, uniquingKeysWith: { $1 })
        let kept = Set(accounts.map(\.id))
        inboxes = inboxes.filter { kept.contains($0.key) }
        failures = failures.filter { kept.contains($0.key) }
        folders = folders.filter { kept.contains($0.key) }
        folderLists = folderLists.filter { $0.key.accountID.map(kept.contains) ?? false }
        inboxNextPages = inboxNextPages.filter { kept.contains($0.key) }
        folderNextPages = folderNextPages.filter { $0.key.accountID.map(kept.contains) ?? false }
        loadingFolders = []
        for key in openedOrder where !kept.contains(key.accountID) { opened[key] = nil }
        openedOrder.removeAll { !kept.contains($0.accountID) }
        for (id, watch) in watches { watch.cancel(); watches[id] = nil }
        if isWatching { for (id, transport) in transports { watches[id] = watch(id, transport) } }
        merge()
    }

    func account(_ id: UUID) -> MailAccount? { accounts.first { $0.id == id } }

    /// The folder a selection names; nil for every inbox together.
    func folder(_ selection: MailboxSelection) -> MailFolder? {
        guard case let .folder(accountID, folderID) = selection else { return nil }
        return folders[accountID]?.first { $0.id == folderID }
    }

    /// What a selection's list holds: the inboxes merged, one account's inbox, or a folder as last read.
    func threads(for selection: MailboxSelection) -> [MailThreadSummary] {
        guard case let .folder(accountID, _) = selection else { return threads }
        if folder(selection)?.role == .inbox { return inboxes[accountID] ?? [] }
        return folderLists[selection] ?? []
    }

    /// Unread threads of every inbox, as their services count them.
    var unreadInInboxes: Int {
        folders.values.reduce(0) { sum, list in sum + (list.first { $0.role == .inbox }?.unreadCount ?? 0) }
    }

    /// Reads a folder that is not an inbox, for a window that shows it; inboxes are kept read already.
    func load(_ selection: MailboxSelection) async {
        guard let folder = folder(selection), folder.role != .inbox, let accountID = selection.accountID,
              let transport = transports[accountID] else { return }
        let generation = generation
        loadingFolders.insert(selection)
        defer { if generation == self.generation { loadingFolders.remove(selection) } }
        guard let page = try? await transport.list(folder, pageToken: nil), generation == self.generation else { return }
        folderLists[selection] = page.threads
        folderNextPages[selection] = page.nextPageToken
    }

    /// Whether a list goes on past what was read.
    func hasMore(_ selection: MailboxSelection) -> Bool {
        switch selection {
        case .allInboxes: !inboxNextPages.isEmpty
        case let .folder(accountID, _):
            folder(selection)?.role == .inbox ? inboxNextPages[accountID] != nil : folderNextPages[selection] != nil
        }
    }

    /// Reads the next page of a list: of each account's inbox for every inbox together.
    func loadMore(_ selection: MailboxSelection) async {
        guard !loadingMore.contains(selection) else { return }
        loadingMore.insert(selection)
        defer { loadingMore.remove(selection) }
        let generation = generation
        let inboxAccounts: [UUID]? = switch selection {
        case .allInboxes: Array(inboxNextPages.keys)
        case let .folder(accountID, _): folder(selection)?.role == .inbox ? [accountID] : nil
        }
        if let inboxAccounts {
            for id in inboxAccounts {
                guard let token = inboxNextPages[id], let transport = transports[id],
                      let page = try? await transport.inbox(pageToken: token), generation == self.generation else { continue }
                let known = Set((inboxes[id] ?? []).map(\.id))
                inboxes[id, default: []] += page.threads.filter { !known.contains($0.id) }
                inboxNextPages[id] = page.nextPageToken
            }
            merge()
            return
        }
        guard let folder = folder(selection), let accountID = selection.accountID, let transport = transports[accountID],
              let token = folderNextPages[selection],
              let page = try? await transport.list(folder, pageToken: token), generation == self.generation else { return }
        let known = Set((folderLists[selection] ?? []).map(\.id))
        folderLists[selection, default: []] += page.threads.filter { !known.contains($0.id) }
        folderNextPages[selection] = page.nextPageToken
    }

    /// Reads the first page of every account's inbox again, and its folders.
    func refresh() async {
        let generation = generation
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }
        await withTaskGroup(of: (UUID, [MailFolder]?).self) { group in
            for (id, transport) in transports {
                group.addTask { (id, try? await transport.folders()) }
            }
            for await (id, list) in group where generation == self.generation {
                if let list { folders[id] = list }
            }
        }
        await withTaskGroup(of: (UUID, Result<MailPage, Error>).self) { group in
            for (id, transport) in transports {
                group.addTask {
                    do { return (id, .success(try await transport.inbox(pageToken: nil))) } catch { return (id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                guard generation == self.generation else { continue }
                switch result {
                case let .success(page):
                    takeFirstPage(page, for: id)
                    failures[id] = nil
                case let .failure(error):
                    failures[id] = Self.failure(error)
                }
            }
        }
        guard generation == self.generation else { return }
        merge()
        // A watch a refused sign-in stopped starts again once the account answers.
        if isWatching {
            for (id, transport) in transports where watches[id] == nil && failures[id] == nil { watches[id] = watch(id, transport) }
        }
    }

    /// An inbox's first page over what was read of it: threads read further down stay, with the page
    /// token past them, so new mail does not take the list back to its first page.
    private func takeFirstPage(_ page: MailPage, for id: UUID) {
        let existing = inboxes[id] ?? []
        guard existing.count > page.threads.count, page.nextPageToken != nil, inboxNextPages[id] != page.nextPageToken,
              let oldest = page.threads.last?.date else {
            inboxes[id] = page.threads
            inboxNextPages[id] = page.nextPageToken
            return
        }
        let fresh = Set(page.threads.map(\.id))
        inboxes[id] = page.threads + existing.filter { !fresh.contains($0.id) && $0.date < oldest }
    }

    /// Searches every account with its service's own search; nothing is kept once the search is left.
    func search(_ query: String, accountID: UUID? = nil) async -> [MailThreadSummary] {
        let targets = transports.filter { accountID == nil || $0.key == accountID }
        var found: [MailThreadSummary] = []
        await withTaskGroup(of: [MailThreadSummary].self) { group in
            for (_, transport) in targets {
                group.addTask { (try? await transport.search(query, pageToken: nil).threads) ?? [] }
            }
            for await threads in group { found += threads }
        }
        return found.sorted { $0.date > $1.date }
    }

    /// The thread as last read, if it was opened.
    func openedThread(_ key: MailThreadKey) -> MailThread? { opened[key] }

    /// Reads a thread for showing, and marks it read on the service when it was unread
    /// (`MailReadSync`).
    func open(_ key: MailThreadKey) async throws -> MailThread {
        guard let transport = transports[key.accountID] else {
            throw MailFailure(kind: .unavailable, message: L10n.string("This account is no longer in the mailbox."))
        }
        let generation = generation
        let thread = try await transport.thread(key.threadID)
        guard generation == self.generation else { return thread }
        remember(thread, for: key)
        if MailReadSync.marksOpenedThreadsRead, thread.summary.isUnread || summary(key)?.isUnread == true {
            // Shown read at once; the request is its own, so choosing another thread does not stop it.
            let previous = state(of: key)
            update(key, with: .read(true))
            Task { [weak self] in try? await self?.send(.read(true), to: key, restoring: previous) }
        }
        return opened[key] ?? thread
    }

    /// Changes a thread on its service, showing the change at once and taking it back if the service
    /// refuses it.
    func apply(_ change: MailThreadChange, to key: MailThreadKey) async throws {
        let previous = state(of: key)
        update(key, with: change)
        try await send(change, to: key, restoring: previous)
    }

    /// The thread's read and star state as shown before a change.
    private func state(of key: MailThreadKey) -> (isUnread: Bool, isStarred: Bool)? {
        let summary = summary(key) ?? folderLists.values.lazy.compactMap { $0.first { $0.id == key } }.first
            ?? opened[key]?.summary
        return summary.map { ($0.isUnread, $0.isStarred) }
    }

    /// Asks the service for a change already shown. A refusal takes back only that thread's change: its
    /// read or star state, or, for a move, its lists read again.
    private func send(_ change: MailThreadChange, to key: MailThreadKey,
                      restoring previous: (isUnread: Bool, isStarred: Bool)?) async throws {
        guard let transport = transports[key.accountID] else { return }
        let generation = generation
        do {
            try await transport.change(key.threadID, change)
        } catch {
            guard generation == self.generation else { throw Self.failure(error) }
            switch change {
            case .read: if let previous { update(key, with: .read(!previous.isUnread)) }
            case .starred: if let previous { update(key, with: .starred(previous.isStarred)) }
            case .archived, .notSpam, .untrash:
                _ = await reread(key.accountID, arrived: [])
                for selection in folderLists.keys where selection.accountID == key.accountID { await load(selection) }
            }
            throw Self.failure(error)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled { forget() }
    }

    /// Mail arrived that no window has shown yet.
    func noteNewMail() {
        if !hasUnseenMail { hasUnseenMail = true }
    }

    // MARK: - Writing

    /// Saves what is being written as a draft on its account's service; the draft's ID comes back on it.
    func save(_ composition: MailComposition) async throws -> MailComposition {
        guard let transport = transports[composition.accountID] else {
            throw MailFailure(kind: .unavailable, message: L10n.string("This account is no longer in the mailbox."))
        }
        var saved = composition
        saved.draftID = try await transport.saveDraft(composition)
        return saved
    }

    /// Sends a saved draft and reads its thread again.
    func sendDraft(_ draftID: String, of composition: MailComposition) async throws {
        guard let transport = transports[composition.accountID] else {
            throw MailFailure(kind: .unavailable, message: L10n.string("This account is no longer in the mailbox."))
        }
        try await transport.sendDraft(draftID)
        await afterWriting(composition)
    }

    /// Removes the draft a composition was saved as, if it was.
    func discard(_ composition: MailComposition) async throws {
        guard let id = composition.draftID, let transport = transports[composition.accountID] else { return }
        try await transport.discardDraft(id)
        await afterWriting(composition)
    }

    /// A thread's draft, from the person or an agent, opened to edit: its recipients, subject and words
    /// over the draft it is on the service.
    func composition(editing message: MailMessage, in thread: MailThread) async throws -> MailComposition {
        let key = thread.summary.id
        guard let transport = transports[key.accountID] else {
            throw MailFailure(kind: .unavailable, message: L10n.string("This account is no longer in the mailbox."))
        }
        let draftID = try await transport.draftID(forMessage: message.id)
        let line = { (addresses: [MailAddress]) in addresses.map(MailComposition.formatted).joined(separator: ", ") }
        let answered = thread.messages.last { !$0.isDraft && $0.date <= message.date }
        let references = [answered?.references, answered?.messageID].compactMap { $0 }.joined(separator: " ")
        var composition = MailComposition(accountID: key.accountID, kind: .reply, threadID: key.threadID, draftID: draftID,
                                          to: line(message.to), cc: line(message.cc), bcc: line(message.bcc),
                                          subject: message.subject, body: message.text, inReplyTo: answered?.messageID,
                                          references: references.isEmpty ? nil : references)
        composition.keepsDraftFiles = !message.attachments.isEmpty
        return composition
    }

    /// The thread written in is read again, so a saved or sent reply, or a discarded draft, shows in it.
    func afterWriting(_ composition: MailComposition) async {
        guard let thread = composition.threadID else { return }
        let key = MailThreadKey(accountID: composition.accountID, threadID: thread)
        if let transport = transports[key.accountID], let fresh = try? await transport.thread(thread) {
            remember(fresh, for: key)
        }
        _ = await reread(key.accountID, arrived: [])
    }

    /// A window shows the mailbox: what arrived until now has been seen.
    func noteShown() {
        if hasUnseenMail { hasUnseenMail = false }
    }

    /// Forgets everything read, as when the mailbox is turned off: the lists, the opened threads and
    /// where each account's history was read up to.
    func forget() {
        stopWatching()
        setAccounts([])
        hasUnseenMail = false
        defaults.removeObject(forKey: MailboxPreference.cursorsKey)
    }

    /// Asks every account what changed, now and every `watchInterval`, while Yardlet runs. No model
    /// is asked anything; a change reads that account's inbox again.
    func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        for (id, transport) in transports where watches[id] == nil { watches[id] = watch(id, transport) }
    }

    func stopWatching() {
        isWatching = false
        for watch in watches.values { watch.cancel() }
        watches = [:]
    }

    /// One account's watch: the cursor kept from the last run, or the account's present one, then what
    /// changed after it. A failure waits twice as long each time, up to ten minutes; a refused sign-in
    /// shows on the account and stops its watch.
    private func watch(_ id: UUID, _ transport: any MailAccountTransport) -> Task<Void, Never> {
        let interval = watchInterval
        return Task { [weak self] in
            var wait = interval
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    if let cursor = self.cursor(for: id) {
                        let changes = try await transport.changes(since: cursor)
                        guard !Task.isCancelled else { return }
                        // The cursor moves on only once the inbox was read, so what arrived is told.
                        let read = changes.changed ? await self.reread(id, arrived: changes.arrivedThreadIDs) : true
                        if read { self.setCursor(changes.cursor, for: id) }
                    } else {
                        let cursor = try await transport.changeCursor()
                        guard !Task.isCancelled else { return }
                        self.setCursor(cursor, for: id)
                    }
                    wait = interval
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    if Self.isSignInRefusal(error) {
                        self.failures[id] = MailFailure(kind: .signInRequired,
                                                        message: L10n.string("Sign in to this account again in Settings › Connectors."))
                        self.watches[id] = nil
                        return
                    }
                    wait = min(wait * 2, Self.longestWatchWait)
                }
                try? await Task.sleep(for: wait)
            }
        }
    }

    /// Reads one account's inbox again after a change, and tells of the threads mail arrived in;
    /// false when the inbox could not be read.
    @discardableResult
    private func reread(_ id: UUID, arrived: [String]) async -> Bool {
        guard let transport = transports[id] else { return false }
        let generation = generation
        guard let page = try? await transport.inbox(pageToken: nil) else { return false }
        guard generation == self.generation else { return true }
        takeFirstPage(page, for: id)
        failures[id] = nil
        merge()
        let threads = page.threads.filter { arrived.contains($0.id.threadID) && $0.isUnread }
        guard !threads.isEmpty else { return true }
        if !isShown { noteNewMail() }
        announce?(threads)
        return true
    }

    private func cursor(for id: UUID) -> String? {
        (defaults.dictionary(forKey: MailboxPreference.cursorsKey) as? [String: String])?[id.uuidString]
    }

    private func setCursor(_ cursor: String, for id: UUID) {
        var cursors = defaults.dictionary(forKey: MailboxPreference.cursorsKey) as? [String: String] ?? [:]
        guard cursors[id.uuidString] != cursor else { return }
        cursors[id.uuidString] = cursor
        defaults.set(cursors, forKey: MailboxPreference.cursorsKey)
    }

    // MARK: - Private

    private func summary(_ key: MailThreadKey) -> MailThreadSummary? {
        inboxes[key.accountID]?.first { $0.id == key }
    }

    private func remember(_ thread: MailThread, for key: MailThreadKey) {
        opened[key] = thread
        openedOrder.removeAll { $0 == key }
        openedOrder.append(key)
        while openedOrder.count > Self.openedLimit { opened[openedOrder.removeFirst()] = nil }
    }

    private func update(_ key: MailThreadKey, with change: MailThreadChange) {
        func changed(_ list: [MailThreadSummary], leaves: Bool) -> [MailThreadSummary] {
            guard let index = list.firstIndex(where: { $0.id == key }) else { return list }
            var list = list
            if leaves { list.remove(at: index); return list }
            switch change {
            case let .read(read): list[index].isUnread = !read
            case let .starred(starred): list[index].isStarred = starred
            case .archived, .notSpam, .untrash: break
            }
            return list
        }
        if let inbox = inboxes[key.accountID] {
            inboxes[key.accountID] = changed(inbox, leaves: change == .archived)
            merge()
        }
        // A thread leaves the folder a move takes it out of; the inbox it goes to is read again.
        for (selection, list) in folderLists where selection.accountID == key.accountID {
            let role = folder(selection)?.role
            let leaves = (change == .notSpam && role == .spam) || (change == .untrash && role == .trash)
                || (change == .archived && role == .inbox) || (change == .starred(false) && role == .starred)
            let updated = changed(list, leaves: leaves)
            if updated != list { folderLists[selection] = updated }
        }
        if var thread = opened[key] {
            switch change {
            case let .read(read):
                thread.summary.isUnread = !read
                for index in thread.messages.indices { thread.messages[index].isUnread = !read && thread.messages[index].isUnread }
            case let .starred(starred): thread.summary.isStarred = starred
            case .archived, .notSpam, .untrash: break
            }
            opened[key] = thread
        }
        if change == .notSpam || change == .untrash {
            Task { [weak self] in await self?.reread(key.accountID, arrived: []) }
        }
    }

    /// Every inbox together, newest first. An account with more to read ends at the oldest thread read
    /// of it, so other accounts' older threads wait until it is read that far too, and the list has no
    /// gap in time.
    private func merge() {
        var merged = accounts.flatMap { inboxes[$0.id] ?? [] }.sorted { $0.date > $1.date }
        let readTo = accounts.compactMap { inboxNextPages[$0.id] != nil ? inboxes[$0.id]?.last?.date : nil }.max()
        if let readTo { merged.removeAll { $0.date < readTo } }
        if merged != threads { threads = merged }
    }

    /// A refused sign-in: a Gmail or Outlook token that no longer refreshes, or a password an IMAP server refused.
    private static func isSignInRefusal(_ error: Error) -> Bool {
        if case OAuthAPISession.Failure.signInRequired = error { return true }
        return (error as? MailFailure)?.kind == .signInRequired
    }

    private static func failure(_ error: Error) -> MailFailure {
        error as? MailFailure ?? MailFailure(kind: .unavailable, message: error.localizedDescription)
    }
}

/// One window's view of the mailbox: the mailbox it lists, the thread chosen and what is searched.
@MainActor @Observable
final class MailWindowState {
    /// Every inbox together, or one folder of one account.
    var mailbox: MailboxSelection = .allInboxes
    /// The sidebar shows the accounts and their folders rather than a list.
    var showsFolders = false
    /// Accounts the person folded or opened in the sidebar, against where each starts: with more than
    /// one account each starts folded to its own line, as a long list of accounts reads best that way.
    var toggledAccounts: Set<UUID> = []
    /// Accounts whose labels are folded in the sidebar.
    var foldedLabels: Set<UUID> = []
    var selection: MailThreadKey?
    var searchText = ""
    /// The services' answer to the search last run, nil while none is shown.
    private(set) var searchResults: [MailThreadSummary]?
    private(set) var isSearching = false
    /// The opened thread, once read.
    private(set) var thread: MailThread?
    private(set) var isOpening = false
    private(set) var failure: MailFailure?

    /// What the person is writing, shown in the thread's place while it is.
    var composition: MailComposition?
    /// When the message just sent leaves, unless the person takes it back first.
    private(set) var sendsAt: Date?
    /// The undo time is over and the message is on its way: Undo is gone.
    private(set) var isSending = false
    private(set) var isSaving = false
    private(set) var writingFailure: String?

    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var searching: Task<Void, Never>?
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var lastSave: Task<Void, Never>?
    /// What the message held when it was opened, so one left as it was is not saved as a draft.
    @ObservationIgnored private var openedContent: [UUID: [String]] = [:]
    /// The draft each message being written was saved as.
    @ObservationIgnored private var draftIDs: [UUID: String] = [:]

    /// How long Undo stays after Send.
    @ObservationIgnored var undoWindow: Duration = .seconds(5)

    init() {}

    /// Starts a new message from `account`, or a reply, reply to all or forward of `message`.
    func write(_ kind: MailComposition.Kind, account: MailAccount, message: MailMessage? = nil, in thread: MailThread? = nil) {
        writingFailure = nil
        let started = message.flatMap { message in thread.map { MailComposition.answering(message, in: $0, as: kind, from: account) } }
            ?? MailComposition(accountID: account.id)
        open(started)
    }

    private func open(_ started: MailComposition) {
        openedContent[started.id] = started.content
        composition = started
    }

    /// Whether the message holds anything other than what it was opened with.
    func isChanged(_ composition: MailComposition) -> Bool {
        openedContent[composition.id].map { $0 != composition.content } ?? true
    }

    /// Opens a thread's draft to go on writing it.
    func edit(_ message: MailMessage, in thread: MailThread, center: MailboxCenter) {
        writingFailure = nil
        Task {
            do { open(try await center.composition(editing: message, in: thread)) }
            catch { failure = error as? MailFailure ?? MailFailure(kind: .unavailable, message: error.localizedDescription) }
        }
    }

    /// Saves what is written as a draft on the service, as the person writes and when they close it;
    /// a message left as it was opened is not saved.
    func save(in center: MailboxCenter) async {
        guard let current = composition, sendsAt == nil, isChanged(current) else { return }
        await enqueueSave(current, in: center).value
    }

    /// Saves one after another, so a save that is under way when the person closes or sends gives its
    /// draft to the next, and no message ends up as two drafts.
    @discardableResult
    private func enqueueSave(_ snapshot: MailComposition, in center: MailboxCenter) -> Task<Void, Never> {
        let previous = lastSave
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var snapshot = snapshot
            if snapshot.draftID == nil { snapshot.draftID = self.draftIDs[snapshot.id] }
            self.isSaving = true
            defer { self.isSaving = false }
            do {
                let saved = try await center.save(snapshot)
                self.draftIDs[snapshot.id] = saved.draftID
                self.openedContent[snapshot.id] = snapshot.content
                if self.composition?.id == snapshot.id, self.composition?.draftID != saved.draftID {
                    self.composition?.draftID = saved.draftID
                }
                self.writingFailure = nil
                // The thread shows the draft as it now is.
                await center.afterWriting(saved)
                if let thread = saved.threadID, self.selection == MailThreadKey(accountID: saved.accountID, threadID: thread) {
                    self.thread = center.openedThread(MailThreadKey(accountID: saved.accountID, threadID: thread)) ?? self.thread
                }
            } catch {
                if self.composition?.id == snapshot.id { self.writingFailure = error.localizedDescription }
            }
        }
        lastSave = task
        return task
    }

    /// Closes the message, keeping it as a draft when anything was written.
    func close(in center: MailboxCenter) {
        guard let current = composition, sendsAt == nil, !isSending else { return }
        composition = nil
        if isChanged(current) { enqueueSave(current, in: center) }
    }

    /// Throws the message away, with the draft it was saved as.
    func discard(in center: MailboxCenter) {
        guard let current = composition, sendsAt == nil, !isSending else { return }
        composition = nil
        let previous = lastSave
        Task { [weak self] in
            await previous?.value
            var current = current
            if current.draftID == nil { current.draftID = self?.draftIDs[current.id] }
            try? await center.discard(current)
        }
    }

    /// Sends what is written after `undoWindow`, during which Undo takes it back.
    func send(in center: MailboxCenter) {
        guard let current = composition, sendsAt == nil, !isSending else { return }
        guard !MailComposition.recipients(current.to + "," + current.cc + "," + current.bcc).isEmpty else {
            writingFailure = L10n.string("Add at least one recipient.")
            return
        }
        writingFailure = nil
        let wait = undoWindow
        sendsAt = .now.addingTimeInterval(Double(wait.components.seconds))
        sending = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled, self.sendsAt != nil else { return }
            // From here the message goes: Undo is gone and nothing takes it back.
            self.sendsAt = nil
            self.isSending = true
            defer { self.isSending = false }
            await self.lastSave?.value
            var current = current
            if current.draftID == nil { current.draftID = self.draftIDs[current.id] }
            do {
                // A draft sent as it was saved is not saved over, so a draft an agent wrote in HTML goes as it is.
                if current.draftID == nil || self.isChanged(current) {
                    let saved = try await center.save(current)
                    self.draftIDs[current.id] = saved.draftID
                    current.draftID = saved.draftID
                    if self.composition?.id == current.id { self.composition?.draftID = saved.draftID }
                }
                guard let draftID = current.draftID else { return }
                try await center.sendDraft(draftID, of: current)
                if self.composition?.id == current.id { self.composition = nil }
                if let key = self.selection { self.thread = center.openedThread(key) ?? self.thread }
            } catch {
                if self.composition?.id == current.id { self.writingFailure = error.localizedDescription }
            }
        }
    }

    /// Takes back the message just sent, before it leaves.
    func undoSend() {
        guard sendsAt != nil, !isSending else { return }
        sending?.cancel()
        sending = nil
        sendsAt = nil
    }

    /// Sends a thread's draft as it is, as its Send button does.
    func sendDraft(_ message: MailMessage, in thread: MailThread, center: MailboxCenter) {
        Task {
            do {
                open(try await center.composition(editing: message, in: thread))
                send(in: center)
            } catch {
                failure = error as? MailFailure ?? MailFailure(kind: .unavailable, message: error.localizedDescription)
            }
        }
    }

    /// Discards a thread's draft.
    func discardDraft(_ message: MailMessage, in thread: MailThread, center: MailboxCenter) {
        Task {
            do {
                let draft = try await center.composition(editing: message, in: thread)
                try await center.discard(draft)
                if selection == thread.summary.id { self.thread = center.openedThread(thread.summary.id) }
            } catch {
                failure = error as? MailFailure ?? MailFailure(kind: .unavailable, message: error.localizedDescription)
            }
        }
    }

    /// The rows the list shows: the search's answer while there is one, else the mailbox's threads,
    /// narrowed at once to what the typed words match.
    func rows(in center: MailboxCenter) -> [MailThreadSummary] {
        let source = searchResults ?? center.threads(for: mailbox)
        let words = searchText.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !words.isEmpty, searchResults == nil else { return source }
        return source.filter { thread in
            let text = ([thread.subject, thread.snippet] + thread.senders.flatMap { [$0.name ?? "", $0.address] })
                .joined(separator: " ").lowercased()
            return words.allSatisfy(text.contains)
        }
    }

    /// Lists a mailbox, reading it from its service when it is a folder other than an inbox.
    func show(_ mailbox: MailboxSelection, in center: MailboxCenter) {
        self.mailbox = mailbox
        showsFolders = false
        searchText = ""
        clearSearch()
        Task { await center.load(mailbox) }
    }

    /// Forgets all the window read and wrote, as when the mailbox is turned off.
    func reset() {
        for task in [opening, searching, sending, lastSave] { task?.cancel() }
        mailbox = .allInboxes
        showsFolders = false
        selection = nil
        thread = nil
        isOpening = false
        failure = nil
        searchText = ""
        searchResults = nil
        isSearching = false
        composition = nil
        sendsAt = nil
        isSending = false
        writingFailure = nil
        draftIDs = [:]
        openedContent = [:]
    }

    /// Shows a thread; choosing the one shown reads it again.
    func select(_ key: MailThreadKey?, in center: MailboxCenter) {
        guard key != selection || (key != nil && !isOpening) else { return }
        opening?.cancel()
        selection = key
        failure = nil
        thread = key.flatMap(center.openedThread)
        guard let key else { isOpening = false; return }
        isOpening = thread == nil
        opening = Task { [weak self] in
            do {
                let thread = try await center.open(key)
                guard let self, !Task.isCancelled, self.selection == key else { return }
                self.thread = thread
            } catch {
                guard let self, !Task.isCancelled, self.selection == key else { return }
                self.failure = error as? MailFailure ?? MailFailure(kind: .unavailable, message: error.localizedDescription)
            }
            if let self, self.selection == key { self.isOpening = false }
        }
    }

    /// Changes the chosen thread; a thread that leaves the list leaves the window showing the next one.
    func apply(_ change: MailThreadChange, in center: MailboxCenter) {
        guard let key = selection else { return }
        let before = rows(in: center)
        let next = before.firstIndex { $0.id == key }.flatMap { index in
            before.indices.contains(index + 1) ? before[index + 1].id : index > 0 ? before[index - 1].id : nil
        }
        Task {
            do {
                try await center.apply(change, to: key)
                guard selection == key else { return }
                if !rows(in: center).contains(where: { $0.id == key }), before.contains(where: { $0.id == key }) {
                    select(next, in: center)
                } else {
                    thread = center.openedThread(key)
                }
            } catch {
                failure = error as? MailFailure ?? MailFailure(kind: .unavailable, message: error.localizedDescription)
            }
        }
    }

    /// Asks the services of the mailbox listed (every account for every inbox) for the typed words.
    func runSearch(in center: MailboxCenter) {
        searching?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { clearSearch(); return }
        isSearching = true
        let account = mailbox.accountID
        searching = Task { [weak self] in
            let found = await center.search(query, accountID: account)
            guard let self, !Task.isCancelled, self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            self.searchResults = found
            self.isSearching = false
        }
    }

    func clearSearch() {
        searching?.cancel()
        searchResults = nil
        isSearching = false
    }
}
