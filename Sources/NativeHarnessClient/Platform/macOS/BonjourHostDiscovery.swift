import Foundation
import Network
import dnssd
import YardletRemote

extension RemoteHostDiscovery {
    /// The app's: Bonjour on this Mac's networks, while the host's window is open.
    static let bonjour = RemoteHostDiscovery { discoveryID, found in
        let watch = BonjourHostWatch(discoveryID: discoveryID) { addresses in
            // In the order found, so a host gone is never reported before it was found.
            DispatchQueue.main.async { MainActor.assumeIsolated { found(addresses) } }
        }
        watch.start()
        return { watch.stop() }
    }
}

/// Looks for one host on this Mac's networks (docs/REMOTE_PROTOCOL.md §11.3): an `NWBrowser` for
/// `_yardlet._tcp` keeps to the instances whose TXT `id`, or name `Yardlet-<id>`, is the host's discovery
/// id, and `DNSServiceResolve` gives each one's host name and port. The window races `Name.local:port`, a
/// name URLSession resolves itself, so a link-local IPv6 address never needs its zone written into a URL.
/// Bonjour that is refused (Local Network access off, a guest network) finds nothing, and the saved
/// addresses and the relay remain.
private final class BonjourHostWatch: @unchecked Sendable {
    private let discoveryID: String
    private let found: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "yardlet.remote.bonjour")
    // Kept on `queue`.
    private var browser: NWBrowser?
    private var resolutions: [NWEndpoint: Resolution] = [:]
    private var reported: [String] = []

    init(discoveryID: String, found: @escaping @Sendable ([String]) -> Void) {
        self.discoveryID = discoveryID
        self.found = found
    }

    func start() {
        queue.async { [self] in
            guard browser == nil else { return }
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteProtocol.bonjourType, domain: nil),
                                    using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.update([]) }
            }
            browser.start(queue: queue)
            self.browser = browser
        }
    }

    func stop() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
            for resolution in resolutions.values { resolution.cancel() }
            resolutions = [:]
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        let matching = Set(results.compactMap { result -> NWEndpoint? in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            if name == "Yardlet-\(discoveryID)" { return result.endpoint }
            if case let .bonjour(txt) = result.metadata, txt["id"] == discoveryID { return result.endpoint }
            return nil
        })
        for (endpoint, resolution) in resolutions where !matching.contains(endpoint) {
            resolution.cancel()
            resolutions[endpoint] = nil
        }
        for endpoint in matching where resolutions[endpoint] == nil {
            guard case let .service(name, type, domain, interface) = endpoint else { continue }
            resolutions[endpoint] = Resolution(name: name, type: type, domain: domain,
                                               interfaceIndex: UInt32(interface?.index ?? 0), queue: queue) { [weak self] in
                self?.report()
            }
        }
        report()
    }

    private func report() {
        let addresses = Array(Set(resolutions.values.compactMap(\.address))).sorted()
        guard addresses != reported else { return }
        reported = addresses
        found(addresses)
    }
}

/// One instance's host name and port, as `DNSServiceResolve` reports them; the resolve ends at its first
/// answer, as the API asks. Used only on the queue its answer arrives on.
private final class Resolution: @unchecked Sendable {
    private(set) var address: String?
    private var service: DNSServiceRef?
    private let queue: DispatchQueue
    private let changed: () -> Void

    init(name: String, type: String, domain: String, interfaceIndex: UInt32, queue: DispatchQueue,
         changed: @escaping () -> Void) {
        self.queue = queue
        self.changed = changed
        var service: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let started = DNSServiceResolve(&service, 0, interfaceIndex, name, type, domain, {
            _, _, _, error, _, host, port, _, _, context in
            guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let host, let context else { return }
            let resolution = Unmanaged<Resolution>.fromOpaque(context).takeUnretainedValue()
            var name = String(cString: host)
            if name.hasSuffix(".") { name.removeLast() }
            resolution.answered("\(name):\(UInt16(bigEndian: port))")
        }, context)
        guard started == DNSServiceErrorType(kDNSServiceErr_NoError), let service else { return }
        guard DNSServiceSetDispatchQueue(service, queue) == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            DNSServiceRefDeallocate(service)
            return
        }
        self.service = service
    }

    private func answered(_ address: String) {
        self.address = address
        // Ended once this answer is handled, not from inside it.
        queue.async { self.cancel() }
        changed()
    }

    /// No answer comes after this: called on the queue the answer arrives on.
    func cancel() {
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
    }

    deinit { cancel() }
}
