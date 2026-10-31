import Foundation
import Observation

/// Where each harness keeps the settings that name its default model, by account.
struct HarnessModelSettingsLocations: Equatable, Sendable {
    /// Claude Code's config folder when a task runs on the default login.
    var claudeConfigDirectory: URL
    /// Codex's home for native tasks on the default login.
    var codexHome: URL
    /// Codex's home for tasks kept in Yardlet's own environment.
    var codexYardletHome: URL

    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let codex = CodexEnvironmentPaths.live(environment: environment)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claude = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? home.appending(path: ".claude", directoryHint: .isDirectory)
        return Self(claudeConfigDirectory: claude.standardizedFileURL, codexHome: codex.nativeHomeURL,
                    codexYardletHome: codex.runtimeHomeURL)
    }

    /// The folder whose settings a task on this account and scope runs with. A saved account
    /// brings its own folder; other harnesses have no model settings Yardlet reads.
    func folder(for harness: HarnessKind, connection: ProviderConnection?,
                scope: SessionEnvironmentScope = .native) -> URL? {
        switch harness {
        case .claudeCode:
            return connection?.homePath.map { URL(filePath: $0) } ?? claudeConfigDirectory
        case .codex:
            return connection?.homePath.map { URL(filePath: $0) } ?? (scope == .native ? codexHome : codexYardletHome)
        default:
            return nil
        }
    }
}

/// The model lists runtimes last advertised, by harness and account, kept across launches so a
/// composer can name and offer models before its task connects, and what each account's settings
/// files say its default is. Nothing here starts a runtime or writes a provider's files.
@MainActor
@Observable
final class HarnessModelCatalogStore {
    private struct Snapshot: Codable {
        var version = 1
        var claude: [String: [HarnessModelOption]] = [:]
        var codex: [String: [CodexModelOption]] = [:]
        var codexThreads: [UUID: CodexModelSelection]? = nil
        /// Antigravity CLI's list, its effort variants folded (it has one sign-in, so no accounts).
        var antigravity: [HarnessModelOption]? = nil
        /// The context window Claude Code last reported for each model it ran (an earlier build
        /// leaves it out).
        var claudeContextWindows: [String: UInt64]? = nil
    }

    private(set) var claude: [String: [HarnessModelOption]] = [:]
    /// The models Antigravity CLI last listed, with each one's effort variants as its levels.
    private(set) var antigravity: [HarnessModelOption] = []
    private(set) var codex: [String: [CodexModelOption]] = [:]
    /// The window Claude Code's `get_context_usage` last gave for each model, by the model as it
    /// names it (`claude-opus-5-5`, `claude-opus-4-8[1m]`). Claude Code takes a window from its own
    /// model registry (`Vf`) and saves none in a conversation, so a saved conversation read before
    /// its task reports again is given the window its model last had here.
    private(set) var claudeContextWindows: [String: UInt64] = [:]
    /// The model and effort each Codex task's thread last reported, by task. Codex keeps a thread's
    /// own settings, so this is what the task resumes on unless it chose another.
    private(set) var codexThreads: [UUID: CodexModelSelection] = [:]
    private(set) var defaults: [String: HarnessModelDefaults] = [:]
    @ObservationIgnored let locations: HarnessModelSettingsLocations
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let environment: [String: String]

    init(fileURL: URL? = nil, locations: HarnessModelSettingsLocations = .live(),
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.fileURL = fileURL
        self.locations = locations
        self.environment = environment
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == 1 else { return }
        claude = snapshot.claude
        codex = snapshot.codex
        codexThreads = snapshot.codexThreads ?? [:]
        antigravity = snapshot.antigravity ?? []
        claudeContextWindows = snapshot.claudeContextWindows ?? [:]
    }

    /// Keeps the window Claude Code reported for `model`.
    func recordClaudeContextWindow(_ tokens: UInt64, model: String) {
        guard tokens > 0, !model.isEmpty, claudeContextWindows[model] != tokens else { return }
        claudeContextWindows[model] = tokens
        save()
    }

    /// The window for a response of `model` (the API model ID a saved conversation records) in a
    /// task that runs `chosenModel`: Claude Code gives a model chosen with the `[1m]` suffix the
    /// million-token window (`sf`: `/\[1m\]/i`), so such a task looks up the model with it.
    func claudeContextWindow(forResponseModel model: String, chosenModel: String?) -> UInt64? {
        let suffix = "[1m]"
        let base = model.lowercased().hasSuffix(suffix) ? String(model.dropLast(suffix.count)) : model
        let wantsMillion = chosenModel?.lowercased().contains(suffix) == true
        return claudeContextWindows[wantsMillion ? base + suffix : base]
    }

    func recordAntigravity(_ models: [HarnessModelOption]) {
        guard !models.isEmpty, antigravity != models else { return }
        antigravity = models
        save()
    }

    static func scope(for connection: ProviderConnection?) -> String { connection?.id ?? "default" }

    /// The models Claude Code last listed for this account, or, before it ever has, for another
    /// account on this Mac: the list belongs to the CLI more than to the login.
    func claudeModels(for connection: ProviderConnection?) -> [HarnessModelOption] {
        Self.preferred(claude, scope: Self.scope(for: connection))
    }

    func codexModels(for connection: ProviderConnection?) -> [CodexModelOption] {
        Self.preferred(codex, scope: Self.scope(for: connection))
    }

    func recordClaude(_ models: [HarnessModelOption], for connection: ProviderConnection?) {
        let scope = Self.scope(for: connection)
        guard !models.isEmpty, claude[scope] != models else { return }
        claude[scope] = models
        save()
    }

    func recordCodex(_ models: [CodexModelOption], for connection: ProviderConnection?) {
        let scope = Self.scope(for: connection)
        guard !models.isEmpty, codex[scope] != models else { return }
        codex[scope] = models
        save()
    }

    /// Keeps what a Codex task's App Server reported, models and the thread's model alike.
    func recordCodex(_ catalog: CodexModelCatalog, for session: SessionRecord) {
        recordCodex(catalog.models, for: session.connection)
        guard let selection = catalog.selection, codexThreads[session.id] != selection else { return }
        codexThreads[session.id] = selection
        save()
    }

    /// The defaults last read for this account and project; nil until a composer asked for them.
    func defaults(for harness: HarnessKind, connection: ProviderConnection?,
                  scope: SessionEnvironmentScope = .native, workspaceURL: URL?) -> HarnessModelDefaults? {
        key(harness, connection, scope, workspaceURL).flatMap { defaults[$0] }
    }

    /// Rereads the account's settings files. Called when a composer appears, so an edit made in
    /// the provider's own settings shows the next time a task or the new-task screen opens. The files
    /// are read off the main thread: a project's folder can be slow to read.
    @discardableResult
    func refreshDefaults(for harness: HarnessKind, connection: ProviderConnection?,
                         scope: SessionEnvironmentScope = .native, workspaceURL: URL?) async -> HarnessModelDefaults? {
        guard harness == .claudeCode || harness == .codex,
              let key = key(harness, connection, scope, workspaceURL),
              let folder = locations.folder(for: harness, connection: connection, scope: scope) else { return nil }
        let workspaceURL = workspaceURL?.standardizedFileURL
        let environment = environment
        let value = await Task.detached(priority: .userInitiated) {
            harness == .claudeCode
                // A saved account's process runs with only its own folder named, as the CLI is told.
                ? HarnessModelDefaultsReader.claude(configDirectory: folder, workspaceURL: workspaceURL,
                                                    environment: environment)
                : HarnessModelDefaultsReader.codex(home: folder)
        }.value
        if defaults[key] != value { defaults[key] = value }
        return value
    }

    private func key(_ harness: HarnessKind, _ connection: ProviderConnection?, _ scope: SessionEnvironmentScope,
                     _ workspaceURL: URL?) -> String? {
        guard let folder = locations.folder(for: harness, connection: connection, scope: scope) else { return nil }
        // Codex reads no project settings for these values; Claude Code does.
        let project = harness == .claudeCode ? workspaceURL?.standardizedFileURL.path(percentEncoded: false) ?? "" : ""
        return [harness.rawValue, folder.standardizedFileURL.path(percentEncoded: false), project]
            .joined(separator: "\u{1F}")
    }

    private static func preferred<Value>(_ lists: [String: [Value]], scope: String) -> [Value] {
        if let exact = lists[scope] { return exact }
        if let native = lists["default"] { return native }
        return lists.keys.sorted().first.flatMap { lists[$0] } ?? []
    }

    private func save() {
        guard let fileURL else { return }
        let snapshot = Snapshot(claude: claude, codex: codex, codexThreads: codexThreads.isEmpty ? nil : codexThreads,
                                antigravity: antigravity.isEmpty ? nil : antigravity,
                                claudeContextWindows: claudeContextWindows.isEmpty ? nil : claudeContextWindows)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            // A list that cannot be kept is read again from the runtime next time.
        }
    }
}
