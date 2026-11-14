import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
import YardletRemote

extension RemoteHostStore {
    /// The hosts in `file`, with the person told of a file that could not be read or saved as they are of
    /// Yardlet's other state files (`StateFile`). The store keeps its own file: the phone app shares it.
    static func file(_ file: URL) -> RemoteHostStore {
        RemoteHostStore(fileURL: file) { event in
            switch event {
            case .unreadable: StateFile.reportUnreadable(file)
            case .saved(let saved): StateFile.report(file, saved: saved)
            }
        }
    }
}

/// The other Macs this one paired with as a client, and the ones open in windows now (File › Connect to
/// Mac…). Nothing runs until a host's window opens: no listener, no daemon, no login item, only outgoing
/// connections while a window is open. What stays on this Mac is the list of hosts
/// (`~/.yardlet/remote/hosts.json`), a key per host and what each host's window last showed
/// (`RemoteHostCache`); removing a host removes all three and asks the host to forget this Mac.
@MainActor
@Observable
final class RemoteHostDirectory {
    enum PairingFailure: Error, Equatable {
        case notALink
        case linkSpent
        case unreachable(String)
        case refused(String)

        var message: String {
            switch self {
            case .notALink: L10n.string("This isn't a Yardlet connection link. Copy it again from Settings › Remote on the other Mac.")
            case .linkSpent: L10n.string("This link was already used or has expired. Make a new one in Settings › Remote on the other Mac.")
            case let .unreachable(name): L10n.format("Can't reach %@. Check that it's awake and that remote connections are on.", name)
            case let .refused(name): L10n.format("%@ didn't accept the connection.", name)
            }
        }
    }

    private(set) var hosts: [RemoteSavedHost]
    /// The host IDs whose windows are open now.
    private(set) var openHostIDs: Set<String> = []
    /// A connection link opened with Yardlet, for the connect window's field; nothing pairs until the person
    /// chooses Connect there.
    var openedLink: String?
    /// Open a host's window and the connect window; the app's windows set them.
    @ObservationIgnored var openHostWindow: ((String) -> Void)?
    @ObservationIgnored var openConnectWindow: (() -> Void)?
    @ObservationIgnored private var models: [String: RemoteHostModel] = [:]
    @ObservationIgnored private let store: RemoteHostStore
    @ObservationIgnored private let keys: any RemoteClientKeyStoring
    @ObservationIgnored private let hello: RemoteHandshakeHello
    @ObservationIgnored private let timing: RemoteHostConnection.Timing
    /// Where each host's window keeps what it last showed; nil keeps nothing.
    @ObservationIgnored private let cacheRoot: URL?
    @ObservationIgnored private let discovery: RemoteHostDiscovery?
    /// Each host's `attention` events, for notifications.
    @ObservationIgnored var onAttention: ((RemoteHostModel, RemoteEvent) -> Void)?
    /// Each host's withdrawn task notifications (hostID, taskID).
    @ObservationIgnored var onWithdrawTaskNotification: ((String, String) -> Void)?

    init(store: RemoteHostStore, keys: any RemoteClientKeyStoring, hello: RemoteHandshakeHello,
         timing: RemoteHostConnection.Timing = .init(), cacheRoot: URL? = nil,
         discovery: RemoteHostDiscovery? = nil) {
        self.store = store
        self.keys = keys
        self.hello = hello
        self.timing = timing
        self.cacheRoot = cacheRoot
        self.discovery = discovery
        hosts = store.all()
        if let cacheRoot { RemoteHostCache.removeAll(in: cacheRoot, except: Set(hosts.map(\.id))) }
    }

    func host(_ id: String) -> RemoteSavedHost? {
        hosts.first { $0.id == id }
    }

    /// The models of the host windows that are open now, in `hosts` order.
    var openModels: [RemoteHostModel] {
        _ = openHostIDs
        return hosts.compactMap { models[$0.id] }
    }

    /// The models of the host windows that are open and connected now, in `hosts` order.
    var connectedModels: [RemoteHostModel] {
        openModels.filter(\.isConnected)
    }

    /// The tasks that need the person across the host windows that are open and connected now.
    var attentionBadgeCount: Int {
        connectedModels.reduce(0) { $0 + $1.attentionBadgeCount }
    }

    /// The model of a host's window, connecting from now on; nil for a host no longer saved.
    func model(for hostID: String) -> RemoteHostModel? {
        if let model = models[hostID] { return model }
        guard let host = store.host(hostID), let key = keys.load(hostID: hostID) else { return nil }
        let cache = cacheRoot.flatMap { RemoteHostCache.folder(in: $0, hostID: hostID) }.map { RemoteHostCache(folder: $0) }
        let model = RemoteHostModel(host: host, clientKey: key, hello: hello, store: store, timing: timing,
                                    cache: cache, discovery: discovery)
        model.onAttention = { [weak self, weak model] event in
            guard let self, let model else { return }
            onAttention?(model, event)
        }
        model.onWithdrawTaskNotification = { [weak self] taskID in
            self?.onWithdrawTaskNotification?(hostID, taskID)
        }
        models[hostID] = model
        openHostIDs.insert(hostID)
        model.start()
        return model
    }

    /// A `yardlet-remote://pair` link another app opened with Yardlet: shown in the connect window.
    func receive(link: URL) {
        openedLink = link.absoluteString
        openConnectWindow?()
    }

    /// A click on a host task's notification: the host's window, on that task.
    func reveal(hostID: String, taskID: String) {
        guard let model = model(for: hostID) else { return }
        model.select(.task(taskID))
        openHostWindow?(hostID)
    }

    /// "Allow once" from a host task's notification, answered while the host's window is open.
    func allowOnce(hostID: String, taskID: String, requestID: String) async -> Bool {
        guard let model = models[hostID] else { return false }
        return await model.allowOnce(taskID: taskID, requestID: requestID)
    }

    /// The host's window closed: its connection ends.
    func close(_ hostID: String) {
        if let model = models.removeValue(forKey: hostID) {
            for task in model.tasks { onWithdrawTaskNotification?(hostID, task.id) }
            model.stop()
        }
        openHostIDs.remove(hostID)
        hosts = store.all()
    }

    /// Hands what the open windows keep on this Mac to the state file writer now, as Yardlet quits.
    func persistNow() {
        for model in models.values { model.files.savePanels() }
    }

    /// Pairs with the host a link names (§12), or pairs again with one saved before. The host as saved.
    func pair(link text: String) async throws -> RemoteSavedHost {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let link = RemoteSecurePairingURL.parse(url) else { throw PairingFailure.notALink }
        let key = RemoteKeyPair.generate()
        let reply: RemoteHandshakeReply
        do {
            reply = try await RemoteHostConnection.pair(link, clientKey: key, hello: hello, timing: timing)
        } catch let failure as RemoteClientSocket.Failure {
            switch failure.error?.code {
            case .pairingUnavailable?, .pairingInvalid?: throw PairingFailure.linkSpent
            case nil: throw PairingFailure.unreachable(link.name)
            default: throw PairingFailure.refused(link.name)
            }
        }
        let earlier = store.host(key: link.macKey)
        var host = earlier ?? RemoteSavedHost(name: link.name, hostKey: link.macKey, direct: link.hosts,
                                              relayURL: link.relayURL, room: link.room, alternateRelayURL: link.alternateRelayURL)
        if earlier != nil {
            // Paired again: the old key's device is the host's to remove; this window takes the new key.
            models.removeValue(forKey: host.id)?.stop()
            host.direct = link.hosts + host.direct.filter { !link.hosts.contains($0) }
        }
        host.update(from: reply)
        keys.save(key, hostID: host.id)
        store.save(host)
        hosts = store.all()
        return host
    }

    /// Removes a host: the host is asked to forget this Mac when it can be reached now (§15.6), then its
    /// entry, key and cache go. A host that cannot be reached keeps this Mac in its device list until removed
    /// there.
    func forget(_ hostID: String) async {
        if let model = models[hostID], model.isConnected {
            _ = await model.response(to: .forgetDevice)
        } else if models[hostID] == nil, let target = store.host(hostID)?.target, let key = keys.load(hostID: hostID) {
            await Self.askToForget(target: target, key: key, hello: hello, timing: timing)
        }
        if let model = models.removeValue(forKey: hostID) {
            for task in model.tasks { onWithdrawTaskNotification?(hostID, task.id) }
            model.stop()
        }
        openHostIDs.remove(hostID)
        if let folder = cacheRoot.flatMap({ RemoteHostCache.folder(in: $0, hostID: hostID) }) { RemoteHostCache.remove(folder) }
        keys.delete(hostID: hostID)
        store.remove(hostID)
        hosts = store.all()
    }

    /// Connects for a moment to send `forgetDevice`, giving up after a few seconds.
    private static func askToForget(target: RemoteHostTarget, key: RemoteKeyPair, hello: RemoteHandshakeHello,
                                    timing: RemoteHostConnection.Timing) async {
        var timing = timing
        timing.backoff = [5]
        let connection = RemoteHostConnection(target: target, clientKey: key, hello: hello, timing: timing)
        let deadline = Task {
            try? await Task.sleep(for: .seconds(6))
            await connection.stop()
        }
        await connection.start()
        for await inbound in connection.inbound {
            switch inbound {
            case .state(.connected):
                _ = await connection.send(id: "forget", .forgetDevice)
            case .response, .state(.revoked), .state(.stopped), .state(.waiting):
                deadline.cancel()
                await connection.stop()
                return
            default:
                continue
            }
        }
    }
}
