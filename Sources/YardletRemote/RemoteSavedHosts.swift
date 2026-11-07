import Foundation

/// A host this computer paired with as a client: where to find it and what it calls this device. The
/// client's own private key for it is kept apart (`RemoteClientKeyStoring`).
public struct RemoteSavedHost: Codable, Equatable, Identifiable, Sendable {
    /// This computer's own ID for the host, which names its window and its key.
    public var id: String
    /// The host's name, as its latest message 2 gave it (§13.1).
    public var name: String
    /// The host's static public key, base64url.
    public var hostKey: String
    /// The direct addresses the host last named, `host:port`.
    public var direct: [String]
    public var relayURL: String?
    public var room: String?
    /// Another address of the same relay, which a client races against `relayURL`.
    public var alternateRelayURL: String?
    /// What the host calls this device.
    public var deviceID: String?
    public var pairedAt: Date
    public var lastConnectedAt: Date?

    public init(id: String = UUID().uuidString, name: String, hostKey: Data, direct: [String], relayURL: String? = nil,
                room: String? = nil, alternateRelayURL: String? = nil, deviceID: String? = nil, pairedAt: Date = Date(),
                lastConnectedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.hostKey = RemoteEncoding.base64url(hostKey)
        self.direct = direct
        self.relayURL = relayURL
        self.room = room
        self.alternateRelayURL = alternateRelayURL
        self.deviceID = deviceID
        self.pairedAt = pairedAt
        self.lastConnectedAt = lastConnectedAt
    }

    public var target: RemoteHostTarget? {
        guard let key = RemoteEncoding.data(base64url: hostKey), key.count == 32 else { return nil }
        return RemoteHostTarget(hostKey: key, direct: direct, relayURL: relayURL, room: room, alternateRelayURL: alternateRelayURL)
    }

    /// The most direct addresses kept: the host's latest first, then earlier ones it did not name this
    /// time (another network's), each tried at once on the next attempt.
    public static let maxDirectAddresses = 8

    /// What message 2 said about the host now: its name, its addresses and room, and the device.
    public mutating func update(from reply: RemoteHandshakeReply, at now: Date = Date()) {
        if let name = reply.server?.name, !name.isEmpty { self.name = name }
        let latest = reply.direct ?? []
        direct = Array((latest + direct.filter { !latest.contains($0) }).prefix(Self.maxDirectAddresses))
        // A host that names no relay uses none now (§13.1).
        relayURL = reply.relay?.url
        room = reply.relay?.room
        alternateRelayURL = reply.relay?.alternate
        if let deviceID = reply.deviceId { self.deviceID = deviceID }
        lastConnectedAt = now
    }
}

/// The hosts this computer paired with, in a file only the person can read (`~/.yardlet/remote/hosts.json`
/// for the app; tests keep them in memory). Nothing else about a host is stored: its tasks and
/// conversations stay on the host.
public final class RemoteHostStore: @unchecked Sendable {
    private struct File: Codable {
        var version = 1
        var hosts: [RemoteSavedHost]
    }

    private let lock = NSLock()
    private let fileURL: URL?
    private var hosts: [RemoteSavedHost]

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder.remoteDates.decode(File.self, from: data) {
            hosts = file.hosts
        } else {
            hosts = []
        }
    }

    public func all() -> [RemoteSavedHost] {
        lock.withLock { hosts }
    }

    public func host(_ id: String) -> RemoteSavedHost? {
        lock.withLock { hosts.first { $0.id == id } }
    }

    /// The host with this static key, which a second pairing with the same host finds.
    public func host(key: Data) -> RemoteSavedHost? {
        let key = RemoteEncoding.base64url(key)
        return lock.withLock { hosts.first { $0.hostKey == key } }
    }

    public func save(_ host: RemoteSavedHost) {
        lock.withLock {
            if let index = hosts.firstIndex(where: { $0.id == host.id }) {
                hosts[index] = host
            } else {
                hosts.append(host)
            }
            write()
        }
    }

    public func remove(_ id: String) {
        lock.withLock {
            hosts.removeAll { $0.id == id }
            write()
        }
    }

    private func write() {
        guard let fileURL else { return }
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // The file goes with its last host.
        if hosts.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder.remoteDates.encode(File(hosts: hosts)) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// Where a client keeps its private key for each host: the Keychain in the app, memory in tests.
public protocol RemoteClientKeyStoring: Sendable {
    func load(hostID: String) -> RemoteKeyPair?
    func save(_ key: RemoteKeyPair, hostID: String)
    func delete(hostID: String)
}

public final class RemoteMemoryClientKeys: RemoteClientKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: RemoteKeyPair] = [:]

    public init() {}

    public func load(hostID: String) -> RemoteKeyPair? { lock.withLock { keys[hostID] } }
    public func save(_ key: RemoteKeyPair, hostID: String) { lock.withLock { keys[hostID] = key } }
    public func delete(hostID: String) { _ = lock.withLock { keys.removeValue(forKey: hostID) } }
}
