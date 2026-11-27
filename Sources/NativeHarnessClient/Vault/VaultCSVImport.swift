import Foundation

/// Sign-ins exported from a browser or password manager as CSV (design §8.1): Chrome's and
/// 1Password's `name`/`title`, `url`, `username`, `password` columns and Bitwarden's `name`,
/// `login_uri`, `login_username`, `login_password`, in any order and among other columns, with the
/// two-factor code where the export has one (1Password's and Apple Passwords' `OTPAuth`, Bitwarden's
/// `login_totp`; design §14).
enum VaultCSVImport {
    struct Entry: Equatable, Sendable {
        var name: String
        var sites: [String]
        var username: String
        var password: String
        var oneTimeCode: OneTimeCodeSecret? = nil
    }

    private static let nameColumns = ["name", "title"]
    private static let addressColumns = ["url", "login_uri"]
    private static let usernameColumns = ["username", "login_username"]
    private static let passwordColumns = ["password", "login_password"]
    private static let codeColumns = ["otpauth", "login_totp", "totp"]

    /// The sign-ins in an export, in file order. A row is left out without a password or two-factor code; one
    /// without a site Yardlet can fill on (`VaultSite.suggestion(for:)`) keeps only its code, as a code with no site
    /// the person links (design §14.3). A row that follows one of the same name, username, password and code joins it
    /// with its sites: an export writes a sign-in's sites in rows one after another (`VaultCSVExport`). Rows apart from
    /// each other stay apart, as two accounts that share a password are.
    static func entries(_ text: String, suffixes: PublicSuffixList = .bundled) -> [Entry] {
        let rows = records(text)
        guard let header = rows.first else { return [] }
        let columns = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func column(_ names: [String]) -> Int? {
            names.lazy.compactMap { columns.firstIndex(of: $0) }.first
        }
        guard let address = column(addressColumns), let password = column(passwordColumns) else { return [] }
        let name = column(nameColumns), username = column(usernameColumns), code = column(codeColumns)
        var entries: [Entry] = []
        for row in rows.dropFirst() {
            func value(_ index: Int?) -> String {
                guard let index, row.indices.contains(index) else { return "" }
                return row[index]
            }
            var secret = value(password)
            let oneTimeCode = OneTimeCodeSecret(setupText: value(code))
            let sites = Self.sites(in: value(address), suffixes: suffixes)
            if sites.isEmpty { secret = "" }
            guard !secret.isEmpty || oneTimeCode != nil else { continue }
            let title = value(name).trimmingCharacters(in: .whitespacesAndNewlines)
            let username = value(username).trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = Entry(name: title.isEmpty ? sites.first ?? username : title, sites: sites, username: username,
                              password: secret, oneTimeCode: oneTimeCode)
            if let last = entries.indices.last, !sites.isEmpty, !entries[last].sites.isEmpty,
               entries[last].name == entry.name, entries[last].username == entry.username,
               entries[last].password == entry.password, entries[last].oneTimeCode == entry.oneTimeCode {
                entries[last].sites += sites.filter { !entries[last].sites.contains($0) }
            } else {
                entries.append(entry)
            }
        }
        return entries
    }

    /// The sites of one row's address field. Bitwarden puts several addresses in one field; an
    /// address without a scheme is read as https.
    private static func sites(in field: String, suffixes: PublicSuffixList) -> [String] {
        var sites: [String] = []
        for part in field.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let address = part.trimmingCharacters(in: .whitespaces)
            guard !address.isEmpty else { continue }
            let site = VaultSite.suggestion(for: address, suffixes: suffixes)
                ?? (address.contains("://") ? nil : VaultSite.suggestion(for: "https://" + address, suffixes: suffixes))
            if let site, !sites.contains(site) { sites.append(site) }
        }
        return sites
    }

    /// RFC 4180 records: fields split at commas, a quoted field may hold commas, line breaks and
    /// doubled quotes, and lines end in CRLF, LF or CR. Blank lines are left out. Read by Unicode
    /// scalar, as other managers' parsers read bytes: a comma or quote followed by a combining mark
    /// is still a comma or a quote.
    static func records(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false
        var fieldWasQuoted = false
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        var index = 0
        func endField() {
            record.append(String(field))
            field = String.UnicodeScalarView()
            fieldWasQuoted = false
        }
        func endRecord() {
            let wasQuoted = fieldWasQuoted
            endField()
            if !(record.count == 1 && record[0].isEmpty && !wasQuoted) { records.append(record) }
            record = []
        }
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if quoted {
                if scalar == "\"" {
                    if index < scalars.count, scalars[index] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"" where field.isEmpty && !fieldWasQuoted:
                quoted = true
                fieldWasQuoted = true
            case ",":
                endField()
            case "\r":
                if index < scalars.count, scalars[index] == "\n" { index += 1 }
                endRecord()
            case "\n":
                endRecord()
            default:
                field.append(scalar)
            }
        }
        if !field.isEmpty || !record.isEmpty || fieldWasQuoted { endRecord() }
        return records
    }
}

extension VaultCenter {
    /// Saves imported sign-ins and says how many were saved. One already in the vault for the same
    /// site and username takes the new password and keeps the rest; any other becomes a new item
    /// the agent may use at any time, as an item made by hand is. A name already taken gets the
    /// username after it, so an agent can name either. A code with no site is left out when an item
    /// already keeps it, as an authenticator app's import is. Codes with no site whose account's
    /// sign-in came in take its site (`linkCodesToTheirSignIns`).
    @discardableResult
    func importSignIns(_ entries: [VaultCSVImport.Entry]) -> Int {
        var saved = 0
        for entry in entries {
            if entry.sites.isEmpty, let code = entry.oneTimeCode, holds(code) { continue }
            if let existing = items.first(where: { item in
                item.username == entry.username && item.sites.contains { entry.sites.contains($0) }
            }) {
                let hasSecrets = existing.hasPassword || existing.hasOneTimeCode || existing.hasPasskey
                // A secret the keychain would not give back is kept rather than overwritten.
                guard var secret = hasSecrets ? secret(of: existing.id) : VaultSecret() else { continue }
                if !entry.password.isEmpty { secret.password = entry.password }
                if let code = entry.oneTimeCode { secret.oneTimeCode = code }
                guard (try? save(existing, secret: secret)) != nil else { continue }
            } else {
                var name = entry.name.isEmpty ? L10n.string("Two-factor code") : entry.name
                if !entry.username.isEmpty,
                   items.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
                    name += " (\(entry.username))"
                }
                let item = VaultItem(name: name, sites: entry.sites, username: entry.username, policy: .always)
                let secret = VaultSecret(password: entry.password.isEmpty ? nil : entry.password, oneTimeCode: entry.oneTimeCode)
                guard (try? save(item, secret: secret)) != nil else { continue }
            }
            saved += 1
        }
        if saved > 0 { linkCodesToTheirSignIns() }
        return saved
    }
}
