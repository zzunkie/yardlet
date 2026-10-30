import Foundation

private final class DotsRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The runtime owns sign-in and renewal. Credentials are confined to this
/// transport actor, never published to views, saved, or included in errors.
actor DotsService: PersonalAgentClient {
    private struct Identity: Equatable { let account: String; let user: String }
    private struct Credential { let identity: Identity; let token: String; let expires: TimeInterval? }
    private let transport: any CodexTransport
    private let session: URLSession
    /// The same policy with room for a 20 MiB file on a slow connection.
    private let uploadSession: URLSession
    private let redirectPolicy = DotsRedirectPolicy()
    private var initialized = false
    private var initializing: Task<Void, Error>?
    private var requestID: Int64 = 2
    private var identity: Identity?
    private var stopped = false
    private var eventTask: Task<Void, Never>?
    private var eventSocket: URLSessionWebSocketTask?
    private var watchID: UUID?

    init(executable: URL, environmentManager: CodexEnvironmentManager?, connection: ProviderConnection?,
         transport: (any CodexTransport)? = nil, configuration: URLSessionConfiguration? = nil) {
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
        return try DotsProjection.agents(catalog: .object(["items": .array(items)]), primary: primary,
                                        accountID: auth.identity.account, userID: auth.identity.user)
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

    func send(_ submission: PersonalAgentSubmission, to agent: PersonalAgent) async throws -> PersonalAgentMessage {
        guard !submission.isEmpty else { throw PersonalAgentFailure.sendRejected }
        try await verify(agent)
        let path = "/messaging/rooms/" + component(agent.id.roomID)
        let room = try await read(path)
        // Check the room binding, and for files that the room takes them, before the only message-writing request.
        if submission.attachments.isEmpty {
            _ = try DotsProjection.messages(.object(["items": .array([])]), room: room, agent: agent)
        } else {
            try DotsProjection.attachmentRoom(room, agent: agent)
        }
        let attachments = submission.attachments.map {
            JSONValue.object(["type": .string("file"), "file_id": .string($0.fileID)])
        }
        let result = try await requestJSON(path + "/messages", method: "POST", body: .json(.object([
            "content": .object(["text": .string(submission.text), "attachments": .array(attachments)]),
            "request_id": .string(submission.requestID), "idempotency_token": .string(submission.requestID),
            "timezone_offset_min": .integer(Int64(submission.timezoneOffsetMinutes))
        ])))
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
        eventSocket = nil
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        initializing?.cancel()
        stopWatching()
        session.invalidateAndCancel()
        uploadSession.invalidateAndCancel()
        await transport.stop()
    }

    private func credentials(refresh: Bool = false) async throws -> Credential {
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

    private func requestJSON(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Body? = nil) async throws -> JSONValue {
        let writing = method != "GET"
        for attempt in 0...1 {
            try Task.checkCancellation()
            let auth = try await credentials(refresh: attempt == 1)
            var components = URLComponents(string: "https://chatgpt.com/backend-api" + path)!
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
            guard (200...299).contains(http.statusCode) else {
                if writing {
                    throw (400...499).contains(http.statusCode) && http.statusCode != 408
                        ? PersonalAgentFailure.sendRejected : .deliveryUnknown
                }
                throw PersonalAgentFailure.unavailable
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
                let socket = session.webSocketTask(with: url)
                defer { socket.cancel(with: .normalClosure, reason: nil) }
                socket.maximumMessageSize = 512 * 1024
                eventSocket = socket
                socket.resume()
                let commands: JSONValue = .array([
                    .object(["id": .integer(1), "command": .object(["type": .string("connect"),
                        "presence": .object(["state": .string("background"), "type": .string("presence")])])]),
                    .object(["id": .integer(2), "command": .object(["type": .string("subscribe"), "topic_id": .string(topic)])])
                ])
                try await socket.send(.string(String(decoding: JSONEncoder().encode(commands), as: UTF8.self)))
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
                        if frame["reply"]?["type"]?.stringValue == "subscribe" {
                            output.yield(.connected)
                            // Cover messages that arrived between the initial read and subscription.
                            output.yield(.changed)
                            delay = 1
                        }
                        if frame["topic_id"]?.stringValue == topic,
                           frame["payload"]?["payload"]?["room_id"]?.stringValue == agent.id.roomID {
                            output.yield(.changed)
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

    private func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_~")))!
    }
}
