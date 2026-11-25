import Foundation

// Task Resource Usage: how much CPU and memory each task's processes use. One sampler reads the
// process table, follows each task's process tree from the processes known to be the task's, and
// averages the CPU those trees used over the last few seconds. This file holds the platform-neutral
// part; `LiveProcessTable` (Platform/macOS) reads the table.

/// Whom a process tree's CPU and memory count toward.
enum TaskResourceOwner: Hashable, Sendable {
    /// A Yardlet task: the processes Yardlet started for it, or the Claude process another app
    /// runs its conversation in.
    case task(UUID)
    /// A Codex App Server Yardlet runs for one account. Many tasks share it, so it is its own row.
    case codexAppServer(CodexAppServerIdentity)
    /// An ACP agent's process Yardlet runs (`ACPProcessLane`), which the agent's open tasks share: Antigravity's,
    /// whose commands name their conversation. It is followed for the servers the tasks' commands start
    /// (`TaskServerFinder`) and has no row of its own.
    case agentProcess(HarnessKind)

    var taskID: UUID? {
        if case let .task(id) = self { return id }
        return nil
    }
}

/// One Codex App Server Yardlet runs: an account's login (nil is the default login) in one storage
/// scope, as `HarnessRegistry` keys its Codex adapters.
struct CodexAppServerIdentity: Hashable, Sendable {
    let connection: ProviderConnection?
    let environmentScope: SessionEnvironmentScope
}

/// Where a counted process tree runs.
enum TaskResourceLocation: Int, Hashable, Comparable, Sendable {
    /// Yardlet started it.
    case yardlet
    /// The Claude desktop app runs it (Claude Code's `entrypoint` is `claude-desktop`).
    case claudeApp
    /// Another program runs a Claude process for the conversation, such as a terminal.
    case otherApp

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The processes Yardlet itself starts for tasks and for the Codex App Servers they share, by
/// process ID. A transport or shell registers its process right after starting it and removes it
/// when it ends; the sampler counts each one with everything it starts.
final class TaskProcessRegistry: @unchecked Sendable {
    static let shared = TaskProcessRegistry()

    private let lock = NSLock()
    private var owners: [Int32: TaskResourceOwner] = [:]

    func register(_ processID: Int32, owner: TaskResourceOwner) {
        guard processID > 0 else { return }
        lock.withLock { owners[processID] = owner }
    }

    /// Removes the registration, unless the ID has since been registered for another owner.
    func unregister(_ processID: Int32, owner: TaskResourceOwner) {
        lock.withLock {
            if owners[processID] == owner { owners[processID] = nil }
        }
    }

    var registered: [Int32: TaskResourceOwner] {
        lock.withLock { owners }
    }
}

// MARK: - Process table

/// One process in the system's process table: its parent, and when it started (microseconds since
/// 1970), which tells it apart from a later process given the same ID.
struct ProcessTableEntry: Equatable, Sendable {
    let processID: Int32
    let parentID: Int32
    let startMicroseconds: Int64
}

/// What one process has used so far.
struct ProcessUsageReading: Equatable, Sendable {
    /// CPU time it used itself, user and system, in nanoseconds.
    var cpuNanoseconds: UInt64
    /// CPU time of its children that have ended and that it collected, in nanoseconds. A command
    /// that starts and ends between two samples shows up here.
    var endedChildrenCPUNanoseconds: UInt64 = 0
    /// Its memory footprint, the figure Activity Monitor's Memory column shows.
    var memoryBytes: UInt64 = 0
}

/// The system's process table. The app reads it through `LiveProcessTable`; tests give their own.
protocol ProcessTableReading: Sendable {
    /// Every process now running.
    func entries() -> [ProcessTableEntry]
    /// What the process has used, or nil when it cannot be read (it has ended, or belongs to
    /// another user).
    func usage(of processID: Int32) -> ProcessUsageReading?
    /// The TCP ports the process listens on that `localhost` reaches: bound to a loopback address or
    /// to every address. Empty when it listens on none or cannot be read.
    func listeningPorts(of processID: Int32) -> [Int]
    /// The values of the environment variables `names` the process started with, those it has; empty
    /// when it cannot be read (it has ended, or belongs to another user).
    func environment(_ names: Set<String>, of processID: Int32) -> [String: String]
    /// The process's name, as Activity Monitor shows it.
    func name(of processID: Int32) -> String?
}

extension ProcessTableReading {
    func listeningPorts(of processID: Int32) -> [Int] { [] }
    func environment(_ names: Set<String>, of processID: Int32) -> [String: String] { [:] }
    func name(of processID: Int32) -> String? { nil }
}

/// When a sample was taken: time since boot without sleep, for the interval a CPU figure covers,
/// and the wall clock, to compare with when processes started.
struct TaskResourceSampleTime: Equatable, Sendable {
    var uptimeNanoseconds: UInt64
    var wallMicroseconds: Int64

    static func now() -> TaskResourceSampleTime {
        TaskResourceSampleTime(
            uptimeNanoseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000),
            wallMicroseconds: Int64(Date().timeIntervalSince1970 * 1_000_000)
        )
    }
}

// MARK: - Sampling

/// A process whose tree counts toward an owner.
struct TaskResourceRoot: Equatable, Sendable {
    var owner: TaskResourceOwner
    var location: TaskResourceLocation
    var processID: Int32
    /// When another app says the process started (Claude Code's `startedAt`), in microseconds since
    /// 1970. A process that started further than `TaskResourceSampler.reportedStartTolerance` from
    /// it took the ID of a process that ended without removing its file, and is not counted.
    var reportedStartMicroseconds: Int64? = nil
    /// Another app's process is not counted when it runs under this process (Yardlet): Yardlet's
    /// own processes count through their own roots.
    var skipsDescendantsOf: Int32? = nil
}

/// One owner's process tree in one sample.
struct TaskResourceMeasurement: Equatable, Sendable {
    var owner: TaskResourceOwner
    var locations: Set<TaskResourceLocation>
    var processCount: Int
    var memoryBytes: UInt64
    /// The CPU time the tree used since the previous sample and how long that was, both in
    /// nanoseconds; nil on the owner's first sample.
    var cpuNanoseconds: UInt64?
    var intervalNanoseconds: UInt64?
}

/// Follows each root's process tree through one read of the process table and measures the CPU
/// each tree used since the previous sample.
///
/// A tree's CPU in an interval is the change of its processes' totals, where a process's total is
/// its own CPU time plus that of the children it collected. A child that ends moves its time into
/// its parent's total, so the tree's sum carries on unbroken, and a command that starts and ends
/// between samples is counted through its parent. Per process:
/// - seen in the previous sample: its total minus the previous one;
/// - started since the previous sample: its whole total;
/// - already running but not counted before (newly found): nothing this time, its total is the
///   baseline for the next sample;
/// - gone since the previous sample: its previous total is taken off, because its parent's total
///   now holds it. An ended child its parent has not collected yet keeps its last reading until it
///   is collected, so the time is neither lost nor counted twice.
/// A tree whose processes left it otherwise (the root ended, a child was handed to another parent)
/// would go below zero; it counts as zero.
struct TaskResourceSampler {
    /// Claude Code writes `startedAt` as it starts, within moments of the process's own start.
    static let reportedStartTolerance: Int64 = 30_000_000

    private struct ProcessKey: Hashable {
        let processID: Int32
        let start: Int64
    }

    private struct RootKey: Hashable {
        let processID: Int32
        let owner: TaskResourceOwner
    }

    private var previousTotals: [ProcessKey: UInt64] = [:]
    private var previousMembers: [TaskResourceOwner: Set<ProcessKey>] = [:]
    private var previousTime: TaskResourceSampleTime?
    /// The last sample's processes that Yardlet's own roots started, by owner, nearest the root
    /// first: the processes a task's servers can be (`TaskServerFinder`). The roots themselves (the
    /// harness, the shell) are left out.
    private(set) var yardletDescendants: [TaskResourceOwner: [ProcessTableEntry]] = [:]
    /// The last sample's process table, and the processes some root's tree took, for the servers whose
    /// shell ended and left them to launchd.
    private(set) var lastEntries: [ProcessTableEntry] = []
    private(set) var claimedProcessIDs = Set<Int32>()
    /// When each root's process started, from the first sample that saw it, for as long as the root
    /// is given. A registration whose process ended unnoticed is not followed into another process
    /// that later took its ID.
    private var rootStarts: [RootKey: Int64] = [:]

    /// Measures every root's tree. Roots come in priority order: a process two roots reach counts
    /// for the first. Reads the process table once, and each counted process's usage once.
    mutating func sample(
        _ roots: [TaskResourceRoot], table: some ProcessTableReading, at time: TaskResourceSampleTime
    ) -> [TaskResourceMeasurement] {
        guard !roots.isEmpty else {
            self = TaskResourceSampler()
            return []
        }
        let entries = table.entries()
        var byID: [Int32: ProcessTableEntry] = [:]
        byID.reserveCapacity(entries.count)
        var children: [Int32: [Int32]] = [:]
        for entry in entries {
            byID[entry.processID] = entry
            if entry.parentID != entry.processID { children[entry.parentID, default: []].append(entry.processID) }
        }

        var claimed = Set<Int32>()
        var owners: [TaskResourceOwner] = []
        var members: [TaskResourceOwner: [ProcessTableEntry]] = [:]
        var locations: [TaskResourceOwner: Set<TaskResourceLocation>] = [:]
        var nextRootStarts: [RootKey: Int64] = [:]
        var descendants: [TaskResourceOwner: [ProcessTableEntry]] = [:]
        for root in roots {
            let rootKey = RootKey(processID: root.processID, owner: root.owner)
            let known = rootStarts[rootKey]
            nextRootStarts[rootKey] = known
            guard let entry = byID[root.processID], !claimed.contains(root.processID) else { continue }
            if let known, known != entry.startMicroseconds { continue }
            nextRootStarts[rootKey] = entry.startMicroseconds
            if let reported = root.reportedStartMicroseconds,
               abs(reported - entry.startMicroseconds) > Self.reportedStartTolerance { continue }
            if let ancestor = root.skipsDescendantsOf, Self.descends(entry, from: ancestor, in: byID) { continue }

            if members[root.owner] == nil { owners.append(root.owner) }
            locations[root.owner, default: []].insert(root.location)
            var tree = members[root.owner] ?? []
            var queue = [entry.processID]
            var index = 0
            while index < queue.count {
                let processID = queue[index]
                index += 1
                guard claimed.insert(processID).inserted, let process = byID[processID] else { continue }
                tree.append(process)
                if root.location == .yardlet, processID != root.processID {
                    descendants[root.owner, default: []].append(process)
                }
                queue.append(contentsOf: children[processID] ?? [])
            }
            members[root.owner] = tree
        }
        rootStarts = nextRootStarts
        yardletDescendants = descendants
        lastEntries = entries
        claimedProcessIDs = claimed

        var totals: [ProcessKey: UInt64] = [:]
        var memory: [TaskResourceOwner: UInt64] = [:]
        var keys: [TaskResourceOwner: Set<ProcessKey>] = [:]
        for owner in owners {
            var ownerKeys = Set<ProcessKey>()
            var ownerMemory: UInt64 = 0
            for process in members[owner] ?? [] {
                let key = ProcessKey(processID: process.processID, start: process.startMicroseconds)
                ownerKeys.insert(key)
                if let usage = table.usage(of: process.processID) {
                    totals[key] = usage.cpuNanoseconds &+ usage.endedChildrenCPUNanoseconds
                    ownerMemory &+= usage.memoryBytes
                } else if let earlier = previousTotals[key] {
                    totals[key] = earlier
                }
            }
            keys[owner] = ownerKeys
            memory[owner] = ownerMemory
        }

        let measurements = owners.map { owner -> TaskResourceMeasurement in
            let ownerKeys = keys[owner] ?? []
            var measurement = TaskResourceMeasurement(
                owner: owner, locations: locations[owner] ?? [], processCount: ownerKeys.count,
                memoryBytes: memory[owner] ?? 0
            )
            guard let previousTime, let before = previousMembers[owner],
                  time.uptimeNanoseconds > previousTime.uptimeNanoseconds else { return measurement }
            var used: Int64 = 0
            for key in ownerKeys {
                guard let total = totals[key] else { continue }
                if let earlier = previousTotals[key] {
                    used += Int64(clamping: total) - Int64(clamping: earlier)
                } else if key.start >= previousTime.wallMicroseconds {
                    used += Int64(clamping: total)
                }
            }
            for key in before where totals[key] == nil {
                used -= Int64(clamping: previousTotals[key] ?? 0)
            }
            measurement.cpuNanoseconds = UInt64(max(0, used))
            measurement.intervalNanoseconds = time.uptimeNanoseconds - previousTime.uptimeNanoseconds
            return measurement
        }

        previousTotals = totals
        previousMembers = keys
        previousTime = time
        return measurements
    }

    /// Whether `ancestor` is among the process's ancestors.
    private static func descends(_ entry: ProcessTableEntry, from ancestor: Int32,
                                 in byID: [Int32: ProcessTableEntry]) -> Bool {
        var parent = entry.parentID
        for _ in 0..<64 {
            if parent == ancestor { return true }
            guard parent > 1, let next = byID[parent], next.parentID != parent else { return false }
            parent = next.parentID
        }
        return false
    }
}

// MARK: - Averaging

/// One owner's recent use, as the sidebar and the Task Resource Usage window show it.
struct TaskResourceUsage: Equatable, Sendable {
    var owner: TaskResourceOwner
    var locations: Set<TaskResourceLocation>
    var processCount: Int
    var memoryBytes: UInt64
    /// CPU over the last `TaskResourceAverager.window`, in percent of one core (two busy cores are
    /// 200); nil until two samples have seen the tree.
    var cpuPercent: Double?
    /// The tree keeps using a lot of CPU: its task's sidebar row says so.
    var isBusy: Bool
}

/// Averages each owner's CPU over the last ten seconds and decides, with hysteresis, whether it
/// keeps using a lot of CPU.
///
/// The indicator turns on when the average over a nearly full window reaches 50 % (half of one
/// core for ten seconds) and off when it drops below 25 %. An idle Claude or Codex process uses a
/// few percent and a streaming turn about 20 %; a build, a test run or a busy loop goes well past
/// 50 %. Requiring most of the window keeps a short burst (a few seconds of a quick command) from
/// lighting it, and the gap between the two thresholds keeps a load hovering around 40 % from
/// blinking on and off.
struct TaskResourceAverager {
    static let window: UInt64 = 10_000_000_000
    static let minimumCoverage: UInt64 = 8_500_000_000
    static let busyAbove: Double = 50
    static let idleBelow: Double = 25

    private struct Interval {
        let cpu: UInt64
        let length: UInt64
    }

    private var history: [TaskResourceOwner: [Interval]] = [:]
    private var busy = Set<TaskResourceOwner>()

    mutating func update(_ measurements: [TaskResourceMeasurement]) -> [TaskResourceUsage] {
        var nextHistory: [TaskResourceOwner: [Interval]] = [:]
        var nextBusy = Set<TaskResourceOwner>()
        let usages = measurements.map { measurement -> TaskResourceUsage in
            var intervals = history[measurement.owner] ?? []
            if let cpu = measurement.cpuNanoseconds, let length = measurement.intervalNanoseconds, length > 0 {
                intervals.append(Interval(cpu: cpu, length: length))
            }
            // The newest intervals that together cover the window.
            var covered: UInt64 = 0
            var kept = 0
            for interval in intervals.reversed() where covered < Self.window {
                covered += interval.length
                kept += 1
            }
            intervals = Array(intervals.suffix(kept))
            nextHistory[measurement.owner] = intervals

            let percent = covered > 0
                ? Double(intervals.reduce(0) { $0 + $1.cpu }) / Double(covered) * 100 : nil
            var isBusy = busy.contains(measurement.owner)
            if let percent {
                isBusy = isBusy ? percent >= Self.idleBelow
                    : percent >= Self.busyAbove && covered >= Self.minimumCoverage
            }
            if isBusy { nextBusy.insert(measurement.owner) }
            return TaskResourceUsage(
                owner: measurement.owner, locations: measurement.locations,
                processCount: measurement.processCount, memoryBytes: measurement.memoryBytes,
                cpuPercent: percent, isBusy: isBusy
            )
        }
        history = nextHistory
        busy = nextBusy
        return usages
    }
}

// MARK: - Claude processes other apps run

/// A Claude Code process as it registers itself in its config folder's `sessions/<pid>.json`.
struct RegisteredClaudeSession: Equatable, Sendable {
    let processID: Int32
    let sessionID: String
    /// When the process started, by its own account (`startedAt`), in microseconds since 1970.
    let startedAtMicroseconds: Int64?
    /// Who started it: the Claude desktop app writes `claude-desktop`.
    let entrypoint: String?

    var location: TaskResourceLocation {
        entrypoint == "claude-desktop" ? .claudeApp : .otherApp
    }
}

/// Reads Claude Code's `sessions` folders, rereading only the files that changed since the last
/// read. The files belong to Claude Code: they are only read, and a file that is not what is
/// expected is skipped.
struct ClaudeSessionRegistryReader {
    private struct Cached {
        let modified: Date
        let size: Int
        let session: RegisteredClaudeSession?
    }

    private var cache: [String: [String: Cached]] = [:]

    mutating func sessions(in folder: URL) -> [RegisteredClaudeSession] {
        let path = folder.path(percentEncoded: false)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            cache[path] = nil
            return []
        }
        let previous = cache[path] ?? [:]
        var next: [String: Cached] = [:]
        var sessions: [RegisteredClaudeSession] = []
        for file in files where file.pathExtension == "json" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let size = values.fileSize, size < 65_536 else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let name = file.lastPathComponent
            let entry: Cached
            if let cached = previous[name], cached.modified == modified, cached.size == size {
                entry = cached
            } else {
                entry = Cached(modified: modified, size: size,
                               session: (try? Data(contentsOf: file)).flatMap(Self.session(from:)))
            }
            next[name] = entry
            if let session = entry.session { sessions.append(session) }
        }
        cache[path] = next
        return sessions.sorted { $0.processID < $1.processID }
    }

    static func session(from data: Data) -> RegisteredClaudeSession? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let pid = value["pid"]?.doubleValue, pid > 1, pid < Double(Int32.max),
              let sessionID = value["sessionId"]?.stringValue, !sessionID.isEmpty else { return nil }
        let startedAt = value["startedAt"]?.doubleValue.flatMap { $0 > 0 && $0 < 1e15 ? Int64($0 * 1_000) : nil }
        return RegisteredClaudeSession(processID: Int32(pid), sessionID: sessionID,
                                       startedAtMicroseconds: startedAt, entrypoint: value["entrypoint"]?.stringValue)
    }
}

// MARK: - Engine

/// A Claude task with a conversation, and the config folder its account uses.
struct ClaudeConversationReference: Hashable, Sendable {
    let taskID: UUID
    let providerSessionID: String
    let configDirectory: URL
}

/// What the app knows on the main actor that a sample needs besides the registered processes.
struct TaskResourceRequest: Sendable {
    /// Each task's bash-mode shell.
    var shells: [UUID: Int32] = [:]
    /// Claude tasks with a conversation another app may be running. A task's conversation counts
    /// only through its own account's `sessions` folder, as `AppModel.isHeldElsewhere` reads it.
    var claudeConversations: [ClaudeConversationReference] = []
    /// Whether to find the ports the tasks' servers listen on (`TaskServersPreference`).
    var findsServers = false
    /// Each Codex task by its thread, for the servers a shared App Server runs for it.
    var codexThreads: [String: UUID] = [:]
    /// Each Antigravity task by its conversation, for the servers a shared `agy acp` runs for it.
    var antigravityConversations: [String: UUID] = [:]
}

/// One sample: each owner's use, and the servers each task's processes run.
struct TaskResourceSample: Equatable, Sendable {
    var usages: [TaskResourceUsage] = []
    var servers: [UUID: [TaskServerPort]] = [:]
}

/// Samples off the main actor: gathers the roots (Yardlet's registered processes, the tasks'
/// shells, and the Claude processes other apps run for Yardlet's tasks), measures their trees and
/// averages the result.
actor TaskResourceEngine {
    private var sampler = TaskResourceSampler()
    private var averager = TaskResourceAverager()
    private var serverFinder = TaskServerFinder()
    private var claudeSessions = ClaudeSessionRegistryReader()
    private let table: any ProcessTableReading
    private let registry: TaskProcessRegistry
    private let ownProcessID: Int32
    private let clock: @Sendable () -> TaskResourceSampleTime

    init(
        table: any ProcessTableReading,
        registry: TaskProcessRegistry = .shared,
        ownProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
        clock: @escaping @Sendable () -> TaskResourceSampleTime = { .now() }
    ) {
        self.table = table
        self.registry = registry
        self.ownProcessID = ownProcessID
        self.clock = clock
    }

    func sample(_ request: TaskResourceRequest) -> [TaskResourceUsage] {
        takeSample(request).usages
    }

    /// Measures the trees and, when the request asks, finds the ports the tasks' processes listen on
    /// (`TaskServerFinder`).
    func takeSample(_ request: TaskResourceRequest) -> TaskResourceSample {
        let roots = roots(for: request)
        let measurements = sampler.sample(roots, table: table, at: clock())
        var sample = TaskResourceSample(usages: averager.update(measurements))
        if request.findsServers {
            var claudeTasks: [String: UUID] = [:]
            for reference in request.claudeConversations where claudeTasks[reference.providerSessionID.lowercased()] == nil {
                claudeTasks[reference.providerSessionID.lowercased()] = reference.taskID
            }
            // With no root the sampler reads no table; servers left to launchd can still be running.
            sample.servers = serverFinder.servers(
                descendants: sampler.yardletDescendants, entries: roots.isEmpty ? table.entries() : sampler.lastEntries,
                claimed: sampler.claimedProcessIDs, table: table,
                claudeSessions: claudeTasks, codexThreads: request.codexThreads,
                antigravityConversations: request.antigravityConversations)
        }
        return sample
    }

    func roots(for request: TaskResourceRequest) -> [TaskResourceRoot] {
        var roots = registry.registered.sorted { $0.key < $1.key }.map {
            TaskResourceRoot(owner: $0.value, location: .yardlet, processID: $0.key)
        }
        roots += request.shells.sorted { $0.value < $1.value }.map {
            TaskResourceRoot(owner: .task($0.key), location: .yardlet, processID: $0.value)
        }

        // Each task's conversation by the `sessions` folder its account reads (Session Switch
        // account folders link theirs to one folder), first task first.
        var folders: [URL: URL] = [:]
        var tasksByFolder: [String: [String: UUID]] = [:]
        for reference in request.claudeConversations {
            let folder = folders[reference.configDirectory] ?? reference.configDirectory
                .appending(path: "sessions", directoryHint: .isDirectory)
                .resolvingSymlinksInPath().standardizedFileURL
            folders[reference.configDirectory] = folder
            let id = reference.providerSessionID.lowercased()
            var path = folder.path(percentEncoded: false)
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            if tasksByFolder[path]?[id] == nil { tasksByFolder[path, default: [:]][id] = reference.taskID }
        }
        for (path, tasks) in tasksByFolder.sorted(by: { $0.key < $1.key }) {
            for session in claudeSessions.sessions(in: URL(filePath: path, directoryHint: .isDirectory)) {
                guard let task = tasks[session.sessionID.lowercased()] else { continue }
                roots.append(TaskResourceRoot(
                    owner: .task(task), location: session.location, processID: session.processID,
                    reportedStartMicroseconds: session.startedAtMicroseconds,
                    skipsDescendantsOf: ownProcessID
                ))
            }
        }
        return roots
    }
}
