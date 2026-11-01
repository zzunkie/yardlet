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
    struct Key: Hashable, Sendable {
        let harness: HarnessKind
        let executableURL: URL
        let environmentScope: SessionEnvironmentScope
        let connection: ProviderConnection?
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
        startsHarnessesInTaskFolders: Bool? = nil
    ) {
        self.factory = factory
        self.startsHarnessesInTaskFolders = startsHarnessesInTaskFolders ?? (factory == nil)
        self.codexEnvironmentManager = codexEnvironmentManager
        self.routingPolicy = routingPolicy
        self.runtimeOverrides = runtimeOverrides
        self.versions = versions
    }

    func adapter(
        for harness: HarnessKind,
        executableURL: URL,
        environmentScope: SessionEnvironmentScope = .native,
        connection: ProviderConnection? = nil
    ) async -> any HarnessAdapter {
        let key = Key(
            harness: harness,
            executableURL: executableURL.standardizedFileURL,
            environmentScope: environmentScope,
            connection: connection
        )
        if let adapter = adapters[key] {
            return adapter
        }
        // The task keeps the runtime path it recorded; only the process started for it changes.
        let started = runtimeOverrides?.executable(for: harness, requested: key.executableURL) ?? key.executableURL
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
                environmentScope: environmentScope,
                connection: connection,
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
        let started = runtimeOverrides?.executable(for: harness, requested: executableURL.standardizedFileURL)
            ?? executableURL.standardizedFileURL
        return AntigravityTransport.servesACP(version: await versions?.version(of: started))
    }

    func invalidateAll() {
        adapters.removeAll()
    }

    /// Every adapter of `harness`, so the next request starts its runtime again.
    func invalidate(harness: HarnessKind) {
        adapters = adapters.filter { $0.key.harness != harness }
    }

    /// Drops the adapter kept for one harness, CLI, storage and account, so the next request for
    /// them makes a new one; other accounts and storages keep theirs. Given `adapter`, only that one
    /// goes: an adapter made in its place since stays.
    func invalidate(harness: HarnessKind, executableURL: URL, environmentScope: SessionEnvironmentScope,
                    connection: ProviderConnection?, ifStill adapter: (any HarnessAdapter)? = nil) {
        let key = Key(harness: harness, executableURL: executableURL.standardizedFileURL,
                      environmentScope: environmentScope, connection: connection)
        if let adapter, let kept = adapters[key],
           ObjectIdentifier(kept as AnyObject) != ObjectIdentifier(adapter as AnyObject) { return }
        adapters.removeValue(forKey: key)
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
                launchArguments: (HarnessCatalog.descriptor(for: harness)?.launchArguments ?? []) + (connection?.launchArguments ?? []),
                launchEnvironmentOverrides: connection?.environment)
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
