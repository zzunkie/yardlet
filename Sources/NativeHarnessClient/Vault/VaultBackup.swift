import Crypto
import Foundation

/// An encrypted backup of the vault in one file (design §8.1), for a Mac without Migration Assistant or a copy kept
/// apart from Time Machine. Each backup has a recovery key of its own, 150 random bits Yardlet shows once and does
/// not keep; the file is sealed with AES-256-GCM under a key HKDF-SHA256 derives from it and a random salt. The key's
/// randomness, not a password the person chose, is what protects the file, so a fast derivation is enough.
///
/// The file holds each item's name, sites, username, other fields, agent use and date, its password and the
/// sign-in's other secrets, previous passwords and two-factor key, and, when the person keeps them in, the addresses
/// and cards. Passkeys stay on the Mac that made them: a copy elsewhere would give a site a second authenticator
/// it counts as one (design §5.2), so a backup only notes which items had one. Usage, last use and settings stay too.
enum VaultBackup {
    static let format = "yardlet-vault-backup"
    static let version = 1
    static let fileExtension = "yardletbackup"
    /// Crockford's base32: no I, L, O or U, so a key read aloud or copied by hand is not misread.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let keyLength = 30

    struct Contents: Codable, Equatable, Sendable {
        struct Item: Codable, Equatable, Sendable {
            var name: String
            var sites: [String]
            var username: String
            var policy: VaultItem.Policy
            var createdAt: Date
            var fields: [VaultFormField]?
            var password: String?
            var secretFields: [VaultFormField]?
            var oneTimeCode: OneTimeCodeSecret?
            var previousPasswords: [VaultPreviousPassword]?
            /// The item had a Yardlet passkey, which stayed on the Mac that made it.
            var hadPasskey: Bool
        }

        var items: [Item]
        var wallet: VaultWallet?
    }

    enum Failure: Error, Equatable, LocalizedError {
        /// Not a backup Yardlet wrote.
        case notABackup
        /// Written by a later Yardlet.
        case newerVersion
        /// The key does not open it (mistyped, another backup's, or the file was changed).
        case wrongKey
        /// The system's random source gave no key.
        case noRandomKey

        var errorDescription: String? {
            switch self {
            case .notABackup: L10n.string("This file is not a Yardlet backup.")
            case .newerVersion: L10n.string("A newer Yardlet made this backup. Update Yardlet to import it.")
            case .wrongKey: L10n.string("This recovery key does not open the backup.")
            case .noRandomKey: L10n.string("Yardlet could not make a recovery key. Try again.")
            }
        }
    }

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var salt: Data
        var sealed: Data
    }

    /// A new recovery key, `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`: 30 base32 characters, 150 random bits.
    static func makeRecoveryKey(randomBytes: (Int) -> [UInt8]?) -> String? {
        guard let bytes = randomBytes(keyLength), bytes.count == keyLength else { return nil }
        let characters = bytes.map { alphabet[Int($0 & 31)] }
        return stride(from: 0, to: keyLength, by: 5).map { String(characters[$0..<$0 + 5]) }.joined(separator: "-")
    }

    /// The key as typed, read as Crockford base32 reads it: any case, spaces and hyphens anywhere, O for 0, I and L
    /// for 1. Nil when it is not a whole key.
    static func normalized(_ typed: String) -> String? {
        var key = ""
        for character in typed.uppercased() where !character.isWhitespace && character != "-" {
            switch character {
            case "O": key.append("0")
            case "I", "L": key.append("1")
            case _ where alphabet.contains(character): key.append(character)
            default: return nil
            }
        }
        return key.count == keyLength ? key : nil
    }

    /// Whether a file's bytes are a backup, to tell one from a CSV export.
    static func isBackup(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.format == format
    }

    /// The backup file's bytes: the format, version and salt in the clear and bound to the sealed contents.
    static func seal(_ contents: Contents, recoveryKey: String, salt: Data) throws -> Data {
        guard let key = normalized(recoveryKey) else { throw Failure.wrongKey }
        let plaintext = try JSONEncoder().encode(contents)
        let box = try AES.GCM.seal(plaintext, using: symmetricKey(key, version: version, salt: salt),
                                   authenticating: header(version: version, salt: salt))
        guard let sealed = box.combined else { throw Failure.wrongKey }
        return try JSONEncoder().encode(Envelope(format: format, version: version, salt: salt, sealed: sealed))
    }

    static func open(_ data: Data, recoveryKey: String) throws -> Contents {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.format == format else {
            throw Failure.notABackup
        }
        guard envelope.version <= version else { throw Failure.newerVersion }
        guard let key = normalized(recoveryKey),
              let box = try? AES.GCM.SealedBox(combined: envelope.sealed),
              let plaintext = try? AES.GCM.open(box, using: symmetricKey(key, version: envelope.version, salt: envelope.salt),
                                                authenticating: header(version: envelope.version, salt: envelope.salt))
        else { throw Failure.wrongKey }
        return try JSONDecoder().decode(Contents.self, from: plaintext)
    }

    /// The file's key, for the version that wrote it.
    private static func symmetricKey(_ normalizedKey: String, version: Int, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(normalizedKey.utf8)), salt: salt,
                               info: Data("\(format) \(version) key".utf8), outputByteCount: 32)
    }

    private static func header(version: Int, salt: Data) -> Data {
        Data("\(format)/\(version)/".utf8) + salt
    }
}

extension VaultCenter {
    struct BackupExport: Equatable {
        /// Shown once, then gone: Yardlet keeps no copy.
        var recoveryKey: String
        /// Items the file can bring back: a passkey alone is only named in it.
        var count: Int
        /// Items whose secret the keychain did not give.
        var unreadable: Int
    }

    struct BackupRestore: Equatable {
        /// Items added, and saved items that took what they lacked.
        var count: Int
        /// Addresses and cards added.
        var walletCount: Int
        /// "Name · site" for each item whose passkey did not come along, to be made again on its site.
        var passkeys: [String]
    }

    /// Writes every item, and the addresses and cards when the person keeps them in, to an encrypted backup: once
    /// the person at this Mac confirms with Touch ID or the login password, they choose the file (`chooseFile`, told
    /// whether there are addresses and cards to offer; nil to stop), and only then are the secrets read, sealed under
    /// a new recovery key and written to a file only their account may read. Nil when they did not confirm or chose
    /// no file. As with the CSV export, only the person's button asks for it, one confirmation reads every item, and
    /// nothing of it is logged.
    func exportBackup(choosingFile chooseFile: (_ offersWallet: Bool) -> (file: URL, includesWallet: Bool)?)
        async throws -> BackupExport? {
        guard isAllowedBuild, await confirmPerson(L10n.string("back up all saved passwords to an encrypted file")) else {
            return nil
        }
        let wallet = self.wallet
        guard let choice = chooseFile(!wallet.isEmpty) else { return nil }
        var contents = VaultBackup.Contents(items: [], wallet: choice.includesWallet && !wallet.isEmpty ? wallet : nil)
        var unreadable = 0
        for item in items {
            guard let secret = secret(of: item.id) else {
                if item.hasPassword || item.hasOneTimeCode || item.hasPasskey { unreadable += 1 }
                continue
            }
            contents.items.append(VaultBackup.Contents.Item(
                name: item.name, sites: secret.savedSites ?? item.sites, username: item.username,
                policy: secret.savedPolicy ?? item.policy, createdAt: item.createdAt, fields: item.fields,
                password: secret.password, secretFields: secret.fields, oneTimeCode: secret.oneTimeCode,
                previousPasswords: secret.previousPasswords, hadPasskey: secret.passkey != nil))
        }
        guard let key = VaultBackup.makeRecoveryKey(randomBytes: randomBytes),
              let salt = randomBytes(32) else { throw VaultBackup.Failure.noRandomKey }
        let data = try VaultBackup.seal(contents, recoveryKey: key, salt: Data(salt))
        try StateFile.write(data, to: choice.file, isPrivate: true)
        let count = contents.items.filter { !($0.password ?? "").isEmpty || $0.oneTimeCode != nil || $0.secretFields != nil }.count
        return BackupExport(recoveryKey: key, count: count, unreadable: unreadable)
    }

    /// Restores a backup without replacing anything saved (design §8.1): an item already here for the same site
    /// and username keeps its values and takes only what it lacks (a password, a code), and a password of the backup
    /// that differs from its own joins its previous passwords; any other becomes a new item with the backup's agent
    /// use. A code with no site already kept, and an address or card already saved, are left out. Passkeys did not
    /// come along: each item that had one is named, to be made again on its site.
    @discardableResult
    func restoreBackup(_ contents: VaultBackup.Contents) -> BackupRestore {
        var restore = BackupRestore(count: 0, walletCount: 0, passkeys: [])
        let suffixes = self.suffixes
        for entry in contents.items {
            if entry.hadPasskey {
                restore.passkeys.append(([entry.name] + entry.sites.prefix(1)).joined(separator: " · "))
            }
            // Sites as Yardlet keeps them, whatever the file says: none that no page could match, such as a public
            // suffix. Without one, the item keeps only its code, as an import's row with no site does.
            var entry = entry
            var sites: [String] = []
            for site in entry.sites.compactMap({ VaultSite.normalize($0, suffixes: suffixes) }) where !sites.contains(site) {
                sites.append(site)
            }
            entry.sites = sites
            if sites.isEmpty {
                entry.password = nil
                entry.secretFields = nil
            }
            let password = entry.password ?? ""
            guard !password.isEmpty || entry.oneTimeCode != nil || !(entry.secretFields ?? []).isEmpty else { continue }
            if entry.sites.isEmpty, let code = entry.oneTimeCode, holds(code) { continue }
            if let existing = items.first(where: { item in
                item.username == entry.username && item.sites.contains { entry.sites.contains($0) }
            }) {
                // A secret the keychain would not give back, or one whose item changed outside Yardlet, is left as it is.
                guard var secret = secretToUpdate(existing) else { continue }
                var changed = false
                if (secret.password ?? "").isEmpty, !password.isEmpty {
                    secret.password = password
                    changed = true
                } else if let current = secret.password, !password.isEmpty, password != current,
                          !(secret.previousPasswords ?? []).contains(where: { $0.password == password }),
                          (secret.previousPasswords ?? []).count < Self.previousPasswordsKept {
                    // Kept after the item's own previous passwords, and only while there is room: none is pushed out.
                    secret.previousPasswords = (secret.previousPasswords ?? [])
                        + [VaultPreviousPassword(password: password, replacedAt: Date())]
                    changed = true
                }
                if secret.oneTimeCode == nil, let code = entry.oneTimeCode {
                    secret.oneTimeCode = code
                    changed = true
                }
                guard changed, (try? save(existing, secret: secret)) != nil else { continue }
            } else {
                var name = entry.name
                if !entry.username.isEmpty,
                   items.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
                    name += " (\(entry.username))"
                }
                let item = VaultItem(name: name, sites: entry.sites, username: entry.username, policy: entry.policy,
                                     createdAt: entry.createdAt, fields: entry.fields)
                let secret = VaultSecret(password: password.isEmpty ? nil : password, fields: entry.secretFields,
                                         oneTimeCode: entry.oneTimeCode, previousPasswords: entry.previousPasswords)
                guard (try? save(item, secret: secret)) != nil else { continue }
            }
            restore.count += 1
        }
        if let wallet = contents.wallet {
            for var address in wallet.addresses {
                address.id = UUID()
                guard !self.wallet.addresses.contains(where: { var saved = $0; saved.id = address.id; return saved == address })
                else { continue }
                guard (try? saveAddress(address)) != nil else { continue }
                restore.walletCount += 1
            }
            for var card in wallet.cards {
                card.id = UUID()
                guard !self.wallet.cards.contains(where: { var saved = $0; saved.id = card.id; return saved == card })
                else { continue }
                guard (try? saveCard(card)) != nil else { continue }
                restore.walletCount += 1
            }
        }
        if restore.count > 0 { linkCodesToTheirSignIns() }
        return restore
    }
}
