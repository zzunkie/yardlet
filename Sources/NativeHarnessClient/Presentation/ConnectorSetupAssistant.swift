import Foundation

/// The "Set up in one go" assistant for the services that need an app of the person's own
/// (Settings → Connectors): Google, whose one OAuth app serves Gmail, Calendar, and Drive, and
/// Slack, whose app Yardlet's manifest creates. Each step opens the exact console page and offers
/// a copy button for every value the person pastes; a step shows a check once it is done.
///
/// Yardlet cannot see a console, so a console step counts as done once its page was opened or
/// ticked by hand, and every console step counts as done once the app's client is saved; the last
/// step is done when an account is connected.
struct ConnectorSetupAssistant: Equatable {
    enum Service: String, Equatable, Sendable {
        case google
        case microsoft
        case slack
        case zoom
        case appStoreConnect
        case mail
    }

    enum StepID: String, CaseIterable, Sendable {
        // Google
        case project, apis, consent, publish, scopes, client, googleSignIn
        // Microsoft
        case msRegister, msRedirect, msPermissions, msClient, msSignIn
        // Slack
        case slackCreate, slackCredentials, slackSignIn
        // Zoom
        case zoomCreate, zoomScopes, zoomCredentials, zoomSignIn
        // App Store Connect
        case ascCreateKey, ascKeyFile, ascConnect
        // A mail account over IMAP: the service's own steps, then the address and app password
        case mailService1, mailService2, mailService3, mailAccount, mailConnect
    }

    struct Link: Equatable {
        let title: String
        let url: URL
    }

    /// A value the person pastes into a console, with what to call its copy button.
    struct Copy: Equatable {
        let label: String
        let value: String
    }

    struct Step: Equatable, Identifiable {
        let id: StepID
        let title: String
        let detail: String?
        var link: Link?
        var copies: [Copy] = []
        var isDone: Bool
    }

    let service: Service
    let steps: [Step]

    /// The first step not done, where the assistant's attention goes.
    var current: StepID? { steps.first { !$0.isDone }?.id }
    var doneCount: Int { steps.filter(\.isDone).count }
    var isComplete: Bool { current == nil }

    // MARK: Google

    static let googleProject = URL(string: "https://console.cloud.google.com/projectcreate")!
    /// Turns on the three services' APIs, and the Docs, Sheets, and Slides APIs Drive's editing
    /// tools call, in one confirmation.
    static var googleAPIs: URL {
        URL(string: "https://console.cloud.google.com/flows/enableapi?apiid="
            + (LocalConnectorService.google.flatMap(\.apiIDs) + GoogleEditorsToolCatalog.apiIDs).joined(separator: ","))!
    }
    static let googleOverview = URL(string: "https://console.cloud.google.com/auth/overview")!
    static let googleAudience = URL(string: "https://console.cloud.google.com/auth/audience")!
    static let googleDataAccess = URL(string: "https://console.cloud.google.com/auth/scopes")!
    static let googleClients = URL(string: "https://console.cloud.google.com/auth/clients")!

    /// The app name the person types in Google's and Slack's consoles.
    static let appName = "Yardlet"

    /// Every Google scope, one per line, as Data Access → "Manually add scopes" takes them.
    static var googleScopeList: String {
        GoogleOAuth.scopes.map(\.url).joined(separator: "\n")
    }

    /// - Parameter builtIn: the build carries Yardlet's own Google app and the person is not setting
    ///   up one of theirs, so signing in is the only step.
    static func google(opened: Set<StepID>, appSaved: Bool, connectedAccounts: Int,
                       builtIn: Bool = false) -> ConnectorSetupAssistant {
        func done(_ id: StepID) -> Bool { appSaved || opened.contains(id) }
        let signIn = Step(id: .googleSignIn, title: L10n.string("Sign in with each Google account"),
                          detail: L10n.string("Pick Gmail, Calendar, and Drive for the account, then sign in once."),
                          isDone: connectedAccounts > 0)
        if builtIn { return ConnectorSetupAssistant(service: .google, steps: [signIn]) }
        let redirect = ConnectorOAuth.registeredClientRedirectURI.absoluteString
        return ConnectorSetupAssistant(service: .google, steps: [
            Step(id: .project, title: L10n.string("Create a Google Cloud project"),
                 detail: L10n.string("Any name. Or pick a project you have."),
                 link: Link(title: L10n.string("New project"), url: googleProject), isDone: done(.project)),
            Step(id: .apis, title: L10n.string("Turn on the Gmail, Calendar, and Drive APIs"),
                 detail: L10n.string("One page turns them on, with the Docs, Sheets, and Slides APIs the Drive tools use and the Analytics and Ads APIs; confirm the project and press Enable."),
                 link: Link(title: L10n.string("Enable APIs"), url: googleAPIs), isDone: done(.apis)),
            Step(id: .consent, title: L10n.string("Set up Google Auth Platform"),
                 detail: L10n.string("App name, your email, then Audience: External for personal Gmail and other accounts, Internal for your Workspace organization's accounts only."),
                 link: Link(title: L10n.string("Google Auth Platform"), url: googleOverview),
                 copies: [Copy(label: L10n.string("App name"), value: appName)], isDone: done(.consent)),
            Step(id: .publish, title: L10n.string("Publish the app (External only)"),
                 detail: L10n.string("Audience → Publish app, so its status is In production. In Testing, Google ends each sign-in after 7 days. No verification is needed for your own use."),
                 link: Link(title: L10n.string("Audience"), url: googleAudience), isDone: done(.publish)),
            Step(id: .scopes, title: L10n.string("Add the scopes"),
                 detail: L10n.string("Data Access → Add or remove scopes → Manually add scopes: paste them all, then Update and Save. Analytics and Ads ask for theirs only on the accounts that turn them on."),
                 link: Link(title: L10n.string("Data Access"), url: googleDataAccess),
                 copies: [Copy(label: L10n.string("Scopes"), value: googleScopeList)], isDone: done(.scopes)),
            Step(id: .client, title: L10n.string("Create a client and paste it here"),
                 detail: L10n.string("Application type Desktop app, name Yardlet, then Create. Paste its client ID and secret below. A Web application client works too with the redirect URL added."),
                 link: Link(title: L10n.string("Create client"), url: googleClients),
                 copies: [Copy(label: L10n.string("App name"), value: appName),
                          Copy(label: L10n.string("Redirect URL"), value: redirect)],
                 isDone: appSaved),
            signIn
        ])
    }

    // MARK: Microsoft

    /// Microsoft Entra admin center → App registrations.
    static let microsoftRegistrations = URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!

    /// The manifest entry that makes Yardlet's loopback a redirect of a desktop (public) client.
    /// Microsoft's redirect form does not take a `127.0.0.1` address, so it goes in the manifest
    /// (learn.microsoft.com/entra/identity-platform/reply-url).
    static var microsoftManifestEntry: String {
        #"{ "url": "\#(ConnectorOAuth.registeredClientRedirectURI.absoluteString)", "type": "InstalledClient" }"#
    }

    /// Every Graph permission the four services use, one per line, as API permissions lists them.
    static var microsoftPermissionList: String {
        (MicrosoftOAuth.baseScopes + LocalConnectorService.microsoft.flatMap(\.scopes)).joined(separator: "\n")
    }

    /// - Parameter builtIn: the build carries Yardlet's own Microsoft app and the person is not
    ///   setting up one of theirs, so signing in is the only step.
    static func microsoft(opened: Set<StepID>, appSaved: Bool, connectedAccounts: Int,
                          builtIn: Bool = false) -> ConnectorSetupAssistant {
        func done(_ id: StepID) -> Bool { appSaved || opened.contains(id) }
        let signIn = Step(id: .msSignIn, title: L10n.string("Sign in with each Microsoft account"),
                          detail: L10n.string("Pick the services for the account, then sign in once. Teams needs a work or school account."),
                          isDone: connectedAccounts > 0)
        if builtIn { return ConnectorSetupAssistant(service: .microsoft, steps: [signIn]) }
        return ConnectorSetupAssistant(service: .microsoft, steps: [
            Step(id: .msRegister, title: L10n.string("Register an app in Microsoft Entra"),
                 detail: L10n.string("App registrations → New registration, name Yardlet. Supported accounts: any organization and personal accounts, or only your organization's. Leave the redirect empty, then Register."),
                 link: Link(title: L10n.string("App registrations"), url: microsoftRegistrations),
                 copies: [Copy(label: L10n.string("App name"), value: appName)], isDone: done(.msRegister)),
            Step(id: .msRedirect, title: L10n.string("Add Yardlet's redirect in the manifest"),
                 detail: L10n.string("In the app, Manifest: add the redirect URL below to publicClient → redirectUris, or in the older AAD Graph manifest the entry below to replyUrlsWithType, then Save. The redirect form doesn't take this address."),
                 copies: [Copy(label: L10n.string("Manifest entry"), value: microsoftManifestEntry),
                          Copy(label: L10n.string("Redirect URL"), value: ConnectorOAuth.registeredClientRedirectURI.absoluteString)],
                 isDone: done(.msRedirect)),
            Step(id: .msPermissions, title: L10n.string("Add the Microsoft Graph permissions"),
                 detail: L10n.string("API permissions → Add a permission → Microsoft Graph → Delegated permissions: add the ones below. An administrator can then grant consent for the whole organization."),
                 copies: [Copy(label: L10n.string("Permissions"), value: microsoftPermissionList)], isDone: done(.msPermissions)),
            Step(id: .msClient, title: L10n.string("Paste the application ID here"),
                 detail: L10n.string("Overview → Application (client) ID. For an app only your organization's accounts use, also its Directory (tenant) ID."),
                 isDone: appSaved),
            signIn
        ])
    }

    // MARK: Slack

    static func slack(opened: Set<StepID>, clientEntered: Bool, connected: Bool) -> ConnectorSetupAssistant {
        ConnectorSetupAssistant(service: .slack, steps: [
            Step(id: .slackCreate, title: L10n.string("Create the Yardlet app in Slack"),
                 detail: L10n.string("Opens Slack with Yardlet's manifest filled in: pick your workspace, press Next, then Create. It has the redirect URL, the 30 user scopes Slack's MCP server uses, MCP on, and PKCE."),
                 link: Link(title: L10n.string("Create in Slack"), url: SlackAppManifest.createURL),
                 copies: [Copy(label: L10n.string("Manifest"), value: SlackAppManifest.prettyJSON),
                          Copy(label: L10n.string("Redirect URL"), value: SlackAppManifest.redirectURL)],
                 isDone: opened.contains(.slackCreate) || clientEntered || connected),
            Step(id: .slackCredentials, title: L10n.string("Paste the client ID"),
                 detail: L10n.string("In the new app, Basic Information → App Credentials → Client ID. A PKCE app needs no secret."),
                 link: Link(title: L10n.string("Your Slack apps"), url: SlackAppManifest.appsURL),
                 isDone: clientEntered || connected),
            Step(id: .slackSignIn, title: L10n.string("Sign in to Slack"),
                 detail: L10n.string("Slack asks to allow Yardlet in your workspace. If your workspace needs an admin's approval, ask for it there."),
                 isDone: connected)
        ])
    }

    // MARK: Zoom

    /// Zoom App Marketplace → Develop → Build App.
    static let zoomCreate = URL(string: "https://marketplace.zoom.us/develop/create")!

    /// The Zoom products in the directory, in its order.
    static var zoomPresets: [ConnectorPreset] { ConnectorPreset.all.filter(\.isZoom) }

    /// The scopes the chosen products ask for, one per line, as the app's Scopes page takes them.
    static func zoomScopeList(_ products: [ConnectorPreset]) -> String {
        products.flatMap { ($0.scope ?? "").split(separator: " ").map(String.init) }.joined(separator: "\n")
    }

    static func zoom(opened: Set<StepID>, products: [ConnectorPreset], clientEntered: Bool, connected: Bool) -> ConnectorSetupAssistant {
        ConnectorSetupAssistant(service: .zoom, steps: [
            Step(id: .zoomCreate, title: L10n.string("Create a Zoom app"),
                 detail: L10n.string("Zoom App Marketplace → Develop → Build App → General App, user-managed. Under OAuth, add the redirect URL below to the redirect URL and the allow list."),
                 link: Link(title: L10n.string("Build an app on Zoom"), url: zoomCreate),
                 copies: [Copy(label: L10n.string("App name"), value: appName),
                          Copy(label: L10n.string("Redirect URL"), value: ConnectorOAuth.registeredClientRedirectURI.absoluteString)],
                 isDone: opened.contains(.zoomCreate) || clientEntered || connected),
            Step(id: .zoomScopes, title: L10n.string("Add the scopes"),
                 detail: L10n.string("Scopes → Add Scopes: the ones below for the products you connect. Yardlet asks Zoom only to read."),
                 copies: [Copy(label: L10n.string("Scopes"), value: zoomScopeList(products))],
                 isDone: opened.contains(.zoomScopes) || clientEntered || connected),
            Step(id: .zoomCredentials, title: L10n.string("Paste the client ID and secret"),
                 detail: L10n.string("App Credentials → Client ID and Client Secret. Your keychain keeps the secret."),
                 isDone: clientEntered || connected),
            Step(id: .zoomSignIn, title: L10n.string("Sign in to Zoom"),
                 detail: L10n.string("Each product signs in once in your browser."), isDone: connected)
        ])
    }

    // MARK: App Store Connect

    /// Users and Access → Integrations → App Store Connect API.
    static let appStoreConnectKeys = URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!
    /// Apple's "Creating API Keys for App Store Connect API".
    static let appStoreConnectKeyGuide =
        URL(string: "https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api")!

    /// Making an API key in App Store Connect, choosing its private key file here, and connecting.
    /// The steps are for the key being added: a key connected before lists above them.
    static func appStoreConnect(opened: Set<StepID>, keyChosen: Bool) -> ConnectorSetupAssistant {
        ConnectorSetupAssistant(service: .appStoreConnect, steps: [
            Step(id: .ascCreateKey, title: L10n.string("Create an API key in App Store Connect"),
                 detail: L10n.string("Users and Access → Integrations → App Store Connect API. An Account Holder or Admin makes a team key and picks its role: Admin covers every tool here, App Manager all but answering reviews. An individual key, made in your profile, has your own access."),
                 link: Link(title: L10n.string("Open App Store Connect"), url: appStoreConnectKeys),
                 isDone: opened.contains(.ascCreateKey) || keyChosen),
            Step(id: .ascKeyFile, title: L10n.string("Choose the key file and enter its IDs"),
                 detail: L10n.string("App Store Connect lets you download the .p8 file once. Yardlet reads the key ID from the file's name; a team key also needs the issuer ID shown above the keys."),
                 isDone: keyChosen),
            Step(id: .ascConnect, title: L10n.string("Connect"),
                 detail: L10n.string("Yardlet keeps the key in your keychain and reads your app list once to check it."),
                 isDone: false)
        ])
    }

    // MARK: Mail over IMAP

    static let mailServiceSteps: [StepID] = [.mailService1, .mailService2, .mailService3]

    /// A mail account's setup: what the chosen service asks first on its website (`MailServerPreset.steps`),
    /// then the address and app password, then the check. A website step counts as done once its page
    /// was opened or ticked, and every one once the account connected.
    static func mail(_ preset: MailServerPreset?, opened: Set<StepID>, accountEntered: Bool) -> ConnectorSetupAssistant {
        let serviceSteps = (preset?.steps ?? []).prefix(mailServiceSteps.count).enumerated().map { index, step in
            let id = mailServiceSteps[index]
            return Step(id: id, title: L10n.string(step.text), detail: nil,
                        link: step.link.map { Link(title: L10n.string("Open"), url: $0) },
                        isDone: opened.contains(id) || accountEntered)
        }
        return ConnectorSetupAssistant(service: .mail, steps: serviceSteps + [
            Step(id: .mailAccount, title: L10n.string("Enter the address and the app password"),
                 detail: L10n.string("The app password the service made, not the password you sign in to its website with."),
                 isDone: accountEntered),
            Step(id: .mailConnect, title: L10n.string("Connect"),
                 detail: L10n.string("Yardlet signs in to the mail server once to check it, and keeps the password in your keychain."),
                 isDone: false)
        ])
    }

    // MARK: Fields

    enum Validation: Equatable {
        case empty
        case valid
        case invalid(String)

        var isValid: Bool { self == .valid }
        var message: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A Google OAuth client ID: `<number>-<letters and digits>.apps.googleusercontent.com`.
    static func validateGoogleClientID(_ text: String) -> Validation {
        let value = trimmed(text)
        guard !value.isEmpty else { return .empty }
        if value.hasPrefix("GOCSPX-") { return .invalid(L10n.string("That is the client secret; the client ID ends with .apps.googleusercontent.com.")) }
        let suffix = ".apps.googleusercontent.com"
        guard value.hasSuffix(suffix), value.count > suffix.count,
              value.dropLast(suffix.count).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            return .invalid(L10n.string("A Google client ID ends with .apps.googleusercontent.com."))
        }
        return .valid
    }

    /// A Google client secret: not empty, no spaces, and not the client ID pasted twice.
    static func validateGoogleSecret(_ text: String) -> Validation {
        let value = trimmed(text)
        guard !value.isEmpty else { return .empty }
        if value.hasSuffix(".apps.googleusercontent.com") {
            return .invalid(L10n.string("That is the client ID; the secret is the other value, often starting with GOCSPX-."))
        }
        guard !value.contains(where: \.isWhitespace), value.count >= 16 else {
            return .invalid(L10n.string("The client secret looks cut off."))
        }
        return .valid
    }

    /// A Slack client ID: two runs of digits with a dot between, `123456789012.1234567890123`.
    static func validateSlackClientID(_ text: String) -> Validation {
        let value = trimmed(text)
        guard !value.isEmpty else { return .empty }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            return .invalid(L10n.string("A Slack client ID is two numbers with a dot between, like 123.456."))
        }
        return .valid
    }

    /// An App Store Connect key ID: ten capital letters and digits.
    static func validateAppStoreKeyID(_ text: String) -> Validation {
        let value = trimmed(text)
        guard !value.isEmpty else { return .empty }
        return AppStoreConnectKey.isKeyID(value.uppercased()) ? .valid
            : .invalid(L10n.string("A key ID is 10 letters and digits, such as 2X9R4HXF34."))
    }

    /// An App Store Connect issuer ID: a UUID.
    static func validateIssuerID(_ text: String) -> Validation {
        let value = trimmed(text)
        guard !value.isEmpty else { return .empty }
        return UUID(uuidString: value) != nil ? .valid
            : .invalid(L10n.string("An issuer ID looks like 57246542-96fe-1a63-e053-0824d011072a."))
    }

    /// A Microsoft application (client) ID: a GUID.
    static func validateMicrosoftClientID(_ text: String) -> Validation {
        let value = trimmed(text)
        guard !value.isEmpty else { return .empty }
        return UUID(uuidString: value) != nil ? .valid
            : .invalid(L10n.string("An application ID looks like 11111111-2222-3333-4444-555555555555."))
    }

    /// A Microsoft directory (tenant): empty for any organization and personal accounts, a GUID, or
    /// a domain such as contoso.onmicrosoft.com.
    static func validateMicrosoftTenant(_ text: String) -> Validation {
        let value = trimmed(text)
        guard !value.isEmpty else { return .empty }
        let domain = value.contains(".") && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        return UUID(uuidString: value) != nil || domain || ["common", "organizations", "consumers"].contains(value.lowercased())
            ? .valid : .invalid(L10n.string("A directory ID is a GUID or a domain such as contoso.onmicrosoft.com."))
    }

    /// A Zoom client ID: letters, digits, `_` and `-`.
    static func validateZoomClientID(_ text: String) -> Validation {
        let value = trimmed(text)
        guard !value.isEmpty else { return .empty }
        return value.count >= 10 && value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
            ? .valid : .invalid(L10n.string("A Zoom client ID is letters and digits, such as aBcD1234EfGh5678."))
    }

    /// A Zoom client secret: no spaces, and not cut off.
    static func validateZoomSecret(_ text: String) -> Validation {
        let value = trimmed(text)
        guard !value.isEmpty else { return .empty }
        return value.count >= 16 && !value.contains(where: \.isWhitespace) ? .valid
            : .invalid(L10n.string("The client secret looks cut off."))
    }

    /// A Slack client secret, only for an app without PKCE: 32 hexadecimal digits.
    static func validateSlackSecret(_ text: String) -> Validation {
        let value = trimmed(text)
        guard !value.isEmpty else { return .empty }
        guard value.count == 32, value.allSatisfy(\.isHexDigit) else {
            return .invalid(L10n.string("A Slack client secret is 32 letters and digits (0–9, a–f)."))
        }
        return .valid
    }
}
