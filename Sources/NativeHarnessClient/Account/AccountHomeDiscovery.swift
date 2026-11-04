import Foundation

/// A Claude or Codex folder with a login or conversations that Yardlet has not saved as an account.
/// It is offered in Settings › Harness Accounts and in the import sheets; adding it saves `connection`,
/// which names the folder as it is. Nothing in the folder is read but its identity.
struct DiscoveredAccountHome: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// An account folder Session Switch made.
        case sessionSwitch
        /// A `CLAUDE_CONFIG_DIR` or `CODEX_HOME` a shell file sets, by its path from home ("~/.zshrc").
        case shellFile(String)
        /// Yardlet's own environment.
        case environment
        /// The folder the Claude and Codex apps use (`~/.claude`, `~/.codex`) while the default
        /// login is elsewhere.
        case appFolder
        /// A folder in the home folder named like one (`~/.claude-work`, `~/.codex_personal`).
        case homeFolder
        /// A folder of the same shape beside a saved account's, as a multi-account tool keeps
        /// its account folders side by side.
        case besideSavedAccount
    }

    let connection: ProviderConnection
    let source: Source
    /// The claude.ai account the folder's `.claude.json` names; nil for Codex and a signed-out folder.
    var email: String?
    var organization: String?
    /// Whether the folder's `projects` is the default login's, so its tasks can move between them.
    var sharesConversations = false

    var id: String { connection.harness.rawValue + ":" + path }
    var harness: HarnessKind { connection.harness }
    var path: String { connection.homePath ?? "" }

    /// The account the folder holds, as account rows name one, else the folder.
    var title: String {
        guard let email else { return ProjectSidebarPresentation.abbreviatedPath(for: URL(filePath: path)) }
        return AccountIdentityProjection.organizationTitle(organization, of: email).map { "\(email) · \($0)" } ?? email
    }

    /// Where the folder was found, then the folder unless the title already names it.
    var subtitle: String {
        let place: String = switch source {
        case .sessionSwitch: "Session Switch"
        case .shellFile(let file):
            L10n.format("%@ in %@", harness == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR", file)
        case .environment:
            L10n.format("%@ in Yardlet's environment", harness == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR")
        case .appFolder: L10n.format("The %@ app's folder", harness == .codex ? "Codex" : "Claude")
        case .homeFolder: L10n.string("Folder in your home")
        case .besideSavedAccount: L10n.string("Beside a saved account's folder")
        }
        guard email != nil else { return place }
        return place + " · " + ProjectSidebarPresentation.abbreviatedPath(for: URL(filePath: path))
    }
}

/// Finds folders a person's own setup points Claude Code or Codex at: a `CLAUDE_CONFIG_DIR` or
/// `CODEX_HOME` set in Yardlet's environment or written in a shell file (read only), the apps' own
/// folders when the default login is elsewhere, folders in the home folder named like them,
/// Session Switch's account folders, and folders of the same shape beside a saved account's (where
/// a multi-account tool keeps the others). Only these places are looked at; the disk is not
/// searched, and no tool but Session Switch is named. A folder found by its place alone (in the
/// home folder or beside an account) must hold a login (`.claude.json`, `auth.json`); one a
/// setting names may hold only history.
enum AccountHomeDiscovery {
    static let shellFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile", ".bashrc", ".profile",
                             ".config/fish/config.fish"]
    static let sessionSwitchAccounts = "Library/Application Support/Session Switch/accounts"

    static func find(saved: [ProviderConnection], defaults: [HarnessKind: URL], environment: [String: String],
                     homeURL: URL) -> [DiscoveredAccountHome] {
        var candidates: [(HarnessKind, URL, DiscoveredAccountHome.Source)] = []
        for (harness, variable) in [(HarnessKind.claudeCode, "CLAUDE_CONFIG_DIR"), (.codex, "CODEX_HOME")] {
            if let value = environment[variable], let url = expand(value, homeURL: homeURL) {
                candidates.append((harness, url, .environment))
            }
            for file in shellFiles {
                guard let text = try? String(contentsOf: homeURL.appending(path: file), encoding: .utf8) else { continue }
                for url in assignments(of: variable, in: text, homeURL: homeURL) {
                    candidates.append((harness, url, .shellFile("~/" + file)))
                }
            }
        }
        candidates.append((.claudeCode, homeURL.appending(path: ".claude"), .appFolder))
        candidates.append((.codex, homeURL.appending(path: ".codex"), .appFolder))
        func names(in folder: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).sorted()
        }
        for name in names(in: homeURL) {
            for (harness, prefix) in [(HarnessKind.claudeCode, ".claude"), (.codex, ".codex")]
            where name.hasPrefix(prefix + "-") || name.hasPrefix(prefix + "_") {
                candidates.append((harness, homeURL.appending(path: name), .homeFolder))
            }
        }
        let sessionSwitch = homeURL.appending(path: sessionSwitchAccounts, directoryHint: .isDirectory)
        for folder in names(in: sessionSwitch) {
            candidates.append((.claudeCode, sessionSwitch.appending(path: folder), .sessionSwitch))
        }
        // Not beside a folder in the home folder itself: that would look into every folder there.
        let home = ProjectSidebarPresentation.normalizedPath(for: homeURL)
        var parents = Set<String>()
        for connection in saved where [.claudeCode, .codex].contains(connection.harness) {
            guard let path = connection.homePath else { continue }
            let parent = URL(filePath: path).deletingLastPathComponent()
            let key = connection.harness.rawValue + ProjectSidebarPresentation.normalizedPath(for: parent)
            guard ProjectSidebarPresentation.normalizedPath(for: parent) != home, parents.insert(key).inserted else { continue }
            for name in names(in: parent) where !name.hasPrefix(".") {
                candidates.append((connection.harness, parent.appending(path: name), .besideSavedAccount))
            }
        }

        func key(_ url: URL) -> String { ProjectSidebarPresentation.normalizedPath(for: url.resolvingSymlinksInPath()) }
        var seen = Set(saved.compactMap { connection in
            connection.homePath.map { connection.harness.rawValue + key(URL(filePath: $0)) }
        })
        for (harness, url) in defaults { seen.insert(harness.rawValue + key(url)) }
        var found: [DiscoveredAccountHome] = []
        for (harness, url, source) in candidates where seen.insert(harness.rawValue + key(url)).inserted {
            guard let home = discovered(harness: harness, url: url, source: source, homeURL: homeURL,
                                        defaultHome: defaults[harness]) else { continue }
            found.append(home)
        }
        return found
    }

    private static func discovered(harness: HarnessKind, url: URL, source: DiscoveredAccountHome.Source,
                                   homeURL: URL, defaultHome: URL?) -> DiscoveredAccountHome? {
        let fileManager = FileManager.default
        func exists(_ name: String) -> Bool { fileManager.fileExists(atPath: url.appending(path: name).path(percentEncoded: false)) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let path = ProjectSidebarPresentation.normalizedPath(for: url)
        var email: String?
        var organization: String?
        // A folder found by its place alone must hold a login; one a setting names may hold only history.
        let needsLogin = source == .homeFolder || source == .besideSavedAccount
        switch harness {
        case .claudeCode:
            let file = NativeMCPHome.claudeConfigFile(configDirectory: url, homeURL: homeURL)
            guard !needsLogin || fileManager.fileExists(atPath: file.path(percentEncoded: false)) else { return nil }
            let account = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?["oauthAccount"]
            email = account?["emailAddress"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            organization = account?["organizationName"]?.stringValue
            guard email != nil || exists("projects") else { return nil }
        case .codex:
            guard needsLogin ? exists("auth.json")
                : exists("auth.json") || exists("sessions") || exists("config.toml") else { return nil }
        default:
            return nil
        }
        let connection = ProviderConnection(id: UUID().uuidString,
            name: email ?? url.lastPathComponent, harness: harness, providerID: nil, homePath: path,
            credentialSelector: nil)
        var shares = false
        if harness == .claudeCode, let defaultHome {
            let projects = { (folder: URL) in
                ProjectSidebarPresentation.normalizedPath(for: folder.appending(path: "projects").resolvingSymlinksInPath())
            }
            shares = exists("projects") && projects(url) == projects(defaultHome)
        }
        return DiscoveredAccountHome(connection: connection, source: source, email: email, organization: organization,
                                     sharesConversations: shares)
    }

    /// The folders a shell file assigns `variable`: `export VAR=…`, `VAR=… command` (an alias body
    /// too) and fish's `set -gx VAR …`. A value that needs more than `~` or `$HOME` to expand, or
    /// stays relative, is left out; commented lines are skipped.
    static func assignments(of variable: String, in text: String, homeURL: URL) -> [URL] {
        let pattern = #"(?:^|[\s;'"(])(?:"# + variable + #"=|set\s+(?:-[a-zA-Z]+\s+)*"# + variable
            + #"\s+)("[^"]*"|'[^']*'|[^\s;'"|&)]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: [URL] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let line = String(line)
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { continue }
            for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let range = Range(match.range(at: 1), in: line),
                      let url = expand(String(line[range]), homeURL: homeURL) else { continue }
                found.append(url)
            }
        }
        return found
    }

    static func expand(_ raw: String, homeURL: URL) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        let home = homeURL.path(percentEncoded: false).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        for prefix in ["~", "${HOME}", "$HOME"] where value == prefix || value.hasPrefix(prefix + "/") {
            value = home + value.dropFirst(prefix.count)
            break
        }
        guard value.hasPrefix("/"), !value.contains("$"), !value.contains("`") else { return nil }
        return URL(filePath: value, directoryHint: .isDirectory).standardizedFileURL
    }
}
