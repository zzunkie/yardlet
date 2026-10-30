import Foundation

/// The shape of a Claude account folder that shares everything but its login with the default
/// config folder, as Session Switch makes its account folders: the entries Claude Code ties to the
/// signed-in account or its organization stay in the folder, and every other entry of the default
/// folder is a link to it. Every login then reads one conversation history, one set of settings,
/// plugins and skills, so a task can continue under another login (`TaskAccountSwitch`).
///
/// Only links are ever made or removed here. Nothing is copied, moved or deleted, except an empty
/// folder giving way to a link; the shared originals are never touched.
enum ClaudeAccountHome {
    /// Entries Claude Code (2.1.291) ties to the account or organization a folder is signed in to:
    /// `backups` holds copies of the folder's own `.claude.json` (where the login's identity lives),
    /// `cache` the plan's model catalog and team discovery, `statsig` and `telemetry` the account's
    /// feature flags and unsent events, `mcp-discovery-cache` and `mcp-needs-auth-cache.json` the
    /// state of MCP sign-ins whose tokens the folder's Keychain item holds. The prefixes cover the
    /// organization's `policy-limits.json` and `remote-settings.json` with their signature, stamp
    /// and consent files. Dot files (`.claude.json`, `.credentials.json`) are the login itself.
    static let accountEntries: Set<String> = [
        "backups", "cache", "statsig", "telemetry", "mcp-discovery-cache", "mcp-needs-auth-cache.json"
    ]
    static let accountEntryPrefixes = ["policy-limits", "remote-settings"]
    /// A name that reads like a credential stays with the folder even when this list does not know
    /// it yet (`hfi-auth.json`, `.session_ingress_token`): linking one would hand it to every login.
    private static let credentialWords = ["auth", "credential", "token"]

    static func isAccountEntry(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return name.hasPrefix(".") || accountEntries.contains(name)
            || accountEntryPrefixes.contains { name.hasPrefix($0) }
            || credentialWords.contains { lowered.contains($0) }
    }

    /// What making `home` share with `primary` changes, worked out from the folders as they are.
    struct Plan: Equatable, Sendable {
        /// Shared entries the folder lacks; each becomes a link to the default folder's.
        var links: [String] = []
        /// Shared entries the folder holds as empty folders; each gives way to a link.
        var emptyFolders: [String] = []
        /// Shared entries the folder keeps its own content in; they stay as they are.
        var kept: [String] = []
        /// Entries that link somewhere other than the default folder; they stay as they are.
        var linkedElsewhere: [String] = []
        /// Whether the folder reads the default folder's conversations once the plan is applied.
        var sharesConversations = false

        var hasChanges: Bool { !links.isEmpty || !emptyFolders.isEmpty }
        /// The folder's own conversations, which stay apart from the default folder's.
        var keepsOwnConversations: Bool { kept.contains("projects") }
    }

    static func plan(home: URL, primary: URL) -> Plan {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: primary.path(percentEncoded: false))) ?? []
        var plan = Plan()
        for name in names.sorted() where !isAccountEntry(name) {
            let path = home.appending(path: name).path(percentEncoded: false)
            switch entry(at: path) {
            case .missing: plan.links.append(name)
            case .emptyFolder: plan.emptyFolders.append(name)
            case .content: plan.kept.append(name)
            case .link(let destination):
                if !isSame(destination, in: home, primary.appending(path: name)) { plan.linkedElsewhere.append(name) }
            }
        }
        // A folder holding conversations the default folder has none of yet keeps them too.
        if !names.contains("projects"), entry(at: home.appending(path: "projects").path(percentEncoded: false)) == .content {
            plan.kept.append("projects")
        }
        let projects = home.appending(path: "projects").path(percentEncoded: false)
        if case .link(let destination) = entry(at: projects) {
            plan.sharesConversations = isSame(destination, in: home, primary.appending(path: "projects"))
        } else {
            plan.sharesConversations = plan.links.contains("projects") || plan.emptyFolders.contains("projects")
        }
        return plan
    }

    /// Makes the links `plan` lists, checking each entry again first: one that changed since the
    /// plan was made stays as it is. An empty folder is removed with `rmdir`, which refuses a folder
    /// that is no longer empty.
    static func apply(_ plan: Plan, home: URL, primary: URL) throws {
        for name in plan.emptyFolders + plan.links {
            let path = home.appending(path: name).path(percentEncoded: false)
            switch entry(at: path) {
            case .emptyFolder: guard rmdir(path) == 0 else { continue }
            case .missing: break
            default: continue
            }
            try FileManager.default.createSymbolicLink(atPath: path,
                withDestinationPath: primary.appending(path: name).path(percentEncoded: false))
        }
    }

    /// Prepares a folder Yardlet made for a new login, before the login runs. The default folder
    /// gains an empty `projects` when it has none yet, as Claude Code would make it there, so the
    /// new login's conversations go where the default login's will be.
    static func prepareNewHome(_ home: URL, primary: URL) throws {
        let projects = primary.appending(path: "projects")
        if entry(at: projects.path(percentEncoded: false)) == .missing {
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try apply(plan(home: home, primary: primary), home: home, primary: primary)
    }

    /// Removes every link directly inside `home`, so nothing that later removes the folder can reach
    /// what the links point to. Only the links go; the folder's own files and the originals stay.
    static func unlinkShared(home: URL) throws {
        let fileManager = FileManager.default
        let path = home.path(percentEncoded: false)
        guard case .content = entry(at: path) else { return }
        for name in try fileManager.contentsOfDirectory(atPath: path) {
            let entryPath = home.appending(path: name).path(percentEncoded: false)
            if case .link = entry(at: entryPath), !removeLink(at: entryPath) {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: entryPath])
            }
        }
    }

    /// Removes the link itself, never what it points to.
    private static func removeLink(at path: String) -> Bool {
        #if os(Windows)
        // A folder link must go with RemoveDirectoryW, which the Windows layer does not have yet; a
        // removal that could follow the link into the original is not tried.
        false
        #else
        unlink(path) == 0
        #endif
    }

    private enum Entry: Equatable {
        case missing, emptyFolder, content
        case link(String)
    }

    /// What is at `path`, without following a link there.
    private static func entry(at path: String) -> Entry {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return .missing }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return .link((try? fileManager.destinationOfSymbolicLink(atPath: path)) ?? "")
        }
        if attributes[.type] as? FileAttributeType == .typeDirectory,
           (try? fileManager.contentsOfDirectory(atPath: path))?.isEmpty == true {
            return .emptyFolder
        }
        return .content
    }

    /// Whether a link in `home` reaching `destination` (absolute, or relative to `home`) ends at `url`.
    private static func isSame(_ destination: String, in home: URL, _ url: URL) -> Bool {
        guard !destination.isEmpty else { return false }
        let target = destination.hasPrefix("/") ? URL(filePath: destination) : home.appending(path: destination)
        return ProjectSidebarPresentation.normalizedPath(for: target.resolvingSymlinksInPath())
            == ProjectSidebarPresentation.normalizedPath(for: url.resolvingSymlinksInPath())
    }
}
