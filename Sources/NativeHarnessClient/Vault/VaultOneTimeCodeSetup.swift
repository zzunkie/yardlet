import Foundation

/// A two-factor code to keep (docs/BROWSER_VAULT_DESIGN.md §14): set up from a site's QR code or
/// setup link (`otpauth://totp/…`), or brought over from an authenticator app's export (Google
/// Authenticator's `otpauth-migration://offline?data=…`). The secret, and the issuer and account the
/// code is for, as the app or site named them.
struct OneTimeCodeSetup: Equatable, Sendable {
    var secret: OneTimeCodeSecret
    var issuer: String
    var account: String

    /// The name a new item takes: the issuer, else the account.
    var itemName: String { issuer.isEmpty ? account : issuer }

    /// The codes a QR code or link holds, and how many of its accounts Yardlet cannot keep
    /// (counter-based HOTP, MD5). Other text holds none.
    static func setups(in text: String) -> (setups: [OneTimeCodeSetup], unsupported: Int) {
        // Some apps leave the label's spaces unencoded.
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "%20")
        guard let components = URLComponents(string: text) else { return ([], 0) }
        switch components.scheme?.lowercased() {
        case "otpauth":
            guard components.host?.lowercased() == "totp" else { return ([], 1) }
            guard let secret = OneTimeCodeSecret(setupText: text) else { return ([], 0) }
            var label = components.path
            if label.hasPrefix("/") { label.removeFirst() }
            let (prefix, account) = split(label)
            let issuer = components.queryItems?.first { $0.name.lowercased() == "issuer" }?.value ?? ""
            return ([OneTimeCodeSetup(secret: secret, issuer: issuer.isEmpty ? prefix : issuer, account: account)], 0)
        case "otpauth-migration":
            guard let data = components.queryItems?.first(where: { $0.name == "data" })?.value,
                  let payload = Data(base64Encoded: base64(data)) else { return ([], 0) }
            return migration(payload)
        default:
            return ([], 0)
        }
    }

    /// "Issuer:account" as labels write it; a label without the colon is the account.
    private static func split(_ label: String) -> (issuer: String, account: String) {
        let trim = { (text: Substring) in text.trimmingCharacters(in: .whitespaces) }
        guard let colon = label.firstIndex(of: ":") else { return ("", trim(label[...])) }
        return (trim(label[..<colon]), trim(label[label.index(after: colon)...]))
    }

    /// Standard base64 with its padding, whichever alphabet and padding the export used.
    private static func base64(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return text
    }

    /// Google Authenticator's `MigrationPayload` (protobuf): field 1 repeats `OtpParameters`, which holds
    /// secret (1, bytes), name (2), issuer (3), algorithm (4: 1 SHA-1, 2 SHA-256, 3 SHA-512, 4 MD5),
    /// digits (5: 1 six, 2 eight) and type (6: 1 HOTP, 2 TOTP). Codes last 30 seconds.
    private static func migration(_ payload: Data) -> (setups: [OneTimeCodeSetup], unsupported: Int) {
        var setups: [OneTimeCodeSetup] = []
        var unsupported = 0
        var reader = ProtobufReader(payload)
        while let field = reader.next() {
            guard field.number == 1, case .bytes(let parameters) = field.value else { continue }
            var secret = Data(), name = "", issuer = ""
            var algorithm: OneTimeCodeSecret.Algorithm? = .sha1
            var digits = 6
            var isTOTP = true
            var inner = ProtobufReader(parameters)
            while let part = inner.next() {
                switch (part.number, part.value) {
                case (1, .bytes(let bytes)): secret = bytes
                case (2, .bytes(let bytes)): name = String(decoding: bytes, as: UTF8.self)
                case (3, .bytes(let bytes)): issuer = String(decoding: bytes, as: UTF8.self)
                case (4, .varint(let value)): algorithm = [0: .sha1, 1: .sha1, 2: .sha256, 3: .sha512][value]
                case (5, .varint(let value)): digits = value == 2 ? 8 : 6
                case (6, .varint(let value)): isTOTP = value != 1
                default: break
                }
            }
            guard isTOTP, let algorithm, !secret.isEmpty else {
                unsupported += 1
                continue
            }
            // The name is "issuer:account" or the account; a prefix other than the issuer is part of the account.
            let (prefix, rest) = split(name)
            let account = prefix.isEmpty || issuer.isEmpty || prefix == issuer ? rest : name
            setups.append(OneTimeCodeSetup(secret: OneTimeCodeSecret(key: secret, digits: digits, algorithm: algorithm),
                                           issuer: issuer.isEmpty ? prefix : issuer, account: account))
        }
        return (setups, unsupported)
    }
}

/// Just enough protobuf to read an export: varints and length-delimited fields; fixed-width ones are skipped.
private struct ProtobufReader {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
    }

    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    /// The next field, or nil at the end or at bytes that are not protobuf.
    mutating func next() -> (number: Int, value: Value)? {
        while index < bytes.count {
            guard let key = varint() else { return nil }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint() else { return nil }
                return (number, .varint(value))
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - index) else { return nil }
                let start = index
                index += Int(length)
                return (number, .bytes(Data(bytes[start..<index])))
            case 1 where index + 8 <= bytes.count: index += 8
            case 5 where index + 4 <= bytes.count: index += 4
            default: return nil
            }
        }
        return nil
    }

    private mutating func varint() -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}

extension VaultCenter {
    /// Saves codes from an authenticator app's export or a QR image as items of their own, with no
    /// site or password (an authenticator's entries), and leaves out codes the vault already keeps. A
    /// code whose account's sign-in is saved takes that sign-in's site (`linkCodesToTheirSignIns`).
    /// Returns how many it saved.
    func importOneTimeCodes(_ setups: [OneTimeCodeSetup]) async -> Int {
        await beginChange()
        defer { endChange() }
        var saved = 0
        for setup in setups where await !hasStoredCode(setup.secret) {
            var name = setup.itemName.isEmpty ? L10n.string("Two-factor code") : setup.itemName
            if !setup.account.isEmpty, name != setup.account,
               items.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
                name += " (\(setup.account))"
            }
            let item = VaultItem(name: name, sites: [], username: setup.account, policy: .always)
            guard (try? await saveItem(item, secret: VaultSecret(oneTimeCode: setup.secret))) != nil else { continue }
            saved += 1
        }
        if saved > 0 { _ = await linkSavedCodes() }
        return saved
    }

    /// Whether an item already keeps this code's secret.
    func holds(_ secret: OneTimeCodeSecret) async -> Bool {
        await beginChange()
        defer { endChange() }
        return await hasStoredCode(secret)
    }

    /// The caller holds the vault change gate throughout the scan.
    func hasStoredCode(_ secret: OneTimeCodeSecret) async -> Bool {
        for item in items where item.hasOneTimeCode {
            if await self.secret(of: item.id)?.oneTimeCode?.key == secret.key { return true }
        }
        return false
    }

    /// The item a site's new code goes into: the site's item for the code's account, else the site's
    /// only item. Nil means a new item for the site.
    func oneTimeCodeTarget(for setup: OneTimeCodeSetup, origin: String) -> VaultItem? {
        let here = items(for: origin)
        let account = setup.account
        if !account.isEmpty {
            let same = here.filter { $0.username.compare(account, options: .caseInsensitive) == .orderedSame }
            if same.count == 1 { return same[0] }
        }
        return here.count == 1 ? here[0] : nil
    }

    /// Puts a site's code into an item (replacing its code), or into a new item for the site. Returns
    /// the item it saved.
    @discardableResult
    func saveOneTimeCode(_ setup: OneTimeCodeSetup, site: String, into item: VaultItem?) async throws -> VaultItem {
        await beginChange()
        defer { endChange() }
        if let requested = item {
            // A secret the keychain would not give back, or one whose item changed outside Yardlet, is left as it is.
            guard let item = items.first(where: { $0.id == requested.id }), item.sites == requested.sites,
                  item.username == requested.username, var secret = try await trustedSecret(of: item) else {
                throw VaultRefusal(message: L10n.string("Yardlet could not read this sign-in from the keychain."))
            }
            secret.oneTimeCode = setup.secret
            try await saveItem(item, secret: secret)
            return items.first { $0.id == item.id } ?? item
        }
        let new = VaultItem(name: setup.issuer.isEmpty ? VaultSite.host(of: site) : setup.issuer, sites: [site],
                            username: setup.account, policy: .always)
        try await saveItem(new, secret: VaultSecret(oneTimeCode: setup.secret))
        return items.first { $0.id == new.id } ?? new
    }
}

extension VaultRefusal: LocalizedError {
    var errorDescription: String? { message }
}
