import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
import YardletRemote

/// The other Macs this one paired with as a client, and the ones open in windows now (File › Connect to
/// Mac…). Nothing runs until a host's window opens: no listener, no daemon, no login item, only outgoing
/// connections while a window is open. What stays on this Mac is the list of hosts
/// (`~/.yardlet/remote/hosts.json`) and a key per host; removing a host removes both and asks the host to
/// forget this Mac.
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
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let timing: RemoteHostConnection.Timing
    /// Each host's `attention` events, for notifications.
    @ObservationIgnored var onAttention: ((RemoteHostModel, RemoteEvent) -> Void)?

    init(store: RemoteHostStore, keys: any RemoteClientKeyStoring, hello: RemoteHandshakeHello,
         session: URLSession = .shared, timing: RemoteHostConnection.Timing = .init()) {
        self.store = store
        self.keys = keys
        self.hello = hello
        self.session = session
        self.timing = timing
        hosts = store.all()
    }

    func host(_ id: String) -> RemoteSavedHost? {
        hosts.first { $0.id == id }
    }

    /// The model of a host's window, connecting from now on; nil for a host no longer saved.
    func model(for hostID: String) -> RemoteHostModel? {
        if let model = models[hostID] { return model }
        guard let host = store.host(hostID), let key = keys.load(hostID: hostID) else { return nil }
        let model = RemoteHostModel(host: host, clientKey: key, hello: hello, store: store, session: session, timing: timing)
        model.onAttention = { [weak self, weak model] event in
            guard let self, let model else { return }
            onAttention?(model, event)
        }
        models[hostID] = model
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

    /// The host's window closed: its connection ends.
    func close(_ hostID: String) {
        models.removeValue(forKey: hostID)?.stop()
        hosts = store.all()
    }

    /// Pairs with the host a link names (§12), or pairs again with one saved before. The host as saved.
    func pair(link text: String) async throws -> RemoteSavedHost {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let link = RemoteSecurePairingURL.parse(url) else { throw PairingFailure.notALink }
        let key = RemoteKeyPair.generate()
        let reply: RemoteHandshakeReply
        do {
            reply = try await RemoteHostConnection.pair(link, clientKey: key, hello: hello, session: session, timing: timing)
        } catch let failure as RemoteClientSocket.Failure {
            switch failure.error?.code {
            case .pairingUnavailable?, .pairingInvalid?: throw PairingFailure.linkSpent
            case nil: throw PairingFailure.unreachable(link.name)
            default: throw PairingFailure.refused(link.name)
            }
        }
        let earlier = store.host(key: link.macKey)
        var host = earlier ?? RemoteSavedHost(name: link.name, hostKey: link.macKey, direct: link.hosts,
                                              relayURL: link.relayURL, room: link.room)
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
    /// entry and key go. A host that cannot be reached keeps this Mac in its device list until removed there.
    func forget(_ hostID: String) async {
        if let model = models[hostID], model.isConnected {
            _ = await model.response(to: .forgetDevice)
        } else if models[hostID] == nil, let target = store.host(hostID)?.target, let key = keys.load(hostID: hostID) {
            await Self.askToForget(target: target, key: key, hello: hello, session: session, timing: timing)
        }
        models.removeValue(forKey: hostID)?.stop()
        keys.delete(hostID: hostID)
        store.remove(hostID)
        hosts = store.all()
    }

    /// Connects for a moment to send `forgetDevice`, giving up after a few seconds.
    private static func askToForget(target: RemoteHostTarget, key: RemoteKeyPair, hello: RemoteHandshakeHello,
                                    session: URLSession, timing: RemoteHostConnection.Timing) async {
        var timing = timing
        timing.backoff = [5]
        let connection = RemoteHostConnection(target: target, clientKey: key, hello: hello, session: session, timing: timing)
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
