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

    public static func parse(_ url: URL) -> RemoteSecurePairingURL? {
        guard url.scheme == RemoteProtocol.pairingScheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "v" })?.value == String(RemoteProtocol.secureVersion),
              let key = items.first(where: { $0.name == "k" })?.value.flatMap(RemoteEncoding.data(base64url:)), key.count == 32,
              let secret = items.first(where: { $0.name == "s" })?.value.flatMap(RemoteEncoding.data(base64url:)),
              secret.count == 32 else { return nil }
        let relay = items.first { $0.name == "r" }?.value
        let room = items.first { $0.name == "i" }?.value
        return RemoteSecurePairingURL(macKey: key, secret: secret, name: items.first { $0.name == "n" }?.value ?? "Mac",
                                      hosts: items.filter { $0.name == "h" }.compactMap(\.value),
                                      relayURL: relay != nil && room != nil ? relay : nil,
                                      room: relay != nil && room != nil ? room : nil)
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

public struct RemoteDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The phone's static public key, base64url. The Mac holds nothing secret of the phone's.
    public var publicKey: String
    public var platform: String?
    public var push: RemotePushRegistration?
    public var createdAt: Date
    public var lastSeenAt: Date?

    public init(id: String = UUID().uuidString, name: String, publicKey: String, platform: String? = nil, createdAt: Date,
                lastSeenAt: Date? = nil) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.platform = platform
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
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
    private var devices: [RemoteDevice]
    /// A seen time is written at most this often per device.
    private let seenWriteInterval: TimeInterval = 60

    /// `devices` are the ones a store without a file starts with (tests and the fixture). Devices paired with
    /// protocol 1 are dropped from the file as it is read.
    public init(fileURL: URL?, devices seeded: [RemoteDevice] = []) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder.remoteDates.decode(StoredFile.self, from: data) {
            let kept = file.devices.compactMap(\.device)
            devices = kept
            if kept.count != file.devices.count { Self.write(kept, to: fileURL) }
        } else {
            devices = seeded
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
    public func remove(_ id: String) -> Bool {
        let count = devices.count
        devices.removeAll { $0.id == id }
        guard devices.count != count else { return false }
        save()
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
        guard let fileURL else { return }
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder.remoteDates.encode(File(devices: devices)) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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
