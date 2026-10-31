import Foundation
import Observation

/// Something a dot produced, as its Outputs list it: a file it sent in its conversation, a file or
/// picture a task of its left on the dot's computer, or a web page it sent or a task made. Each keeps
/// where it came from, which is also how it opens.
struct PersonalAgentOutput: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A file of the dot's room, read as the conversation reads its attachments.
        case messageFile(PersonalAgentAttachment)
        /// A file on the dot's computer, never a path on this Mac.
        case remoteFile(PersonalAgentRemoteFile, isImage: Bool)
        /// A web page, opened in the browser when the person chooses it.
        case link(URL)
    }

    enum Source: Equatable, Sendable {
        case message(id: String)
        case task(threadID: String, turnID: String, itemID: String)
    }

    /// What tells one output from another: a room file by room and file, a remote file by its
    /// computer and path, a page by its provider identity or address.
    let id: String
    let title: String
    let kind: Kind
    let source: Source
    /// When it was produced, if the provider says; an output without a time is not given one.
    let producedAt: Date?
}

/// A file a task presented on the dot's computer: its absolute path there, the thread whose work
/// presented it, and the computer (`environmentID`) that thread's metadata named when it was read.
struct PersonalAgentRemoteFile: Equatable, Sendable {
    let path: String
    let threadID: String
    let environmentID: String?

    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// Where a thread's files are, as its metadata names it (`environments`): a computer, none that can be
/// told, or nothing said, in which case a verified parent's computer is the thread's.
enum PersonalAgentOutputEnvironment: Equatable, Sendable {
    case computer(id: String, cwd: String?)
    case unavailable
    case parents

    /// The provider's own choice: the first environment; a managed one only with exactly one
    /// connected computer, whose working folder is then not known. An empty or unreadable list is
    /// no computer, and is never inherited.
    init(thread raw: JSONValue) {
        guard let value = raw["environments"], value != .null else { self = .parents; return }
        guard case let .array(list) = value, let first = list.first else { self = .unavailable; return }
        let id = first["environmentId"]?.stringValue
        if id == "managed" || (id == nil && first["environmentConfigId"]?.stringValue != nil) {
            guard case let .array(connected)? = raw["connectedEnvironmentIds"], connected.count == 1,
                  let only = connected[0].stringValue, !only.isEmpty else { self = .unavailable; return }
            self = .computer(id: only, cwd: nil)
            return
        }
        guard let id, !id.isEmpty else { self = .unavailable; return }
        let cwd = first["cwd"]?.stringValue.flatMap { $0.hasPrefix("/") ? PersonalAgentOutputScan.normalized($0) : nil }
        self = .computer(id: id, cwd: cwd)
    }

    /// The parent a thread's metadata names: `parentThreadId` first, else the subagent spawn it came
    /// from. A source written as a plain string names no parent.
    static func parent(of raw: JSONValue) -> String? {
        if let explicit = raw["parentThreadId"]?.stringValue, !explicit.isEmpty { return explicit }
        return raw["source"]?["subAgent"]?["thread_spawn"]?["parent_thread_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The rules by which a thread's items and the dot's messages become outputs, and the threads a
/// thread's items say it spawned. Pure: the same pages always give the same outputs.
enum PersonalAgentOutputScan {
    /// Outputs of one turn's items. Agent messages count only once the turn completed; a picture and a
    /// connector's resources count once their own item did.
    static func outputs(of turn: CodexTurnState, items: [CodexItemState], threadID: String,
                        environment: PersonalAgentOutputEnvironment) -> [PersonalAgentOutput] {
        let computer: (id: String, cwd: String?)? = if case let .computer(id, cwd) = environment { (id, cwd) } else { nil }
        // When it was produced: its item's completion, else its turn's. A start is not a production time.
        let turnTime = turn.completedAt
        var outputs: [PersonalAgentOutput] = []
        func file(_ raw: String, title: String?, item: CodexItemState, isImage: Bool) {
            guard let path = resolve(raw, cwd: computer?.cwd) else { return }
            let remote = PersonalAgentRemoteFile(path: path, threadID: threadID, environmentID: computer?.id)
            let filesystem = computer.map { "environment:" + $0.id } ?? "thread:" + threadID
            outputs.append(.init(id: "path:" + filesystem + "\u{0}" + path, title: title ?? remote.name,
                                 kind: .remoteFile(remote, isImage: isImage),
                                 source: .task(threadID: threadID, turnID: turn.id, itemID: item.id),
                                 producedAt: item.completedAt ?? turnTime))
        }
        // What the turn's answers present, read once: a file they cite as a source is context, and a
        // link to the same file is not an output either.
        let answers: [(CodexItemState, [PersonalAgentPresentedReferences.PresentedReference])] = turn.status != .completed ? [] :
            items.compactMap { item in
                guard item.raw["type"]?.stringValue == "agentMessage", item.raw["phase"]?.stringValue != "commentary",
                      let text = item.raw["text"]?.stringValue else { return nil }
                return (item, PersonalAgentPresentedReferences.references(text))
            }
        var sources = Set<String>()
        for case let .citation(citation, "source"?, nil) in answers.flatMap(\.1) where citation.target == .file {
            if let path = resolve(citation.path, cwd: computer?.cwd) { sources.insert(path) }
        }
        for item in items {
            let raw = item.raw
            switch raw["type"]?.stringValue {
            case "agentMessage":
                guard let next = answers.first(where: { $0.0.id == item.id }) else { continue }
                for reference in next.1 {
                    switch reference {
                    case let .citation(citation, purpose, page):
                        // A citation of a source is context. A web document is a link; a live document
                        // and a page of the provider's Pages are neither a file nor a link here.
                        guard purpose == nil || purpose == "output" || purpose == "" else { continue }
                        switch citation.target {
                        case .file where page == nil:
                            file(citation.path, title: nil, item: item, isImage: false)
                        case let .web(address):
                            guard let url = webAddress(address.absoluteString) else { continue }
                            outputs.append(.init(id: "url:" + canonical(url), title: citation.label ?? pageName(url),
                                                 kind: .link(url), source: .task(threadID: threadID, turnID: turn.id, itemID: item.id),
                                                 producedAt: item.completedAt ?? turnTime))
                        default:
                            continue
                        }
                    case let .link(label, destination):
                        guard let path = filePath(destination),
                              !sources.contains(resolve(path, cwd: computer?.cwd) ?? "") else { continue }
                        file(path, title: label, item: item, isImage: false)
                    }
                }
            case "imageGeneration":
                guard raw["status"]?.stringValue == "completed", raw["failure"] == nil || raw["failure"] == .null,
                      let path = imagePath(raw) else { continue }
                file(path, title: nil, item: item, isImage: true)
            case "mcpToolCall":
                outputs += resources(of: item, turn: turn, threadID: threadID, at: item.completedAt ?? turnTime)
            default:
                continue
            }
        }
        return outputs
    }

    /// Where a picture was saved on the computer, as the provider reads it: `savedPath` first, then a
    /// `result` that is a path. One known only by its file ID is a stored asset, not a file there, and
    /// a result of picture data is no path: Base64 has no dot in its last part.
    private static func imagePath(_ raw: JSONValue) -> String? {
        if let saved = raw["savedPath"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved.hasPrefix("/") ? saved : nil
        }
        if let file = raw["fileId"]?.stringValue, !file.isEmpty { return nil }
        guard let result = raw["result"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              result.hasPrefix("/"), result.count <= 4096, !result.contains("\n"),
              result.split(separator: "/").last?.contains(".") == true else { return nil }
        return result
    }

    /// The resources a connector's call says it created or updated (`openai/resourceActivities`).
    /// Without that metadata, or with metadata that does not read, nothing is guessed from its text.
    private static func resources(of item: CodexItemState, turn: CodexTurnState, threadID: String,
                                  at time: Date?) -> [PersonalAgentOutput] {
        let raw = item.raw
        guard raw["status"]?.stringValue == "completed", raw["error"] == nil || raw["error"] == .null,
              let result = raw["result"], result != .null,
              let meta = result["_meta"]?["openai/resourceActivities"],
              meta["version"] == .integer(1), case let .array(list)? = meta["resources"] else { return [] }
        struct Resource { let id: String; let url: URL; let title: String?; let produced: Bool }
        var resources: [Resource] = []
        for value in list {
            guard let id = value["id"]?.stringValue, !id.isEmpty, let url = webAddress(value["url"]?.stringValue),
                  case let .array(activities)? = value["activities"], !activities.isEmpty else { return [] }
            let names = activities.compactMap(\.stringValue)
            guard names.count == activities.count, names.allSatisfy(["read", "created", "updated"].contains) else { return [] }
            if let title = value["title"], title != .null, title.stringValue == nil { return [] }
            resources.append(.init(id: id, url: url, title: value["title"]?.stringValue, produced: names.contains { $0 != "read" }))
        }
        let scope = raw["pluginId"]?.stringValue ?? "mcp-server:" + (raw["server"]?.stringValue ?? "")
        return resources.filter(\.produced).map { resource in
            let title = resource.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(id: "provider:" + scope + ":" + resource.id,
                         title: title.flatMap { $0.isEmpty ? nil : $0 } ?? pageName(resource.url),
                         kind: .link(resource.url), source: .task(threadID: threadID, turnID: turn.id, itemID: item.id),
                         producedAt: time)
        }
    }

    /// Outputs of a message the dot sent: its ready files, the links it attached, and the web pages its
    /// text links; the same page attached and linked is one output.
    static func outputs(of message: PersonalAgentMessage, roomID: String) -> [PersonalAgentOutput] {
        guard message.author == .agent, !message.isDeleted else { return [] }
        var outputs = message.attachments.compactMap { attachment -> PersonalAgentOutput? in
            if let url = attachment.url {
                return .init(id: "url:" + canonical(url), title: attachment.name, kind: .link(url),
                             source: .message(id: message.id), producedAt: message.createdAt)
            }
            guard attachment.type == "file", let file = attachment.fileID, !file.isEmpty, !attachment.isLoading else { return nil }
            return .init(id: "message-file:" + roomID + ":" + file, title: attachment.name, kind: .messageFile(attachment),
                         source: .message(id: message.id), producedAt: message.createdAt)
        }
        for case let .link(label, destination) in PersonalAgentPresentedReferences.references(message.text) {
            guard let url = webAddress(destination), !outputs.contains(where: { $0.id == "url:" + canonical(url) }) else { continue }
            outputs.append(.init(id: "url:" + canonical(url), title: label ?? pageName(url), kind: .link(url),
                                 source: .message(id: message.id), producedAt: message.createdAt))
        }
        return outputs
    }

    /// The threads a thread's items say it started: a subagent's start, or the receivers of a spawn.
    /// They are only candidates until their own metadata names this thread as their parent.
    static func spawnedThreads(in items: [CodexItemState]) -> [String] {
        var threads: [String] = []
        for item in items {
            let raw = item.raw
            switch raw["type"]?.stringValue {
            case "subAgentActivity" where raw["kind"]?.stringValue == "started":
                if let id = raw["agentThreadId"]?.stringValue, !id.isEmpty { threads.append(id) }
            case "collabAgentToolCall" where raw["tool"]?.stringValue == "spawnAgent":
                if case let .array(ids)? = raw["receiverThreadIds"] {
                    threads += ids.compactMap { $0.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
                }
            default:
                continue
            }
        }
        return threads
    }

    /// A web address an output may open: HTTP(S), with no user or password in it.
    static func webAddress(_ raw: String?) -> URL? {
        guard let raw, let components = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host?.isEmpty == false,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    /// An address that names the computer it is opened on (localhost, a loopback or unspecified
    /// address). A dot's output names its own computer by it, never this Mac, so it does not open here.
    static func namesItsOwnComputer(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "::"
            || host == "0.0.0.0" || host.hasPrefix("127.") || host.hasPrefix("::ffff:127.")
    }

    /// A Markdown destination that names a file: a path, `sandbox:` or `file://`; any other scheme
    /// is not a file.
    private static func filePath(_ destination: String) -> String? {
        var value = destination
        if value.hasPrefix("sandbox:") { value.removeFirst("sandbox:".count) }
        else if value.lowercased().hasPrefix("file://") {
            guard let url = URL(string: value), url.host == nil || url.host == "" else { return nil }
            return url.path
        }
        if value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil { return nil }
        if value.hasPrefix("#") { return nil }
        let path = value.split(separator: "#", maxSplits: 1).first.map(String.init) ?? value
        return path.removingPercentEncoding ?? path
    }

    /// An absolute path, or a relative one under the thread's known working folder; nothing else.
    static func resolve(_ raw: String, cwd: String?) -> String? {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return normalized(path) }
        guard let cwd else { return nil }
        return normalized(cwd + "/" + path)
    }

    /// `.` and `..` removed and slashes collapsed, as written; nothing on this Mac is consulted.
    static func normalized(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast(); continue }
            parts.append(part)
        }
        guard !parts.isEmpty else { return nil }
        return "/" + parts.joined(separator: "/")
    }

    private static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.fragment = nil
        if components.path.count > 1, components.path.hasSuffix("/") { components.path.removeLast() }
        return components.url?.absoluteString ?? url.absoluteString
    }

    private static func pageName(_ url: URL) -> String {
        let host = (url.host ?? "").replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
        return url.path == "/" || url.path.isEmpty ? host : host + url.path
    }
}

/// The selected dot's Outputs: what its conversation's messages and its tasks' work presented, read a
/// part at a time and never claimed to be all of it. The conversation's own pages feed it as they are
/// read; earlier messages and each task's earlier work are read only when the person asks, from
/// their own cursors, without moving the conversation.
@MainActor @Observable
final class PersonalAgentOutputs {
    enum ScopePhase: Equatable {
        case idle, loading, loaded
        case failed(PersonalAgentFailure)
    }

    /// Newest first; outputs without a time after those with one, in the order they were found.
    private(set) var items: [PersonalAgentOutput] = []
    private(set) var scope: ScopePhase = .idle
    private(set) var isReading = false
    /// Tasks whose work was checked at least in part.
    private(set) var checkedTasks = 0
    /// More of the tasks' work, or earlier messages, remain to be checked.
    private(set) var hasEarlier = false
    /// Every message of the conversation was checked.
    private(set) var checkedAllMessages = false
    /// Parts that could not be read; their outputs are missing until Try again reads them.
    private(set) var failure: PersonalAgentFailure?

    private struct Unit: Equatable { let threadID: String; let cursor: String? }
    /// What a look reads: the first page of each task, earlier pages and messages, or what failed.
    private enum Pass { case first, earlier, retry }
    private struct Child: Hashable { let threadID: String; let parentID: String }
    private struct Stamp { let deleted: Bool; let time: Date? }

    let roomID: String
    @ObservationIgnored private var roomEntries: [String: [PersonalAgentOutput]] = [:]
    /// What was last seen of each message, kept after its outputs are gone, so an older read of a
    /// deleted or changed message never brings its outputs back.
    @ObservationIgnored private var stamps: [String: Stamp] = [:]
    @ObservationIgnored private var taskEntries: [String: [PersonalAgentOutput]] = [:]
    @ObservationIgnored private var queue: [Unit] = []
    @ObservationIgnored private var failedUnits: [Unit] = []
    @ObservationIgnored private var failedChildren: [Child] = []
    @ObservationIgnored private var environments: [String: PersonalAgentOutputEnvironment] = [:]
    @ObservationIgnored private var parents: [String: String] = [:]
    @ObservationIgnored private var known: Set<String> = []
    /// Threads whose metadata named another parent than the one that spawned them, by that pair.
    @ObservationIgnored private var notChildren: Set<Child> = []
    @ObservationIgnored private var cursors: [String: Set<String>] = [:]
    @ObservationIgnored private var checked: Set<String> = []
    /// The conversation's earlier cursor when the person first looked further back, then this list's own.
    @ObservationIgnored private var roomCursor: String?
    @ObservationIgnored private var roomCursorTaken = false
    @ObservationIgnored private var roomCursors: Set<String> = []
    /// The earlier page of messages last asked for could not be read; Try again reads it.
    @ObservationIgnored private var roomFailed = false
    @ObservationIgnored var task: Task<Void, Never>?

    /// How many tasks' first pages the first look reads, how many further pages each look further back
    /// reads, and how many item pages a turn may take.
    static let firstPages = 8
    static let unitsPerRead = 4
    nonisolated static let itemPagesPerTurn = 20

    init(roomID: String) { self.roomID = roomID }

    // MARK: The conversation's messages

    /// Messages a read of the room returned. Only these are looked at; a message a page leaves out
    /// keeps its outputs, a deleted one loses them for good, and an older read of a message changes
    /// nothing.
    func noteRoom(_ messages: [PersonalAgentMessage]) {
        var changed = false
        for message in messages {
            let time = message.updatedAt ?? message.createdAt
            if let stamp = stamps[message.id] {
                if stamp.deleted { continue }
                if !message.isDeleted, let old = stamp.time, let new = time, new < old { continue }
            }
            stamps[message.id] = .init(deleted: message.isDeleted, time: time)
            let outputs = PersonalAgentOutputScan.outputs(of: message, roomID: roomID)
            if (roomEntries[message.id] ?? []) != outputs {
                roomEntries[message.id] = outputs.isEmpty ? nil : outputs
                changed = true
            }
        }
        if changed { publish() }
    }

    /// The conversation reached its first message, or has an earlier page to read.
    func noteConversation(before: String?, loaded: Bool) {
        guard loaded, !roomCursorTaken else { return }
        if before == nil, !checkedAllMessages { checkedAllMessages = true; updateEarlier() }
    }

    // MARK: Reading

    /// Reads the dot's tasks and the first of their work, once; later calls change nothing.
    func start(reader: any PersonalAgentClient, agent: PersonalAgent, conversationBefore: String?,
               isCurrent: @escaping @MainActor () -> Bool, failed: @escaping @MainActor (Error) -> Void) {
        guard scope == .idle, task == nil else { return }
        run(reader: reader, agent: agent, conversationBefore: conversationBefore, pass: .first, isCurrent: isCurrent, failed: failed)
    }

    /// Reads further back: an earlier page of messages and the next pages of the tasks' work.
    func readEarlier(reader: any PersonalAgentClient, agent: PersonalAgent, conversationBefore: String?,
                     isCurrent: @escaping @MainActor () -> Bool, failed: @escaping @MainActor (Error) -> Void) {
        guard task == nil else { return }
        run(reader: reader, agent: agent, conversationBefore: conversationBefore, pass: .earlier, isCurrent: isCurrent, failed: failed)
    }

    /// Reads again what failed: the tasks' list, a task's page or a child that could not be checked.
    func retry(reader: any PersonalAgentClient, agent: PersonalAgent, conversationBefore: String?,
               isCurrent: @escaping @MainActor () -> Bool, failed: @escaping @MainActor (Error) -> Void) {
        guard task == nil else { return }
        if case .failed = scope { scope = .idle }
        let units = failedUnits
        queue = units + queue
        failedUnits = []
        failure = nil
        let children = failedChildren
        failedChildren = []
        run(reader: reader, agent: agent, conversationBefore: conversationBefore, pass: .retry, retrying: units, children: children,
            isCurrent: isCurrent, failed: failed)
    }

    func cancel() {
        task?.cancel()
        task = nil
        isReading = false
    }

    private func run(reader: any PersonalAgentClient, agent: PersonalAgent, conversationBefore: String?, pass: Pass,
                     retrying: [Unit] = [], children: [Child] = [], isCurrent: @escaping @MainActor () -> Bool,
                     failed: @escaping @MainActor (Error) -> Void) {
        isReading = true
        task = Task { [weak self] in
            await self?.read(reader: reader, agent: agent, conversationBefore: conversationBefore, pass: pass,
                             retrying: retrying, children: children, isCurrent: isCurrent, failed: failed)
            guard let self, isCurrent() else { return }
            self.task = nil
            self.isReading = false
            self.updateEarlier()
        }
    }

    private func read(reader: any PersonalAgentClient, agent: PersonalAgent, conversationBefore: String?, pass: Pass,
                      retrying: [Unit], children: [Child], isCurrent: @escaping @MainActor () -> Bool,
                      failed: @escaping @MainActor (Error) -> Void) async {
        func fail(_ error: Error) -> PersonalAgentFailure {
            let value = error as? PersonalAgentFailure ?? .network
            failed(error)
            return value
        }
        if pass == .earlier || (pass == .retry && roomFailed) { await readEarlierMessages(reader: reader, agent: agent, conversationBefore: conversationBefore,
                                            isCurrent: isCurrent, fail: fail) }
        guard isCurrent() else { return }
        if scope != .loaded {
            scope = .loading
            do {
                let threads = try await reader.outputThreads(for: agent)
                guard isCurrent() else { return }
                for thread in threads where known.insert(thread).inserted { queue.append(.init(threadID: thread, cursor: nil)) }
                scope = .loaded
            } catch {
                guard isCurrent() else { return }
                scope = .failed(fail(error))
                return
            }
        }
        for child in children {
            await admit(child, reader: reader, agent: agent, isCurrent: isCurrent, fail: fail)
            guard isCurrent() else { return }
        }
        // The first look and Try again read only first pages and what failed; earlier pages wait.
        var budget = pass == .earlier ? Self.unitsPerRead : Self.firstPages + retrying.count
        while budget > 0, let index = queue.firstIndex(where: { pass == .earlier || $0.cursor == nil || retrying.contains($0) }) {
            let unit = queue.remove(at: index)
            budget -= 1
            do {
                try await read(unit, reader: reader, agent: agent, isCurrent: isCurrent, fail: fail)
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent() else { return }
                failedUnits.append(unit)
                failure = fail(error)
                if failure == .accountChanged || failure == .signInRequired { return }
            }
            guard isCurrent() else { return }
        }
    }

    /// One page of a task's turns, read and turned into outputs away from the main actor; only what it
    /// found is applied here, once the whole page was read.
    private func read(_ unit: Unit, reader: any PersonalAgentClient, agent: PersonalAgent,
                      isCurrent: @escaping @MainActor () -> Bool, fail: (Error) -> PersonalAgentFailure) async throws {
        let thread = unit.threadID
        try await learnEnvironment(of: thread, reader: reader, agent: agent, isCurrent: isCurrent)
        let page = try await Self.read(unit.threadID, cursor: unit.cursor, seen: cursors[thread] ?? [],
                                       environment: resolvedEnvironment(of: thread), reader: reader, agent: agent)
        guard isCurrent() else { throw CancellationError() }
        if let cursor = unit.cursor { cursors[thread, default: []].insert(cursor) }
        for (turn, outputs) in page.outputs { taskEntries[thread + "\u{0}" + turn] = outputs.isEmpty ? nil : outputs }
        if checked.insert(thread).inserted { checkedTasks = checked.count }
        if let next = page.nextCursor { queue.append(.init(threadID: thread, cursor: next)) }
        publish()
        for child in page.spawned where !known.contains(child) {
            await admit(.init(threadID: child, parentID: thread), reader: reader, agent: agent, isCurrent: isCurrent, fail: fail)
            guard isCurrent() else { throw CancellationError() }
        }
    }

    /// The computer a thread's files are on, from its metadata; when it names none, from the parent its
    /// metadata names, once the transport verified that parent among the dot's threads. A listed child
    /// inherits as a spawned one does.
    private func learnEnvironment(of thread: String, reader: any PersonalAgentClient, agent: PersonalAgent,
                                  isCurrent: @escaping @MainActor () -> Bool, visited: Set<String> = []) async throws {
        if environments[thread] == nil {
            let metadata = try await reader.outputThread(thread, for: agent)
            guard isCurrent() else { throw CancellationError() }
            let named = PersonalAgentOutputEnvironment(thread: metadata.raw)
            if named == .parents, let parent = PersonalAgentOutputEnvironment.parent(of: metadata.raw), parent != thread,
               known.contains(parent), parents[thread] == nil {
                let verified = try await reader.outputChild(thread, of: parent, for: agent)
                guard isCurrent() else { throw CancellationError() }
                if verified != nil { parents[thread] = parent }
            }
            environments[thread] = named
        }
        if environments[thread] == .parents, let parent = parents[thread], !visited.contains(parent) {
            try await learnEnvironment(of: parent, reader: reader, agent: agent, isCurrent: isCurrent,
                                       visited: visited.union([thread]))
        }
    }

    private struct PageRead: Sendable {
        let outputs: [(turn: String, outputs: [PersonalAgentOutput])]
        let spawned: [String]
        let nextCursor: String?
    }

    /// One page of a thread's turns and each turn's items to their end. A repeated cursor, or more
    /// promised with nothing given, is not the provider's history.
    private nonisolated static func read(_ thread: String, cursor: String?, seen: Set<String>,
                                         environment: PersonalAgentOutputEnvironment,
                                         reader: any PersonalAgentClient, agent: PersonalAgent) async throws -> PageRead {
        let page = try await reader.outputTurns(thread, cursor: cursor, for: agent)
        if let next = page.nextCursor {
            guard next != cursor, !seen.contains(next), !page.turns.isEmpty else { throw PersonalAgentFailure.invalidResponse }
        }
        var outputs: [(turn: String, outputs: [PersonalAgentOutput])] = []
        var spawned: [String] = []
        for turn in page.turns.reversed() {
            var items: [CodexItemState] = []
            var itemCursor: String?
            var itemCursors = Set<String>()
            var pages = 0
            repeat {
                try Task.checkCancellation()
                guard pages < itemPagesPerTurn else { throw PersonalAgentFailure.tooLarge }
                let itemPage = try await reader.outputItems(thread, turnID: turn.id, cursor: itemCursor, for: agent)
                guard itemPage.entries.allSatisfy({ $0.turnID == turn.id }) else { throw PersonalAgentFailure.invalidResponse }
                items += itemPage.entries.map(\.item)
                if let next = itemPage.nextCursor {
                    if let itemCursor { itemCursors.insert(itemCursor) }
                    guard next != itemCursor, !itemCursors.contains(next), !itemPage.entries.isEmpty else {
                        throw PersonalAgentFailure.invalidResponse
                    }
                }
                itemCursor = itemPage.nextCursor
                pages += 1
            } while itemCursor != nil
            outputs.append((turn.id, PersonalAgentOutputScan.outputs(of: turn, items: items, threadID: thread,
                                                                    environment: environment)))
            spawned += PersonalAgentOutputScan.spawnedThreads(in: items)
        }
        return .init(outputs: outputs, spawned: spawned, nextCursor: page.nextCursor)
    }

    /// A spawned thread joins only when its own metadata names the thread that spawned it.
    private func admit(_ child: Child, reader: any PersonalAgentClient, agent: PersonalAgent,
                       isCurrent: @escaping @MainActor () -> Bool, fail: (Error) -> PersonalAgentFailure) async {
        guard !known.contains(child.threadID), !notChildren.contains(child) else { return }
        do {
            let read = try await reader.outputChild(child.threadID, of: child.parentID, for: agent)
            guard isCurrent() else { return }
            // Its metadata names another parent: it is not this thread's child, and nothing is missing.
            guard let metadata = read else { notChildren.insert(child); return }
            guard known.insert(child.threadID).inserted else { return }
            environments[child.threadID] = PersonalAgentOutputEnvironment(thread: metadata.raw)
            parents[child.threadID] = child.parentID
            queue.append(.init(threadID: child.threadID, cursor: nil))
        } catch {
            guard isCurrent() else { return }
            failedChildren.append(child)
            failure = fail(error)
        }
    }

    /// A thread's computer, or its verified parent's when its metadata names none, never in a cycle.
    private func resolvedEnvironment(of thread: String) -> PersonalAgentOutputEnvironment {
        var current = thread
        var visited: Set<String> = []
        while visited.insert(current).inserted {
            switch environments[current] {
            case .parents?:
                guard let parent = parents[current] else { return .unavailable }
                current = parent
            case let value?: return value
            case nil: return .unavailable
            }
        }
        return .unavailable
    }

    private func readEarlierMessages(reader: any PersonalAgentClient, agent: PersonalAgent, conversationBefore: String?,
                                     isCurrent: @escaping @MainActor () -> Bool, fail: (Error) -> PersonalAgentFailure) async {
        if !roomCursorTaken {
            guard !checkedAllMessages, let start = conversationBefore else { return }
            roomCursor = start
            roomCursorTaken = true
        }
        guard let cursor = roomCursor, roomCursors.insert(cursor).inserted else {
            roomCursor = nil
            return
        }
        do {
            let page = try await reader.messages(for: agent, before: cursor)
            guard isCurrent() else { return }
            roomFailed = false
            noteRoom(page.messages)
            roomCursor = page.before
            if page.before == nil || page.messages.isEmpty { roomCursor = nil; checkedAllMessages = true }
        } catch {
            guard isCurrent() else { return }
            roomCursors.remove(cursor)
            roomFailed = true
            failure = fail(error)
        }
    }

    private func updateEarlier() {
        let more = !queue.isEmpty || !checkedAllMessages
        if hasEarlier != more { hasEarlier = more }
    }

    /// The list again from what was found: each output once, a picture over the plain file at the same
    /// place, newest first.
    private func publish() {
        var merged: [PersonalAgentOutput] = []
        var index: [String: Int] = [:]
        for output in Array(roomEntries.values.joined()) + Array(taskEntries.values.joined()) {
            if let at = index[output.id] {
                let existing = merged[at]
                if case .remoteFile(_, false) = existing.kind, case .remoteFile(_, true) = output.kind { merged[at] = output }
                else if let new = output.producedAt, existing.producedAt.map({ new > $0 }) ?? true { merged[at] = output }
                continue
            }
            index[output.id] = merged.count
            merged.append(output)
        }
        merged.sort { a, b in
            switch (a.producedAt, b.producedAt) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.id < b.id
            }
        }
        if merged != items { items = merged }
    }
}
