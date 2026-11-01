import Foundation
import YardletAgentTools

// The session tools that read the person's personal agents (docs/PERSONAL_AGENTS.md, "Agents reading
// the dots"): `list_personal_agents`, `read_personal_agent` and `read_personal_agent_thread`. They read
// through the app's watch (`PersonalAgentWatch.reading`), the reader of the account a window last opened
// the dots with, so they use the same login and runtime and add no credential path. They only read:
// nothing is sent, answered, uploaded or marked read, and no turn starts. A thread is read only when the
// transport itself listed it for that dot and account, in the dot's Activity or its bound threads.
extension AppModel {
    func callPersonalAgentTool(named name: String, arguments: JSONValue,
                               defaults: UserDefaults = .yardlet) async -> AgentToolResult {
        guard PersonalAgentNotificationPreference.isOn(in: defaults), let reading = personalAgentWatch.reading else {
            return .failure("Yardlet is not following any personal agents now. It reads the dots of the account last "
                + "opened in Personal agents while Settings > Notifications > Personal agent messages is on. Ask the "
                + "person to open Personal agents in Yardlet's sidebar.", .unreachable, retry: .no)
        }
        do {
            switch name {
            case SessionToolCatalog.listPersonalAgents:
                return try await listPersonalAgents(reading.reader, accountChoiceID: reading.accountChoiceID)
            case SessionToolCatalog.readPersonalAgent:
                return try await readPersonalAgent(arguments, reader: reading.reader)
            default:
                return try await readPersonalAgentThread(arguments, reader: reading.reader)
            }
        } catch let result as PersonalAgentToolRefusal {
            return result.result
        } catch {
            return Self.personalAgentFailure(error)
        }
    }

    /// The person's own words for what went wrong, for an agent to act on.
    private static func personalAgentFailure(_ error: Error) -> AgentToolResult {
        switch error as? PersonalAgentFailure {
        case .signInRequired?, .accountChanged?, .runtimeUnavailable?, .stopped?:
            return .failure("The ChatGPT sign-in Yardlet reads the personal agents with is not available now. Ask the "
                + "person to open Personal agents in Yardlet's sidebar.", .unreachable, retry: .no)
        case .accessDenied?:
            return .failure("Not read: that thread is not among the agent's Activity tasks or listed threads. Use a "
                + "threadId from list_personal_agents.", .notFound, retry: .withChanges)
        case .missing?:
            return .failure("Not read: the provider no longer has that thread.", .notFound, retry: .no)
        case .network?, .unavailable?:
            return .failure("Dots could not be reached. Try again later.", .unreachable, retry: .later)
        default:
            return .failure("Dots answered in a way Yardlet cannot read.", .unreachable, retry: .later)
        }
    }

    // MARK: list_personal_agents

    private func listPersonalAgents(_ reader: any PersonalAgentClient, accountChoiceID: String) async throws -> AgentToolResult {
        let agents = try await reader.agents()
        var entries: [PersonalAgentToolEntry] = []
        for agent in agents {
            async let activity = Self.attempt { try await reader.activity(for: agent, cursor: nil) }
            async let computers = Self.attempt { try await reader.computers(for: agent) }
            async let threads = Self.attempt { try await PersonalAgentThreads.read(from: reader, agent: agent) }
            let (activityRead, computersRead, threadsRead) = try await (activity, computers, threads)
            var entry = PersonalAgentToolEntry(agent: agent.id.agentID, name: agent.name, primary: agent.isPrimary ? true : nil,
                                               paused: agent.isPaused ? true : nil)
            entry.unread = personalAgentWatch.unread[agent.id].map { $0 == .request ? "asks for input" : "message" }
            switch activityRead {
            case let .success(page):
                entry.activity = page.items.map {
                    .init(threadId: $0.id, title: $0.title, status: PersonalAgentToolEntry.status($0),
                          updatedAt: $0.updatedAt.map(SessionToolText.iso))
                }
                entry.moreActivity = page.cursor == nil ? nil : true
            case .failure: entry.activityUnavailable = true
            }
            switch threadsRead {
            case let .success(values):
                let known = try? computersRead.get()
                entry.threads = values.map { PersonalAgentToolEntry.Thread($0, computers: known) }
            case .failure: entry.threadsUnavailable = true
            }
            entries.append(entry)
        }
        let account = connections.choices(for: [.codex]).first { $0.id == accountChoiceID }?.title
        let listing = PersonalAgentToolListing(
            account: account, agents: entries,
            note: entries.isEmpty ? "This account has no personal agents."
                : "Threads of kind task are Codex tasks the agent started; their agent loop ran in the provider's "
                    + "cloud, and ranOn names where their commands ran. " + SessionToolText.untrustedNote)
        return .text(SessionToolText.json(listing))
    }

    /// A part's read, kept apart so one failing part leaves the others; a login that ended ends them all.
    nonisolated private static func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> Result<T, Error> {
        do { return .success(try await body()) } catch let failure as PersonalAgentFailure
            where [.signInRequired, .accountChanged, .runtimeUnavailable, .stopped].contains(failure) {
            throw failure
        } catch {
            return .failure(error)
        }
    }

    // MARK: read_personal_agent

    private func readPersonalAgent(_ arguments: JSONValue, reader: any PersonalAgentClient) async throws -> AgentToolResult {
        let agent = try await personalAgent(arguments, reader: reader)
        let cursor = try PersonalAgentToolCursor(arguments["cursor"]?.stringValue)
        let page = try await reader.messages(for: agent, before: cursor?.page)
        var messages = page.messages
        if let before = cursor?.before {
            guard let end = messages.firstIndex(where: { $0.id == before }) else { throw PersonalAgentToolRefusal.staleCursor }
            messages = Array(messages[..<end])
        }
        let lines = messages.map { Self.line(for: $0, agent: agent, in: page.messages) }
        // The newest messages first; older ones of the page wait for the cursor.
        var shown: [String] = [], total = 0
        for line in lines.reversed() {
            guard shown.isEmpty || total + line.count + 1 <= SessionToolPolicy.readCharacterLimit else { break }
            shown.insert(line, at: 0)
            total += line.count + 1
        }
        let left = messages.count - shown.count
        let next: PersonalAgentToolCursor? = left > 0 ? .init(page: cursor?.page, before: messages[left].id)
            : page.before.map { .init(page: $0, before: nil) }
        var head = "Personal agent \(agent.name) (\(agent.id.agentID)): \(shown.count) message(s), oldest first."
        if let next { head += " Pass cursor \"\(next.text)\" for earlier messages." } else { head += " This is the start of the conversation." }
        head += " " + SessionToolText.untrustedNote
        let body = shown.isEmpty ? "(No messages.)" : shown.joined(separator: "\n")
        return .text(head + "\n\n" + body)
    }

    static let personalAgentMessageLimit = 4_000

    /// One message on its own lines: time, sender, text, attachments and replies.
    private static func line(for message: PersonalAgentMessage, agent: PersonalAgent, in page: [PersonalAgentMessage]) -> String {
        let sender = switch message.author {
        case .person: "Person"
        case .agent: agent.name
        case let .other(name): name
        case .unknown: "Someone"
        }
        var head = message.createdAt.map { "[\(SessionToolText.iso($0))] " } ?? ""
        head += sender
        if let parent = message.replyToMessageID {
            let quoted = message.replyPreview.map { preview -> String in
                preview.isDeleted ? "a deleted message" : "\"" + String(preview.text.prefix(80)) + "\""
            } ?? "message \(parent)"
            head += " (reply to \(quoted))"
        }
        guard !message.isDeleted else { return head + ": (deleted)" }
        var text = message.text
        if text.count > personalAgentMessageLimit { text = String(text.prefix(personalAgentMessageLimit)) + " [cut]" }
        var line = head + ": " + text
        let names = message.attachments.map(\.name).filter { !$0.isEmpty }
        if !names.isEmpty { line += "\n  Attachments: " + names.joined(separator: ", ") }
        let replies = page.filter { $0.id != message.id && ($0.replyRootMessageID ?? $0.replyToMessageID) == message.id }.count
        if replies > 0 { line += "\n  Replies on this page: \(replies)" }
        if PersonalAgentWatch.asks(message) { line += "\n  Asks the person for input." }
        if message.isUnsupported { line += "\n  (A message Yardlet cannot show.)" }
        return line
    }

    // MARK: read_personal_agent_thread

    private func readPersonalAgentThread(_ arguments: JSONValue, reader: any PersonalAgentClient) async throws -> AgentToolResult {
        let agent = try await personalAgent(arguments, reader: reader)
        guard let threadID = arguments["thread_id"]?.stringValue?.trimmingCharacters(in: .whitespaces), !threadID.isEmpty else {
            throw PersonalAgentToolRefusal.missing("thread_id")
        }
        let cursor = try PersonalAgentToolCursor(arguments["cursor"]?.stringValue)
        let reading = PersonalAgentActivityReading(
            agentID: agent.id, activity: .init(id: threadID, title: "", status: .unknown, outcome: .unknown, updatedAt: nil, preview: nil),
            isBoundThread: try await Self.isBoundThread(threadID, of: agent, reader: reader))
        let thread = try await reading.thread(from: reader, for: agent)
        let turns = try await reading.turns(after: cursor?.page, from: reader, for: agent)
        var history = PersonalAgentActivityHistory(threadID: threadID)
        history.begin(thread)
        let added = try history.apply(turns: turns, after: nil)
        // Each turn's first page of items, a few at a time; a turn that cannot be read is said so.
        let pages = await withTaskGroup(of: (String, Result<CodexItemPage, Error>).self) { group in
            for turnID in added {
                group.addTask {
                    do { return (turnID, .success(try await reading.items(of: turnID, after: nil, from: reader, for: agent))) }
                    catch { return (turnID, .failure(error)) }
                }
            }
            var values: [String: Result<CodexItemPage, Error>] = [:]
            for await (turnID, page) in group { values[turnID] = page }
            return values
        }
        var unreadTurns = 0
        for turnID in added {
            switch pages[turnID] {
            case let .success(page)?:
                do { try history.apply(items: page, of: turnID, after: nil) } catch { unreadTurns += 1 }
            case let .failure(error)?:
                if let failure = error as? PersonalAgentFailure, [.signInRequired, .accountChanged].contains(failure) { throw failure }
                unreadTurns += 1
            case nil:
                unreadTurns += 1
            }
        }
        let presentation = CodexConversationProjection.presentation(history.state, workspaceURL: URL(filePath: "/"),
                                                                    historySelection: nil)
        guard let conversation = SessionToolText.conversation(
            presentation, workspaceURL: nil, turns: SessionToolPolicy.readMaximumTurns,
            cursor: cursor?.before.map { SessionToolText.cursorPrefix + $0 })
        else { throw PersonalAgentToolRefusal.staleCursor }
        let next: PersonalAgentToolCursor?
        if let local = conversation.cursor {
            next = .init(page: cursor?.page, before: String(local.dropFirst(SessionToolText.cursorPrefix.count)))
        } else {
            next = turns.nextCursor.map { .init(page: $0, before: nil) }
        }
        let summary = PersonalAgentThread(binding: .init(id: threadID, parentID: nil, attachedAt: nil),
                                          currentRoot: agent.rootThreadID, thread: thread)
        var head = SessionToolText.json(PersonalAgentToolThreadHead(
            agent: agent.id.agentID, threadId: threadID, title: summary.title ?? summary.preview,
            status: PersonalAgentToolEntry.status(thread.status), createdAt: thread.createdAt.map(SessionToolText.iso),
            updatedAt: thread.updatedAt.map(SessionToolText.iso)))
        head += "\n\nShowing \(conversation.shownTurns) turn(s), oldest first."
        if unreadTurns > 0 { head += " The work of \(unreadTurns) turn(s) could not be read." }
        if history.turns.contains(where: { $0.itemsNextCursor != nil }) {
            head += " Some turns hold more work than their first \(PersonalAgentActivityHistory.itemPageSize) items shown."
        }
        if let next { head += " Pass cursor \"\(next.text)\" for earlier turns." }
        head += " " + SessionToolText.untrustedNote
        let body = conversation.text.isEmpty ? "(No turns.)" : conversation.text
        return .text(head + "\n\n" + body)
    }

    /// Whether `threadID` is one of the dot's bound threads, read with the bound-thread reads; otherwise
    /// it is looked for in the dot's Activity, a few pages back, so the Activity reads admit it. Neither
    /// widens what the transport admits: it checks each read against what it listed itself.
    private static func isBoundThread(_ threadID: String, of agent: PersonalAgent,
                                      reader: any PersonalAgentClient) async throws -> Bool {
        if try await reader.boundThreads(for: agent).contains(where: { $0.id == threadID }) { return true }
        var cursor: String?
        for _ in 0..<4 {
            let page = try await reader.activity(for: agent, cursor: cursor)
            if page.items.contains(where: { $0.id == threadID }) { return false }
            guard let next = page.cursor else { break }
            cursor = next
        }
        throw PersonalAgentFailure.accessDenied
    }

    /// The agent an `agent` argument names: its reference, or its name when one agent has it.
    private func personalAgent(_ arguments: JSONValue, reader: any PersonalAgentClient) async throws -> PersonalAgent {
        guard let reference = arguments["agent"]?.stringValue?.trimmingCharacters(in: .whitespaces), !reference.isEmpty else {
            throw PersonalAgentToolRefusal.missing("agent")
        }
        let agents = try await reader.agents()
        if let agent = agents.first(where: { $0.id.agentID == reference }) { return agent }
        let named = agents.filter { $0.name.compare(reference, options: [.caseInsensitive]) == .orderedSame }
        guard named.count == 1 else { throw PersonalAgentToolRefusal.unknownAgent(named.isEmpty ? 0 : named.count) }
        return named[0]
    }
}

/// A refusal of the call's own arguments, answered as such.
private enum PersonalAgentToolRefusal: Error {
    case missing(String)
    case unknownAgent(Int)
    case staleCursor

    var result: AgentToolResult {
        switch self {
        case let .missing(name):
            .failure("Not read: \(name) is required.", .invalidArguments, retry: .withChanges)
        case let .unknownAgent(count):
            .failure(count > 1 ? "Not read: several personal agents have that name; give its agent reference."
                : "Not read: no personal agent has that reference or name. list_personal_agents lists them.",
                     .notFound, retry: .withChanges)
        case .staleCursor:
            .failure("Not read: that cursor names nothing this read found. Read again without cursor.",
                     .invalidArguments, retry: .withChanges)
        }
    }
}

/// Where the next read starts: the provider's page (nil for the newest) and, when one read of it did not
/// fit, the first message or turn already shown from it. Opaque to the model.
struct PersonalAgentToolCursor: Codable, Equatable {
    var page: String?
    var before: String?

    init(page: String?, before: String?) {
        self.page = page
        self.before = before
    }

    /// Nil for no cursor; a value that is not one of these cursors is refused.
    fileprivate init?(_ text: String?) throws {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.page != nil || value.before != nil
        else { throw PersonalAgentToolRefusal.staleCursor }
        self = value
    }

    var text: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct PersonalAgentToolListing: Encodable {
    var account: String?
    var agents: [PersonalAgentToolEntry]
    var note: String
}

private struct PersonalAgentToolThreadHead: Encodable {
    var agent: String
    var threadId: String
    var title: String?
    var status: String?
    var createdAt: String?
    var updatedAt: String?
}

private struct PersonalAgentToolEntry: Encodable {
    struct Activity: Encodable {
        var threadId: String
        var title: String
        var status: String?
        var updatedAt: String?
    }

    struct Thread: Encodable {
        var threadId: String
        /// `conversation` for one of the dot's conversation roots, `task` for a Codex task one started.
        var kind: String
        var current: Bool?
        var parentThreadId: String?
        var title: String?
        var status: String?
        var createdAt: String?
        var updatedAt: String?
        /// `cloud`, a computer's name, or `another computer` for one the dot's list does not hold.
        var ranOn: String?
        var folder: String?
        var unreadable: Bool?

        init(_ thread: PersonalAgentThread, computers: [PersonalAgentComputer]?) {
            threadId = thread.id
            kind = thread.kind == .task ? "task" : "conversation"
            current = thread.isCurrentRoot ? true : nil
            parentThreadId = thread.parentID
            title = thread.title ?? thread.preview
            status = PersonalAgentToolEntry.status(thread.status)
            createdAt = thread.createdAt.map(SessionToolText.iso)
            updatedAt = (thread.updatedAt ?? thread.attachedAt).map(SessionToolText.iso)
            unreadable = thread.failure == nil ? nil : true
            switch PersonalAgentThreadPlace(thread, computers: computers) {
            case .cloud?: ranOn = "cloud"
            case let .computer(name, folder)?: ranOn = name; self.folder = folder
            case .unlistedComputer?: ranOn = "another computer"
            case nil: break
            }
        }
    }

    var agent: String
    var name: String
    var primary: Bool?
    var paused: Bool?
    /// Messages from the agent not yet seen in Yardlet: `message`, or `asks for input`.
    var unread: String?
    var activity: [Activity]?
    var moreActivity: Bool?
    var activityUnavailable: Bool?
    var threads: [Thread]?
    var threadsUnavailable: Bool?

    init(agent: String, name: String, primary: Bool?, paused: Bool?) {
        self.agent = agent
        self.name = name
        self.primary = primary
        self.paused = paused
    }

    static func status(_ activity: PersonalAgentActivity) -> String? {
        switch (activity.status, activity.outcome) {
        case (.running, _): "running"
        case (_, .succeeded): "succeeded"
        case (_, .failed): "failed"
        case (_, .interrupted): "interrupted"
        case (.completed, _): "completed"
        default: nil
        }
    }

    static func status(_ status: CodexThreadRuntimeStatus?) -> String? {
        switch status {
        case .idle?: "idle"
        case .active?: "running"
        case .systemError?: "error"
        case .notLoaded?: "not loaded"
        default: nil
        }
    }
}
