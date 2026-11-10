import Foundation

/// Where a mail account's IMAP and SMTP servers are and whom to sign in as. Nothing here is secret;
/// the password is in the secure store under the account's connector.
struct MailServerSettings: Codable, Equatable, Sendable {
    /// The preset it came from (`MailServerPreset.id`); nil for servers the person typed.
    var preset: String?
    var imapHost: String
    var imapPort: Int
    var imapSecurity: MailSocketSecurity
    var imapUsername: String
    var smtpHost: String
    var smtpPort: Int
    var smtpSecurity: MailSocketSecurity
    var smtpUsername: String

    /// The servers the password goes to, which it is bound to (`ConnectorRecord.credentialDestination`).
    var credentialDestination: String {
        "mail:\(imapHost.lowercased()):\(imapPort),\(smtpHost.lowercased()):\(smtpPort)"
    }
}

/// A mail service that is reached over IMAP and SMTP with an app password, as its own help pages give
/// it: the servers, the user name, and what the person turns on first on the service's website. Gmail
/// and Outlook are not here; their accounts come through their own connectors' sign-in.
struct MailServerPreset: Identifiable, Hashable, Sendable {
    struct Server: Hashable, Sendable {
        var host: String
        var port: Int
        var security: MailSocketSecurity
    }

    /// One thing to do on the service before connecting, with where to do it.
    struct Step: Hashable, Sendable {
        /// Localized with `L10n.string`.
        var text: String
        var link: URL?
    }

    let id: String
    let name: String
    /// Addresses at these domains pick this preset.
    let domains: [String]
    let imap: Server
    let smtp: Server
    /// iCloud takes the address's name part as the IMAP user name; everyone else the whole address.
    var imapUsesNamePart = false
    let steps: [Step]

    /// The settings for an account at `address`.
    func settings(for address: String) -> MailServerSettings {
        let name = address.split(separator: "@", maxSplits: 1).first.map(String.init) ?? address
        return MailServerSettings(preset: id, imapHost: imap.host, imapPort: imap.port, imapSecurity: imap.security,
                                  imapUsername: imapUsesNamePart ? name : address,
                                  smtpHost: smtp.host, smtpPort: smtp.port, smtpSecurity: smtp.security, smtpUsername: address)
    }

    static func preset(id: String) -> MailServerPreset? { all.first { $0.id == id } }

    /// The preset whose domain the address is at.
    static func matching(_ address: String) -> MailServerPreset? {
        guard let domain = address.split(separator: "@").last.map({ $0.lowercased() }), address.contains("@") else { return nil }
        return all.first { $0.domains.contains(domain) }
    }

    /// Addresses whose service has its own connector, which reads it better than IMAP.
    static func connectorService(for address: String) -> LocalConnectorService? {
        guard let domain = address.split(separator: "@").last.map({ $0.lowercased() }), address.contains("@") else { return nil }
        if ["gmail.com", "googlemail.com"].contains(domain) { return .gmail }
        if ["outlook.com", "hotmail.com", "live.com", "msn.com"].contains(domain) { return .outlookMail }
        return nil
    }

    private static func step(_ text: String, _ link: String? = nil) -> Step {
        Step(text: text, link: link.flatMap(URL.init(string:)))
    }

    /// The services, most used here first. Servers and ports are those the services' help pages give
    /// (docs/MAILBOX.md, "Mail accounts over IMAP").
    static let all: [MailServerPreset] = [
        MailServerPreset(
            id: "naver", name: "Naver Mail", domains: ["naver.com"],
            imap: Server(host: "imap.naver.com", port: 993, security: .tls),
            smtp: Server(host: "smtp.naver.com", port: 465, security: .tls),
            steps: [step("Turn on 2-step verification in your Naver ID's security settings.", "https://nid.naver.com"),
                    step("There, create an application password: choose to enter its name yourself and name it Yardlet."),
                    step("In Naver Mail, Settings › POP3/IMAP Settings › IMAP/SMTP, choose Use.", "https://mail.naver.com")]),
        MailServerPreset(
            id: "daum", name: "Daum Mail", domains: ["daum.net", "hanmail.net"],
            imap: Server(host: "imap.daum.net", port: 993, security: .tls),
            smtp: Server(host: "smtp.daum.net", port: 465, security: .tls),
            steps: [step("Turn on 2-step verification for the account you sign in to Daum with.", "https://accounts.kakao.com"),
                    step("Create an app password on Daum's My Page (Daum member › My Page › Account security).", "https://mail.daum.net"),
                    step("In Daum Mail, Settings › IMAP/POP3, choose Use.", "https://mail.daum.net")]),
        MailServerPreset(
            id: "kakao", name: "Kakao Mail", domains: ["kakao.com"],
            imap: Server(host: "imap.kakao.com", port: 993, security: .tls),
            smtp: Server(host: "smtp.kakao.com", port: 465, security: .tls),
            steps: [step("Turn on 2-step verification in your Kakao account's security settings.", "https://accounts.kakao.com"),
                    step("There, create an app password (2-step verification › App password)."),
                    step("In Kakao Mail, Settings › POP3/IMAP, choose Use.", "https://mail.kakao.com/setting/POP3IMAP")]),
        MailServerPreset(
            id: "naverworks", name: "NAVER WORKS", domains: [],
            imap: Server(host: "imap.worksmobile.com", port: 993, security: .tls),
            smtp: Server(host: "smtp.worksmobile.com", port: 465, security: .tls),
            steps: [step("Your administrator allows IMAP/SMTP for your account (Standard plan or above)."),
                    step("Create a third-party app password in your profile › Security.",
                         "https://help.worksmobile.com/en/use-guides/settings/security/3rd-party-app-password/")]),
        MailServerPreset(
            id: "icloud", name: "iCloud Mail", domains: ["icloud.com", "me.com", "mac.com"],
            imap: Server(host: "imap.mail.me.com", port: 993, security: .tls),
            smtp: Server(host: "smtp.mail.me.com", port: 587, security: .startTLS),
            imapUsesNamePart: true,
            steps: [step("Your Apple Account uses two-factor authentication."),
                    step("Create an app-specific password in your Apple Account › Sign-In and Security › App-Specific Passwords.",
                         "https://account.apple.com")]),
        MailServerPreset(
            id: "yahoo", name: "Yahoo Mail", domains: ["yahoo.com", "ymail.com", "rocketmail.com"],
            imap: Server(host: "imap.mail.yahoo.com", port: 993, security: .tls),
            smtp: Server(host: "smtp.mail.yahoo.com", port: 465, security: .tls),
            steps: [step("Create an app password in Yahoo's Account Security.", "https://login.yahoo.com/account/security")]),
        MailServerPreset(
            id: "aol", name: "AOL Mail", domains: ["aol.com"],
            imap: Server(host: "imap.aol.com", port: 993, security: .tls),
            smtp: Server(host: "smtp.aol.com", port: 465, security: .tls),
            steps: [step("Create an app password in AOL's Account Security.", "https://login.aol.com/account/security")]),
        MailServerPreset(
            id: "zoho", name: "Zoho Mail", domains: ["zoho.com", "zohomail.com"],
            imap: Server(host: "imap.zoho.com", port: 993, security: .tls),
            smtp: Server(host: "smtp.zoho.com", port: 465, security: .tls),
            steps: [step("In Zoho Mail, Settings › Mail Accounts › IMAP Access, turn IMAP on (paid plans).", "https://mail.zoho.com"),
                    step("With two-factor sign-in on, create an app-specific password in Zoho Accounts › Security.",
                         "https://accounts.zoho.com")]),
        MailServerPreset(
            id: "zoho-organization", name: "Zoho Mail for organizations", domains: [],
            imap: Server(host: "imappro.zoho.com", port: 993, security: .tls),
            smtp: Server(host: "smtppro.zoho.com", port: 465, security: .tls),
            steps: [step("In Zoho Mail, Settings › Mail Accounts › IMAP Access, turn IMAP on.", "https://mail.zoho.com"),
                    step("With two-factor sign-in on, create an app-specific password in Zoho Accounts › Security.",
                         "https://accounts.zoho.com")]),
        MailServerPreset(
            id: "fastmail", name: "Fastmail", domains: ["fastmail.com", "fastmail.fm"],
            imap: Server(host: "imap.fastmail.com", port: 993, security: .tls),
            smtp: Server(host: "smtp.fastmail.com", port: 465, security: .tls),
            steps: [step("Create an app password with IMAP and SMTP access in Fastmail's Settings › Privacy & Security.",
                         "https://app.fastmail.com/settings/security")]),
        MailServerPreset(
            id: "proton-bridge", name: "Proton Mail Bridge", domains: [],
            imap: Server(host: "127.0.0.1", port: 1143, security: .startTLS),
            smtp: Server(host: "127.0.0.1", port: 1025, security: .startTLS),
            steps: [step("Install Proton Mail Bridge and sign in to it (paid Proton plans).", "https://proton.me/mail/bridge"),
                    step("Use the address and the password Bridge shows for your account, not your Proton password."),
                    step("In Bridge's settings, export its TLS certificate and add it to Keychain Access as trusted.")]),
    ]
}
