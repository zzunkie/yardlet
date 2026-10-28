import Foundation
import YardletAgentTools

/// A service Yardlet knows how to connect, checked against the service's live endpoint with
/// unauthenticated requests only (docs/CONNECTORS.md, "Directory"). How it signs in decides what
/// the user is asked for: nothing (dynamic client registration or no sign-in), an OAuth client
/// they register with the service, or a token they paste.
struct ConnectorPreset: Identifiable, Equatable, Sendable {
    enum SignIn: Equatable, Sendable {
        /// OAuth with dynamic client registration: the browser opens and that is all.
        case oauth
        /// OAuth with a client the user registers with the service, which has no dynamic
        /// registration (Slack, Google).
        case registeredClient
        /// An access token or API key the user pastes.
        case token
        /// The server answers without credentials.
        case none
        /// Yardlet's own server for the service (`LocalConnectorService`), signed in to each
        /// Google account with the Google OAuth app the person registered once (Gmail).
        case googleAccount
        /// Yardlet's own server on Microsoft Graph (Outlook, OneDrive, Teams), signed in to each
        /// Microsoft account with one Microsoft Entra app.
        case microsoftAccount
        /// Yardlet's own App Store Connect server, with an API key the person adds: the private
        /// key file App Store Connect gave them once, its key ID, and a team key's issuer ID.
        case appStoreConnectKey
        /// Yardlet's own server for the Mac's calendars, reminders, or contacts: macOS asks the
        /// person once, when they turn it on.
        case macPermission
        /// An app on this Mac serves the tools (Xcode, through `mcpbridge`); nothing to sign in to.
        case localApp
    }

    var id: String
    var name: String
    var serverURL: URL
    var signIn: SignIn
    /// GitHub takes a token by default and an OAuth app of the user's own too.
    var acceptsRegisteredClient = false
    var tokenQueryParameter: String?
    var scope: String?
    var authorizationParameters: [String: String] = [:]
    /// An SF Symbol standing for the service; not its logo.
    var symbol: String
    /// Where the user registers the client or creates the token.
    var setupURL: URL?
    /// What the user needs, in a sentence (a catalog key).
    var note: String?
    /// The names other harnesses give this service: claude.ai connectors ("claude.ai Linear"),
    /// Codex plugins by the part before `@`, stdio packages.
    var claudeAINames: [String] = []
    var codexPlugins: [String] = []
    var packages: [String] = []

    var usesToken: Bool { signIn == .token }
    var needsRegisteredClient: Bool { signIn == .registeredClient }
    /// One of Zoom's product servers, which share one Zoom app of the person's own.
    var isZoom: Bool { id.hasPrefix("zoom-") }

    static func preset(id: String) -> ConnectorPreset? { all.first { $0.id == id } }

    /// The preset for a server address, by canonical address and then by host.
    static func preset(for url: URL) -> ConnectorPreset? {
        let canonical = MCPServerAddress.canonical(url)
        if let exact = all.first(where: { MCPServerAddress.canonical($0.serverURL) == canonical }) { return exact }
        let host = url.host()?.lowercased()
        return all.first { $0.serverURL.host()?.lowercased() == host && host != "127.0.0.1" }
    }

    private static let googleOffline = ["access_type": "offline", "prompt": "consent"]
    private static let googleSetup = URL(string: "https://console.cloud.google.com/auth/clients")!

    /// The service Yardlet serves itself: Google's, App Store Connect, the Mac's data, or Xcode.
    var localService: LocalConnectorService? {
        switch signIn {
        case .googleAccount, .microsoftAccount, .appStoreConnectKey, .macPermission, .localApp: LocalConnectorService(presetID: id)
        case .oauth, .registeredClient, .token, .none: nil
        }
    }

    /// Whether a name another app gives a service stands for this one: the directory's name, a
    /// claude.ai connector's name without its prefix, or a Codex plugin's, in any case.
    func isNamed(_ name: String) -> Bool {
        let wanted = name.lowercased().trimmingCharacters(in: .whitespaces)
        let prefix = ClaudeNativeMCPConfig.claudeAIPrefix.lowercased()
        return wanted == self.name.lowercased()
            || claudeAINames.contains { $0.lowercased() == wanted || $0.lowercased().replacingOccurrences(of: prefix, with: "") == wanted }
            || codexPlugins.contains(wanted)
    }

    static let all: [ConnectorPreset] = [
        ConnectorPreset(id: "linear", name: "Linear", serverURL: URL(string: "https://mcp.linear.app/mcp")!,
                        signIn: .oauth, symbol: "checklist",
                        claudeAINames: ["claude.ai Linear"], codexPlugins: ["linear"]),
        ConnectorPreset(id: "notion", name: "Notion", serverURL: URL(string: "https://mcp.notion.com/mcp")!,
                        signIn: .oauth, symbol: "doc.text",
                        claudeAINames: ["claude.ai Notion"], codexPlugins: ["notion"]),
        // The Slack app the setup assistant creates from Yardlet's manifest (`SlackAppManifest`).
        ConnectorPreset(id: "slack", name: "Slack", serverURL: URL(string: "https://mcp.slack.com/mcp")!,
                        signIn: .registeredClient, symbol: "number",
                        setupURL: URL(string: "https://api.slack.com/apps")!,
                        note: "Needs a Slack app of your own, made from Yardlet's manifest in a few clicks. Enter its client ID.",
                        claudeAINames: ["claude.ai Slack"], codexPlugins: ["slack"]),
        // Yardlet's own Google servers on the public Gmail, Calendar, and Drive APIs (2026-10-17,
        // 2026-10-19), all signed in with one Google OAuth app: Google's own MCP servers for them
        // need the Workspace developer preview, which personal accounts cannot join.
        ConnectorPreset(id: "gmail", name: "Gmail", serverURL: GoogleOAuth.Endpoints.live.gmailAPI,
                        signIn: .googleAccount, scope: GmailToolCatalog.scope,
                        authorizationParameters: googleOffline, symbol: "envelope", setupURL: googleSetup,
                        note: "Yardlet's own Gmail server. Each Google account signs in once.",
                        claudeAINames: ["claude.ai Gmail"], codexPlugins: ["gmail"]),
        ConnectorPreset(id: "google-calendar", name: "Google Calendar",
                        serverURL: GoogleOAuth.Endpoints.live.calendarAPI, signIn: .googleAccount,
                        scope: GoogleCalendarToolCatalog.scopes.joined(separator: " "),
                        authorizationParameters: googleOffline, symbol: "calendar", setupURL: googleSetup,
                        note: "Yardlet's own Google Calendar server, with the same Google OAuth app as Gmail.",
                        claudeAINames: ["claude.ai Google Calendar"], codexPlugins: ["google-calendar", "google_calendar"]),
        ConnectorPreset(id: "google-drive", name: "Google Drive",
                        serverURL: GoogleOAuth.Endpoints.live.driveAPI, signIn: .googleAccount,
                        scope: GoogleDriveToolCatalog.scopes.joined(separator: " "),
                        authorizationParameters: googleOffline, symbol: "externaldrive", setupURL: googleSetup,
                        note: "Yardlet's own Google Drive server, with the same Google OAuth app as Gmail.",
                        claudeAINames: ["claude.ai Google Drive"], codexPlugins: ["google-drive", "google_drive"]),
        // Google Analytics 4 and Google Ads on the same Google sign-in (2026-10-27), read only: each
        // account turns them on by itself, so their scopes are asked for only then.
        ConnectorPreset(id: "google-analytics", name: "Google Analytics",
                        serverURL: GoogleOAuth.Endpoints.live.analyticsAdminAPI, signIn: .googleAccount,
                        scope: GoogleAnalyticsToolCatalog.scopes.joined(separator: " "),
                        authorizationParameters: googleOffline, symbol: "chart.line.uptrend.xyaxis", setupURL: googleSetup,
                        note: "Yardlet's own Google Analytics 4 server, read only, with the same Google OAuth app as Gmail."),
        ConnectorPreset(id: "google-ads", name: "Google Ads",
                        serverURL: GoogleOAuth.Endpoints.live.adsAPI, signIn: .googleAccount,
                        scope: GoogleAdsToolCatalog.scopes.joined(separator: " "),
                        authorizationParameters: googleOffline, symbol: "megaphone", setupURL: googleSetup,
                        note: "Yardlet's own Google Ads server, read only, with the same Google OAuth app as Gmail."),
        // Yardlet's own servers on Microsoft Graph (2026-10-27), all signed in with one Microsoft Entra
        // app: Microsoft's own MCP servers (Work IQ) follow each tenant's Copilot licensing and policy.
        ConnectorPreset(id: "outlook-mail", name: "Outlook Mail", serverURL: LocalConnectorService.outlookMail.address,
                        signIn: .microsoftAccount, symbol: "envelope.badge",
                        note: "Yardlet's own Outlook mail server on Microsoft Graph. Each Microsoft account signs in once."),
        ConnectorPreset(id: "outlook-calendar", name: "Outlook Calendar", serverURL: LocalConnectorService.outlookCalendar.address,
                        signIn: .microsoftAccount, symbol: "calendar.badge.clock",
                        note: "Yardlet's own Outlook calendar server, with the same Microsoft app as Outlook Mail."),
        ConnectorPreset(id: "onedrive", name: "OneDrive", serverURL: LocalConnectorService.oneDrive.address,
                        signIn: .microsoftAccount, symbol: "cloud",
                        note: "Yardlet's own OneDrive server, with the same Microsoft app as Outlook Mail."),
        ConnectorPreset(id: "microsoft-teams", name: "Microsoft Teams", serverURL: LocalConnectorService.teams.address,
                        signIn: .microsoftAccount, symbol: "person.3",
                        note: "Yardlet's own Teams server, for work or school accounts, with the same Microsoft app as Outlook Mail."),
        // The Mac's own calendars, reminders, and contacts (2026-10-26): iCloud has no OAuth API, so
        // Yardlet reads what the Mac keeps in sync, through EventKit and Contacts, once macOS lets it.
        ConnectorPreset(id: "apple-calendar", name: "Apple Calendar", serverURL: LocalConnectorService.appleCalendar.address,
                        signIn: .macPermission, symbol: "calendar",
                        note: "The calendars on this Mac, iCloud's and the other accounts' in Calendar. macOS asks once."),
        ConnectorPreset(id: "apple-reminders", name: "Apple Reminders", serverURL: LocalConnectorService.appleReminders.address,
                        signIn: .macPermission, symbol: "checklist",
                        note: "The reminders on this Mac. macOS asks once."),
        ConnectorPreset(id: "apple-contacts", name: "Apple Contacts", serverURL: LocalConnectorService.appleContacts.address,
                        signIn: .macPermission, symbol: "person.crop.circle",
                        note: "The contacts on this Mac, read only. macOS asks once."),
        ConnectorPreset(id: "github", name: "GitHub", serverURL: URL(string: "https://api.githubcopilot.com/mcp/")!,
                        signIn: .token, acceptsRegisteredClient: true, symbol: "chevron.left.forwardslash.chevron.right",
                        setupURL: URL(string: "https://github.com/settings/personal-access-tokens/new")!,
                        note: "Paste a personal access token, or use an OAuth app of your own.",
                        claudeAINames: ["claude.ai GitHub"], codexPlugins: ["github"]),
        ConnectorPreset(id: "browserbase", name: "Browserbase", serverURL: URL(string: "https://mcp.browserbase.com/mcp")!,
                        signIn: .token, tokenQueryParameter: "browserbaseApiKey", symbol: "globe",
                        setupURL: URL(string: "https://www.browserbase.com/settings")!,
                        note: "Paste your Browserbase API key. Browserbase takes it in the server address; it stays in your keychain.",
                        packages: ["@browserbasehq/mcp", "@browserbasehq/mcp-server-browserbase", "@browserbasehq/mcp-browserbase"]),
        ConnectorPreset(id: "atlassian", name: "Atlassian", serverURL: URL(string: "https://mcp.atlassian.com/v1/mcp")!,
                        signIn: .oauth, symbol: "square.stack.3d.up",
                        claudeAINames: ["claude.ai Atlassian"], codexPlugins: ["atlassian"]),
        ConnectorPreset(id: "sentry", name: "Sentry", serverURL: URL(string: "https://mcp.sentry.dev/mcp")!,
                        signIn: .oauth, symbol: "ladybug",
                        claudeAINames: ["claude.ai Sentry"], codexPlugins: ["sentry"]),
        // The services' own remote servers, each answering an unauthenticated `initialize` with 401
        // and OAuth metadata that has a registration endpoint (2026-10-21, docs/CONNECTORS.md, "Directory").
        // Left out: Vercel and Canva admit only clients they approved; Box, HubSpot, and Asana's
        // V2 server have no registration (an app of the person's own).
        // Work and planning
        ConnectorPreset(id: "asana", name: "Asana", serverURL: URL(string: "https://mcp.asana.com/mcp")!,
                        signIn: .oauth, symbol: "checkmark.circle"),
        ConnectorPreset(id: "clickup", name: "ClickUp", serverURL: URL(string: "https://mcp.clickup.com/mcp")!,
                        signIn: .oauth, symbol: "checklist.checked"),
        ConnectorPreset(id: "monday", name: "monday.com", serverURL: URL(string: "https://mcp.monday.com/mcp")!,
                        signIn: .oauth, symbol: "calendar.day.timeline.left", claudeAINames: ["claude.ai monday.com", "claude.ai Monday"]),
        ConnectorPreset(id: "todoist", name: "Todoist", serverURL: URL(string: "https://ai.todoist.net/mcp")!,
                        signIn: .oauth, symbol: "checkmark.square"),
        ConnectorPreset(id: "airtable", name: "Airtable", serverURL: URL(string: "https://mcp.airtable.com/mcp")!,
                        signIn: .oauth, symbol: "tablecells"),
        ConnectorPreset(id: "miro", name: "Miro", serverURL: URL(string: "https://mcp.miro.com/")!,
                        signIn: .oauth, symbol: "rectangle.on.rectangle.angled"),
        ConnectorPreset(id: "dropbox", name: "Dropbox", serverURL: URL(string: "https://mcp.dropbox.com/mcp")!,
                        signIn: .oauth, symbol: "shippingbox"),
        ConnectorPreset(id: "intercom", name: "Intercom", serverURL: URL(string: "https://mcp.intercom.com/mcp")!,
                        signIn: .oauth, symbol: "bubble.left.and.bubble.right"),
        ConnectorPreset(id: "zapier", name: "Zapier", serverURL: URL(string: "https://mcp.zapier.com/api/mcp/mcp")!,
                        signIn: .oauth, symbol: "bolt"),
        // Services that reach many apps through one sign-in, like Zapier: each runs its own server,
        // answers an unauthenticated GET with 401 and OAuth metadata with a registration endpoint
        // (checked 2026-10-27, docs/CONNECTORS.md, "Directory"). Pipedream keeps its resource
        // metadata only at the root; Make takes `client_secret_post` alone.
        ConnectorPreset(id: "pipedream", name: "Pipedream", serverURL: URL(string: "https://mcp.pipedream.net/v2")!,
                        signIn: .oauth, symbol: "point.3.connected.trianglepath.dotted"),
        ConnectorPreset(id: "composio", name: "Composio", serverURL: URL(string: "https://connect.composio.dev/mcp")!,
                        signIn: .oauth, symbol: "square.grid.3x3"),
        ConnectorPreset(id: "make", name: "Make", serverURL: URL(string: "https://mcp.make.com/v2")!,
                        signIn: .oauth, symbol: "arrow.triangle.2.circlepath"),
        ConnectorPreset(id: "granola", name: "Granola", serverURL: URL(string: "https://mcp.granola.ai/mcp")!,
                        signIn: .oauth, symbol: "note.text"),
        ConnectorPreset(id: "fireflies", name: "Fireflies", serverURL: URL(string: "https://api.fireflies.ai/mcp")!,
                        signIn: .oauth, symbol: "mic"),
        ConnectorPreset(id: "gamma", name: "Gamma", serverURL: URL(string: "https://mcp.gamma.app/mcp")!,
                        signIn: .oauth, symbol: "rectangle.stack"),
        // Services checked on 2026-10-29 the same way, here and at the end of the groups below: 401
        // without a token, protected resource and authorization server metadata, a registration
        // endpoint, and PKCE `S256` (docs/CONNECTORS.md, "Directory"). Each asks for the scopes its
        // server lists, except Ramp, Apollo.io, and Brex, whose lists reach payments, purchases, or sending.
        ConnectorPreset(id: "basecamp", name: "Basecamp", serverURL: URL(string: "https://mcp.basecamp.com/mcp")!,
                        signIn: .oauth, symbol: "mountain.2"),
        ConnectorPreset(id: "teamwork", name: "Teamwork", serverURL: URL(string: "https://mcp.ai.teamwork.com")!,
                        signIn: .oauth, symbol: "list.bullet.clipboard"),
        ConnectorPreset(id: "lucid", name: "Lucid", serverURL: URL(string: "https://mcp.lucid.app/mcp")!,
                        signIn: .oauth, symbol: "flowchart"),
        ConnectorPreset(id: "pandadoc", name: "PandaDoc", serverURL: URL(string: "https://mcp.pandadoc.com/v1/mcp")!,
                        signIn: .oauth, symbol: "signature"),
        ConnectorPreset(id: "fathom", name: "Fathom", serverURL: URL(string: "https://api.fathom.ai/mcp")!,
                        signIn: .oauth, symbol: "waveform"),
        ConnectorPreset(id: "deepl", name: "DeepL", serverURL: URL(string: "https://mcp.deepl.com/v1/mcp")!,
                        signIn: .oauth, symbol: "translate"),
        ConnectorPreset(id: "mobbin", name: "Mobbin", serverURL: URL(string: "https://api.mobbin.com/mcp")!,
                        signIn: .oauth, symbol: "iphone"),
        // Zoom's own servers, one per product (developers.zoom.us/docs/mcp/servers, 2026-10-27): no
        // dynamic registration, so a Zoom app of the person's own (General app, PKCE, its secret in
        // Basic). Each asks only for the read scopes of its server's metadata (`scopes_supported`).
        ConnectorPreset(id: "zoom-meetings", name: "Zoom Meetings", serverURL: URL(string: "https://mcp.zoom.us/mcp/meeting/streamable")!,
                        signIn: .registeredClient,
                        scope: "meeting:read:search meeting:read:assets cloud_recording:read:list_user_recordings cloud_recording:read:content",
                        symbol: "video", setupURL: URL(string: "https://marketplace.zoom.us/develop/create")!,
                        note: "Needs a Zoom app of your own. Yardlet asks only to read meetings, their summaries, and recordings."),
        ConnectorPreset(id: "zoom-team-chat", name: "Zoom Team Chat", serverURL: URL(string: "https://mcp.zoom.us/mcp/chat/streamable")!,
                        signIn: .registeredClient,
                        scope: "team_chat:read:list_user_messages team_chat:read:list_user_sessions team_chat:read:channel "
                            + "team_chat:read:list_contacts team_chat:read:list_user_channels team_chat:read:list_members "
                            + "team_chat:read:list_user_files chat_channel:read",
                        symbol: "bubble.left.and.text.bubble.right", setupURL: URL(string: "https://marketplace.zoom.us/develop/create")!,
                        note: "Needs a Zoom app of your own. Yardlet asks only to read chats and channels."),
        // Zoom names its file search scope `canvas:write:file_search`; it searches, it does not write.
        ConnectorPreset(id: "zoom-docs", name: "Zoom Docs", serverURL: URL(string: "https://mcp.zoom.us/mcp/canvas/streamable")!,
                        signIn: .registeredClient,
                        scope: "docs:read:file docs:read:list_children docs:read:export docs:read:list_file_collaborators "
                            + "docs:read:general_access canvas:read:data_table canvas:read:comment canvas:write:file_search",
                        symbol: "doc.richtext", setupURL: URL(string: "https://marketplace.zoom.us/develop/create")!,
                        note: "Needs a Zoom app of your own. Yardlet asks only to read and search docs."),
        // Sales, marketing, and product analytics
        // Apollo.io lists sending, sequence, and purchase scopes too; Yardlet asks only for the
        // profile, contact search, and person and company lookups.
        ConnectorPreset(id: "apollo-io", name: "Apollo.io", serverURL: URL(string: "https://mcp.apollo.io/mcp")!,
                        signIn: .oauth, scope: "read_user_profile app_scopes people_match organizations_enrich contacts_search",
                        symbol: "person.crop.rectangle.stack"),
        ConnectorPreset(id: "attio", name: "Attio", serverURL: URL(string: "https://mcp.attio.com/mcp")!,
                        signIn: .oauth, symbol: "person.2.crop.square.stack"),
        // Customer.io's sign-in page lets the person grant each scope; sending (`write:live`) also
        // needs an account admin's switch (docs.customer.io/ai/mcp/get-started).
        ConnectorPreset(id: "customer-io", name: "Customer.io", serverURL: URL(string: "https://mcp.customer.io/mcp")!,
                        signIn: .oauth, symbol: "envelope.open"),
        ConnectorPreset(id: "klaviyo", name: "Klaviyo", serverURL: URL(string: "https://mcp.klaviyo.com/mcp")!,
                        signIn: .oauth, symbol: "mail.stack"),
        ConnectorPreset(id: "mailerlite", name: "MailerLite", serverURL: URL(string: "https://mcp.mailerlite.com/mcp")!,
                        signIn: .oauth, symbol: "newspaper"),
        ConnectorPreset(id: "ahrefs", name: "Ahrefs", serverURL: URL(string: "https://api.ahrefs.com/mcp/mcp")!,
                        signIn: .oauth, symbol: "link"),
        ConnectorPreset(id: "semrush", name: "Semrush", serverURL: URL(string: "https://mcp.semrush.com/v2/mcp")!,
                        signIn: .oauth, symbol: "chart.bar.doc.horizontal"),
        ConnectorPreset(id: "similarweb", name: "Similarweb", serverURL: URL(string: "https://mcp.similarweb.com")!,
                        signIn: .oauth, symbol: "chart.xyaxis.line"),
        // Amplitude, Mixpanel, and Port have a server per region; these are the default ones, and
        // another region's is added by its address.
        ConnectorPreset(id: "amplitude", name: "Amplitude", serverURL: URL(string: "https://mcp.amplitude.com/mcp")!,
                        signIn: .oauth, symbol: "waveform.path.ecg"),
        ConnectorPreset(id: "mixpanel", name: "Mixpanel", serverURL: URL(string: "https://mcp.mixpanel.com/mcp")!,
                        signIn: .oauth, symbol: "chart.pie"),
        // Building and running software
        // Xcode's own MCP server (Xcode 26.3 and later), which `mcpbridge` reaches; offered only on
        // a Mac with Xcode (`XcodeBridge.locate`).
        ConnectorPreset(id: "xcode", name: "Xcode", serverURL: LocalConnectorService.xcode.address,
                        signIn: .localApp, symbol: "hammer",
                        note: "Xcode's own tools, while Xcode is open with a project and its Intelligence settings let other agents use them.",
                        packages: ["mcpbridge"]),
        // Apple's App Store Connect API with the person's own API key; no third-party server holds it.
        ConnectorPreset(id: "app-store-connect", name: "App Store Connect", serverURL: AppStoreConnectAPI.liveBase,
                        signIn: .appStoreConnectKey, symbol: "app.badge",
                        setupURL: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!,
                        note: "An App Store Connect API key: its .p8 file, key ID, and, for a team key, the issuer ID."),
        ConnectorPreset(id: "gitlab", name: "GitLab", serverURL: URL(string: "https://gitlab.com/api/v4/mcp")!,
                        signIn: .oauth, symbol: "arrow.triangle.branch"),
        ConnectorPreset(id: "supabase", name: "Supabase", serverURL: URL(string: "https://mcp.supabase.com/mcp")!,
                        signIn: .oauth, symbol: "server.rack"),
        ConnectorPreset(id: "neon", name: "Neon", serverURL: URL(string: "https://mcp.neon.tech/mcp")!,
                        signIn: .oauth, symbol: "cylinder.split.1x2"),
        ConnectorPreset(id: "prisma", name: "Prisma Postgres", serverURL: URL(string: "https://mcp.prisma.io/mcp")!,
                        signIn: .oauth, symbol: "cylinder", claudeAINames: ["claude.ai Prisma"]),
        ConnectorPreset(id: "netlify", name: "Netlify", serverURL: URL(string: "https://netlify-mcp.netlify.app/mcp")!,
                        signIn: .oauth, symbol: "globe.americas"),
        ConnectorPreset(id: "cloudflare", name: "Cloudflare", serverURL: URL(string: "https://bindings.mcp.cloudflare.com/mcp")!,
                        signIn: .oauth, symbol: "cloud", claudeAINames: ["claude.ai Cloudflare Developer Platform"]),
        ConnectorPreset(id: "posthog", name: "PostHog", serverURL: URL(string: "https://mcp.posthog.com/mcp")!,
                        signIn: .oauth, symbol: "chart.bar.xaxis"),
        ConnectorPreset(id: "semgrep", name: "Semgrep", serverURL: URL(string: "https://mcp.semgrep.ai/mcp")!,
                        signIn: .oauth, symbol: "lock.shield"),
        ConnectorPreset(id: "postman", name: "Postman", serverURL: URL(string: "https://mcp.postman.com/mcp")!,
                        signIn: .oauth, symbol: "paperplane"),
        ConnectorPreset(id: "jam", name: "Jam", serverURL: URL(string: "https://mcp.jam.dev/mcp")!,
                        signIn: .oauth, symbol: "record.circle"),
        ConnectorPreset(id: "circleci", name: "CircleCI", serverURL: URL(string: "https://mcp.circleci.com/v1/mcp")!,
                        signIn: .oauth, symbol: "circle.circle"),
        ConnectorPreset(id: "browserstack", name: "BrowserStack", serverURL: URL(string: "https://mcp.browserstack.com/mcp")!,
                        signIn: .oauth, symbol: "macbook.and.iphone"),
        ConnectorPreset(id: "bugsnag", name: "BugSnag", serverURL: URL(string: "https://bugsnag.mcp.smartbear.com/mcp")!,
                        signIn: .oauth, symbol: "exclamationmark.triangle"),
        ConnectorPreset(id: "swagger", name: "Swagger", serverURL: URL(string: "https://swagger.mcp.smartbear.com/mcp")!,
                        signIn: .oauth, symbol: "curlybraces"),
        ConnectorPreset(id: "zephyr", name: "Zephyr", serverURL: URL(string: "https://zephyr.mcp.smartbear.com/mcp")!,
                        signIn: .oauth, symbol: "checkmark.seal"),
        ConnectorPreset(id: "grafana", name: "Grafana", serverURL: URL(string: "https://mcp.grafana.com/mcp")!,
                        signIn: .oauth, symbol: "gauge.medium"),
        ConnectorPreset(id: "honeycomb", name: "Honeycomb", serverURL: URL(string: "https://mcp.honeycomb.io/mcp")!,
                        signIn: .oauth, symbol: "hexagon"),
        ConnectorPreset(id: "axiom", name: "Axiom", serverURL: URL(string: "https://mcp.axiom.co/mcp")!,
                        signIn: .oauth, symbol: "list.bullet.rectangle"),
        ConnectorPreset(id: "statsig", name: "Statsig", serverURL: URL(string: "https://api.statsig.com/v1/mcp")!,
                        signIn: .oauth, symbol: "flag"),
        ConnectorPreset(id: "port", name: "Port", serverURL: URL(string: "https://mcp.port.io/v1")!,
                        signIn: .oauth, symbol: "square.stack.3d.down.right"),
        ConnectorPreset(id: "aiven", name: "Aiven", serverURL: URL(string: "https://mcp.aiven.live/mcp")!,
                        signIn: .oauth, symbol: "cylinder.fill"),
        ConnectorPreset(id: "upstash", name: "Upstash", serverURL: URL(string: "https://mcp.upstash.com/mcp")!,
                        signIn: .oauth, symbol: "bolt.horizontal"),
        ConnectorPreset(id: "algolia", name: "Algolia", serverURL: URL(string: "https://mcp.algolia.com/mcp")!,
                        signIn: .oauth, symbol: "text.magnifyingglass"),
        ConnectorPreset(id: "contentful", name: "Contentful", serverURL: URL(string: "https://mcp.contentful.com/mcp")!,
                        signIn: .oauth, symbol: "square.text.square"),
        ConnectorPreset(id: "sanity", name: "Sanity", serverURL: URL(string: "https://mcp.sanity.io")!,
                        signIn: .oauth, symbol: "doc.plaintext"),
        ConnectorPreset(id: "workos", name: "WorkOS", serverURL: URL(string: "https://mcp.workos.com/mcp")!,
                        signIn: .oauth, symbol: "person.badge.key"),
        ConnectorPreset(id: "apify", name: "Apify", serverURL: URL(string: "https://mcp.apify.com/")!,
                        signIn: .oauth, symbol: "ant"),
        ConnectorPreset(id: "mapbox", name: "Mapbox", serverURL: URL(string: "https://mcp.mapbox.com/mcp")!,
                        signIn: .oauth, symbol: "map"),
        // Payments and sites
        ConnectorPreset(id: "stripe", name: "Stripe", serverURL: URL(string: "https://mcp.stripe.com")!,
                        signIn: .oauth, symbol: "dollarsign.circle"),
        ConnectorPreset(id: "paypal", name: "PayPal", serverURL: URL(string: "https://mcp.paypal.com/mcp")!,
                        signIn: .oauth, symbol: "creditcard"),
        ConnectorPreset(id: "square", name: "Square", serverURL: URL(string: "https://mcp.squareup.com/mcp")!,
                        signIn: .oauth, symbol: "square.grid.2x2"),
        // Mercury's own server (docs.mercury.com/docs/connecting-mercury-mcp), read only: Yardlet asks
        // for `read` and `offline_access` alone, so payment and transfer requests, categories, and
        // transaction notes stay out (docs/CONNECTORS.md, "Directory").
        ConnectorPreset(id: "mercury", name: "Mercury", serverURL: URL(string: "https://mcp.mercury.com/mcp")!,
                        signIn: .oauth, scope: "read offline_access", symbol: "building.columns",
                        claudeAINames: ["claude.ai Mercury"]),
        ConnectorPreset(id: "webflow", name: "Webflow", serverURL: URL(string: "https://mcp.webflow.com/mcp")!,
                        signIn: .oauth, symbol: "macwindow"),
        ConnectorPreset(id: "wix", name: "Wix", serverURL: URL(string: "https://mcp.wix.com/mcp")!,
                        signIn: .oauth, symbol: "safari"),
        // Ramp and Brex list card, bill, transfer, and bank account scopes too; like Mercury, Yardlet
        // asks only to read: Ramp's transactions, business, and cards, and Brex's users, card
        // expenses, and cash accounts (docs/CONNECTORS.md, "Directory").
        ConnectorPreset(id: "ramp", name: "Ramp", serverURL: URL(string: "https://mcp.ramp.com/mcp")!,
                        signIn: .oauth, scope: "transactions:read business:read cards:read", symbol: "dollarsign.square"),
        ConnectorPreset(id: "brex", name: "Brex", serverURL: URL(string: "https://api.brex.com/mcp")!,
                        signIn: .oauth,
                        scope: "openid offline_access users.readonly expenses.card.readonly accounts.cash.readonly",
                        symbol: "creditcard.fill"),
        ConnectorPreset(id: "paddle", name: "Paddle", serverURL: URL(string: "https://mcp.paddle.com/mcp")!,
                        signIn: .oauth, symbol: "cart"),
        ConnectorPreset(id: "beancount-io", name: "Beancount.io", serverURL: URL(string: "https://beancount.io/api-gateway/mcp")!,
                        signIn: .oauth, symbol: "book.closed"),
        ConnectorPreset(id: "hostinger", name: "Hostinger", serverURL: URL(string: "https://mcp.hostinger.com")!,
                        signIn: .oauth, symbol: "network"),
        // Figma's remote server (mcp.figma.com) admits only clients in Figma's catalog, so the
        // desktop app's own server is the one Yardlet can use.
        ConnectorPreset(id: "figma-desktop", name: "Figma", serverURL: URL(string: "http://127.0.0.1:3845/mcp")!,
                        signIn: .none, symbol: "paintpalette",
                        note: "The Figma desktop app's server (turn it on in Dev Mode). Figma's remote server admits only apps Figma approved.",
                        claudeAINames: ["claude.ai Figma"], codexPlugins: ["figma"]),
        // Search and documentation. These answer without a sign-in (Hugging Face, Exa, and Context7
        // also take one for more, which Yardlet does not ask for); Tavily signs in.
        ConnectorPreset(id: "tavily", name: "Tavily", serverURL: URL(string: "https://mcp.tavily.com/mcp/")!,
                        signIn: .oauth, symbol: "magnifyingglass"),
        ConnectorPreset(id: "exa", name: "Exa", serverURL: URL(string: "https://mcp.exa.ai/mcp")!,
                        signIn: .none, symbol: "magnifyingglass.circle"),
        ConnectorPreset(id: "huggingface", name: "Hugging Face", serverURL: URL(string: "https://huggingface.co/mcp")!,
                        signIn: .none, symbol: "face.smiling"),
        ConnectorPreset(id: "context7", name: "Context7", serverURL: URL(string: "https://mcp.context7.com/mcp")!,
                        signIn: .none, symbol: "books.vertical"),
        ConnectorPreset(id: "deepwiki", name: "DeepWiki", serverURL: URL(string: "https://mcp.deepwiki.com/mcp")!,
                        signIn: .none, symbol: "book.pages"),
        ConnectorPreset(id: "openai-docs", name: "OpenAI Docs", serverURL: URL(string: "https://developers.openai.com/mcp")!,
                        signIn: .none, symbol: "book"),
        ConnectorPreset(id: "microsoft-learn", name: "Microsoft Learn", serverURL: URL(string: "https://learn.microsoft.com/api/mcp")!,
                        signIn: .none, symbol: "graduationcap"),
        ConnectorPreset(id: "aws-knowledge", name: "AWS Knowledge", serverURL: URL(string: "https://knowledge-mcp.global.api.aws")!,
                        signIn: .none, symbol: "cloud.fill"),
        ConnectorPreset(id: "cloudflare-docs", name: "Cloudflare Docs", serverURL: URL(string: "https://docs.mcp.cloudflare.com/mcp")!,
                        signIn: .none, symbol: "doc.text.magnifyingglass"),
        // Twilio's public API documentation (twilio.com/docs/ai/mcp): no sign-in, and no account's
        // messages or calls, which need Twilio's own API keys.
        ConnectorPreset(id: "twilio-docs", name: "Twilio Docs", serverURL: URL(string: "https://mcp.twilio.com/docs")!,
                        signIn: .none, symbol: "phone.bubble")
    ]
}

/// A service found in another harness's own configuration, offered once for connecting through
/// Yardlet (Settings → Connectors, "Import").
struct ConnectorImportSuggestion: Identifiable, Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case preset(ConnectorPreset)
        /// A remote server the directory does not know, by the name and address it was found under.
        case custom(name: String, url: URL)
        /// A program another app or harness starts (stdio), by its name there and where it was
        /// found first; what it runs is read from that file only when the person asks to see it.
        case program(name: String, server: NativeMCPServer, home: NativeMCPHome)
    }

    var target: Target
    /// Where it was found ("Claude Code · developer@example.test", "Codex plugin"), deduplicated.
    var foundIn: [String]

    var id: String {
        switch target {
        case .preset(let preset): "preset|\(preset.id)"
        case .custom(_, let url): "custom|\(MCPServerAddress.canonical(url))"
        case .program(let name, let server, _): "program|" + (server.programKey ?? "\(server.command ?? "")|\(name)")
        }
    }

    var name: String {
        switch target {
        case .preset(let preset): preset.name
        case .custom(let name, _): name
        case .program(let name, _, _): name
        }
    }

    /// The server's address; nil for a program.
    var serverURL: URL? {
        switch target {
        case .preset(let preset): preset.serverURL
        case .custom(_, let url): url
        case .program: nil
        }
    }

    /// Everything a sign-in needs comes from the server: one click adds and connects. A program
    /// is never one click: the person sees what runs first.
    var connectsInOneClick: Bool {
        switch target {
        case .preset(let preset): [.oauth, .none, .macPermission, .localApp].contains(preset.signIn)
        case .custom: true
        case .program: false
        }
    }
    /// What each harness and account has that Yardlet could carry instead, less what is already
    /// added, the Yardlet server itself, local programs no preset stands for, and claude.ai's own
    /// connectors (Claude Docs, Claude Code Remote), which exist only in claude.ai.
    static func suggestions(from inventory: [NativeMCPInventoryEntry], connected: [ConnectorRecord]) -> [ConnectorImportSuggestion] {
        let added = Set(connected.map { MCPServerAddress.canonical($0.serverURL) })
        let addedPrograms = Set(connected.compactMap { $0.program?.key })
        var order: [String] = []
        var byID: [String: ConnectorImportSuggestion] = [:]
        func found(_ target: Target, _ place: String) {
            let suggestion = ConnectorImportSuggestion(target: target, foundIn: [place])
            if let url = suggestion.serverURL, added.contains(MCPServerAddress.canonical(url)) { return }
            if case .program(_, let server, _) = target, let key = server.programKey, addedPrograms.contains(key) { return }
            if var existing = byID[suggestion.id] {
                if !existing.foundIn.contains(place) { existing.foundIn.append(place) }
                byID[suggestion.id] = existing
            } else {
                order.append(suggestion.id)
                byID[suggestion.id] = suggestion
            }
        }
        for entry in inventory {
            let place = Self.place(entry.home)
            for server in entry.servers where server.name != AgentToolEnvironment.serverName {
                if let url = server.url {
                    if let preset = ConnectorPreset.preset(for: url) {
                        found(.preset(preset), place)
                    } else if url.scheme == "https" {
                        found(.custom(name: server.name, url: url), place)
                    }
                } else if let package = server.package,
                          let preset = ConnectorPreset.all.first(where: { $0.packages.contains { package.hasPrefix($0) } }) {
                    found(.preset(preset), place)
                } else if server.command != nil, server.isEnabled, !server.isAppHelper {
                    found(.program(name: server.name, server: server, home: entry.home), place)
                }
            }
            for name in entry.accountConnectors {
                switch entry.home.kind {
                case .claude:
                    if let preset = ConnectorPreset.all.first(where: { $0.claudeAINames.contains(name) }) {
                        found(.preset(preset), L10n.format("claude.ai · %@", Self.account(entry.home)))
                    }
                case .codex:
                    let base = String(name.split(separator: "@").first ?? "")
                    if let preset = ConnectorPreset.all.first(where: { $0.codexPlugins.contains(base) }) {
                        found(.preset(preset), L10n.string("Codex plugin"))
                    }
                case .antigravity, .app:
                    break
                }
            }
            // The ChatGPT apps Codex connected (Gmail, Google Calendar, Slack…), by name.
            for name in entry.apps {
                if let preset = ConnectorPreset.all.first(where: { $0.isNamed(name) }) {
                    found(.preset(preset), entry.home.account.map { L10n.format("Codex app · %@", $0) } ?? L10n.string("Codex app"))
                }
            }
        }
        // The directory's order, then the rest as found.
        let presetOrder = ConnectorPreset.all.map { "preset|\($0.id)" }
        return order.enumerated().compactMap { index, id in byID[id].map { (index, $0) } }
            .sorted { lhs, rhs in
                let left = presetOrder.firstIndex(of: lhs.1.id) ?? presetOrder.count
                let right = presetOrder.firstIndex(of: rhs.1.id) ?? presetOrder.count
                return left != right ? left < right : lhs.0 < rhs.0
            }
            .map(\.1)
    }

    static func account(_ home: NativeMCPHome) -> String {
        home.account ?? L10n.string("Default login")
    }

    static func place(_ home: NativeMCPHome) -> String {
        switch home.kind {
        case .claude: "Claude Code · " + account(home)
        case .codex: home.account.map { "Codex · \($0)" } ?? "Codex"
        case .antigravity: "Antigravity"
        case .app(let app, _): app.name
        }
    }
}

/// Whether a connector reaches one task, and if not, why.
enum ConnectorTaskState: Equatable, Sendable {
    case on
    /// The user turned it off for this task.
    case off
    /// The task's harness loads a server at the same address from its own configuration and
    /// cannot be told to leave it out (or Yardlet's connector was not connected when the task
    /// started), so Yardlet leaves its copy out rather than give the model the same tools twice.
    case harnessHasIt
    /// Antigravity tasks get no connectors.
    case unsupportedHarness
}

/// What Yardlet knows about a task when it injects the Yardlet MCP server: its harness and the
/// remote servers that harness loads itself (`NativeMCPInventory.loadedRemoteServers`).
struct ConnectorTaskScope: Equatable, Sendable {
    var harness: HarnessKind
    var nativeServerURLs: Set<String> = []
    /// The harness's own entries behind those addresses, by its names.
    var nativeServers: [HarnessRemoteServer] = []
    /// Addresses where Yardlet's connected connector stands in for the harness's own server in
    /// this task: the harness is told to leave its copy out of this process, so the model gets
    /// one, Yardlet's (`ConnectorCenter.withYardletStandIns`).
    var yardletServedURLs: Set<String> = []
    /// The programs the harness starts itself (`NativeMCPServer.programKey`): a program connector
    /// that starts the same package stays out of the task, so the model gets the harness's copy.
    var nativePrograms: Set<String> = []

    /// Antigravity's per-task route is going away, so its tasks get no connectors.
    var carriesConnectors: Bool { harness != .antigravityCLI }

    /// The harness's own servers left out of this task for Yardlet's connectors.
    var leftOutNativeServers: [HarnessRemoteServer] {
        nativeServers.filter { yardletServedURLs.contains($0.address) }
    }

    /// Only Claude Code takes a list of servers to leave out of one process (`deniedMcpServers` in
    /// `--settings`, which merges from every settings source). Codex and ACP harnesses keep their
    /// own server, and Yardlet's copy stays out of the task.
    static func canLeaveOutNativeServers(_ harness: HarnessKind) -> Bool { harness == .claudeCode }
}

/// The connector behind a Yardlet tool name, for the conversation's tool rows ("Linear: create
/// issue"). The center keeps it current; reading it needs no actor.
final class ConnectorToolLabels: @unchecked Sendable {
    struct Label: Equatable, Sendable {
        var connector: String
        var presetID: String?
        /// The server's own name for the tool.
        var tool: String
        /// The account the connector acts in (a Gmail address), when it has one.
        var account: String? = nil
        /// The local service behind it, whose sending and changing tools ask every time.
        var localService: LocalConnectorService? = nil
        /// Where the connector's picture comes from.
        var icons: ConnectorIconSources = .none
    }

    static let shared = ConnectorToolLabels()

    private let lock = NSLock()
    private var labels: [String: Label] = [:]

    func update(_ records: [ConnectorRecord]) {
        var next: [String: Label] = [:]
        for record in records {
            for tool in record.offeredTools {
                guard let original = tool["name"]?.stringValue else { continue }
                next[ConnectorToolNaming.name(slug: record.slug, tool: original)] =
                    Label(connector: record.name, presetID: record.presetID, tool: original, account: record.account,
                          localService: record.localService, icons: record.iconSources)
            }
        }
        lock.withLock { labels = next }
    }

    /// The label for a tool of the Yardlet server, by its name there (`linear_create_issue`).
    func label(forTool name: String) -> Label? {
        lock.withLock { labels[name] }
    }

    /// The label for a Claude Code tool name (`mcp__yardlet__linear_create_issue`).
    func label(forClaudeTool name: String) -> Label? {
        let prefix = "mcp__\(AgentToolEnvironment.serverName)__"
        guard name.hasPrefix(prefix) else { return nil }
        return label(forTool: String(name.dropFirst(prefix.count)))
    }

    /// The tool's words: "create issue" for `create_issue`.
    static func spaced(_ tool: String) -> String {
        tool.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
    }
}
