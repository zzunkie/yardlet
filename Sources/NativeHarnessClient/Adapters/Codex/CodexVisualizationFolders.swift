import Foundation

/// The folder the Codex app gives each thread for the visualizations its model writes (docs/CONVERSATION_MEDIA.md,
/// "Codex visualizations"): `<Codex home>/visualizations/YYYY/MM/DD/<thread>`, dated in UTC by the time in the
/// thread's UUIDv7 ID. A turn that may write gets it among its workspace roots, made as the turn starts, as the app
/// does. Unlike the app, Yardlet takes away a folder its turn made and left empty, and lists the ones it made in its own
/// state, so that deleting the thread (`thread/delete`) takes away only those: never a folder the Codex app or another
/// client made, and nothing when a thread is archived or only leaves Yardlet's list.
struct CodexVisualizationFolders: Sendable {
    let codexHome: URL
    /// The folders Yardlet made, one path a line.
    let listURL: URL

    init(codexHome: URL, listURL: URL) {
        self.codexHome = codexHome.standardizedFileURL
        self.listURL = listURL
    }

    /// For the App Server an adapter starts: the Codex home it runs with and Yardlet's state beside the harness.
    init(paths: CodexEnvironmentPaths, scope: SessionEnvironmentScope) {
        self.init(codexHome: scope == .native ? paths.nativeHomeURL : paths.runtimeHomeURL,
                  listURL: paths.harnessRootURL.appending(path: "visualization-folders.txt"))
    }

    /// One adapter per account and scope writes the shared list.
    private static let lock = NSLock()

    /// The thread's folder, or nil for an ID that is not a UUIDv7 (the app gives such a thread none).
    func folder(threadID: String) -> URL? {
        guard let date = Self.date(threadID: threadID) else { return nil }
        return codexHome.appending(path: "visualizations", directoryHint: .isDirectory)
            .appending(path: date, directoryHint: .isDirectory)
            .appending(path: threadID, directoryHint: .isDirectory)
    }

    /// `YYYY/MM/DD` in UTC of the millisecond time a UUIDv7 starts with.
    static func date(threadID: String) -> String? {
        let hex = threadID.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit), hex[hex.index(hex.startIndex, offsetBy: 12)] == "7",
              let milliseconds = UInt64(hex.prefix(12), radix: 16) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day],
                                            from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d/%02d/%02d", year, month, day)
    }

    /// Makes the thread's folder for a turn that starts, as the app does on every turn. Returns it with the folders this
    /// made, the outermost first, or nil when it cannot be made, and the turn goes without it.
    func prepare(threadID: String) -> (folder: URL, made: [URL])? {
        guard let folder = folder(threadID: threadID) else { return nil }
        let manager = FileManager.default
        var missing: [URL] = []
        var place = folder
        while !manager.fileExists(atPath: place.nativePath), place.path(percentEncoded: false) != codexHome.path(percentEncoded: false) {
            missing.insert(place, at: 0)
            place = place.deletingLastPathComponent()
        }
        guard manager.fileExists(atPath: codexHome.nativePath), !isLinked(folder) else { return nil }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        if missing.contains(folder) { list(add: folder) }
        return (folder, missing)
    }

    /// After the turn: what it made and left empty goes, the innermost first; the thread's folder stays listed only
    /// while it is there.
    func finish(made: [URL]) {
        let manager = FileManager.default
        for folder in made.reversed() {
            guard (try? manager.contentsOfDirectory(atPath: folder.nativePath))?.isEmpty == true else { break }
            try? manager.removeItem(at: folder)
        }
        if let thread = made.last, !manager.fileExists(atPath: thread.nativePath) { list(remove: thread) }
    }

    /// After `thread/delete`: the thread's folder goes, with what the model wrote in it, if Yardlet made it.
    func remove(threadID: String) {
        guard let folder = folder(threadID: threadID), listed(folder) else { return }
        if !isLinked(folder) { try? FileManager.default.removeItem(at: folder) }
        list(remove: folder)
    }

    /// Whether the folder or a folder on its way down from the Codex home is a link, which is never followed.
    private func isLinked(_ folder: URL) -> Bool {
        var place = folder
        let home = codexHome.path(percentEncoded: false)
        while place.path(percentEncoded: false).count > home.count {
            if (try? place.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return true }
            place = place.deletingLastPathComponent()
        }
        return false
    }

    private func listed(_ folder: URL) -> Bool {
        Self.lock.withLock { readList().contains(folder.nativePath) }
    }

    private func list(add folder: URL) {
        Self.lock.withLock {
            var paths = readList()
            guard !paths.contains(folder.nativePath) else { return }
            paths.append(folder.nativePath)
            writeList(paths)
        }
    }

    private func list(remove folder: URL) {
        Self.lock.withLock {
            let paths = readList()
            guard paths.contains(folder.nativePath) else { return }
            writeList(paths.filter { $0 != folder.nativePath })
        }
    }

    private func readList() -> [String] {
        guard let text = try? String(contentsOf: listURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private func writeList(_ paths: [String]) {
        let manager = FileManager.default
        if paths.isEmpty {
            try? manager.removeItem(at: listURL)
            return
        }
        try? manager.createDirectory(at: listURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (paths.joined(separator: "\n") + "\n").write(to: listURL, atomically: true, encoding: .utf8)
    }
}
