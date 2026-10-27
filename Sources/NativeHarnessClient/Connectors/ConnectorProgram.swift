import Foundation

/// A program Yardlet runs on this Mac as a connector's MCP server (stdio): a package from an MCP
/// registry (`npx`, `uvx`, `docker run`) or a server another app's settings start (Claude app,
/// Cursor, VS Code, Claude Code, Codex). It is someone else's code running with the person's
/// access, so a connector of this kind exists only after the person has seen exactly what runs and
/// said yes (docs/CONNECTORS.md, "Programs on this Mac"). The record keeps what to show; the
/// arguments and environment values, which may hold keys, are in the keychain with the connector.
struct ConnectorProgram: Codable, Equatable, Sendable {
    enum Runtime: String, Codable, Sendable {
        case npx
        case uvx
        case docker
        /// A program another app's settings name, as they name it.
        case command
    }

    var runtime: Runtime
    /// What runs, by the name or path the person saw (`npx`, `/usr/local/bin/server`).
    var program: String
    /// The npm or PyPI package, or the image; nil for a plain program.
    var package: String?
    var version: String?
    /// Where it came from: the registry's server name, or the app whose settings had it.
    var origin: String
    /// The environment variables the person gave values for, by name.
    var environmentNames: [String] = []

    /// The program and package, for noticing a harness that starts the same server itself; nil
    /// without a package, where nothing tells two programs apart.
    var key: String? {
        package.map { ConnectorPrograms.key(program: program, package: $0) }
    }

    /// "npx · @upstash/context7-mcp 4.4.4" for a settings row.
    var summary: String {
        [program, [package, version].compactMap { $0 }.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What to install for the runtime, when it is missing.
    var missingRuntimeAdvice: String {
        switch runtime {
        case .npx: L10n.string("npx isn't on this Mac. Install Node.js (nodejs.org), then try again.")
        case .uvx: L10n.string("uvx isn't on this Mac. Install uv (docs.astral.sh/uv), then try again.")
        case .docker: L10n.string("docker isn't on this Mac. Install Docker Desktop and start it, then try again.")
        case .command: L10n.format("%@ isn't on this Mac anymore.", program)
        }
    }
}

/// Everything a connector's program needs to start, as the person confirmed it. Kept in the
/// keychain (`ConnectorCredential.program`).
struct ConnectorProgramSpec: Codable, Equatable, Sendable {
    var arguments: [String]
    var environment: [String: String]
}

/// How a program starts: the executable found on this Mac, its arguments, a small environment,
/// and the connector's own folder to work in.
struct ConnectorProgramLaunch: Equatable, Sendable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var directory: URL
}

enum ConnectorPrograms {
    /// A registry package as a program and what it starts with, with the person's values for its
    /// inputs (`values[name]`). An argument whose input was left empty is left out; Docker's
    /// `-e NAME=value` passes the value through the environment, so it is not in the arguments
    /// other processes can see.
    static func plan(_ package: MCPRegistryEntry.Package, entry: MCPRegistryEntry,
                     values: [String: String]) -> (program: ConnectorProgram, spec: ConnectorProgramSpec) {
        var environment: [String: String] = [:]
        for input in package.environment {
            if let value = values[input.name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                environment[input.name] = value
            }
        }
        func filled(_ argument: MCPRegistryEntry.Package.Argument) -> [String]? {
            guard let value = argument.value else { return argument.flag.map { [$0] } }
            var text = value
            for input in package.argumentInputs where text.contains("{\(input.name)}") {
                let given = values[input.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !given.isEmpty else { return nil }
                text = text.replacingOccurrences(of: "{\(input.name)}", with: given)
            }
            if let flag = argument.flag, ["-e", "--env"].contains(flag), package.kind == .oci,
               let equals = text.firstIndex(of: "="), MCPRegistryCheck.isEnvironmentName(String(text[..<equals])) {
                let name = String(text[..<equals])
                environment[name] = String(text[text.index(after: equals)...])
                return [flag, name]
            }
            return (argument.flag.map { [$0] } ?? []) + [text]
        }
        let runtime = package.runtimeArguments.compactMap(filled).flatMap { $0 }
        let arguments = package.packageArguments.compactMap(filled).flatMap { $0 }
        let pinned = package.version.flatMap { $0 == "latest" ? nil : $0 }
        let all: [String]
        let program: ConnectorProgram.Runtime
        switch package.kind {
        case .npm:
            program = .npx
            all = ["-y"] + runtime + [package.identifier + (pinned.map { "@\($0)" } ?? "")] + arguments
        case .pypi:
            program = .uvx
            all = runtime + [package.identifier + (pinned.map { "==\($0)" } ?? "")] + arguments
        case .oci:
            program = .docker
            let tagged = package.identifier.contains("@sha256:") || package.identifier.split(separator: "/").last?.contains(":") == true
            let image = tagged ? package.identifier : package.identifier + (pinned.map { ":\($0)" } ?? "")
            // Variables the registry lists as the server's own reach the container by name.
            let forwarded = package.environment.map(\.name).filter { environment[$0] != nil && !runtime.contains($0) }
                .flatMap { ["-e", $0] }
            all = ["run", "-i", "--rm"] + runtime.filter { !["-i", "--interactive", "--rm"].contains($0) } + forwarded
                + [image] + arguments
        }
        let shownVersion = package.kind == .oci && pinned == nil ? nil : (pinned ?? "latest")
        return (ConnectorProgram(runtime: program, program: program.rawValue, package: package.identifier, version: shownVersion,
                                 origin: entry.name, environmentNames: environment.keys.sorted()),
                ConnectorProgramSpec(arguments: all, environment: environment))
    }

    /// The program's file name and the package without its version (`npx|@upstash/context7-mcp`),
    /// the same for a harness's `npx -y @upstash/context7-mcp@latest` and a registry's package.
    static func key(program: String, package: String) -> String {
        var name = package.lowercased()
        if let equals = name.range(of: "==") { name = String(name[..<equals.lowerBound]) }
        if let at = name.dropFirst().lastIndex(of: "@") { name = String(name[..<at]) }
        return URL(filePath: program).lastPathComponent.lowercased() + "|" + name
    }

    /// The command line as the person reads it, values of secret inputs shown as dots.
    static func commandLine(_ program: String, _ arguments: [String], hiding secrets: [String] = []) -> String {
        let hidden = secrets.filter { $0.count >= 4 }
        return ([program] + arguments).map { argument in
            var shown = argument
            for secret in hidden { shown = shown.replacingOccurrences(of: secret, with: "•••") }
            return quoted(shown)
        }.joined(separator: " ")
    }

    private static func quoted(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let plain = argument.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "@%+=:,./_-•".unicodeScalars.contains($0) }
        return plain ? argument : "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The program's executable on this Mac: a path as given, or a name found in the search
    /// directories (`RuntimeProcessEnvironment.searchDirectories`); nil when there is none.
    static func locate(_ program: String, home: URL, fileManager: FileManager = .default) -> URL? {
        if program.hasPrefix("/") {
            return fileManager.isExecutableFile(atPath: program) ? URL(filePath: program) : nil
        }
        if program.hasPrefix("~/") {
            let path = home.appending(path: String(program.dropFirst(2))).path(percentEncoded: false)
            return fileManager.isExecutableFile(atPath: path) ? URL(filePath: path) : nil
        }
        guard !program.contains("/"), !program.isEmpty else { return nil }
        return RuntimeProcessEnvironment.searchDirectories(home: home, fileManager: fileManager).lazy
            .map { $0.appending(path: program) }
            .first { fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    /// The environment a program starts with: the person's home, user, language and temporary
    /// folder, a `PATH` that reaches its runtime, npm's and uv's caches in the connector's own
    /// folder (so removing the connector removes what they downloaded), then the person's values.
    /// Nothing else of Yardlet's environment is passed on.
    static func environment(executable: URL, folder: URL, values: [String: String],
                            base: [String: String] = ProcessInfo.processInfo.environment, home: URL) -> [String: String] {
        var environment: [String: String] = ["HOME": home.path(percentEncoded: false)]
        for name in ["USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "SHELL", "TERM"] {
            if let value = base[name], !value.isEmpty { environment[name] = value }
        }
        let path = RuntimeProcessEnvironment.values(executableURL: executable, base: ["HOME": home.path(percentEncoded: false)])["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = path
        let cache = folder.path(percentEncoded: false)
        environment["npm_config_cache"] = cache + "/npm"
        environment["npm_config_update_notifier"] = "false"
        environment["UV_CACHE_DIR"] = cache + "/uv"
        environment["UV_PYTHON_INSTALL_DIR"] = cache + "/uv-python"
        environment["UV_TOOL_DIR"] = cache + "/uv-tools"
        return environment.merging(values) { _, given in given }
    }
}

/// A program the person is about to run through Yardlet, before they confirm it: from a registry
/// entry's package, or from another app's or harness's settings. It says what will run and asks
/// for the values it needs (`ConnectorProgramPage`).
struct ConnectorProgramDraft: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case registry(MCPRegistryEntry, MCPRegistryEntry.Package)
        /// Found in `place` (an app or harness), started as `launch` says now.
        case imported(place: String, launch: NativeMCPLaunch)
    }

    var name: String
    var source: Source
    /// What the person fills in or checks: the registry's inputs, or the settings' environment.
    var inputs: [MCPRegistryEntry.Input]
    /// What the fields start with: defaults, or the values the settings hold.
    var initialValues: [String: String]

    var id: String {
        switch source {
        case .registry(let entry, _): "registry|\(entry.name)"
        case .imported(let place, let launch): "imported|\(place)|\(name)|\(launch.command)"
        }
    }

    static func registry(_ entry: MCPRegistryEntry, package: MCPRegistryEntry.Package) -> ConnectorProgramDraft {
        let inputs = package.argumentInputs + package.environment.filter { input in
            !package.argumentInputs.contains { $0.name == input.name }
        }
        var values: [String: String] = [:]
        for input in inputs { if let value = input.defaultValue { values[input.name] = value } }
        return ConnectorProgramDraft(name: entry.title, source: .registry(entry, package), inputs: inputs, initialValues: values)
    }

    static func imported(name: String, place: String, launch: NativeMCPLaunch) -> ConnectorProgramDraft {
        // A value in someone's settings may be a key, so each is a secure field filled with it.
        let names = (Array(launch.environment.keys) + launch.unresolved).sorted()
        let inputs = names.map { MCPRegistryEntry.Input(name: $0, summary: "", isRequired: false, isSecret: true, defaultValue: nil) }
        return ConnectorProgramDraft(name: name, source: .imported(place: place, launch: launch), inputs: inputs,
                                     initialValues: launch.environment)
    }

    var runtime: ConnectorProgram.Runtime {
        switch source {
        case .registry(_, let package):
            switch package.kind {
            case .npm: .npx
            case .pypi: .uvx
            case .oci: .docker
            }
        case .imported(_, let launch):
            ConnectorProgram.Runtime(rawValue: URL(filePath: launch.command).lastPathComponent) ?? .command
        }
    }

    /// Where it came from, in a line: the registry's server name, or the app it was found in.
    var origin: String {
        switch source {
        case .registry(let entry, _): entry.name
        case .imported(let place, _): place
        }
    }

    var repository: URL? {
        if case .registry(let entry, _) = source { return entry.repository ?? entry.website }
        return nil
    }

    /// The required fields are filled in.
    func isReady(_ values: [String: String]) -> Bool {
        inputs.filter(\.isRequired).allSatisfy { !(values[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The program and what it starts with, given the person's values.
    func plan(_ values: [String: String]) -> (program: ConnectorProgram, spec: ConnectorProgramSpec) {
        switch source {
        case .registry(let entry, let package):
            return ConnectorPrograms.plan(package, entry: entry, values: values)
        case .imported(let place, let launch):
            var environment: [String: String] = [:]
            for input in inputs {
                if let value = values[input.name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    environment[input.name] = value
                }
            }
            let package = NativeMCPConfigFiles.packageName(in: launch.arguments)
            let program = ConnectorProgram(runtime: runtime, program: launch.command, package: package, version: nil,
                                           origin: place, environmentNames: environment.keys.sorted())
            return (program, ConnectorProgramSpec(arguments: launch.arguments, environment: environment))
        }
    }

    /// The command line as it will run, secret values hidden.
    func commandLine(_ values: [String: String]) -> String {
        let (program, spec) = plan(values)
        let secrets = inputs.filter(\.isSecret).compactMap { values[$0.name] }.filter { !$0.isEmpty }
        return ConnectorPrograms.commandLine(program.program, spec.arguments, hiding: secrets)
    }
}
