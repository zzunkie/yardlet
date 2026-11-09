import Foundation

/// Counts the tokens the harnesses' own transcripts on this Mac record (Claude Code's and Codex's),
/// reading each file only past where it last stopped, and keeps the counts by day for a year in
/// `TokenUsageStore`. It hands the app a summary of the last 30 days after each read that counted
/// something. Nothing is sent anywhere; deleting its folder removes all it kept.
actor TokenUsageLedger {
    /// The folders whose transcripts are read: Claude Code's `projects` and Codex's `sessions`, one
    /// entry per folder however many account folders link to it.
    struct Roots: Equatable, Sendable {
        var claude: [URL] = []
        var codex: [URL] = []

        init(claude: [URL] = [], codex: [URL] = []) {
            self.claude = Self.unique(claude)
            self.codex = Self.unique(codex)
        }

        /// Each folder once, by its real path: the one the file system lists files and reports changes under
        /// (a temporary folder's `/private/var`, which `resolvingSymlinksInPath` would drop).
        private static func unique(_ urls: [URL]) -> [URL] {
            var seen: Set<String> = []
            return urls.map(canonical).filter { seen.insert($0.path).inserted }
        }

        static func canonical(_ url: URL) -> URL {
            CanonicalPath.resolve(url.path(percentEncoded: false))
                .map { URL(filePath: $0, directoryHint: .isDirectory) } ?? url.standardizedFileURL
        }

        var all: [URL] { claude + codex }

        func harness(of path: String) -> HarnessKind? {
            guard path.hasSuffix(".jsonl") else { return nil }
            if claude.contains(where: { PathRules.current.isStrictlyInside(path, folder: $0.path(percentEncoded: false)) }) {
                return .claudeCode
            }
            if codex.contains(where: { PathRules.current.isStrictlyInside(path, folder: $0.path(percentEncoded: false)) }),
               (path as NSString).lastPathComponent.hasPrefix("rollout-") { return .codex }
            return nil
        }
    }

    /// Whose account each provider session ran on, as the app knows it when the session's requests are
    /// read: Yardlet's tasks by their provider session, anything else on its harness's default login.
    struct Attribution: Equatable, Sendable {
        var accounts: [String: String] = [:]
        var defaults: [HarnessKind: String] = [:]

        func account(_ harness: HarnessKind, session: String) -> String {
            accounts[session] ?? defaults[harness] ?? ""
        }
    }

    /// Names the accounts of the sessions a read counted (the app's main actor answers).
    typealias Resolve = @Sendable (Set<String>) async -> Attribution

    /// A year of days is kept; the responses counted in the last two weeks are remembered so a copy in
    /// a forked conversation adds nothing.
    static let keptDays = 365
    static let seenDays = 14

    let directory: URL
    private var roots: Roots
    private let resolve: Resolve
    /// The sessions' accounts as last asked, asked again after ten minutes as a task can move.
    private var accounts: [String: (name: String, asked: Date)] = [:]
    private var defaults: [HarnessKind: String] = [:]
    private var pendingPaths: Set<String> = []
    private var needsFullScan = false
    private var isReading = false
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private var store: TokenUsageStore?
    private var files: [String: TokenUsageStore.FileState] = [:]
    private var seen: [Int64: Int64] = [:]
    private var publish: (@Sendable (TokenUsageSummary) -> Void)?
    private var prunedDay: Int?
    /// The transcript bytes read so far, for checking that a read costs what was written.
    private(set) var bytesRead: UInt64 = 0

    init(directory: URL, roots: Roots, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() },
         resolve: @escaping Resolve = { _ in Attribution() }) {
        self.directory = directory
        self.roots = roots
        self.resolve = resolve
        self.calendar = calendar
        self.now = now
    }

    var databaseURL: URL { directory.appending(path: "usage.sqlite3") }

    /// Opens the counts, reads every transcript written to since, and hands over the summary.
    func start(publish: @escaping @Sendable (TokenUsageSummary) -> Void) async {
        self.publish = publish
        do {
            let store = try TokenUsageStore(url: databaseURL)
            files = try store.fileStates()
            seen = try store.seen(since: day(daysBefore: Self.seenDays))
            self.store = store
        } catch {
            return
        }
        await scanAll()
    }

    /// Stops counting; the counts stay until the folder is removed.
    func stop() {
        store = nil
        publish = nil
        files = [:]
        seen = [:]
    }

    /// Reads every transcript of the roots modified within the kept year.
    func scanAll() async {
        needsFullScan = true
        await readPending()
    }

    /// Reads the files the watcher saw change: only what was written since the last read.
    func changed(_ paths: [String]) async {
        pendingPaths.formUnion(paths)
        await readPending()
    }

    /// Hands over the summary again, as a new day starts with nothing read yet.
    func republish() {
        prune()
        sendSummary()
    }

    /// One read at a time, so a file is never read twice from the same place: what arrives meanwhile
    /// waits for the read under way and goes next.
    private func readPending() async {
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }
        var counted = false
        while store != nil, needsFullScan || !pendingPaths.isEmpty {
            if needsFullScan {
                needsFullScan = false
                pendingPaths = []
                for slice in allFiles() { counted = await read(slice) || counted }
            } else {
                let paths = pendingPaths
                pendingPaths = []
                counted = await read(paths.compactMap { path in roots.harness(of: path).map { (path, $0) } }) || counted
            }
        }
        guard counted || summarized == nil else { return }
        prune()
        sendSummary()
    }

    /// Every transcript of the roots modified within the kept year, oldest first, in slices.
    private func allFiles() -> [[(path: String, harness: HarnessKind)]] {
        let oldest = now().addingTimeInterval(-Double(Self.keptDays) * 86_400)
        var found: [(url: URL, harness: HarnessKind, modified: Date)] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        for root in roots.all {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in enumerator {
                guard let harness = roots.harness(of: url.path),
                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= oldest else { continue }
                found.append((url, harness, modified))
            }
        }
        // Oldest first, so a forked conversation's copy comes after the original it copies.
        let ordered = found.sorted { $0.modified < $1.modified }.map { ($0.url.path, $0.harness) }
        return stride(from: 0, to: ordered.count, by: 200).map { Array(ordered[$0..<min($0 + 200, ordered.count)]) }
    }

    // MARK: Reading

    private struct Batch {
        var requests: [TokenUsageRequest] = []
        var rows: [String: TokenUsageStore.Row] = [:]
        var seen: [(hash: Int64, output: Int64, day: Int)] = []
        var files: [String: TokenUsageStore.FileState] = [:]
    }

    /// Reads the files past where each stopped, names the sessions' accounts, and records it all at once;
    /// whether anything was counted.
    private func read(_ paths: [(path: String, harness: HarnessKind)]) async -> Bool {
        guard store != nil else { return false }
        var batch = Batch()
        for (path, harness) in paths { read(path, harness: harness, into: &batch) }
        guard !batch.files.isEmpty else { return false }
        let asked = now()
        let unknown = Set(batch.requests.map(\.session)).filter { session in
            accounts[session].map { asked.timeIntervalSince($0.asked) > 600 } ?? true
        }
        if !unknown.isEmpty {
            let answer = await resolve(unknown)
            defaults = answer.defaults
            for session in unknown { accounts[session] = (answer.accounts[session] ?? "", asked) }
        }
        // The store may have closed while the app answered.
        guard let store else { return false }
        for request in batch.requests { count(request, into: &batch) }
        do {
            try store.apply(rows: Array(batch.rows.values), seen: batch.seen, files: batch.files)
            files.merge(batch.files) { $1 }
        } catch {
            // Nothing was recorded, so the same lines are read again next time.
            seen = (try? store.seen(since: day(daysBefore: Self.seenDays))) ?? seen
            return false
        }
        return !batch.rows.isEmpty
    }

    private func read(_ path: String, harness: HarnessKind, into batch: inout Batch) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return }
        // Where the file system has no file number, a file is known by its path alone.
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var state = files[path] ?? TokenUsageStore.FileState(inode: inode, offset: 0, carry: nil)
        // A file replaced or cut short is read again from its start.
        if state.inode != inode || size < state.offset {
            state = TokenUsageStore.FileState(inode: inode, offset: 0, carry: nil)
        }
        guard size > state.offset, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        var carry = state.carry.flatMap { try? JSONDecoder().decode(CodexUsageReader.Carry.self, from: $0) }
            ?? CodexUsageReader.Carry()
        var pending = Data()
        do {
            try handle.seek(toOffset: state.offset)
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                bytesRead += UInt64(chunk.count)
                pending.append(chunk)
                let (lines, consumed) = TokenUsageLines.complete(pending)
                guard consumed > 0 else { continue }
                let requests = harness == .codex
                    ? CodexUsageReader.requests(in: lines, carry: &carry)
                    : ClaudeUsageReader.requests(in: lines)
                batch.requests += requests
                state.offset += UInt64(consumed)
                pending.removeFirst(consumed)
            }
        } catch {
            return
        }
        if harness == .codex { state.carry = try? JSONEncoder().encode(carry) }
        batch.files[path] = state
    }

    private func count(_ request: TokenUsageRequest, into batch: inout Batch) {
        let day = day(of: request.date)
        guard day >= self.day(daysBefore: Self.keptDays) else { return }
        var request = request
        var requests = 1
        if let id = request.messageID {
            // The same response again, a later line of it or a forked conversation's copy: only output it
            // had not counted yet.
            let hash = Self.hash(id)
            let output = request.output
            if let counted = seen[hash] {
                guard output > counted else { return }
                request.freshInput = 0
                request.cacheWrite = 0
                request.longCacheWrite = 0
                request.cacheRead = 0
                request.output = output - counted
                requests = 0
            }
            seen[hash] = output
            batch.seen.append((hash, output, day))
        }
        let named = accounts[request.session]?.name ?? ""
        let account = named.isEmpty ? defaults[request.harness] ?? "" : named
        let key = [String(day), request.harness.rawValue, request.model, request.session, request.folder, account]
            .joined(separator: "\u{1F}")
        var row = batch.rows[key] ?? TokenUsageStore.Row(
            day: day, harness: request.harness.rawValue, model: request.model, session: request.session,
            folder: request.folder, account: account, amount: TokenUsageAmount())
        row.amount.freshInput += request.freshInput
        row.amount.cacheWrite += request.cacheWrite + request.longCacheWrite
        row.amount.cacheRead += request.cacheRead
        row.amount.output += request.output
        row.amount.requests += requests
        if let rates = TokenUsagePrices.rates(model: request.model, prompt: request.prompt, fast: request.fast,
                                              usOnly: request.usOnly) {
            let cost: [TokenUsageKind: Double] = [
                .freshInput: Double(request.freshInput) * rates.input / 1e6,
                .cacheWrite: (Double(request.cacheWrite) * rates.cacheWrite
                              + Double(request.longCacheWrite) * rates.longCacheWrite) / 1e6,
                .cacheRead: Double(request.cacheRead) * rates.cacheRead / 1e6,
                .output: Double(request.output) * rates.output / 1e6
            ]
            row.amount.kindCost.merge(cost, uniquingKeysWith: +)
        }
        batch.rows[key] = row
    }

    /// FNV-1a of a response's id.
    static func hash(_ id: String) -> Int64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return Int64(bitPattern: value)
    }

    // MARK: Summary

    /// A day as `yyyymmdd` in the Mac's calendar and time zone.
    private func day(of date: Date) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    private func day(daysBefore count: Int) -> Int {
        day(of: calendar.date(byAdding: .day, value: -count, to: now()) ?? now())
    }

    private func prune() {
        let today = day(daysBefore: 0)
        guard prunedDay != today, let store else { return }
        prunedDay = today
        try? store.prune(usageBefore: day(daysBefore: Self.keptDays), seenBefore: day(daysBefore: Self.seenDays))
        let oldest = day(daysBefore: Self.seenDays)
        if seen.count > 50_000, let kept = try? store.seen(since: oldest) { seen = kept }
    }

    /// The day the last summary was made for.
    private var summarized: Int?

    private func sendSummary() {
        guard let store, let publish, let rows = try? store.rows(since: day(daysBefore: 29)) else { return }
        summarized = day(daysBefore: 0)
        publish(TokenUsageSummary(rows: rows, calendar: calendar, now: now()))
    }
}

/// The ledger's counts for the views: the last 30 days, and each range's counts by the key each
/// grouping reads (model id, provider session, folder, account), which the app names.
struct TokenUsageSummary: Equatable, Sendable {
    struct Key: Hashable, Sendable {
        let harness: HarnessKind?
        let value: String
        /// The session's folder, which names a session Yardlet does not know.
        var folder = ""
    }

    var days: [TokenUsageDay]
    var groups: [TokenUsageRange: [TokenUsageGrouping: [Key: TokenUsageAmount]]]
    var updatedAt: Date

    init(days: [TokenUsageDay], groups: [TokenUsageRange: [TokenUsageGrouping: [Key: TokenUsageAmount]]],
         updatedAt: Date) {
        self.days = days
        self.groups = groups
        self.updatedAt = updatedAt
    }

    init(rows: [TokenUsageStore.Row], calendar: Calendar, now: Date) {
        let today = calendar.startOfDay(for: now)
        let starts = (0..<30).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        func number(_ date: Date) -> Int {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
        }
        let numbers = starts.map(number)
        var byDay: [Int: TokenUsageAmount] = [:]
        var groups: [TokenUsageRange: [TokenUsageGrouping: [Key: TokenUsageAmount]]] = [:]
        for row in rows {
            byDay[row.day, default: TokenUsageAmount()].add(row.amount)
            let harness = HarnessKind(rawValue: row.harness)
            for range in TokenUsageRange.allCases where row.day >= numbers[numbers.count - range.days] {
                let keys: [TokenUsageGrouping: Key] = [
                    .model: Key(harness: harness, value: row.model),
                    .task: Key(harness: harness, value: row.session, folder: row.folder),
                    .project: Key(harness: nil, value: row.folder),
                    .account: Key(harness: harness, value: row.account)
                ]
                for (grouping, key) in keys {
                    groups[range, default: [:]][grouping, default: [:]][key, default: TokenUsageAmount()].add(row.amount)
                }
            }
        }
        self.init(days: zip(starts, numbers).map { TokenUsageDay(start: $0, amount: byDay[$1] ?? TokenUsageAmount()) },
                  groups: groups, updatedAt: now)
    }
}
