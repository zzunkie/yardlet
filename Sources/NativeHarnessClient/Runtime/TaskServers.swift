import Foundation

// A task's local servers: the TCP ports the processes a task started listen on, such as a dev server
// on `localhost:3000`, found by the processes' lineage rather than by scanning the whole system. The
// resource sampler already follows each task's process tree (`TaskResourceSampler`); this reads the
// listening sockets of the processes under Yardlet's own roots in that tree, and of the processes
// those trees left to launchd.

/// A port one of a task's processes listens on, which the task's browser opens as `localhost:<port>`.
struct TaskServerPort: Hashable, Sendable {
    let port: Int
    /// The process listening: when several share the port (a server and its workers), the one
    /// nearest the task's own process.
    let processID: Int32
    let processName: String

    var address: String { "localhost:\(port)" }
    var url: URL { URL(string: "http://localhost:\(port)")! }
}

/// Which task each listening port belongs to.
///
/// - A process under a task's own root (its Claude Code CLI, its terminal panel's shell, its
///   bash-mode shell) is the task's. The root itself is left out: the harness or the shell listening
///   (a sign-in callback, a remote-control server) is not the task's server.
/// - A Codex App Server runs commands for every task of its account. Codex gives a command's
///   processes the thread that ran it in their environment (`CODEX_THREAD_ID`); the process's own,
///   else its nearest ancestor's under the server, names the task. Processes with no thread (the
///   server's MCP servers) are no task's.
/// - A server started in the background from a shell that then ended (`npm run dev &`, `nohup`, a
///   database that daemonizes) is left to launchd, out of every tree. Its environment still says who
///   ran it: Claude Code gives its commands `CLAUDE_CODE_SESSION_ID`, and Yardlet starts its CLI with
///   `CLAUDE_CODE_ENTRYPOINT=native-harness-client` (the Claude app's is `claude-desktop`); Codex gives
///   `CODEX_THREAD_ID`. Such a process, with what it started, is the task's whose conversation that is.
///   Each of launchd's children is read once (its environment is fixed when it starts): about 9 ms for
///   the 376 on the Mac this was written on, then only the new ones.
/// - Processes another app runs (the Claude app's CLI) are not read.
struct TaskServerFinder {
    static let claudeSessionVariable = "CLAUDE_CODE_SESSION_ID"
    static let claudeEntrypointVariable = "CLAUDE_CODE_ENTRYPOINT"
    static let yardletClaudeEntrypoint = "native-harness-client"
    static let codexThreadVariable = "CODEX_THREAD_ID"
    private static let variables: Set<String> = [claudeSessionVariable, claudeEntrypointVariable, codexThreadVariable]

    private struct ProcessKey: Hashable {
        let processID: Int32
        let start: Int64
    }

    /// What each process's environment says about who ran it, read once per process.
    private var environments: [ProcessKey: [String: String]] = [:]

    /// The servers of each task, lowest port first.
    /// - Parameters:
    ///   - descendants: the processes under Yardlet's roots (`TaskResourceSampler.yardletDescendants`).
    ///   - entries: the whole process table, for launchd's children; `claimed`, the processes some
    ///     root's tree already took.
    ///   - claudeSessions, codexThreads: each Claude conversation and Codex thread Yardlet lists, by its
    ///     lowercased ID, with its task.
    mutating func servers(
        descendants: [TaskResourceOwner: [ProcessTableEntry]], entries: [ProcessTableEntry], claimed: Set<Int32>,
        table: some ProcessTableReading, claudeSessions: [String: UUID], codexThreads: [String: UUID]
    ) -> [UUID: [TaskServerPort]] {
        var candidates: [(task: UUID?, process: ProcessTableEntry, codexTree: [Int32: ProcessTableEntry]?)] = []
        for (owner, processes) in descendants {
            switch owner {
            case let .task(id):
                candidates += processes.map { (id, $0, nil) }
            case .codexAppServer:
                var byID: [Int32: ProcessTableEntry] = [:]
                for process in processes { byID[process.processID] = process }
                candidates += processes.map { (nil, $0, byID) }
            }
        }

        var present = Set<ProcessKey>()
        if !claudeSessions.isEmpty || !codexThreads.isEmpty {
            var children: [Int32: [ProcessTableEntry]]?
            for entry in entries where entry.parentID == 1 && !claimed.contains(entry.processID) {
                present.insert(ProcessKey(processID: entry.processID, start: entry.startMicroseconds))
                guard let task = task(ofLeftBehind: entry, table: table, claudeSessions: claudeSessions,
                                      codexThreads: codexThreads) else { continue }
                if children == nil {
                    var map: [Int32: [ProcessTableEntry]] = [:]
                    for entry in entries where entry.parentID != entry.processID { map[entry.parentID, default: []].append(entry) }
                    children = map
                }
                var queue = [entry]
                var index = 0
                var seen: Set<Int32> = [entry.processID]
                while index < queue.count {
                    let process = queue[index]
                    index += 1
                    candidates.append((task, process, nil))
                    for child in children?[process.processID] ?? [] where seen.insert(child.processID).inserted {
                        queue.append(child)
                    }
                }
            }
        }

        var found: [UUID: [Int: TaskServerPort]] = [:]
        for candidate in candidates {
            let ports = table.listeningPorts(of: candidate.process.processID)
            guard !ports.isEmpty else { continue }
            let task: UUID?
            if let tree = candidate.codexTree {
                task = thread(of: candidate.process, in: tree, table: table, present: &present).flatMap { codexThreads[$0] }
            } else {
                task = candidate.task
            }
            guard let task else { continue }
            let name = table.name(of: candidate.process.processID) ?? ""
            for port in ports where found[task]?[port] == nil {
                found[task, default: [:]][port] = TaskServerPort(port: port, processID: candidate.process.processID,
                                                                 processName: name)
            }
        }
        // Forget the processes that ended.
        environments = environments.filter { present.contains($0.key) }
        return found.mapValues { $0.values.sorted { $0.port < $1.port } }
    }

    /// The task of a process launchd took over: the Yardlet Claude conversation or the Codex thread its
    /// environment names.
    private mutating func task(ofLeftBehind entry: ProcessTableEntry, table: some ProcessTableReading,
                               claudeSessions: [String: UUID], codexThreads: [String: UUID]) -> UUID? {
        let environment = environment(of: entry, table: table)
        if let session = environment[Self.claudeSessionVariable]?.lowercased(),
           environment[Self.claudeEntrypointVariable] == Self.yardletClaudeEntrypoint,
           let task = claudeSessions[session] { return task }
        if let thread = environment[Self.codexThreadVariable]?.lowercased() { return codexThreads[thread] }
        return nil
    }

    /// The Codex thread the process runs for: its own `CODEX_THREAD_ID`, else that of its nearest
    /// ancestor among the server's processes.
    private mutating func thread(of process: ProcessTableEntry, in tree: [Int32: ProcessTableEntry],
                                 table: some ProcessTableReading, present: inout Set<ProcessKey>) -> String? {
        var current: ProcessTableEntry? = process
        for _ in 0..<32 {
            guard let entry = current else { return nil }
            present.insert(ProcessKey(processID: entry.processID, start: entry.startMicroseconds))
            if let thread = environment(of: entry, table: table)[Self.codexThreadVariable], !thread.isEmpty {
                return thread.lowercased()
            }
            current = tree[entry.parentID]
        }
        return nil
    }

    private mutating func environment(of entry: ProcessTableEntry, table: some ProcessTableReading) -> [String: String] {
        let key = ProcessKey(processID: entry.processID, start: entry.startMicroseconds)
        if let known = environments[key] { return known }
        let read = table.environment(Self.variables, of: entry.processID)
        environments[key] = read
        return read
    }
}

/// Settings › General's "Show servers tasks start": on by default. Off, nothing is read and nothing shows.
enum TaskServersPreference {
    static let key = "YardletShowsTaskServers"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}
