import Foundation

/// How a host's window looks for its host on this network (docs/REMOTE_PROTOCOL.md §11.3) while it is open:
/// Bonjour in the app (`Platform/macOS/BonjourHostDiscovery.swift`), nothing in tests unless one fakes it.
/// `watch` starts looking for the host with a discovery id (`RemoteIdentity.discoveryID(for:)`) and tells
/// `found` the addresses it resolved, `host:port`, each time they change, an empty list once the host is
/// gone. The closure it returns stops looking.
struct RemoteHostDiscovery: Sendable {
    typealias Found = @MainActor @Sendable ([String]) -> Void

    var watch: @MainActor @Sendable (_ discoveryID: String, _ found: @escaping Found) -> @MainActor @Sendable () -> Void
}
