import AppKit
import Darwin
import Foundation
import YardletAgentTools

/// The macOS side of the Yardlet MCP server: `yardlet-mcp` in `Contents/Helpers`, a Unix domain
/// socket in a private per-run directory under the user's temporary folder, and the CEF browser
/// host for the tabs. The socket starts the first time a task is injected.
@MainActor
final class MacAgentToolService: NativeSurfaceResource {
    static let shared = MacAgentToolService()

    let broker: AgentToolBroker
    let tabs: BrowserAgentTabs
    let connectors: ConnectorCenter
    /// The vault for agents (docs/BROWSER_VAULT_DESIGN.md).
    let vault: VaultCenter
    private let directory: URL
    private var listener: UnixSocketListener?

    /// The helper in the app bundle, or next to the executable in a development build.
    nonisolated static var executableURL: URL? {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/\(AgentToolEnvironment.executableName)")
        if FileManager.default.isExecutableFile(atPath: bundled.path(percentEncoded: false)) { return bundled }
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent()
            .appending(path: AgentToolEnvironment.executableName)
        if let sibling, FileManager.default.isExecutableFile(atPath: sibling.path(percentEncoded: false)) { return sibling }
        return nil
    }

    private init() {
        let temporary = FileManager.default.temporaryDirectory
        Self.removeDirectoriesOfEndedRuns(in: temporary)
        AntigravityLeftoverFolder.removeIfPresent(
            cachesDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let directory = temporary.appending(path: "\(Self.directoryPrefix)\(getpid())", directoryHint: .isDirectory)
        self.directory = directory
        let tabs = BrowserAgentTabs {
            MacBrowserHost.isAvailable ? MacBrowserHost.shared.client : nil
        }
        self.tabs = tabs
        let tools = BrowserAgentTools(usesMacEditingCommands: true, tabs: tabs)
        tools.setupKeysPictured = { image in
            await Task.detached(priority: .userInitiated) {
                VaultQRCodeReader.setups(in: VaultQRCodeReader.messages(in: image)).setups.map(\.secret.key)
            }.value
        }
        tools.clipboardIsConcealed = { VaultClipboard.holdsConcealed() }
        broker = AgentToolBroker(
            environment: AgentToolBroker.Environment(
                executableURL: Self.executableURL,
                endpoint: directory.appending(path: "tools.sock").path(percentEncoded: false),
                privateDirectory: directory
            ),
            tools: tools
        )
        var connectorEnvironment = ConnectorCenter.Environment(
            repository: FileConnectorRepository.live(),
            credentials: Self.connectorCredentials(),
            http: URLSessionConnectorTransport(),
            userAgent: MacOAuthUserAgent(),
            sha256: MacOAuthUserAgent.sha256,
            clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        )
        connectorEnvironment.googleBuiltInApp = GoogleOAuth.BuiltInApp.from(info: Bundle.main.infoDictionary)
        connectorEnvironment.microsoftBuiltInApp = MicrosoftOAuth.BuiltInApp.from(info: Bundle.main.infoDictionary)
        connectorEnvironment.gitHubClientID = GitHubDeviceSignIn.clientID(from: Bundle.main.infoDictionary)
        connectorEnvironment.copyToClipboard = { text in
            TranscriptClipboard.copy(text)
        }
        connectorEnvironment.xcodeBridge = { XcodeBridge.locate() }
        connectorEnvironment.macData = MacEventKitStore.shared
        connectorEnvironment.es256 = MacES256Signer()
        connectorEnvironment.registries = .live
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            connectorEnvironment.programFolders = caches
                .appending(path: Bundle.main.bundleIdentifier ?? "com.zzunkie.yardlet", directoryHint: .isDirectory)
                .appending(path: "ConnectorPrograms", directoryHint: .isDirectory)
        }
        connectors = ConnectorCenter(environment: connectorEnvironment)
        broker.connectors = connectors
        connectors.onToolsChanged = { [weak broker = self.broker] in broker?.toolsMayHaveChanged() }
        vault = MacVault.makeCenter()
        broker.vault = vault
        vault.onToolsChanged = { [weak broker = self.broker] in broker?.toolsMayHaveChanged() }
        broker.startEndpoint = { [unowned self] in try self.startListener() }
        NativeSurfaceResourceRegistry.shared.register(self)
    }

    /// The keychain; a QA run with a temporary home has no login keychain, so it keeps
    /// credentials in memory when asked to.
    private static func connectorCredentials() -> any ConnectorCredentialStoring {
#if DEBUG
        if ProcessInfo.processInfo.environment["YARDLET_CONNECTOR_QA_MEMORY_CREDENTIALS"] == "1" {
            return InMemoryConnectorCredentialStore()
        }
#endif
        return KeychainConnectorCredentialStore.live()
    }

    /// Listens on the socket, unless it already does. The system may clear old files from the temporary
    /// folder, the socket among them, and a listener whose file is gone takes no new call; the next task
    /// injected then listens again at the same path, which every task's server still names.
    private func startListener() throws {
        let path = directory.appending(path: "tools.sock").path(percentEncoded: false)
        if listener != nil, FileManager.default.fileExists(atPath: path) { return }
        listener?.stop()
        listener = nil
        let broker = broker
        listener = try UnixSocketListener(path: path) { body, peer in
            // An agent works while Yardlet sits behind other windows. Without an activity, App Nap
            // coalesces the timers a call waits on (page loads, text waits) into seconds.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Agent browser tool call"
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }
            return await broker.respond(to: body, peer: peer)
        }
    }

#if DEBUG
    /// QA without a model turn: with YARDLET_AGENT_TOOLS_QA=<file>, issues the launch a harness
    /// would get for a stand-in task and writes it to that file, so a script can start
    /// yardlet-mcp itself and speak JSON-RPC to it. YARDLET_AGENT_TOOLS_QA_ROOT is the stand-in
    /// task's folder, for file uploads.
    func writeQALaunchIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["YARDLET_AGENT_TOOLS_QA"], !path.isEmpty,
              let launch = broker.agentToolServer(
                  for: UUID(),
                  workspaceRoots: ProcessInfo.processInfo.environment["YARDLET_AGENT_TOOLS_QA_ROOT"].map { [URL(filePath: $0)] } ?? []
              ) else { return }
        let document: JSONValue = .object([
            "command": .string(launch.command),
            "env": .object(launch.environment.mapValues { .string($0) })
        ])
        let url = URL(filePath: path)
        guard let data = try? JSONEncoder().encode(document) else { return }
        _ = FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: data,
                                           attributes: [.posixPermissions: 0o600])
    }

    /// QA without the settings screen: YARDLET_CONNECTOR_QA_ADD="<name>|<server URL>" adds that
    /// connector when no connector has the address and connects it (with
    /// YARDLET_CONNECTOR_QA_FOLLOW_SIGN_IN=1 the sign-in follows redirects instead of opening a
    /// browser). YARDLET_CONNECTOR_QA_REMOVE_ALL=1 removes every connector, so the app deletes its
    /// own keychain items.
    func runConnectorQAIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        if environment["YARDLET_CONNECTOR_QA_REMOVE_ALL"] == "1" {
            connectors.connectors.map(\.id).forEach(connectors.remove)
        }
        guard let request = environment["YARDLET_CONNECTOR_QA_ADD"], !request.isEmpty else { return }
        let parts = request.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let url = URL(string: parts[1]) else { return }
        if let existing = connectors.connectors.first(where: { $0.serverURL == url }) {
            if existing.status != .connected { connectors.connect(existing.id) }
        } else {
            Task {
                guard let record = try? await connectors.add(name: parts[0], serverURL: url) else { return }
                connectors.connect(record.id)
            }
        }
    }
#endif

    func stop() {}

    func terminateForApplicationShutdown() {
        listener?.stop()
        listener = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Whether `process` is one of `ancestors` or runs under one, by the parent chain the kernel reports.
    nonisolated static func process(_ process: Int32, descendsFromAnyOf ancestors: Set<Int32>) -> Bool {
        var current = process
        for _ in 0..<64 {
            if ancestors.contains(current) { return true }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
            let parent = info.kp_eproc.e_ppid
            guard parent > 1, parent != current else { return false }
            current = parent
        }
        return false
    }

    private static let directoryPrefix = "Yardlet-tools-"

    /// A run that crashed leaves its directory, with its socket and Claude config files, behind.
    private static func removeDirectoriesOfEndedRuns(in temporary: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path(percentEncoded: false))) ?? []
        for name in names where name.hasPrefix(directoryPrefix) {
            guard let pid = Int32(name.dropFirst(directoryPrefix.count)), pid != getpid() else { continue }
            if kill(pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(at: temporary.appending(path: name))
            }
        }
    }
}
