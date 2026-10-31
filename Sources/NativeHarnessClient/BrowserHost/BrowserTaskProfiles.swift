import Foundation

/// Which browser profile each task's tabs use (docs/BROWSER_SESSION_ISOLATION.md). With per-task storage,
/// the default, a task's tabs share a profile of its own (cookies, local and session storage, IndexedDB,
/// cache) in a folder the host keeps next to the default profile, `<root cache>/Task-<key>` (Chromium
/// opens a profile on disk only in a direct child of its root cache); the vault's sign-ins stay shared.
/// A new folder starts with the cookies of the task's parent, if it has a folder, else of the default
/// profile. With shared storage every tab uses the default profile, as before.
///
/// Tasks follow the person's sign-ins (section 11): each site the person signs in to in a task's panel counts
/// a sign-in, which the default profile and the tasks open then take in place of their cookies of that site,
/// and every other task when its tab next opens. A site the task signed in to itself (its agent, or the person
/// for it) stays the task's and follows nothing.
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

    static let storageKey = "Yardlet.browser.cookieStorage"

    /// The browser's root cache, where Chromium keeps the default profile and its own folders too.
    let root: URL
    /// A task profile's folder name is this and its key (the host's `TaskProfiles` names it the same).
    nonisolated static let folderPrefix = "Task-"
    /// The folder in the root cache that removed profiles go to, to be deleted off the main thread (`removeFolders`).
    nonisolated static let removingFolderName = "Removed task profiles"
    private nonisolated static let deleting = DispatchQueue(label: "Yardlet.browser.removed-profiles", qos: .utility)
    private static let savedFile = "TaskProfiles.json"
    private let defaults: UserDefaults
    /// The task a task was started from (`create_task`): a new task's profile starts from its parent's.
    var parentOf: @MainActor (UUID) -> UUID? = { _ in nil }

    /// Saved in the root cache: tasks whose profile has another key (they took over the new-task
    /// screen's tabs), the key the new-task screen uses now, and the sign-ins tasks follow.
    private struct Saved: Codable {
        var aliases: [String: String] = [:]
        var draftKey: String?
        var following: Following?
    }

    /// The person's sign-ins and which of them each profile holds, by profile key.
    struct Following: Codable, Equatable {
        /// Each site's count of the person's sign-ins since tasks began following them.
        var signIns: [String: Int] = [:]
        /// The sign-in of each site a profile holds; a site it has none of holds 0.
        var received: [String: [String: Int]] = [:]
        /// The profiles that started following: made since, or filled once from the default profile. Any other
        /// predates following and has not opened since.
        var followers: Set<String> = []
        /// The sites each profile signed in to itself.
        var own: [String: Set<String>] = [:]
        /// The agents' earlier password manager fills were read into `own`, once.
        var readAgentFills = false
    }
    private var saved: Saved

    var following: Following {
        get { saved.following ?? Following() }
        set { saved.following = newValue }
    }

    init(root: URL, defaults: UserDefaults = .yardlet) {
        self.root = root
        self.defaults = defaults
        saved = (try? Data(contentsOf: root.appending(path: Self.savedFile)))
            .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    var storage: Storage {
        get { defaults.string(forKey: Self.storageKey).flatMap(Storage.init(rawValue:)) ?? .perTask }
        set { defaults.set(newValue.rawValue, forKey: Self.storageKey) }
    }

    /// The folder key of a task's profile.
    func key(for session: UUID) -> String {
        if session == TaskWorkspaceStore.draftID { return draftKey }
        return saved.aliases[session.uuidString] ?? session.uuidString
    }

    /// The new-task screen's own key; a task that takes over its tabs takes the key with them.
    private var draftKey: String {
        if let key = saved.draftKey { return key }
        let key = UUID().uuidString
        saved.draftKey = key
        save()
        return key
    }

    func folder(for key: String) -> URL {
        root.appending(path: Self.folderPrefix + key, directoryHint: .isDirectory)
    }

    func folderExists(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(for: key).path(percentEncoded: false))
    }

    /// The profile a task's tabs use; nil for the default profile (shared storage).
    func profile(for session: UUID) -> BrowserTabProfile? {
        guard storage == .perTask else { return nil }
        let key = key(for: session)
        var seed: String?
        if !folderExists(key), let parent = parentOf(session) {
            let parentKey = self.key(for: parent)
            if folderExists(parentKey) { seed = parentKey }
        }
        return BrowserTabProfile(key: key, seedFrom: seed)
    }

    /// What a tab of the task opens in, with the cookies it takes first: a new folder its seed's, then the person's
    /// sign-ins it follows and has not yet; a folder that predates following, once, the default profile's sites it
    /// has none of. From then on the profile counts as holding them.
    func opening(for session: UUID) -> BrowserTabProfile? {
        guard var profile = profile(for: session) else { return nil }
        let key = profile.key
        var following = following
        if !folderExists(key) {
            // The new folder holds what its seed holds: the default profile every sign-in, a parent task its own.
            following.received[key] = profile.seedFrom.map { following.received[$0] ?? [:] } ?? following.signIns
            following.own[key] = profile.seedFrom.flatMap { following.own[$0] }
            following.followers.insert(key)
        } else if !following.followers.contains(key) {
            profile.fill = true
            following.followers.insert(key)
        }
        let own = following.own[key] ?? []
        let behind = following.signIns.filter { site, signIn in
            !own.contains(site) && signIn > following.received[key]?[site] ?? 0
        }
        if !behind.isEmpty {
            profile.follow = behind.keys.sorted()
            following.received[key, default: [:]].merge(behind) { $1 }
        }
        if following != self.following {
            self.following = following
            save()
        }
        return profile
    }

    /// The person signed in to `site` in the task whose profile is `key`: another sign-in of the site, which goes to
    /// the default profile (nil) and to each profile of `open` (tasks with tabs open) that follows the site. The
    /// profiles to copy it to; none for a site the task signed in to itself, which stays its own.
    func personSignedIn(to site: String, in key: String, open: Set<String>) -> [String?] {
        var following = following
        guard !(following.own[key]?.contains(site) ?? false) else { return [] }
        let signIn = (following.signIns[site] ?? 0) + 1
        following.signIns[site] = signIn
        following.received[key, default: [:]][site] = signIn
        var targets: [String?] = [nil]
        for other in open.sorted() where other != key && !(following.own[other]?.contains(site) ?? false) {
            following.received[other, default: [:]][site] = signIn
            targets.append(other)
        }
        self.following = following
        save()
        return targets
    }

    /// The task signed in to `site` itself (its agent, or the person when the agent handed the page over): the site
    /// stays the task's and follows none of the person's sign-ins.
    func signedInItself(to site: String, in key: String) {
        guard !(following.own[key]?.contains(site) ?? false) else { return }
        following.own[key, default: []].insert(site)
        save()
    }

    func isOwn(_ site: String, in key: String) -> Bool {
        following.own[key]?.contains(site) ?? false
    }

    /// The agents' fills from the password manager before tasks followed sign-ins, once: each task's filled
    /// sites become its own (`fills` gives each fill's task and site).
    func adoptEarlierAgentFills(_ fills: () -> [(task: UUID, site: String)]) {
        guard !following.readAgentFills else { return }
        var following = following
        following.readAgentFills = true
        for fill in fills() { following.own[key(for: fill.task), default: []].insert(fill.site) }
        self.following = following
        save()
    }

    /// Tabs went from one task to another with their pages (the new-task screen's to the task it started):
    /// a task without a profile yet takes theirs, so its other tabs open beside them.
    func tabsMoved(from source: UUID, to target: UUID) {
        guard target != TaskWorkspaceStore.draftID, saved.aliases[target.uuidString] == nil,
              !folderExists(target.uuidString) else { return }
        saved.aliases[target.uuidString] = key(for: source)
        if source == TaskWorkspaceStore.draftID { saved.draftKey = UUID().uuidString }
        save()
    }

    /// Removes the profile folders no kept task uses (archived and deleted tasks, a new-task screen's
    /// profile it no longer has). Only while the host is not running, which holds the folders open.
    ///
    /// Each folder is moved out of the profiles at once and deleted off the main thread: deleting a profile
    /// with a large cache took seconds, and the host ends, which removes them, as the app quits. What a quit
    /// cut short is deleted at the next removal.
    @discardableResult
    func removeFolders(keeping tasks: Set<UUID>) -> [String] {
        let kept = Set(tasks.map(key(for:))).union([draftKey])
        saved.aliases = saved.aliases.filter { tasks.contains(UUID(uuidString: $0.key) ?? UUID()) }
        if var following = saved.following {
            following.received = following.received.filter { kept.contains($0.key) }
            following.own = following.own.filter { kept.contains($0.key) }
            following.followers = following.followers.intersection(kept)
            saved.following = following
        }
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

    private func save() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: root.appending(path: Self.savedFile), options: .atomic)
    }
}
