import Crypto
import Foundation

// Noise_IK_25519_ChaChaPoly_SHA256 (the Noise Protocol Framework, revision 34) for protocol v2
// (docs/REMOTE_PROTOCOL.md §13): the phone initiates knowing the Mac's static key, the Mac responds.
// Only what IK needs is here: X25519, ChaCha20-Poly1305 with Noise's nonce layout, SHA-256 and its
// HMAC-based HKDF.

public enum RemoteNoise {
    public static let protocolName = "Noise_IK_25519_ChaChaPoly_SHA256"
    /// Mixed into every handshake, so a v2 handshake never completes with anything else.
    public static let prologue = Data("yardlet-remote/2".utf8)
    /// The largest Noise message (§3 of the Noise spec).
    public static let maxMessageLength = 65_535
    public static let tagLength = 16
    public static let keyLength = 32
    /// The most application bytes one transport message carries: the message limit less the tag and
    /// the chunk flag (§13.2).
    public static let maxChunkLength = maxMessageLength - tagLength - 1

    public struct Failure: Error, Equatable, Sendable {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
    }
}

/// An X25519 key pair as raw bytes.
public struct RemoteKeyPair: Equatable, Sendable {
    public let privateKey: Data
    public let publicKey: Data

    public init(privateKey: Data) throws {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        self.privateKey = key.rawRepresentation
        publicKey = key.publicKey.rawRepresentation
    }

    public static func generate() -> RemoteKeyPair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        // A freshly made key always reads back.
        return try! RemoteKeyPair(privateKey: key.rawRepresentation)
    }

    func agree(with publicKey: Data) throws -> Data {
        let mine = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        let shared = try mine.sharedSecretFromKeyAgreement(with: theirs)
        return shared.withUnsafeBytes { Data($0) }
    }
}

/// One direction's key and counter. A `SymmetricKey` never changes once made, but swift-crypto outside
/// Apple's platforms does not mark it `Sendable`.
public struct RemoteNoiseCipher: @unchecked Sendable {
    var key: SymmetricKey?
    private(set) var nonce: UInt64 = 0

    init(key: Data? = nil) {
        self.key = key.map { SymmetricKey(data: $0) }
    }

    var hasKey: Bool { key != nil }

    /// ChaCha20-Poly1305 nonce: 32 zero bits, then the counter little-endian.
    private func nonceBytes() -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: nonce.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    public mutating func encrypt(_ plaintext: Data, ad: Data = Data()) throws -> Data {
        guard let key else { return plaintext }
        guard nonce < .max else { throw RemoteNoise.Failure("Nonce exhausted") }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonceBytes(), authenticating: ad)
        nonce += 1
        return box.ciphertext + box.tag
    }

    public mutating func decrypt(_ ciphertext: Data, ad: Data = Data()) throws -> Data {
        guard let key else { return ciphertext }
        guard nonce < .max else { throw RemoteNoise.Failure("Nonce exhausted") }
        guard ciphertext.count >= RemoteNoise.tagLength else { throw RemoteNoise.Failure("Message too short") }
        let split = ciphertext.count - RemoteNoise.tagLength
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonceBytes(), ciphertext: ciphertext.prefix(split),
                                               tag: ciphertext.suffix(RemoteNoise.tagLength))
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
            nonce += 1
            return plaintext
        } catch {
            throw RemoteNoise.Failure("Decryption failed")
        }
    }
}

/// The chaining key, the handshake hash and the cipher between them.
struct RemoteNoiseSymmetric {
    private(set) var chainingKey: Data
    private(set) var hash: Data
    var cipher = RemoteNoiseCipher()

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        hash = name.count <= 32 ? name + Data(count: 32 - name.count) : Data(SHA256.hash(data: name))
        chainingKey = hash
    }

    mutating func mixHash(_ data: Data) {
        hash = Data(SHA256.hash(data: hash + data))
    }

    mutating func mixKey(_ input: Data) {
        let (chaining, key) = Self.hkdf2(chainingKey, input)
        chainingKey = chaining
        cipher = RemoteNoiseCipher(key: key)
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(plaintext, ad: hash)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ciphertext, ad: hash)
        mixHash(ciphertext)
        return plaintext
    }

    func split() -> (RemoteNoiseCipher, RemoteNoiseCipher) {
        let (first, second) = Self.hkdf2(chainingKey, Data())
        return (RemoteNoiseCipher(key: first), RemoteNoiseCipher(key: second))
    }

    static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Noise's HKDF with two outputs.
    static func hkdf2(_ chainingKey: Data, _ input: Data) -> (Data, Data) {
        let temp = hmac(chainingKey, input)
        let first = hmac(temp, Data([1]))
        let second = hmac(temp, first + Data([2]))
        return (first, second)
    }
}

/// One side of an IK handshake. The initiator writes message 1 and reads message 2; the responder
/// the other way round. Then `split()` gives the transport ciphers.
public struct RemoteNoiseHandshake {
    public enum Role: Sendable {
        case initiator
        case responder
    }

    public let role: Role
    private var symmetric = RemoteNoiseSymmetric(protocolName: RemoteNoise.protocolName)
    private let localStatic: RemoteKeyPair
    private var localEphemeral: RemoteKeyPair?
    /// The responder's static key for the initiator; the initiator's, read from message 1, for the responder.
    public private(set) var remoteStatic: Data?
    private var remoteEphemeral: Data?
    /// Tests fix the ephemeral key; real handshakes make a new one.
    private let presetEphemeral: RemoteKeyPair?

    /// - Parameters:
    ///   - remoteStatic: the responder's static public key, which the initiator must know (IK).
    public init(role: Role, localStatic: RemoteKeyPair, remoteStatic: Data? = nil,
                prologue: Data = RemoteNoise.prologue, ephemeral: RemoteKeyPair? = nil) throws {
        self.role = role
        self.localStatic = localStatic
        presetEphemeral = ephemeral
        symmetric.mixHash(prologue)
        switch role {
        case .initiator:
            guard let remoteStatic, remoteStatic.count == 32 else { throw RemoteNoise.Failure("IK needs the responder's key") }
            self.remoteStatic = remoteStatic
            symmetric.mixHash(remoteStatic)
        case .responder:
            symmetric.mixHash(localStatic.publicKey)
        }
    }

    /// The handshake hash, the same on both sides once message 2 is through.
    public var handshakeHash: Data { symmetric.hash }

    /// `-> e, es, s, ss` and the payload.
    public mutating func writeMessage1(payload: Data) throws -> Data {
        guard role == .initiator, localEphemeral == nil, let remoteStatic else { throw RemoteNoise.Failure("Out of order") }
        let ephemeral = presetEphemeral ?? .generate()
        localEphemeral = ephemeral
        var message = ephemeral.publicKey
        symmetric.mixHash(ephemeral.publicKey)
        symmetric.mixKey(try ephemeral.agree(with: remoteStatic))
        message += try symmetric.encryptAndHash(localStatic.publicKey)
        symmetric.mixKey(try localStatic.agree(with: remoteStatic))
        message += try symmetric.encryptAndHash(payload)
        try Self.checkLength(message)
        return message
    }

    /// Reads message 1 and returns its payload; `remoteStatic` is then the initiator's key.
    public mutating func readMessage1(_ message: Data) throws -> Data {
        guard role == .responder, remoteEphemeral == nil else { throw RemoteNoise.Failure("Out of order") }
        try Self.checkLength(message)
        let bytes = Data(message)
        guard bytes.count >= 32 + 32 + RemoteNoise.tagLength * 2 else { throw RemoteNoise.Failure("Message 1 too short") }
        let ephemeral = bytes.prefix(32)
        remoteEphemeral = ephemeral
        symmetric.mixHash(ephemeral)
        symmetric.mixKey(try localStatic.agree(with: ephemeral))
        let encryptedStatic = bytes.dropFirst(32).prefix(32 + RemoteNoise.tagLength)
        let initiatorStatic = try symmetric.decryptAndHash(Data(encryptedStatic))
        remoteStatic = initiatorStatic
        symmetric.mixKey(try localStatic.agree(with: initiatorStatic))
        return try symmetric.decryptAndHash(Data(bytes.dropFirst(32 + 32 + RemoteNoise.tagLength)))
    }

    /// `<- e, ee, se` and the payload.
    public mutating func writeMessage2(payload: Data) throws -> Data {
        guard role == .responder, localEphemeral == nil, let remoteEphemeral, let remoteStatic else {
            throw RemoteNoise.Failure("Out of order")
        }
        let ephemeral = presetEphemeral ?? .generate()
        localEphemeral = ephemeral
        var message = ephemeral.publicKey
        symmetric.mixHash(ephemeral.publicKey)
        symmetric.mixKey(try ephemeral.agree(with: remoteEphemeral))
        symmetric.mixKey(try ephemeral.agree(with: remoteStatic))
        message += try symmetric.encryptAndHash(payload)
        try Self.checkLength(message)
        return message
    }

    /// Reads message 2 and returns its payload.
    public mutating func readMessage2(_ message: Data) throws -> Data {
        guard role == .initiator, let localEphemeral, remoteEphemeral == nil else { throw RemoteNoise.Failure("Out of order") }
        try Self.checkLength(message)
        let bytes = Data(message)
        guard bytes.count >= 32 + RemoteNoise.tagLength else { throw RemoteNoise.Failure("Message 2 too short") }
        let ephemeral = bytes.prefix(32)
        remoteEphemeral = ephemeral
        symmetric.mixHash(ephemeral)
        symmetric.mixKey(try localEphemeral.agree(with: ephemeral))
        symmetric.mixKey(try localStatic.agree(with: ephemeral))
        return try symmetric.decryptAndHash(Data(bytes.dropFirst(32)))
    }

    /// The transport ciphers: what this side sends with, and what it receives with.
    public func split() -> (send: RemoteNoiseCipher, receive: RemoteNoiseCipher) {
        let (first, second) = symmetric.split()
        return role == .initiator ? (first, second) : (second, first)
    }

    private static func checkLength(_ message: Data) throws {
        guard message.count <= RemoteNoise.maxMessageLength else { throw RemoteNoise.Failure("Message too long") }
    }
}

/// One application message as Noise transport messages, and back (§13.2): chunks of at most
/// `maxChunkLength` bytes, each led by a flag byte, `0x01` on the last.
public enum RemoteNoiseFraming {
    public static func seal(_ message: Data, with cipher: inout RemoteNoiseCipher) throws -> [Data] {
        var frames: [Data] = []
        var offset = message.startIndex
        repeat {
            let end = message.index(offset, offsetBy: RemoteNoise.maxChunkLength, limitedBy: message.endIndex) ?? message.endIndex
            var plaintext = Data([end == message.endIndex ? 1 : 0])
            plaintext += message[offset..<end]
            frames.append(try cipher.encrypt(plaintext))
            offset = end
        } while offset < message.endIndex
        return frames
    }

    /// Joins chunks as they arrive.
    public struct Joiner: Sendable {
        private var pending = Data()
        public let limit: Int

        public init(limit: Int) {
            self.limit = limit
        }

        /// The whole message once its last chunk is in; nil while more are to come.
        public mutating func add(_ frame: Data, with cipher: inout RemoteNoiseCipher) throws -> Data? {
            guard frame.count <= RemoteNoise.maxMessageLength else { throw RemoteNoise.Failure("Frame too long") }
            let plaintext = try cipher.decrypt(frame)
            guard let flag = plaintext.first, flag <= 1 else { throw RemoteNoise.Failure("Bad chunk flag") }
            pending += plaintext.dropFirst()
            guard pending.count <= limit else { throw TooLarge() }
            guard flag == 1 else { return nil }
            defer { pending = Data() }
            return pending
        }

        public struct TooLarge: Error {}
    }
}
