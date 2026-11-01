import Foundation

/// One of a dot's Codex threads as its profile binds them, with what its metadata on the execution
/// history host says: a conversation root (the current one or an earlier one), or a task a root
/// spawned. A spawned task's agent loop runs on the provider's side, also when its commands ran on a
/// computer of the person's, so its history lives only on that host; Yardlet keeps no local session
/// for it and links it to none.
struct PersonalAgentThread: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case conversation, task }

    let id: String
    let kind: Kind
    /// The dot's current conversation root.
    let isCurrentRoot: Bool
    /// The root a spawned task names in the profile's listing.
    let parentID: String?
    let attachedAt: Date?
    var title: String?
    var preview: String?
    var status: CodexThreadRuntimeStatus?
    var createdAt: Date?
    var updatedAt: Date?
    /// The computer its metadata names, matched against the dot's computers by environment.
    var environmentID: String?
    /// The last part of the folder it worked in, never the whole path.
    var folder: String?
    /// Why its metadata could not be read; the thread is still the dot's.
    var failure: PersonalAgentFailure?

    var displayTitle: String {
        title ?? preview ?? (kind == .task ? L10n.string("Codex task") : L10n.string("Conversation"))
    }

    /// The thread as the read-only reader opens it, in the shape of an Activity task.
    var activity: PersonalAgentActivity {
        let running = if case .active = status { true } else { false }
        return PersonalAgentActivity(id: id, title: displayTitle, status: running ? .running : .unknown,
                                     outcome: status == .systemError ? .failed : .unknown,
                                     updatedAt: updatedAt ?? createdAt, preview: preview)
    }

    init(binding: PersonalAgentThreadBinding, currentRoot: String?, thread: CodexThreadState?,
         failure: PersonalAgentFailure? = nil) {
        id = binding.id
        isCurrentRoot = binding.id == currentRoot
        parentID = binding.parentID
        attachedAt = binding.attachedAt
        self.failure = failure
        let source = thread?.raw["threadSource"]?.stringValue
        kind = switch source {
        case "aeon": .conversation
        case "aeon_child": .task
        default: binding.parentID == nil || binding.id == currentRoot ? .conversation : .task
        }
        guard let thread else { return }
        title = Self.line(thread.name)
        preview = Self.line(thread.preview)
        status = thread.status
        createdAt = thread.createdAt
        updatedAt = thread.updatedAt
        if case let .computer(id, cwd) = PersonalAgentOutputEnvironment(thread: thread.raw) {
            environmentID = id
            folder = Self.folder(cwd ?? thread.workspacePath)
        }
    }

    /// Text on one line, cut to a row's length.
    private static func line(_ value: String?) -> String? {
        let words = (value ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return words.count > 120 ? String(words.prefix(119)) + "…" : words
    }

    private static func folder(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        let last = path.split(separator: "/").last.map(String.init)
        return last?.isEmpty == false ? last : nil
    }
}

/// Where a dot's thread ran, as far as its metadata and the dot's computers tell.
enum PersonalAgentThreadPlace: Equatable, Sendable {
    case cloud
    case computer(name: String, folder: String?)
    /// It names a computer the dot's list does not hold.
    case unlistedComputer

    init?(_ thread: PersonalAgentThread, computers: [PersonalAgentComputer]?) {
        guard let environment = thread.environmentID else { return nil }
        guard let computer = computers?.first(where: { $0.id == environment }) else {
            self = .unlistedComputer
            return
        }
        self = computer.isCloud ? .cloud : .computer(name: computer.name, folder: thread.folder)
    }

    var text: String {
        switch self {
        case .cloud: L10n.string("Cloud computer")
        case let .computer(name, folder?): name + " · " + folder
        case let .computer(name, nil): name
        case .unlistedComputer: L10n.string("Another computer")
        }
    }
}

/// Reads a dot's bound threads and each one's metadata, a few at a time, newest first. Only threads the
/// transport itself listed for the dot are read (`boundThreads`, then `outputThread`).
enum PersonalAgentThreads {
    /// The most threads whose metadata one read asks for.
    static let limit = 50
    static let concurrentReads = 6

    static func read(from reader: any PersonalAgentClient, agent: PersonalAgent) async throws -> [PersonalAgentThread] {
        let bindings = Array(try await reader.boundThreads(for: agent).prefix(limit))
        var threads: [Int: PersonalAgentThread] = [:]
        var start = 0
        while start < bindings.count {
            let batch = Array(bindings[start..<min(start + concurrentReads, bindings.count)].enumerated())
                .map { ($0.offset + start, $0.element) }
            try await withThrowingTaskGroup(of: (Int, PersonalAgentThread).self) { group in
                for (index, binding) in batch {
                    group.addTask {
                        do {
                            let thread = try await reader.outputThread(binding.id, for: agent)
                            return (index, PersonalAgentThread(binding: binding, currentRoot: agent.rootThreadID, thread: thread))
                        } catch let failure as PersonalAgentFailure where failure != .accountChanged && failure != .signInRequired {
                            return (index, PersonalAgentThread(binding: binding, currentRoot: agent.rootThreadID, thread: nil,
                                                               failure: failure))
                        }
                    }
                }
                for try await (index, thread) in group { threads[index] = thread }
            }
            try Task.checkCancellation()
            start += concurrentReads
        }
        return sorted(bindings.indices.compactMap { threads[$0] })
    }

    /// Newest first by the thread's own update time, else when it was bound; the listing's order last.
    static func sorted(_ threads: [PersonalAgentThread]) -> [PersonalAgentThread] {
        threads.enumerated().sorted { a, b in
            let (da, db) = (a.element.updatedAt ?? a.element.createdAt ?? a.element.attachedAt,
                            b.element.updatedAt ?? b.element.createdAt ?? b.element.attachedAt)
            switch (da, db) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}
