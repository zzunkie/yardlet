import Foundation

/// Where items' secrets are kept: the login keychain on macOS (`KeychainVaultSecretStore`), memory
/// in tests and QA runs.
protocol VaultSecretStoring {
    func load(_ id: UUID) throws -> VaultSecret?
    func save(_ secret: VaultSecret, for id: UUID) throws
    func delete(_ id: UUID) throws
    func deleteAll() throws
}

final class InMemoryVaultSecretStore: VaultSecretStoring {
    private var secrets: [UUID: VaultSecret] = [:]

    init(_ secrets: [UUID: VaultSecret] = [:]) {
        self.secrets = secrets
    }

    func load(_ id: UUID) throws -> VaultSecret? { secrets[id] }
    func save(_ secret: VaultSecret, for id: UUID) throws { secrets[id] = secret }
    func delete(_ id: UUID) throws { secrets[id] = nil }
    func deleteAll() throws { secrets = [:] }
}

/// One use of an item, as the usage log keeps it (design §6.3). No value is ever written here.
struct VaultUse: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case filled, refused }
    /// How the fill was allowed.
    enum Confirmation: String, Codable, Sendable { case always, unlocked, touchID, person }

    var at: Date
    var taskID: UUID?
    var taskTitle: String?
    var harness: String?
    var itemID: UUID?
    var itemName: String?
    var origin: String
    var kinds: [String]
    var outcome: Outcome
    var reason: String?
    var confirmedBy: Confirmation?
}

/// The items (no secrets) and their usage log.
protocol VaultRepository {
    func loadItems() -> [VaultItem]
    func saveItems(_ items: [VaultItem])
    func appendUse(_ use: VaultUse)
    func uses(of itemID: UUID, limit: Int) -> [VaultUse]
    /// Every use the log keeps, oldest first.
    func allUses() -> [VaultUse]
    func removeAll()
}

/// `~/.yardlet/vault/items.json` and `usage.jsonl` (90 days).
struct FileVaultRepository: VaultRepository {
    let directory: URL
    var keepUses: TimeInterval = 90 * 24 * 60 * 60

    static func live(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> FileVaultRepository {
        FileVaultRepository(directory: homeURL
            .appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
            .appending(path: "vault", directoryHint: .isDirectory))
    }

    private var itemsURL: URL { directory.appending(path: "items.json") }
    private var usesURL: URL { directory.appending(path: "usage.jsonl") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func prepareDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    func loadItems() -> [VaultItem] {
        guard let data = try? Data(contentsOf: itemsURL) else { return [] }
        return (try? Self.decoder.decode([VaultItem].self, from: data)) ?? []
    }

    func saveItems(_ items: [VaultItem]) {
        prepareDirectory()
        guard let data = try? Self.encoder.encode(items) else { return }
        try? data.write(to: itemsURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: itemsURL.path(percentEncoded: false))
    }

    func appendUse(_ use: VaultUse) {
        prepareDirectory()
        var lines = readUses()
        lines.append(use)
        let cutoff = use.at.addingTimeInterval(-keepUses)
        lines.removeAll { $0.at < cutoff }
        let text = lines.compactMap { try? Self.encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(to: usesURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: usesURL.path(percentEncoded: false))
    }

    private func readUses() -> [VaultUse] {
        guard let text = try? String(contentsOf: usesURL, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { try? Self.decoder.decode(VaultUse.self, from: Data($0.utf8)) }
    }

    func uses(of itemID: UUID, limit: Int) -> [VaultUse] {
        Array(readUses().filter { $0.itemID == itemID }.suffix(limit).reversed())
    }

    func allUses() -> [VaultUse] { readUses() }

    func removeAll() {
        try? FileManager.default.removeItem(at: itemsURL)
        try? FileManager.default.removeItem(at: usesURL)
    }
}

final class InMemoryVaultRepository: VaultRepository {
    private(set) var items: [VaultItem]
    private(set) var uses: [VaultUse] = []

    init(items: [VaultItem] = []) {
        self.items = items
    }

    func loadItems() -> [VaultItem] { items }
    func saveItems(_ items: [VaultItem]) { self.items = items }
    func appendUse(_ use: VaultUse) { uses.append(use) }
    func uses(of itemID: UUID, limit: Int) -> [VaultUse] { Array(uses.filter { $0.itemID == itemID }.suffix(limit).reversed()) }
    func allUses() -> [VaultUse] { uses }
    func removeAll() {
        items = []
        uses = []
    }
}

/// What an agent's `browser_fill_credential` fills.
enum VaultFillKind: String, Sendable {
    case login
    case oneTimeCode = "one_time_code"
    case passkey
    /// A new password Yardlet makes for a sign-up form, saved as a new item (design §15).
    case newPassword = "new_password"
}

private extension VaultItem {
    /// Whether the item has what a fill of this kind needs.
    func has(_ kind: VaultFillKind) -> Bool {
        switch kind {
        case .login: hasPassword
        case .oneTimeCode: hasOneTimeCode
        case .passkey: hasPasskey
        }
    }
}

/// One fill an agent asks for: the page's origin comes from the browser, never from the model.
struct VaultFillRequest: Sendable {
    var sessionID: UUID
    var itemName: String?
    var kind: VaultFillKind
    var origin: String
    /// The agent ran its own scripts in the document to fill, or in a tab linked to it by `window.opener`: a script
    /// set there before the fill could take the value, so the person confirms whatever the item's policy.
    var afterAgentScript = false
}

/// The values for one allowed fill. They go into the page and nowhere else.
struct VaultFillGrant {
    var item: VaultItem
    var username: String?
    var password: String?
    var code: String?
    var passkey: VaultPasskey?
    var confirmedBy: VaultUse.Confirmation
}

/// A refused fill, in words for the agent.
struct VaultRefusal: Error, Equatable {
    var message: String
}

/// An item whose sites or agent policy in `items.json` are not the ones saved with its secret.
struct VaultChangedOutside: Error {}

/// The vault for agents (docs/BROWSER_VAULT_DESIGN.md): the person's items, whether the vault is on,
/// the decision for each fill, and the usage log. The page work is `BrowserAgentTools`'s.
@MainActor
final class VaultCenter: ObservableObject {
    struct Environment {
        var secrets: any VaultSecretStoring
        var repository: any VaultRepository
        /// Read only when a site is suggested or checked, not when the app starts.
        var suffixes: @Sendable () -> PublicSuffixList = { .bundled }
        /// The keyed hash TOTP codes need (CryptoKit on macOS).
        var hmac: OneTimeCode.HMAC
        /// Only a team-signed build keeps its items behind the keychain's code requirement (design §4.3).
        var isAllowedBuild: Bool
        /// Asks the person at this Mac (Touch ID, or the login password) and says whether they confirmed.
        var confirm: @MainActor (_ reason: String) async -> Bool = { _ in false }
        /// Secure random bytes for new passwords (`SecRandomCopyBytes` on macOS).
        var randomBytes: VaultPasswordGenerator.RandomBytes = VaultPasswordGenerator.systemRandomBytes
        var now: () -> Date = Date.init
        var defaults: UserDefaults = .yardlet
    }

    static let enabledKey = "Yardlet.vault.enabled"

    private var environment: Environment
    @Published private(set) var items: [VaultItem]
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            environment.defaults.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { onTurnedOff?() }
            onToolsChanged?()
        }
    }
    /// Whether a "while unlocked" item fills without asking. Touch ID unlocks it; the screen locking
    /// or the Mac sleeping locks it (design §6.4).
    private(set) var isUnlocked = false
    /// The task's title and harness, for the usage log and the words the person sees.
    var describeTask: @MainActor (UUID) -> (title: String, harness: String)? = { _ in nil }
    /// A system notification that opens the task when clicked (the app sets it).
    var notify: @MainActor (_ title: String, _ body: String, _ taskID: UUID?) -> Void = { _, _, _ in }
    /// The tool list a task gets may have changed (on, off, first or last item).
    var onToolsChanged: (() -> Void)?
    /// The vault was turned off: anything armed for a fill is let go (passkey authenticators).
    var onTurnedOff: (() -> Void)?

    init(environment: Environment) {
        self.environment = environment
        items = environment.repository.loadItems()
        isEnabled = environment.defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    var isAllowedBuild: Bool { environment.isAllowedBuild }

    /// Whether tasks get `browser_fill_credential`: a team-signed build with the vault on and an item in it.
    var offersTool: Bool { environment.isAllowedBuild && isEnabled && !items.isEmpty }

    var suffixes: PublicSuffixList { environment.suffixes() }

    func lock() {
        isUnlocked = false
    }

    // MARK: Agent fills

    /// Decides one agent fill and, when allowed, gives the values. A refusal is logged here; a grant
    /// is logged by `record(_:for:filled:)` once the page took it.
    func authorize(_ request: VaultFillRequest) async -> Result<VaultFillGrant, VaultRefusal> {
        let host = VaultSite.host(of: request.origin)
        guard environment.isAllowedBuild, isEnabled else {
            return refuse(request, item: nil, "Yardlet's password manager is off in its settings.")
        }
        let onSite = items.filter { item in item.sites.contains { VaultSite.matches($0, origin: request.origin) } }
        // A site's password and its two-factor code are often two items (a code brought over from an
        // authenticator app keeps an item of its own), so only the items that have what is asked for are
        // weighed, unless none has it.
        let able = onSite.filter { $0.has(request.kind) }
        let matching = able.isEmpty ? onSite : able
        let item: VaultItem
        if let name = request.itemName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            // Several accounts on one site often share its name (an import names items by site), so an item
            // is named by its name or its username.
            func isNamed(_ item: VaultItem) -> Bool {
                item.name.compare(name, options: [.caseInsensitive]) == .orderedSame
                    || !item.username.isEmpty && item.username.compare(name, options: [.caseInsensitive]) == .orderedSame
            }
            let here = matching.filter(isNamed)
            guard here.count < 2 else {
                return refuse(request, item: nil, "Several items for \(host) are named “\(name)”: "
                    + here.map(Self.label).joined(separator: ", ") + ". Name one by its username.")
            }
            guard let named = here.first ?? onSite.first(where: isNamed) ?? items.first(where: isNamed) else {
                return refuse(request, item: nil, "No saved item is named “\(name)”."
                    + (matching.isEmpty ? "" : " Items for \(host): " + matching.map(Self.label).joined(separator: ", ") + "."))
            }
            guard onSite.contains(where: { $0.id == named.id }) else {
                // An item with no site yet, such as a code from an authenticator app, is for no page until the
                // person fills it on one; asking for it is no phishing sign.
                if named.sites.isEmpty {
                    return refuse(request, item: named, "“\(named.name)” has no site saved yet, so Yardlet does not fill "
                        + "it for an agent. " + Self.personLinks(host))
                }
                // An item named for another site: a page asking for it is a phishing sign, so the person hears of it.
                let title = describeTask(request.sessionID)?.title ?? L10n.string("A task")
                notify(L10n.string("Not filled on another site"),
                                   L10n.format("“%@” asked for “%@” on %@, which is not one of its sites.", title, named.name, host),
                                   request.sessionID)
                // Its own sites stay unsaid: a name guessed on one page would otherwise tell where it signs in.
                return refuse(request, item: named, "“\(named.name)” is not saved for \(host), so Yardlet did not fill it.")
            }
            item = named
        } else {
            guard let only = matching.first else {
                return refuse(request, item: nil, "No item is saved for \(host)." + unlinkedCodes(request))
            }
            guard matching.count == 1 else {
                return refuse(request, item: nil, "Several items are saved for \(host): "
                    + matching.map(Self.label).joined(separator: ", ") + ". Name one with item, by its name or username.")
            }
            item = only
        }
        switch request.kind {
        case .login where !item.hasPassword && item.username.isEmpty:
            return refuse(request, item: item, "“\(item.name)” has no username or password.")
        case .oneTimeCode where !item.hasOneTimeCode:
            return refuse(request, item: item, "“\(item.name)” has no one-time code set up." + unlinkedCodes(request))
        case .passkey where !item.hasPasskey:
            return refuse(request, item: item, "“\(item.name)” has no passkey.")
        default:
            break
        }
        let confirmation: VaultUse.Confirmation
        switch item.policy {
        case .always where !request.afterAgentScript:
            confirmation = .always
        case .whileUnlocked where isUnlocked && !request.afterAgentScript:
            confirmation = .unlocked
        default:
            let title = describeTask(request.sessionID)?.title ?? L10n.string("A task")
            notify(L10n.string("Waiting for you to sign in"),
                               L10n.format("“%@” is waiting to sign in to %@ with “%@”.", title, host, item.name),
                               request.sessionID)
            let reason = request.afterAgentScript
                ? L10n.format("fill “%@” on %@ for “%@”, on a page where it ran its own scripts", item.name, host, title)
                : L10n.format("fill “%@” on %@ for “%@”", item.name, host, title)
            guard await environment.confirm(reason) else {
                guard request.afterAgentScript else {
                    return refuse(request, item: item, "The person at this Mac did not confirm filling “\(item.name)”, "
                        + "so Yardlet did not fill it.")
                }
                return refuse(request, item: item, "You ran your own scripts on this page (browser_evaluate here or in a tab "
                    + "linked to it), so Yardlet asked the person before filling “\(item.name)”, and they did not confirm. "
                    + "Reload the page (browser_navigate to its address) and fill it without running scripts on it first.")
            }
            if item.policy == .whileUnlocked { isUnlocked = true }
            confirmation = .touchID
        }
        let secret: VaultSecret?
        do {
            secret = try trustedSecret(of: item)
        } catch is VaultChangedOutside {
            return refuse(request, item: item, "“\(item.name)”'s sites or agent use were changed outside Yardlet, so it fills "
                + "nothing until the person opens it in Yardlet's settings and saves it again.")
        } catch {
            return refuse(request, item: item, "Yardlet could not read “\(item.name)” from the keychain.")
        }
        var grant = VaultFillGrant(item: item, confirmedBy: confirmation)
        switch request.kind {
        case .login:
            grant.username = item.username.isEmpty ? nil : item.username
            grant.password = secret?.password
        case .oneTimeCode:
            guard let code = secret?.oneTimeCode else {
                return refuse(request, item: item, "“\(item.name)” has no one-time code set up.")
            }
            grant.code = OneTimeCode.code(for: code, at: environment.now(), hmac: environment.hmac)
        case .passkey:
            guard let passkey = secret?.passkey else { return refuse(request, item: item, "“\(item.name)” has no passkey.") }
            grant.passkey = passkey
        case .newPassword:
            return refuse(request, item: item, "A new password is made for a sign-up form, not filled from “\(item.name)”.")
        }
        return .success(grant)
    }

    // MARK: New passwords (design §15)

    /// How many replaced passwords an item keeps.
    static let previousPasswordsKept = 5

    /// A strong password for a new-password field, within the site's `passwordrules` and the field's
    /// `minlength` and `maxlength` (0 or less for none); nil when the system's random source fails.
    func makePassword(rules: String?, minLength: Int, maxLength: Int) -> String? {
        VaultPasswordGenerator.generate(rules: rules.flatMap(PasswordRules.init), fieldMinLength: minLength,
                                        fieldMaxLength: maxLength, random: environment.randomBytes)
    }

    /// Decides an agent's new password for a sign-up form whose username field holds `username`. It goes into
    /// a new item; a saved item of that username or of the name asked for is the person's to change, since
    /// Yardlet cannot tell whether the site took a change, and the person's update after it is what makes
    /// a new password the item's.
    /// A page where the agent ran its own scripts asks the person first, as a saved password's fill does.
    func authorizeNewPassword(_ request: VaultFillRequest, username: String) async -> Result<VaultUse.Confirmation, VaultRefusal> {
        let host = VaultSite.host(of: request.origin)
        guard environment.isAllowedBuild, isEnabled else {
            return refuse(request, item: nil, "Yardlet's password manager is off in its settings.").map { _ in .always }
        }
        guard VaultSite.suggestion(for: request.origin, suffixes: suffixes) != nil else {
            return refuse(request, item: nil, "Yardlet saves new passwords only for https sites, so it made none for \(host).")
                .map { _ in .always }
        }
        let here = items(for: request.origin)
        let name = request.itemName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let saved = here.first { item in
            !name.isEmpty && (item.name.compare(name, options: .caseInsensitive) == .orderedSame
                || item.username.compare(name, options: .caseInsensitive) == .orderedSame)
                || !username.isEmpty && item.username.compare(username, options: .caseInsensitive) == .orderedSame
        }
        if let saved {
            return refuse(request, item: saved, "\(Self.label(saved)) is already saved for \(host). Yardlet makes a new "
                + "password only for a new account; changing a saved one is for the person at this Mac, so hand them the tab.")
                .map { _ in .always }
        }
        guard request.afterAgentScript else { return .success(.always) }
        let title = describeTask(request.sessionID)?.title ?? L10n.string("A task")
        notify(L10n.string("Waiting for you to sign in"),
               L10n.format("“%@” is waiting to make a password for %@.", title, host), request.sessionID)
        guard await environment.confirm(L10n.format("make a password for %@ for “%@”, on a page where it ran its own scripts",
                                                   host, title)) else {
            return refuse(request, item: nil, "You ran your own scripts on this page (browser_evaluate here or in a tab "
                + "linked to it), so Yardlet asked the person before making a password, and they did not confirm. Reload "
                + "the page (browser_navigate to its address) and fill it without running scripts on it first.")
                .map { _ in .always }
        }
        return .success(.touchID)
    }

    /// Logs an agent's fill refused outside `authorize`, such as a new password for a form that sends elsewhere.
    func recordRefusal(_ request: VaultFillRequest, _ message: String) {
        _ = refuse(request, item: nil, message)
    }

    /// Keeps a password Yardlet made the moment it goes into a page (Chrome's presave): in `presaved`, an
    /// item this page took a made password into before, else in a new item for the site named `name` (its
    /// host by default). Beside a saved item of the same username, the new item goes without the username,
    /// as Chrome's does, so the saved password stays the one filled until the person updates it.
    @discardableResult
    func presaveMadePassword(_ password: String, origin: String, username: String, name: String? = nil,
                             into presaved: UUID? = nil) throws -> VaultItem {
        guard let site = VaultSite.suggestion(for: origin, suffixes: suffixes) else {
            throw VaultRefusal(message: "Yardlet saves new passwords only for https sites.")
        }
        let here = items(for: origin)
        let taken = !username.isEmpty && here.contains { $0.id != presaved && $0.username == username }
        if let presaved, var item = here.first(where: { $0.id == presaved }) {
            if item.username.isEmpty, !taken { item.username = username }
            var secret = (try trustedSecret(of: item)) ?? VaultSecret()
            secret.password = password
            try save(item, secret: secret)
            return item
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let item = VaultItem(name: trimmed.isEmpty ? VaultSite.host(of: origin) : trimmed, sites: [site],
                             username: taken ? "" : username)
        try save(item, secret: VaultSecret(password: password))
        return item
    }

    /// Logs a fill the page took (or failed to take after the grant), and counts the item as used.
    func record(_ grant: VaultFillGrant, for request: VaultFillRequest, filled kinds: [String], failure: String? = nil) {
        log(request, item: grant.item, kinds: kinds, outcome: failure == nil ? .filled : .refused,
            reason: failure, confirmedBy: grant.confirmedBy)
        guard failure == nil, let index = items.firstIndex(where: { $0.id == grant.item.id }) else { return }
        items[index].lastUsedAt = environment.now()
        environment.repository.saveItems(items)
    }

    /// A passkey's signature count after the site accepted it.
    func updatePasskeyCount(of itemID: UUID, to count: Int) {
        guard var secret = try? environment.secrets.load(itemID), secret.passkey != nil else { return }
        secret.passkey?.signCount = count
        try? environment.secrets.save(secret, for: itemID)
    }

    /// An item as a refusal lists it: its name, and the username that tells apart items of one name.
    private static func label(_ item: VaultItem) -> String {
        item.username.isEmpty ? "“\(item.name)”" : "“\(item.name)” (\(item.username))"
    }

    /// How an item with no site comes to fill on one: the person fills it there once.
    private static func personLinks(_ host: String) -> String {
        "Ask the person to fill it from the two-factor code bar in this task's browser panel; that saves the site "
            + "of \(host) for it, and later fills here work."
    }

    /// For a refused code: the codes with no site the code bar offers on this page, if any.
    private func unlinkedCodes(_ request: VaultFillRequest) -> String {
        let unlinked = request.kind == .oneTimeCode ? unlinkedCodeItems(for: request.origin) : []
        guard !unlinked.isEmpty else { return "" }
        return " " + unlinked.map(Self.label).joined(separator: ", ") + " may be its two-factor code, saved with no site. "
            + Self.personLinks(VaultSite.host(of: request.origin))
    }

    private func refuse(_ request: VaultFillRequest, item: VaultItem?, _ message: String) -> Result<VaultFillGrant, VaultRefusal> {
        log(request, item: item, kinds: [request.kind.rawValue], outcome: .refused, reason: message, confirmedBy: nil)
        return .failure(VaultRefusal(message: message))
    }

    private func log(_ request: VaultFillRequest, item: VaultItem?, kinds: [String], outcome: VaultUse.Outcome,
                     reason: String?, confirmedBy: VaultUse.Confirmation?) {
        let task = describeTask(request.sessionID)
        environment.repository.appendUse(VaultUse(
            at: environment.now(), taskID: request.sessionID, taskTitle: task?.title, harness: task?.harness,
            itemID: item?.id, itemName: item?.name, origin: request.origin, kinds: kinds, outcome: outcome,
            reason: reason, confirmedBy: confirmedBy))
    }

    // MARK: The person's own fills and edits

    /// The items for a page, for the address field's key button (design §8.3).
    func items(for origin: String) -> [VaultItem] {
        guard environment.isAllowedBuild, isEnabled else { return [] }
        return items.filter { item in item.sites.contains { VaultSite.matches($0, origin: origin) } }
    }

    /// The two-factor codes with no site yet whose name names the page's site (`Vercel` on vercel.com), as an
    /// authenticator app's import leaves them (design §14.3). The code bar offers them when none of the
    /// site's own items has a code; none fills until the person picks one there, which saves the site.
    func unlinkedCodeItems(for origin: String) -> [VaultItem] {
        guard environment.isAllowedBuild, isEnabled,
              let site = VaultSite.suggestion(for: origin, suffixes: suffixes) else { return [] }
        return items.filter { $0.sites.isEmpty && $0.hasOneTimeCode && VaultSite.isNamed(site, by: $0.name) }
    }

    /// Saves a site for an item the person chose on one of its pages, as "Autofill and save" does in other
    /// password managers. Returns the item as saved.
    @discardableResult
    func link(_ itemID: UUID, to site: String) -> VaultItem? {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        if !items[index].sites.contains(site) {
            // The secret keeps the sites it may go to; one whose item changed outside Yardlet takes none.
            guard var secret = try? trustedSecret(of: items[index]) else { return nil }
            items[index].sites.append(site)
            secret.savedSites = items[index].sites
            try? environment.secrets.save(secret, for: itemID)
            environment.repository.saveItems(items)
        }
        return items[index]
    }

    /// The values for the person's own fill: they pressed the key button or the code bar, so no policy
    /// applies. The code is the one current now.
    func valuesForPerson(_ item: VaultItem, origin: String) -> VaultFillGrant? {
        guard item.sites.contains(where: { VaultSite.matches($0, origin: origin) }),
              let secret = try? trustedSecret(of: item) else { return nil }
        var grant = VaultFillGrant(item: item, confirmedBy: .person)
        grant.username = item.username.isEmpty ? nil : item.username
        grant.password = secret.password
        grant.code = secret.oneTimeCode.map { code(for: $0) }
        return grant
    }

    /// The code a secret gives at a moment (now by default), as an authenticator app shows it.
    func code(for secret: OneTimeCodeSecret, at date: Date? = nil) -> String {
        OneTimeCode.code(for: secret, at: date ?? environment.now(), hmac: environment.hmac)
    }

    /// The saved secret, for the item sheet once the person confirmed (showing the password).
    func secret(of itemID: UUID) -> VaultSecret? {
        try? environment.secrets.load(itemID)
    }

    func confirmPerson(_ reason: String) async -> Bool {
        await environment.confirm(reason)
    }

    func uses(of itemID: UUID, limit: Int = 20) -> [VaultUse] {
        environment.repository.uses(of: itemID, limit: limit)
    }

    /// The agents' fills the log keeps (90 days): each task and the site of the page filled. A task signed in
    /// to that site itself (docs/BROWSER_SESSION_ISOLATION.md 11).
    func agentFills() -> [(task: UUID, site: String)] {
        environment.repository.allUses().compactMap { use in
            guard use.outcome == .filled, use.confirmedBy != .person, let task = use.taskID,
                  let site = BrowserLoginFollow.site(of: use.origin) else { return nil }
            return (task, site)
        }
    }

    /// The item's secret, if the sites and agent policy `items.json` gives the item are the ones Yardlet saved with the
    /// secret; a secret saved before they were kept with it takes the item's now. Otherwise the person hears of it
    /// and it throws `VaultChangedOutside`.
    private func trustedSecret(of item: VaultItem) throws -> VaultSecret? {
        guard var secret = try environment.secrets.load(item.id) else { return nil }
        guard let sites = secret.savedSites, let policy = secret.savedPolicy else {
            secret.savedSites = item.sites
            secret.savedPolicy = item.policy
            try? environment.secrets.save(secret, for: item.id)
            return secret
        }
        guard sites == item.sites, policy == item.policy else {
            notify(L10n.string("A password item changed outside Yardlet"),
                   L10n.format("“%@” has sites or an agent use Yardlet did not save, so it fills nothing. Open it in Settings → Passwords to check it and save it.", item.name),
                   nil)
            throw VaultChangedOutside()
        }
        return secret
    }

    /// Adds or replaces an item and its secret, which keeps the item's sites and agent policy with it.
    func save(_ item: VaultItem, secret: VaultSecret) throws {
        var item = item
        var secret = secret
        secret.savedSites = item.sites
        secret.savedPolicy = item.policy
        if let stored = try? environment.secrets.load(item.id), let old = stored.password, !old.isEmpty,
           let new = secret.password, !new.isEmpty, new != old {
            // A password it replaces stays in the item's previous ones (design §15).
            let earlier = (secret.previousPasswords ?? stored.previousPasswords ?? []).filter { $0.password != old && $0.password != new }
            secret.previousPasswords = Array(([VaultPreviousPassword(password: old, replacedAt: environment.now())] + earlier)
                .prefix(Self.previousPasswordsKept))
        }
        item.hasPassword = !(secret.password ?? "").isEmpty
        item.hasOneTimeCode = secret.oneTimeCode != nil
        item.hasPasskey = secret.passkey != nil
        try environment.secrets.save(secret, for: item.id)
        let hadItems = !items.isEmpty
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        environment.repository.saveItems(items)
        if !hadItems { onToolsChanged?() }
    }

    func delete(_ itemID: UUID) throws {
        try environment.secrets.delete(itemID)
        items.removeAll { $0.id == itemID }
        environment.repository.saveItems(items)
        if items.isEmpty { onToolsChanged?() }
    }

    /// Empties the vault: every secret, item and use. Returns the sites that hold a Yardlet passkey,
    /// which only the person can remove there.
    @discardableResult
    func clear() throws -> [String] {
        let passkeySites = items.filter(\.hasPasskey).flatMap(\.sites)
        try environment.secrets.deleteAll()
        environment.repository.removeAll()
        items = []
        isUnlocked = false
        onTurnedOff?()
        onToolsChanged?()
        return passkeySites
    }
}
