import Foundation

/// An MCP server a harness loads from its own configuration: Claude Code's `.claude.json` and a
/// project's `.mcp.json`, Codex's `config.toml`, Antigravity's `mcp_config.json`. Yardlet reads these
/// files only to show what each harness has and to avoid offering a connector twice
/// (docs/CONNECTORS.md, "Harnesses' own servers"). It keeps the name, the address without its query, and a
/// stdio server's program name; never a header, an environment value, or a query string, which is
/// where such entries keep their secrets. Nothing here writes a file.
struct NativeMCPServer: Equatable, Hashable, Sendable, Identifiable {
    enum Scope: Equatable, Hashable, Sendable {
        /// Claude Code `mcpServers` at the top of `.claude.json` (`claude mcp add --scope user`).
        case claudeUser
        /// Claude Code `projects.<folder>.mcpServers` (`--scope local`).
        case claudeLocal(project: String)
        /// A project's `.mcp.json` (`--scope project`).
        case claudeProject(project: String)
        /// Codex `[mcp_servers.<name>]`.
        case codex
        /// Antigravity `mcp_config.json`.
        case antigravity
        /// An editor or app that is not a Yardlet harness (`NativeMCPApp`).
        case app(NativeMCPApp)
    }

    var name: String
    /// A remote server's address with no query, fragment or user info.
    var url: URL?
    /// A stdio server's program, by file name alone (`npx`).
    var command: String?
    /// The program as the settings wrote it, path included; kept only to tell an app's own helper
    /// apart. Nil for a remote server.
    var launchPath: String?
    /// For `npx`-style launches, the first argument naming a package (`@browserbasehq/mcp`).
    var package: String?
    var scope: Scope
    var isEnabled: Bool = true

    var id: String { "\(scope)|\(name)" }

    /// A program inside an app's bundle (Codex's `node_repl` and computer use, a browser
    /// extension's host): it works only for that app, so it is not offered elsewhere.
    var isAppHelper: Bool { launchPath?.contains(".app/Contents/") == true }

    /// The program and package it starts, as a program connector would name them, for noticing
    /// the same server started twice; nil for a remote server or a program without a package.
    var programKey: String? {
        guard let command, let package else { return nil }
        return ConnectorPrograms.key(program: command, package: package)
    }

    /// What a row shows after the name: the host and path, or the program and package.
    var detail: String {
        if let url { return (url.host() ?? "") + (url.path() == "/" ? "" : url.path()) }
        return [command, package].compactMap { $0 }.joined(separator: " ")
    }
}

/// Server addresses compared the way a duplicate would be noticed: scheme and host in lowercase,
/// no default port, no trailing slash, and no query or fragment.
/// A remote server a task's harness loads itself: its name there and its address as written,
/// without query, fragment or user info.
struct HarnessRemoteServer: Equatable, Hashable, Sendable {
    var name: String
    var url: URL

    init(name: String, url: URL) {
        self.name = name
        self.url = url
    }

    init?(_ server: NativeMCPServer) {
        guard let url = server.url else { return nil }
        self.init(name: server.name, url: url)
    }

    var address: String { MCPServerAddress.canonical(url) }
}

enum MCPServerAddress {
    static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? url.absoluteString
    }

    /// The address without what may carry a secret, for keeping and showing.
    static func shown(_ text: String) -> URL? {
        guard var components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.isEmpty == false
        else { return nil }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }
}

/// Claude Code's `.claude.json`, as far as MCP goes.
struct ClaudeNativeMCPConfig: Equatable, Sendable {
    struct Project: Equatable, Sendable {
        var servers: [NativeMCPServer] = []
        /// `disabledMcpServers`: names the user turned off in this folder (claude.ai connectors too).
        var disabled: Set<String> = []
        /// `.mcp.json` approvals kept with the project entry.
        var enabledProjectServers: Set<String> = []
        var enablesAllProjectServers = false
        var disabledProjectServers: Set<String> = []
    }

    var userServers: [NativeMCPServer] = []
    var projects: [String: Project] = [:]
    /// claude.ai connectors this login has used (`claudeAiMcpEverConnected`), as the CLI names them
    /// ("claude.ai Gmail"). Names only; the connectors themselves live in the claude.ai account.
    var claudeAIConnectors: [String] = []
    /// The claude.ai account this login is signed in to (`oauthAccount`), as the Usage lines name it:
    /// the address, with a team's organization after it. Nil when signed out.
    var account: String?

    static let claudeAIPrefix = "claude.ai "

    static func parse(_ data: Data) -> ClaudeNativeMCPConfig {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), root.objectValue != nil else {
            return ClaudeNativeMCPConfig()
        }
        var config = ClaudeNativeMCPConfig()
        config.userServers = servers(root["mcpServers"], scope: .claudeUser)
        for (path, entry) in root["projects"]?.objectValue ?? [:] {
            var project = Project()
            project.servers = servers(entry["mcpServers"], scope: .claudeLocal(project: path))
            project.disabled = names(entry["disabledMcpServers"])
            project.enabledProjectServers = names(entry["enabledMcpjsonServers"])
            project.disabledProjectServers = names(entry["disabledMcpjsonServers"])
            project.enablesAllProjectServers = entry["enableAllProjectMcpServers"]?.boolValue == true
            if !project.servers.isEmpty || !project.disabled.isEmpty || !project.enabledProjectServers.isEmpty
                || project.enablesAllProjectServers {
                config.projects[path] = project
            }
        }
        config.claudeAIConnectors = (root["claudeAiMcpEverConnected"]?.arrayValue ?? []).compactMap(\.stringValue)
            .filter { $0.hasPrefix(claudeAIPrefix) }
        if let email = root["oauthAccount"]?["emailAddress"]?.stringValue, !email.isEmpty {
            let organization = AccountIdentityProjection.sharedOrganization(
                root["oauthAccount"]?["organizationName"]?.stringValue, of: email)
            config.account = organization.map { "\(email) (\($0))" } ?? email
        }
        return config
    }

    /// A project's `.mcp.json`: `{"mcpServers": {...}}`.
    static func projectServers(_ data: Data, project: String) -> [NativeMCPServer] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return servers(root["mcpServers"], scope: .claudeProject(project: project))
    }

    static func servers(_ value: JSONValue?, scope: NativeMCPServer.Scope) -> [NativeMCPServer] {
        (value?.objectValue ?? [:]).sorted { $0.key < $1.key }.compactMap { name, entry in
            NativeMCPConfigFiles.server(named: name, entry: entry, scope: scope)
        }
    }

    private static func names(_ value: JSONValue?) -> Set<String> {
        Set((value?.arrayValue ?? []).compactMap(\.stringValue))
    }
}

/// Codex's `config.toml`, as far as MCP goes: `[mcp_servers.<name>]`, the plugins it enables, and
/// the ChatGPT apps (connectors) it has settings for.
struct CodexNativeMCPConfig: Equatable, Sendable {
    /// A ChatGPT app's settings, `[apps.<id>]`: whether it is on, and the tools it names
    /// (`[apps.<id>.tools."linear.save_comment"]`), which say whose app it is when no name is cached.
    struct App: Equatable, Sendable {
        var id: String
        var isEnabled = true
        var toolNames: [String] = []

        /// The service its tools are named after (`linear` for `linear.save_comment` or
        /// `linear_save_comment`), when they agree.
        var serviceFromToolNames: String? {
            let prefixes = Set(toolNames.compactMap { name -> String? in
                let piece = name.split(whereSeparator: { $0 == "." || $0 == "_" }).first.map(String.init)
                return piece?.isEmpty == false ? piece?.lowercased() : nil
            })
            return prefixes.count == 1 ? prefixes.first : nil
        }
    }

    var servers: [NativeMCPServer] = []
    /// `[plugins."<id>"]` not turned off, by ID (`linear@openai-curated`).
    var plugins: [String] = []
    var apps: [App] = []

    /// Reads only table headers and `url`, `command`, `args`, `enabled` lines, which is all MCP
    /// needs; a value it cannot read is skipped rather than guessed.
    static func parse(_ text: String) -> CodexNativeMCPConfig {
        struct Entry { var url: String?; var command: String?; var package: String?; var enabled = true }
        var servers: [(String, Entry)] = []
        var plugins: [(String, Bool)] = []
        var apps: [App] = []
        var table: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("[") {
                guard !line.hasPrefix("[["), let end = line.lastIndex(of: "]") else { table = ["\u{0}"]; continue }
                table = tablePath(String(line[line.index(after: line.startIndex)..<end]))
                if table.count == 2, table[0] == "mcp_servers", !servers.contains(where: { $0.0 == table[1] }) {
                    servers.append((table[1], Entry()))
                } else if table.count == 2, table[0] == "plugins", !plugins.contains(where: { $0.0 == table[1] }) {
                    plugins.append((table[1], true))
                } else if table.count >= 2, table[0] == "apps" {
                    if !apps.contains(where: { $0.id == table[1] }) { apps.append(App(id: table[1])) }
                    if table.count == 4, table[2] == "tools", let index = apps.firstIndex(where: { $0.id == table[1] }) {
                        apps[index].toolNames.append(table[3])
                    }
                }
                continue
            }
            if table.count == 2, table[0] == "apps", let equals = line.firstIndex(of: "="),
               line[..<equals].trimmingCharacters(in: .whitespaces) == "enabled",
               let index = apps.firstIndex(where: { $0.id == table[1] }) {
                apps[index].isEnabled = !line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces).hasPrefix("false")
                continue
            }
            guard table.count == 2, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if table[0] == "mcp_servers", let index = servers.firstIndex(where: { $0.0 == table[1] }) {
                switch key {
                case "url": servers[index].1.url = string(value)
                case "command": servers[index].1.command = string(value)
                case "args": servers[index].1.package = firstPackage(in: value)
                case "enabled": servers[index].1.enabled = !value.hasPrefix("false")
                default: break
                }
            } else if table[0] == "plugins", key == "enabled", let index = plugins.firstIndex(where: { $0.0 == table[1] }) {
                plugins[index].1 = !value.hasPrefix("false")
            }
        }
        var config = CodexNativeMCPConfig()
        config.servers = servers.compactMap { name, entry in
            var server: NativeMCPServer
            if let text = entry.url {
                guard let url = MCPServerAddress.shown(text) else { return nil }
                server = NativeMCPServer(name: name, url: url, scope: .codex)
            } else if let command = entry.command {
                server = NativeMCPServer(name: name, command: NativeMCPConfigFiles.programName(command),
                                         package: entry.package, scope: .codex)
                server.launchPath = command
            } else {
                return nil
            }
            server.isEnabled = entry.enabled
            return server
        }
        config.plugins = plugins.filter(\.1).map(\.0)
        config.apps = apps
        return config
    }

    /// `mcp_servers."a.b"` → ["mcp_servers", "a.b"]: dots split parts except inside quotes.
    private static func tablePath(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in header {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "." {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }

    private static func string(_ value: String) -> String? {
        guard let quote = value.first, quote == "\"" || quote == "'" else { return nil }
        let body = value.dropFirst()
        guard let close = body.firstIndex(of: quote) else { return nil }
        return String(body[..<close])
    }

    /// The package a quoted argument list names, if any (`NativeMCPConfigFiles.packageName`).
    private static func firstPackage(in value: String) -> String? {
        guard value.hasPrefix("[") else { return nil }
        let pieces = value.split(separator: "\"", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
        return NativeMCPConfigFiles.packageName(in: pieces)
    }
}

/// Codex's cache of the ChatGPT apps' tools (`{"tools": [{"connector_id", "connector_name", …}]}`),
/// read for the app names alone.
enum CodexAppToolsCache {
    private struct File: Decodable {
        struct Tool: Decodable {
            var connector_id: String?
            var connector_name: String?
        }
        var tools: [Tool]
    }

    /// Connector ID → name, without OpenAI's own built-in apps (`connector_openai_*`).
    static func names(_ data: Data) -> [String: String] {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        var names: [String: String] = [:]
        for tool in file.tools {
            guard let id = tool.connector_id, !id.hasPrefix("connector_openai_"),
                  let name = tool.connector_name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }
}

/// Apps that keep MCP servers of their own and are not Yardlet harnesses: the Claude app
/// (`claude_desktop_config.json`), Cursor (`~/.cursor/mcp.json`) and VS Code (`mcp.json` in the
/// user folder, which may hold comments). Read only, like the harnesses' files.
enum NativeMCPApp: String, CaseIterable, Equatable, Hashable, Sendable {
    case claudeApp
    case cursor
    case vscode
    case vscodeInsiders

    var name: String {
        switch self {
        case .claudeApp: L10n.string("Claude app")
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        case .vscodeInsiders: "VS Code Insiders"
        }
    }

    func file(home: URL) -> URL {
        let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return switch self {
        case .claudeApp: support.appending(path: "Claude/claude_desktop_config.json")
        case .cursor: home.appending(path: ".cursor/mcp.json")
        case .vscode: support.appending(path: "Code/User/mcp.json")
        case .vscodeInsiders: support.appending(path: "Code - Insiders/User/mcp.json")
        }
    }

    /// VS Code keeps its servers under `servers`; the others under `mcpServers`.
    var serversKey: String {
        switch self {
        case .vscode, .vscodeInsiders: "servers"
        case .claudeApp, .cursor: "mcpServers"
        }
    }

    static func parse(_ data: Data, app: NativeMCPApp) -> [NativeMCPServer] {
        guard let root = NativeMCPConfigFiles.json(data) else { return [] }
        return ClaudeNativeMCPConfig.servers(root[app.serversKey], scope: .app(app))
    }
}

/// Antigravity's `mcp_config.json` (`{"mcpServers": {...}}`, remote servers under `serverUrl`).
enum AntigravityNativeMCPConfig {
    static func parse(_ data: Data) -> [NativeMCPServer] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return ClaudeNativeMCPConfig.servers(root["mcpServers"], scope: .antigravity)
    }
}

/// Reading the files themselves: size-limited, cached by modification date, never written.
enum NativeMCPConfigFiles {
    /// Larger files are not read; a `.claude.json` with long histories stays well under this.
    static let maximumSize = 16 * 1_048_576

    static func server(named name: String, entry: JSONValue, scope: NativeMCPServer.Scope) -> NativeMCPServer? {
        guard entry.objectValue != nil else { return nil }
        let address = entry["url"]?.stringValue ?? entry["serverUrl"]?.stringValue ?? entry["httpUrl"]?.stringValue
        var server: NativeMCPServer
        if let address {
            guard let url = MCPServerAddress.shown(address) else { return nil }
            server = NativeMCPServer(name: name, url: url, scope: scope)
        } else if let command = entry["command"]?.stringValue {
            let package = packageName(in: (entry["args"]?.arrayValue ?? []).compactMap(\.stringValue))
            server = NativeMCPServer(name: name, command: programName(command), package: package, scope: scope)
            server.launchPath = command
        } else {
            return nil
        }
        if entry["disabled"]?.boolValue == true || entry["enabled"]?.boolValue == false { server.isEnabled = false }
        return server
    }

    /// The npm package a launch names: a scoped name (`@browserbasehq/mcp`) or one with "mcp" in
    /// it. Any other argument, which may be a key passed on the command line, is never kept.
    static func packageName(in arguments: [String]) -> String? {
        let packages = arguments.filter { argument in
            argument.range(of: #"^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*(@[a-z0-9._^~-]+)?$"#,
                           options: .regularExpression) != nil
                && (argument.hasPrefix("@") || argument.contains("mcp"))
        }
        // An installer launch (`npx @smithery/cli install @browserbasehq/mcp-browserbase`) names
        // the server's package after its own.
        return packages.first { $0.contains("mcp") } ?? packages.first
    }

    static func programName(_ command: String) -> String {
        URL(filePath: command).lastPathComponent
    }

    private static let cache = Cache()

    /// The file's path and modification date, or nil when it is missing or too large.
    private static func stamp(_ url: URL) -> (path: String, modified: Date?)? {
        let path = url.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size <= maximumSize else { return nil }
        return (path, attributes[.modificationDate] as? Date)
    }

    /// The file's bytes, or nil when it is missing, too large, or unreadable.
    static func data(_ url: URL) -> Data? {
        guard stamp(url) != nil else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The file parsed, reused while its modification date stays. Only the parsed result, which
    /// holds no secret, is kept; the file's bytes are not.
    private static func parsed<T: Sendable>(_ url: URL, _ parse: (Data) -> T) -> T? {
        guard let stamp = stamp(url) else { return nil }
        if let cached: T = cache.value(for: stamp.path, modified: stamp.modified) { return cached }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let value = parse(data)
        cache.store(value, for: stamp.path, modified: stamp.modified)
        return value
    }

    static func claude(_ file: URL) -> ClaudeNativeMCPConfig? {
        parsed(file, ClaudeNativeMCPConfig.parse)
    }

    static func codex(home: URL) -> CodexNativeMCPConfig? {
        parsed(home.appending(path: "config.toml")) { CodexNativeMCPConfig.parse(String(decoding: $0, as: UTF8.self)) }
    }

    static func antigravity(_ file: URL) -> [NativeMCPServer] {
        parsed(file, AntigravityNativeMCPConfig.parse) ?? []
    }

    static func app(_ app: NativeMCPApp, file: URL) -> [NativeMCPServer] {
        parsed(file) { NativeMCPApp.parse($0, app: app) } ?? []
    }

    /// JSON, or JSON with comments and trailing commas as VS Code writes it.
    static func json(_ data: Data) -> JSONValue? {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) { return value }
        return try? JSONDecoder().decode(JSONValue.self, from: withoutComments(data))
    }

    /// Drops `//` and `/* */` comments outside strings, and a comma before `}` or `]`.
    static func withoutComments(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var inString = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                output.append(byte)
                if byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                    output.append(bytes[index + 1])
                    index += 2
                    continue
                }
                if byte == UInt8(ascii: "\"") { inString = false }
                index += 1
                continue
            }
            if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") {
                while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
                continue
            } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "*") {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) { index += 1 }
                index += 2
                continue
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                // A trailing comma before the close.
                if let last = output.lastIndex(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }), output[last] == UInt8(ascii: ",") {
                    output.remove(at: last)
                }
            }
            output.append(byte)
            index += 1
        }
        return Data(output)
    }

    /// The ChatGPT apps a Codex home has connected, by connector ID, with the names Codex cached
    /// beside their tools (`cache/codex_apps_tools/*.json`), the newest file last so its names win.
    /// Only IDs and names are kept, never a tool's schema; OpenAI's own built-in apps are left out.
    static func codexAppNames(home: URL) -> [String: String] {
        let folder = home.appending(path: "cache/codex_apps_tools", directoryHint: .isDirectory)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 < $1.1 }
        var names: [String: String] = [:]
        for (file, _) in files {
            if let tools = parsed(file, CodexAppToolsCache.names) {
                names.merge(tools) { _, new in new }
            }
        }
        return names
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (Date, any Sendable)] = [:]

        func value<T>(for path: String, modified: Date?) -> T? {
            lock.withLock {
                guard let modified, let entry = entries[path], entry.0 == modified else { return nil }
                return entry.1 as? T
            }
        }

        func store(_ value: any Sendable, for path: String, modified: Date?) {
            guard let modified else { return }
            lock.withLock { entries[path] = (modified, value) }
        }
    }
}

/// One place a harness keeps MCP servers: a Claude Code login's config folder, a Codex home, or
/// Antigravity's config.
struct NativeMCPHome: Equatable, Hashable, Sendable, Identifiable {
    enum Kind: Equatable, Hashable, Sendable {
        /// `file` is the login's `.claude.json`.
        case claude(file: URL)
        case codex(home: URL)
        case antigravity(file: URL)
        /// An app that is not a harness: its servers can be connected through Yardlet, nothing more.
        case app(NativeMCPApp, file: URL)
    }

    var kind: Kind
    /// The account it belongs to, as the account list names it; nil for the default login.
    var account: String?

    var id: String {
        switch kind {
        case .claude(let file): "claude|\(file.path(percentEncoded: false))"
        case .codex(let home): "codex|\(home.path(percentEncoded: false))"
        case .antigravity(let file): "antigravity|\(file.path(percentEncoded: false))"
        case .app(let app, let file): "\(app.rawValue)|\(file.path(percentEncoded: false))"
        }
    }

    /// The harness it belongs to; nil for an app that is not one.
    var harness: HarnessKind? {
        switch kind {
        case .claude: .claudeCode
        case .codex: .codex
        case .antigravity: .antigravityCLI
        case .app: nil
        }
    }

    /// Claude Code keeps `.claude.json` in `CLAUDE_CONFIG_DIR` when one is set, and in the home
    /// folder beside `~/.claude` otherwise.
    static func claudeConfigFile(configDirectory: URL, homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        func path(_ url: URL) -> String {
            var path = url.standardizedFileURL.path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        if path(configDirectory) == path(homeURL.appending(path: ".claude")) {
            return homeURL.appending(path: ".claude.json")
        }
        return configDirectory.appending(path: ".claude.json")
    }

    /// The default logins, every saved account, and Session Switch account folders not saved in
    /// Yardlet (each has its own `.claude.json`), then Antigravity's config files.
    static func all(
        connections: [ProviderConnection],
        locations: HarnessModelSettingsLocations = .live(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [NativeMCPHome] {
        var homes: [NativeMCPHome] = [
            NativeMCPHome(kind: .claude(file: claudeConfigFile(configDirectory: locations.claudeConfigDirectory, homeURL: homeURL)))
        ]
        for connection in connections where connection.harness == .claudeCode {
            guard let path = connection.homePath else { continue }
            homes.append(NativeMCPHome(kind: .claude(file: URL(filePath: path).appending(path: ".claude.json")),
                                       account: connection.name))
        }
        let sessionSwitch = homeURL.appending(path: "Library/Application Support/Session Switch/accounts", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: sessionSwitch, includingPropertiesForKeys: nil)) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = folder.appending(path: ".claude.json")
            guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { continue }
            homes.append(NativeMCPHome(kind: .claude(file: file), account: "Session Switch " + folder.lastPathComponent.prefix(8)))
        }
        homes.append(NativeMCPHome(kind: .codex(home: locations.codexHome)))
        for connection in connections where connection.harness == .codex {
            guard let path = connection.homePath else { continue }
            homes.append(NativeMCPHome(kind: .codex(home: URL(filePath: path)), account: connection.name))
        }
        let gemini = homeURL.appending(path: ".gemini", directoryHint: .isDirectory)
        homes.append(NativeMCPHome(kind: .antigravity(file: gemini.appending(path: "antigravity/mcp_config.json"))))
        homes.append(NativeMCPHome(kind: .antigravity(file: gemini.appending(path: "config/mcp_config.json"))))
        for app in NativeMCPApp.allCases {
            homes.append(NativeMCPHome(kind: .app(app, file: app.file(home: homeURL))))
        }
        // A saved account and a Session Switch folder can be the same folder.
        var seen = Set<String>()
        return homes.filter { home in
            let key: String = switch home.kind {
            case .claude(let file), .antigravity(let file), .app(_, let file): file.resolvingSymlinksInPath().path(percentEncoded: false)
            case .codex(let home): home.resolvingSymlinksInPath().path(percentEncoded: false)
            }
            return seen.insert(key).inserted
        }
    }
}

/// What one home holds, read now.
struct NativeMCPInventoryEntry: Equatable, Sendable, Identifiable {
    var home: NativeMCPHome
    var servers: [NativeMCPServer]
    /// claude.ai connectors (Claude) or plugins (Codex) the account carries, by name.
    var accountConnectors: [String]
    /// The ChatGPT apps a Codex home has connected, by name ("Gmail", "Google Calendar").
    var apps: [String] = []

    var id: String { home.id }
}

enum NativeMCPInventory {
    /// Every home's servers. Homes with nothing and files that are missing are left out.
    static func read(_ homes: [NativeMCPHome]) -> [NativeMCPInventoryEntry] {
        homes.compactMap { home in
            switch home.kind {
            case .claude(let file):
                guard let config = NativeMCPConfigFiles.claude(file) else { return nil }
                let local = config.projects.keys.sorted().flatMap { config.projects[$0]?.servers ?? [] }
                // Named by the account it is signed in to rather than by its folder, so one account
                // reached through two folders reads as one.
                var home = home
                home.account = config.account ?? home.account
                let entry = NativeMCPInventoryEntry(home: home, servers: config.userServers + local,
                                                    accountConnectors: config.claudeAIConnectors)
                return entry.servers.isEmpty && entry.accountConnectors.isEmpty ? nil : entry
            case .codex(let codexHome):
                let config = NativeMCPConfigFiles.codex(home: codexHome)
                let apps = codexApps(config?.apps ?? [], names: NativeMCPConfigFiles.codexAppNames(home: codexHome))
                guard config != nil || !apps.isEmpty else { return nil }
                let entry = NativeMCPInventoryEntry(home: home, servers: config?.servers ?? [],
                                                    accountConnectors: config?.plugins ?? [], apps: apps)
                return entry.servers.isEmpty && entry.accountConnectors.isEmpty && entry.apps.isEmpty ? nil : entry
            case .antigravity(let file):
                let servers = NativeMCPConfigFiles.antigravity(file)
                return servers.isEmpty ? nil : NativeMCPInventoryEntry(home: home, servers: servers, accountConnectors: [])
            case .app(let app, let file):
                let servers = NativeMCPConfigFiles.app(app, file: file)
                return servers.isEmpty ? nil : NativeMCPInventoryEntry(home: home, servers: servers, accountConnectors: [])
            }
        }
    }

    /// A Codex home's connected ChatGPT apps by name: the names Codex cached, less the apps its
    /// configuration turned off, then apps the configuration names only by ID, by their tools'
    /// names (`linear.save_comment` → "linear"). Sorted, each once.
    static func codexApps(_ settings: [CodexNativeMCPConfig.App], names: [String: String]) -> [String] {
        let off = Set(settings.filter { !$0.isEnabled }.map(\.id))
        var found = names.filter { !off.contains($0.key) }.map(\.value)
        for app in settings where app.isEnabled && names[app.id] == nil {
            if let service = app.serviceFromToolNames { found.append(service) }
        }
        var seen = Set<String>()
        return found.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// The remote servers a task's harness loads itself, by canonical address: for Claude Code the
    /// login's user servers, the task folder's local servers less those turned off, and the
    /// folder's `.mcp.json` servers the user approved; for Codex the home's enabled servers.
    /// Other harnesses report none here.
    static func loadedRemoteServers(
        harness: HarnessKind,
        configFolder: URL?,
        workspaceURL: URL,
        originWorkspaceURL: URL? = nil,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Set<String> {
        Set(loadedRemoteServerEntries(harness: harness, configFolder: configFolder, workspaceURL: workspaceURL,
                                      originWorkspaceURL: originWorkspaceURL, homeURL: homeURL).map(\.address))
    }

    /// The same servers with the harness's name for each and its address as written.
    static func loadedRemoteServerEntries(
        harness: HarnessKind,
        configFolder: URL?,
        workspaceURL: URL,
        originWorkspaceURL: URL? = nil,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [HarnessRemoteServer] {
        loadedServers(harness: harness, configFolder: configFolder, workspaceURL: workspaceURL,
                      originWorkspaceURL: originWorkspaceURL, homeURL: homeURL).compactMap(HarnessRemoteServer.init)
    }

    /// Every server a task's harness loads itself, remote or a program it starts.
    static func loadedServers(
        harness: HarnessKind,
        configFolder: URL?,
        workspaceURL: URL,
        originWorkspaceURL: URL? = nil,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [NativeMCPServer] {
        guard let configFolder else { return [] }
        switch harness {
        case .claudeCode:
            let file = NativeMCPHome.claudeConfigFile(configDirectory: configFolder, homeURL: homeURL)
            let config = NativeMCPConfigFiles.claude(file) ?? ClaudeNativeMCPConfig()
            let folders = [workspaceURL, originWorkspaceURL].compactMap { $0 }
                .map { $0.standardizedFileURL.path(percentEncoded: false) }
                .map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            var servers = config.userServers
            var disabled = Set<String>()
            for folder in folders {
                guard let project = config.projects[folder] else { continue }
                servers += project.servers
                disabled.formUnion(project.disabled)
            }
            servers += approvedProjectServers(folder: workspaceURL, config: config, folders: folders,
                                              configFolder: configFolder)
            return servers.filter { $0.isEnabled && !disabled.contains($0.name) }
        case .codex:
            let config = NativeMCPConfigFiles.codex(home: configFolder) ?? CodexNativeMCPConfig()
            return config.servers.filter(\.isEnabled)
        default:
            return []
        }
    }

    /// `.mcp.json` servers load once approved: in the project entry, the folder's settings, or the
    /// login's settings (`enabledMcpjsonServers`, `enableAllProjectMcpServers`), unless turned off.
    private static func approvedProjectServers(folder: URL, config: ClaudeNativeMCPConfig, folders: [String],
                                               configFolder: URL) -> [NativeMCPServer] {
        guard let data = NativeMCPConfigFiles.data(folder.appending(path: ".mcp.json")) else { return [] }
        let servers = ClaudeNativeMCPConfig.projectServers(data, project: folder.path(percentEncoded: false))
        guard !servers.isEmpty else { return [] }
        var enabled = Set<String>()
        var disabled = Set<String>()
        var all = false
        for path in folders {
            guard let project = config.projects[path] else { continue }
            enabled.formUnion(project.enabledProjectServers)
            disabled.formUnion(project.disabledProjectServers)
            all = all || project.enablesAllProjectServers
        }
        for file in [folder.appending(path: ".claude/settings.local.json"), folder.appending(path: ".claude/settings.json"),
                     configFolder.appending(path: "settings.json")] {
            guard let data = NativeMCPConfigFiles.data(file),
                  let settings = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
            enabled.formUnion((settings["enabledMcpjsonServers"]?.arrayValue ?? []).compactMap(\.stringValue))
            disabled.formUnion((settings["disabledMcpjsonServers"]?.arrayValue ?? []).compactMap(\.stringValue))
            all = all || settings["enableAllProjectMcpServers"]?.boolValue == true
        }
        return servers.filter { !disabled.contains($0.name) && (all || enabled.contains($0.name)) }
    }
}

/// How one program server in another app's or harness's settings starts, read again when the
/// person asks to run it through Yardlet, and only then: its program, arguments and environment.
/// Values that refer to something else (`${input:key}`, `${env:NAME}`, `${NAME}`) are not followed;
/// they are left for the person to fill in. The file is not changed.
struct NativeMCPLaunch: Equatable, Sendable {
    var command: String
    var arguments: [String]
    var environment: [String: String]
    /// Environment variables whose value the settings left to something Yardlet does not follow.
    var unresolved: [String] = []

    static func from(_ entry: JSONValue) -> NativeMCPLaunch? {
        guard let command = entry["command"]?.stringValue, !command.isEmpty, entry["url"] == nil, entry["serverUrl"] == nil else {
            return nil
        }
        let arguments = (entry["args"]?.arrayValue ?? []).compactMap(\.stringValue)
        var environment: [String: String] = [:]
        var unresolved: [String] = []
        for (name, value) in entry["env"]?.objectValue ?? [:] where MCPRegistryCheck.isEnvironmentName(name) {
            guard let text = value.stringValue else { continue }
            if text.contains("${") { unresolved.append(name) } else { environment[name] = text }
        }
        return NativeMCPLaunch(command: command, arguments: arguments, environment: environment, unresolved: unresolved.sorted())
    }

    /// The program server named `name` in a home, as its file says now.
    static func read(_ server: NativeMCPServer, in home: NativeMCPHome) -> NativeMCPLaunch? {
        switch home.kind {
        case .claude(let file):
            guard let root = NativeMCPConfigFiles.data(file).flatMap(NativeMCPConfigFiles.json) else { return nil }
            switch server.scope {
            case .claudeLocal(let project): return root["projects"]?[project]?["mcpServers"]?[server.name].flatMap(from)
            default: return root["mcpServers"]?[server.name].flatMap(from)
            }
        case .codex(let codexHome):
            guard let data = NativeMCPConfigFiles.data(codexHome.appending(path: "config.toml")) else { return nil }
            return CodexNativeMCPConfig.launch(String(decoding: data, as: UTF8.self), server: server.name)
        case .antigravity(let file):
            return NativeMCPConfigFiles.data(file).flatMap(NativeMCPConfigFiles.json)?["mcpServers"]?[server.name].flatMap(from)
        case .app(let app, let file):
            return NativeMCPConfigFiles.data(file).flatMap(NativeMCPConfigFiles.json)?[app.serversKey]?[server.name].flatMap(from)
        }
    }
}

extension CodexNativeMCPConfig {
    /// One server's `command`, `args` and `env` from `config.toml`: `[mcp_servers.<name>]` with
    /// `env = { … }` inline or an `[mcp_servers.<name>.env]` table. Strings, arrays of strings
    /// (on one line or several) and inline tables of strings are read; anything else is skipped.
    static func launch(_ text: String, server: String) -> NativeMCPLaunch? {
        var command: String?
        var arguments: [String] = []
        var environment: [String: String] = [:]
        var section: String?
        var pending: (key: String, text: String)?
        func assign(_ key: String, _ value: String) {
            switch (section, key) {
            case ("server", "command"): command = TOMLValue.string(value)
            case ("server", "args"): arguments = TOMLValue.strings(value) ?? arguments
            case ("server", "env"): environment.merge(TOMLValue.table(value) ?? [:]) { $1 }
            case ("env", _): if let text = TOMLValue.string(value) { environment[key] = text }
            default: break
            }
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if var open = pending {
                open.text += " " + line
                if TOMLValue.isComplete(open.text) { assign(open.key, open.text); pending = nil } else { pending = open }
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                let path = header.split(separator: ".", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
                section = if path == ["mcp_servers", server] { "server" }
                    else if path == ["mcp_servers", server, "env"] { "env" }
                    else { nil }
                continue
            }
            guard section != nil, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if TOMLValue.isComplete(value) { assign(key, value) } else { pending = (key, value) }
        }
        guard let command, !command.isEmpty else { return nil }
        let unresolved = environment.filter { $0.value.contains("${") }.map(\.key).sorted()
        for name in unresolved { environment[name] = nil }
        return NativeMCPLaunch(command: command, arguments: arguments,
                               environment: environment.filter { MCPRegistryCheck.isEnvironmentName($0.key) }, unresolved: unresolved)
    }
}

/// The few TOML values MCP settings use: basic and literal strings, arrays of them, and inline
/// tables of them.
private enum TOMLValue {
    /// Brackets and braces balance outside strings.
    static func isComplete(_ text: String) -> Bool {
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in text {
            if let open = quote {
                if escaped { escaped = false } else if character == "\\", open == "\"" { escaped = true } else if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            case "#": return depth <= 0
            default: break
            }
        }
        return depth <= 0
    }

    /// The strings in order, each with where it ended.
    static func strings(in text: String) -> [(value: String, end: String.Index)] {
        var found: [(String, String.Index)] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "#" { break }
            guard character == "\"" || character == "'" else { index = text.index(after: index); continue }
            var value = ""
            var cursor = text.index(after: index)
            while cursor < text.endIndex, text[cursor] != character {
                if character == "\"", text[cursor] == "\\", text.index(after: cursor) < text.endIndex {
                    let next = text[text.index(after: cursor)]
                    value.append(["n": "\n", "t": "\t", "\"": "\"", "\\": "\\"][next] ?? next)
                    cursor = text.index(cursor, offsetBy: 2)
                    continue
                }
                value.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex else { break }
            found.append((value, cursor))
            index = text.index(after: cursor)
        }
        return found
    }

    static func string(_ text: String) -> String? {
        guard let first = text.first, first == "\"" || first == "'" else { return nil }
        return strings(in: text).first?.value
    }

    static func strings(_ text: String) -> [String]? {
        guard text.hasPrefix("[") else { return nil }
        return strings(in: text).map { $0.value }
    }

    /// `{ KEY = "value", "OTHER" = "x" }`: keys and values alternate as strings once bare keys
    /// are quoted.
    static func table(_ text: String) -> [String: String]? {
        guard text.hasPrefix("{") else { return nil }
        let quotedKeys = text.replacingOccurrences(of: #"([{,]\s*)([A-Za-z_][A-Za-z0-9_-]*)\s*="#, with: "$1\"$2\" =",
                                                   options: .regularExpression)
        let values = strings(in: quotedKeys).map { $0.value }
        var table: [String: String] = [:]
        var index = 0
        while index + 1 < values.count {
            table[values[index]] = values[index + 1]
            index += 2
        }
        return table
    }
}
