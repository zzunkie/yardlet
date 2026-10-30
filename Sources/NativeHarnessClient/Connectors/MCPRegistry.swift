import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A server a public MCP registry lists: the GitHub MCP Registry (the list VS Code shows) or the
/// official MCP Registry (registry.modelcontextprotocol.io), which share the `server.json` format
/// (docs/CONNECTORS.md, "Registries"). What a registry says is someone else's data: an entry keeps
/// only fields that passed the checks below, its words are plain text for the person to read and
/// never reach a model as instructions, and addresses and package names that are not well formed
/// leave the entry out or mark it as one Yardlet cannot run.
struct MCPRegistryEntry: Codable, Equatable, Sendable, Identifiable {
    enum Source: String, Codable, Sendable {
        case github
        case official
    }

    /// A value the person gives when connecting: an HTTP header's (an API key), an environment
    /// variable's, or a part of a program's arguments.
    struct Input: Codable, Equatable, Sendable, Identifiable {
        /// The header's or variable's name (`x-api-key`, `CONTEXT7_API_KEY`).
        var name: String
        var summary: String
        var isRequired: Bool
        var isSecret: Bool
        var defaultValue: String?

        var id: String { name }
    }

    /// A server that runs at the service: Streamable HTTP at a fixed address.
    struct Remote: Codable, Equatable, Sendable {
        var url: URL
        /// A header the server asks for, with the value's form (`Bearer {value}`); nil when it
        /// needs none.
        var keyHeader: KeyHeader?
    }

    struct KeyHeader: Codable, Equatable, Sendable {
        var name: String
        /// "Bearer " when the key goes after it in `Authorization`; empty for the key as is.
        var prefix: String
        var input: Input

        /// Sent the way Yardlet sends a pasted token: `Authorization: Bearer`.
        var isBearer: Bool { name.caseInsensitiveCompare("Authorization") == .orderedSame && prefix == "Bearer " }
    }

    /// A program the registry says runs the server on the person's computer (stdio).
    struct Package: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case npm
            case pypi
            case oci
        }

        var kind: Kind
        var identifier: String
        /// Nil or "latest" when the registry names no fixed version.
        var version: String?
        /// One argument: a flag with its value, a flag alone, or a value alone. `{name}` in the
        /// value is where an input's value goes; an argument whose input is left empty is left out.
        struct Argument: Codable, Equatable, Sendable {
            var flag: String?
            var value: String?
        }

        /// The runtime's own options (`npx`, `uvx`, `docker run`), then the package's arguments.
        var runtimeArguments: [Argument]
        var packageArguments: [Argument]
        /// Inputs for the arguments' `{name}` parts.
        var argumentInputs: [Input]
        var environment: [Input]
    }

    /// Why an entry cannot be connected as it is, said in a line.
    enum Limitation: String, Codable, Sendable, Error {
        /// Only the old HTTP+SSE transport.
        case oldTransport
        /// The address holds a part each person fills in (a tenant, a generated URL).
        case addressPerAccount
        /// More than one header, or a header that is not a key.
        case headers
        /// A package kind Yardlet does not run (MCP bundles, NuGet, Cargo) or from another registry.
        case packageKind
        /// Docker options beyond environment variables and a loopback port.
        case dockerOptions
        /// No remote and no package.
        case nothingToRun
    }

    var name: String
    var title: String
    var summary: String
    var version: String
    var website: URL?
    var repository: URL?
    var icons: [MCPServerIcon]
    var remote: Remote?
    var package: Package?
    var limitation: Limitation?
    var sources: [Source]
    /// The repository's stars, as the GitHub registry gives them.
    var stars: Int?

    var id: String { name }
}

// MARK: Reading a registry's answer

/// The two registries' list answers (`GET /v0.1/servers`), read leniently: an entry that does not
/// decode or does not pass the checks is skipped, the rest are kept.
enum MCPRegistryFormat {
    /// The most an answer may be; a GitHub registry page of 100 carries every README and stays
    /// near 3 MB.
    static let maximumAnswerSize = 8 * 1_048_576
    static let maximumEntriesPerAnswer = 200

    struct Page: Equatable, Sendable {
        var entries: [MCPRegistryEntry]
        var nextCursor: String?
    }

    static func page(_ data: Data, source: MCPRegistryEntry.Source) -> Page? {
        guard data.count <= maximumAnswerSize,
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }
        let entries = answer.servers.prefix(maximumEntriesPerAnswer).compactMap { item -> MCPRegistryEntry? in
            guard let item = item.value, item.isActive, let server = item.server else { return nil }
            return entry(server, source: source)
        }
        let cursor = answer.metadata?.nextCursor.flatMap { $0.isEmpty || $0.count > 1_024 ? nil : $0 }
        return Page(entries: entries, nextCursor: cursor)
    }

    // The wire form. Every field is optional so one odd entry does not spoil the page.

    private struct Answer: Decodable {
        var servers: [Lenient<Item>]
        var metadata: Metadata?
    }

    private struct Metadata: Decodable {
        var nextCursor: String?
    }

    private struct Item: Decodable {
        var server: Server?
        var meta: Meta?

        enum CodingKeys: String, CodingKey {
            case server
            case meta = "_meta"
        }

        /// Deleted and deprecated entries are left out; the official registry marks spam and
        /// malware "deleted".
        var isActive: Bool {
            guard let status = meta?.official?.status else { return true }
            return status == "active"
        }
    }

    private struct Meta: Decodable {
        var official: Official?

        enum CodingKeys: String, CodingKey {
            case official = "io.modelcontextprotocol.registry/official"
        }

        struct Official: Decodable {
            var status: String?
        }
    }

    fileprivate struct Server: Decodable {
        var name: String?
        var title: String?
        var description: String?
        var version: String?
        var websiteUrl: String?
        var repository: Repository?
        var icons: [Icon]?
        var remotes: [Lenient<RemoteForm>]?
        var packages: [Lenient<PackageForm>]?
        var meta: ServerMeta?

        enum CodingKeys: String, CodingKey {
            case name, title, description, version, websiteUrl, repository, icons, remotes, packages
            case meta = "_meta"
        }
    }

    fileprivate struct Repository: Decodable {
        var url: String?
    }

    fileprivate struct Icon: Decodable {
        var src: String?
        var mimeType: String?
        var sizes: [String]?
        var theme: String?
    }

    fileprivate struct ServerMeta: Decodable {
        var publisher: Publisher?

        enum CodingKeys: String, CodingKey {
            case publisher = "io.modelcontextprotocol.registry/publisher-provided"
        }

        struct Publisher: Decodable {
            var github: GitHub?
        }

        struct GitHub: Decodable {
            var stargazerCount: Int?
        }
    }

    fileprivate struct InputForm: Decodable {
        var name: String?
        var description: String?
        var isRequired: Bool?
        var isSecret: Bool?
        var value: String?
        var `default`: String?
        var variables: [String: InputForm]?
    }

    fileprivate struct RemoteForm: Decodable {
        var type: String?
        var url: String?
        var headers: [InputForm]?
    }

    fileprivate struct ArgumentForm: Decodable {
        var type: String?
        var name: String?
        var value: String?
        var `default`: String?
        var isRequired: Bool?
        var description: String?
        var isSecret: Bool?
        var variables: [String: InputForm]?
    }

    fileprivate struct PackageForm: Decodable {
        var registryType: String?
        var registryBaseUrl: String?
        var identifier: String?
        var version: String?
        var transport: Transport?
        var runtimeArguments: [ArgumentForm]?
        var packageArguments: [ArgumentForm]?
        var environmentVariables: [InputForm]?

        struct Transport: Decodable {
            var type: String?
        }
    }

    // MARK: Checks

    private static func entry(_ server: Server, source: MCPRegistryEntry.Source) -> MCPRegistryEntry? {
        guard let name = server.name, MCPRegistryCheck.isServerName(name) else { return nil }
        let fallbackTitle = String(name.split(separator: "/").last ?? Substring(name))
        let remotes = (server.remotes ?? []).compactMap(\.value)
        let packages = (server.packages ?? []).compactMap(\.value)
        var limitation: MCPRegistryEntry.Limitation?
        var remote: MCPRegistryEntry.Remote?
        // The first Streamable HTTP remote Yardlet can use; else why none can be used.
        for form in remotes {
            switch self.remote(form) {
            case .success(let usable):
                remote = usable
            case .failure(let reason):
                limitation = limitation ?? reason
                continue
            }
            break
        }
        var package: MCPRegistryEntry.Package?
        var packageLimitation: MCPRegistryEntry.Limitation?
        for form in packages {
            switch self.package(form) {
            case .success(let usable):
                package = usable
            case .failure(let reason):
                packageLimitation = packageLimitation ?? reason
                continue
            }
            break
        }
        if remote != nil || package != nil {
            limitation = nil
        } else {
            limitation = limitation ?? packageLimitation ?? .nothingToRun
        }
        return MCPRegistryEntry(
            name: name,
            title: MCPRegistryCheck.text(server.title, limit: 80) ?? fallbackTitle,
            summary: MCPRegistryCheck.text(server.description, limit: 240) ?? "",
            version: MCPRegistryCheck.version(server.version) ?? "",
            website: server.websiteUrl.flatMap(MCPRegistryCheck.webAddress),
            repository: server.repository?.url.flatMap(MCPRegistryCheck.webAddress),
            icons: (server.icons ?? []).prefix(6).compactMap { icon in
                guard let src = icon.src, let url = MCPRegistryCheck.webAddress(src) else { return nil }
                return MCPServerIcon(src: url.absoluteString, mimeType: MCPRegistryCheck.text(icon.mimeType, limit: 40),
                                     sizes: icon.sizes.map { Array($0.prefix(4)).compactMap { MCPRegistryCheck.text($0, limit: 12) } },
                                     theme: icon.theme == "light" || icon.theme == "dark" ? icon.theme : nil)
            },
            remote: remote,
            package: package,
            limitation: limitation,
            sources: [source],
            stars: server.meta?.publisher?.github?.stargazerCount.map { max(0, $0) }
        )
    }

    private static func remote(_ form: RemoteForm) -> Result<MCPRegistryEntry.Remote, MCPRegistryEntry.Limitation> {
        guard form.type == "streamable-http" else { return .failure(.oldTransport) }
        guard let text = form.url else { return .failure(.nothingToRun) }
        if text.contains("{") { return .failure(.addressPerAccount) }
        guard let url = MCPRegistryCheck.webAddress(text) else { return .failure(.nothingToRun) }
        let required = (form.headers ?? []).filter { $0.isRequired == true }
        guard required.count <= 1 else { return .failure(.headers) }
        guard let header = required.first else { return .success(.init(url: url, keyHeader: nil)) }
        // One key: the header's whole value is the key, after "Bearer " for Authorization.
        guard let headerName = header.name, MCPRegistryCheck.isHeaderName(headerName) else { return .failure(.headers) }
        let value = header.value ?? ""
        let prefix: String
        if value.isEmpty || value.range(of: #"^\{[A-Za-z0-9_.-]+\}$"#, options: .regularExpression) != nil {
            prefix = headerName.caseInsensitiveCompare("Authorization") == .orderedSame ? "Bearer " : ""
        } else if value.range(of: #"^Bearer \{[A-Za-z0-9_.-]+\}$"#, options: .regularExpression) != nil {
            prefix = "Bearer "
        } else {
            return .failure(.headers)
        }
        let input = MCPRegistryEntry.Input(name: headerName, summary: MCPRegistryCheck.text(header.description, limit: 240) ?? "",
                                           isRequired: true, isSecret: true, defaultValue: nil)
        return .success(.init(url: url, keyHeader: .init(name: headerName, prefix: prefix, input: input)))
    }

    private static let defaultRegistries: [MCPRegistryEntry.Package.Kind: String] = [
        .npm: "https://registry.npmjs.org", .pypi: "https://pypi.org"
    ]

    private static func package(_ form: PackageForm) -> Result<MCPRegistryEntry.Package, MCPRegistryEntry.Limitation> {
        guard form.transport?.type == nil || form.transport?.type == "stdio",
              let kind = form.registryType.flatMap(MCPRegistryEntry.Package.Kind.init(rawValue:)),
              let identifier = form.identifier, MCPRegistryCheck.isPackage(identifier, kind: kind)
        else { return .failure(.packageKind) }
        // Packages from another npm or PyPI registry are left out: the person confirms a name that
        // only means one thing on the public registry.
        if let base = form.registryBaseUrl?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
           kind != .oci, base != defaultRegistries[kind] {
            return .failure(.packageKind)
        }
        var inputs: [MCPRegistryEntry.Input] = []
        func arguments(_ forms: [ArgumentForm]?, runtime: Bool) -> [MCPRegistryEntry.Package.Argument]? {
            var result: [MCPRegistryEntry.Package.Argument] = []
            for argument in (forms ?? []).prefix(24) {
                var value = argument.value ?? argument.default
                if value == nil, argument.isRequired == true {
                    // A required value the registry leaves to the person.
                    guard let name = argument.name.flatMap(MCPRegistryCheck.inputName) ?? "argument\(inputs.count + 1)".nilIfEmpty
                    else { return nil }
                    inputs.append(.init(name: name, summary: MCPRegistryCheck.text(argument.description, limit: 240) ?? "",
                                        isRequired: true, isSecret: argument.isSecret == true, defaultValue: nil))
                    value = "{\(name)}"
                }
                for (name, variable) in (argument.variables ?? [:]).sorted(by: { $0.key < $1.key }) {
                    guard MCPRegistryCheck.inputName(name) != nil else { return nil }
                    if !inputs.contains(where: { $0.name == name }) {
                        inputs.append(.init(name: name, summary: MCPRegistryCheck.text(variable.description ?? argument.description,
                                                                                        limit: 240) ?? "",
                                            isRequired: variable.isRequired == true,
                                            isSecret: variable.isSecret == true,
                                            defaultValue: variable.isSecret == true ? nil : MCPRegistryCheck.text(variable.default, limit: 200)))
                    }
                }
                switch argument.type {
                case "named":
                    guard let flag = argument.name, MCPRegistryCheck.isFlag(flag) else { return nil }
                    if runtime, kind == .oci, !MCPRegistryCheck.dockerFlags.contains(flag) { return nil }
                    if let value {
                        guard MCPRegistryCheck.isArgument(value) else { return nil }
                        if runtime, kind == .oci, ["-p", "--publish"].contains(flag), !value.hasPrefix("127.0.0.1:") { return nil }
                    }
                    result.append(.init(flag: flag, value: value))
                case "positional", nil:
                    guard let value else { continue }
                    guard MCPRegistryCheck.isArgument(value) else { return nil }
                    if runtime {
                        // `npx -y` is Yardlet's own; any other bare runtime argument changes what
                        // runs in ways the registry's format does not say, so the entry is left out.
                        if kind == .npm, ["-y", "--yes"].contains(value) { continue }
                        return nil
                    }
                    result.append(.init(flag: nil, value: value))
                default:
                    return nil
                }
            }
            return result
        }
        guard let runtimeArguments = arguments(form.runtimeArguments, runtime: true) else {
            return .failure(kind == .oci ? .dockerOptions : .packageKind)
        }
        guard let packageArguments = arguments(form.packageArguments, runtime: false) else { return .failure(.packageKind) }
        let environment = (form.environmentVariables ?? []).prefix(24).compactMap { variable -> MCPRegistryEntry.Input? in
            guard let name = variable.name, MCPRegistryCheck.isEnvironmentName(name) else { return nil }
            return .init(name: name, summary: MCPRegistryCheck.text(variable.description, limit: 240) ?? "",
                         isRequired: variable.isRequired == true, isSecret: variable.isSecret == true,
                         defaultValue: variable.isSecret == true ? nil : MCPRegistryCheck.text(variable.value ?? variable.default, limit: 200))
        }
        return .success(.init(kind: kind, identifier: identifier, version: MCPRegistryCheck.version(form.version),
                              runtimeArguments: runtimeArguments, packageArguments: packageArguments,
                              argumentInputs: inputs, environment: environment))
    }
}

/// Decodes a value, or leaves nil where it does not decode.
private struct Lenient<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// What a registry's fields must look like before Yardlet keeps them.
enum MCPRegistryCheck {
    /// Reverse-DNS namespace, a slash, a name (the registry's own pattern), 200 characters at most.
    static func isServerName(_ name: String) -> Bool {
        name.count <= 200 && name.range(of: #"^[A-Za-z0-9.-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    /// One line of plain text: control and formatting characters (bidirectional overrides, zero
    /// width) and Markdown links' targets are dropped, spaces collapse, and it is cut at `limit`.
    static func text(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        var kept = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                kept.append(" ")
            default:
                kept.append(scalar)
            }
        }
        let words = String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return words.count > limit ? String(words.prefix(limit - 1)) + "…" : words
    }

    /// An https address with a host and no user info, 2,048 characters at most.
    static func webAddress(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= 2_048, let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              host.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
        else { return nil }
        return components.url
    }

    static func version(_ text: String?) -> String? {
        guard let text, text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$"#, options: .regularExpression) != nil else { return nil }
        return text
    }

    static func isPackage(_ identifier: String, kind: MCPRegistryEntry.Package.Kind) -> Bool {
        let pattern = switch kind {
        case .npm: #"^(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]{0,213}$"#
        case .pypi: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$"#
        // registry/owner/name with an optional tag or digest.
        case .oci: #"^[a-z0-9][a-z0-9._-]*(\.[a-z0-9-]+)*(:[0-9]+)?(/[a-z0-9][a-z0-9._-]*)+(:[A-Za-z0-9._-]{1,128}|@sha256:[a-f0-9]{64})?$"#
        }
        return identifier.count <= 255 && identifier.range(of: pattern, options: .regularExpression) != nil
    }

    static func isEnvironmentName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil
    }

    static func isHeaderName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil
    }

    /// An input's name as a variable (`{token}`), or a flag's name without its dashes (`--from`
    /// → `from`).
    static func inputName(_ name: String) -> String? {
        let bare = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return bare.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil ? bare : nil
    }

    static func isFlag(_ flag: String) -> Bool {
        flag.range(of: #"^--?[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
    }

    /// One argument: printable, one line, 512 characters at most.
    static func isArgument(_ value: String) -> Bool {
        value.count <= 512 && !value.unicodeScalars.contains { scalar in
            [.control, .format, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory)
        }
    }

    /// The Docker options a registry may give: environment variables, a port on this Mac only,
    /// and the container's own lifetime. Mounts, devices, privileges and host networking are not
    /// among them.
    static let dockerFlags: Set<String> = ["-e", "--env", "-p", "--publish", "-i", "--interactive", "--rm", "--init"]
}

// MARK: What connecting an entry asks

extension MCPRegistryEntry {
    /// How the person connects it from Yardlet.
    enum Reach: Equatable, Sendable {
        /// Runs at the service; signing in happens in the browser, or not at all.
        case signIn(URL)
        /// Runs at the service and takes a key the person pastes.
        case key(URL, KeyHeader)
        /// Runs on this Mac, once the person has seen what runs.
        case local(Package)
        case unavailable(Limitation)
    }

    var reach: Reach {
        if let remote {
            if let header = remote.keyHeader { return .key(remote.url, header) }
            return .signIn(remote.url)
        }
        if let package { return .local(package) }
        return .unavailable(limitation ?? .nothingToRun)
    }

    /// Shown without a search: the ones that run at the service.
    var showsWithoutSearch: Bool {
        switch reach {
        case .signIn, .key: true
        case .local, .unavailable: false
        }
    }

    /// The domain the registry checked the publisher owns (`com.notion` → `notion.com`), for a
    /// namespace other than a GitHub account's.
    var publisherDomain: String? {
        let namespace = name.split(separator: "/").first.map(String.init) ?? ""
        let labels = namespace.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2, !(labels[0] == "io" && labels[1] == "github") else { return nil }
        return labels.reversed().joined(separator: ".")
    }

    /// The service published it itself: its namespace is a domain the registry checked, and the
    /// server runs on that domain (or, for a local program, the namespace alone).
    func isPublishedByService(suffixes: PublicSuffixList = .bundled) -> Bool {
        guard let domain = publisherDomain, let own = suffixes.registrableDomain(of: domain) else { return false }
        guard let host = remote?.url.host()?.lowercased() else { return package != nil }
        return suffixes.registrableDomain(of: host) == own
    }

    /// The registry's order for Yardlet's list: servers that run at the service, then programs,
    /// then those Yardlet cannot connect; in each, the service's own first, signing in before keys,
    /// both registries before one, then stars, then title.
    static func ranked(_ entries: [MCPRegistryEntry], suffixes: PublicSuffixList = .bundled) -> [MCPRegistryEntry] {
        func key(_ entry: MCPRegistryEntry) -> (Int, Int, Int, Int, Int) {
            let (group, reach) = switch entry.reach {
            case .signIn: (0, 0)
            case .key: (0, 1)
            case .local: (1, 0)
            case .unavailable: (2, 0)
            }
            return (group, entry.isPublishedByService(suffixes: suffixes) ? 0 : 1, reach, -entry.sources.count, -(entry.stars ?? 0))
        }
        let keyed = entries.map { (key($0), $0) }
        return keyed.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            let titles = lhs.1.title.localizedCaseInsensitiveCompare(rhs.1.title)
            return titles == .orderedSame ? lhs.1.name < rhs.1.name : titles == .orderedAscending
        }.map { $0.1 }
    }

    /// One list from several answers: an entry both registries list is one, with both sources, the
    /// GitHub registry's stars, and the first answer's fields; so is one at a server address seen
    /// already. Entries at a directory service's address, or already added, are left out.
    static func merged(_ lists: [[MCPRegistryEntry]], excludingAddresses excluded: Set<String> = []) -> [MCPRegistryEntry] {
        var order: [String] = []
        var byName: [String: MCPRegistryEntry] = [:]
        var nameByAddress: [String: String] = [:]
        for list in lists {
            for entry in list {
                let address = entry.remote.map { MCPServerAddress.canonical($0.url) }
                if let address, excluded.contains(address) { continue }
                let key = byName[entry.name] != nil ? entry.name : address.flatMap { nameByAddress[$0] } ?? entry.name
                if var existing = byName[key] {
                    for source in entry.sources where !existing.sources.contains(source) { existing.sources.append(source) }
                    existing.stars = existing.stars ?? entry.stars
                    if existing.icons.isEmpty { existing.icons = entry.icons }
                    byName[key] = existing
                } else {
                    order.append(key)
                    byName[key] = entry
                    if let address { nameByAddress[address] = key }
                }
            }
        }
        return order.compactMap { byName[$0] }
    }

    /// Whether a search names it: its title, registry name or summary holds every word.
    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [title, name, summary, package?.identifier ?? ""].joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

// MARK: Asking the registries

/// Reads the registries: the GitHub MCP Registry for the list Yardlet shows (it is the
/// subregistry VS Code reads, sorted by stars), and both for a search. The official registry asks
/// host apps to read it through a subregistry and to scrape it rarely, so Yardlet asks it only
/// with a search. Answers are read only; nothing is sent but the search words.
struct MCPRegistryClient: Sendable {
    struct Endpoints: Equatable, Sendable {
        var github: URL
        var official: URL

        static let live = Endpoints(
            github: URL(string: "https://api.mcp.github.com/v0.1/servers")!,
            official: URL(string: "https://registry.modelcontextprotocol.io/v0.1/servers")!
        )
    }

    enum Failure: Error, Equatable, LocalizedError {
        case http(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .http(429), .http(403): L10n.string("The registry asked Yardlet to wait. Try again in a minute.")
            case .http(let status): L10n.format("The registry answered with an error (%lld).", Int64(status))
            case .unreadable: L10n.string("The registry's answer could not be read.")
            }
        }
    }

    var endpoints: Endpoints = .live
    let http: any ConnectorHTTPTransport
    var clientVersion = "1"
    static let pageSize = 50
    static let searchSize = 30

    /// One page of the GitHub registry's list, most stars first.
    func browse(cursor: String?) async throws -> MCPRegistryFormat.Page {
        try await page(.github, items: ["limit": String(Self.pageSize), "cursor": cursor])
    }

    /// Both registries' matches for a search, each its own list; a registry that fails gives none
    /// while the other's are kept, and only when both fail does the search fail.
    func search(_ query: String) async throws -> [[MCPRegistryEntry]] {
        let words = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !words.isEmpty else { return [] }
        async let github = try? page(.github, items: ["search": words, "limit": String(Self.searchSize)])
        async let official = try? page(.official, items: ["search": words, "version": "latest", "limit": String(Self.searchSize)])
        let answers = await [github, official]
        if answers.allSatisfy({ $0 == nil }) {
            // Asked once more, so the person reads why.
            _ = try await page(.github, items: ["search": words, "limit": String(Self.searchSize)])
        }
        return answers.compactMap { $0?.entries }
    }

    private func page(_ source: MCPRegistryEntry.Source, items: [String: String?]) async throws -> MCPRegistryFormat.Page {
        let base = source == .github ? endpoints.github : endpoints.official
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = items.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
            .sorted { $0.name < $1.name }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Yardlet/\(clientVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
        guard let page = MCPRegistryFormat.page(data, source: source) else { throw Failure.unreadable }
        return page
    }
}
