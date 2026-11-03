import Crypto
import Foundation
#if canImport(Security)
import Security
#endif

// Pairing (§12): a one-time secret the Mac shows in a QR code; the phone's key becomes the device.

public enum RemoteRandom {
    public static func bytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        #if canImport(Security)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess { return bytes }
        #endif
        // The system's cryptographic generator on every platform (getrandom, BCryptGenRandom).
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        return bytes
    }
}

public enum RemoteDigest {
    /// SHA-256 of the text's UTF-8, hex.
    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The one pairing open at a time.
public struct RemotePairingTicket: Equatable, Sendable {
    /// The QR's secret (§12): 32 random bytes.
    public var secret: Data
    public var expiresAt: Date
    /// Closed after one successful use (the Mac); the fixture can keep it open.
    public var isSingleUse: Bool
    /// The phone key that used it, which may use it again for a short while (§12).
    public var pairedKey: Data?

    public static let lifetime: TimeInterval = 5 * 60

    public init(secret: Data = Data(RemoteRandom.bytes(32)), expiresAt: Date, isSingleUse: Bool = true) {
        self.secret = secret
        self.expiresAt = expiresAt
        self.isSingleUse = isSingleUse
    }
}

/// What the QR code holds (§12).
public struct RemoteSecurePairingURL: Equatable, Sendable {
    public var macKey: Data
    public var secret: Data
    public var name: String
    /// `host:port`, in the order to try.
    public var hosts: [String]
    public var relayURL: String?
    public var room: String?

    public init(macKey: Data, secret: Data, name: String, hosts: [String], relayURL: String? = nil, room: String? = nil) {
        self.macKey = macKey
        self.secret = secret
        self.name = name
        self.hosts = hosts
        self.relayURL = relayURL
        self.room = room
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = RemoteProtocol.pairingScheme
        components.host = "pair"
        var items = [
            URLQueryItem(name: "v", value: String(RemoteProtocol.secureVersion)),
            URLQueryItem(name: "k", value: RemoteEncoding.base64url(macKey)),
            URLQueryItem(name: "s", value: RemoteEncoding.base64url(secret)),
            URLQueryItem(name: "n", value: name)
        ]
        items += hosts.map { URLQueryItem(name: "h", value: $0) }
        if let relayURL, let room {
            items += [URLQueryItem(name: "r", value: relayURL), URLQueryItem(name: "i", value: room)]
        }
        components.queryItems = items
        // `URLComponents` leaves `:` and `/` in query values, which every reader takes.
        return components.url
    }

    /// The longest Mac name a link carries; a longer one is cut.
    public static let maxNameLength = 64

    /// Reads a pairing link (§12). Anyone can send one, so it takes only what a client can safely try: at most
    /// `RemoteSavedHost.maxDirectAddresses` direct addresses, each a plain `host:port` (anything else, which could
    /// add a path to the WebSocket's URL, is left out), a name of at most `maxNameLength` characters, and a room made
    /// of letters, digits, `-` and `_` (a link naming another is refused).
    public static func parse(_ url: URL) -> RemoteSecurePairingURL? {
        guard url.scheme == RemoteProtocol.pairingScheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "v" })?.value == String(RemoteProtocol.secureVersion),
              let key = items.first(where: { $0.name == "k" })?.value.flatMap(RemoteEncoding.data(base64url:)), key.count == 32,
              let secret = items.first(where: { $0.name == "s" })?.value.flatMap(RemoteEncoding.data(base64url:)),
              secret.count == 32 else { return nil }
        let relay = items.first { $0.name == "r" }?.value
        let room = items.first { $0.name == "i" }?.value
        if relay != nil, let room, !isRoom(room) { return nil }
        let hosts = items.filter { $0.name == "h" }.compactMap(\.value).filter(isHostPort)
        let name = String((items.first { $0.name == "n" }?.value ?? "Mac").prefix(maxNameLength))
        return RemoteSecurePairingURL(macKey: key, secret: secret, name: name,
                                      hosts: Array(hosts.prefix(RemoteSavedHost.maxDirectAddresses)),
                                      relayURL: relay != nil && room != nil ? relay : nil,
                                      room: relay != nil && room != nil ? room : nil)
    }

    /// `host:port` with a port from 1 to 65535: a name or IPv4 address of letters, digits, dots and hyphens, or an IPv6
    /// address in brackets.
    static func isHostPort(_ text: String) -> Bool {
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]),
              (1...65535).contains(port), text[text.index(after: colon)...].allSatisfy(\.isASCII) else { return false }
        let host = text[..<colon]
        guard !host.isEmpty, host.count <= 255 else { return false }
        if host.first == "[" {
            let inner = host.dropFirst().dropLast()
            return host.last == "]" && !inner.isEmpty && inner.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        return host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    /// A relay room as a URL path segment may carry it.
    static func isRoom(_ text: String) -> Bool {
        (1...128).contains(text.count)
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// The six digits both sides show for a link request (§12.1). Each side adds a random nonce: the phone
/// commits to its own in message 1, learns the Mac's in message 2, and then reveals its own.
public enum RemoteLinkCode {
    public static let nonceLength = 32

    /// What message 1 carries for the phone's nonce.
    public static func commitment(phoneKey: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: Data("yardlet-link-commit/2".utf8) + phoneKey + nonce))
    }

    public static func code(macKey: Data, phoneKey: Data, macNonce: Data, phoneNonce: Data) -> String {
        let digest = Array(SHA256.hash(data: Data("yardlet-link/2".utf8) + macKey + phoneKey + macNonce + phoneNonce))
        let value = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
        return String(format: "%06u", value % 1_000_000)
    }
}

// MARK: - Devices

/// Where a v2 device's pushes go (§15.6).
public struct RemotePushRegistration: Codable, Equatable, Sendable {
    public var provider: String
    public var token: String
    /// The push key, base64url.
    public var key: String

    public init(provider: String, token: String, key: String) {
        self.provider = provider
        self.token = token
        self.key = key
    }
}

/// Additional host access is granted only in this Mac's paired-device settings.
public enum RemoteDevicePermission: String, Codable, CaseIterable, Hashable, Sendable {
    case terminal, fileWrites, settings
}

public struct RemoteDevicePermissions: Codable, Equatable, Sendable {
    public var terminal: Bool
    public var fileWrites: Bool
    public var settings: Bool

    public init(terminal: Bool = false, fileWrites: Bool = false, settings: Bool = false) {
        self.terminal = terminal
        self.fileWrites = fileWrites
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey { case terminal, fileWrites, settings }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        terminal = try values.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
        fileWrites = try values.decodeIfPresent(Bool.self, forKey: .fileWrites) ?? false
        settings = try values.decodeIfPresent(Bool.self, forKey: .settings) ?? false
    }

    public subscript(_ permission: RemoteDevicePermission) -> Bool {
        get {
            switch permission {
            case .terminal: terminal
            case .fileWrites: fileWrites
            case .settings: settings
            }
        }
        set {
            switch permission {
            case .terminal: terminal = newValue
            case .fileWrites: fileWrites = newValue
            case .settings: settings = newValue
            }
        }
    }
}

public struct RemoteDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The phone's static public key, base64url. The Mac holds nothing secret of the phone's.
    public var publicKey: String
    public var platform: String?
    public var push: RemotePushRegistration?
    public var permissions: RemoteDevicePermissions?
    public var createdAt: Date
    public var lastSeenAt: Date?

    public init(id: String = UUID().uuidString, name: String, publicKey: String, platform: String? = nil, createdAt: Date,
                lastSeenAt: Date? = nil, permissions: RemoteDevicePermissions? = nil) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.platform = platform
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.permissions = permissions
    }
}

/// The paired devices, in a file only the person can read (`~/.yardlet/remote/devices.json` for the
/// app; a test or the fixture passes its own folder, or none to keep them in memory).
public actor RemoteDeviceStore {
    private struct File: Codable {
        var version = 2
        var devices: [RemoteDevice]
    }

    /// One entry of the file as read: a device paired with protocol 1 (a token digest and no public key),
    /// which this Mac no longer serves, reads as nil.
    private struct StoredDevice: Decodable {
        let device: RemoteDevice?

        init(from decoder: Decoder) throws {
            device = try? RemoteDevice(from: decoder)
        }
    }

    private struct StoredFile: Decodable {
        var devices: [StoredDevice]
    }

    private let fileURL: URL?
    private let recoveryFileURL: URL?
    private let beforePermissionWrite: (@Sendable () async -> Void)?
    private var recoveryDenials: Set<RemotePermissionKey> = []
    private var durableRecoveryDenials: Set<RemotePermissionKey> = []
    private struct RecoveryFile: Codable {
        var version = 1
        var denied: [RemotePermissionKey]
    }
    private var devices: [RemoteDevice]
    /// A seen time is written at most this often per device.
    private let seenWriteInterval: TimeInterval = 60

    /// `devices` are the ones a store without a file starts with (tests and the fixture). Devices paired with
    /// protocol 1 are dropped from the file as it is read.
    public init(fileURL: URL?, devices seeded: [RemoteDevice] = [], recoveryFileURL: URL? = nil,
                beforePermissionWrite: (@Sendable () async -> Void)? = nil) {
        self.fileURL = fileURL
        self.beforePermissionWrite = beforePermissionWrite
        self.recoveryFileURL = recoveryFileURL ?? fileURL?.deletingLastPathComponent().appendingPathComponent("permission-denials.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder.remoteDates.decode(StoredFile.self, from: data) {
            let kept = file.devices.compactMap(\.device)
            devices = kept
            if kept.count != file.devices.count { Self.write(kept, to: fileURL) }
        } else {
            devices = seeded
        }
        if let journal = self.recoveryFileURL, FileManager.default.fileExists(atPath: journal.path) {
            if let data = try? Data(contentsOf: journal), let saved = try? JSONDecoder().decode(RecoveryFile.self, from: data),
               saved.version == 1 {
                recoveryDenials = Set(saved.denied)
                durableRecoveryDenials = recoveryDenials
            } else {
                // An unreadable recovery record never revives an old grant.
                recoveryDenials = Set(devices.flatMap { device in
                    RemoteDevicePermission.allCases.map { RemotePermissionKey(deviceID: device.id, permission: $0) }
                })
            }
        }
    }

    public func all() -> [RemoteDevice] { devices }

    /// A device by its public key, marked seen and renamed to what it calls itself now.
    public func authenticate(publicKey: Data, name: String?, now: Date = Date()) -> RemoteDevice? {
        let key = RemoteEncoding.base64url(publicKey)
        guard let index = devices.firstIndex(where: { $0.publicKey == key }) else { return nil }
        if let name, !name.isEmpty, devices[index].name != name { devices[index].name = name }
        markSeen(at: index, now: now, force: true)
        return devices[index]
    }

    /// A new device, or the one this key already is.
    public func addSecure(name: String, publicKey: Data, platform: String?, now: Date = Date()) -> RemoteDevice {
        if let device = authenticate(publicKey: publicKey, name: name, now: now) { return device }
        let device = RemoteDevice(name: name.isEmpty ? "Phone" : name, publicKey: RemoteEncoding.base64url(publicKey),
                                  platform: platform, createdAt: now, lastSeenAt: now)
        devices.append(device)
        save()
        return device
    }

    public func device(_ id: String) -> RemoteDevice? {
        devices.first { $0.id == id }
    }

    public func device(publicKey: Data) -> RemoteDevice? {
        let key = RemoteEncoding.base64url(publicKey)
        return devices.first { $0.publicKey == key }
    }

    func permissionBootstrap() -> RemotePermissionBootstrap {
        RemotePermissionBootstrap(devices: devices, recovery: recoveryState())
    }

    /// All operations here are synchronous on the persistence actor. RemoteServer queues them in
    /// request order; metadata writes between operations preserve these committed permission values.
    func persistPermissionWrite(_ operation: RemotePermissionWrite) async -> RemotePermissionWriteResult {
        await beforePermissionWrite?()
        switch operation {
        case let .grant(key):
            guard let index = devices.firstIndex(where: { $0.id == key.deviceID }) else { return result(false) }
            // A denial fence must be durable before a grant can replace the primary record.
            if recoveryDenials.contains(key), !writeRecovery(recoveryDenials) { return result(false) }
            var updated = devices
            var permissions = updated[index].permissions ?? RemoteDevicePermissions()
            permissions[key.permission] = true
            updated[index].permissions = permissions
            do { try Self.writeChecked(updated, to: fileURL) }
            catch { return result(false) }
            devices = updated
            if recoveryDenials.contains(key) {
                let cleared = recoveryDenials.subtracting([key])
                guard writeRecovery(cleared) else { return result(false) }
                recoveryDenials = cleared
            }
            return result(true, device: devices[index])
        case let .deny(keys):
            return persistDenial(keys, replacement: nil, removing: nil)
        case let .register(device):
            let keys = Set(RemoteDevicePermission.allCases.map { RemotePermissionKey(deviceID: device.id, permission: $0) })
            return persistDenial(keys, replacement: device, removing: nil)
        case let .remove(id):
            let keys = Set(RemoteDevicePermission.allCases.map { RemotePermissionKey(deviceID: id, permission: $0) })
            return persistDenial(keys, replacement: nil, removing: id)
        }
    }

    private func persistDenial(_ keys: Set<RemotePermissionKey>, replacement: RemoteDevice?, removing: String?) -> RemotePermissionWriteResult {
        recoveryDenials.formUnion(keys)
        _ = writeRecovery(recoveryDenials)
        var updated = devices
        if let replacement {
            if let index = updated.firstIndex(where: { $0.publicKey == replacement.publicKey }) {
                guard updated[index].id == replacement.id else { return result(false) }
                if !replacement.name.isEmpty,
                   (replacement.lastSeenAt ?? .distantPast) >= (updated[index].lastSeenAt ?? .distantPast) {
                    updated[index].name = replacement.name
                }
                updated[index].lastSeenAt = max(updated[index].lastSeenAt ?? .distantPast, replacement.lastSeenAt ?? .distantPast)
            } else {
                var registered = replacement
                registered.permissions = RemoteDevicePermissions()
                updated.append(registered)
            }
        }
        for index in updated.indices {
            var permissions = updated[index].permissions ?? RemoteDevicePermissions()
            for key in keys where key.deviceID == updated[index].id { permissions[key.permission] = false }
            updated[index].permissions = permissions
        }
        if let removing { updated.removeAll { $0.id == removing } }
        do { try Self.writeChecked(updated, to: fileURL) }
        catch { return result(false) }
        devices = updated
        let cleared = recoveryDenials.subtracting(keys)
        if writeRecovery(cleared) { recoveryDenials = cleared }
        else if removing == nil { return result(false) }
        return result(true, device: replacement.flatMap { registered in devices.first { $0.id == registered.id } })
    }

    private func writeRecovery(_ denied: Set<RemotePermissionKey>) -> Bool {
        do {
            if let recoveryFileURL {
                let sorted = denied.sorted {
                    $0.deviceID == $1.deviceID ? $0.permission.rawValue < $1.permission.rawValue : $0.deviceID < $1.deviceID
                }
                let data = try JSONEncoder().encode(RecoveryFile(denied: sorted))
                try Self.writePrivateData(data, to: recoveryFileURL)
            }
            durableRecoveryDenials = denied
            return true
        } catch { return false }
    }

    private func recoveryState() -> RemotePermissionRecoveryState {
        let unsafe = recoveryDenials.filter { key in
            !durableRecoveryDenials.contains(key)
                && devices.first(where: { $0.id == key.deviceID })?.permissions?[key.permission] == true
        }
        return RemotePermissionRecoveryState(unsavedDeniedPermissions: recoveryDenials,
                                             unsafeDeniedPermissions: Set(unsafe))
    }

    private func result(_ succeeded: Bool, device: RemoteDevice? = nil) -> RemotePermissionWriteResult {
        RemotePermissionWriteResult(succeeded: succeeded, device: device, recovery: recoveryState())
    }

    /// Stores where the device's pushes go and returns its push key, made once and kept.
    public func setPush(_ id: String, provider: String, token: String) -> Data? {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return nil }
        let key = devices[index].push.flatMap { RemoteEncoding.data(base64url: $0.key) } ?? RemotePushSeal.newKey()
        devices[index].push = RemotePushRegistration(provider: provider, token: token, key: RemoteEncoding.base64url(key))
        save()
        return key
    }

    public func clearPush(_ id: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].push != nil else { return }
        devices[index].push = nil
        save()
    }

    /// Forgets a push token the push service no longer knows, if it is still the device's.
    public func dropPushToken(_ token: String) {
        guard let index = devices.firstIndex(where: { $0.push?.token == token }) else { return }
        devices[index].push = nil
        save()
    }

    public func seen(_ id: String, now: Date = Date()) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        markSeen(at: index, now: now, force: false)
    }

    @discardableResult
    public func remove(_ id: String) throws -> Bool {
        let updated = devices.filter { $0.id != id }
        guard updated.count != devices.count else { return false }
        try Self.writeChecked(updated, to: fileURL)
        devices = updated
        return true
    }

    private func markSeen(at index: Int, now: Date, force: Bool) {
        if !force, let last = devices[index].lastSeenAt, now.timeIntervalSince(last) < seenWriteInterval { return }
        devices[index].lastSeenAt = now
        save()
    }

    private func save() {
        Self.write(devices, to: fileURL)
    }

    private static func write(_ devices: [RemoteDevice], to fileURL: URL?) {
        try? writeChecked(devices, to: fileURL)
    }

    private static func writeChecked(_ devices: [RemoteDevice], to fileURL: URL?) throws {
        guard let fileURL else { return }
        try writePrivateData(JSONEncoder.remoteDates.encode(File(devices: devices)), to: fileURL)
    }

    private static func writePrivateData(_ data: Data, to fileURL: URL) throws {
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".remote-state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data().write(to: temporary, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary, options: [.usingNewMetadataOnly])
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }

}

extension JSONEncoder {
    static var remoteDates: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}

extension JSONDecoder {
    static var remoteDates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
