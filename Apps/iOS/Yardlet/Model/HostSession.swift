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
    private(set) var conversations: [String: ConversationState] = [:]
    /// Each open task's composer settings as the Mac last answered them (§15.23).
    private(set) var taskSettings: [String: [RemoteSetting]] = [:]
    /// The Mac's clock minus this phone's, so times read as the Mac wrote them (§2).
    private(set) var clockOffset: TimeInterval = 0
    /// The last command the Mac refused, in a line for the screen.
    var commandError: String?

    /// How this phone asks for pushes, once the system gave it a token.
    @ObservationIgnored var pushRegistration: (provider: String, token: String)? {
        didSet { if pushRegistration?.token != oldValue?.token { registerPush() } }
    }
    /// The push key the Mac made for this phone (§15.6), to keep for the notification service extension.
    @ObservationIgnored var onPushKey: ((_ key: Data, _ keyID: String) -> Void)?

    @ObservationIgnored private var connector: RemoteHostConnection?
    @ObservationIgnored private let clientKey: RemoteKeyPair
    @ObservationIgnored private let hello: RemoteHandshakeHello
    @ObservationIgnored private let store: RemoteHostStore?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var finder: BonjourFinder?
    @ObservationIgnored private var pending: [String: (RemoteResponse) -> Void] = [:]
    @ObservationIgnored private var nextRequest = 0
    /// Subscriptions, the least recently shown first; a Mac takes 8 per connection (§7).
    @ObservationIgnored private var subscribed: [String] = []
    @ObservationIgnored static let keptSubscriptions = 6

    init(host: RemoteSavedHost, clientKey: RemoteKeyPair, hello: RemoteHandshakeHello, store: RemoteHostStore?,
         isDemo: Bool = false) {
        id = host.id
        self.host = host
        self.clientKey = clientKey
        self.hello = hello
        self.store = store
        self.isDemo = isDemo
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
            subscribed.removeAll { $0 == taskID }
            applyTasks(changed: [], removed: [taskID])
        case .taskSettingsChanged:
            guard let taskID = event.taskId, conversations[taskID] != nil else { return }
            Task { await readTaskSettings(taskID) }
        case .closing:
            closingReason = event.reason
        case .revoked:
            connection = .removed
        case .attention, .schedulesChanged, .linked, .linkRefused, .linkRequest, .linkResolved, .tabFrame,
             .browserTabsChanged:
            // Not shown on the phone yet: schedules, link requests and a task's browser tab (§15.21, §15.11).
            break
        }
    }

    /// The list again, then each open conversation's latest page: what changed while away.
    private func resync() {
        request(.snapshot) { [weak self] response in
            guard let self, response.ok else { return }
            projects = response.projects ?? []
            tasks = (response.tasks ?? []).sorted { $0.lastActivityAt > $1.lastActivityAt }
            newTask = response.newTask
            followUp = response.followUp
            taskControls = response.taskControls == true
            if let serverTime = response.serverTime {
                clockOffset = Double(serverTime) / 1000 - Date().timeIntervalSince1970
            }
            hasSnapshot = true
        }
        for taskID in subscribed { subscribe(taskID) }
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
        taskControls = response.taskControls == true
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

    private func registerPush() {
        guard isConnected, !isDemo, let registration = pushRegistration else { return }
        request(.registerPush(provider: registration.provider, token: registration.token)) { [weak self] response in
            guard let self, response.ok, let text = response.pushKey, let key = RemoteEncoding.data(base64url: text),
                  let keyID = response.pushKeyId else { return }
            onPushKey?(key, keyID)
        }
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
        return conversation
    }

    private func subscribe(_ taskID: String) {
        subscribed.removeAll { $0 == taskID }
        subscribed.append(taskID)
        // The conversations shown longest ago are let go.
        while subscribed.count > Self.keptSubscriptions {
            let dropped = subscribed.removeFirst()
            conversations[dropped] = nil
            taskSettings[dropped] = nil
            send(.unsubscribeTask(taskID: dropped))
        }
        guard isConnected else { return }
        request(.subscribeTask(taskID: taskID, detail: .basic)) { [weak self] response in
            guard let conversation = self?.conversations[taskID] else { return }
            if response.ok {
                conversation.load(response.items ?? [], cursor: response.cursor, hasOlder: response.hasOlder == true)
                // Read once subscribed, so the Mac tells of their changes from now on.
                Task { await self?.readTaskSettings(taskID) }
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

    func setTaskSetting(_ taskID: String, setting: String, value: String, confirmed: Bool) async {
        let response = await response(to: .setTaskSetting(taskID: taskID, setting: setting, value: value,
                                                           confirmed: confirmed))
        if response.ok {
            if let settings = response.settings { taskSettings[taskID] = settings }
        } else {
            commandError = Self.message(for: response.error, host: name)
        }
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

    private func failPending() {
        let waiting = pending
        pending = [:]
        for (id, handler) in waiting { handler(.failure(id, RemoteError(.unavailable, "Not connected"))) }
    }

    /// A refusal in the person's words.
    static func message(for error: RemoteError?, host: String) -> String {
        switch error?.code {
        case .unavailable?: String(localized: "Can't reach \(host) right now.")
        case .busy?: String(localized: "\(host) is changing this task. Try again in a moment.")
        case .requestNotFound?: String(localized: "This request was already answered.")
        case .notAllowed?:
            error.flatMap { $0.message.isEmpty ? nil : $0.message } ?? String(localized: "That isn't offered for this task now.")
        case .unsupportedCommand?: String(localized: "Slash commands run on \(host).")
        case .tooLarge?: String(localized: "The message is too long.")
        case .emptyMessage?: String(localized: "Write a message first.")
        case .rateLimited?: String(localized: "Too many requests. Try again in a moment.")
        case .notRunning?: String(localized: "Nothing is running.")
        case .notFound?: String(localized: "\(host) no longer lists this task.")
        default: String(localized: "\(host) couldn't do that.")
        }
    }
}
