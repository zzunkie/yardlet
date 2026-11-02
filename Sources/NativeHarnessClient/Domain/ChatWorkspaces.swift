import Foundation

/// Folders a harness app makes for a conversation that belongs to no project, the way the Codex app
/// files a chat under `~/Documents/Codex/<date>/<name>` and the Claude app under its
/// `scratch-workspaces`. A task in one of these folders is a chat: the sidebar lists it under Chats
/// rather than making the folder a project. Yardlet's own chats go under `~/Documents/Yardlet`.
/// A folder the person added as a project stays a project.
enum ChatWorkspaces {
    /// Where Yardlet makes a chat's folder: `<root>/<yyyy-MM-dd>/<name>`.
    static func yardletRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Documents/Yardlet", directoryHint: .isDirectory)
    }

    /// Every folder whose subfolders are chats: Yardlet's, the Codex app's and the Claude app's.
    static func roots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [yardletRoot(home: home),
         home.appending(path: "Documents/Codex", directoryHint: .isDirectory),
         home.appending(path: "Library/Application Support/Claude/scratch-workspaces", directoryHint: .isDirectory)]
    }

    /// Whether `workspace` is a chat's folder: inside one of the roots, not the root itself.
    /// The sidebar asks this of every task on every redraw, so each answer is kept for the folder.
    /// The folder's own path counts as well as where it leads, so a chat whose folder was later
    /// replaced by a link to a project's folder stays in Chats instead of moving to a group named
    /// after the old folder, and a root reached through a link still counts.
    static func isChat(_ workspace: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let key = home.path(percentEncoded: false) + "\u{0}" + workspace.path(percentEncoded: false)
        if let known = answers.value(for: key) { return known }
        let folder = workspace.standardizedFileURL
        let resolved = folder.resolvingSymlinksInPath()
        let isChat = roots(home: home).contains { root in
            let root = root.standardizedFileURL
            return contains(root, folder) || contains(root.resolvingSymlinksInPath(), resolved)
        }
        answers.set(isChat, for: key)
        return isChat
    }

    private static func contains(_ root: URL, _ folder: URL) -> Bool {
        let base = root.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let path = folder.path(percentEncoded: false)
        return path.hasPrefix(prefix) && path.count > prefix.count
    }

    /// The name a new chat's folder starts from, as the Codex app names its chats' folders.
    static let newChatName = "new-chat"

    /// Makes a new chat's folder under `root`, in the folder of `date` (`yyyy-MM-dd`, local time):
    /// `new-chat`, or `new-chat-2`, `new-chat-3`… when that name is taken. Nothing that exists is
    /// reused or changed.
    static func makeFolder(in root: URL, on date: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        let day = root.appending(path: dayName(for: date), directoryHint: .isDirectory)
        try fileManager.createDirectory(at: day, withIntermediateDirectories: true)
        var number = 1
        while true {
            let name = number == 1 ? newChatName : "\(newChatName)-\(number)"
            let folder = day.appending(path: name, directoryHint: .isDirectory)
            do {
                // Without intermediate folders, creating fails when the name is already there.
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
                return Project.canonical(folder)
            } catch where fileManager.fileExists(atPath: folder.path(percentEncoded: false)) {
                number += 1
            }
        }
    }

    /// `yyyy-MM-dd` in the Gregorian calendar and the local time zone.
    static func dayName(for date: Date) -> String {
        let day = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    private static let answers = Answers()

    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Bool] = [:]

        func value(for key: String) -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func set(_ value: Bool, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            values[key] = value
        }
    }
}
