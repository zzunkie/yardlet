import Foundation
import Network

/// Finds a paired Mac on the same network (docs/REMOTE_PROTOCOL.md §11.3): the `_yardlet._tcp` instance whose TXT
/// `id` is the discovery ID of the Mac key this phone saved, resolved to `host:port` for the connection's race.
/// The Mac's name is not advertised, so nothing but the key tells Macs apart. iOS asks for Local Network access the
/// first time; refused, nothing is found and the phone connects through the other paths.
final class BonjourFinder: @unchecked Sendable {
    private let discoveryID: String
    private let onChange: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "app.yardlet.remote.bonjour")
    private var browser: NWBrowser?
    private var resolving: [NWEndpoint: NWConnection] = [:]
    private var found: [NWEndpoint: String] = [:]

    init(discoveryID: String, onChange: @escaping @Sendable ([String]) -> Void) {
        self.discoveryID = discoveryID
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_yardlet._tcp", domain: nil), using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
            browser.start(queue: queue)
            self.browser = browser
        }
    }

    func cancel() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
            for connection in resolving.values { connection.cancel() }
            resolving = [:]
            found = [:]
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        let mine = Set(results.compactMap { result -> NWEndpoint? in
            guard case let .bonjour(txt) = result.metadata, txt["id"] == discoveryID else { return nil }
            return result.endpoint
        })
        for endpoint in Set(found.keys).subtracting(mine) { found[endpoint] = nil }
        for endpoint in Set(resolving.keys).subtracting(mine) {
            resolving[endpoint]?.cancel()
            resolving[endpoint] = nil
        }
        for endpoint in mine where found[endpoint] == nil && resolving[endpoint] == nil { resolve(endpoint) }
        publish()
    }

    /// The service's address: a TCP connection to it that is closed once ready, read for where it went.
    private func resolve(_ endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolving[endpoint] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint,
                   let address = Self.address(host, port) {
                    found[endpoint] = address
                }
                connection.cancel()
                resolving[endpoint] = nil
                publish()
            case .failed, .cancelled:
                resolving[endpoint] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func publish() {
        onChange(Array(Set(found.values)).sorted())
    }

    static func address(_ host: NWEndpoint.Host, _ port: NWEndpoint.Port) -> String? {
        switch host {
        case let .ipv4(address):
            return address.rawValue.map(String.init).joined(separator: ".") + ":\(port.rawValue)"
        case let .ipv6(address):
            // A link-local address needs its interface, which a URL cannot carry.
            guard !address.isLinkLocal else { return nil }
            let text = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
            return "[\(text)]:\(port.rawValue)"
        case let .name(name, _):
            return "\(name):\(port.rawValue)"
        @unknown default:
            return nil
        }
    }
}
