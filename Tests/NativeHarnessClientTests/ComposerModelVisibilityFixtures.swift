import Foundation
import XCTest
@testable import NativeHarnessClient

/// Claude Code 2.1.291's model list and a Codex catalog, as the fakes report them.
enum ModelVisibilityFixtures {
    static let claudeModels: [HarnessModelOption] = [
        .init(value: "default", name: "Default (recommended)", description: "Opus 5.5 · Best for everyday, complex tasks",
              effortLevels: ["low", "medium", "high", "xhigh", "max"]),
        .init(value: "opus", name: "Opus", description: "Opus 5.5", effortLevels: ["low", "medium", "high", "xhigh", "max"]),
        .init(value: "fable", name: "Fable", description: "Fable 5.1", effortLevels: ["low", "medium", "high", "xhigh", "max"]),
        .init(value: "sonnet", name: "Sonnet", description: "Sonnet 5.5", effortLevels: ["low", "medium", "high", "xhigh", "max"]),
        .init(value: "haiku", name: "Haiku", description: "Haiku 4.5")
    ]

    /// The `initialize` answer's models, in the CLI's own shape.
    static var claudeInitialize: JSONValue {
        .object(["models": .array(claudeModels.map { option in
            var model: [String: JSONValue] = ["value": .string(option.value), "displayName": .string(option.name)]
            if let description = option.description { model["description"] = .string(description) }
            if !option.effortLevels.isEmpty {
                model["supportsEffort"] = .bool(true)
                model["supportedEffortLevels"] = .array(option.effortLevels.map { .string($0) })
            }
            return .object(model)
        })])
    }

    static func codexModel(_ id: String, efforts: [String], isDefault: Bool = false) -> CodexModelOption {
        CodexModelOption(id: id, model: id, displayName: id.split(separator: "-").map { $0.capitalized }.joined(separator: "-"),
                         defaultReasoningEffort: efforts.last ?? "low", supportedReasoningEfforts: efforts, isDefault: isDefault)
    }
}

final class ModelVisibilityTransportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [FakeClaudeTransport] = []
    /// What each fake CLI answers to `initialize` and `get_settings`.
    private let initializeResponse: JSONValue
    private let effectiveSettings: [String: JSONValue]
    private let appliedSettings: [String: JSONValue]

    init(initializeResponse: JSONValue = ModelVisibilityFixtures.claudeInitialize,
         effectiveSettings: [String: JSONValue] = [:], appliedSettings: [String: JSONValue] = [:]) {
        self.initializeResponse = initializeResponse
        self.effectiveSettings = effectiveSettings
        self.appliedSettings = appliedSettings
    }

    func make() -> FakeClaudeTransport {
        let transport = FakeClaudeTransport(initializeResponse: initializeResponse,
                                            effectiveSettings: effectiveSettings, appliedSettings: appliedSettings)
        lock.withLock { transports.append(transport) }
        return transport
    }
    var all: [FakeClaudeTransport] { lock.withLock { transports } }
}

/// A Claude task saved on an account folder that has not connected this launch, behind the
/// product route with a fake CLI.
@MainActor
struct ClaudeFixture {
    let root: URL
    let cli: URL
    let connection: ProviderConnection
    let model: AppModel
    let session: SessionRecord
    let transports: ModelVisibilityTransportLog

    static func make(settings: String, createsSession: Bool = true,
                     transports: ModelVisibilityTransportLog = ModelVisibilityTransportLog(),
                     in test: XCTestCase) async throws -> ClaudeFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "model-visibility-claude-\(UUID().uuidString)")
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let account = root.appending(path: "account")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        try Data(settings.utf8).write(to: account.appending(path: "settings.json"))
        let cli = root.appending(path: "claude-fixture")
        try Data("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo '2.1.291 (Claude Code)'; exit 0; fi\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let connection = ProviderConnection(id: "account", name: "developer@example.test", harness: .claudeCode,
                                            providerID: nil, homePath: account.path, credentialSelector: nil)
        let session = SessionRecord(harness: .claudeCode, workspaceURL: root, runtimeExecutableURL: cli,
            title: "Saved", status: .completed, providerSessionID: UUID().uuidString.lowercased(),
            connection: connection)
        let suite = testDefaultsSuite("ModelVisibility")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let sessions = createsSession ? [session] : []
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, url in
                YHPProviderCompatibilityAdapter(
                    adapter: ClaudeAdapter(executableURL: url, transportFactory: { _ in transports.make() }),
                    manifest: HarnessProtocolCompatibilityManifest.claude())
            },
            modelCatalogs: HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
                claudeConfigDirectory: root.appending(path: "no-default-login"),
                codexHome: root.appending(path: "codex"), codexYardletHome: root.appending(path: "codex-yardlet")),
                environment: [:]),
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            restoresIndexOnLaunch: false
        )
        test.addTeardownBlock { await model.shutdown() }
        return ClaudeFixture(root: root, cli: cli, connection: connection, model: model, session: session,
                             transports: transports)
    }
}

/// A Codex task that has not connected this launch, with a fake App Server and a Codex home of
/// its own.
@MainActor
struct CodexFixture {
    let root: URL
    let executable: URL
    let transport: FakeCodexTransport
    let session: SessionRecord
    let model: AppModel

    init(config: String, stored: Bool = true, catalogs: HarnessModelCatalogStore? = nil, in test: XCTestCase) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "model-visibility-codex-\(UUID().uuidString)")
        self.root = root
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "codex-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: home.appending(path: "config.toml"))
        executable = root.appending(path: "codex")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.160.0\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        transport = FakeCodexTransport(responses: Self.responses())
        let adapter = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: executable, transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.codex())
        session = SessionRecord(harness: .codex, workspaceURL: root, runtimeExecutableURL: executable,
            title: "Saved", status: .completed, providerSessionID: "original")
        let sessionID = session.id
        let sessions = stored ? [session] : []
        let suite = testDefaultsSuite("ModelVisibility")
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in adapter },
            modelCatalogs: catalogs ?? HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
                claudeConfigDirectory: root.appending(path: "claude"), codexHome: home,
                codexYardletHome: root.appending(path: "codex-yardlet")), environment: [:]),
            initialCodexCapabilities: catalogs.map { [sessionID: CodexCapabilityState(modelCatalog: .init(models: $0.codexModels(for: nil)))] } ?? [:],
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            restoresIndexOnLaunch: false)
        self.model = model
        test.addTeardownBlock { await model.shutdown() }
    }

    private static func responses() -> [String: [JSONValue]] {
        func thread(_ id: String) -> JSONValue {
            .object(["thread": .object(["id": .string(id), "status": .object(["type": .string("idle")]),
                "historyMode": .string("paginated"), "turns": .array([])]),
                "model": .string("gpt-test"), "reasoningEffort": .string("high")])
        }
        func model(_ id: String, efforts: [String], isDefault: Bool) -> JSONValue {
            .object(["id": .string(id), "model": .string(id), "displayName": .string(id),
                "defaultReasoningEffort": .string(efforts.last!), "isDefault": .bool(isDefault),
                "supportedReasoningEfforts": .array(efforts.map { .object(["reasoningEffort": .string($0)]) })])
        }
        let empty = JSONValue.object(["data": .array([]), "nextCursor": .null])
        return ["initialize": [.object(["platformOs": .string("macos")])],
                "thread/resume": [thread("original")], "thread/start": [thread("new-thread")],
                "thread/read": Array(repeating: thread("original"), count: 6),
                "thread/items/list": Array(repeating: empty, count: 4),
                "thread/turns/list": Array(repeating: empty, count: 4),
                "thread/name/set": [.object([:])],
                "model/list": [.object(["data": .array([model("gpt-test", efforts: ["low", "high"], isDefault: true),
                                                         model("fast", efforts: ["low"], isDefault: false)]),
                                        "nextCursor": .null])],
                "turn/start": [.object(["turn": .object(["id": .string("turn-1")])])]]
    }
}
