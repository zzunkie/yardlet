import Foundation

/// The vault's sign-ins as a CSV file the person takes to another password manager (design §8.1): the columns of Apple
/// Passwords' export, `Title,URL,Username,Password,Notes,OTPAuth`. Chrome reads `URL`, `Username`, `Password` and
/// `Notes` in any case and passes over the others; Bitwarden's "Safari and macOS" import and 1Password's "Safari" import
/// take Apple's file, Bitwarden with its `OTPAuth` column; Yardlet's own Import CSV reads it back (`VaultCSVImport`).
/// A sign-in saved for several sites takes a row for each, as Chrome and Apple Passwords export one; a two-factor code
/// with no site takes one row with no address. Passkeys, previous passwords, addresses and cards are left out.
enum VaultCSVExport {
    static let header = ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"]

    struct Row: Equatable, Sendable {
        var title: String
        var url: String
        var username: String
        var password: String
        /// The sign-in's other fields (design §17), one `label: value` line each.
        var notes: String
        var otpAuth: String

        var fields: [String] { [title, url, username, password, notes, otpAuth] }
    }

    /// One item's rows: none when it holds no password and no code (a passkey alone).
    static func rows(of item: VaultItem, secret: VaultSecret) -> [Row] {
        let password = secret.password ?? ""
        let code = secret.oneTimeCode.map { otpAuth($0, issuer: item.name, account: item.username) } ?? ""
        guard !password.isEmpty || !code.isEmpty else { return [] }
        let fields = (item.fields ?? []) + (secret.fields ?? [])
        let notes = fields.filter { !$0.value.isEmpty }.map { "\($0.title): \($0.value)" }.joined(separator: "\n")
        // The sites saved with the secret, not `items.json`'s, which any process of the person's can write (design §5.3).
        let sites = secret.savedSites ?? item.sites
        let addresses = sites.isEmpty ? [""] : sites.map(address(of:))
        return addresses.map { Row(title: item.name, url: $0, username: item.username, password: password, notes: notes,
                                   otpAuth: code) }
    }

    /// The file's text: RFC 4180, with CRLF line ends.
    static func text(_ rows: [Row]) -> String {
        ([header] + rows.map(\.fields)).map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// An address for a site: `github.com` → `https://github.com/`; a development server's origin as it is.
    static func address(of site: String) -> String {
        (site.contains("://") ? site : "https://" + site) + "/"
    }

    /// The code's `otpauth://totp/` link, as authenticator apps and password managers take a setup.
    static func otpAuth(_ secret: OneTimeCodeSecret, issuer: String, account: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        let label = account.isEmpty ? encoded(issuer) : "\(encoded(issuer)):\(encoded(account))"
        return "otpauth://totp/\(label)?secret=\(Base32.encode(secret.key))&issuer=\(encoded(issuer))"
            + "&algorithm=\(secret.algorithm.rawValue.uppercased())&digits=\(secret.digits)&period=\(secret.period)"
    }

    /// A field quoted when it holds a comma, a quote, a line break or space at either end; quotes doubled. Read by
    /// Unicode scalar, as importers read the file: a comma or quote followed by a combining mark is still one.
    private static func field(_ value: String) -> String {
        let scalars = value.unicodeScalars
        let needsQuotes = scalars.contains { $0 == "," || $0 == "\"" || CharacterSet.newlines.contains($0) }
            || [scalars.first, scalars.last].contains { $0.map(CharacterSet.whitespacesAndNewlines.contains) == true }
        guard needsQuotes else { return value }
        var quoted = String.UnicodeScalarView()
        quoted.append("\"")
        for scalar in scalars {
            quoted.append(scalar)
            if scalar == "\"" { quoted.append("\"") }
        }
        quoted.append("\"")
        return String(quoted)
    }
}

extension VaultCenter {
    struct SignInExport: Equatable {
        /// Items in the file.
        var count: Int
        /// Items whose secret the keychain did not give.
        var unreadable: Int
    }

    /// Writes every sign-in and two-factor code to a CSV file: once the person at this Mac confirms with Touch ID or
    /// the login password, they choose the file (`chooseFile`, nil to stop), and only then are the secrets read, into
    /// a file only their account may read (`StateFile.write`). Nil when they did not confirm or chose no file. Only the
    /// Export button in Settings → Passwords asks for it: no tool does, and nothing of it is logged. The one
    /// confirmation reads every item, those an agent may use only after Touch ID too, since that step is Yardlet's own
    /// check before it reads the keychain (design §4.3). The vault being off does not stop it: off is not removed,
    /// and the export is the way out.
    func exportSignIns(choosingFile chooseFile: () -> URL?) async throws -> SignInExport? {
        guard isAllowedBuild, await confirmPerson(L10n.string("export all saved passwords to a file")),
              let file = chooseFile() else { return nil }
        var rows: [VaultCSVExport.Row] = []
        var count = 0
        var unreadable = 0
        for item in items {
            guard let secret = secret(of: item.id) else {
                if item.hasPassword || item.hasOneTimeCode { unreadable += 1 }
                continue
            }
            let itemRows = VaultCSVExport.rows(of: item, secret: secret)
            guard !itemRows.isEmpty else { continue }
            rows += itemRows
            count += 1
        }
        try StateFile.write(Data(VaultCSVExport.text(rows).utf8), to: file, isPrivate: true)
        return SignInExport(count: count, unreadable: unreadable)
    }
}
