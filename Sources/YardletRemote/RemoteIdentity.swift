import Crypto
import Foundation

/// The Mac's two v2 keys (docs/REMOTE_PROTOCOL.md §11.2): the X25519 key phones authenticate it by,
/// and the Ed25519 key that opens its room on the relay. Kept in the Keychain by the app.
public struct RemoteIdentity: Equatable, Sendable {
    public let noise: RemoteKeyPair
    public let relayPrivateKey: Data

    public init(noisePrivateKey: Data, relayPrivateKey: Data) throws {
        noise = try RemoteKeyPair(privateKey: noisePrivateKey)
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: relayPrivateKey)
        self.relayPrivateKey = relayPrivateKey
    }

    public static func generate() -> RemoteIdentity {
        try! RemoteIdentity(noisePrivateKey: RemoteKeyPair.generate().privateKey,
                            relayPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation)
    }

    public var relayPublicKey: Data {
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: relayPrivateKey))?.publicKey.rawRepresentation ?? Data()
    }

    /// The Mac's room on the relay: derived from the relay key, so only its holder can open it.
    public var room: String { Self.room(for: relayPublicKey) }

    /// What Bonjour advertises in place of the Mac's name.
    public var discoveryID: String { Self.discoveryID(for: noise.publicKey) }

    public func signRelayChallenge(room: String, nonce: String) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: relayPrivateKey)
        return try key.signature(for: Self.relayChallengeMessage(room: room, nonce: nonce))
    }

    public static func room(for relayPublicKey: Data) -> String {
        RemoteEncoding.base32(Data(SHA256.hash(data: relayPublicKey)).prefix(20))
    }

    public static func discoveryID(for noisePublicKey: Data) -> String {
        RemoteEncoding.hex(Data(SHA256.hash(data: Data("yardlet-mdns/2".utf8) + noisePublicKey)).prefix(8))
    }

    public static func relayChallengeMessage(room: String, nonce: String) -> Data {
        Data("yardlet-relay-host/1\n\(room)\n\(nonce)".utf8)
    }

    /// The two keys as one secret blob, for the Keychain.
    public var stored: Data {
        (try? JSONEncoder().encode(Stored(version: 1, noise: RemoteEncoding.base64url(noise.privateKey),
                                          relay: RemoteEncoding.base64url(relayPrivateKey)))) ?? Data()
    }

    public init(stored: Data) throws {
        let value = try JSONDecoder().decode(Stored.self, from: stored)
        guard let noise = RemoteEncoding.data(base64url: value.noise),
              let relay = RemoteEncoding.data(base64url: value.relay) else { throw RemoteNoise.Failure("Unreadable identity") }
        try self.init(noisePrivateKey: noise, relayPrivateKey: relay)
    }

    private struct Stored: Codable {
        var version: Int
        var noise: String
        var relay: String
    }
}

/// Where the Mac's identity lives: the Keychain for the app, memory for tests and the fixture.
public protocol RemoteIdentityStoring: Sendable {
    func load() throws -> RemoteIdentity?
    func save(_ identity: RemoteIdentity) throws
}

public final class RemoteMemoryIdentityStore: RemoteIdentityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: RemoteIdentity?

    public init(_ identity: RemoteIdentity? = nil) {
        self.identity = identity
    }

    public func load() throws -> RemoteIdentity? {
        lock.withLock { identity }
    }

    public func save(_ identity: RemoteIdentity) throws {
        lock.withLock { self.identity = identity }
    }
}

extension RemoteIdentityStoring {
    /// The stored identity, or a new one saved now.
    public func loadOrCreate() throws -> RemoteIdentity {
        if let identity = try load() { return identity }
        let identity = RemoteIdentity.generate()
        try save(identity)
        return identity
    }
}

/// Binary as the protocol writes it (§11.2).
public enum RemoteEncoding {
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64url text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !base64.contains("=") else { return nil }
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    /// RFC 4648 base32 in lowercase, without padding.
    public static func base32(_ data: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var result = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                result.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { result.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return result
    }

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func data(hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// A push payload sealed for one device (§16): ChaCha20-Poly1305 with the device's push key, a
/// random nonce and fixed associated data, so only that phone opens it.
public enum RemotePushSeal {
    public static let associatedData = Data("yardlet-push/1".utf8)

    public static func newKey() -> Data {
        Data(RemoteRandom.bytes(32))
    }

    public static func keyID(_ key: Data) -> String {
        RemoteEncoding.hex(Data(SHA256.hash(data: key)).prefix(8))
    }

    public static func seal(_ plaintext: Data, key: Data, nonce: Data? = nil) throws -> String {
        let nonce = try ChaChaPoly.Nonce(data: nonce ?? Data(RemoteRandom.bytes(12)))
        let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce, authenticating: associatedData)
        return RemoteEncoding.base64url(box.combined)
    }

    public static func open(_ sealed: String, key: Data) throws -> Data {
        guard let combined = RemoteEncoding.data(base64url: sealed) else { throw RemoteNoise.Failure("Not base64url") }
        let box = try ChaChaPoly.SealedBox(combined: combined)
        return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: associatedData)
    }

    /// FCM's collapse key for a task: its first 16 hex characters of SHA-256.
    public static func collapseKey(taskID: String) -> String {
        RemoteEncoding.hex(Data(SHA256.hash(data: Data(taskID.utf8))).prefix(8))
    }
}
