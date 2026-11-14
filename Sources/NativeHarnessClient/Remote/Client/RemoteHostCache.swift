import Foundation
import YardletRemote

/// What a host's window last showed, kept on this Mac so that reopening the window shows the host's list and
/// the conversations open last at once, before it connects (docs/REMOTE_PROTOCOL.md §18, "What stays on the
/// client"). Each host has a folder of its own (0700) in the app's caches: `list.json` with what the sidebar
/// shows, and a file for each conversation open last, at most `RemoteHostModel.keptSubscriptions`, each
/// its latest page as the host would send it (files 0600). The host's own list and pages replace them once
/// the window connects. Removing the host removes its folder, and a folder whose host is no longer saved
/// goes when the app next starts.
///
/// What it writes is gathered on the main actor once the window has been quiet for `quiet` (or after
/// `longestWait` of steady changes) and when it closes, then encoded and written on a queue of its own: the
/// list when it changed, a conversation only when it changed, and of a long one only its latest page.
@MainActor
final class RemoteHostCache {
    struct List: Codable, Equatable, Sendable {
        var projects: [RemoteProject] = []
        var tasks: [RemoteTask] = []
        var newTask: RemoteNewTask?
        var followUp: RemoteFollowUpMode?
        /// The conversations kept, the one shown longest ago first.
        var conversations: [String] = []
    }

    struct Page: Codable, Equatable, Sendable {
        var taskID: String
        var items: [RemoteItem]
        var cursor: String?
        var hasOlder: Bool
    }

    nonisolated let folder: URL
    private let quiet: Duration
    private let longestWait: Duration
    private let limits = RemoteConversationWindow.Limits()
    private weak var model: RemoteHostModel?
    /// Pages read from disk whose conversations were not opened since.
    private var saved: [String: Page] = [:]
    /// What the folder holds now, as last written or read.
    private var written: List?
    private var writtenRevisions: [String: Int] = [:]
    private var isRead = false
    private var isClosed = false
    private var pending: Task<Void, Never>?
    private var firstChange: ContinuousClock.Instant?
    private var lastChange: ContinuousClock.Instant?

    /// Reads, writes and removals, in the order they were asked for.
    nonisolated static let disk = DispatchQueue(label: "yardlet.remote.host-cache", qos: .utility)
    private nonisolated static let listName = "list.json"

    init(folder: URL, quiet: Duration = .seconds(1.5), longestWait: Duration = .seconds(10)) {
        self.folder = folder
        self.quiet = quiet
        self.longestWait = longestWait
    }

    /// A host's folder under `root`; nil for an ID that is not a plain folder name.
    nonisolated static func folder(in root: URL, hostID: String) -> URL? {
        guard !hostID.isEmpty, hostID != ".", hostID != "..", !hostID.contains("/") else { return nil }
        return root.appending(path: hostID, directoryHint: .isDirectory)
    }

    // MARK: - The window's side

    /// Reads what the folder holds, off the main thread, and shows it in `model` unless the host's own list
    /// arrived first.
    func open(for model: RemoteHostModel) {
        self.model = model
        let folder = folder
        Task { [weak self] in
            let read = await withCheckedContinuation { continuation in
                Self.disk.async { continuation.resume(returning: Self.read(folder)) }
            }
            self?.restore(read)
        }
    }

    private func restore(_ read: (list: List, pages: [String: Page])?) {
        guard !isClosed else { return }
        adopt(read)
        guard let read, let model else { return }
        model.showCached(read.list)
        for (taskID, conversation) in model.conversations where !conversation.isLoaded {
            show(taskID, in: conversation)
        }
    }

    /// What the folder holds, which a write keeps beside what the window shows.
    private func adopt(_ read: (list: List, pages: [String: Page])?) {
        isRead = true
        guard let read else { return }
        written = read.list
        saved = read.pages
        writtenRevisions = [:]
    }

    /// A conversation the window just opened: its saved page, until the host's own arrives.
    func show(_ taskID: String, in conversation: RemoteConversationModel) {
        guard let page = saved.removeValue(forKey: taskID) else { return }
        conversation.load(page.items, cursor: page.cursor, hasOlder: page.hasOlder)
        writtenRevisions[taskID] = conversation.revision
    }

    /// Something arrived: written once the window has been quiet for a moment.
    func changed() {
        guard !isClosed else { return }
        let now = ContinuousClock.now
        lastChange = now
        if firstChange == nil { firstChange = now }
        guard pending == nil else { return }
        pending = Task { [weak self] in
            while let wait = self?.untilDue(), wait > .zero {
                try? await Task.sleep(for: wait)
                if Task.isCancelled { return }
            }
            self?.write()
        }
    }

    /// The window closed: what changed is written now, and nothing after. A window closed before the folder's first read
    /// came back waits for it here, or what it showed would be lost or would replace what the folder holds.
    func close() {
        guard !isClosed else { return }
        if !isRead { adopt(Self.disk.sync { [folder] in Self.read(folder) }) }
        write()
        isClosed = true
        model = nil
    }

    private func untilDue() -> Duration? {
        guard let firstChange, let lastChange else { return nil }
        return min(lastChange + quiet, firstChange + longestWait) - .now
    }

    /// Gathers what changed since the last write and hands it to the disk queue.
    private func write() {
        pending?.cancel()
        pending = nil
        firstChange = nil
        lastChange = nil
        guard isRead, let model else { return }
        let open = model.conversations.filter { $0.value.isLoaded }
        let previous = written?.conversations ?? []
        var kept = previous.filter { saved[$0] != nil && open[$0] == nil } + open.keys.sorted()
        var list = written ?? List()
        if model.hasSnapshot {
            let listed = Set(model.tasks.map(\.id))
            kept = kept.filter(listed.contains)
            list.projects = model.projects
            list.tasks = model.tasks
            list.newTask = model.newTask
            list.followUp = model.followUp
        }
        list.conversations = Array(kept.suffix(RemoteHostModel.keptSubscriptions))
        guard written != nil || model.hasSnapshot || !list.conversations.isEmpty else { return }

        var pages: [Page] = []
        for taskID in list.conversations {
            guard let conversation = open[taskID], writtenRevisions[taskID] != conversation.revision else { continue }
            let latest = conversation.latestItems(within: limits)
            // Cut short, the host's cursor names an earlier start than the page kept: it reads no further back.
            pages.append(Page(taskID: taskID, items: latest.items, cursor: latest.isWhole ? conversation.cursor : nil,
                              hasOlder: conversation.hasOlder || !latest.isWhole))
            writtenRevisions[taskID] = conversation.revision
        }
        let gone = Set(previous).subtracting(list.conversations)
        for taskID in gone {
            writtenRevisions[taskID] = nil
            saved[taskID] = nil
        }
        let changedList = list != written ? list : nil
        guard changedList != nil || !pages.isEmpty || !gone.isEmpty else { return }
        written = list
        Self.disk.async { [folder, pages] in Self.store(changedList, pages: pages, removing: gone, in: folder) }
    }

    // MARK: - Disk

    private nonisolated static func file(for taskID: String, in folder: URL) -> URL {
        folder.appending(path: "conversation-\(RemoteEncoding.base64url(Data(taskID.utf8))).json")
    }

    private nonisolated static func read(_ folder: URL) -> (list: List, pages: [String: Page])? {
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: folder.appending(path: listName)),
              let list = try? decoder.decode(List.self, from: data) else { return nil }
        var pages: [String: Page] = [:]
        for taskID in list.conversations {
            if let data = try? Data(contentsOf: file(for: taskID, in: folder)),
               let page = try? decoder.decode(Page.self, from: data), page.taskID == taskID {
                pages[taskID] = page
            }
        }
        return (list, pages)
    }

    private nonisolated static func store(_ list: List?, pages: [Page], removing gone: Set<String>, in folder: URL) {
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path(percentEncoded: false))
        let encoder = JSONEncoder()
        func put(_ data: Data?, at url: URL) {
            guard let data else { return }
            try? StateFile.write(data, to: url, isPrivate: true)
        }
        for page in pages { put(try? encoder.encode(page), at: file(for: page.taskID, in: folder)) }
        for taskID in gone { try? files.removeItem(at: file(for: taskID, in: folder)) }
        // The list last, so it never names a page not yet written.
        if let list { put(try? encoder.encode(list), at: folder.appending(path: listName)) }
    }

    /// Removes a host's folder, after whatever was asked of the disk before (the window's unsaved Files edits included,
    /// handed to `StateFileWriter`), and the folder of all hosts with its last host.
    nonisolated static func remove(_ folder: URL) {
        disk.async {
            StateFileWriter.shared.flush()
            try? FileManager.default.removeItem(at: folder)
            removeIfEmpty(folder.deletingLastPathComponent())
        }
    }

    /// Removes the folders under `root` of hosts no longer saved.
    nonisolated static func removeAll(in root: URL, except hostIDs: Set<String>) {
        disk.async {
            let files = FileManager.default
            guard let names = try? files.contentsOfDirectory(atPath: root.path(percentEncoded: false)) else { return }
            for name in names where !hostIDs.contains(name) {
                try? files.removeItem(at: root.appending(path: name))
            }
            removeIfEmpty(root)
        }
    }

    private nonisolated static func removeIfEmpty(_ folder: URL) {
        let path = folder.path(percentEncoded: false)
        if (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
