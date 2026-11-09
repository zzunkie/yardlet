import Foundation

/// Where the worktrees Yardlet makes for new tasks live: `~/.yardlet/worktrees/<repository>/<name>`,
/// each on its own branch `yardlet/<name>` made from the repository's current HEAD.
///
/// The folder is Yardlet's own storage root rather than a repository, so a task's worktree never
/// appears as untracked files in the checkout it came from. It is not the Codex app's
/// `~/.codex/worktrees` either, whose own clean-up would treat these worktrees as its own, and its
/// path has no spaces, so build scripts that do not quote paths keep working inside it.
///
/// Being inside this folder is also what marks a worktree as Yardlet's: archive clean-up only
/// ever considers a task's folder when it lies exactly here.
struct TaskWorktreeLayout: Equatable, Sendable {
    let rootURL: URL

    static let branchPrefix = "yardlet/"

    static func live(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> TaskWorktreeLayout {
        TaskWorktreeLayout(
            rootURL: homeURL
                .appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
                .appending(path: "worktrees", directoryHint: .isDirectory)
        )
    }

    func worktreeURL(repositoryFolder: String, name: String) -> URL {
        rootURL.appending(path: repositoryFolder, directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
    }

    /// The Yardlet worktree a task's folder is in — the folder itself, or the worktree that holds
    /// it when the task runs in a subfolder — or nil when the folder is anywhere else.
    func worktreeURL(containing workspaceURL: URL) -> URL? {
        let root = ProjectSidebarPresentation.normalizedPath(for: rootURL)
        let path = ProjectSidebarPresentation.normalizedPath(for: workspaceURL)
        guard let relative = PathRules.current.relativePath(of: path, in: root) else { return nil }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return nil }
        return worktreeURL(repositoryFolder: String(components[0]), name: String(components[1]))
    }
}

/// Short, readable worktree and branch names taken from a task's first prompt.
enum TaskWorktreeNaming {
    static let maximumLength = 40
    /// The Codex app suggests branch names from a task's first five words as well.
    private static let maximumWords = 5
    private static let trailingFillers: Set<String> = [
        "a", "an", "and", "at", "by", "for", "from", "in", "into", "of", "on", "or", "the", "to", "with"
    ]

    /// Lowercase ASCII words from the first line, joined by hyphens: both a valid folder name and
    /// a valid branch name component. Other scripts are transliterated first so a Korean or
    /// Japanese prompt still names its worktree; a prompt with no letters at all becomes `task`.
    static func slug(from text: String, fallback: String = "task") -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        let latin = line.applyingTransform(.toLatin, reverse: false) ?? line
        let plain = (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin).lowercased()
        var words = Array(plain
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .prefix(maximumWords))
        while words.count > 1, let last = words.last, trailingFillers.contains(String(last)) {
            words.removeLast()
        }
        var slug = ""
        for word in words {
            let candidate = slug.isEmpty ? String(word) : slug + "-" + word
            if candidate.count > maximumLength {
                // A single overlong first word is cut rather than dropped.
                if slug.isEmpty { slug = String(word.prefix(maximumLength)) }
                break
            }
            slug = candidate
        }
        return slug.isEmpty ? fallback : slug
    }

    /// The name itself, then numbered alternatives, for picking one nobody has used yet.
    static func candidates(for slug: String, limit: Int = 50) -> [String] {
        [slug] + (2...max(2, limit)).map { "\(slug)-\($0)" }
    }
}

/// A linked worktree made for a new task.
struct TaskWorktree: Equatable, Sendable {
    /// The folder the task runs in: the worktree itself, or the same subfolder inside it that the
    /// task was started from.
    let workspaceURL: URL
    let worktreeURL: URL
    /// The checkout the worktree was made from.
    let sourceURL: URL
    let branch: String
    /// The commit the branch started at.
    let baseCommit: String
    /// Git LFS files left as their pointers: their content was never downloaded on this Mac, or Git
    /// LFS is not installed (`TaskWorktreeService` checks out without the network).
    var largeFilesLeftAsPointers = 0
}

enum TaskWorktreeError: LocalizedError, Equatable, Sendable {
    case notARepository
    case noCommits
    case missingFolder(String)
    case timedOut
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .notARepository:
            L10n.string("The folder isn't in a Git repository, so it can't have a worktree.")
        case .noCommits:
            L10n.string("The repository has no commits yet, so a worktree can't be made from it.")
        case let .missingFolder(folder):
            L10n.format("“%@” isn't in the repository's committed files, so the new worktree doesn't have it.", folder)
        case .timedOut:
            L10n.string("Git didn't finish in time.")
        case let .gitFailed(message):
            L10n.format("Couldn't create the worktree: %@", message)
        }
    }
}

/// What archiving a task did with the Yardlet worktree it ran in.
enum TaskWorktreeCleanup: Equatable, Sendable {
    /// The folder is gone; its branch stays for unarchiving.
    case removed
    case keptUncommittedChanges
    case keptUnmergedCommits(branch: String?)
    /// Git refused to remove it; the message is Git's.
    case failed(String)
    /// Already gone, not a linked worktree, or not one Yardlet made: nothing was touched.
    case untouched
}

/// What restoring an archived task did about its missing Yardlet worktree.
enum TaskWorktreeRestoration: Equatable, Sendable {
    case recreated
    /// The worktree is still there, or the task never ran in one of Yardlet's worktrees.
    case notNeeded
    case repositoryMissing(String)
    case branchMissing(String?)
    case failed(String)
}
