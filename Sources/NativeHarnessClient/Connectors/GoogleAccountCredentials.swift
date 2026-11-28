import Foundation

/// Both grants share a Keychain item so removing an account removes its secrets in one operation.
/// Serialize read-modify-write operations across sessions refreshing the two grants independently.
struct GoogleAccountCredentials: Sendable {
    private static let lock = NSLock()
    let store: any ConnectorCredentialStoring
    let tokenEndpoint: URL
    let builtInClientID: String?

    func update<T>(_ id: UUID, _ change: (inout ConnectorCredential?) throws -> T) throws -> T {
        try Self.lock.withLock {
            var value = try store.load(id)
            let previous = value
            let result = try change(&value)
            if value != previous {
                if let value { try store.save(value, for: id) }
                else { try store.delete(id) }
            }
            return result
        }
    }

    struct Migration: Sendable {
        let builtIn: Bool
        let calendar: Bool
        let mailbox: Bool
    }

    /// Prepare the one-time Keychain work alongside snapshot decoding, before any record is
    /// published to the native screens or agent tool lists.
    func migrations(in saved: ConnectorSavedSettings, builtIn: GoogleOAuth.BuiltInApp?) -> [UUID: Result<Migration, Error>] {
        let groups = Dictionary(grouping: saved.connectors.filter(\.isGoogle), by: \.credentialID)
        var results = [UUID: Result<Migration, Error>]()
        let sharedClient = saved.googleAppClientID == builtIn?.clientID ? nil : saved.googleAppClientID
        for (id, records) in groups where records.contains(where: { $0.googleUISignIn == nil }) {
            let personal = records.compactMap(\.googleOAuthClientID).first
            let custom = personal.flatMap { $0 == builtIn?.clientID ? nil : $0 } ?? sharedClient
            guard custom != nil || builtIn != nil else { continue }
            results[id] = Result {
                try update(id) { value in
                    let client = value?.clientID ?? value?.uiClientID ?? custom ?? builtIn?.clientID
                    let isBuiltIn = builtIn != nil && client == builtIn?.clientID
                    guard var stored = value else { return Migration(builtIn: isBuiltIn, calendar: false, mailbox: false) }
                    let services = Set(records.filter {
                        $0.googleAgentDisabled != true && (stored.scope == nil ? $0.status == .connected : $0.status != .notConnected)
                    }.compactMap(\.localService))
                    if stored.kind == .oauth, !stored.accessToken.isEmpty {
                        stored.clientID = client
                        if stored.clientSecret == nil {
                            if isBuiltIn { stored.clientSecret = builtIn?.clientSecret }
                            else if let app = try store.load(GoogleOAuth.appCredentialID), app.clientID == client {
                                stored.clientSecret = app.clientSecret
                            }
                        }
                        if stored.tokenEndpoint == nil { stored.tokenEndpoint = tokenEndpoint }
                        if stored.tokenEndpointAuthMethod == nil, stored.clientSecret != nil {
                            stored.tokenEndpointAuthMethod = "client_secret_post"
                        }
                        let calendar = (personal == nil || isBuiltIn) && services.contains(.googleCalendar)
                            && GoogleOAuth.grantedServices(stored.scope, of: [.googleCalendar]).contains(.googleCalendar)
                        let mailbox = personal == nil && !isBuiltIn && services.contains(.gmail)
                            && GoogleOAuth.grants(stored.scope, all: GoogleOAuth.mailboxScope)
                        if stored.uiAccessToken == nil && (calendar || mailbox) {
                            var standard = stored
                            // Older grants omitted the scope string. Limit their native use to the
                            // services that were actually connected in that snapshot.
                            if standard.scope == nil {
                                var scopes = calendar ? LocalConnectorService.googleCalendar.scopes : []
                                if mailbox { scopes.append(GoogleOAuth.mailboxScope) }
                                standard.scope = scopes.joined(separator: " ")
                            }
                            stored.setCalendarGrant(standard)
                        }
                        if isBuiltIn {
                            stored.clearAgentGrant()
                            stored.clientID = nil
                            stored.clientSecret = nil
                        }
                        value = stored
                    }
                    let grant = stored.calendarGrant(endpoint: tokenEndpoint)
                    let calendar = grant != nil && services.contains(.googleCalendar)
                        && GoogleOAuth.grantedServices(grant?.scope, of: [.googleCalendar]).contains(.googleCalendar)
                    let mailbox = grant != nil && !isBuiltIn && services.contains(.gmail)
                        && GoogleOAuth.grants(grant?.scope, all: GoogleOAuth.mailboxScope)
                    return Migration(builtIn: isBuiltIn, calendar: calendar, mailbox: mailbox)
                }
            }
        }
        return results
    }

    func saveAgent(_ agent: ConnectorCredential, for id: UUID) throws {
        try update(id) { value in
            var next = agent
            next.keepUIGrants(from: value, endpoint: tokenEndpoint)
            value = next
        }
    }

    func sessionStore(_ purpose: GoogleGrantStore.Purpose) -> GoogleGrantStore {
        GoogleGrantStore(account: self, purpose: purpose)
    }
}

/// A migrated Mailbox grant survives a later Calendar-only sign-in on the same account.
struct GoogleMailboxGrant: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var clientID: String
    var clientSecret: String?
    var scope: String?

    init?(_ grant: ConnectorCredential?) {
        guard let grant, let clientID = grant.clientID else { return nil }
        self.clientID = clientID
        accessToken = grant.accessToken
        refreshToken = grant.refreshToken
        expiresAt = grant.expiresAt
        clientSecret = grant.clientSecret
        scope = grant.scope
    }

    func credential(endpoint: URL) -> ConnectorCredential {
        ConnectorCredential(kind: .oauth, accessToken: accessToken, refreshToken: refreshToken,
                            expiresAt: expiresAt, scope: scope, clientID: clientID, clientSecret: clientSecret,
                            tokenEndpoint: endpoint, tokenEndpointAuthMethod: clientSecret == nil ? "none" : "client_secret_post")
    }
}

extension ConnectorCredential {
    func calendarGrant(endpoint: URL) -> ConnectorCredential? {
        guard let token = uiAccessToken, let client = uiClientID else { return nil }
        return ConnectorCredential(kind: .oauth, accessToken: token, refreshToken: uiRefreshToken,
                                   expiresAt: uiExpiresAt, scope: uiGrantedScopes, clientID: client,
                                   clientSecret: uiClientSecret, tokenEndpoint: endpoint,
                                   tokenEndpointAuthMethod: uiClientSecret == nil ? "none" : "client_secret_post")
    }

    mutating func keepUIGrants(from previous: ConnectorCredential?, endpoint: URL) {
        setCalendarGrant(previous?.calendarGrant(endpoint: endpoint))
        uiMailboxGrant = previous?.uiMailboxGrant
    }

    mutating func setCalendarGrant(_ grant: ConnectorCredential?) {
        uiAccessToken = grant?.accessToken
        uiRefreshToken = grant?.refreshToken
        uiExpiresAt = grant?.expiresAt
        uiClientID = grant?.clientID
        uiClientSecret = grant?.clientSecret
        uiGrantedScopes = grant?.scope
    }

    mutating func clearAgentGrant() {
        kind = .client
        accessToken = ""
        refreshToken = nil
        expiresAt = nil
        scope = nil
        refreshScope = nil
    }
}

struct GoogleGrantStore: ConnectorCredentialStoring {
    let account: GoogleAccountCredentials
    enum Purpose: Hashable { case agent, calendar, mailbox }
    let purpose: Purpose

    private func project(_ current: ConnectorCredential) -> ConnectorCredential? {
        switch purpose {
        case .agent:
            guard let client = current.clientID, client != account.builtInClientID else { return nil }
            var agent = current
            agent.keepUIGrants(from: nil, endpoint: account.tokenEndpoint)
            return agent
        case .calendar:
            let grant = current.calendarGrant(endpoint: account.tokenEndpoint)
            guard let grant, GoogleOAuth.grantedServices(grant.scope, of: [.googleCalendar]).contains(.googleCalendar) else { return nil }
            return grant
        case .mailbox:
            let grant = current.uiMailboxGrant?.credential(endpoint: account.tokenEndpoint)
                ?? current.calendarGrant(endpoint: account.tokenEndpoint)
            guard let grant, grant.clientID != account.builtInClientID,
                  GoogleOAuth.grants(grant.scope, all: GoogleOAuth.mailboxScope) else { return nil }
            return grant
        }
    }

    func load(_ id: UUID) throws -> ConnectorCredential? {
        try account.update(id) { $0.flatMap(project) }
    }

    private func assign(_ grant: ConnectorCredential?, to current: inout ConnectorCredential) {
        switch purpose {
        case .agent:
            if var next = grant {
                next.keepUIGrants(from: current, endpoint: account.tokenEndpoint)
                current = next
            } else { current.clearAgentGrant() }
        case .calendar:
            current.setCalendarGrant(grant)
        case .mailbox:
            if current.uiMailboxGrant != nil { current.uiMailboxGrant = GoogleMailboxGrant(grant) }
            else { current.setCalendarGrant(grant) }
        }
    }

    /// A delayed refresh cannot restore credentials superseded by a disconnect or sign-in.
    func replace(_ original: ConnectorCredential, with refreshed: ConnectorCredential?, for id: UUID) throws -> Bool {
        try account.update(id) { value in
            guard var current = value, let projected = project(current),
                  projected.refreshToken == original.refreshToken, projected.clientID == original.clientID,
                  projected.accessToken == original.accessToken else { return false }
            assign(refreshed, to: &current)
            value = current
            return true
        }
    }

    func save(_ credential: ConnectorCredential, for id: UUID) throws {
        try account.update(id) { value in
            guard var current = value else { return }
            assign(credential, to: &current)
            value = current
        }
    }

    func delete(_ id: UUID) throws {
        try account.update(id) { value in
            guard var current = value else { return }
            assign(nil, to: &current)
            value = current
        }
    }
}
