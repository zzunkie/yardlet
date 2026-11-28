import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OAuth clients for the Calendar screen and for account-scoped agent tools.
enum GoogleOAuth {
    static let personalModeURL = URL(string: "https://console.cloud.google.com/auth/overview/personal?apis=ws,wsmcp&clientType=desktop&isAgent=true")!

    /// The Desktop OAuth client a build carries, from `YardletGoogleOAuthClientID` and
    /// `YardletGoogleOAuthClientSecret` in Info.plist (scripts/build-app.sh writes them from
    /// Packaging/GoogleOAuthClient.json, which stays out of git). An installed app's secret ships
    /// inside it, so Google does not treat it as secret (developers.google.com/identity/protocols/
    /// oauth2/native-app); PKCE protects each sign-in.
    struct BuiltInApp: Equatable, Sendable {
        let clientID: String
        let clientSecret: String?

        static let clientIDKey = "YardletGoogleOAuthClientID"
        static let clientSecretKey = "YardletGoogleOAuthClientSecret"

        /// The services Yardlet's own app signs in for, whose scopes are the ones its Google Cloud
        /// project lists. Analytics and Ads sign in only with an app of the person's own.
        static let services: [LocalConnectorService] = [.googleCalendar]

        /// The app in a bundle's info dictionary; nil when the build carries none.
        static func from(info: [String: Any]?) -> BuiltInApp? {
            func value(_ key: String) -> String? {
                let text = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return text?.isEmpty == false ? text : nil
            }
            guard let id = value(clientIDKey) else { return nil }
            return BuiltInApp(clientID: id, clientSecret: value(clientSecretKey))
        }
    }

    /// Google's endpoints. Tests point them at a stand-in server.
    struct Endpoints: Equatable, Sendable {
        var authorization: URL
        var token: URL
        /// The Gmail API's base, `…/gmail/v1/`.
        var gmailAPI: URL
        /// The Calendar API's base, `…/calendar/v3/`.
        var calendarAPI: URL = Endpoints.liveCalendar
        /// Used to identify an account signing in for Drive alone.
        var driveAPI: URL = Endpoints.liveDrive
        /// The Analytics Admin and Data APIs' bases (v1beta), and the Google Ads API's (v26).
        var analyticsAdminAPI: URL = Endpoints.liveAnalyticsAdmin
        var analyticsDataAPI: URL = Endpoints.liveAnalyticsData
        var adsAPI: URL = Endpoints.liveAds
        /// The OpenID Connect user info endpoint, which names an account that has none of Gmail,
        /// Calendar, and Drive.
        var userInfo: URL = Endpoints.liveUserInfo

        private static let liveCalendar = URL(string: "https://www.googleapis.com/calendar/v3/")!
        private static let liveDrive = URL(string: "https://www.googleapis.com/drive/v3/")!
        private static let liveAnalyticsAdmin = URL(string: "https://analyticsadmin.googleapis.com/v1beta/")!
        private static let liveAnalyticsData = URL(string: "https://analyticsdata.googleapis.com/v1beta/")!
        private static let liveAds = URL(string: "https://googleads.googleapis.com/v26/")!
        private static let liveUserInfo = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!

        /// developers.google.com/identity/protocols/oauth2/native-app and the Gmail, Calendar, and
        /// Drive API references.
        static let live = Endpoints(
            authorization: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            token: URL(string: "https://oauth2.googleapis.com/token")!,
            gmailAPI: URL(string: "https://gmail.googleapis.com/gmail/v1/")!
        )

        /// The API base a service's requests go to; a service not Google's keeps its own address.
        func base(for service: LocalConnectorService) -> URL {
            switch service {
            case .gmail: GoogleWorkspaceEndpoint.gmail.url
            case .googleCalendar: GoogleWorkspaceEndpoint.calendar.url
            case .googleDrive: GoogleWorkspaceEndpoint.drive.url
            case .googleAnalytics: analyticsAdminAPI
            case .googleAds: adsAPI
            default: service.address
            }
        }
    }

    /// OAuth scopes requested by the six Workspace MCP endpoints.
    static func workspaceScopes(for service: LocalConnectorService) -> [String] {
        let names: [String] = switch service {
        case .gmail: ["gmail.modify", "gmail.settings.basic"]
        case .googleCalendar: ["calendar.calendarlist.readonly", "calendar.events", "calendar.events.freebusy"]
        case .googleDrive: ["drive", "documents", "spreadsheets", "presentations"]
        default: []
        }
        return names.map { "https://www.googleapis.com/auth/" + $0 }
    }

    static let mailboxScope = "https://www.googleapis.com/auth/gmail.modify"

    /// The account's address, which names an account that has none of Gmail, Calendar, and Drive.
    static let emailScope = "https://www.googleapis.com/auth/userinfo.email"

    static var calendarUIScope: String { (["openid", emailScope] + LocalConnectorService.googleCalendar.scopes).joined(separator: " ") }

    /// The scopes for a set of Google services, in the directory's order, space-separated.
    static func scope(for services: some Sequence<LocalConnectorService>) -> String {
        let wanted = Set(services)
        var seen = Set<String>()
        return LocalConnectorService.google.filter(wanted.contains).flatMap(\.scopes)
            .filter { seen.insert($0).inserted }.joined(separator: " ")
    }

    /// The services a sign-in with `clientID` may use: with Yardlet's own app, only those it signs
    /// in for; with any other app, all of them. An app saved under the same client ID as Yardlet's
    /// is Yardlet's.
    static func services(_ services: some Sequence<LocalConnectorService>, clientID: String?,
                         builtIn: BuiltInApp?) -> [LocalConnectorService] {
        guard let builtIn, clientID == builtIn.clientID else { return Array(services) }
        return services.filter(BuiltInApp.services.contains)
    }

    /// The services whose every scope a granted scope string holds. Without one (a token from
    /// before Google listed it), every asked-for service counts as granted.
    static func grantedServices(_ granted: String?, of services: some Sequence<LocalConnectorService>)
        -> Set<LocalConnectorService> {
        Set(services.filter { grants(granted, all: $0.scopes.joined(separator: " ")) })
    }

    /// The secure-store item that holds the registered app (a `client` credential), beside the
    /// connectors' own items. Fixed, so Settings and every sign-in find the one app.
    static let appCredentialID = UUID(uuidString: "6A0F1C2E-9B4D-4E7A-A1C3-5D8E2F7B9C40")!

    /// The authorization server as Google's documentation names it: no discovery request, no
    /// dynamic registration, the secret in the form.
    static func authorizationServer(_ endpoints: Endpoints) -> OAuthAuthorizationServer {
        OAuthAuthorizationServer(
            issuer: "https://accounts.google.com",
            authorizationEndpoint: endpoints.authorization,
            tokenEndpoint: endpoints.token,
            registrationEndpoint: nil,
            tokenEndpointAuthMethods: ["client_secret_post", "client_secret_basic"]
        )
    }

    /// A REST API sign-in names no resource (RFC 8707 is for the MCP servers).
    static func plan(scope: String, endpoints: Endpoints) -> OAuthPlan {
        OAuthPlan(server: authorizationServer(endpoints), resource: nil, scope: scope)
    }

    /// Offline access for a refresh token, with consent asked each sign-in so Google issues one
    /// every time. A new account also gets the account chooser, so a second account is not the
    /// browser's current one by default; signing in again names the account it was.
    /// With `include_granted_scopes`, a sign-in that turns on one more service for an account
    /// (incremental authorization) gets a token for what the account granted before as well.
    static func authorizationParameters(account: String?) -> [String: String] {
        var parameters = ["access_type": "offline", "include_granted_scopes": "true"]
        if let account, !account.isEmpty {
            parameters["prompt"] = "consent"
            parameters["login_hint"] = account
        } else {
            parameters["prompt"] = "select_account consent"
        }
        return parameters
    }

    /// Whether Google granted every scope asked for. With granular consent a person can leave a
    /// scope unchecked; the token response's `scope` lists what was granted.
    static func grants(_ granted: String?, all requested: String) -> Bool {
        guard let granted else { return true }
        let have = Set(granted.split(separator: " ").map(String.init))
        return requested.split(separator: " ").allSatisfy { have.contains(String($0)) }
    }
}

enum GoogleSignInError: Error, Equatable, LocalizedError {
    /// No Google OAuth app is saved yet.
    case noApp
    /// Google issued a token without the scopes a service's tools need (left unchecked on the
    /// consent page), by the service's name.
    case scopeNotGranted(String)
    /// Google issued no refresh token, so the sign-in would not outlast the hour.
    case noRefreshToken
    /// The account signs in with Yardlet's own app, which does not sign in for these services
    /// (Analytics, Ads), by name.
    case needsOwnApp(String)

    static func scopeNotGranted(_ services: [LocalConnectorService]) -> GoogleSignInError {
        .scopeNotGranted(services.map(\.name).formatted(.list(type: .and)))
    }

    static func needsOwnApp(_ services: [LocalConnectorService]) -> GoogleSignInError {
        .needsOwnApp(services.map(\.name).formatted(.list(type: .and)))
    }

    var errorDescription: String? {
        switch self {
        case .noApp:
            L10n.string("Save your Google OAuth app first: Settings → Connectors → Set up Google.")
        case .scopeNotGranted(let services):
            L10n.format("Google did not grant access to %@. Connect again and allow it.", services)
        case .noRefreshToken:
            L10n.string("Google did not issue a lasting sign-in. Connect again.")
        case .needsOwnApp(let services):
            L10n.format("Yardlet's Google app does not sign in for %@. Save a Google OAuth app of your own, then reconnect this account.",
                        services)
        }
    }
}
