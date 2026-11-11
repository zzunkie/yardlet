import Foundation

enum HarnessAdapterRoute: Sendable {
    case legacy
    case yardletProtocol
}

struct HarnessRoutingPolicy: Sendable {
    let codex: HarnessAdapterRoute
    let structuredHeadless: HarnessAdapterRoute
    let msp: HarnessAdapterRoute
    let acp: HarnessAdapterRoute
    let piRPC: HarnessAdapterRoute
    let claude: HarnessAdapterRoute

    static let productDefault = HarnessRoutingPolicy(
        codex: .yardletProtocol,
        structuredHeadless: .yardletProtocol,
        msp: .yardletProtocol,
        acp: .yardletProtocol,
        piRPC: .yardletProtocol,
        claude: .yardletProtocol
    )
    static let legacy = HarnessRoutingPolicy(
        codex: .legacy,
        structuredHeadless: .legacy,
        msp: .legacy,
        acp: .legacy,
        piRPC: .legacy,
        claude: .legacy
    )

    func route(for harness: HarnessKind) -> HarnessAdapterRoute {
        if harness == .codex {
            return codex
        }
        if harness == .cursorAgent {
            return structuredHeadless
        }
        if harness == .claudeCode {
            return claude
        }
        if HarnessCatalog.descriptor(for: harness)?.transport == .msp {
            return msp
        }
        if HarnessCatalog.descriptor(for: harness)?.transport == .acp {
            return acp
        }
        if HarnessCatalog.descriptor(for: harness)?.transport == .piRPC {
            return piRPC
        }
        return .legacy
    }
}

actor HarnessRegistry {
    /// What an adapter is kept for: a harness, the CLI it runs, the storage and the account.
    struct Key: Hashable, Sendable {
        let harness: HarnessKind
        let executableURL: URL
        let environmentScope: SessionEnvironmentScope
        let connection: ProviderConnection?

        init(harness: HarnessKind, executableURL: URL, environmentScope: SessionEnvironmentScope = .native,
             connection: ProviderConnection? = nil) {
            self.harness = harness
            self.executableURL = executableURL.standardizedFileURL
            self.environmentScope = environmentScope
            self.connection = connection
        }
    }

    typealias Factory = @Sendable (HarnessKind, URL) -> any HarnessAdapter

    private let factory: Factory?
    private let codexEnvironmentManager: CodexEnvironmentManager?
    private let routingPolicy: HarnessRoutingPolicy
    /// The earlier CLI version to start in place of an install whose update failed Yardlet's check.
    private let runtimeOverrides: CLIRuntimeOverrides?
    /// The versions runtimes reported, read again only when a file changes. Antigravity CLI runs
    /// over ACP from the version that serves it and in print mode before (`AntigravityTransport`);
    /// without this, it keeps print mode.
    private let versions: RuntimeVersionCache?
    /// Where Antigravity's `agy acp` processes leave schema copies that go once they exit
    /// (`AntigravitySchemaCopies`). The app passes the CLI's own folder; without it nothing is removed.
    private let antigravitySchemaCopies: AntigravitySchemaCopies?
    private var adapters: [Key: any HarnessAdapter] = [:]
    /// The adapters start each task's harness in the task's folder, so a task whose folder is gone
    /// cannot be run (`TaskFolderMissing`). Its own adapters do; a factory's are the caller's, which
    /// say so themselves.
    nonisolated let startsHarnessesInTaskFolders: Bool

    init(
        factory: Factory? = nil,
        codexEnvironmentManager: CodexEnvironmentManager? = nil,
        routingPolicy: HarnessRoutingPolicy = .productDefault,
        runtimeOverrides: CLIRuntimeOverrides? = nil,
        versions: RuntimeVersionCache? = nil,
        antigravitySchemaCopies: AntigravitySchemaCopies? = nil,
        startsHarnessesInTaskFolders: Bool? = nil
    ) {
        self.factory = factory
        self.startsHarnessesInTaskFolders = startsHarnessesInTaskFolders ?? (factory == nil)
        self.codexEnvironmentManager = codexEnvironmentManager
        self.routingPolicy = routingPolicy
        self.runtimeOverrides = runtimeOverrides
        self.versions = versions
        self.antigravitySchemaCopies = antigravitySchemaCopies
    }

    func adapter(
        for harness: HarnessKind,
        executableURL: URL,
        environmentScope: SessionEnvironmentScope = .native,
        connection: ProviderConnection? = nil
    ) async -> any HarnessAdapter {
        await adapter(for: Key(harness: harness, executableURL: executableURL, environmentScope: environmentScope,
                               connection: connection))
    }

    /// The adapter kept for `key`, made when there is none. Asking starts no runtime.
    func adapter(for key: Key) async -> any HarnessAdapter {
        if let adapter = adapters[key] {
            return adapter
        }
        let harness = key.harness
        // The key names the runtime asked for; an earlier version held in its place is what starts.
        let started = startedExecutable(for: harness, requested: key.executableURL)
        let antigravityPrintMode = factory == nil && harness == .antigravityCLI
            ? !(await servesACP(.antigravityCLI, executableURL: started)) : false
        // Another request may have made it while the version was read.
        if let adapter = adapters[key] {
            return adapter
        }
        let adapter = factory?(harness, started)
            ?? makeDefaultAdapter(
                harness: harness,
                executableURL: started,
                environmentScope: key.environmentScope,
                connection: key.connection,
                antigravityPrintMode: antigravityPrintMode
            )
        adapters[key] = adapter
        return adapter
    }

    /// Whether `harness` at `executableURL` runs over ACP, from the version the runtime reported
    /// (`--version` runs only when the file changed since it was last read). Antigravity CLI does
    /// from `AntigravityTransport.acpMinimum`; every other harness keeps its catalog transport.
    func servesACP(_ harness: HarnessKind, executableURL: URL) async -> Bool {
        guard HarnessCatalog.descriptor(for: harness)?.transport == .acp else { return false }
        guard harness == .antigravityCLI else { return true }
        let started = startedExecutable(for: harness, requested: executableURL)
        return AntigravityTransport.servesACP(version: await versions?.version(of: started))
    }

    /// The CLI a request for `requested` starts: the earlier version Yardlet holds while an update
    /// failed its check (`CLIRuntimeOverrides`), else `requested` itself.
    func startedExecutable(for harness: HarnessKind, requested: URL) -> URL {
        runtimeOverrides?.executable(for: harness, requested: requested.standardizedFileURL) ?? requested.standardizedFileURL
    }

    func invalidateAll() {
        adapters.removeAll()
    }

    /// Every adapter of `harness`, so the next request starts its runtime again.
    func invalidate(harness: HarnessKind) {
        adapters = adapters.filter { $0.key.harness != harness }
    }

    /// Drops the adapter kept for one harness, CLI, storage and account, so the next request for
    /// them makes a new one; other accounts and storages keep theirs.
    func invalidate(_ key: Key) {
        adapters.removeValue(forKey: key)
    }

    /// Drops `adapter` from wherever it is kept, so the next request for its harness, CLI, storage
    /// and account makes a new one. What it is kept under is the registry's to know: the harness's
    /// CLI may have changed since the task got the adapter. An adapter made in its place since stays.
    func invalidate(_ adapter: any HarnessAdapter) {
        let identity = ObjectIdentifier(adapter as AnyObject)
        adapters = adapters.filter { ObjectIdentifier($0.value as AnyObject) != identity }
    }

    private func makeDefaultAdapter(
        harness: HarnessKind,
        executableURL: URL,
        environmentScope: SessionEnvironmentScope,
        connection: ProviderConnection?,
        antigravityPrintMode: Bool
    ) -> any HarnessAdapter {
        if harness == .codex {
            let legacy = CodexAdapter(
                executableURL: executableURL,
                environmentManager: connection?.codexEnvironmentManager() ?? codexEnvironmentManager
                    ?? CodexEnvironmentManager(paths: .live()),
                environmentScope: environmentScope,
                namesNewThreads: true,
                predictsNextMessages: true,
                // The App Server every task of this account and scope shares: its own row in Task
                // Resource Usage.
                resourceOwner: .codexAppServer(CodexAppServerIdentity(connection: connection,
                                                                      environmentScope: environmentScope))
            )
            switch routingPolicy.route(for: harness) {
            case .legacy:
                return legacy
            case .yardletProtocol:
                return YHPCodexCompatibilityAdapter(
                    adapter: legacy,
                    manifest: HarnessProtocolCompatibilityManifest.codex()
                )
            }
        }
        if harness == .claudeCode {
            let legacy = ClaudeAdapter(executableURL: executableURL, environmentOverrides: connection?.environment ?? [:])
            switch routingPolicy.route(for: harness) {
            case .legacy:
                return legacy
            case .yardletProtocol:
                return YHPProviderCompatibilityAdapter(
                    adapter: legacy,
                    manifest: HarnessProtocolCompatibilityManifest.claude()
                )
            }
        }
        if HarnessCatalog.descriptor(for: harness)?.transport == .msp {
            let legacy = MuseAdapter(
                kind: harness,
                executableURL: executableURL,
                launchArguments: HarnessCatalog.descriptor(for: harness)?.launchArguments
                    ?? ["serve"]
            )
            switch routingPolicy.route(for: harness) {
            case .legacy:
                return legacy
            case .yardletProtocol:
                return YHPProviderCompatibilityAdapter(
                    adapter: legacy,
                    manifest: HarnessProtocolCompatibilityManifest.msp(harness)
                )
            }
        }
        if HarnessCatalog.descriptor(for: harness)?.transport == .acp, !antigravityPrintMode {
            let legacy = ACPAdapter(kind: harness, executableURL: executableURL,
                launchArguments: ACPLaunchConfiguration.arguments(for: harness, connection: connection),
                launchEnvironmentOverrides: connection?.environment,
                schemaCopies: harness == .antigravityCLI ? antigravitySchemaCopies?.counting(executableURL) : nil,
                conversationStore: harness == .antigravityCLI ? .live : nil)
            switch routingPolicy.route(for: harness) {
            case .legacy:
                return legacy
            case .yardletProtocol:
                return YHPProviderCompatibilityAdapter(
                    adapter: legacy,
                    manifest: HarnessProtocolCompatibilityManifest.acp(harness)
                )
            }
        }
        if HarnessCatalog.descriptor(for: harness)?.transport == .piRPC {
            let legacy = PiRPCAdapter(kind: harness, executableURL: executableURL,
                launchArguments: (HarnessCatalog.descriptor(for: harness)?.launchArguments ?? []) + (connection?.launchArguments ?? []),
                environmentOverrides: connection?.environment ?? [:])
            switch routingPolicy.route(for: harness) {
            case .legacy:
                return legacy
            case .yardletProtocol:
                return YHPProviderCompatibilityAdapter(
                    adapter: legacy,
                    manifest: HarnessProtocolCompatibilityManifest.piRPC(harness)
                )
            }
        }
        if harness == .cursorAgent || harness == .antigravityCLI {
            let legacy = StructuredHeadlessAdapter(kind: harness, executableURL: executableURL)
            switch routingPolicy.route(for: harness) {
            case .legacy:
                return legacy
            case .yardletProtocol:
                return YHPProviderCompatibilityAdapter(
                    adapter: legacy,
                    manifest: HarnessProtocolCompatibilityManifest.structuredHeadless(harness),
                    interruptEventPolicy: .synthesizeCanceled,
                    canceledTurnProjection: .omit
                )
            }
        }
        return UnsupportedHarnessAdapter(kind: harness, executableURL: executableURL)
    }
}
