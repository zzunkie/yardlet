import Foundation
import Observation

/// Task Resource Usage on the main actor: runs the one sampler for the whole app, every
/// `activeInterval` while Yardlet is the active app and every `backgroundInterval` otherwise, and
/// publishes what the sidebar, the Task Resource Usage window and a task's header (its servers) show.
/// Only a change someone can see is published: a row's CPU to a tenth of a percent, its memory to a
/// MiB, its process count, the CPU of a busy task in whole percent, and a task's ports.
@MainActor
@Observable
final class TaskResourceMonitor {
    /// One line of the Task Resource Usage window.
    struct Row: Identifiable, Equatable, Sendable {
        let id: TaskResourceOwner
        let harness: HarnessKind
        let title: String
        /// Where it runs: Yardlet, the Claude app, another app, or several of them.
        let location: String
        /// The last ten seconds' CPU, in percent of one core, to a tenth; nil until measured.
        let cpuPercent: Double?
        /// Its memory footprint, to a MiB.
        let memoryBytes: UInt64
        let processCount: Int

        var taskID: UUID? { id.taskID }
        /// Sorts a row not yet measured below every measured one.
        var cpuSortValue: Double { cpuPercent ?? -1 }

        /// The window's order: the busiest CPU first, then the most memory, then by title.
        static func heavierFirst(_ lhs: Row, _ rhs: Row) -> Bool {
            if lhs.cpuSortValue != rhs.cpuSortValue { return lhs.cpuSortValue > rhs.cpuSortValue }
            if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    /// Every counted process tree, heaviest first.
    private(set) var rows: [Row] = []
    /// Tasks whose processes keep using a lot of CPU (`TaskResourceAverager`), with that CPU in
    /// whole percent. A task that is not busy is absent. Reading this observes every task; a
    /// sidebar row reads `busyCPU(of:)`, so a sample that changes one task's CPU redraws that row
    /// and not every row in the sidebar.
    var busyTaskCPU: [UUID: Int] { busyCPU.dictionary }
    @ObservationIgnored private let busyCPU = TaskStateTable<Int>()
    /// The ports each task's processes listen on (`TaskServerFinder`); a task with none is absent. A
    /// task's header reads its own, so a server starting redraws that header only.
    @ObservationIgnored private let servers = TaskStateTable<[TaskServerPort]>()

    @ObservationIgnored var activeInterval: Duration = .seconds(3)
    @ObservationIgnored var backgroundInterval: Duration = .seconds(10)
    /// What the app knows that a sample needs (tasks' shells and Claude conversations).
    @ObservationIgnored var request: @MainActor () -> TaskResourceRequest = { TaskResourceRequest() }
    /// A task's harness and title, or nil when it is not a task the app lists.
    @ObservationIgnored var describe: @MainActor (TaskResourceOwner) -> (harness: HarnessKind, title: String)? = { _ in nil }

    @ObservationIgnored private let engine: TaskResourceEngine
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private(set) var isApplicationActive = true

    init(engine: TaskResourceEngine) {
        self.engine = engine
    }

    convenience init(table: any ProcessTableReading, registry: TaskProcessRegistry = .shared) {
        self.init(engine: TaskResourceEngine(table: table, registry: registry))
    }

    var isRunning: Bool { loop != nil }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.isApplicationActive ? self.activeInterval : self.backgroundInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Yardlet became the active app or stopped being it. Becoming active samples at once and
    /// returns to the active interval, instead of finishing a background wait.
    func setApplicationActive(_ active: Bool) {
        guard active != isApplicationActive else { return }
        isApplicationActive = active
        if active, loop != nil {
            stop()
            start()
        }
    }

    /// Takes one sample now and publishes it.
    func refresh() async {
        let sample = await engine.takeSample(request())
        guard !Task.isCancelled else { return }
        apply(sample.usages)
        applyServers(sample.servers)
    }

    /// The ports the task's processes listen on, lowest first; empty when it has none.
    func servers(of task: UUID) -> [TaskServerPort] {
        servers[task] ?? []
    }

    func applyServers(_ found: [UUID: [TaskServerPort]]) {
        for id in Set(servers.dictionary.keys).union(found.keys) where servers[id] != found[id] {
            servers[id] = found[id]
        }
    }

    func apply(_ usages: [TaskResourceUsage]) {
        var next: [Row] = []
        var busy: [UUID: Int] = [:]
        for usage in usages where usage.processCount > 0 {
            guard let described = describe(usage.owner) else { continue }
            let mebibytes = (usage.memoryBytes + (1 << 19)) >> 20
            next.append(Row(
                id: usage.owner, harness: described.harness, title: described.title,
                location: Self.locationName(usage.locations, owner: usage.owner),
                cpuPercent: usage.cpuPercent.map { ($0 * 10).rounded() / 10 },
                memoryBytes: mebibytes << 20, processCount: usage.processCount
            ))
            if usage.isBusy, let task = usage.owner.taskID, let cpu = usage.cpuPercent {
                busy[task, default: 0] += Int(cpu.rounded())
            }
        }
        next.sort(by: Row.heavierFirst)
        if next != rows { rows = next }
        for id in Set(busyCPU.dictionary.keys).union(busy.keys) where busyCPU[id] != busy[id] {
            busyCPU[id] = busy[id]
        }
    }

    /// The busy CPU of `taskIDs` that are busy, observing only those tasks.
    func busyCPU(of taskIDs: some Sequence<UUID>) -> [UUID: Int] {
        var values: [UUID: Int] = [:]
        for id in taskIDs { if let percent = busyCPU[id] { values[id] = percent } }
        return values
    }

    static func locationName(_ locations: Set<TaskResourceLocation>, owner: TaskResourceOwner) -> String {
        if case .codexAppServer = owner { return YardletProduct.name }
        return locations.sorted().map { location in
            switch location {
            case .yardlet: YardletProduct.name
            case .claudeApp: L10n.string("Claude app")
            case .otherApp: L10n.string("Another app")
            }
        }.joined(separator: ", ")
    }
}

extension AppModel {
    /// What a resource sample needs from the app: each task's bash-mode shell, the Claude tasks
    /// whose conversation another app may run, with the config folder each one's account reads
    /// (`isHeldElsewhere` reads the same folder), and whether to find the tasks' servers, with each
    /// Codex task's thread and Antigravity task's conversation.
    func taskResourceRequest() -> TaskResourceRequest {
        var request = TaskResourceRequest(shells: taskShells.processIDs())
        guard !usesVisualFixture else { return request }
        if TaskServersPreference.isOn() {
            request.findsServers = true
            for session in store.sessions where session.harness == .codex || session.harness == .antigravityCLI {
                guard let conversation = session.providerSessionID?.lowercased(), !conversation.isEmpty else { continue }
                if session.harness == .codex {
                    request.codexThreads[conversation] = session.id
                } else {
                    request.antigravityConversations[conversation] = session.id
                }
            }
        }
        let environment = ProcessInfo.processInfo.environment
        for session in store.sessions where session.harness == .claudeCode {
            guard let id = session.providerSessionID, !id.isEmpty else { continue }
            request.claudeConversations.append(ClaudeConversationReference(
                taskID: session.id, providerSessionID: id,
                configDirectory: ClaudeSubagentTranscriptReader.configDirectory(
                    connection: session.connection, environment: environment, workspaceURL: session.workspaceURL
                )
            ))
        }
        return request
    }

    /// The harness and title a resource row shows: a task's own, or for a Codex App Server, the
    /// account it runs for. Nil for a task the app no longer lists.
    func taskResourceDescription(_ owner: TaskResourceOwner) -> (harness: HarnessKind, title: String)? {
        switch owner {
        case let .task(id):
            guard let session = store.sessions.first(where: { $0.id == id }) else { return nil }
            return (session.harness, session.title)
        case let .codexAppServer(identity):
            // The account the login reported (its email), else the saved connection's name.
            let choice = connections.choices(for: [.codex]).first { $0.connection?.id == identity.connection?.id }
            let reported = choice?.snapshot?.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let account = (reported?.isEmpty == false ? reported : nil) ?? choice?.knownLabel
                ?? identity.connection?.name ?? L10n.string("Default account")
            return (.codex, L10n.format("Codex App Server · %@", account))
        case .agentProcess:
            return nil
        }
    }
}
