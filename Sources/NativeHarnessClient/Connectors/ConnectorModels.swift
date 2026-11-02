import Foundation
import YardletAgentTools

/// A service the user connected in Yardlet: a remote MCP server (Streamable HTTP) that Yardlet
/// signs in to once and offers to every harness through the Yardlet MCP server
/// (docs/CONNECTORS.md). The record carries no secret; the credential lives in the platform's
/// secure store under the record's ID.
struct ConnectorRecord: Codable, Equatable, Identifiable, Sendable {
    enum Authorization: String, Codable, Sendable {
        /// Not decided yet: the first connection finds out what the server asks for.
        case unknown
        /// OAuth 2.1 with the server's authorization server (MCP authorization).
        case oauth
        /// An access token the user pasted, sent as a bearer token.
        case token
        /// The server answers without credentials.
        case none
    }

    enum Status: String, Codable, Sendable {
        /// Added but never connected, or disconnected by the user.
        case notConnected
        /// Signed in with a tool list; its tools reach new sessions.
        case connected
        /// The server refused the credential and a refresh did not help.
        case signInRequired
    }

    var id: UUID
    var name: String
    /// Prefix of this connector's tool names, unique among connectors.
    var slug: String
    var serverURL: URL
    var authorization: Authorization
    var status: Status
    /// The server's tools as its `tools/list` gave them, kept so a new session lists them without
    /// waiting for the network.
    var tools: [ToolJSON]
    var toolsUpdatedAt: Date?
    /// The directory entry it was added from (`ConnectorPreset.id`), for its icon and help.
    var presetID: String?
    /// An OAuth client the user registered with the service, for a server without dynamic client
    /// registration (Slack, Google). Its secret, if any, is in the secure store with the token.
    var oauthClientID: String?
    /// The scope to ask for at sign-in instead of the one the server advertises.
    var scope: String?
    /// Further authorization request parameters (Google's `access_type=offline`).
    var authorizationParameters: [String: String]?
    /// The query parameter the access token goes in, for a server that takes its key in the
    /// address (Browserbase); nil sends it as a bearer token.
    var tokenQueryParameter: String?
    /// The server Yardlet runs itself for this connector instead of a remote MCP server (Gmail
    /// through Google's public REST API); nil for a remote server. Absent in files from before.
    var localService: LocalConnectorService?
    /// The account the connector is signed in to, once known (a Gmail address). Several
    /// connectors of one local service are told apart by it.
    var account: String?
    /// For a service signed in per account (Google's, Microsoft's): the secure-store item of the
    /// account's one sign-in, which that account's services share. Nil when it is this record's own
    /// ID: the first service of an account, and every Gmail account added before Calendar and Drive.
    /// Saved as `googleAccountID`, its name from when only Google accounts had one.
    var accountSignInID: UUID?
    /// The icons the server gave for itself when Yardlet last connected (`serverInfo.icons`), for
    /// its picture. Absent in files from before and for a server that gives none.
    var serverIcons: [MCPServerIcon]?
    /// The header a pasted key goes in, as is, for a server that takes it outside
    /// `Authorization: Bearer` (`x-api-key`, an MCP registry's entry). Absent in files from before.
    var tokenHeader: String?
    /// The program Yardlet runs on this Mac for the server (stdio), as the person confirmed it;
    /// nil for a server at an address. Absent in files from before.
    var program: ConnectorProgram?
    /// A mail account's IMAP and SMTP servers and user names (`LocalConnectorService.imapMail`); not
    /// secret, the password is in the secure store. Absent in files from before.
    var mailServer: MailServerSettings?

    init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        serverURL: URL,
        authorization: Authorization = .unknown,
        status: Status = .notConnected,
        tools: [ToolJSON] = [],
        toolsUpdatedAt: Date? = nil,
        presetID: String? = nil,
        oauthClientID: String? = nil,
        scope: String? = nil,
        authorizationParameters: [String: String]? = nil,
        tokenQueryParameter: String? = nil,
        localService: LocalConnectorService? = nil,
        account: String? = nil,
        accountSignInID: UUID? = nil,
        serverIcons: [MCPServerIcon]? = nil,
        tokenHeader: String? = nil,
        program: ConnectorProgram? = nil,
        mailServer: MailServerSettings? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.serverURL = serverURL
        self.authorization = authorization
        self.status = status
        self.tools = tools
        self.toolsUpdatedAt = toolsUpdatedAt
        self.presetID = presetID
        self.oauthClientID = oauthClientID
        self.scope = scope
        self.authorizationParameters = authorizationParameters
        self.tokenQueryParameter = tokenQueryParameter
        self.localService = localService
        self.account = account
        self.accountSignInID = accountSignInID
        self.serverIcons = serverIcons
        self.tokenHeader = tokenHeader
        self.program = program
        self.mailServer = mailServer
    }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, serverURL, authorization, status, tools, toolsUpdatedAt, presetID, oauthClientID, scope
        case authorizationParameters, tokenQueryParameter, localService, account, serverIcons, tokenHeader, program, mailServer
        case accountSignInID = "googleAccountID"
    }

    /// The secure-store item this connector's sign-in is under: its account's for a service signed
    /// in per account (Google's, Microsoft's), its own otherwise.
    var credentialID: UUID { accountSignInID ?? id }

    /// The directory entry. A local service's entry belongs only to a record of that service: a
    /// remote server once added under the same ID stays a plain remote server.
    var preset: ConnectorPreset? {
        guard let preset = presetID.flatMap(ConnectorPreset.preset(id:)) else { return nil }
        return (preset.localService != nil) == (localService != nil) ? preset : nil
    }

    /// A Google service, whose sign-in is its Google account's.
    var isGoogle: Bool { localService?.isGoogle == true }

    /// A service whose sign-in is its account's, shared with the account's other services:
    /// Google's and Microsoft's.
    var signsInPerAccount: Bool { localService?.accountProvider != nil }

    /// The tools it offers: a local service's own catalog, which comes with the app, or the
    /// server's list as it last gave it (a remote server's, or Xcode's).
    var offeredTools: [ToolJSON] { localService?.tools ?? tools }

    /// "Gmail · person@example.com" where an account tells several apart; the name alone otherwise.
    var displayName: String { account.map { "\(name) · \($0)" } ?? name }

    /// Signs in with a client the user registered rather than one Yardlet registers itself.
    var usesRegisteredClient: Bool { oauthClientID?.isEmpty == false }

    /// A directory service that needs the user's own OAuth client (Slack, Google) or a token
    /// (GitHub, Browserbase) and has neither yet. Connecting would otherwise reach a server that
    /// lists tools to anyone and only refuses calls.
    var needsSetupBeforeConnecting: Bool {
        guard let preset, !usesRegisteredClient, authorization != .token else { return false }
        return preset.needsRegisteredClient || preset.usesToken
    }
}

/// Who signs in the accounts of services Yardlet serves itself: one sign-in per account carries
/// the scopes of every service turned on for that account (docs/CONNECTORS.md, "Google" and
/// "Microsoft 365").
enum ConnectorAccountProvider: String, Sendable, CaseIterable {
    case google
    case microsoft

    var name: String {
        switch self {
        case .google: "Google"
        case .microsoft: "Microsoft"
        }
    }

    /// Its services, in the directory's order.
    var services: [LocalConnectorService] {
        switch self {
        case .google: LocalConnectorService.google
        case .microsoft: LocalConnectorService.microsoft
        }
    }
}

/// A service whose MCP server Yardlet runs itself, inside the app, instead of a remote MCP
/// server. Its tools reach harnesses through the Yardlet MCP server like any connector's
/// (docs/CONNECTORS.md, "Google", "Microsoft 365" and "Apple"):
/// - Google's three call Google's public APIs, signed in with the one Google OAuth app: one sign-in
///   per Google account carries the scopes of the services turned on for it.
/// - Microsoft's four (Outlook mail and calendar, OneDrive, Teams) call Microsoft Graph, signed in
///   the same way per Microsoft account with one Microsoft Entra app.
/// - App Store Connect calls Apple's REST API with tokens Yardlet signs with the person's API key.
/// - The Mac's calendars, reminders, and contacts are read and written through EventKit and
///   Contacts once macOS lets Yardlet.
/// - Xcode's own MCP server is reached through `mcpbridge`, which Yardlet runs; its tools are
///   Xcode's, as that server lists them.
enum LocalConnectorService: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Gmail through the Gmail REST API.
    case gmail
    /// Google Calendar through the Calendar API v3.
    case googleCalendar = "google-calendar"
    /// Google Drive through the Drive API v3.
    case googleDrive = "google-drive"
    /// Google Analytics 4 through the Analytics Admin and Data APIs, read only.
    case googleAnalytics = "google-analytics"
    /// Google Ads through the Google Ads API, read only.
    case googleAds = "google-ads"
    /// Outlook mail through Microsoft Graph.
    case outlookMail = "outlook-mail"
    /// Outlook calendars through Microsoft Graph.
    case outlookCalendar = "outlook-calendar"
    /// OneDrive through Microsoft Graph.
    case oneDrive = "onedrive"
    /// Microsoft Teams chats and channels through Microsoft Graph.
    case teams = "microsoft-teams"
    /// App Store Connect through the App Store Connect API.
    case appStoreConnect = "app-store-connect"
    /// The Mac's calendars through EventKit.
    case appleCalendar = "apple-calendar"
    /// The Mac's reminders through EventKit.
    case appleReminders = "apple-reminders"
    /// The Mac's contacts through the Contacts framework.
    case appleContacts = "apple-contacts"
    /// Xcode's MCP server through `xcrun mcpbridge` (Xcode 26.3 and later).
    case xcode
    /// A mail account without an API (iCloud, Naver, Daum, Kakao and others) through IMAP and SMTP,
    /// signed in with the account's app password.
    case imapMail = "imap-mail"

    /// Google's, signed in per Google account with one Google OAuth app.
    static let google: [LocalConnectorService] = [.gmail, .googleCalendar, .googleDrive, .googleAnalytics, .googleAds]
    /// What a new Google account signs in with unless the person picks otherwise: Analytics and
    /// Ads ask for more, so each is turned on only when wanted.
    static let googleDefaults: [LocalConnectorService] = [.gmail, .googleCalendar, .googleDrive]
    /// Microsoft's, signed in per Microsoft account with one Microsoft Entra app.
    static let microsoft: [LocalConnectorService] = [.outlookMail, .outlookCalendar, .oneDrive, .teams]
    /// The Mac's own data, which macOS lets Yardlet reach once the person allows it.
    static let mac: [LocalConnectorService] = [.appleCalendar, .appleReminders, .appleContacts]

    var isGoogle: Bool { Self.google.contains(self) }
    var isMicrosoft: Bool { Self.microsoft.contains(self) }

    /// Who signs its accounts in, for a service signed in per account; nil for the rest.
    var accountProvider: ConnectorAccountProvider? {
        if isGoogle { return .google }
        if isMicrosoft { return .microsoft }
        return nil
    }
    var isMac: Bool { Self.mac.contains(self) }

    var id: String { rawValue }

    /// The directory entry (`ConnectorPreset.id`), which is the raw value.
    var presetID: String { rawValue }

    var name: String {
        switch self {
        case .gmail: "Gmail"
        case .googleCalendar: "Google Calendar"
        case .googleDrive: "Google Drive"
        case .googleAnalytics: "Google Analytics"
        case .googleAds: "Google Ads"
        case .outlookMail: "Outlook Mail"
        case .outlookCalendar: "Outlook Calendar"
        case .oneDrive: "OneDrive"
        case .teams: "Microsoft Teams"
        case .appStoreConnect: "App Store Connect"
        case .appleCalendar: "Apple Calendar"
        case .appleReminders: "Apple Reminders"
        case .appleContacts: "Apple Contacts"
        case .xcode: "Xcode"
        case .imapMail: "Mail (IMAP)"
        }
    }

    /// The first account's tool prefix (`calendar_list_events`); a later account's adds its address.
    var slugBase: String {
        switch self {
        case .gmail: "gmail"
        case .googleCalendar: "calendar"
        case .googleDrive: "drive"
        case .googleAnalytics: "analytics"
        case .googleAds: "google_ads"
        case .outlookMail: "outlook"
        case .outlookCalendar: "outlook_calendar"
        case .oneDrive: "onedrive"
        case .teams: "teams"
        case .appStoreConnect: "app_store_connect"
        case .appleCalendar: "apple_calendar"
        case .appleReminders: "apple_reminders"
        case .appleContacts: "apple_contacts"
        case .xcode: "xcode"
        case .imapMail: "mail"
        }
    }

    /// Where its requests go, or what it reads: the API's base, or the Mac app whose data it is.
    /// Google's come from `GoogleOAuth.Endpoints` and Microsoft's from `MicrosoftOAuth.Endpoints`,
    /// which tests replace.
    var address: URL {
        switch self {
        case .gmail: GoogleOAuth.Endpoints.live.gmailAPI
        case .googleCalendar: GoogleOAuth.Endpoints.live.calendarAPI
        case .googleDrive: GoogleOAuth.Endpoints.live.driveAPI
        case .googleAnalytics: GoogleOAuth.Endpoints.live.analyticsAdminAPI
        case .googleAds: GoogleOAuth.Endpoints.live.adsAPI
        case .outlookMail, .outlookCalendar, .oneDrive, .teams: MicrosoftOAuth.Endpoints.live.address(for: self)
        case .appStoreConnect: AppStoreConnectAPI.liveBase
        case .appleCalendar: URL(filePath: "/System/Applications/Calendar.app", directoryHint: .isDirectory)
        case .appleReminders: URL(filePath: "/System/Applications/Reminders.app", directoryHint: .isDirectory)
        case .appleContacts: URL(filePath: "/System/Applications/Contacts.app", directoryHint: .isDirectory)
        case .xcode: XcodeBridge.defaultExecutable
        // Each account's own server is its record's address.
        case .imapMail: URL(string: "imaps://localhost")!
        }
    }

    /// The scopes its tools need, all asked for in the account's one sign-in: Google's, or
    /// Microsoft Graph's permissions; none for a service not signed in per account.
    var scopes: [String] {
        switch self {
        case .gmail: [GmailToolCatalog.scope]
        case .googleCalendar: GoogleCalendarToolCatalog.scopes
        case .googleDrive: GoogleDriveToolCatalog.scopes
        case .googleAnalytics: GoogleAnalyticsToolCatalog.scopes
        case .googleAds: GoogleAdsToolCatalog.scopes
        case .outlookMail: OutlookMailToolCatalog.scopes
        case .outlookCalendar: OutlookCalendarToolCatalog.scopes
        case .oneDrive: OneDriveToolCatalog.scopes
        case .teams: TeamsToolCatalog.scopes
        default: []
        }
    }

    /// The tools that come with the app; nil for Xcode, whose tools are those its server lists.
    var tools: [ToolJSON]? {
        switch self {
        case .gmail: GmailToolCatalog.tools
        case .googleCalendar: GoogleCalendarToolCatalog.tools
        case .googleDrive: GoogleDriveToolCatalog.tools
        case .googleAnalytics: GoogleAnalyticsToolCatalog.tools
        case .googleAds: GoogleAdsToolCatalog.tools
        case .outlookMail: OutlookMailToolCatalog.tools
        case .outlookCalendar: OutlookCalendarToolCatalog.tools
        case .oneDrive: OneDriveToolCatalog.tools
        case .teams: TeamsToolCatalog.tools
        case .appStoreConnect: AppStoreConnectToolCatalog.tools
        case .appleCalendar: MacCalendarToolCatalog.tools
        case .appleReminders: MacRemindersToolCatalog.tools
        case .appleContacts: MacContactsToolCatalog.tools
        case .xcode: nil
        case .imapMail: MailAccountToolCatalog.tools
        }
    }

    /// Tools each harness asks the person about before every call: sending, deleting drafts, and
    /// changing labels, writing events, creating and changing files, sending Teams messages, inviting
    /// testers, sending builds and review replies, submitting for review, and changing the Mac's
    /// calendars and reminders. Xcode's tools are asked about as the harness asks about any server's.
    var approvalRequiredTools: Set<String> {
        switch self {
        case .gmail: GmailToolCatalog.approvalRequired
        case .googleCalendar: GoogleCalendarToolCatalog.approvalRequired
        case .googleDrive: GoogleDriveToolCatalog.approvalRequired
        case .outlookMail: OutlookMailToolCatalog.approvalRequired
        case .outlookCalendar: OutlookCalendarToolCatalog.approvalRequired
        case .oneDrive: OneDriveToolCatalog.approvalRequired
        case .teams: TeamsToolCatalog.approvalRequired
        case .appStoreConnect: AppStoreConnectToolCatalog.approvalRequired
        case .imapMail: MailAccountToolCatalog.approvalRequired
        case .appleCalendar: MacCalendarToolCatalog.approvalRequired
        case .appleReminders: MacRemindersToolCatalog.approvalRequired
        case .googleAnalytics, .googleAds, .appleContacts, .xcode: []
        }
    }

    /// The Google APIs that must be turned on in the Cloud project of the Google app.
    var apiIDs: [String] {
        switch self {
        case .gmail: ["gmail.googleapis.com"]
        case .googleCalendar: ["calendar-json.googleapis.com"]
        case .googleDrive: ["drive.googleapis.com"]
        case .googleAnalytics: ["analyticsadmin.googleapis.com", "analyticsdata.googleapis.com"]
        case .googleAds: ["googleads.googleapis.com"]
        default: []
        }
    }

    init?(presetID: String) {
        self.init(rawValue: presetID)
    }
}

/// What Yardlet keeps in the secure store for one connector.
struct ConnectorCredential: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case oauth
        case token
        /// Only the OAuth client the user registered (`ConnectorRecord.oauthClientID`), kept for the
        /// next sign-in; no token yet.
        case client
        /// A private key that signs each token Yardlet sends (an App Store Connect API key).
        case signingKey
        /// The arguments and environment a program on this Mac starts with (`ConnectorProgram`).
        case program
        /// A mail account's password, in `accessToken` (`ConnectorCredential.password`).
        case password
    }

    var kind: Kind
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scope: String?
    /// The OAuth client Yardlet registered with the authorization server, needed to refresh.
    var clientID: String?
    var clientSecret: String?
    var tokenEndpoint: URL?
    /// `none`, `client_secret_post`, or `client_secret_basic`.
    var tokenEndpointAuthMethod: String?
    /// RFC 8707 resource indicator sent with every token request.
    var resource: String?
    /// The scope a refresh names again, for an identity provider that issues a refreshed token for
    /// what the refresh asks (Microsoft's); nil leaves it out, as most servers expect.
    var refreshScope: String?
    /// A signing key's ID, its issuer (a team key's; nil for an individual key), and the private
    /// key itself in PEM. Absent in items from before.
    var keyID: String?
    var issuerID: String?
    var privateKey: String?
    /// A program's arguments and environment values. Absent in items from before.
    var program: ConnectorProgramSpec?

    /// A mail account's password (an app password, as the services ask for), signed in with the user
    /// names its record's `mailServer` keeps.
    static func password(_ value: String) -> ConnectorCredential {
        ConnectorCredential(kind: .password, accessToken: value)
    }

    static func token(_ value: String) -> ConnectorCredential {
        ConnectorCredential(kind: .token, accessToken: value)
    }

    static func client(id: String, secret: String?) -> ConnectorCredential {
        ConnectorCredential(kind: .client, accessToken: "", clientID: id, clientSecret: secret)
    }

    static func signingKey(id: String, issuer: String?, privateKey: String) -> ConnectorCredential {
        ConnectorCredential(kind: .signingKey, accessToken: "", keyID: id, issuerID: issuer, privateKey: privateKey)
    }

    static func program(_ spec: ConnectorProgramSpec) -> ConnectorCredential {
        ConnectorCredential(kind: .program, accessToken: "", program: spec)
    }

    /// What goes to the server: nothing for a client kept before its first sign-in, for a
    /// signing key, whose tokens are made per request, or for a program's start.
    var presentedToken: String? {
        kind == .client || kind == .signingKey || kind == .program || accessToken.isEmpty ? nil : accessToken
    }

    /// The registered client alone, as a disconnect keeps it for the next sign-in.
    var clientOnly: ConnectorCredential? {
        guard let clientID, !clientID.isEmpty else { return nil }
        return .client(id: clientID, secret: clientSecret)
    }

    /// What a disconnect keeps for the next connection: the registered client, or a program's
    /// start as the person confirmed it.
    var keptAfterDisconnect: ConnectorCredential? {
        kind == .program ? self : clientOnly
    }

    /// True when the access token is past, or within a minute of, its expiry.
    func needsRefresh(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < 60
    }
}

/// The connector's secret, in the platform's secure store (the Keychain on macOS).
protocol ConnectorCredentialStoring: Sendable {
    func load(_ id: UUID) throws -> ConnectorCredential?
    func save(_ credential: ConnectorCredential, for id: UUID) throws
    func delete(_ id: UUID) throws
}

final class InMemoryConnectorCredentialStore: ConnectorCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [UUID: ConnectorCredential] = [:]

    init(_ credentials: [UUID: ConnectorCredential] = [:]) {
        self.credentials = credentials
    }

    func load(_ id: UUID) throws -> ConnectorCredential? {
        lock.withLock { credentials[id] }
    }

    func save(_ credential: ConnectorCredential, for id: UUID) throws {
        lock.withLock { credentials[id] = credential }
    }

    func delete(_ id: UUID) throws {
        _ = lock.withLock { credentials.removeValue(forKey: id) }
    }
}

/// Names under which a connector's tools reach a harness. Claude Code and Codex call a tool
/// `mcp__yardlet__<name>` and the model APIs allow 64 characters of `[A-Za-z0-9_-]`, so a name
/// is the connector's slug, an underscore, and the server's tool name, cleaned and kept to 50.
enum ConnectorToolNaming {
    static let maximumLength = 50
    static let maximumSlugLength = 20

    /// A lowercase ASCII prefix from the connector's name. `browser` is the browser tools'.
    static func slug(for name: String, taken: Set<String>) -> String {
        var base = String(name.lowercased().unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : "_"
        })
        base = base.split(separator: "_").joined(separator: "_")
        if base.count > maximumSlugLength { base = String(base.prefix(maximumSlugLength)) }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if base.isEmpty { base = "connector" }
        let reserved = String(AgentToolCatalog.browserToolPrefix.dropLast())
        var candidate = base
        var suffix = 2
        while candidate == reserved || taken.contains(candidate) {
            candidate = "\(base)\(suffix)"
            suffix += 1
        }
        return candidate
    }

    static func name(slug: String, tool: String) -> String {
        let cleaned = String(tool.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
                ? Character(scalar) : "_"
        })
        let full = "\(slug)_\(cleaned)"
        guard full.count > maximumLength else { return full }
        // Keep names distinct when two long names share a beginning.
        let hash = String(format: "%08x", fnv1a(tool))
        return "\(full.prefix(maximumLength - hash.count - 1))_\(hash)"
    }

    /// FNV-1a: stable across runs and platforms, unlike `Hasher`.
    private static func fnv1a(_ text: String) -> UInt32 {
        text.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }
}
