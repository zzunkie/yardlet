import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
import YardletRemote

/// Another Mac's Yardlet as this one follows it in a window of its own (docs/REMOTE_PROTOCOL.md, as a phone
/// follows it): its projects and tasks, the conversations open in the window, and every command, each sent
/// through the host's own paths. Nothing of the host's is stored here but its entry in `RemoteHostStore`:
/// provider sign-ins, sessions and histories stay on the host, and what this model holds goes with it.
///
/// Responses and events are applied in the order they arrive (`RemoteHostConnection.inbound`): a
/// subscription's page before the changes to it. After every new connection the list and the open
/// conversations are read again, as a phone does after reconnecting.
@MainActor
@Observable
final class RemoteHostModel: Identifiable {
    enum Connection: Equatable {
        case connecting
        case connected(RemoteClientPath)
        /// Not reachable now; trying again (at `retryAt`).
        case unreachable(retryAt: Date?)
        /// The host removed this computer, or no longer knows it.
        case removed
        case stopped
    }

    /// What the window shows in its detail.
    enum Selection: Equatable {
        case none
        case task(String)
        case newTask
    }

    nonisolated let id: String
    private(set) var host: RemoteSavedHost
    private(set) var connection: Connection = .stopped
    /// Why the host closed the last connection on purpose: its remote turned off, or Yardlet quit there.
    private(set) var closingReason: String?
    private(set) var hasSnapshot = false
    private(set) var projects: [RemoteProject] = []
    /// The host's listed tasks, most recently active first.
    private(set) var tasks: [RemoteTask] = []
    private(set) var newTask: RemoteNewTask?
    private(set) var followUp: RemoteFollowUpMode?
    private(set) var selection: Selection = .none
    private(set) var conversations: [String: RemoteConversationModel] = [:]
    /// The last command the host refused, in a line for the window.
    var commandError: String?

    /// Called for each `attention` event, for a notification of the host's task.
    @ObservationIgnored var onAttention: ((RemoteEvent) -> Void)?
    @ObservationIgnored private let connector: RemoteHostConnection
    @ObservationIgnored private let store: RemoteHostStore?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var pending: [String: (RemoteResponse) -> Void] = [:]
    @ObservationIgnored private var nextRequest = 0
    /// Subscriptions, the least recently shown first; a host takes 8 per connection (§7).
    @ObservationIgnored private var subscribed: [String] = []
    @ObservationIgnored static let keptSubscriptions = 6

    init(host: RemoteSavedHost, clientKey: RemoteKeyPair, hello: RemoteHandshakeHello, store: RemoteHostStore?,
         session: URLSession = .shared, timing: RemoteHostConnection.Timing = .init()) {
        id = host.id
        self.host = host
        self.store = store
        connector = RemoteHostConnection(target: host.target ?? RemoteHostTarget(hostKey: Data(), direct: []),
                                         clientKey: clientKey, hello: hello, session: session, timing: timing)
    }

    var name: String { host.name }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    func start() {
        guard reader == nil else { return }
        connection = .connecting
        let stream = connector.inbound
        reader = Task { [weak self] in
            for await inbound in stream {
                guard let self else { return }
                self.handle(inbound)
            }
        }
        Task { await connector.start() }
    }

    func stop() {
        reader?.cancel()
        reader = nil
        Task { await connector.stop() }
        failPending()
        connection = .stopped
    }

    /// The person asked to try now, or the network changed.
    func reconnectNow() {
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
            if let target = host.target { Task { await connector.update(target: target) } }
            for conversation in conversations.values { conversation.renameHost(host.name) }
            connection = .connected(path)
            resync()
        case let .waiting(retryAt, _):
            failPending()
            connection = .unreachable(retryAt: retryAt)
        case .revoked:
            failPending()
            connection = .removed
        case .stopped:
            failPending()
            connection = .stopped
        }
    }

    private func handle(_ event: RemoteEvent) {
        switch event.event {
        case .tasksChanged:
            if let projects = event.projects { self.projects = projects }
            applyTasks(changed: event.tasks ?? [], removed: event.removedTaskIds ?? [])
        case .attention:
            onAttention?(event)
        case .conversation:
            guard let taskID = event.taskId, let conversation = conversations[taskID] else { return }
            if !conversation.apply(event.changes ?? []) { subscribe(taskID) }
        case .conversationReset:
            guard let taskID = event.taskId, let conversation = conversations[taskID] else { return }
            conversation.load(event.items ?? [], cursor: event.cursor, hasOlder: event.hasOlder == true)
        case .conversationEnded:
            guard let taskID = event.taskId else { return }
            conversations[taskID] = nil
            subscribed.removeAll { $0 == taskID }
            applyTasks(changed: [], removed: [taskID])
        case .closing:
            closingReason = event.reason
        case .revoked, .linked, .linkRefused, .linkRequest, .linkResolved, .schedulesChanged:
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
            hasSnapshot = true
            if case let .task(id) = selection, !tasks.contains(where: { $0.id == id }) { selection = .none }
        }
        for taskID in subscribed { subscribe(taskID) }
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
        if case let .task(id) = selection, gone.contains(id) { selection = .none }
    }

    func task(_ id: String) -> RemoteTask? {
        tasks.first { $0.id == id }
    }

    // MARK: - Showing tasks

    func select(_ selection: Selection) {
        guard selection != self.selection else { return }
        self.selection = selection
        commandError = nil
        guard case let .task(taskID) = selection else { return }
        if conversations[taskID] == nil {
            let harness = HarnessKind(rawValue: task(taskID)?.harness ?? HarnessKind.claudeCode.rawValue)
            conversations[taskID] = RemoteConversationModel(taskID: taskID, harness: harness, hostName: host.name)
            subscribe(taskID)
        } else {
            subscribed.removeAll { $0 == taskID }
            subscribed.append(taskID)
        }
        if task(taskID)?.unread == true { send(.markRead(taskID: taskID)) }
    }

    private func subscribe(_ taskID: String) {
        subscribed.removeAll { $0 == taskID }
        subscribed.append(taskID)
        // The conversations shown longest ago are let go, the one shown kept.
        while subscribed.count > Self.keptSubscriptions {
            let dropped = subscribed.removeFirst()
            conversations[dropped] = nil
            send(.unsubscribeTask(taskID: dropped))
        }
        guard isConnected else { return }
        request(.subscribeTask(taskID: taskID)) { [weak self] response in
            guard let conversation = self?.conversations[taskID] else { return }
            if response.ok {
                conversation.load(response.items ?? [], cursor: response.cursor, hasOlder: response.hasOlder == true)
            } else if response.error?.code == .notFound {
                self?.conversations[taskID] = nil
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
            let detail = response.ok
                ? RemoteItemDetail(output: response.output, outputTruncated: response.outputTruncated == true, diffs: response.diffs ?? [])
                : nil
            self?.conversations[taskID]?.setDetail(detail, for: itemID)
        }
    }

    // MARK: - Commands

    /// Sends a request; `onResponse` runs in the order responses and events arrive. A request sent while
    /// no connection is open, or cut off by a dropped one, is answered `unavailable` here.
    func request(_ request: RemoteRequest, onResponse: ((RemoteResponse) -> Void)? = nil) {
        nextRequest += 1
        let id = "c\(nextRequest)"
        pending[id] = { onResponse?($0) }
        Task { [connector] in
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

    /// A command whose refusal the window shows.
    func send(_ request: RemoteRequest) {
        self.request(request) { [weak self] response in
            if !response.ok { self?.commandError = Self.message(for: response.error, host: self?.name ?? "") }
        }
    }

    /// Sends a command and says whether the host took it, the refusal shown as `send` shows it.
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
        case .unavailable?: L10n.format("Can't reach %@ right now.", host)
        case .busy?: L10n.format("%@ is changing this task. Try again in a moment.", host)
        case .requestNotFound?: L10n.string("This request was already answered.")
        case .notAllowed?: error?.message.isEmpty == false ? error!.message : L10n.string("That isn't offered for this task now.")
        case .unsupportedCommand?: L10n.format("Slash commands run on %@.", host)
        case .tooLarge?: L10n.string("The message is too long.")
        case .emptyMessage?: L10n.string("Write a message first.")
        case .rateLimited?: L10n.string("Too many requests. Try again in a moment.")
        case .notRunning?: L10n.string("Nothing is running.")
        case .notFound?: L10n.format("%@ no longer lists this task.", host)
        default: L10n.format("%@ couldn't do that.", host)
        }
    }

    // MARK: - Files

    /// Sends a file up in parts (§15.20); its upload ID once the host holds it all.
    func upload(_ url: URL, mediaType: String) async -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 0, size <= RemoteProtocol.maxFileBytes else {
            commandError = L10n.string("The file is too large to send.")
            return nil
        }
        let uploadID = UUID().uuidString
        var offset = 0
        while offset < size {
            try? handle.seek(toOffset: UInt64(offset))
            guard let data = try? handle.read(upToCount: RemoteProtocol.maxUploadPartBytes), !data.isEmpty else { return nil }
            let part = RemoteUploadPart(uploadID: uploadID, name: offset == 0 ? url.lastPathComponent : nil,
                                        mediaType: offset == 0 ? mediaType : nil, size: offset == 0 ? size : nil,
                                        offset: offset, data: data)
            let response = await response(to: .uploadFile(part))
            guard response.ok, let received = response.received else {
                commandError = Self.message(for: response.error, host: name)
                return nil
            }
            offset = received
        }
        return uploadID
    }
}
