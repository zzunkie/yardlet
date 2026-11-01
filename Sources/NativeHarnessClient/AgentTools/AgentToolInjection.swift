import Foundation
import YardletAgentTools

/// How a harness starts the Yardlet MCP server for one task. Each harness receives it through its
/// own per-session route (Claude `--mcp-config`, Codex thread `config`, ACP `mcpServers`), so no
/// harness configuration file is written and the harness's native app is unaffected.
struct AgentToolServerLaunch: Equatable, Sendable {
    var name = AgentToolEnvironment.serverName
    /// Absolute path of `yardlet-mcp`.
    var command: String
    var arguments: [String] = []
    /// The app endpoint, the task's token, and the task's ID.
    var environment: [String: String]
    /// A directory only the user can open, for files that carry the token.
    var privateDirectory: URL?
    /// The harness's own remote servers that Yardlet's connectors stand in for in this task, as
    /// the harness's configuration writes their addresses (`ConnectorTaskScope.leftOutNativeServers`).
    var leftOutServerURLs: [URL] = []

    /// A Codex MCP call may wait for a page load or a batch, beyond Codex's default limit, and a
    /// session tool may wait for another task's turn (`SessionToolWaiting.ceiling`).
    static let codexToolTimeoutSeconds: Int64 = 1_800

    /// The task suggestion and session tools under Claude Code's names, and `list_task_runs`. A
    /// chip, a read of the person's own tasks and projects, a message, child task or subagent in the
    /// same project, and hiding or showing a project the person asked about need no card (the Claude
    /// app runs its `spawn_task` and session tools so too, `allowedTools`); anything further, and every
    /// `archive_task`, the app itself asks the person about on one card, unless
    /// the task runs without asking.
    /// Of the scheduled-task tools only `list_task_runs` goes without asking, as the Claude app
    /// allows only its own; the CLI asks before the others as it asks before any tool.
    static var claudeAllowedTools: [String] {
        ((TaskSuggestionToolCatalog.tools + SessionToolCatalog.tools).map(\.name) + [ScheduleToolCatalog.listRuns])
            .map { "mcp__\(AgentToolEnvironment.serverName)__\($0)" }
    }

    /// Claude Code's `--mcp-config` document.
    var claudeConfig: JSONValue {
        .object(["mcpServers": .object([name: .object([
            "type": .string("stdio"),
            "command": .string(command),
            "args": .array(arguments.map { .string($0) }),
            "env": .object(environment.mapValues { .string($0) })
        ])])])
    }

    /// Claude Code's `--settings` document leaving the stood-in servers out of this process, or nil
    /// when there are none. `deniedMcpServers` merges from every settings source, the command
    /// line's included ("so users can deny servers for themselves", CLI 2.1.299 and 2.1.304), and
    /// a denied server is not connected at all: no sign-in of its own, nothing in the account's
    /// needs-auth cache. A `serverUrl` matches the host in any case and the path and query by
    /// pattern, so each address goes as written and again with any query; another path on the same
    /// host (Linear's `/mcp/readonly`) stays.
    var claudeSettings: JSONValue? {
        guard !leftOutServerURLs.isEmpty else { return nil }
        let patterns = leftOutServerURLs.flatMap { [$0.absoluteString, $0.absoluteString + "?*"] }
        return .object(["deniedMcpServers": .array(patterns.map { .object(["serverUrl": .string($0)]) })])
    }

    /// Codex's per-thread `config` override. Codex merges it into the user's configuration, so
    /// this adds one `mcp_servers` entry beside the user's own servers. No tool gets an
    /// `approval_mode` of Yardlet's: whether Codex asks before a call follows the task's own
    /// approval setting and the tool's annotations, as for any server (decision of 2026-10-22:
    /// whether approval is skipped follows each harness's own setting).
    var codexConfig: JSONValue {
        .object(["mcp_servers": .object([name: .object([
            "command": .string(command),
            "args": .array(arguments.map { .string($0) }),
            "env": .object(environment.mapValues { .string($0) }),
            "tool_timeout_sec": .integer(Self.codexToolTimeoutSeconds)
        ])])])
    }

    /// ACP's stdio `McpServer`, whose environment is a name/value list.
    var acpServer: JSONValue {
        .object([
            "name": .string(name),
            "command": .string(command),
            "args": .array(arguments.map { .string($0) }),
            "env": .array(environment.keys.sorted().map { key in
                .object(["name": .string(key), "value": .string(environment[key] ?? "")])
            })
        ])
    }

    /// Writes Claude's config to a file only the user can read and returns its path. A file keeps
    /// the token out of the process list, where a JSON argument would show it.
    func writeClaudeConfig(for localSessionID: UUID) throws -> URL {
        guard let privateDirectory else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "No private directory"])
        }
        let url = privateDirectory.appending(path: "claude-\(localSessionID.uuidString.lowercased()).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(claudeConfig)
        let path = url.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(at: url) }
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        return url
    }
}

/// Which per-session route a harness offers for the Yardlet MCP server. Harnesses with none
/// (Muse's MSP, Pi RPC, Cursor, and Antigravity in print mode) run without it; their users can still
/// register MCP servers in the harness itself.
enum AgentToolInjectionRoute: Equatable, Sendable {
    /// Claude Code `--mcp-config`.
    case claudeMCPConfig
    /// Codex `thread/start`, `thread/resume`, and `thread/fork` `config`.
    case codexThreadConfig
    /// ACP `session/new` and `session/load` `mcpServers`.
    case acpSessionMCPServers

    static func route(for harness: HarnessKind) -> AgentToolInjectionRoute? {
        switch HarnessCatalog.descriptor(for: harness)?.transport {
        case .claudeStreamJSON: .claudeMCPConfig
        case .codexAppServer: .codexThreadConfig
        case .acp: .acpSessionMCPServers
        default: nil
        }
    }
}

/// Optional Yardlet tool surface. An adapter whose harness takes MCP servers per session gets the
/// Yardlet server before the session starts, resumes, or forks; nil leaves the session without
/// it. Adapters with no such route (Muse, Pi, Cursor, Antigravity in print mode) do not conform.
protocol HarnessAgentToolConfiguring: Actor {
    func setAgentToolServer(_ server: AgentToolServerLaunch?, for localSessionID: UUID) async
}

/// Issues the Yardlet MCP server launch for a task, or nil when the tools are off or this build
/// cannot run them.
@MainActor
protocol AgentToolLaunchProviding: AnyObject {
    /// `workspaceRoots` are the task's folders, primary first; file uploads may come only from them.
    /// `connectorScope` is the task's harness and the servers it loads itself, which decide the
    /// connectors it gets.
    func agentToolServer(for localSessionID: UUID, workspaceRoots: [URL],
                         connectorScope: ConnectorTaskScope?) -> AgentToolServerLaunch?
    /// The task was archived or deleted: its token stops working and its tab closes.
    func releaseAgentTools(for localSessionID: UUID)
    /// The task's turn ended (it is ready, completed or failed): a change to its tools held for
    /// the turn is told to its server now.
    func taskTurnEnded(_ localSessionID: UUID)
}

extension AgentToolLaunchProviding {
    func taskTurnEnded(_ localSessionID: UUID) {}
}

/// The one setting: agent browser tools, on unless the user turns them off. A change applies to
/// sessions started or resumed afterwards.
enum AgentToolPreference {
    static let browserToolsKey = "Yardlet.agentBrowserTools"

    static func isEnabled(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: browserToolsKey) as? Bool ?? true
    }
}

/// Whether Claude Code processes Yardlet starts load the claude.ai account's own connectors.
/// Off unless the user turns it on: each Claude account carries different claude.ai connectors,
/// and Yardlet's connectors are the ones every account and harness shares. Off is the CLI's own
/// per-process switch, `ENABLE_CLAUDEAI_MCP_SERVERS=false` (2.1.29x: `[claudeai-mcp] Disabled via
/// env var`); nothing is written to the account's settings.
enum ClaudeAIConnectorPreference {
    static let key = "Yardlet.claudeAIConnectors"
    static let environmentVariable = "ENABLE_CLAUDEAI_MCP_SERVERS"

    static func isEnabled(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? false
    }
}

extension ToolJSON {
    init(_ value: JSONValue) {
        switch value {
        case .object(let object): self = .object(object.mapValues(ToolJSON.init))
        case .array(let array): self = .array(array.map(ToolJSON.init))
        case .string(let string): self = .string(string)
        case .integer(let integer): self = .integer(integer)
        case .number(let number): self = .number(number)
        case .bool(let bool): self = .bool(bool)
        case .null: self = .null
        }
    }
}

extension JSONValue {
    init(_ value: ToolJSON) {
        switch value {
        case .object(let object): self = .object(object.mapValues(JSONValue.init))
        case .array(let array): self = .array(array.map(JSONValue.init))
        case .string(let string): self = .string(string)
        case .integer(let integer): self = .integer(integer)
        case .number(let number): self = .number(number)
        case .bool(let bool): self = .bool(bool)
        case .null: self = .null
        }
    }
}
