import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class DotsRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The runtime owns sign-in and renewal. Credentials are confined to this
/// transport actor, never published to views, saved, or included in errors.
actor DotsService: PersonalAgentClient {
    struct Identity: Equatable { let account: String; let user: String }
    struct Credential { let identity: Identity; let token: String; let expires: TimeInterval? }
    private let transport: any CodexTransport
    private let session: URLSession
    /// The same policy with room for a 20 MiB file on a slow connection.
    private let uploadSession: URLSession
    /// The room-live stream's session: the same policy, read for as long as the observer lasts.
    let streamSession: URLSession
    let liveTiming: DotsLiveTiming
    private let makeSocket: @Sendable (URL, URLSession) -> any DotsEventSocket
    private let redirectPolicy = DotsRedirectPolicy()
    private var initialized = false
    private var initializing: Task<Void, Error>?
    private var requestID: Int64 = 2
    private var identity: Identity?
    private(set) var stopped = false
    private var eventTask: Task<Void, Never>?
    private var eventSocket: (any DotsEventSocket)?
    private var watchID: UUID?
    /// The user's event socket once its first commands are sent, which the room-live topic rides on.
    var openSocket: (any DotsEventSocket)?
    var live: DotsRoomLive?
    /// Commands after the socket's own two (connect, then the messaging topic).
    var nextCommand: Int64 = 3
    /// What this reader itself read for each dot: its profile's current root thread, and the tasks its
    /// Activity listed. A task's execution record is read only for a task listed here, so a value made
    /// elsewhere opens nothing.
    private var profileRoots: [PersonalAgentIdentity: String] = [:]
    private var listedTasks: [PersonalAgentIdentity: Set<String>] = [:]
    /// The product each task's thread belongs to, as its read metadata says (`productSKU`).
    private var threadProducts: [PersonalAgentIdentity: [String: String]] = [:]
    /// The threads each dot's Outputs may read: its root and bound threads as its profile listed them,
    /// and the children whose metadata named one of those as parent, with that parent.
    private var outputScopes: [PersonalAgentIdentity: Set<String>] = [:]
    private var outputParents: [PersonalAgentIdentity: [String: String]] = [:]
    private let makeDurableSocket: @Sendable (URLRequest, URLSession) -> any DotsEventSocket

    init(executable: URL, environmentManager: CodexEnvironmentManager?, connection: ProviderConnection?,
         transport: (any CodexTransport)? = nil, configuration: URLSessionConfiguration? = nil,
         liveTiming: DotsLiveTiming = .init(),
         socket: (@Sendable (URL, URLSession) -> any DotsEventSocket)? = nil,
         durableSocket: (@Sendable (URLRequest, URLSession) -> any DotsEventSocket)? = nil) {
        self.transport = transport ?? CodexProcessTransport(executableURL: executable,
            environmentManager: connection?.codexEnvironmentManager() ?? environmentManager
                ?? CodexEnvironmentManager(paths: .live()), environmentScope: .native,
            resourceOwner: .codexAppServer(.init(connection: connection, environmentScope: .native)))
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: redirectPolicy, delegateQueue: nil)
        let uploads = config.copy() as! URLSessionConfiguration
        uploads.timeoutIntervalForRequest = 60
        uploads.timeoutIntervalForResource = 600
        uploadSession = URLSession(configuration: uploads, delegate: redirectPolicy, delegateQueue: nil)
        // The stream idles up to a minute between events, as the provider's client allows it.
        let stream = config.copy() as! URLSessionConfiguration
        stream.timeoutIntervalForRequest = 60
        stream.timeoutIntervalForResource = 7 * 24 * 60 * 60
        streamSession = URLSession(configuration: stream, delegate: redirectPolicy, delegateQueue: nil)
        self.liveTiming = liveTiming
        makeSocket = socket ?? { url, session in
            let task = session.webSocketTask(with: url)
            task.maximumMessageSize = 512 * 1024
            return task
        }
        makeDurableSocket = durableSocket ?? { request, session in
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = DotsDurableFiles.maximumMessageBytes
            return task
        }
    }

    func agents() async throws -> [PersonalAgent] {
        let auth = try await credentials()
        var items: [JSONValue] = [], cursor: String?, seen = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "include_room_preview", value: "false")]
            if let cursor { query.append(.init(name: "cursor", value: cursor)) }
            let page = try await read("/tbo", query: query)
            guard case let .array(next)? = page["items"] else { throw PersonalAgentFailure.invalidResponse }
            items += next
            cursor = page["cursor"]?.stringValue
            if let cursor, !seen.insert(cursor).inserted { throw PersonalAgentFailure.invalidResponse }
            guard items.count <= 1_000 else { throw PersonalAgentFailure.invalidResponse }
        } while cursor != nil
        let primary = try await read("/tbo/primary")
        let agents = try DotsProjection.agents(catalog: .object(["items": .array(items)]), primary: primary,
                                               accountID: auth.identity.account, userID: auth.identity.user)
        profileRoots = Dictionary(agents.compactMap { agent in agent.rootThreadID.map { (agent.id, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        return agents
    }

    func messages(for agent: PersonalAgent, before: String?) async throws -> PersonalAgentPage {
        let auth = try await credentials()
        guard auth.identity.account == agent.id.accountID, auth.identity.user == agent.id.userID else {
            throw PersonalAgentFailure.accountChanged
        }
        let path = "/messaging/rooms/" + component(agent.id.roomID)
        let room = try await read(path)
        var query = [URLQueryItem(name: "limit", value: "20")]
        if let before { query.append(.init(name: "before", value: before)) }
        let page = try await read(path + "/messages", query: query)
        let projected = try DotsProjection.messages(page, room: room, agent: agent)
        if let before, projected.before == before {
            return .init(messages: projected.messages, before: nil, roomLifecycle: projected.roomLifecycle)
        }
        return projected
    }

    /// One page of a reply thread, read as the provider's room reads it: the room's binding is
    /// checked, and only `before` pages back. An unchanged cursor ends the thread, as a missing one does.
    func replies(to rootID: String, for agent: PersonalAgent, before: String?) async throws -> PersonalAgentPage {
        guard !rootID.isEmpty else { throw PersonalAgentFailure.invalidResponse }
        try await verify(agent)
        let path = "/messaging/rooms/" + component(agent.id.roomID)
        let room = try await read(path)
        var query = [URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "reply_root_message_id", value: rootID)]
        if let before { query.append(.init(name: "before", value: before)) }
        let page = try await read(path + "/messages", query: query)
        let projected = try DotsProjection.messages(page, room: room, agent: agent, thread: true)
        if let before, projected.before == before {
            return .init(messages: projected.messages, before: nil, roomLifecycle: projected.roomLifecycle)
        }
        return projected
    }

    func send(_ submission: PersonalAgentSubmission, to agent: PersonalAgent) async throws -> PersonalAgentMessage {
        // An ordinary reply and an option answer are told apart before anything is read; a request
        // that is neither, or half of one, is not sent.
        guard !submission.isEmpty, let reply = submission.reply else { throw PersonalAgentFailure.sendRejected }
        try await verify(agent)
        let path = "/messaging/rooms/" + component(agent.id.roomID)
        let room = try await read(path)
        // Check the room binding, and for files or an ordinary reply that the room takes them, before
        // the only message-writing request. The provider gates both on the same lifecycle.
        if case .ordinary = reply {
            try DotsProjection.attachmentRoom(room, agent: agent, refusal: .repliesNotAllowed)
        } else if submission.attachments.isEmpty {
            _ = try DotsProjection.messages(.object(["items": .array([])]), room: room, agent: agent)
        } else {
            try DotsProjection.attachmentRoom(room, agent: agent)
        }
        let attachments = submission.attachments.map {
            JSONValue.object(["type": .string("file"), "file_id": .string($0.fileID)])
        }
        var body: [String: JSONValue] = [
            "content": .object(["text": .string(submission.text), "attachments": .array(attachments)]),
            "request_id": .string(submission.requestID), "idempotency_token": .string(submission.requestID),
            "timezone_offset_min": .integer(Int64(submission.timezoneOffsetMinutes))
        ]
        switch reply {
        case .message: break
        // An ordinary reply names the message it answers, and nothing else.
        case let .ordinary(parent):
            body["reply_to"] = .object(["message_id": .string(parent)])
        // An option question's answer replies to it, naming the option chosen; nothing else is passed through.
        case let .option(question, selection):
            body["reply_to"] = .object(["message_id": .string(question)])
            body["message_metadata"] = .object(["option_picker": .object(["selection": .integer(Int64(selection))])])
        }
        let result = try await requestJSON(path + "/messages", method: "POST", body: .json(.object(body)))
        guard let message = try? DotsProjection.messages(.object(["items": .array([result])]), room: room, agent: agent).messages.first,
              message.author == .person, message.requestID == submission.requestID else {
            throw PersonalAgentFailure.deliveryUnknown
        }
        return message
    }

    /// The provider composer's ordinary upload: one multipart `file` field, answered with the file's
    /// ID. No upload URL, storage write or reservation; a failure leaves nothing to clean up here,
    /// and nothing is deleted on the provider when the person removes the file.
    func upload(_ file: PersonalAgentPreparedFile, to agent: PersonalAgent) async throws -> PersonalAgentUploadedFile {
        guard PersonalAgentFileRules.accepts(size: file.data.count) else { throw PersonalAgentFailure.attachmentLimit }
        try await verify(agent)
        let path = "/messaging/rooms/" + component(agent.id.roomID)
        // The same room binding and attachment gate the send checks, before the file goes anywhere.
        try DotsProjection.attachmentRoom(try await read(path), agent: agent)
        let boundary = "YardletFormBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let value: JSONValue
        do {
            value = try await requestJSON(path + "/files", method: "POST",
                                          body: .multipart(Self.multipart(file, boundary: boundary), boundary: boundary))
        } catch let failure as PersonalAgentFailure {
            switch failure {
            case .accountChanged, .signInRequired, .stopped, .runtimeUnavailable: throw failure
            default: throw PersonalAgentFailure.uploadFailed
            }
        }
        try await verify(agent)
        guard let id = value["id"]?.stringValue, !id.isEmpty else { throw PersonalAgentFailure.uploadFailed }
        return .init(fileID: id, name: file.name, mimeType: file.mimeType, sizeBytes: file.data.count)
    }

    /// The form a browser sends for one file: its name with quotes and line breaks percent-escaped,
    /// UTF-8 otherwise.
    static func multipart(_ file: PersonalAgentPreparedFile, boundary: String) -> Data {
        let name = file.name.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A")
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n".utf8))
        body.append(Data("Content-Type: \(file.mimeType)\r\n\r\n".utf8))
        body.append(file.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    func download(_ attachment: PersonalAgentAttachment, for agent: PersonalAgent) async throws -> PersonalAgentDownload {
        try await verify(agent)
        guard attachment.type == "file", let fileID = attachment.fileID, !fileID.isEmpty else {
            throw PersonalAgentFailure.attachmentUnavailable
        }
        let metadata = try await read("/messaging/rooms/" + component(agent.id.roomID) + "/files/" + component(fileID))
        guard let raw = metadata["download_url"]?.stringValue else { throw PersonalAgentFailure.attachmentUnavailable }
        let data = try await fetch(DotsAttachmentLocation(raw), limit: 25 * 1024 * 1024)
        try await verify(agent)
        return .init(data: data, name: metadata["name"]?.stringValue ?? attachment.name)
    }

    func avatar(for agent: PersonalAgent) async throws -> Data {
        try await verify(agent)
        guard let avatar = agent.avatar else { throw PersonalAgentFailure.attachmentUnavailable }
        let data = try await fetch(DotsAttachmentLocation(avatar.location), limit: 4 * 1024 * 1024, imageOnly: true)
        try await verify(agent)
        return data
    }

    func pet(_ id: String, for agent: PersonalAgent) async throws -> PersonalAgentPet? {
        try await verify(agent)
        var cursor: String?, seen = Set<String>(), count = 0
        repeat {
            var query = [URLQueryItem(name: "limit", value: "20")]
            if let cursor { query.append(.init(name: "cursor", value: cursor)) }
            let page = try DotsProjection.pets(try await read("/pets", query: query))
            if let pet = page.pets.first(where: { $0.id == id }) {
                try await verify(agent)
                return pet
            }
            cursor = page.cursor
            count += page.pets.count
            if let cursor, !seen.insert(cursor).inserted { throw PersonalAgentFailure.invalidResponse }
            guard count <= 1_000, seen.count <= 100 else { throw PersonalAgentFailure.invalidResponse }
        } while cursor != nil
        return nil
    }

    func spriteSheet(_ pet: PersonalAgentPet, for agent: PersonalAgent) async throws -> Data {
        try await verify(agent)
        let data = try await fetch(DotsAttachmentLocation(pet.location), limit: 20 * 1024 * 1024, imageOnly: true)
        try await verify(agent)
        return data
    }

    func activity(for agent: PersonalAgent, cursor: String?) async throws -> PersonalAgentActivityPage {
        try await verify(agent)
        var query = [URLQueryItem(name: "limit", value: "5")]
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        let page = try DotsProjection.activity(try await read("/tbo/" + component(agent.id.agentID) + "/activity", query: query))
        try await verify(agent)
        listedTasks[agent.id, default: []].formUnion(page.items.map(\.id))
        return page.cursor == cursor ? .init(items: page.items, cursor: nil) : page
    }

    func schedules(for agent: PersonalAgent) async throws -> [PersonalAgentSchedule] {
        try await verify(agent)
        var schedules: [PersonalAgentSchedule] = [], cursor: String?, seen = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "limit", value: "100")]
            if let cursor { query.append(.init(name: "cursor", value: cursor)) }
            let page = try await read("/tbo/" + component(agent.id.agentID) + "/automations", query: query)
            schedules += try DotsProjection.schedules(page)
            cursor = page["cursor"]?.stringValue
            if let cursor, !seen.insert(cursor).inserted { throw PersonalAgentFailure.invalidResponse }
            guard schedules.count <= 1_000 else { throw PersonalAgentFailure.invalidResponse }
        } while cursor != nil
        return schedules
    }

    func computers(for agent: PersonalAgent) async throws -> [PersonalAgentComputer] {
        try await verify(agent)
        guard let root = agent.rootThreadID, !root.isEmpty else { return [] }
        let value = try await read("/tbo/" + component(agent.id.agentID) + "/computers",
                                   query: [.init(name: "expected_thread_id", value: root)])
        return try DotsProjection.computers(value, rootThreadID: root)
    }

    func inspectRequest(in messageID: String, for agent: PersonalAgent) async throws -> DotsRequestInspection {
        try await verify(agent)
        let value = try await read(requestPath(messageID, for: agent), query: [.init(name: "inspect", value: "true")])
        try await verify(agent)
        return try DotsRequestInspection(value)
    }

    /// One POST of an answer, never repeated. Credentials may be renewed and the account is checked
    /// before it leaves; any failure up to then is `notDispatched`. From the moment the request is
    /// handed to the network, every outcome but an `applied` status is uncertain: an expired login,
    /// a rejection, a server error, a lost connection, a cancellation or a changed account.
    func respond(_ result: DotsInputResult, fingerprint: String, in messageID: String,
                 for agent: PersonalAgent) async throws -> DotsResponseOutcome {
        var request: URLRequest
        do {
            try Task.checkCancellation()
            let auth = try await credentials()
            guard auth.identity.account == agent.id.accountID, auth.identity.user == agent.id.userID else {
                throw PersonalAgentFailure.accountChanged
            }
            request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api" + requestPath(messageID, for: agent) + "/response")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(JSONValue.object([
                "request_fingerprint": .string(fingerprint), "result": result.json
            ]))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Yardlet/PersonalAgents", forHTTPHeaderField: "User-Agent")
            request.setValue("Bearer " + auth.token, forHTTPHeaderField: "Authorization")
            request.setValue(auth.identity.account, forHTTPHeaderField: "ChatGPT-Account-Id")
            try Task.checkCancellation()
        } catch {
            throw DotsResponseFailure.notDispatched(error as? PersonalAgentFailure ?? .stopped)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw DotsResponseFailure.uncertain(.deliveryUnknown) }
        guard let http = response as? HTTPURLResponse else { throw DotsResponseFailure.uncertain(.invalidResponse) }
        guard (200...299).contains(http.statusCode) else {
            let failure: PersonalAgentFailure = switch http.statusCode {
            case 401: .signInRequired
            case 403: .verificationRequired
            case 400...499 where http.statusCode != 408: .sendRejected
            default: .deliveryUnknown
            }
            throw DotsResponseFailure.uncertain(failure)
        }
        do {
            let auth = try await credentials()
            guard auth.identity.account == agent.id.accountID, auth.identity.user == agent.id.userID else {
                throw PersonalAgentFailure.accountChanged
            }
        } catch { throw DotsResponseFailure.uncertain(error as? PersonalAgentFailure ?? .stopped) }
        guard data.count <= 1024 * 1024, let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DotsResponseFailure.uncertain(.invalidResponse)
        }
        return value["status"]?.stringValue == "applied" ? .applied : .unconfirmed
    }

    private func requestPath(_ messageID: String, for agent: PersonalAgent) -> String {
        "/messaging/rooms/" + component(agent.id.roomID) + "/messages/" + component(messageID) + "/elicitation"
    }

    // MARK: Activity history

    /// Where the provider's own app reads a task's execution history: a host of its own, not the
    /// ChatGPT API. Only these reads, and only this exact host, carry the credential there.
    private static let historyOrigin = "https://codex-cloud-backend.chatgpt.com"

    func activityThread(_ threadID: String, for agent: PersonalAgent) async throws -> CodexThreadState {
        try await verifyListed(threadID, for: agent)
        return try await threadMetadata(threadID, for: agent)
    }

    /// A task this reader saw in the dot's own Activity, read under the same login.
    private func verifyListed(_ threadID: String, for agent: PersonalAgent) async throws {
        try await verify(agent)
        guard listedTasks[agent.id]?.contains(threadID) == true else { throw PersonalAgentFailure.accessDenied }
    }

    /// The product a read names for its thread, as the provider's own app names it: the dot's current
    /// root is its own; another thread is unknown until its metadata says it is the dot's (`aeon`) or
    /// not (`codex`). It is a label, never a permission: a refused read is not retried under another.
    private func productSKU(_ threadID: String, for agent: PersonalAgent) -> String {
        if profileRoots[agent.id] == threadID { return "aeon" }
        return threadProducts[agent.id]?[threadID] ?? "unknown"
    }

    func activityTurns(_ threadID: String, cursor: String?, for agent: PersonalAgent) async throws -> CodexTurnPage {
        try await verifyListed(threadID, for: agent)
        return try await threadTurns(threadID, cursor: cursor, for: agent)
    }

    func activityItems(_ threadID: String, turnID: String, cursor: String?,
                       for agent: PersonalAgent) async throws -> CodexItemPage {
        try await verifyListed(threadID, for: agent)
        return try await threadItems(threadID, turnID: turnID, cursor: cursor, for: agent)
    }

    /// A thread's metadata from the execution-history host, which must name the thread asked for.
    private func threadMetadata(_ threadID: String, for agent: PersonalAgent) async throws -> CodexThreadState {
        let value = try await requestJSON("/v1/threads/" + component(threadID), origin: Self.historyOrigin,
                                          product: productSKU(threadID, for: agent))
        let thread = try PersonalAgentActivityHistory.thread(value, id: threadID)
        try await verify(agent)
        threadProducts[agent.id, default: [:]][threadID] = thread.raw["threadSource"]?.stringValue == "aeon" ? "aeon" : "codex"
        return thread
    }

    private func threadTurns(_ threadID: String, cursor: String?, for agent: PersonalAgent) async throws -> CodexTurnPage {
        var query = [URLQueryItem(name: "limit", value: String(PersonalAgentActivityHistory.initialTurnCount)),
                     URLQueryItem(name: "sortDirection", value: "desc"), URLQueryItem(name: "itemsView", value: "notLoaded")]
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        let value = try await requestJSON("/v2/threads/" + component(threadID) + "/turns", query: query,
                                          origin: Self.historyOrigin, product: productSKU(threadID, for: agent))
        let page = try PersonalAgentActivityHistory.turnPage(value)
        try await verify(agent)
        return page
    }

    /// A page of one turn's items. A page too large to carry is asked for again from the same cursor
    /// with half as many items, down to one, as the provider's own app does.
    private func threadItems(_ threadID: String, turnID: String, cursor: String?,
                             for agent: PersonalAgent) async throws -> CodexItemPage {
        var limit = PersonalAgentActivityHistory.itemPageSize
        while true {
            var query = [URLQueryItem(name: "turnId", value: turnID), URLQueryItem(name: "limit", value: String(limit)),
                         URLQueryItem(name: "sortDirection", value: "asc")]
            if let cursor { query.append(.init(name: "cursor", value: cursor)) }
            do {
                let value = try await requestJSON("/v2/threads/" + component(threadID) + "/items", query: query,
                                                  origin: Self.historyOrigin, product: productSKU(threadID, for: agent))
                let page = try PersonalAgentActivityHistory.itemPage(value, turnID: turnID)
                try await verify(agent)
                return page
            } catch PersonalAgentFailure.tooLarge where limit > 1 {
                limit /= 2
            }
        }
    }

    // MARK: Outputs

    /// The dot's execution threads its Outputs are read from: its current root, whose profile must
    /// name this dot and this root, and the threads the profile binds. This list is apart from the
    /// Activity's, which it never widens; a spawned thread joins it only through `outputChild`.
    func outputThreads(for agent: PersonalAgent) async throws -> [String] {
        try await verify(agent)
        guard let root = agent.rootThreadID, !root.isEmpty, profileRoots[agent.id] == root else { return [] }
        let profile = try await read("/tbo/by-thread/" + component(root))
        guard profile["id"]?.stringValue == agent.id.agentID, profile["active_root_thread_id"]?.stringValue == root else {
            throw PersonalAgentFailure.invalidResponse
        }
        var threads = [root], seen: Set<String> = [root], cursor: String?, cursors = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "include_hidden", value: "false")]
            if let cursor { query.append(.init(name: "cursor", value: cursor)) }
            let page = try await read("/tbo/" + component(agent.id.agentID) + "/threads", query: query)
            guard case let .array(items)? = page["items"] else { throw PersonalAgentFailure.invalidResponse }
            for item in items {
                guard let id = item["thread_id"]?.stringValue, !id.isEmpty else { throw PersonalAgentFailure.invalidResponse }
                if seen.insert(id).inserted { threads.append(id) }
            }
            cursor = page["cursor"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            if let cursor, !cursors.insert(cursor).inserted { throw PersonalAgentFailure.invalidResponse }
            guard threads.count <= 1_000 else { throw PersonalAgentFailure.invalidResponse }
        } while cursor != nil
        try await verify(agent)
        outputScopes[agent.id, default: []].formUnion(threads)
        return threads
    }

    private func verifyOutput(_ threadID: String, for agent: PersonalAgent) async throws {
        try await verify(agent)
        guard outputScopes[agent.id]?.contains(threadID) == true else { throw PersonalAgentFailure.accessDenied }
    }

    func outputThread(_ threadID: String, for agent: PersonalAgent) async throws -> CodexThreadState {
        try await verifyOutput(threadID, for: agent)
        return try await threadMetadata(threadID, for: agent)
    }

    func outputChild(_ threadID: String, of parentID: String, for agent: PersonalAgent) async throws -> CodexThreadState? {
        try await verifyOutput(parentID, for: agent)
        let thread = try await threadMetadata(threadID, for: agent)
        // A thread whose metadata names another parent, or none, is not this one's child.
        guard PersonalAgentOutputEnvironment.parent(of: thread.raw) == parentID else { return nil }
        outputScopes[agent.id, default: []].insert(threadID)
        outputParents[agent.id, default: [:]][threadID] = parentID
        return thread
    }

    func outputTurns(_ threadID: String, cursor: String?, for agent: PersonalAgent) async throws -> CodexTurnPage {
        try await verifyOutput(threadID, for: agent)
        return try await threadTurns(threadID, cursor: cursor, for: agent)
    }

    func outputItems(_ threadID: String, turnID: String, cursor: String?,
                     for agent: PersonalAgent) async throws -> CodexItemPage {
        try await verifyOutput(threadID, for: agent)
        return try await threadItems(threadID, turnID: turnID, cursor: cursor, for: agent)
    }

    /// A file a task of the dot presented on its computer. The thread's computer is read again from
    /// its metadata, or its verified parent's when it names none, and must be the one the file was
    /// found on; the file is then read over the execution host's socket, never from this Mac. A failure
    /// there is a `DotsRemoteFileError`, naming its step.
    func outputFile(_ file: PersonalAgentRemoteFile, for agent: PersonalAgent) async throws -> PersonalAgentDownload {
        try await verifyOutput(file.threadID, for: agent)
        guard file.path.hasPrefix("/"), PersonalAgentOutputScan.normalized(file.path) == file.path else {
            throw PersonalAgentFailure.remoteFile
        }
        var current = file.threadID, visited = Set<String>()
        var environment = PersonalAgentOutputEnvironment.unavailable
        while visited.insert(current).inserted {
            let thread = try await threadMetadata(current, for: agent)
            environment = PersonalAgentOutputEnvironment(thread: thread.raw)
            guard environment == .parents, let parent = outputParents[agent.id]?[current] else { break }
            current = parent
        }
        guard case let .computer(id, _) = environment, file.environmentID == nil || file.environmentID == id else {
            throw PersonalAgentFailure.computerUnavailable
        }
        let auth = try await credentials()
        guard auth.identity.account == agent.id.accountID, auth.identity.user == agent.id.userID else {
            throw PersonalAgentFailure.accountChanged
        }
        let socket = makeDurableSocket(DotsDurableFiles.request(token: auth.token, account: auth.identity.account), streamSession)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await DotsDurableFiles.read(file.path, environmentID: id, socket: socket, version: version) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(DotsDurableFiles.timeout * 1_000_000_000))
                throw PersonalAgentFailure.network
            }
            defer { group.cancelAll(); socket.cancel(with: .normalClosure, reason: nil) }
            return try await group.next()!
        }
        // Bytes that outlive the login they were read under are not shown.
        try await verify(agent)
        return .init(data: data, name: file.name)
    }

    /// One bounded read of a file or picture. Only the provider API path gets the account credential;
    /// signed storage gets none, and a redirect is refused by the session's delegate.
    private func fetch(_ location: DotsAttachmentLocation, limit: Int, imageOnly: Bool = false) async throws -> Data {
        var request = URLRequest(url: location.url)
        request.setValue("Yardlet/PersonalAgents", forHTTPHeaderField: "User-Agent")
        if location.authenticated {
            let auth = try await credentials()
            request.setValue("Bearer " + auth.token, forHTTPHeaderField: "Authorization")
            request.setValue(auth.identity.account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.expectedContentLength <= limit,
                  !imageOnly || http.mimeType?.hasPrefix("image/") == true else {
                throw PersonalAgentFailure.attachmentUnavailable
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw PersonalAgentFailure.attachmentUnavailable }
                data.append(byte)
            }
            return data
        } catch let error as PersonalAgentFailure { throw error }
        catch { throw PersonalAgentFailure.network }
    }

    private func verify(_ agent: PersonalAgent) async throws {
        let auth = try await credentials()
        guard auth.identity.account == agent.id.accountID, auth.identity.user == agent.id.userID else {
            throw PersonalAgentFailure.accountChanged
        }
    }

    func updates(for agent: PersonalAgent) async -> AsyncStream<PersonalAgentUpdate> {
        stopWatching()
        let id = UUID()
        watchID = id
        let pair = AsyncStream<PersonalAgentUpdate>.makeStream(bufferingPolicy: .bufferingNewest(2))
        eventTask = Task { [weak self] in
            guard let self else { pair.continuation.finish(); return }
            await self.watch(agent, id: id, into: pair.continuation)
        }
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.stopWatching(ifCurrent: id) } }
        return pair.stream
    }

    private func stopWatching(ifCurrent id: UUID? = nil) {
        if let id, id != watchID { return }
        watchID = nil
        eventTask?.cancel()
        eventTask = nil
        eventSocket?.cancel(with: .normalClosure, reason: nil)
        if let eventSocket { liveSocketClosed(eventSocket) }
        eventSocket = nil
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        initializing?.cancel()
        stopLive()
        stopWatching()
        session.invalidateAndCancel()
        uploadSession.invalidateAndCancel()
        streamSession.invalidateAndCancel()
        await transport.stop()
    }

    func credentials(refresh: Bool = false) async throws -> Credential {
        guard !stopped else { throw PersonalAgentFailure.stopped }
        if !initialized {
            if initializing == nil {
                let transport = transport
                initializing = Task {
                    try await transport.start()
                    _ = try await transport.request(CodexProtocol.initialize(id: 1, clientVersion: "0.1"))
                }
            }
            do { try await initializing?.value; initialized = true }
            catch { throw PersonalAgentFailure.runtimeUnavailable }
        }
        let id = requestID
        requestID += 1
        let response: CodexRPCIncomingMessage
        do {
            response = try await transport.request(.init(id: id, method: "getAuthStatus",
                params: .object(["includeToken": .bool(true), "refreshToken": .bool(refresh)])))
        } catch { throw PersonalAgentFailure.runtimeUnavailable }
        guard !stopped else { throw PersonalAgentFailure.stopped }
        guard response.result?["authMethod"]?.stringValue == "chatgpt",
              let token = response.result?["authToken"]?.stringValue else { throw PersonalAgentFailure.signInRequired }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw PersonalAgentFailure.signInRequired }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let claims = try? JSONDecoder().decode(JSONValue.self, from: data),
              let fields = claims["https://api.openai.com/auth"],
              let account = fields["chatgpt_account_id"]?.stringValue ?? fields["account_id"]?.stringValue,
              let user = fields["user_id"]?.stringValue ?? fields["chatgpt_user_id"]?.stringValue else {
            throw PersonalAgentFailure.signInRequired
        }
        let current = Identity(account: account, user: user)
        if let identity, identity != current { throw PersonalAgentFailure.accountChanged }
        identity = current
        let expiry: TimeInterval?
        switch claims["exp"] {
        case let .integer(value)?: expiry = Double(value)
        case let .number(value)?: expiry = value
        default: expiry = nil
        }
        if !refresh, let expiry, expiry - Date().timeIntervalSince1970 <= 60 { return try await credentials(refresh: true) }
        if let expiry, expiry <= Date().timeIntervalSince1970 { throw PersonalAgentFailure.signInRequired }
        return Credential(identity: current, token: token, expires: expiry)
    }

    private func read(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        try await requestJSON(path, query: query)
    }

    private enum Body {
        case json(JSONValue)
        case multipart(Data, boundary: String)
    }

    private func requestJSON(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Body? = nil,
                             origin: String = "https://chatgpt.com/backend-api", product: String? = nil) async throws -> JSONValue {
        let writing = method != "GET"
        for attempt in 0...1 {
            try Task.checkCancellation()
            let auth = try await credentials(refresh: attempt == 1)
            var components = URLComponents(string: origin + path)!
            if !query.isEmpty { components.queryItems = query }
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            switch body {
            case let .json(value)?:
                request.httpBody = try JSONEncoder().encode(value)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            case let .multipart(data, boundary)?:
                request.httpBody = data
                request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
            case nil: break
            }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Yardlet/PersonalAgents", forHTTPHeaderField: "User-Agent")
            request.setValue("Bearer " + auth.token, forHTTPHeaderField: "Authorization")
            request.setValue(auth.identity.account, forHTTPHeaderField: "ChatGPT-Account-Id")
            if let product { request.setValue(product, forHTTPHeaderField: "X-OpenAI-Product-Sku") }
            let data: Data, response: URLResponse
            let transfer = if case .multipart? = body { uploadSession } else { session }
            do { (data, response) = try await transfer.data(for: request) }
            catch {
                if writing { throw PersonalAgentFailure.deliveryUnknown }
                if Task.isCancelled { throw CancellationError() }
                throw PersonalAgentFailure.network
            }
            guard let http = response as? HTTPURLResponse else { throw PersonalAgentFailure.invalidResponse }
            if http.statusCode == 401, attempt == 0 { continue }
            if http.statusCode == 401 { throw PersonalAgentFailure.signInRequired }
            if http.statusCode == 403 { throw writing ? PersonalAgentFailure.verificationRequired : .accessDenied }
            if http.statusCode == 404, origin == Self.historyOrigin { throw PersonalAgentFailure.missing }
            // The provider's own words for a page too large to decode; only these, in its structured error.
            if origin == Self.historyOrigin, !(200...299).contains(http.statusCode),
               let error = try? JSONDecoder().decode(JSONValue.self, from: data),
               error["error"]?["message"]?.stringValue?.contains("decoded message length too large") == true {
                throw PersonalAgentFailure.tooLarge
            }
            guard (200...299).contains(http.statusCode) else {
                if writing {
                    throw (400...499).contains(http.statusCode) && http.statusCode != 408
                        ? PersonalAgentFailure.sendRejected : .deliveryUnknown
                }
                throw PersonalAgentFailure.unavailable
            }
            if origin == Self.historyOrigin, data.count > PersonalAgentActivityHistory.maximumPageBytes {
                throw PersonalAgentFailure.tooLarge
            }
            guard data.count <= 8 * 1024 * 1024, http.mimeType?.contains("json") == true,
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                throw writing ? PersonalAgentFailure.deliveryUnknown : .invalidResponse
            }
            // A read that outlives an account switch must never populate the old view.
            _ = try await credentials()
            return value
        }
        throw PersonalAgentFailure.signInRequired
    }

    private func watch(_ agent: PersonalAgent, id: UUID, into output: AsyncStream<PersonalAgentUpdate>.Continuation) async {
        defer { output.finish() }
        var delay: UInt64 = 1
        let topic = "calpico-chatgpt-messaging"
        while !Task.isCancelled, !stopped, watchID == id {
            do {
                let auth = try await credentials()
                guard auth.identity.account == agent.id.accountID, auth.identity.user == agent.id.userID else {
                    throw PersonalAgentFailure.accountChanged
                }
                let info = try await read("/celsius/ws/user")
                try Task.checkCancellation()
                guard watchID == id else { return }
                guard let raw = info["websocket_url"]?.stringValue, let url = URL(string: raw),
                      url.scheme == "wss", url.host == "ws.chatgpt.com", url.port == nil else {
                    throw PersonalAgentFailure.invalidResponse
                }
                let socket = makeSocket(url, session)
                defer {
                    socket.cancel(with: .normalClosure, reason: nil)
                    liveSocketClosed(socket)
                }
                eventSocket = socket
                socket.resume()
                let commands: JSONValue = .array([
                    .object(["id": .integer(1), "command": .object(["type": .string("connect"),
                        "presence": .object(["state": .string("background"), "type": .string("presence")])])]),
                    .object(["id": .integer(2), "command": .object(["type": .string("subscribe"), "topic_id": .string(topic)])])
                ])
                try await socket.send(.string(String(decoding: JSONEncoder().encode(commands), as: UTF8.self)))
                guard watchID == id, !Task.isCancelled else { return }
                liveSocketOpened(socket)
                while !Task.isCancelled, !stopped {
                    let incoming = try await socket.receive()
                    let data: Data
                    switch incoming {
                    case let .data(value): data = value
                    case let .string(value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                          case let .array(frames) = value else { continue }
                    for frame in frames {
                        // A reply names its command by id; the room-live topic's are its own.
                        if let command = frame["id"], let reply = frame["reply"] {
                            if command == .integer(2) {
                                if reply["type"]?.stringValue == "subscribe" {
                                    output.yield(.connected)
                                    // Cover messages that arrived between the initial read and subscription.
                                    output.yield(.changed)
                                    delay = 1
                                }
                            } else {
                                liveReply(command, reply)
                            }
                        }
                        if frame["topic_id"]?.stringValue == topic,
                           frame["payload"]?["payload"]?["room_id"]?.stringValue == agent.id.roomID {
                            output.yield(.changed)
                        } else if frame["type"]?.stringValue == "message", let other = frame["topic_id"]?.stringValue {
                            liveMessage(topic: other, payload: frame["payload"])
                        }
                    }
                }
                socket.cancel(with: .normalClosure, reason: nil)
            } catch let failure as PersonalAgentFailure where failure == .accountChanged || failure == .signInRequired
                || failure == .accessDenied || failure == .invalidResponse || failure == .runtimeUnavailable || failure == .stopped {
                if !stopped { output.yield(.failed(failure)) }
                return
            } catch {
                if Task.isCancelled || stopped { return }
                eventSocket?.cancel(with: .goingAway, reason: nil)
                output.yield(.reconnecting)
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(30, delay * 2)
            }
        }
    }

    func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_~")))!
    }
}
