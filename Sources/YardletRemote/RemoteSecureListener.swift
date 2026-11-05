import Foundation
import Network

/// The v2 listener for direct paths (§11.1, §11.3): one WebSocket listener on every interface, port 47616
/// or a free one when that is taken, advertised with Bonjour under the Mac's discovery id rather than its
/// name. Every connection is a `RemoteSecureConnection`; nothing is served before its Noise handshake, so
/// unlike v1 there is no need to pick addresses.
public final class RemoteSecureListener: RemoteDirectListening, @unchecked Sendable {
    public typealias State = RemoteDirectListenerState
    public typealias Advertisement = RemoteDirectAdvertisement

    private let server: RemoteServer
    private let staticKey: RemoteKeyPair
    private let preferredPort: UInt16
    private let advertisement: Advertisement?
    /// Tests bind loopback only.
    private let loopbackOnly: Bool
    private let queue = DispatchQueue(label: "yardlet.remote.secure-listener")
    private var listener: NWListener?
    private var channels: [ObjectIdentifier: RemoteNWFrameChannel] = [:]
    private var state = State.stopped
    private var triedFallback = false
    /// Told on the listener's queue whenever its state changes.
    public var onStateChange: (@Sendable (State) -> Void)?

    public init(server: RemoteServer, staticKey: RemoteKeyPair, port: UInt16 = RemoteProtocol.securePort,
                advertisement: Advertisement?, loopbackOnly: Bool = false) {
        self.server = server
        self.staticKey = staticKey
        preferredPort = port
        self.advertisement = advertisement
        self.loopbackOnly = loopbackOnly
    }

    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            triedFallback = false
            open(port: preferredPort)
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for channel in channels.values { channel.connection.cancel() }
            channels.removeAll()
            update(.stopped)
        }
    }

    public var currentState: State {
        queue.sync { state }
    }

    private func open(port: UInt16) {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = RemoteNoise.maxMessageLength
        // A browser always sends Origin; a web page must not reach the remote.
        websocket.setClientRequestHandler(queue) { _, headers in
            let fromBrowser = RemoteWebSocket.isFromBrowser(headers.map { $0.name })
            return NWProtocolWebSocket.Response(status: fromBrowser ? .reject : .accept, subprotocol: nil,
                                                additionalHeaders: fromBrowser ? nil : [RemoteWebSocket.acceptedHeader])
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        // Not shared: a second Yardlet (a QA build) must not take half of this one's phones; it falls
        // back to a free port instead.
        parameters.allowLocalEndpointReuse = false
        parameters.includePeerToPeer = false
        if loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
            // On iOS a listener that accepts local connections only is handed none (the phone app's demo Mac); the
            // loopback address alone keeps every other device out there.
            #if os(macOS)
            parameters.acceptLocalOnly = true
            #endif
        }
        let listener: NWListener
        do {
            listener = loopbackOnly ? try NWListener(using: parameters)
                : try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        } catch {
            fallBackOrFail(error.localizedDescription)
            return
        }
        if let advertisement {
            listener.service = NWListener.Service(name: advertisement.name, type: RemoteProtocol.bonjourType, domain: nil,
                                                  txtRecord: NWTXTRecord(advertisement.txt).data)
        }
        self.listener = listener
        update(.starting)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.update(.ready(port: listener.port?.rawValue ?? port))
            case let .failed(error), let .waiting(error):
                listener.cancel()
                self.listener = nil
                self.fallBackOrFail(error.localizedDescription)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    /// The preferred port is taken (another Yardlet, an old process): any free port, which Bonjour and
    /// message 2 name.
    private func fallBackOrFail(_ message: String) {
        if !triedFallback, preferredPort != 0 {
            triedFallback = true
            open(port: 0)
        } else {
            update(.failed(message))
        }
    }

    private func update(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }

    private func accept(_ connection: NWConnection) {
        let host = RemoteHandshakeAdmission.host(of: connection.endpoint)
        let waiting = channels.values.filter(\.isHandshaking).map { (id: ObjectIdentifier($0), host: $0.host, since: $0.acceptedAt) }
        for id in RemoteHandshakeAdmission.displaced(waiting: waiting, host: host) { channels[id]?.connection.cancel() }
        let channel = RemoteNWFrameChannel(connection: connection, queue: queue, host: host)
        channels[ObjectIdentifier(channel)] = channel
        queue.asyncAfter(deadline: .now() + RemoteHandshakeAdmission.handshakeTimeout) { [weak channel] in
            guard let channel, channel.isHandshaking else { return }
            channel.connection.cancel()
        }
        let path = Self.path(of: connection.endpoint)
        let server = self.server
        let key = staticKey
        connection.stateUpdateHandler = { [weak self, weak channel] state in
            guard let self, let channel else { return }
            switch state {
            case .ready:
                let metadata = channel.connection.metadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                guard metadata?.additionalServerHeaders?.contains(where: { $0.0 == RemoteWebSocket.acceptedHeader.name }) == true else {
                    channel.connection.cancel()
                    return
                }
                channel.secure = RemoteSecureConnection(transport: channel, server: server, staticKey: key, path: path)
                self.receive(on: channel)
            case let .failed(error), let .waiting(error):
                if !channel.isHandshaking { RemoteLog.notice("Direct: a phone's connection over \(path.rawValue) failed: \(RemoteLog.error(error))") }
                channel.connection.cancel()
            case .cancelled:
                self.channels[ObjectIdentifier(channel)] = nil
                channel.secure?.transportClosed()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on channel: RemoteNWFrameChannel) {
        channel.connection.receiveMessage { [weak self, weak channel] data, context, _, error in
            guard let self, let channel else { return }
            if let error {
                if !channel.isHandshaking { RemoteLog.notice("Direct: a phone's connection ended: \(RemoteLog.error(error))") }
                channel.connection.cancel()
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .binary?:
                // Network.framework hands over whole frames: one that does not decrypt is refused.
                if channel.secure?.receive(data ?? Data()) == false { channel.secure?.refuse() }
                self.receive(on: channel)
            case .close?:
                RemoteLog.notice("Direct: a phone closed its connection, code \(Self.code(of: metadata?.closeCode))")
                channel.connection.cancel()
            case .text?:
                channel.close(.unsupportedData)
            default:
                self.receive(on: channel)
            }
        }
    }

    private static func code(of closeCode: NWProtocolWebSocket.CloseCode?) -> UInt16 {
        switch closeCode {
        case let .protocolCode(code)?: code.rawValue
        case let .applicationCode(code)?, let .privateCode(code)?: code
        case nil: 0
        @unknown default: 0
        }
    }

    /// Which path a phone came over, from its address.
    static func path(of endpoint: NWEndpoint) -> RemotePath {
        guard case let .hostPort(host, _) = endpoint else { return .local }
        let address: String
        switch host {
        case let .ipv4(value): address = "\(value)"
        case let .ipv6(value): address = "\(value)"
        case let .name(name, _): address = name
        @unknown default: return .local
        }
        return RemoteAddressSelection.path(ofPeer: address)
    }
}

/// A WebSocket connection carrying binary frames.
final class RemoteNWFrameChannel: RemoteFrameChannel, @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    let host: String
    let acceptedAt = Date()
    var secure: RemoteSecureConnection?
    private var isClosing = false
    /// Bytes handed to the connection that it has not passed to the network yet (on `queue`).
    private var unsent = 0

    init(connection: NWConnection, queue: DispatchQueue, host: String) {
        self.connection = connection
        self.queue = queue
        self.host = host
    }

    /// Not yet past message 2: the WebSocket is still opening or the Noise handshake is not done.
    var isHandshaking: Bool { secure?.isHandshaking ?? true }

    func sendFrame(_ frame: Data) {
        queue.async { [self] in
            guard !isClosing else { return }
            // A phone that asks and never reads would leave every answer here: past the limit the connection goes,
            // with what it held (§7).
            unsent += frame.count
            guard unsent <= RemoteProtocol.maxUnsentBytes else {
                isClosing = true
                connection.forceCancel()
                return
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
            let count = frame.count
            connection.send(content: frame, contentContext: context, isComplete: true, completion: .contentProcessed { [self] _ in
                unsent -= count
            })
        }
    }

    func close(_ code: RemoteCloseCode) {
        queue.async { [self] in
            guard !isClosing else { return }
            isClosing = true
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = (try? NWProtocolWebSocket.CloseCode(rawValue: code.rawValue)) ?? .protocolCode(.normalClosure)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }
    }
}
