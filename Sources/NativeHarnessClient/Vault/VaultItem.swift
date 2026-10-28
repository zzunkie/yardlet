import Foundation

/// One sign-in the person keeps in Yardlet's vault for agents (docs/BROWSER_VAULT_DESIGN.md). The
/// item holds what is not secret: its name, the sites it is for, the username, which secrets it has
/// and how the agent may use it. The secrets themselves live in `VaultSecret`, in the keychain.
struct VaultItem: Codable, Identifiable, Equatable, Sendable {
    /// How an agent may use the item (design §6.1).
    enum Policy: String, Codable, CaseIterable, Sendable {
        /// Fills without asking, also while the person is away.
        case always
        /// Fills without asking while the vault is unlocked; a locked vault asks for Touch ID once.
        case whileUnlocked
        /// Asks for Touch ID at every fill.
        case everyTime
    }

    var id: UUID
    var name: String
    /// Hosts such as `github.com` (the site and its subdomains, over https), or an exact origin such
    /// as `http://localhost:3000` for a development server.
    var sites: [String]
    var username: String
    var hasPassword: Bool
    var hasOneTimeCode: Bool
    var hasPasskey: Bool
    var policy: Policy
    var createdAt: Date
    var lastUsedAt: Date?

    init(id: UUID = UUID(), name: String, sites: [String], username: String, hasPassword: Bool = false,
         hasOneTimeCode: Bool = false, hasPasskey: Bool = false, policy: Policy = .always,
         createdAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.sites = sites
        self.username = username
        self.hasPassword = hasPassword
        self.hasOneTimeCode = hasOneTimeCode
        self.hasPasskey = hasPasskey
        self.policy = policy
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

/// The secrets of one item, as the keychain keeps them.
struct VaultSecret: Codable, Equatable, Sendable {
    var password: String?
    var oneTimeCode: OneTimeCodeSecret?
    var passkey: VaultPasskey?
    /// The item's sites and agent policy as Yardlet last saved them (`VaultCenter.save`). `items.json` is a plain file
    /// any process of the person's can write, the keychain item only Yardlet can read, so the secret goes only where
    /// and as these say.
    var savedSites: [String]?
    var savedPolicy: VaultItem.Policy?
    /// The passwords this one replaced, newest first (design §15): a change the site did not take loses
    /// nothing. Nil in items saved before they were kept.
    var previousPasswords: [VaultPreviousPassword]?

    init(password: String? = nil, oneTimeCode: OneTimeCodeSecret? = nil, passkey: VaultPasskey? = nil,
         previousPasswords: [VaultPreviousPassword]? = nil) {
        self.password = password
        self.oneTimeCode = oneTimeCode
        self.passkey = passkey
        self.previousPasswords = previousPasswords
    }
}

/// A password an item held before, and when another replaced it.
struct VaultPreviousPassword: Codable, Equatable, Sendable {
    var password: String
    var replacedAt: Date
}

/// A passkey Yardlet holds itself (design §5.2): the credential a CDP virtual authenticator
/// created for the site, with its private key.
struct VaultPasskey: Codable, Equatable, Sendable {
    /// Base64 of the credential ID, as CDP `WebAuthn.Credential` carries it.
    var credentialID: String
    var relyingPartyID: String
    /// Base64 of the user handle.
    var userHandle: String
    /// Base64 of the PKCS#8 private key.
    var privateKey: String
    var signCount: Int
}

/// A TOTP secret (RFC 6238): the shared key and how codes are made from it.
struct OneTimeCodeSecret: Codable, Equatable, Sendable {
    enum Algorithm: String, Codable, Sendable {
        case sha1, sha256, sha512
    }

    var key: Data
    var digits: Int
    var period: Int
    var algorithm: Algorithm

    init(key: Data, digits: Int = 6, period: Int = 30, algorithm: Algorithm = .sha1) {
        self.key = key
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    /// A setup key as sites show it (base32, any case, spaces allowed) or an `otpauth://totp/…` address.
    init?(setupText: String) {
        let text = setupText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: text), components.scheme?.lowercased() == "otpauth" {
            guard components.host?.lowercased() == "totp" else { return nil }
            let query = Dictionary((components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }) { $1 }
            guard let secret = query["secret"], let key = Base32.decode(secret) else { return nil }
            let digits = query["digits"].flatMap(Int.init) ?? 6
            let period = query["period"].flatMap(Int.init) ?? 30
            let algorithm = query["algorithm"].flatMap { Algorithm(rawValue: $0.lowercased()) } ?? .sha1
            guard (6...8).contains(digits), period > 0 else { return nil }
            self.init(key: key, digits: digits, period: period, algorithm: algorithm)
        } else {
            guard let key = Base32.decode(text), !key.isEmpty else { return nil }
            self.init(key: key)
        }
    }
}

/// RFC 6238 time-based codes. The keyed hash comes from the platform (`hmac`), so the engine needs
/// no cryptography library.
enum OneTimeCode {
    typealias HMAC = (OneTimeCodeSecret.Algorithm, _ key: Data, _ message: Data) -> Data

    static func code(for secret: OneTimeCodeSecret, at date: Date, hmac: HMAC) -> String {
        let counter = UInt64(max(0, date.timeIntervalSince1970) / Double(secret.period))
        let message = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let hash = [UInt8](hmac(secret.algorithm, secret.key, message))
        guard let last = hash.last else { return "" }
        // RFC 4226 §5.3 dynamic truncation.
        let offset = Int(last & 0x0f)
        guard offset + 3 < hash.count else { return "" }
        let binary = (UInt32(hash[offset] & 0x7f) << 24) | (UInt32(hash[offset + 1]) << 16)
            | (UInt32(hash[offset + 2]) << 8) | UInt32(hash[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<secret.digits { modulus *= 10 }
        let value = String(binary % modulus)
        return String(repeating: "0", count: max(0, secret.digits - value.count)) + value
    }
}

/// RFC 4648 base32, as TOTP setup keys are written.
enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// Unpadded, in capitals, as sites show a setup key.
    static func encode(_ data: Data) -> String {
        var bits: UInt32 = 0
        var count = 0
        var text = ""
        for byte in data {
            bits = (bits << 8) | UInt32(byte)
            count += 8
            while count >= 5 {
                count -= 5
                text.append(alphabet[Int((bits >> UInt32(count)) & 31)])
            }
        }
        if count > 0 { text.append(alphabet[Int((bits << UInt32(5 - count)) & 31)]) }
        return text
    }

    static func decode(_ text: String) -> Data? {
        var bits: UInt32 = 0
        var count = 0
        var bytes: [UInt8] = []
        for character in text.uppercased() where character != " " && character != "-" && character != "=" {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            bits = (bits << 5) | UInt32(index)
            count += 5
            if count >= 8 {
                count -= 8
                bytes.append(UInt8((bits >> UInt32(count)) & 0xff))
            }
        }
        return Data(bytes)
    }
}
