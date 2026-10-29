import Foundation
import Observation

/// A model access route is a capability of a harness, not a classification of its vendor.
enum ModelAccessKind: String, Codable, Sendable {
    case includedService, externalProvider, configuredProvider

    var title: String {
        switch self {
        case .includedService: L10n.string("Included model service")
        case .externalProvider: L10n.string("External model provider")
        case .configuredProvider: L10n.string("Configured model provider")
        }
    }
}

struct HarnessConnectionCapabilities: Sendable {
    let access: ModelAccessKind
    let supportsSeparateHome: Bool

    static func capabilities(for harness: HarnessKind) -> Self {
        let external: Set<HarnessKind> = [.pi, .openCode, .hermes]
        let separate: Set<HarnessKind> = [.codex, .claudeCode, .pi, .openCode, .hermes]
        return Self(
            access: external.contains(harness) ? .externalProvider
                : [.codex, .claudeCode].contains(harness) ? .configuredProvider : .includedService,
            supportsSeparateHome: separate.contains(harness)
        )
    }
}

/// Contains only routing metadata. OAuth sessions and secrets remain in the owner's store.
/// Store this binding with the provider session ID; never look up a global "current account"
/// while resuming a saved task.
struct ProviderConnection: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    let harness: HarnessKind
    let providerID: String?
    let homePath: String?
    /// One account inside a credential store shared by several. No built-in harness selects an
    /// account this way now, so a connection carrying one is not valid; the field stays so a saved
    /// task's connection is written back as it was read.
    let credentialSelector: String?

    var providerDisplayName: String { Self.providerDisplayName(providerID) }

    static func providerDisplayName(_ providerID: String?) -> String {
        switch providerID {
        case "openai-codex", "openai_codex": "ChatGPT (OpenAI)"
        case "openai": "OpenAI API"
        case "anthropic": "Anthropic"
        case "github-copilot": "GitHub Copilot"
        case "google": "Google Gemini"
        case "openrouter": "OpenRouter"
        case let value?: value
        case nil: L10n.string("Provider configured by harness")
        }
    }

    var environment: [String: String] {
        guard let homePath else { return [:] }
        var values: [String: String]
        switch harness {
        case .codex: values = ["CODEX_HOME": homePath, "YARDLET_NATIVE_CODEX_HOME": homePath]
        case .claudeCode: values = ["CLAUDE_CONFIG_DIR": homePath]
        case .pi: values = ["PI_CODING_AGENT_DIR": homePath]
        case .hermes: values = ["HERMES_HOME": homePath]
        case .openCode:
            values = ["XDG_DATA_HOME": homePath + "/data", "XDG_CONFIG_HOME": homePath + "/config",
                    "XDG_STATE_HOME": homePath + "/state", "XDG_CACHE_HOME": homePath + "/cache"]
        default: values = [:]
        }
        values["YARDLET_ACCOUNT_ENVIRONMENT"] = "isolated"
        return values
    }

    var launchArguments: [String] {
        if let providerID, harness == .pi {
            return ["--provider", providerID]
        }
        return []
    }

    func validate(for expectedHarness: HarnessKind) throws {
        guard harness == expectedHarness, !id.isEmpty, !name.isEmpty else {
            throw ProviderConnectionError.invalidBinding
        }
        if let homePath {
            guard HarnessConnectionCapabilities.capabilities(for: harness).supportsSeparateHome,
                  homePath.hasPrefix("/"), !homePath.contains("\0") else {
                throw ProviderConnectionError.invalidBinding
            }
        }
        guard credentialSelector == nil else { throw ProviderConnectionError.invalidBinding }
        if let providerID {
            guard providerID.range(of: #"^[a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil else {
                throw ProviderConnectionError.invalidBinding
            }
        }
    }

    func codexEnvironmentManager() -> CodexEnvironmentManager? {
        guard harness == .codex, let homePath else { return nil }
        return CodexEnvironmentManager(paths: CodexEnvironmentPaths(
            nativeHomeURL: URL(filePath: homePath), yardletRootURL: CodexEnvironmentPaths.live().yardletRootURL
        ), isolatesAccountEnvironment: true)
    }
}

/// Claude resumes a session ID from its config's `projects` folder. Two configs whose folders
/// resolve to one directory hold the same conversations, so a task can continue under either
/// login without moving or copying history. Session Switch account folders are configured this way.
enum ClaudeConversationStorage {
    static func projectsDirectory(
        for connection: ProviderConnection?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let url = ClaudeSubagentTranscriptReader.configDirectory(connection: connection, environment: environment)
            .appending(path: "projects", directoryHint: .isDirectory).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url.standardizedFileURL.path(percentEncoded: false)
    }

    static func isShared(
        _ first: ProviderConnection?, _ second: ProviderConnection?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let lhs = projectsDirectory(for: first, environment: environment),
              let rhs = projectsDirectory(for: second, environment: environment) else { return false }
        return lhs == rhs
    }
}

/// Which accounts an existing task may continue under. The provider session ID never changes.
enum TaskAccountSwitch {
    static func supports(_ harness: HarnessKind) -> Bool { harness == .claudeCode }

    /// Claude changes the config folder only when both folders hold the same conversation history.
    static func allows(_ connection: ProviderConnection, for session: SessionRecord) -> Bool {
        guard connection.harness == session.harness else { return false }
        switch session.harness {
        case .claudeCode:
            return connection.homePath != nil && connection.credentialSelector == nil
                && ClaudeConversationStorage.isShared(session.connection, connection)
        default:
            return false
        }
    }
}

extension TaskAccountSwitch {
    /// Whether two accounts of `harness` keep their conversations in one place, so a task started
    /// under one could go on under the other: the same account, or Claude config folders whose
    /// `projects` resolve to one folder (`allows`).
    static func sharesConversations(_ first: ProviderConnection?, _ second: ProviderConnection?, harness: HarnessKind,
                                    environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if first?.id == second?.id { return true }
        return supports(harness) && ClaudeConversationStorage.isShared(first, second, environment: environment)
    }
}

enum ProviderConnectionError: LocalizedError {
    case invalidBinding, unreadableStore, signedOut
    /// The harness (named) could not sign an account out, so nothing was deleted.
    case signOutFailed(String)
    var errorDescription: String? {
        switch self {
        case .signOutFailed(let harness): L10n.format("%@ could not sign out, so nothing was deleted.", harness)
        case .invalidBinding: L10n.string("This account connection is not valid for the selected harness.")
        case .unreadableStore: L10n.string("Saved connections could not be read. Existing data has been preserved.")
        case .signedOut: L10n.string("This account is not signed in. Sign in from Accounts, then choose it again.")
        }
    }
}

/// Reads a harness's default (native) login. Tests inject one; the app reads through the runtime.
typealias AccountSnapshotLoader = @Sendable (HarnessDescriptor, URL?) async -> HarnessAccountSnapshot
/// Reads a saved account. Tests inject one; the app reads through the runtime.
typealias ConnectionSnapshotLoader = @Sendable (ProviderConnection, URL?) async -> HarnessAccountSnapshot
/// Uses one reset of an account's plan limits (the account, the attempt's ID, the reset to take).
/// Tests inject one; the app calls the harness.
typealias UsageResetRunner = @MainActor (AccountChoice, String, String?) async throws -> AccountUsageResetOutcome

/// Where the person's use of a reset of an account's plan limits stands.
enum UsageResetState: Equatable {
    case using
    /// The harness answered; `left` is how many resets the account holds afterwards, when known.
    case answered(AccountUsageResetOutcome, left: Int?)
    /// The attempt got no answer. Using a reset again sends the same attempt, so at most one is used.
    case failed(String)
}

/// When a check request may reuse what is already known.
enum AccountCheckPolicy: Sendable {
    /// Skip readings a check in this run confirmed less than `freshnessInterval` ago, and join a
    /// check already running. Lists use this when they appear.
    case ifStale
    /// Check again even when the reading is fresh, but join a check already running: one started
    /// a moment ago answers the same question. The refresh button uses this.
    case refresh
    /// Start a new check and discard the answer of any check already running, because the account
    /// may have changed since it started (a sign-in ended, the runtime changed).
    case restart
}

/// A read of a default login that the caller runs itself (the sign-in console's probe). It
/// supersedes every check of that login started before it.
struct AccountReadToken: Equatable, Sendable {
    let key: String
    let generation: Int
}

/// The one owner of account readings: the saved accounts, the default (native) login of each
/// harness, how current each reading is, and the checks that replace them. Every account list and
/// the account chip read from here, and every check goes through `check(...)`, which runs one check
/// per account at a time and applies one freshness rule.
@MainActor @Observable
final class ProviderConnectionStore {
    private(set) var connections: [ProviderConnection] = []
    private(set) var snapshots: [String: HarnessAccountSnapshot] = [:]
    private(set) var defaultSnapshots: [HarnessKind: HarnessAccountSnapshot] = [:]
    private(set) var errorMessage: String?
    /// How current each shown reading is, keyed like `AccountChoice.id`.
    private(set) var readingStatus: [String: AccountReadingStatus] = [:]
    /// Accounts this store is checking now, keyed like `AccountChoice.id`.
    private(set) var checkingKeys: Set<String> = []
    /// The account each choice last reported signed in, from the remembered readings, so a choice
    /// names its account while it is being checked again. Display only: it binds nothing.
    var knownAccountLabels: [String: String] {
        cache.entries.compactMapValues { entry in
            guard entry.state == .signedIn,
                  let label = entry.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty
            else { return nil }
            return label
        }
    }
    /// The person's own answers to which accounts automatic assignment may use,
    /// by `AccountChoice.id`. An account without one follows `isInAutomaticAssignmentByDefault`.
    private(set) var automaticAssignment: [String: Bool] = [:]
    var selection: [HarnessKind: String] = [:] {
        didSet { if selection != oldValue { onSelectionChange?(selection) } }
    }
    @ObservationIgnored var onSelectionChange: (([HarnessKind: String]) -> Void)?
    /// The environment Codex's default login is read in, the one the app's Codex tasks run in.
    @ObservationIgnored var codexEnvironmentManager: CodexEnvironmentManager?
    /// Replace the runtime reads of default logins and saved accounts; nil reads the runtimes.
    @ObservationIgnored var defaultLoader: AccountSnapshotLoader?
    @ObservationIgnored var connectionLoader: ConnectionSnapshotLoader?
    @ObservationIgnored private let fileURL: URL?
    /// Where `automaticAssignment` is kept; nil keeps it in memory.
    @ObservationIgnored private let assignmentDefaults: UserDefaults?
    /// The environment default logins are found in (`CLAUDE_CONFIG_DIR`); tests give their own.
    @ObservationIgnored var defaultLoginEnvironment = ProcessInfo.processInfo.environment
    /// Where Yardlet makes the folders of accounts added with a new sign-in; tests give their own.
    @ObservationIgnored var accountsRoot = CodexEnvironmentPaths.live().yardletRootURL.appending(path: "connections")
    /// The home folder discovery looks in; tests give their own.
    @ObservationIgnored var homeURL = FileManager.default.homeDirectoryForCurrentUser
    /// Moves a deleted account's folder to the Trash; tests remove it instead.
    @ObservationIgnored var moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    /// Folders with a Claude or Codex login or history that are not saved accounts, as last found.
    private(set) var discoveredHomes: [DiscoveredAccountHome] = []
    @ObservationIgnored private var readFailed = false
    @ObservationIgnored private var cache: AccountSnapshotCache
    /// The check running for each key; another request for the key waits for it.
    @ObservationIgnored private var runningChecks: [String: RunningCheck] = [:]
    /// Bumped by every check and outside read of a key; only the latest one's answer is shown.
    @ObservationIgnored private var generations: [String: Int] = [:]
    /// When a reading in this run last confirmed each key.
    @ObservationIgnored private var confirmedAt: [String: Date] = [:]
    @ObservationIgnored private var liveUpdateClients = 0
    @ObservationIgnored private var liveBroker: HarnessAccountBroker?
    @ObservationIgnored private var liveUpdates: Task<Void, Never>?
    /// Each account's use of a reset that the person has not dismissed, keyed like `AccountChoice.id`.
    private(set) var usageResetStates: [String: UsageResetState] = [:]
    /// The attempt each account's last use sent without getting an answer.
    @ObservationIgnored private var unansweredResetAttempts: [String: String] = [:]
    /// Replaces the harness call that uses a reset; nil calls the account's harness.
    @ObservationIgnored var usageResetRunner: UsageResetRunner?
    #if DEBUG
    var usesFixtureSnapshots = false
    #endif

    /// A reading confirmed this long ago is current enough to show without checking again.
    static let freshnessInterval: TimeInterval = 60

    private struct RunningCheck {
        let generation: Int
        let task: Task<Void, Never>
    }

    /// `snapshotCacheURL` remembers each account's last completed reading between launches, so
    /// the list shows it at once while the next check runs. Nil keeps readings in memory only.
    init(fileURL: URL? = nil, snapshotCacheURL: URL? = nil, assignmentDefaults: UserDefaults? = nil,
         defaultLoader: AccountSnapshotLoader? = nil, connectionLoader: ConnectionSnapshotLoader? = nil) {
        self.fileURL = fileURL
        self.assignmentDefaults = assignmentDefaults
        automaticAssignment = assignmentDefaults?.dictionary(forKey: Self.automaticAssignmentKey) as? [String: Bool] ?? [:]
        self.defaultLoader = defaultLoader
        self.connectionLoader = connectionLoader
        cache = AccountSnapshotCache(fileURL: snapshotCacheURL)
        if let fileURL {
            do {
                let saved = try JSONDecoder().decode([ProviderConnection].self, from: Data(contentsOf: fileURL))
                // A removed harness's accounts go with it. They are only Yardlet's routing records;
                // the logins stay in that harness's own store, and saved tasks keep their copy.
                connections = saved.filter { !HarnessCatalog.retired.contains($0.harness) }
                guard Set(connections.map(\.id)).count == connections.count else { throw ProviderConnectionError.invalidBinding }
                for connection in connections { try connection.validate(for: connection.harness) }
                if connections.count != saved.count { try? Self.write(connections, to: fileURL) }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            } catch {
                readFailed = true
                connections = []
                errorMessage = ProviderConnectionError.unreadableStore.localizedDescription
            }
        }
        restoreRememberedReadings()
    }

    static func live() -> ProviderConnectionStore {
        let root = CodexEnvironmentPaths.live().yardletRootURL
        return Self(fileURL: root.appending(path: "provider-connections.json"),
            snapshotCacheURL: root.appending(path: snapshotCacheFileName), assignmentDefaults: .yardlet)
    }

    static let automaticAssignmentKey = "Yardlet.automaticAccountAssignment"

    static let snapshotCacheFileName = "account-snapshots.json"

    /// Shows each saved and default account's last completed reading until a check replaces it.
    private func restoreRememberedReadings() {
        guard !readFailed else { return }
        for connection in connections {
            guard let entry = cache.entries[connection.id], entry.harness == connection.harness else { continue }
            snapshots[connection.id] = entry.snapshot(id: connection.id)
            readingStatus[connection.id] = .remembered
        }
        for harness in HarnessCatalog.builtIns.map(\.id) {
            let key = AccountSnapshotCache.defaultKey(for: harness)
            guard let entry = cache.entries[key], entry.harness == harness else { continue }
            defaultSnapshots[harness] = entry.snapshot(
                id: harness == .pi ? "pi:\(entry.providerID ?? "openai-codex")" : harness.rawValue)
            readingStatus[key] = .remembered
        }
        cache.retain(keys: Set(connections.map(\.id)))
    }

    /// Applies a check's answer to the reading shown under `key` and returns what to show.
    /// Signed in or out is shown and remembered; needing attention is shown and the remembered
    /// reading forgotten. A check that could not finish keeps the last signed-in reading on screen,
    /// marked as not checked; a missing runtime is shown as it is.
    private func accept(_ snapshot: HarnessAccountSnapshot, key: String,
                        current: HarnessAccountSnapshot?) -> HarnessAccountSnapshot {
        let shown: HarnessAccountSnapshot
        switch snapshot.state {
        case .signedIn, .signedOut:
            cache.remember(snapshot, key: key)
            readingStatus[key] = .current
            shown = snapshot
        case .unknown:
            if let current, current.state == .signedIn {
                readingStatus[key] = .checkFailed
                shown = current
            } else {
                readingStatus[key] = .current
                shown = snapshot
            }
        case .actionRequired:
            cache.forget(key)
            readingStatus[key] = .current
            shown = snapshot
        case .unavailable:
            readingStatus[key] = .current
            shown = snapshot
        }
        confirmedAt[key] = readingStatus[key] == .current ? Date() : nil
        return shown
    }

    /// Whether the row for `choice` is being checked by this store now.
    func isChecking(_ choice: AccountChoice) -> Bool { checkingKeys.contains(choice.id) }

    /// Whether a harness's default login is being checked now.
    func isCheckingDefault(_ harness: HarnessKind) -> Bool {
        checkingKeys.contains(AccountSnapshotCache.defaultKey(for: harness))
    }

    /// Whether a default login or saved account of any of these harnesses is being checked now.
    func isChecking(anyOf harnesses: some Sequence<HarnessKind>) -> Bool {
        let wanted = Set(harnesses)
        guard !wanted.isEmpty, !checkingKeys.isEmpty else { return false }
        let keys = Set(wanted.map(AccountSnapshotCache.defaultKey(for:)))
            .union(connections.filter { wanted.contains($0.harness) }.map(\.id))
        return !checkingKeys.isDisjoint(with: keys)
    }

    /// Whether `.ifStale` keeps the reading under `key` without checking again.
    func isFresh(_ key: String, now: Date = Date()) -> Bool {
        guard (readingStatus[key] ?? .current) == .current, let confirmed = confirmedAt[key] else { return false }
        return now.timeIntervalSince(confirmed) < Self.freshnessInterval
    }

    /// How current the reading shown for `choice` is; nil before any reading.
    func readingStatus(for choice: AccountChoice) -> AccountReadingStatus? { readingStatus[choice.id] }

    func connections(for harness: HarnessKind) -> [ProviderConnection] {
        connections.filter { $0.harness == harness }
    }

    func selected(for harness: HarnessKind) -> ProviderConnection? {
        guard let id = selection[harness] else { return nil }
        return connections.first { $0.id == id && $0.harness == harness }
    }

    // MARK: - Account folders

    /// The Claude config folder of the default login: the one other Claude folders share with.
    var claudeDefaultHome: URL {
        ClaudeSubagentTranscriptReader.configDirectory(connection: nil, environment: defaultLoginEnvironment, homeURL: homeURL)
    }

    var codexDefaultHome: URL {
        codexEnvironmentManager?.paths.nativeHomeURL
            ?? CodexEnvironmentPaths.live(environment: defaultLoginEnvironment, homeURL: homeURL).nativeHomeURL
    }

    /// Whether Yardlet made this account's folder for a new sign-in, so it may keep the folder's
    /// links current and remove the folder with the account.
    func isMadeByYardlet(_ connection: ProviderConnection) -> Bool {
        guard let path = connection.homePath else { return false }
        return Self.folder(URL(filePath: path)).hasPrefix(Self.folder(accountsRoot) + "/")
    }

    /// One spelling of a folder's path, to compare two spellings of one folder.
    private static func folder(_ url: URL) -> String { ProjectSidebarPresentation.normalizedPath(for: url) }

    /// Makes the folder for an account added with a new sign-in. A Claude folder shares everything
    /// but its login with the default folder (`ClaudeAccountHome`), as Session Switch's do.
    func makeAccountHome(for harness: HarnessKind) throws -> URL {
        let home = accountsRoot.appending(path: UUID().uuidString).appending(path: harness.rawValue)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if harness == .claudeCode { try ClaudeAccountHome.prepareNewHome(home, primary: claudeDefaultHome) }
        return home
    }

    /// What sharing a Claude account's folder with the default folder would change; nil for other
    /// accounts.
    func sharingPlan(for connection: ProviderConnection) -> ClaudeAccountHome.Plan? {
        guard connection.harness == .claudeCode, let path = connection.homePath else { return nil }
        return ClaudeAccountHome.plan(home: URL(filePath: path), primary: claudeDefaultHome)
    }

    /// Makes the links the person approved in a sharing plan.
    func share(_ connection: ProviderConnection, plan: ClaudeAccountHome.Plan) throws {
        guard connection.harness == .claudeCode, let path = connection.homePath else { return }
        try ClaudeAccountHome.apply(plan, home: URL(filePath: path), primary: claudeDefaultHome)
    }

    /// Looks again for folders with a login or history that are not saved accounts.
    func findUnsavedAccountHomes() async {
        #if DEBUG
        guard !usesFixtureSnapshots else { return }
        #endif
        let saved = connections
        let defaults: [HarnessKind: URL] = [.claudeCode: claudeDefaultHome, .codex: codexDefaultHome]
        let environment = defaultLoginEnvironment
        let home = homeURL
        let found = await Task.detached(priority: .utility) {
            AccountHomeDiscovery.find(saved: saved, defaults: defaults, environment: environment, homeURL: home)
        }.value
        // An account saved meanwhile is no longer one to add.
        let savedPaths = Set(connections.compactMap { $0.homePath.map { Self.folder(URL(filePath: $0)) } })
        discoveredHomes = found.filter { !savedPaths.contains($0.path) }
    }

    /// The accounts a conversation can be imported under: those that can be chosen, then the found
    /// folders of the harness, named as found (importing under one saves it, `saveIfFound`).
    func importChoices(for harness: HarnessKind) -> [AccountChoice] {
        choices(for: [harness]).filter(\.canSelect) + discoveredHomes.filter { $0.harness == harness }.map {
            AccountChoice(harness: harness, connection: $0.connection, snapshot: nil,
                          knownLabel: L10n.format("%@ (folder found)", $0.title))
        }
    }

    /// Saves the found folder a conversation is being imported under, so the task's account is one
    /// the account lists show. Any other connection is left as it is.
    func saveIfFound(_ connection: ProviderConnection?) throws {
        guard let connection, let found = discoveredHomes.first(where: { $0.connection.id == connection.id }) else { return }
        try add(found)
    }

    /// Saves a found folder as an account, as it is.
    @discardableResult
    func add(_ found: DiscoveredAccountHome) throws -> ProviderConnection {
        try save(found.connection)
        return found.connection
    }

    func add(name: String, harness: HarnessKind, home: URL, providerID: String? = nil) throws -> ProviderConnection {
        let connection = ProviderConnection(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            harness: harness, providerID: providerID, homePath: home.standardizedFileURL.path, credentialSelector: nil)
        try save(connection)
        return connection
    }

    func save(_ connection: ProviderConnection) throws {
        guard !readFailed else { throw ProviderConnectionError.unreadableStore }
        try connection.validate(for: connection.harness)
        var updated = connections.filter { $0.id != connection.id }
        updated.append(connection)
        if let fileURL { try Self.write(updated, to: fileURL) }
        connections = updated
        errorMessage = nil
        // A folder saved by any route is no longer one to add.
        if let path = connection.homePath.map({ Self.folder(URL(filePath: $0)) }) {
            discoveredHomes.removeAll { $0.harness == connection.harness && $0.path == path }
        }
    }

    // MARK: - Removing

    /// The command that signs a harness's own login out of an account folder without asking.
    private static let signOutArguments: [HarnessKind: [String]] = [.claudeCode: ["auth", "logout"], .codex: ["logout"]]

    /// Takes a saved account off Yardlet's list: its record, its remembered reading, the new-task
    /// choice and its automatic-assignment answer. The login and its folder stay, and tasks keep
    /// their own copy of the binding, so they go on in that folder under the same storage scope.
    func remove(_ connection: ProviderConnection) throws {
        guard !readFailed else { throw ProviderConnectionError.unreadableStore }
        let remaining = connections.filter { $0.id != connection.id }
        if let fileURL { try Self.write(remaining, to: fileURL) }
        connections = remaining
        supersede(connection.id)
        snapshots[connection.id] = nil
        readingStatus[connection.id] = nil
        confirmedAt[connection.id] = nil
        cache.forget(connection.id)
        if selection[connection.harness] == connection.id { selection[connection.harness] = nil }
        if automaticAssignment.removeValue(forKey: connection.id) != nil {
            if automaticAssignment.isEmpty { assignmentDefaults?.removeObject(forKey: Self.automaticAssignmentKey) }
            else { assignmentDefaults?.set(automaticAssignment, forKey: Self.automaticAssignmentKey) }
        }
    }

    /// Whether deleting the account's folder leaves its conversations where they are: a Claude
    /// folder whose `projects` is the default login's.
    func keepsConversationsInDefaultFolder(_ connection: ProviderConnection) -> Bool {
        connection.harness == .claudeCode
            && ClaudeConversationStorage.isShared(connection, nil, environment: defaultLoginEnvironment)
    }

    /// Whether the account's folder is one Yardlet made for a sign-in and can sign out and delete:
    /// `<accountsRoot>/<UUID>/<harness>` of a harness whose CLI signs out without asking.
    func canSignOutAndDelete(_ connection: ProviderConnection) -> Bool {
        guard Self.signOutArguments[connection.harness] != nil, isMadeByYardlet(connection),
              let path = connection.homePath else { return false }
        return Self.folder(URL(filePath: path).deletingLastPathComponent().deletingLastPathComponent())
            == Self.folder(accountsRoot)
    }

    /// Signs a Yardlet-made account out with its own CLI, then takes it off the list, removes the
    /// links in its folder (so nothing the folder shares can be reached) and moves the folder to
    /// the Trash. When the CLI cannot sign out, nothing changes.
    func signOutAndDelete(_ connection: ProviderConnection, executableURL: URL?) async throws {
        guard canSignOutAndDelete(connection), let path = connection.homePath,
              let arguments = Self.signOutArguments[connection.harness] else { throw ProviderConnectionError.invalidBinding }
        guard let executableURL,
              let result = try? await AccountCommandRunner.run(executableURL: executableURL, arguments: arguments,
                  environment: connection.environment, timeout: .seconds(30)),
              result.exitCode == 0 else { throw ProviderConnectionError.signOutFailed(connection.harness.displayName) }
        try remove(connection)
        let home = URL(filePath: path)
        try ClaudeAccountHome.unlinkShared(home: home)
        try moveToTrash(home.deletingLastPathComponent())
    }

    private static func write(_ connections: [ProviderConnection], to fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(connections).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Shows a saved account's reading that was read outside `check(...)`; a check of that account
    /// still running no longer changes it.
    func publish(_ snapshot: HarnessAccountSnapshot, for connection: ProviderConnection) {
        supersede(connection.id)
        apply(snapshot, for: connection)
    }

    private func apply(_ snapshot: HarnessAccountSnapshot, for connection: ProviderConnection) {
        snapshots[connection.id] = accept(snapshot, key: connection.id, current: snapshots[connection.id])
    }

    /// A Claude session's own plan-limit report, applied to the account it runs under so the
    /// account list follows it without another check. An account never checked stays unchecked.
    func recordRateLimit(_ limit: HarnessRateLimit, for connection: ProviderConnection?) {
        if let connection {
            guard connection.harness == .claudeCode, let snapshot = snapshots[connection.id] else { return }
            let usage = ClaudeUsageProbe.usage(snapshot.usage, updatedBy: limit)
            guard usage != snapshot.usage else { return }
            snapshots[connection.id] = snapshot.replacingUsage(usage)
            cache.remember(snapshot.replacingUsage(usage), key: connection.id)
        } else if let snapshot = defaultSnapshots[.claudeCode] {
            let usage = ClaudeUsageProbe.usage(snapshot.usage, updatedBy: limit)
            guard usage != snapshot.usage else { return }
            defaultSnapshots[.claudeCode] = snapshot.replacingUsage(usage)
            cache.remember(snapshot.replacingUsage(usage), key: AccountSnapshotCache.defaultKey(for: .claudeCode))
        }
    }

    // MARK: - Automatic assignment

    /// Whether Yardlet may start an agent's task on this account by itself.
    func isInAutomaticAssignment(_ choice: AccountChoice) -> Bool {
        automaticAssignment[choice.id] ?? isInAutomaticAssignmentByDefault(choice)
    }

    /// Unless the person said otherwise, automatic assignment uses the harness's default login and
    /// the accounts that keep their conversations with it (`TaskAccountSwitch.sharesConversations`):
    /// a task started there is in the same history as the person's own, and can move to another of
    /// them at a limit. Session Switch's Claude folders share `~/.claude/projects`; a Codex login in
    /// another `CODEX_HOME` keeps its own history, so it stays out until the person includes it.
    func isInAutomaticAssignmentByDefault(_ choice: AccountChoice) -> Bool {
        sharesConversationsWithDefaultLogin(choice)
    }

    /// Whether an account keeps its conversations where the harness's default login does.
    func sharesConversationsWithDefaultLogin(_ choice: AccountChoice) -> Bool {
        TaskAccountSwitch.sharesConversations(choice.connection, nil, harness: choice.harness,
                                              environment: defaultLoginEnvironment)
    }

    /// The person includes an account in automatic assignment or leaves it out. An answer the same as
    /// the default is forgotten, so the default applies again.
    func setInAutomaticAssignment(_ included: Bool, for choice: AccountChoice) {
        automaticAssignment[choice.id] = included == isInAutomaticAssignmentByDefault(choice) ? nil : included
        if automaticAssignment.isEmpty {
            assignmentDefaults?.removeObject(forKey: Self.automaticAssignmentKey)
        } else {
            assignmentDefaults?.set(automaticAssignment, forKey: Self.automaticAssignmentKey)
        }
    }

    /// The smallest share any of an account's plan limits has left, from its last reading.
    func remainingFraction(for connection: ProviderConnection) -> Double? {
        snapshots[connection.id].flatMap(Self.remainingFraction)
    }

    nonisolated static func remainingFraction(_ snapshot: HarnessAccountSnapshot) -> Double? {
        snapshot.usage.filter { $0.evidence == .exactQuota }
            .compactMap { $0.usedFraction.map { max(0, 1 - $0) } }.min()
    }

    /// Shows default logins' readings that were read outside `check(...)` (the Codex account
    /// monitor, a fixture); a check of that login still running no longer changes it.
    func publishDefaults(_ values: [HarnessAccountSnapshot]) {
        for value in values { finishRead(beginRead(ofDefault: value.harness), with: value) }
    }

    /// Starts a read of a harness's default login that the caller runs itself. Checks of the login
    /// that started earlier no longer change what is shown.
    func beginRead(ofDefault harness: HarnessKind) -> AccountReadToken {
        let key = AccountSnapshotCache.defaultKey(for: harness)
        return AccountReadToken(key: key, generation: supersede(key))
    }

    /// Whether no check or read of the same login started after this one.
    func isLatest(_ token: AccountReadToken) -> Bool { generations[token.key] == token.generation }

    /// Shows the answer of a read begun with `beginRead(ofDefault:)` unless a later check or read
    /// of the login has started since. Returns whether it was shown.
    @discardableResult
    func finishRead(_ token: AccountReadToken, with snapshot: HarnessAccountSnapshot) -> Bool {
        guard isLatest(token), token.key == AccountSnapshotCache.defaultKey(for: snapshot.harness) else { return false }
        applyDefault(snapshot)
        return true
    }

    private func applyDefault(_ snapshot: HarnessAccountSnapshot) {
        let key = AccountSnapshotCache.defaultKey(for: snapshot.harness)
        defaultSnapshots[snapshot.harness] = accept(snapshot, key: key, current: defaultSnapshots[snapshot.harness])
    }

    /// Ends the check running for `key` as far as the shown reading goes, and returns the
    /// generation the next reading of it carries.
    @discardableResult
    private func supersede(_ key: String) -> Int {
        let generation = (generations[key] ?? 0) + 1
        generations[key] = generation
        if runningChecks.removeValue(forKey: key) != nil {
            checkingKeys.remove(key)
        }
        return generation
    }

    func choices(for harnesses: [HarnessKind]) -> [AccountChoice] {
        AccountChoiceProjection.choices(harnesses: harnesses, connections: connections,
            defaults: defaultSnapshots, snapshots: snapshots, knownLabels: knownAccountLabels)
    }

    /// The account a conversation from another app comes in under unless the person picks
    /// another: the one this harness's new tasks start on, else the first that can be chosen.
    /// The import sheet starts on it, and following the other apps' lists uses it.
    func defaultImportChoice(for harness: HarnessKind) -> AccountChoice? {
        let accounts = choices(for: [harness]).filter(\.canSelect)
        return accounts.first { $0.connection?.id == selection[harness] } ?? accounts.first
    }

    func choose(_ choice: AccountChoice) {
        guard choice.canSelect else { return }
        selection[choice.harness] = choice.connection?.id
    }

    /// Checks the accounts a new task can start on with `harness`, as the new-task screen's
    /// account control and a suggestion's Options list them: the default login, and the saved
    /// accounts too when a signed-out default is hidden next to them, so one can be chosen.
    func checkNewTaskAccounts(for harness: HarnessKind, runtimeSelections: RuntimeSelectionStore) async {
        await check(defaultsOf: [harness], savedOf: [], runtimeSelections: runtimeSelections)
        if selection[harness] == nil, defaultSnapshots[harness]?.state == .signedOut, !connections(for: harness).isEmpty {
            await check(defaultsOf: [], savedOf: [harness], runtimeSelections: runtimeSelections)
        }
    }

    // MARK: - Checks

    /// The one way account readings are checked. Checks the default login of each harness in
    /// `defaultsOf` and the saved accounts of each harness in `savedOf` (nil means every harness;
    /// `connectionIDs` narrows the saved accounts) side by side, and returns when all have
    /// answered. Each row updates as soon as its own answer arrives. A request for an account whose
    /// check is already running waits for that check instead of starting another process.
    func check(defaultsOf defaultHarnesses: [HarnessKind]? = nil, savedOf savedHarnesses: [HarnessKind]? = nil,
               connectionIDs: Set<String>? = nil, policy: AccountCheckPolicy = .ifStale,
               runtimeSelections: RuntimeSelectionStore) async {
        #if DEBUG
        guard !usesFixtureSnapshots else { return }
        #endif
        let catalog = HarnessCatalog.builtIns.map(\.id)
        let defaults = defaultHarnesses ?? catalog
        let saved = Set(savedHarnesses ?? catalog)
        var running: [Task<Void, Never>] = []
        for harness in defaults {
            guard let descriptor = HarnessCatalog.descriptor(for: harness) else { continue }
            let task = schedule(AccountSnapshotCache.defaultKey(for: harness), policy: policy) { isLatest in
                let executable = runtimeSelections.selectedURL(for: harness)
                let snapshot = await self.readDefault(descriptor, executableURL: executable)
                guard isLatest(), runtimeSelections.selectedURL(for: harness) == executable else { return }
                self.applyDefault(snapshot)
            }
            if let task { running.append(task) }
        }
        // Each saved account is checked by its own CLI process, so they run side by side.
        for connection in connections where saved.contains(connection.harness)
            && (connectionIDs?.contains(connection.id) ?? true) {
            let task = schedule(connection.id, policy: policy) { isLatest in
                let value = await self.read(connection, executableURL: runtimeSelections.selectedURL(for: connection.harness))
                guard isLatest(), self.connections.contains(connection) else { return }
                self.apply(value, for: connection)
            }
            if let task { running.append(task) }
        }
        for task in running { await task.value }
        for harness in catalog where defaults.contains(harness) || saved.contains(harness) {
            replaceSignedOutDefaultSelection(for: harness)
        }
    }

    /// Starts `work` as the check for `key`, or returns the check already running for it; nil when
    /// the policy keeps a fresh reading. The row under `key` shows a spinner meanwhile.
    private func schedule(_ key: String, policy: AccountCheckPolicy,
                          work: @escaping @MainActor (_ isLatest: @escaping @MainActor () -> Bool) async -> Void)
        -> Task<Void, Never>? {
        if policy != .restart, let running = runningChecks[key] { return running.task }
        if policy == .ifStale, isFresh(key) { return nil }
        let generation = supersede(key)
        checkingKeys.insert(key)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await work { [weak self] in self?.generations[key] == generation }
            guard let running = self.runningChecks[key], running.generation == generation else { return }
            self.runningChecks[key] = nil
            self.checkingKeys.remove(key)
        }
        runningChecks[key] = RunningCheck(generation: generation, task: task)
        return task
    }

    /// Reads a harness's default login, or the login a sign-in console works with (`connection`).
    func readDefault(_ descriptor: HarnessDescriptor, executableURL: URL?,
                     connection: ProviderConnection? = nil) async -> HarnessAccountSnapshot {
        if let defaultLoader { return await defaultLoader(descriptor, executableURL) }
        let broker = connection.map { HarnessAccountBroker(connection: $0) }
            ?? HarnessAccountBroker(codexEnvironmentManager: codexEnvironmentManager)
        return await broker.snapshot(for: descriptor, executableURL: executableURL)
    }

    private func read(_ connection: ProviderConnection, executableURL: URL?) async -> HarnessAccountSnapshot {
        if let connectionLoader { return await connectionLoader(connection, executableURL) }
        // A folder Yardlet made in the shared shape links what the default folder gained since, as
        // Session Switch prepares its folders before each launch. Only missing links and empty
        // folders change. A folder made before keeps its own history and changes only when the
        // person shares it.
        if connection.harness == .claudeCode, isMadeByYardlet(connection), let plan = sharingPlan(for: connection),
           plan.hasChanges, plan.sharesConversations {
            try? share(connection, plan: plan)
        }
        return await ProviderConnectionService.snapshot(connection, executableURL: executableURL)
    }

    // MARK: - Live Codex updates

    /// Follows Codex's own account notifications while an accounts page is open, so a sign-in or
    /// a limit change shows without another check. Each call needs a matching `stopLiveUpdates()`.
    /// The monitor owns one App Server process and never starts a thread or a turn.
    func startLiveUpdates(runtimeSelections: RuntimeSelectionStore) async {
        liveUpdateClients += 1
        #if DEBUG
        guard !usesFixtureSnapshots else { return }
        #endif
        guard liveBroker == nil, defaultLoader == nil,
              let executable = runtimeSelections.selectedURL(for: .codex) else { return }
        let broker = HarnessAccountBroker(codexEnvironmentManager: codexEnvironmentManager)
        liveBroker = broker
        do {
            let stream = try await broker.startCodexAccountUpdates(executableURL: executable)
            guard liveUpdateClients > 0, liveBroker === broker else {
                await broker.stopCodexAccountUpdates()
                return
            }
            liveUpdates = Task { @MainActor [weak self] in
                for await snapshot in stream {
                    guard !Task.isCancelled else { break }
                    self?.publishDefaults([snapshot])
                }
            }
        } catch {
            // The checks still answer when an older runtime cannot keep a notification stream open.
            if liveBroker === broker { liveBroker = nil }
        }
    }

    func stopLiveUpdates() async {
        liveUpdateClients = max(0, liveUpdateClients - 1)
        guard liveUpdateClients == 0 else { return }
        liveUpdates?.cancel()
        liveUpdates = nil
        let broker = liveBroker
        liveBroker = nil
        await broker?.stopCodexAccountUpdates()
    }

    // MARK: - Usage resets

    /// The account a task runs under, as its row in an account list shows it.
    func choice(for harness: HarnessKind, connection: ProviderConnection?) -> AccountChoice {
        let saved = connection.map { connection in connections.first { $0.id == connection.id } ?? connection }
        return AccountChoice(harness: harness, connection: saved,
            snapshot: saved.map { snapshots[$0.id] } ?? defaultSnapshots[harness])
    }

    /// Checks the one account `choice` names.
    func check(_ choice: AccountChoice, policy: AccountCheckPolicy = .ifStale,
               runtimeSelections: RuntimeSelectionStore) async {
        await check(defaultsOf: choice.connection == nil ? [choice.harness] : [],
            savedOf: choice.connection == nil ? [] : [choice.harness],
            connectionIDs: Set(choice.connection.map { [$0.id] } ?? []), policy: policy,
            runtimeSelections: runtimeSelections)
    }

    /// The person uses one reset of `choice`'s plan limits, after confirming it: the harness's own
    /// call under that account's login takes the reset that expires first, then the account is
    /// checked again so its limits and count show what changed. An attempt that got no answer is
    /// sent again as it was, so a reset is never used twice for one press.
    func useUsageReset(_ choice: AccountChoice, runtimeSelections: RuntimeSelectionStore) async {
        let key = choice.id
        guard usageResetStates[key] != .using else { return }
        usageResetStates[key] = .using
        let attemptID = unansweredResetAttempts[key] ?? UUID().uuidString
        unansweredResetAttempts[key] = attemptID
        let current = self.choice(for: choice.harness, connection: choice.connection)
        let before = current.snapshot?.usageResets
        do {
            let outcome: AccountUsageResetOutcome
            if let usageResetRunner {
                outcome = try await usageResetRunner(current, attemptID, before?.next?.id)
            } else {
                guard let executable = runtimeSelections.selectedURL(for: choice.harness) else {
                    throw AccountUsageResetError.unsupported
                }
                let broker = current.connection.map { HarnessAccountBroker(connection: $0) }
                    ?? HarnessAccountBroker(codexEnvironmentManager: codexEnvironmentManager)
                outcome = try await broker.useUsageReset(harness: choice.harness, executableURL: executable,
                    attemptID: attemptID, resetID: before?.next?.id)
            }
            unansweredResetAttempts[key] = nil
            await check(current, policy: .restart, runtimeSelections: runtimeSelections)
            let after = self.choice(for: choice.harness, connection: choice.connection)
            let left = readingStatus[key] == .current ? after.snapshot?.usageResets?.availableCount
                : before.map { max(0, $0.availableCount - (outcome == .reset ? 1 : 0)) }
            usageResetStates[key] = .answered(outcome, left: left)
        } catch {
            usageResetStates[key] = .failed(error.localizedDescription)
        }
    }

    /// Forgets an answered or failed use once the person has seen it. An unanswered attempt is still
    /// sent again by the next use.
    func dismissUsageReset(for choice: AccountChoice) {
        guard let state = usageResetStates[choice.id], state != .using else { return }
        usageResetStates[choice.id] = nil
    }

    func usageSummary(for connection: ProviderConnection) -> String {
        guard let snapshot = snapshots[connection.id] else { return L10n.string("Not checked") }
        return Self.usageSummary(snapshot)
    }

    static func usageSummary(_ snapshot: HarnessAccountSnapshot) -> String {
        let quota = snapshot.usage.filter { $0.evidence == .exactQuota }
        guard !quota.isEmpty else { return snapshot.state.displayName }
        return quota.map { metric in
            "\(metric.label) · \(metric.detail)"
        }.joined(separator: " · ")
    }

    /// New tasks must not start on a default login the runtime reports as signed out while a saved
    /// account is signed in. The saved account with the most limit left becomes the choice; an
    /// explicit choice is never replaced.
    func replaceSignedOutDefaultSelection(for harness: HarnessKind) {
        guard selection[harness] == nil, defaultSnapshots[harness]?.state == .signedOut else { return }
        var best: (connection: ProviderConnection, left: Double)?
        // Only a sign-in a check confirmed in this run counts; a remembered one may have ended since.
        for connection in connections(for: harness) where snapshots[connection.id]?.state == .signedIn
            && readingStatus[connection.id] == .current {
            let left = snapshots[connection.id]?.usage.filter { $0.evidence == .exactQuota }
                .compactMap { $0.usedFraction.map { 1 - $0 } }.min() ?? 1
            if best == nil || left > best!.left { best = (connection, left) }
        }
        if let best { selection[harness] = best.connection.id }
    }
}
