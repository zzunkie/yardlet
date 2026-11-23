import Foundation
import Observation
import YardletRemote

/// One Mac as this phone follows it (docs/REMOTE_PROTOCOL.md): its projects and tasks, the conversations open on
/// the phone, and every command, each sent through the Mac's own paths. Responses and events are applied in the
/// order they arrive (`RemoteHostConnection.inbound`), so a subscription's page comes before the changes to it.
/// After every new connection the list and the open conversations are read again.
///
/// The connection is open only while the app is in front: iOS suspends an app in the background, and the Mac
/// pushes to a phone only while it holds no connection from it (§16), so the session closes it when the app goes
/// to the background and opens it again when it comes back.
@MainActor
@Observable
final class HostSession: Identifiable {
    enum Connection: Equatable {
        case connecting
        case connected(RemoteClientPath)
        /// Not reachable now; trying again at `retryAt`.
        case unreachable(retryAt: Date?)
        /// The Mac removed this phone, or no longer knows it.
        case removed
        case stopped
    }

    nonisolated let id: String
    let isDemo: Bool
    private(set) var host: RemoteSavedHost
    private(set) var connection: Connection = .stopped
    /// Why the Mac closed the last connection on purpose: its remote turned off, or Yardlet quit there.
    private(set) var closingReason: String?
    private(set) var hasSnapshot = false
    private(set) var projects: [RemoteProject] = []
    /// The Mac's listed tasks, most recently active first.
    private(set) var tasks: [RemoteTask] = []
    private(set) var newTask: RemoteNewTask?
    private(set) var followUp: RemoteFollowUpMode?
    /// The Mac answers a task's settings, slash commands, edit and fork (§15.23).
    private(set) var taskControls = false
    /// The Mac reads a suggested task's choices for the phone and starts it with the phone's (§15.9).
    private(set) var suggestionOptions = false
    /// The Mac answers `composerState` and `composerAction` for a task's queue (§15.33).
    private(set) var composerExtensions = false
    /// The Mac reads and stops a Claude Code subagent (`subtask`, §15.31).
    private(set) var subtasks = false
    /// What each open task's composer on the Mac says: whether its queue is paused, and its notice (§15.33).
    private(set) var composerStates: [String: RemoteComposerState] = [:]
    /// Link requests (§12.1) waiting for an answer from any of the Mac's devices, the oldest first (§15.11).
    private(set) var linkRequests: [LinkRequest] = []
    struct Capabilities: Equatable {
        var scheduledTasks = false
        var hostSettings = false
        var hostAccounts = false
        var hostCalendar = false
        var hostMail = false
    }

    /// Capabilities advertised by the connected Mac's snapshot.
    private(set) var capabilities = Capabilities()
    /// Mail and Calendar availability and device permission on the connected Mac (§15.38); nil until read.
    private(set) var mailCalendarState: RemoteMailCalendarState?
    /// The Mac's Settings page as last read (§15.36); nil until read.
    private(set) var hostSettings: RemoteHostSettings?
    /// The Mac's Accounts, Harnesses and Connectors state as last read (§15.37); nil until read.
    private(set) var hostAccounts: RemoteAccountsState?
    /// Counts the Mac's `hostSettingsChanged` notifications (§15.36).
    private(set) var hostSettingsChanges = 0
    /// Counts the Mac's `hostAccountsChanged` notifications (§15.37).
    private(set) var hostAccountsChanges = 0
    /// The Mac lists its scheduled tasks, runs one now, and pauses or resumes one (§15.21).
    private(set) var scheduledTasks = false
    /// Counts the Mac's `schedulesChanged` (§15.21), so a Schedules screen open reads the list again.
    private(set) var schedulesChanges = 0
    /// The Mac lists a task's outputs and serves its files (§15.22).
    private(set) var taskFiles = false
    /// Each open task's outputs as the Mac last listed them, newest first (§15.22).
    private(set) var outputs: [String: [RemoteOutput]] = [:]
    /// The Mac takes a turn's next steps: Codex's questions answered and its plan implemented (§15.31).
    private(set) var nextSteps = false
    private(set) var conversations: [String: ConversationState] = [:]
    /// Each open task's composer settings as the Mac last answered them (§15.23).
    private(set) var taskSettings: [String: [RemoteSetting]] = [:]
    /// The Mac's clock minus this phone's, so times read as the Mac wrote them (§2).
    private(set) var clockOffset: TimeInterval = 0
    /// The last command the Mac refused, in a line for the screen.
    var commandError: String?
    /// A task's browser tabs on this connection (§15.25): the tab screen's watch, and the open conversation's list.
    let browser = TaskBrowser()

    /// How this phone asks for pushes, once the system gave it a token.
    @ObservationIgnored var pushRegistration: (provider: String, token: String)? {
        didSet { if pushRegistration?.token != oldValue?.token { registerPush() } }
    }
    /// The push key the Mac made for this phone (§15.6), to keep for the notification service extension.
    @ObservationIgnored var onPushKey: ((_ key: Data, _ keyID: String) -> Void)?

    /// The registration under way, so one ends before the next begins and the Mac keeps the latest target.
    @ObservationIgnored private var registeringPush: Task<Void, Never>?
    @ObservationIgnored private var connector: RemoteHostConnection?
    @ObservationIgnored private let clientKey: RemoteKeyPair
    @ObservationIgnored private let hello: RemoteHandshakeHello
    @ObservationIgnored private let store: RemoteHostStore?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var finder: BonjourFinder?
    @ObservationIgnored private var pending: [String: (RemoteResponse) -> Void] = [:]
    @ObservationIgnored private var nextRequest = 0
    /// Counts connections opened and lost, so what was read on one connection is not acted on over another.
    @ObservationIgnored private var connectionNumber = 0
    /// Subscriptions, the least recently shown first; a Mac takes 8 per connection (§7).
    @ObservationIgnored private var subscribed: [String] = []
    /// The Mac answers a subscription in full detail (§15.24), as its list last said. Kept with the saved Mac: a
    /// conversation open on a new connection is subscribed before the list answers.
    @ObservationIgnored private var fullConversation: Bool
    /// The detail each conversation was last asked for in.
    @ObservationIgnored private var subscribedDetail: [String: RemoteConversationDetail] = [:]
    @ObservationIgnored static let keptSubscriptions = 6
    @ObservationIgnored private var watchingHostSettingsCount = 0
    @ObservationIgnored private var watchingHostAccountsCount = 0
    @ObservationIgnored private var readingHostSettings = false
    @ObservationIgnored private var dirtyHostSettings = false

    init(host: RemoteSavedHost, clientKey: RemoteKeyPair, hello: RemoteHandshakeHello, store: RemoteHostStore?,
         isDemo: Bool = false) {
        id = host.id
        self.host = host
        self.clientKey = clientKey
        self.hello = hello
        self.store = store
        self.isDemo = isDemo
        fullConversation = host.fullConversation == true
        browser.transport = { [weak self] request, onResponse in self?.request(request, onResponse: onResponse) }
        browser.isConnected = { [weak self] in self?.isConnected == true }
    }

    var name: String { host.name }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    // MARK: - Connecting

    func start() {
        guard connector == nil, let target = host.target else { return }
        let connector = RemoteHostConnection(target: target, clientKey: clientKey, hello: hello)
        self.connector = connector
        if case .removed = connection { return }
        connection = .connecting
        let stream = connector.inbound
        reader = Task { [weak self] in
            for await inbound in stream {
                guard let self else { return }
                self.handle(inbound)
            }
        }
        // The Mac on this network, found by its key (§11.3): its addresses go first in the race.
        if !isDemo {
            let finder = BonjourFinder(discoveryID: RemoteIdentity.discoveryID(for: target.hostKey)) { addresses in
                Task { await connector.discovered(addresses) }
            }
            finder.start()
            self.finder = finder
        }
        Task { await connector.start() }
    }

    /// Closes the connection; `start` opens a new one.
    func stop() {
        reader?.cancel()
        reader = nil
        finder?.cancel()
        finder = nil
        if let connector { Task { await connector.stop() } }
        connector = nil
        failPending()
        if connection != .removed { connection = .stopped }
    }

    /// The person asked to try now, or the network changed.
    func reconnectNow() {
        guard let connector else { return start() }
        Task { await connector.reconnectNow() }
    }

    // MARK: - Reading what arrives

    private func handle(_ inbound: RemoteHostConnection.Inbound) {
        switch inbound {
        case let .state(state):
            handle(state)
        case let .response(response):
            pending.removeValue(forKey: response.re)?(response)
        case let .event(event):
            handle(event)
        }
    }

    private func handle(_ state: RemoteHostConnection.State) {
        switch state {
        case .idle, .connecting:
            if !isConnected { connection = .connecting }
        case let .connected(path, reply):
            failPending()
            closingReason = nil
            host.update(from: reply)
            store?.save(host)
            if let target = host.target, let connector { Task { await connector.update(target: target) } }
            if let serverTime = reply.serverTime {
                clockOffset = Double(serverTime) / 1000 - Date().timeIntervalSince1970
            }
            connection = .connected(path)
            resync()
            registerPush()
        case let .waiting(retryAt, _):
            failPending()
            connection = .unreachable(retryAt: retryAt)
        case .revoked:
            failPending()
            connection = .removed
            if !isDemo { PushTargets.remove(hostID: id) }
        case .stopped:
            failPending()
            if connection != .removed { connection = .stopped }
        }
    }

    private func handle(_ event: RemoteEvent) {
        switch event.event {
        case .tasksChanged:
            if let projects = event.projects { self.projects = projects }
            applyTasks(changed: event.tasks ?? [], removed: event.removedTaskIds ?? [])
        case .conversation:
            guard let taskID = event.taskId, let conversation = conversations[taskID] else { return }
            if !conversation.apply(event.changes ?? []) { subscribe(taskID) }
        case .conversationReset:
            guard let taskID = event.taskId, let conversation = conversations[taskID] else { return }
            conversation.load(event.items ?? [], cursor: event.cursor, hasOlder: event.hasOlder == true)
        case .conversationEnded:
            guard let taskID = event.taskId else { return }
            conversations[taskID] = nil
            taskSettings[taskID] = nil
            composerStates[taskID] = nil
            outputs[taskID] = nil
            subscribed.removeAll { $0 == taskID }
            subscribedDetail[taskID] = nil
            applyTasks(changed: [], removed: [taskID])
        case .taskRailChanged:
            break
        case .taskSettingsChanged:
            guard let taskID = event.taskId, conversations[taskID] != nil else { return }
            // `composerChanged` invalidates only the composer's state, not the task's settings (§15.33).
            if event.composerChanged == true {
                Task { await readComposerState(taskID) }
            } else {
                Task { await readTaskSettings(taskID) }
            }
        case .closing:
            closingReason = event.reason
        case .revoked:
            connection = .removed
        case .linkRequest:
            guard let requestID = event.requestId, let code = event.code else { return }
            linkRequests.removeAll { $0.id == requestID }
            linkRequests.append(LinkRequest(id: requestID, name: event.name, code: code))
        case .linkResolved:
            linkRequests.removeAll { $0.id == event.requestId }
        case .attention:
            if let taskID = event.taskId, PushNotice.outdates(event) { withdrawNotices { $0 == taskID } }
        case .schedulesChanged:
            schedulesChanges += 1
        case .tabFrame, .browserTabsChanged, .tabCopied:
            browser.receive(event)
        case .mailCalendarChanged:
            Task { await refreshMailCalendarState() }
        case .hostSettingsChanged:
            hostSettingsChanges += 1
            if watchingHostSettingsCount > 0 {
                Task { _ = await fetchHostSettings(watching: true) }
            }
        case .hostAccountsChanged:
            hostAccountsChanges += 1
            if watchingHostAccountsCount > 0 {
                Task { _ = await fetchHostAccounts(watching: true) }
            }
        case .linked, .linkRefused, .terminalOutput, .terminalClosed:
            // Not shown on the phone yet: terminals (§15.29).
            // `linked` and `linkRefused` go only to the connection that asked (§12.1).
            break
        }
    }

    /// The list again, then each open conversation's latest page: what changed while away.
    private func resync() {
        // A request still waiting is told again on the new connection (§12.1).
        linkRequests = []
        request(.snapshot) { [weak self] response in
            guard let self, response.ok else { return }
            projects = response.projects ?? []
            tasks = (response.tasks ?? []).sorted { $0.lastActivityAt > $1.lastActivityAt }
            newTask = response.newTask
            followUp = response.followUp
            applyFlags(response)
            if let serverTime = response.serverTime {
                clockOffset = Double(serverTime) / 1000 - Date().timeIntervalSince1970
            }
            hasSnapshot = true
            withdrawSettledNotices()
            // Watched again once the snapshot says how (§15.25).
            browser.rewatch()
            takeFullConversation(response.fullConversation == true)
        }
        for taskID in subscribed { subscribe(taskID) }
    }

    /// What the list says of full detail (§15.24), kept with the saved Mac. A conversation asked for in the other
    /// detail, before the list answered or from a Mac that changed since, is asked for again in this one.
    private func takeFullConversation(_ full: Bool) {
        if full != fullConversation {
            fullConversation = full
            host.fullConversation = full ? true : nil
            store?.save(host)
        }
        for taskID in subscribed {
            if let detail = subscribedDetail[taskID], detail != (full ? .full : .basic) { requestPage(taskID) }
        }
    }

    /// Pull to refresh: the list read again.
    func refresh() async {
        guard isConnected else {
            reconnectNow()
            return
        }
        let response = await response(to: .snapshot)
        guard response.ok else { return }
        projects = response.projects ?? []
        tasks = (response.tasks ?? []).sorted { $0.lastActivityAt > $1.lastActivityAt }
        newTask = response.newTask
        followUp = response.followUp
        applyFlags(response)
        withdrawSettledNotices()
        takeFullConversation(response.fullConversation == true)
    }

    /// What the snapshot says the Mac answers.
    private func applyFlags(_ snapshot: RemoteResponse) {
        taskControls = snapshot.taskControls == true
        suggestionOptions = snapshot.suggestionOptions == true
        composerExtensions = snapshot.composerExtensions == true
        scheduledTasks = snapshot.scheduledTasks == true
        taskFiles = snapshot.taskFiles == true
        nextSteps = snapshot.nextSteps == true
        subtasks = snapshot.subtasks == true
        capabilities = Capabilities(
            scheduledTasks: snapshot.scheduledTasks == true,
            hostSettings: snapshot.hostSettings == true,
            hostAccounts: snapshot.hostAccounts == true,
            hostCalendar: snapshot.hostCalendar == true,
            hostMail: snapshot.hostMail == true
        )
        browser.apply(snapshot)
        if capabilities.hostCalendar || capabilities.hostMail {
            Task { await refreshMailCalendarState() }
        } else {
            mailCalendarState = nil
        }
        if capabilities.hostSettings {
            if watchingHostSettingsCount > 0 {
                Task { _ = await fetchHostSettings(watching: true) }
            }
        } else {
            hostSettings = nil
        }
        if capabilities.hostAccounts {
            if watchingHostAccountsCount > 0 {
                Task { _ = await fetchHostAccounts(watching: true) }
            }
        } else {
            hostAccounts = nil
        }
    }

    /// Reads Mail and Calendar readiness and this device's permission from the Mac (§15.38).
    func refreshMailCalendarState() async {
        guard isConnected, capabilities.hostCalendar || capabilities.hostMail else { return }
        let response = await response(to: .mailCalendarState(watching: true))
        if response.ok, let state = response.mailCalendarState {
            mailCalendarState = state
        }
    }

    // MARK: - Host Settings & Accounts (§15.36, §15.37)

    func watchHostSettings() async {
        watchingHostSettingsCount += 1
        _ = await fetchHostSettings(watching: true)
    }

    func unwatchHostSettings() {
        guard watchingHostSettingsCount > 0 else { return }
        watchingHostSettingsCount -= 1
        if watchingHostSettingsCount == 0, capabilities.hostSettings, isConnected {
            request(.hostSettings(watching: false))
        }
    }

    @discardableResult
    func fetchHostSettings(watching: Bool = true) async -> RemoteHostSettings? {
        guard isConnected, capabilities.hostSettings else { return nil }
        guard !readingHostSettings else {
            dirtyHostSettings = true
            return hostSettings
        }
        readingHostSettings = true
        defer { readingHostSettings = false }
        repeat {
            dirtyHostSettings = false
            let answer = await response(to: .hostSettings(watching: watching))
            guard capabilities.hostSettings else { return nil }
            if answer.ok, let page = answer.settingsPage {
                if hostSettings != page { hostSettings = page }
            } else if !answer.ok {
                commandError = Self.message(for: answer.error, host: name)
            }
        } while dirtyHostSettings && isConnected
        return hostSettings
    }

    @discardableResult
    func setHostSetting(id: String, value: String, confirmed: Bool = false) async -> Bool {
        guard isConnected, capabilities.hostSettings else { return false }
        let answer = await response(to: .setHostSetting(setting: id, value: value, confirmed: confirmed))
        if answer.ok, let page = answer.settingsPage {
            hostSettings = page
            return true
        }
        commandError = Self.message(for: answer.error, host: name, otherwise: [
            .notAllowed: String(localized: "Allow Change settings for this device on \(name) to edit settings.")
        ])
        return false
    }

    @discardableResult
    func saveHostInstructions(text: String) async -> Bool {
        guard isConnected, capabilities.hostSettings else { return false }
        let answer = await response(to: .saveHostInstructions(text: text))
        if answer.ok, let page = answer.settingsPage {
            hostSettings = page
            return true
        }
        commandError = Self.message(for: answer.error, host: name, otherwise: [
            .notAllowed: String(localized: "Allow Change settings for this device on \(name) to edit instructions.")
        ])
        return false
    }

    @discardableResult
    func runHostCLIUpdate(action: String, harness: String? = nil) async -> Bool {
        guard isConnected, capabilities.hostSettings else { return false }
        let answer = await response(to: .hostCLIUpdate(action: action, harness: harness))
        if answer.ok, let page = answer.settingsPage {
            hostSettings = page
            return true
        }
        commandError = Self.message(for: answer.error, host: name, otherwise: [
            .notAllowed: String(localized: "Allow Change settings for this device on \(name) to update CLIs.")
        ])
        return false
    }

    func watchHostAccounts() async {
        watchingHostAccountsCount += 1
        _ = await fetchHostAccounts(watching: true)
    }

    func unwatchHostAccounts() {
        guard watchingHostAccountsCount > 0 else { return }
        watchingHostAccountsCount -= 1
        if watchingHostAccountsCount == 0, capabilities.hostAccounts, isConnected {
            request(.hostAccounts(watching: false))
        }
    }

    @discardableResult
    func fetchHostAccounts(watching: Bool = true, refreshHarnesses: [String] = []) async -> RemoteAccountsState? {
        guard isConnected, capabilities.hostAccounts else { return nil }
        let answer = await response(to: .hostAccounts(watching: watching, refreshHarnesses: refreshHarnesses))
        if answer.ok, let state = answer.hostAccountsState {
            if hostAccounts != state { hostAccounts = state }
            return state
        }
        if !answer.ok {
            commandError = Self.message(for: answer.error, host: name)
        }
        return nil
    }

    @discardableResult
    func setHostAccount(
        harness: String? = nil,
        accountID: String? = nil,
        automaticAssignment: Bool? = nil,
        settingID: String? = nil,
        enabled: Bool? = nil
    ) async -> Bool {
        guard isConnected, capabilities.hostAccounts else { return false }
        let answer = await response(to: .setHostAccount(
            harness: harness,
            accountID: accountID,
            automaticAssignment: automaticAssignment,
            settingID: settingID,
            enabled: enabled
        ))
        if answer.ok {
            if let state = answer.hostAccountsState { hostAccounts = state }
            return true
        }
        commandError = Self.message(for: answer.error, host: name, otherwise: [
            .notAllowed: String(localized: "Allow Change settings for this device on \(name) to change accounts.")
        ])
        return false
    }

    @discardableResult
    func setHostConnector(id: String, enabled: Bool) async -> Bool {
        guard isConnected, capabilities.hostAccounts else { return false }
        let answer = await response(to: .setHostConnector(id: id, enabled: enabled))
        if answer.ok {
            if let state = answer.hostAccountsState { hostAccounts = state }
            return true
        }
        commandError = Self.message(for: answer.error, host: name, otherwise: [
            .notAllowed: String(localized: "Allow Change settings for this device on \(name) to change connectors.")
        ])
        return false
    }

    func sendConnectorSetup(_ setup: RemoteConnectorSetupRequest) async -> RemoteResponse {
        guard isConnected, capabilities.hostAccounts else {
            return .failure(setup.operationID, RemoteError(.unavailable, "Not connected"))
        }
        return await response(to: .connectorSetup(setup))
    }

    private func applyTasks(changed: [RemoteTask], removed: [String]) {
        guard !changed.isEmpty || !removed.isEmpty else { return }
        var next = tasks
        let gone = Set(removed)
        if !gone.isEmpty { next.removeAll { gone.contains($0.id) } }
        for task in changed {
            if let index = next.firstIndex(where: { $0.id == task.id }) { next[index] = task } else { next.append(task) }
        }
        next.sort { $0.lastActivityAt > $1.lastActivityAt }
        tasks = next
    }

    func task(_ id: String) -> RemoteTask? {
        tasks.first { $0.id == id }
    }

    func project(_ id: String?) -> RemoteProject? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    /// A time the Mac wrote, on this phone's clock.
    func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000 - clockOffset)
    }

    // MARK: - Push

    /// The Mac pushes through its relay, which sends only to a target bound to the Mac's room (§14.5): on each
    /// connection the phone binds its token there and gives the Mac the target, never the token.
    private func registerPush() {
        guard isConnected, !isDemo, let registration = pushRegistration,
              let relay = PushTargets.relay(for: host), let room = host.room else { return }
        let connection = connectionNumber
        let previous = registeringPush
        registeringPush = Task { [weak self, id] in
            await previous?.value
            // The connection this was asked on ended while an earlier registration ran (the Mac removed, the app sent to
            // the background): nothing is registered for it.
            guard let self, connectionNumber == connection, isConnected else { return }
            guard let target = await PushTargets.register(provider: registration.provider, token: registration.token,
                                                          relay: relay, room: room, hostID: id),
                  connectionNumber == connection, isConnected else { return }
            let answer = await response(to: .registerPush(provider: registration.provider, token: target))
            guard answer.ok, let text = answer.pushKey, let key = RemoteEncoding.data(base64url: text),
                  let keyID = answer.pushKeyId else { return }
            onPushKey?(key, keyID)
        }
    }

    // MARK: - Notifications

    /// Takes back this Mac's notifications of the tasks `matching` picks, and their count on the badge.
    private func withdrawNotices(_ matching: @escaping @Sendable (_ taskID: String) -> Bool) {
        let hostID = id
        Task { await PushNotice.withdraw { $0 == hostID && matching($1) } }
    }

    /// The list read again: notifications of tasks no longer waiting or holding an unread result go, answered, read or
    /// removed while the phone was away. iOS may never hand the app the background push that withdraws them (§16).
    private func withdrawSettledNotices() {
        let notified = Set(tasks.filter { $0.attention == .waiting || $0.attention == .unread }.map(\.id))
        withdrawNotices { !notified.contains($0) }
    }

    /// Allow Once from an approval's notification (§4.4, §5.2, §6.5). The task's page is read again on this
    /// connection, and `allowOnce` goes only while that page holds the same ordinary request, pending and offering it,
    /// with a command short enough to allow unread (`allowsUnread`), over the connection that read it, and while
    /// `mayAnswer` holds. A longer command is left on its card for the person to read and allow there. An answer that
    /// does not come back is not sent again.
    func allowOnceFromNotification(taskID: String, requestID: String, mayAnswer: () -> Bool) async {
        guard isConnected else {
            commandError = Self.message(for: RemoteError(.unavailable), host: name)
            return
        }
        let connection = connectionNumber
        if conversations[taskID] == nil { conversations[taskID] = ConversationState(taskID: taskID) }
        let page = await withCheckedContinuation { continuation in
            subscribe(taskID) { continuation.resume(returning: $0) }
        }
        guard connectionNumber == connection, isConnected, mayAnswer() else { return }
        guard page.ok else {
            commandError = Self.message(for: page.error, host: name)
            return
        }
        guard let request = conversations[taskID]?.pendingRequests.first(where: { $0.requestId == requestID }),
              (request.requestKind ?? "approval") == "approval",
              request.options?.contains(RemoteApprovalAnswer.allowOnce.rawValue) == true else {
            commandError = Self.message(for: RemoteError(.requestNotFound), host: name)
            return
        }
        guard Self.allowsUnread(request) else {
            commandError = String(localized: "This command is too long to allow from a notification. Read it whole, then allow it.")
            return
        }
        await perform(.answerApproval(taskID: taskID, requestID: requestID, answer: .allowOnce))
    }

    /// The longest line a notification says about a request (§5.2 `summary`).
    static let noticeLine = 120

    /// A request a notification may allow without its card being read: its command came whole, on one line and no
    /// longer than a notification's line, or it has none.
    static func allowsUnread(_ request: RemoteItem) -> Bool {
        let command = (request.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty
            || (request.truncated != true && command.count <= noticeLine && !command.contains(where: \.isNewline))
    }

    // MARK: - Conversations

    /// The conversation of a task shown now, subscribed if it was not.
    func open(_ taskID: String) -> ConversationState {
        let conversation: ConversationState
        if let open = conversations[taskID] {
            conversation = open
            subscribed.removeAll { $0 == taskID }
            subscribed.append(taskID)
        } else {
            conversation = ConversationState(taskID: taskID)
            conversations[taskID] = conversation
            subscribe(taskID)
        }
        if isConnected, task(taskID)?.unread == true { send(.markRead(taskID: taskID)) }
        // Read now: its notification has done its work.
        withdrawNotices { $0 == taskID }
        return conversation
    }

    /// Subscribes to a task's conversation; `then` runs once its page is applied, or the Mac refused it.
    private func subscribe(_ taskID: String, then: ((RemoteResponse) -> Void)? = nil) {
        subscribed.removeAll { $0 == taskID }
        subscribed.append(taskID)
        // The conversations shown longest ago are let go.
        while subscribed.count > Self.keptSubscriptions {
            let dropped = subscribed.removeFirst()
            conversations[dropped] = nil
            taskSettings[dropped] = nil
            composerStates[dropped] = nil
            outputs[dropped] = nil
            subscribedDetail[dropped] = nil
            send(.unsubscribeTask(taskID: dropped))
        }
        requestPage(taskID, then: then)
    }

    /// Asks for a conversation's latest page and its changes from now on, in full detail from a Mac that answers it
    /// (§4.2, §15.24): pictures, a running command's output, a subagent's card, a compaction's and a limit's own fields.
    private func requestPage(_ taskID: String, then: ((RemoteResponse) -> Void)? = nil) {
        guard isConnected else {
            then?(.failure("", RemoteError(.unavailable)))
            return
        }
        let detail: RemoteConversationDetail = fullConversation ? .full : .basic
        subscribedDetail[taskID] = detail
        request(.subscribeTask(taskID: taskID, detail: detail)) { [weak self] response in
            defer { then?(response) }
            guard let conversation = self?.conversations[taskID] else { return }
            if response.ok {
                conversation.load(response.items ?? [], cursor: response.cursor, hasOlder: response.hasOlder == true)
                // Read once subscribed, so the Mac tells of their changes from now on.
                Task {
                    await self?.readTaskSettings(taskID)
                    await self?.readComposerState(taskID)
                }
            } else if response.error?.code == .notFound {
                conversation.markGone()
            }
        }
    }

    /// Earlier turns of a shown conversation (§4.2 `loadOlder`).
    func loadOlder(_ taskID: String) {
        guard let conversation = conversations[taskID], conversation.hasOlder, !conversation.isLoadingOlder,
              let cursor = conversation.cursor else { return }
        conversation.setLoadingOlder(true)
        request(.loadOlder(taskID: taskID, cursor: cursor)) { [weak self] response in
            guard let conversation = self?.conversations[taskID] else { return }
            if response.ok {
                conversation.prepend(response.items ?? [], cursor: response.cursor, hasOlder: response.hasOlder == true)
            } else {
                conversation.setLoadingOlder(false)
                if response.error?.code == .invalidCursor { self?.subscribe(taskID) }
            }
        }
    }

    /// What a line holds beyond its words (§15.8), read once.
    func loadDetail(_ taskID: String, itemID: String) {
        guard let conversation = conversations[taskID], conversation.beginLoadingDetail(itemID) else { return }
        request(.itemDetail(taskID: taskID, itemID: itemID)) { [weak self] response in
            if response.error?.code == .unavailable {
                self?.conversations[taskID]?.cancelLoadingDetail(itemID)
                return
            }
            let detail = response.ok
                ? RemoteItemDetail(output: response.output, outputTruncated: response.outputTruncated == true,
                                   diffs: response.diffs ?? [])
                : RemoteItemDetail()
            self?.conversations[taskID]?.setDetail(detail, for: itemID)
        }
    }

    // MARK: - Task settings (§15.23)

    func readTaskSettings(_ taskID: String, prepare: Bool = false) async {
        guard taskControls else { return }
        let response = await response(to: .taskSettings(taskID: taskID, prepare: prepare))
        if response.ok, let settings = response.settings { taskSettings[taskID] = settings }
    }

    /// Changes a setting through the Mac's control; why the Mac refused it, for the sheet that asked, or nil.
    func setTaskSetting(_ taskID: String, setting: String, value: String) async -> String? {
        let response = await response(to: .setTaskSetting(taskID: taskID, setting: setting, value: value,
                                                           confirmed: false))
        guard response.ok else { return Self.message(for: response.error, host: name) }
        if let settings = response.settings { taskSettings[taskID] = settings }
        return nil
    }

    // MARK: - The composer's state and the turn's next steps (§15.33, §15.31)

    private func readComposerState(_ taskID: String) async {
        guard composerExtensions else { return }
        let response = await response(to: .composerState(taskID: taskID))
        if response.ok, let state = response.composerState, conversations[taskID] != nil { composerStates[taskID] = state }
    }

    /// A queued message's Retry, Move Up, Move Down or new words (`edit` with `value`), or `resume` for a queue the
    /// person paused by stopping a turn. The answer carries the composer's state after it.
    @discardableResult
    func composerAction(_ taskID: String, action: String, itemID: String? = nil, value: String? = nil) async -> Bool {
        let response = await response(to: .composerAction(taskID: taskID, action: action, itemID: itemID, value: value))
        if response.ok {
            if let state = response.composerState, conversations[taskID] != nil { composerStates[taskID] = state }
        } else {
            commandError = Self.message(for: response.error, host: name)
        }
        return response.ok
    }

    /// What a turn offers next, as the Mac's card does: Retry its error, or Resume once its limit reset (§15.31).
    func nextStep(_ taskID: String, turnID: String, action: RemoteNextStep) {
        Task { await nextStep(taskID, turnID: turnID, action: action, text: nil) }
    }

    // MARK: - Subagents (§15.31)

    /// Why the Mac did not read or stop a subagent, in a line for the sheet that asked.
    struct Refusal: Error {
        let message: String
    }

    /// A Claude Code subagent's conversation, its latest turns, as the Mac's subtask pane reads it.
    func readSubtask(_ taskID: String, activityID: String) async -> Result<RemoteSubtaskTranscript, Refusal> {
        let response = await response(to: .subtask(taskID: taskID, activityID: activityID, stop: false))
        if response.ok { return .success(response.subtask ?? RemoteSubtaskTranscript()) }
        return .failure(Refusal(message: subtaskRefusal(response.error)
            ?? String(localized: "Couldn't load the subagent's conversation.")))
    }

    /// Stops a Claude Code subagent as its card's Stop on the Mac does; why the Mac refused, or nil. The line says
    /// it stopped when the Mac's next change comes.
    func stopSubtask(_ taskID: String, activityID: String) async -> String? {
        let response = await response(to: .subtask(taskID: taskID, activityID: activityID, stop: true))
        guard !response.ok else { return nil }
        return subtaskRefusal(response.error) ?? Self.message(for: response.error, host: name)
    }

    private func subtaskRefusal(_ error: RemoteError?) -> String? {
        switch error?.code {
        case .notFound?: String(localized: "\(name) no longer has this subagent.")
        case .unavailable? where error?.reason == nil: String(localized: "Can't reach \(name) right now.")
        default: nil
        }
    }

    // MARK: - Link requests (§12.1, §15.11)

    struct LinkRequest: Identifiable, Equatable {
        let id: String
        let name: String?
        let code: String
    }

    func answerLink(_ requestID: String, approve: Bool) {
        linkRequests.removeAll { $0.id == requestID }
        send(.answerLink(requestID: requestID, approve: approve))
    }

    // MARK: - Slash commands, edit and fork (§15.23)

    /// The task's slash commands that may run from the phone, in the Mac's list's order and words; nil when the Mac
    /// could not say.
    func composerCommands(_ taskID: String) async -> [RemoteComposerCommand]? {
        guard taskControls, isConnected else { return nil }
        let response = await response(to: .composerCommands(taskID: taskID))
        return response.ok ? response.commands ?? [] : nil
    }

    /// Runs a slash command as the Mac's composer does. Whether the Mac took it, and the task it started (`/clear`,
    /// New chat, Fork chat), which the phone opens as the Mac's window opens it; a refusal shows as a command's does.
    func runComposerCommand(_ taskID: String, name: String, arguments: String? = nil) async -> (ok: Bool, started: String?) {
        let response = await response(to: .runComposerCommand(taskID: taskID, command: name, arguments: arguments))
        guard response.ok else {
            var words = [RemoteErrorCode.notAllowed: String(localized: "This command can't run now.")]
            if task(taskID)?.running == true { words[.busy] = String(localized: "Available once this turn ends.") }
            commandError = Self.message(for: response.error, host: self.name, otherwise: words)
            return (false, nil)
        }
        return (true, response.taskId.flatMap { $0 == taskID ? nil : $0 })
    }

    /// Edit Message and Send: the turn is replaced by the edited message, whose pictures stay with it.
    func editMessage(_ taskID: String, turnID: String, text: String) async -> Bool {
        let response = await response(to: .editMessage(taskID: taskID, turnID: turnID, text: text))
        if !response.ok {
            commandError = Self.message(for: response.error, host: name,
                                        otherwise: [.notAllowed: String(localized: "This message can't be edited now.")])
        }
        return response.ok
    }

    /// Fork from Here: the fork's task ID once the Mac started it, listed before the answer.
    func fork(_ taskID: String, turnID: String) async -> String? {
        let response = await response(to: .forkTask(taskID: taskID, turnID: turnID))
        guard response.ok else {
            commandError = Self.message(for: response.error, host: name, otherwise: [
                .notAllowed: String(localized: "You can't fork from this turn now."),
                .internal: String(localized: "The fork didn't start.")
            ])
            return nil
        }
        return response.taskId
    }

    /// A refusal in the person's words; one that names no reason takes the words `otherwise` gives its code, as what
    /// the request was about says more than the code alone.
    static func message(for error: RemoteError?, host: String, otherwise: [RemoteErrorCode: String]) -> String {
        if let error, error.reason == nil, let words = otherwise[error.code] { return words }
        return message(for: error, host: host)
    }

    // MARK: - Next steps (§15.31)

    /// A turn's next step, for the turn the screen showed when the person chose it, and whether the Mac took it. One
    /// the conversation moved past says so.
    @discardableResult
    func nextStep(_ taskID: String, turnID: String, action: RemoteNextStep, text: String?) async -> Bool {
        let response = await response(to: .nextStep(taskID: taskID, turnID: turnID, action: action, text: text))
        if !response.ok {
            let moved = String(localized: "The task has changed, so this can't be done now.")
            commandError = Self.message(for: response.error, host: name, otherwise: [.notFound: moved, .notAllowed: moved])
        }
        return response.ok
    }

    // MARK: - Files (§15.20)

    /// Sends a file up in parts (`RemoteFileUpload`, read off the main actor); its upload ID once the Mac holds it all.
    /// Cancelling the task (the attachment removed) stops it between parts. A refusal shows as a command's does.
    func upload(_ url: URL, mediaType: String) async -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let result = await RemoteFileUpload.send(url, mediaType: mediaType) { [weak self] part in
            await self?.response(to: .uploadFile(part)) ?? .failure("", RemoteError(.unavailable))
        }
        switch result {
        case let .success(uploadID):
            return uploadID
        case .failure(.tooLarge):
            commandError = String(localized: "The file is too large to send.")
        case let .failure(.refused(error)):
            commandError = Self.message(for: error, host: name)
        case .failure(.unreadable), .failure(.cancelled):
            break
        }
        return nil
    }

    // MARK: - Files from the Mac (§15.22)

    /// Reads the task's outputs again, as the Mac's Outputs card lists them. A failed read keeps the list shown.
    func loadOutputs(_ taskID: String) async {
        guard taskFiles, isConnected else { return }
        let response = await response(to: .taskOutputs(taskID: taskID))
        guard response.ok, conversations[taskID] != nil else { return }
        let listed = response.outputs ?? []
        if outputs[taskID] != listed { outputs[taskID] = listed }
    }

    /// Reads one of the task's files in parts into `folder` (`RemoteFileDownload`): an output, or a path its
    /// conversation names, absolute, from `~/`, or relative to the task's folder. A connection that drops after the
    /// first part is waited for a while.
    func readFile(_ path: String, of taskID: String, into folder: URL,
                  progress: @escaping @MainActor @Sendable (RemoteFileDownload.Progress) -> Void)
        async -> Result<RemoteFileDownload.File, RemoteFileDownload.Failure> {
        await RemoteFileDownload.read(into: folder) { [weak self] offset in
            await self?.response(to: .readFile(taskID: taskID, path: path, offset: offset)) ?? .failure("", RemoteError(.unavailable))
        } reconnected: { [weak self] in
            await self?.waitForConnection() ?? false
        } progress: { part in
            await progress(part)
        }
    }

    /// True once connected again within `limit`.
    private func waitForConnection(within limit: Duration = .seconds(30)) async -> Bool {
        let end = ContinuousClock.now + limit
        while !isConnected {
            guard ContinuousClock.now < end, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return true
    }

    // MARK: - Commands

    /// Sends a request; `onResponse` runs in the order responses and events arrive. A request sent while no
    /// connection is open, or cut off by a dropped one, is answered `unavailable` here.
    func request(_ request: RemoteRequest, onResponse: ((RemoteResponse) -> Void)? = nil) {
        nextRequest += 1
        let id = "p\(nextRequest)"
        pending[id] = { onResponse?($0) }
        guard let connector else { return fail(id) }
        Task {
            let sent = await connector.send(id: id, request)
            if !sent { self.fail(id) }
        }
    }

    /// A request whose answer the caller waits for.
    func response(to request: RemoteRequest) async -> RemoteResponse {
        await withCheckedContinuation { continuation in
            self.request(request) { continuation.resume(returning: $0) }
        }
    }

    /// A command whose refusal the screen shows.
    func send(_ request: RemoteRequest) {
        self.request(request) { [weak self] response in
            guard let self, !response.ok else { return }
            commandError = Self.message(for: response.error, host: name)
        }
    }

    /// Sends a command and says whether the Mac took it, the refusal shown as `send` shows it.
    @discardableResult
    func perform(_ request: RemoteRequest) async -> Bool {
        let response = await response(to: request)
        if !response.ok { commandError = Self.message(for: response.error, host: name) }
        return response.ok
    }

    private func fail(_ id: String) {
        pending.removeValue(forKey: id)?(.failure(id, RemoteError(.unavailable, "Not connected")))
    }

    /// A connection opened or lost: what waits for an answer is answered `unavailable`, and what was read before no
    /// longer counts as read on this connection (`connectionNumber`).
    private func failPending() {
        connectionNumber += 1
        browser.connectionEnded()
        let waiting = pending
        pending = [:]
        for (id, handler) in waiting { handler(.failure(id, RemoteError(.unavailable, "Not connected"))) }
    }

    /// A refusal in the person's words. The Mac's own words are shown only where they are meant for the person, with
    /// the reasons `failed` and `form`; otherwise `message` is an English diagnostic for logs (§2, §8).
    static func message(for error: RemoteError?, host: String) -> String {
        if let error, error.reason == .failed || error.reason == .form,
           !error.message.isEmpty, error.message != error.code.rawValue {
            return error.message
        }
        if let reason = error?.reason, let words = words(for: reason, host: host) { return words }
        switch error?.code {
        case .unavailable?: return String(localized: "Can't reach \(host) right now.")
        case .busy?: return String(localized: "\(host) is changing this task. Try again in a moment.")
        case .requestNotFound?: return String(localized: "This request was already answered.")
        case .notAllowed?: return String(localized: "That isn't offered for this task now.")
        case .unsupportedCommand?: return String(localized: "Slash commands run on \(host).")
        case .tooLarge?: return String(localized: "The message is too long.")
        case .emptyMessage?: return String(localized: "Write a message first.")
        case .rateLimited?: return String(localized: "Too many requests. Try again in a moment.")
        case .notRunning?: return String(localized: "Nothing is running.")
        case .notFound?: return String(localized: "\(host) no longer lists this task.")
        default: return String(localized: "\(host) couldn't do that.")
        }
    }

    /// What a refusal's reason says, whatever its code (§8); nil for the reasons that carry the Mac's own words.
    static func words(for reason: RemoteRefusal, host: String) -> String? {
        switch reason {
        case .harness: String(localized: "\(host) can't use this harness now.")
        case .setting: String(localized: "\(host) doesn't take this setting now.")
        case .confirmation: String(localized: "Confirm this choice on \(host).")
        case .terminal:
            String(localized: "To use this from here, allow Terminal for this device in Settings › Remote › Paired devices on \(host).")
        case .fileWrites:
            String(localized: "To change files from here, allow Write files for this device in Settings › Remote › Paired devices on \(host).")
        case .fileChanged: String(localized: "The file changed on \(host). Open it again.")
        case .account: String(localized: "\(host) can't move this task to that account now.")
        case .worktree: String(localized: "This project isn't in a Git repository, so it can't start in a new worktree.")
        case .attachments: String(localized: "This task doesn't take pictures or files.")
        case .signIn: String(localized: "Sign in to the harness on \(host) first.")
        case .folderMissing: String(localized: "This task's folder is no longer on \(host).")
        case .notConnected: String(localized: "This task isn't connected to its harness on \(host).")
        case .otherApp: String(localized: "Another app is using this task's conversation.")
        case .editing: String(localized: "A message of this task is being edited on \(host).")
        case .changing: String(localized: "This task is changing on \(host). Try again in a moment.")
        case .queue: String(localized: "Messages are waiting in the queue, so this can't be done now.")
        case .running: String(localized: "This can be done once the turn ends.")
        case .hostOnly: String(localized: "Do this on \(host).")
        case .mailCalendar:
            String(localized: "To use Mail and Calendar from here, allow Mail and Calendar for this device in Settings › Remote › Paired devices on \(host).")
        case .failed, .form: nil
        }
    }
}
