import Foundation

/// One file or folder a composer `@` mention can point at, inside one of the task's roots.
struct WorkspaceFileMatch: Equatable, Identifiable, Sendable {
    let root: URL
    let relativePath: String
    let isDirectory: Bool

    var id: String { url.path(percentEncoded: false) }
    var url: URL {
        root.appending(path: relativePath, directoryHint: isDirectory ? .isDirectory : .notDirectory)
            .standardizedFileURL
    }
    var name: String { String(relativePath.split(separator: "/").last ?? Substring(relativePath)) }
    /// The folder part shown beside the name; empty for an entry at the root.
    var folder: String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }
}

struct WorkspaceFileSearchResult: Equatable, Sendable {
    var matches: [WorkspaceFileMatch] = []
    /// No root could be listed at all, so an empty list is not an answer.
    var failed = false
}

/// The files of one root, as relative paths. Git's own view of the work tree comes first so
/// ignored output stays out; any other folder gets a bounded walk that skips dependency and
/// build folders. Both are capped, so a home folder or a huge monorepo cannot stall a mention.
enum WorkspaceFileListing {
    static let fileLimit = 30_000
    private static let walkVisitLimit = 100_000
    private static let gitOutputLimit = 8 * 1_048_576
    static let skippedDirectories: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".build", "build", "dist", "DerivedData",
        ".next", ".venv", "venv", "__pycache__", ".swiftpm", "Pods", "target"
    ]

    static func files(in root: URL) -> [String]? {
        gitFiles(in: root) ?? walkedFiles(in: root)
    }

    static func gitFiles(
        in root: URL,
        executableURL: URL = GitExecutableLocator.preferredURL(),
        timeout: TimeInterval = 3
    ) -> [String]? {
        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = root.standardizedFileURL
        process.arguments = ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        // Listing must never take the index lock from a harness or the user's own Git.
        process.environment = GitExecutableLocator.environment(for: executableURL, overrides: ["GIT_OPTIONAL_LOCKS": "0"])
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exit: ProcessExit
        do { exit = try ProcessExit(running: process) } catch { return nil }
        // Apple's Git can block while resolving a folder outside the app's file access.
        let watchdog = DispatchWorkItem { if process.isRunning { NativeProcessTree.terminate(process: process) } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        var data = Data()
        let reader = output.fileHandleForReading
        while data.count < gitOutputLimit, let chunk = try? reader.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
        }
        let isTruncated = data.count >= gitOutputLimit
        if isTruncated, process.isRunning { process.terminate() }
        let ended = exit.waitBlockingThread(timeout: .seconds(timeout + 2))
        guard isTruncated || (ended && process.terminationReason == .exit && process.terminationStatus == 0) else { return nil }
        var entries = data.split(separator: 0, omittingEmptySubsequences: true)
        if isTruncated, data.last != 0 { entries.removeLast() }
        return entries.prefix(fileLimit).map { String(decoding: $0, as: UTF8.self) }
    }

    static func walkedFiles(in root: URL, limit: Int = fileLimit) -> [String]? {
        let root = root.standardizedFileURL
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        guard (try? root.resourceValues(forKeys: keys))?.isDirectory == true,
              let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants], errorHandler: { _, _ in true }
              ) else { return nil }
        var files: [String] = []
        var visited = 0
        while let url = enumerator.nextObject() as? URL, files.count < limit {
            visited += 1
            guard visited <= walkVisitLimit else { break }
            if (try? url.resourceValues(forKeys: keys))?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard let path = PathRules.current.relativePath(of: url.standardizedFileURL, in: root), !path.isEmpty else { continue }
            files.append(path)
        }
        return files
    }
}

/// Ranks listed paths for a typed query. A match in the file name beats one only in its folders,
/// a contiguous match beats a scattered one, and shallower, shorter paths break ties.
enum WorkspaceFileRanking {
    struct Entry: Sendable {
        let relativePath: String
        let isDirectory: Bool
        /// The lowercased, precomposed path as UTF-8. Typed Hangul is precomposed while a file
        /// system may keep names decomposed, so both sides are normalized once, up front, and
        /// every keystroke then compares bytes.
        let key: [UInt8]
        let nameStart: Int
        /// Where the name's extension starts; the name's end when it has none.
        let stemEnd: Int
        let depth: Int

        init(relativePath: String, isDirectory: Bool) {
            self.relativePath = relativePath
            self.isDirectory = isDirectory
            let key = Array(WorkspaceFileRanking.normalized(relativePath).utf8)
            self.key = key
            nameStart = (key.lastIndex(of: slash) ?? -1) + 1
            stemEnd = key[nameStart...].lastIndex(of: dot) ?? key.count
            depth = key.reduce(0) { $1 == slash ? $0 + 1 : $0 }
        }
    }

    private struct Query {
        let bytes: [UInt8]
        let scalars: [Unicode.Scalar]
        let hasSlash: Bool
        let isASCII: Bool

        init(_ normalized: String) {
            bytes = Array(normalized.utf8)
            scalars = Array(normalized.unicodeScalars)
            hasSlash = bytes.contains(slash)
            isASCII = bytes.allSatisfy { $0 < 0x80 }
        }
    }

    private static let slash = UInt8(ascii: "/"), dot = UInt8(ascii: ".")

    static func normalized(_ value: String) -> String {
        value.lowercased().precomposedStringWithCanonicalMapping
    }

    /// Files plus the folders that contain them, so a folder can be mentioned as well.
    static func entries(forFiles paths: [String]) -> [Entry] {
        var folders = Set<String>()
        var entries: [Entry] = []
        entries.reserveCapacity(paths.count)
        for path in paths {
            entries.append(Entry(relativePath: path, isDirectory: false))
            var folder = Substring(path)
            while let slash = folder.lastIndex(of: "/") {
                folder = folder[..<slash]
                guard !folder.isEmpty, folders.insert(String(folder)).inserted else { break }
            }
        }
        entries += folders.map { Entry(relativePath: $0, isDirectory: true) }
        return entries
    }

    static func rank(_ entries: [Entry], query: String, limit: Int) -> [Entry] {
        let query = Query(normalized(query))
        guard !query.bytes.isEmpty, limit > 0 else { return [] }
        // Collect by tier. Once the better tiers already hold `limit` entries, worse tiers can no
        // longer show, so their costlier checks are skipped for the rest of the listing.
        var tiers = Array(repeating: [(entry: Entry, spread: Int)](), count: tierCount)
        var worstShown = tierCount - 1
        for (index, entry) in entries.enumerated() {
            if index % 4096 == 0, Task.isCancelled { return [] }
            guard let (tier, spread) = score(entry, query, worstTier: worstShown) else { continue }
            tiers[tier].append((entry, spread))
            while worstShown > tier, tiers[0..<worstShown].reduce(0, { $0 + $1.count }) >= limit {
                worstShown -= 1
            }
        }
        var ranked: [Entry] = []
        for tier in tiers[0...worstShown] where ranked.count < limit {
            ranked += tier.sorted { l, r in
                if l.spread != r.spread { return l.spread < r.spread }
                if l.entry.isDirectory != r.entry.isDirectory { return !l.entry.isDirectory }
                if l.entry.depth != r.entry.depth { return l.entry.depth < r.entry.depth }
                if l.entry.key.count != r.entry.key.count { return l.entry.key.count < r.entry.key.count }
                return l.entry.relativePath < r.entry.relativePath
            }
            .prefix(limit - ranked.count)
            .map(\.entry)
        }
        return ranked
    }

    private static let tierCount = 7

    /// Lower is better; `nil` means no match at `worstTier` or better.
    private static func score(_ entry: Entry, _ query: Query, worstTier: Int) -> (tier: Int, spread: Int)? {
        entry.key.withUnsafeBufferPointer { key in
            query.bytes.withUnsafeBufferPointer { needle in
                let name = entry.nameStart
                if !query.hasSlash {
                    if key.count - name == needle.count && occurs(needle, in: key, at: name)
                        || entry.stemEnd - name == needle.count && occurs(needle, in: key, at: name) { return (0, 0) }
                    guard worstTier >= 1 else { return nil }
                    if occurs(needle, in: key, at: name) { return (1, 0) }
                    guard worstTier >= 2 else { return nil }
                    if find(needle, in: key, from: name) { return (2, 0) }
                }
                guard worstTier >= 3 else { return nil }
                if find(needle, in: key, from: 0) { return (3, 0) }
                guard worstTier >= 4 else { return nil }
                if !query.hasSlash, let spread = spread(of: query, in: key, from: name) {
                    let tier = matchesInitials(query, in: entry) ? 4 : 5
                    // A folder is offered for its name, not for letters scattered through it.
                    return tier <= worstTier && (tier == 4 || !entry.isDirectory) ? (tier, spread) : nil
                }
                guard worstTier >= 6, !entry.isDirectory else { return nil }
                return spread(of: query, in: key, from: 0).map { (6, $0) }
            }
        }
    }

    private static func occurs(_ needle: UnsafeBufferPointer<UInt8>, in key: UnsafeBufferPointer<UInt8>, at start: Int) -> Bool {
        guard start + needle.count <= key.count else { return false }
        var offset = 0
        while offset < needle.count {
            if key[start + offset] != needle[offset] { return false }
            offset += 1
        }
        return true
    }

    private static func find(_ needle: UnsafeBufferPointer<UInt8>, in key: UnsafeBufferPointer<UInt8>, from start: Int) -> Bool {
        var index = start
        while index + needle.count <= key.count {
            if occurs(needle, in: key, at: index) { return true }
            index += 1
        }
        return false
    }

    /// How far apart the query's characters land when matched in order, or nil when they do not.
    /// An ASCII query never matches inside a multi-byte character, so it can walk bytes.
    private static func spread(of query: Query, in key: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var wanted = 0, first = -1
        if query.isASCII {
            var index = start
            while index < key.count {
                if key[index] == query.bytes[wanted] {
                    if first < 0 { first = index }
                    wanted += 1
                    if wanted == query.bytes.count { return index - first }
                }
                index += 1
            }
            return nil
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: key[start...]), as: UTF8.self)
        for (offset, scalar) in text.unicodeScalars.enumerated() where scalar == query.scalars[wanted] {
            if first < 0 { first = offset }
            wanted += 1
            if wanted == query.scalars.count { return offset - first }
        }
        return nil
    }

    /// Whether the query lands on word starts of the file name, in order: the initials of
    /// `SessionTranscriptView` or `session_transcript_view`.
    private static func matchesInitials(_ query: Query, in entry: Entry) -> Bool {
        guard query.isASCII else { return false }
        let name = entry.relativePath.utf8.split(separator: slash, omittingEmptySubsequences: false).last ?? []
        let separators: Set<UInt8> = [dot, UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: " ")]
        func isLower(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z") }
        func isUpper(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") }
        var wanted = 0
        var previous: UInt8?
        for byte in name {
            let startsWord = previous.map { previous in
                separators.contains(byte) || separators.contains(previous) || (isLower(previous) && isUpper(byte))
            } ?? true
            let folded = isUpper(byte) ? byte + 32 : byte
            if startsWord, folded == query.bytes[wanted] {
                wanted += 1
                if wanted == query.bytes.count { return true }
            }
            previous = byte
        }
        return false
    }
}

/// Lists each root once per short window and ranks off the main thread. A burst of keystrokes
/// shares one listing; a file created a moment ago appears once the listing expires.
actor WorkspaceFileSearchIndex {
    static let shared = WorkspaceFileSearchIndex()

    private struct Listing {
        let entries: [WorkspaceFileRanking.Entry]
        let failed: Bool
        let loadedAt: ContinuousClock.Instant
    }

    private let lifetime: Duration
    private let list: @Sendable (URL) -> [String]?
    private var listings: [String: Listing] = [:]
    private var loads: [String: Task<Listing, Never>] = [:]

    init(
        lifetime: Duration = .seconds(15),
        list: @escaping @Sendable (URL) -> [String]? = WorkspaceFileListing.files(in:)
    ) {
        self.lifetime = lifetime
        self.list = list
    }

    func search(_ query: String, in roots: [URL], limit: Int = 50) async -> WorkspaceFileSearchResult {
        var seen = Set<String>()
        var ranked: [(root: URL, entries: [WorkspaceFileRanking.Entry])] = []
        var failures = 0
        for root in roots.map(\.standardizedFileURL) where seen.insert(root.path(percentEncoded: false)).inserted {
            let listing = await listing(for: root)
            if listing.failed { failures += 1 }
            ranked.append((root, WorkspaceFileRanking.rank(listing.entries, query: query, limit: limit)))
        }
        guard !Task.isCancelled else { return .init() }
        // Each root is already ranked; interleave by rank so one root cannot crowd out another's
        // best match, and drop a path a nested root lists twice.
        var matches: [WorkspaceFileMatch] = []
        var paths = Set<String>()
        for position in 0..<(ranked.map(\.entries.count).max() ?? 0) {
            for (root, entries) in ranked where position < entries.count {
                let match = WorkspaceFileMatch(
                    root: root, relativePath: entries[position].relativePath,
                    isDirectory: entries[position].isDirectory
                )
                if paths.insert(match.id).inserted { matches.append(match) }
            }
        }
        return .init(matches: Array(matches.prefix(limit)), failed: !roots.isEmpty && failures == ranked.count)
    }

    private func listing(for root: URL) async -> Listing {
        let key = root.path(percentEncoded: false)
        discardExpiredListings()
        if let cached = listings[key] { return cached }
        if let load = loads[key] { return await load.value }
        let list = list
        let load = Task.detached(priority: .userInitiated) { () -> Listing in
            let paths = list(root)
            return Listing(
                entries: WorkspaceFileRanking.entries(forFiles: paths ?? []),
                failed: paths == nil, loadedAt: .now
            )
        }
        loads[key] = load
        let listing = await load.value
        loads[key] = nil
        listings[key] = listing
        // Do not keep a large listing around after the reader stops mentioning files.
        let lifetime = lifetime
        Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            await self?.discardExpiredListings()
        }
        return listing
    }

    private func discardExpiredListings() {
        let now = ContinuousClock.now
        listings = listings.filter { now - $0.value.loadedAt < lifetime }
    }
}
