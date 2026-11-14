import Foundation

/// Which browser profile each task's tabs use (docs/BROWSER_SESSION_ISOLATION.md). With "Keep cookies" per task, the
/// default, tasks share the default profile, as the Codex app's threads share one browser: the person's sign-ins reach
/// every task as they are made, and a site that keeps several accounts in one set of cookies (Google) keeps them all.
/// A task takes a profile of its own (`<root cache>/Task-<key>`; Chromium opens a profile on disk only in a direct
/// child of its root cache) just before its agent signs in to a site itself or runs its first page script, starting as
/// a copy of the default profile's cookies, so its sign-in changes no other task's. A child task of such a task starts with a copy of its
/// parent's. The vault's sign-ins stay shared. With shared storage every tab uses the default profile.
@MainActor
final class BrowserTaskProfiles {
    /// Settings › General "Keep cookies", as the Claude app's (`launchPreviewStorage`: per session or shared).
    enum Storage: String, CaseIterable, Identifiable, Sendable {
        case perTask
        case shared

        var id: Self { self }

        var title: String {
            switch self {
            case .perTask: L10n.string("Per task")
            case .shared: L10n.string("Shared by all tasks")
            }
        }
    }

    static let storageKey = "YardletBrowserCookieStorage"

    /// The browser's root cache, where Chromium keeps the default profile and its own folders too.
    let root: URL
    /// A task profile's folder name is this and its key (the host's `TaskProfiles` names it the same).
    nonisolated static let folderPrefix = "Task-"
    /// The folder in the root cache that removed profiles go to, to be deleted off the main thread (`removeFolders`).
    nonisolated static let removingFolderName = "Removed task profiles"
    private nonisolated static let deleting = DispatchQueue(label: "Yardlet.browser.removed-profiles", qos: .utility)
    private static let savedFile = "TaskProfiles.json"
    private let defaults: UserDefaults
    /// The task a task was started from (`create_task`): a child of a task with a profile of its own starts from it.
    var parentOf: @MainActor (UUID) -> UUID? = { _ in nil }

    /// Saved in the root cache.
    private struct Saved: Codable {
        /// Tasks whose profile has another key than their ID: they took over the new-task screen's tabs before tasks
        /// shared the default profile, or their ID's folder was in use when they took a profile of their own.
        var aliases: [String: String] = [:]
        /// The profiles of their own, by key, each with the key of the profile a new folder starts from (a parent
        /// task's), empty for the default profile.
        var own: [String: String]?
        /// Child tasks whose first tab opened in the default profile, where they stay, though their parent takes a
        /// profile of its own later.
        var sharedChildren: Set<String>?
        /// Whether the task profiles from before tasks shared the default profile were sorted (`shareEarlierProfiles`).
        var sorted: Bool?
        /// Before tasks shared the default profile: the sites each profile had signed in to itself.
        var following: Earlier?
    }

    private struct Earlier: Codable {
        var own: [String: Set<String>]?
    }

    private var saved: Saved

    init(root: URL, defaults: UserDefaults = .yardlet) {
        self.root = root
        self.defaults = defaults
        StateFileWriter.shared.flush()
        saved = (try? Data(contentsOf: root.appending(path: Self.savedFile)))
            .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    var storage: Storage {
        get { defaults.string(forKey: Self.storageKey).flatMap(Storage.init(rawValue:)) ?? .perTask }
        set { defaults.set(newValue.rawValue, forKey: Self.storageKey) }
    }

    /// The folder key of a task's profile.
    func key(for session: UUID) -> String {
        saved.aliases[session.uuidString] ?? session.uuidString
    }

    func folder(for key: String) -> URL {
        root.appending(path: Self.folderPrefix + key, directoryHint: .isDirectory)
    }

    func folderExists(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(for: key).path(percentEncoded: false))
    }

    /// Whether the profile with this key is one of its own. Until the earlier profiles are sorted, a task keeps the
    /// folder it has.
    private func isOwn(_ key: String) -> Bool {
        saved.own?[key] != nil || (saved.sorted != true && folderExists(key))
    }

    /// The panels that are no task's and keep the default profile: the new-task screen's, whose tabs the task it starts
    /// takes over, and the mailbox's, which opens mail's links with the person's own sign-ins (docs/MAILBOX.md, "Links").
    private static let taskless: Set<UUID> = [TaskWorkspaceStore.draftID, TaskWorkspaceStore.mailID]

    /// Whether the task's tabs use a profile of their own.
    func hasOwnProfile(_ session: UUID) -> Bool {
        !Self.taskless.contains(session) && isOwn(key(for: session))
    }

    /// The profile a task's tabs use; nil for the default profile.
    func profile(for session: UUID) -> BrowserTabProfile? {
        guard storage == .perTask, hasOwnProfile(session) else { return nil }
        let key = key(for: session)
        // A new folder starts from its parent's, while that is there.
        let seed = saved.own?[key].flatMap { $0.isEmpty || folderExists(key) || !folderExists($0) ? nil : $0 }
        return BrowserTabProfile(key: key, seedFrom: seed)
    }

    /// What a tab of the task opens in: a child task's first tab decides whether it takes a copy of its parent's
    /// profile of its own (when its parent has one then) or stays in the default profile.
    func opening(for session: UUID) -> BrowserTabProfile? {
        guard storage == .perTask, !Self.taskless.contains(session) else { return nil }
        let key = key(for: session)
        if !isOwn(key), !(saved.sharedChildren?.contains(key) ?? false), let parent = parentOf(session) {
            let parentKey = self.key(for: parent)
            if isOwn(parentKey) {
                saved.own = (saved.own ?? [:]).merging([key: parentKey]) { $1 }
            } else {
                saved.sharedChildren = (saved.sharedChildren ?? []).union([key])
            }
            save()
        }
        return profile(for: session)
    }

    /// The task's agent is about to sign in to a site itself (a fill from the password manager, typing into a password
    /// or one-time code field) or to run its first page script: the task takes a profile of its own, which starts as a
    /// copy of the default profile's cookies, so that sign-in changes no other task's. False when the task has one already, or every task
    /// shares the default profile (the setting).
    func takeOwnProfile(for session: UUID) -> Bool {
        guard storage == .perTask, !Self.taskless.contains(session) else { return false }
        var key = key(for: session)
        guard !isOwn(key) else { return false }
        // A folder left from before tasks shared the default profile, not yet removed, is no copy of it.
        if folderExists(key) {
            key = UUID().uuidString
            saved.aliases[session.uuidString] = key
        }
        saved.own = (saved.own ?? [:]).merging([key: ""]) { $1 }
        save()
        return true
    }

    /// Sorts the task profiles from before tasks shared the default profile, once, before the browser host first
    /// starts. A profile that had signed in to a site itself (`following.own`) stays its task's; every other one holds
    /// copies of the person's sign-ins, so its task moves to the default profile, which first takes the sites such a
    /// profile has cookies of and it has none of (`fill`: the keys to empty, answering the keys whose sites it could
    /// not take, which stay their tasks' own, or nil to try again at the next start). Their folders go to `setAside`
    /// (a folder in the Trash), so the person can take one back; a folder that does not move is tried again at the
    /// next start. Nil when nothing was sorted.
    @discardableResult
    func shareEarlierProfiles(setAside: URL, fill: ([String]) -> Set<String>?) -> (kept: Int, moved: Int)? {
        guard saved.sorted != true else { return nil }
        let earlierOwn = Set((saved.following?.own ?? [:]).filter { !$0.value.isEmpty }.keys)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        let keys = names.filter { $0.hasPrefix(Self.folderPrefix) }.map { String($0.dropFirst(Self.folderPrefix.count)) }
            .filter { UUID(uuidString: $0) != nil }
        let emptied = keys.filter { !earlierOwn.contains($0) && saved.own?[$0] == nil }.sorted()
        guard let unreadable = emptied.isEmpty ? [] : fill(emptied) else { return nil }
        let moving = emptied.filter { !unreadable.contains($0) }
        if !moving.isEmpty {
            try? FileManager.default.createDirectory(at: setAside, withIntermediateDirectories: true)
            // A move within the home is one rename, however much the profile holds.
            let unmoved = moving.filter { key in
                (try? FileManager.default.moveItem(at: folder(for: key), to: setAside.appending(path: Self.folderPrefix + key))) == nil
            }
            guard unmoved.isEmpty else { return nil }
        }
        var own = saved.own ?? [:]
        for key in earlierOwn.union(unreadable) where folderExists(key) { own[key] = own[key] ?? "" }
        saved.own = own
        saved.following = nil
        saved.sorted = true
        save()
        return (keys.count - moving.count, moving.count)
    }

#if DEBUG
    /// QA: the state before tasks shared the default profile, with the profiles of their own now as earlier profiles
    /// that had signed in to a site themselves, except `emptying`, which held copies of the person's sign-ins only.
    func restoreEarlierProfiles(emptying: Set<String>) {
        let own = Set((saved.own ?? [:]).keys).subtracting(emptying)
        saved.following = Earlier(own: Dictionary(uniqueKeysWithValues: own.map { ($0, ["qa.test"]) }))
        saved.own = nil
        saved.sorted = nil
        save()
    }
#endif

    /// Removes the profile folders no kept task uses (archived and deleted tasks, a task that uses the default
    /// profile). Only while the host is not running, which holds the folders open.
    ///
    /// Each folder is moved out of the profiles at once and deleted off the main thread: deleting a profile
    /// with a large cache took seconds, and the host ends, which removes them, as the app quits. What a quit
    /// cut short is deleted at the next removal.
    @discardableResult
    func removeFolders(keeping tasks: Set<UUID>) -> [String] {
        let keys = Set(tasks.map(key(for:)))
        let kept = keys.filter(isOwn)
        saved.aliases = saved.aliases.filter { tasks.contains(UUID(uuidString: $0.key) ?? UUID()) }
        saved.own = saved.own?.filter { keys.contains($0.key) }
        saved.sharedChildren = saved.sharedChildren?.intersection(keys)
        save()
        // Only task profiles: the root cache also holds the default profile and Chromium's own folders.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        let removing = root.appending(path: Self.removingFolderName, directoryHint: .isDirectory)
        var removed: [String] = []
        for name in names where name.hasPrefix(Self.folderPrefix) {
            let key = String(name.dropFirst(Self.folderPrefix.count))
            guard UUID(uuidString: key) != nil, !kept.contains(key) else { continue }
            try? FileManager.default.createDirectory(at: removing, withIntermediateDirectories: true)
            // A move within the root cache is one rename, however much the profile holds.
            if (try? FileManager.default.moveItem(at: folder(for: key), to: removing.appending(path: UUID().uuidString))) != nil {
                removed.append(key)
            }
        }
        forgetMissingProfiles()
        Self.deleteRemovedFolders(in: removing)
        return removed
    }

    private nonisolated static func deleteRemovedFolders(in removing: URL) {
        deleting.async {
            let manager = FileManager.default
            let path = removing.path(percentEncoded: false)
            for name in (try? manager.contentsOfDirectory(atPath: path)) ?? [] {
                try? manager.removeItem(at: removing.appending(path: name))
            }
            // A folder moved in meanwhile waits for its own deletion, which comes next.
            if (try? manager.contentsOfDirectory(atPath: path))?.isEmpty == true { try? manager.removeItem(atPath: path) }
        }
    }

    /// Chromium lists every profile it opened in the root cache's `Local State` (`profile.info_cache`,
    /// `profile.profiles_order`, `variations_google_groups`) and keeps a profile there after its folder is
    /// gone; task profiles without a folder leave it too, so removed tasks leave nothing behind.
    private func forgetMissingProfiles() {
        let file = root.appending(path: "Local State")
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var changed = false
        func missing(_ name: String) -> Bool {
            guard name.hasPrefix(Self.folderPrefix), UUID(uuidString: String(name.dropFirst(Self.folderPrefix.count))) != nil
            else { return false }
            return !FileManager.default.fileExists(atPath: root.appending(path: name).path(percentEncoded: false))
        }
        func prune(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                let kept = dictionary.filter { !missing($0.key) }
                if kept.count != dictionary.count { changed = true }
                return kept.mapValues(prune)
            }
            if let array = value as? [Any] {
                let kept = array.filter { !(($0 as? String).map(missing) ?? false) }
                if kept.count != array.count { changed = true }
                return kept.map(prune)
            }
            return value
        }
        let pruned = prune(state)
        guard changed, let output = try? JSONSerialization.data(withJSONObject: pruned) else { return }
        try? output.write(to: file, options: .atomic)
    }

    /// Encoded and written on `StateFileWriter`'s queue: a child task's first tab saves, and an agent opens tabs
    /// while the main thread must not wait for the disk.
    private func save() {
        let saved = saved, file = root.appending(path: Self.savedFile)
        StateFileWriter.shared.write(file) { try StateFile.write(JSONEncoder().encode(saved), to: file) }
    }
}
