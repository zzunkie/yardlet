import Foundation

/// Where a conversation imported from another app goes in Yardlet. The one decision every import
/// path asks, kept here so the sidebar's Chats can take it over in one place.
enum ConversationImportPlacement: Equatable, Sendable {
    /// A chat's folder (`ChatWorkspaces`): the task belongs to no project.
    case chat
    /// The project of this folder: a worktree's original repository, else the conversation's own
    /// folder, or the nearest of `projectRoots` that holds either inside it. The task's cwd stays
    /// the conversation's folder either way.
    case project(root: URL)

    /// - Parameter projectRoots: folders that are or will be projects (the person's projects and the
    ///   other conversations being imported), so a conversation in a folder inside one joins it.
    static func of(
        _ conversation: ImportableConversation,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        projectRoots: [URL] = []
    ) -> ConversationImportPlacement {
        if ChatWorkspaces.isChat(conversation.workspaceURL, home: home) { return .chat }
        let folder = folder(of: conversation)
        return .project(root: nearestEnclosing(folder, in: projectRoots, home: home) ?? folder)
    }

    /// The folder a conversation stands for: its worktree's repository, else its own.
    static func folder(of conversation: ImportableConversation) -> URL {
        conversation.workspaceOrigin?.originWorkspaceURL ?? conversation.workspaceURL
    }

    /// The nearest of `roots` that holds `folder` strictly inside it. The home folder and the
    /// folders above it never count, so a project there does not take in everything.
    static func nearestEnclosing(_ folder: URL, in roots: [URL], home: URL) -> URL? {
        func path(_ url: URL) -> String { PathRules.current.path(of: url.standardizedFileURL) }
        let target = path(folder)
        let homePath = path(home)
        return roots
            .filter { root in
                let base = path(root)
                return PathRules.current.isStrictlyInside(target, folder: base) && !PathRules.current.isInside(homePath, folder: base)
            }
            .max { path($0).count < path($1).count }
    }
}

/// The group an import list shows a conversation under: Chats, or a project by its name.
struct ConversationImportDestination: Hashable, Sendable {
    /// The project's ID, the folder that would become a project, or `chats`.
    let id: String
    let name: String

    static var chats: ConversationImportDestination {
        ConversationImportDestination(id: "chats", name: L10n.string("Chats"))
    }

    var isChats: Bool { id == "chats" }
}

/// The conversations open in the Claude and Codex apps and Antigravity CLI, and why a source
/// could not be read.
struct OtherAppConversations: Equatable, Sendable {
    var claude: [ImportableConversation] = []
    var codex: [ImportableConversation] = []
    var codexError: String?
    var antigravity: [ImportableConversation] = []
    var antigravityError: String?

    var all: [ImportableConversation] { claude + codex + antigravity }

    /// The list with each conversation that names no origin given its folder's, when the folder is
    /// a linked Git worktree. Only Git's files are read; nothing starts.
    func resolvingWorktreeOrigins(reader: GitMetadataReader = .live) -> OtherAppConversations {
        func resolved(_ conversation: ImportableConversation) -> ImportableConversation {
            guard conversation.workspaceOrigin == nil else { return conversation }
            let origin = GitWorktreeOriginResolver.resolve(workspaceURL: conversation.workspaceURL, reader: reader)
            guard origin.isWorktree else { return conversation }
            var copy = conversation
            copy.workspaceOrigin = origin
            return copy
        }
        var copy = self
        copy.claude = claude.map(resolved)
        copy.codex = codex.map(resolved)
        copy.antigravity = antigravity.map(resolved)
        return copy
    }
}

/// A Claude conversation another app's process still holds. Yardlet follows it read-only and
/// does not continue it as well; it continues here once that app lets it go.
struct ConversationHeldElsewhere: LocalizedError, Equatable {
    var errorDescription: String? {
        L10n.string("This conversation is still open in the Claude app. It continues here once you close it there.")
    }
}

/// What following a detached task compares to notice another app's writes: the provider file's
/// size and modification time.
struct DetachedConversationStamp: Equatable, Sendable {
    let size: Int
    let modified: Date

    init?(file: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false)),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.size = size
        self.modified = modified
    }
}
