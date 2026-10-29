import XCTest
@testable import NativeHarnessClient

final class DotsServiceTests: XCTestCase {
    func testWritesRefreshOnlyAfterRejectionAndRetainTheSameRequestIdentity() async throws {
        let fixture = DotsHTTPRecorder(postStatuses: [401, 200])
        let broker = DotsTestBroker()
        let service = makeService(fixture, broker: broker)
        let submission = PersonalAgentSubmission(text: "Keep this as a draft.")
        let message = try await service.send(submission, to: agent)
        XCTAssertEqual(message.requestID, submission.requestID)
        XCTAssertEqual(message.author, .person)
        let posts = fixture.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        for post in posts {
            let body = try JSONDecoder().decode(JSONValue.self, from: fixture.body(post))
            XCTAssertEqual(body["request_id"]?.stringValue, submission.requestID)
            XCTAssertEqual(body["idempotency_token"]?.stringValue, submission.requestID)
            XCTAssertEqual(body["content"]?["text"]?.stringValue, submission.text)
            XCTAssertEqual(post.url?.path, "/backend-api/messaging/rooms/room/messages")
            XCTAssertNil(post.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(body["app_attest_challenge"])
        }
        let renewals = await broker.renewalCount()
        XCTAssertEqual(renewals, 1)
        await service.stop()
    }

    func testAmbiguousResponsesNeverRetryAndAccountChangesBlockWrites() async throws {
        for (status, expected) in [(503, PersonalAgentFailure.deliveryUnknown), (403, .verificationRequired)] {
            let fixture = DotsHTTPRecorder(postStatuses: [status])
            let service = makeService(fixture, broker: DotsTestBroker())
            do { _ = try await service.send(.init(text: "Draft"), to: agent); XCTFail("Expected send failure") }
            catch { XCTAssertEqual(error as? PersonalAgentFailure, expected) }
            XCTAssertEqual(fixture.requests.filter { $0.httpMethod == "POST" }.count, 1)
            await service.stop()
        }
        let fixture = DotsHTTPRecorder()
        let service = makeService(fixture, broker: DotsTestBroker(changesAccountAt: 3))
        do { _ = try await service.send(.init(text: "Draft"), to: agent); XCTFail("Expected account change") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .accountChanged) }
        XCTAssertTrue(fixture.requests.allSatisfy { $0.httpMethod == "GET" })
        await service.stop()
    }

    func testLoginLossAfterAcceptanceDoesNotPretendTheMessageWasRejected() async throws {
        let fixture = DotsHTTPRecorder()
        let service = makeService(fixture, broker: DotsTestBroker(signsOutAt: 5))
        do { _ = try await service.send(.init(text: "Draft"), to: agent); XCTFail("Expected login loss") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .signInRequired) }
        XCTAssertEqual(fixture.requests.filter { $0.httpMethod == "POST" }.count, 1)
        // PersonalAgentTests checks that this failure keeps the original pending ID.
        await service.stop()
    }

    func testAttachmentRequestsKeepCredentialsAtTheProviderOrigin() async throws {
        let fixture = DotsHTTPRecorder()
        let service = makeService(fixture, broker: DotsTestBroker())
        let file = try await service.download(.init(fileID: "file", name: "report.txt", type: "file"), for: agent)
        XCTAssertEqual(file.data, Data("Preview text".utf8))
        let metadata = try XCTUnwrap(fixture.requests.first { $0.url?.path.hasSuffix("/files/file") == true })
        XCTAssertNotNil(metadata.value(forHTTPHeaderField: "Authorization"))
        let download = try XCTUnwrap(fixture.requests.first { $0.url?.host == "files.oaiusercontent.com" })
        XCTAssertNil(download.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(download.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
        var pictured = agent
        pictured.avatar = .init(location: "https://files.oaiusercontent.com/avatar", version: "v1")
        let picture = try await service.avatar(for: pictured)
        XCTAssertEqual(picture, Data("PNG".utf8))
        let avatar = try XCTUnwrap(fixture.requests.first { $0.url?.path == "/avatar" })
        XCTAssertNil(avatar.value(forHTTPHeaderField: "Authorization"), "A signed picture is read without the account token")
        pictured.avatar = .init(location: "https://example.com/avatar", version: "v1")
        do { _ = try await service.avatar(for: pictured); XCTFail("Only provider hosts serve pictures") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .attachmentUnavailable) }
        // The pet a profile names is looked for page by page; its sheet is read as the picture is.
        let found = try await service.pet("pet", for: agent)
        let pet = try XCTUnwrap(found)
        XCTAssertEqual(fixture.requests.filter { $0.url?.path == "/backend-api/pets" }.count, 2)
        let sheetData = try await service.spriteSheet(pet, for: agent)
        XCTAssertEqual(sheetData, Data("PNG".utf8))
        let sheet = try XCTUnwrap(fixture.requests.first { $0.url?.path == "/sheet" })
        XCTAssertNil(sheet.value(forHTTPHeaderField: "Authorization"), "A signed sheet is read without the account token")
        let missing = try await service.pet("another", for: agent)
        XCTAssertNil(missing)
        // One of the provider's own pets, whose sheet is on its public CDN, is read the same way.
        let builtIn = PersonalAgentPet(id: "built-in", location: "https://cdn.openai.com/pets/example/sheet.png", version: "1")
        let builtInData = try await service.spriteSheet(builtIn, for: agent)
        XCTAssertEqual(builtInData, Data("PNG".utf8))
        let cdn = try XCTUnwrap(fixture.requests.first { $0.url?.host == "cdn.openai.com" })
        XCTAssertNil(cdn.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(cdn.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
        // Storage that refuses or no longer has the sheet leaves the still picture.
        for status in [403, 404] {
            let refused = PersonalAgentPet(id: "pet", location: "https://files.oaiusercontent.com/sheet-\(status)", version: "2")
            do { _ = try await service.spriteSheet(refused, for: agent); XCTFail("A \(status) sheet is not read") }
            catch { XCTAssertEqual(error as? PersonalAgentFailure, .attachmentUnavailable) }
        }
        XCTAssertTrue(try DotsAttachmentLocation("/estuary/content?id=file").authenticated)
        for raw in ["http://files.oaiusercontent.com/file", "https://chatgpt.com.evil.test/backend-api/files/a",
                    "https://chatgpt.com/backend-api/tbo", "https://127.0.0.1/file", "file:///etc/passwd",
                    "https://user:password@files.oaiusercontent.com/file", "https://cdn.openai.com.evil.test/sheet.png",
                    "https://images.cdn.openai.com/sheet.png", "http://cdn.openai.com/sheet.png"] {
            XCTAssertThrowsError(try DotsAttachmentLocation(raw))
        }
        await service.stop()
    }

    private var agent: PersonalAgent {
        .init(id: .init(accountID: "account", userID: "person", agentID: "dot", roomID: "room"),
              name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
    }

    private func makeService(_ fixture: DotsHTTPRecorder, broker: DotsTestBroker) -> DotsService {
        DotsHTTPProtocol.current = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DotsHTTPProtocol.self]
        return DotsService(executable: URL(filePath: "/usr/bin/false"), environmentManager: nil, connection: nil,
                           transport: broker, configuration: configuration)
    }
}

private final class DotsHTTPRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var statuses: [Int]
    init(postStatuses: [Int] = [200]) { statuses = postStatuses }
    var requests: [URLRequest] { lock.withLock { recorded } }
    func body(_ request: URLRequest) -> Data { request.httpBody ?? Data() }

    func respond(_ input: URLRequest) -> (Int, Data) {
        lock.withLock {
            var request = input
            if request.httpBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                request.httpBody = data
            }
            recorded.append(request)
            if request.url?.host == "files.oaiusercontent.com" {
                if let status = ["/sheet-403": 403, "/sheet-404": 404][request.url?.path ?? ""] { return (status, Data()) }
                return (200, Data((["/avatar", "/sheet"].contains(request.url?.path) ? "PNG" : "Preview text").utf8))
            }
            if request.url?.host == "cdn.openai.com" { return (200, Data("PNG".utf8)) }
            if request.url?.path == "/backend-api/pets" {
                return (200, Data((request.url?.query?.contains("cursor=next") == true
                    ? #"{"pets":[{"id":"pet","artwork_revision":"2","updated_at":"2026-10-29T06:00:00Z","spritesheet_url":"https://files.oaiusercontent.com/sheet"}]}"#
                    : #"{"pets":[{"id":"other","spritesheet_url":"https://files.oaiusercontent.com/other"}],"cursor":"next"}"#).utf8))
            }
            if request.url?.path.hasSuffix("/files/file") == true {
                return (200, Data(#"{"name":"report.txt","download_url":"https://files.oaiusercontent.com/file"}"#.utf8))
            }
            if request.httpMethod == "POST" {
                let status = statuses.isEmpty ? 200 : statuses.removeFirst()
                let body = (try? JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())) ?? .null
                let result: JSONValue = .object(["id": .string("server-message"), "account_user_id": .string("person"),
                    "request_id": body["request_id"] ?? .null, "content": body["content"] ?? .null])
                return (status, try! JSONEncoder().encode(result))
            }
            return (200, Data(#"{"id":"room","aeon_id":"dot","members":[{"account_user_id":"person","role":"user"}]}"#.utf8))
        }
    }
}

private final class DotsHTTPProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var current: DotsHTTPRecorder?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.current else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let (status, data) = fixture.respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": ["/avatar", "/sheet"].contains(request.url?.path) || request.url?.host == "cdn.openai.com"
                                                          ? "image/png" : "application/json",
                                                      "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private actor DotsTestBroker: CodexTransport {
    private var count = 0
    private var renewals = 0
    let changesAccountAt: Int?
    let signsOutAt: Int?
    init(changesAccountAt: Int? = nil, signsOutAt: Int? = nil) {
        self.changesAccountAt = changesAccountAt; self.signsOutAt = signsOutAt
    }
    func start() { }
    func stop() { }
    func sendResponse(_ response: CodexRPCResponse) { }
    func sendErrorResponse(_ response: CodexRPCErrorResponse) { }
    func notifications() -> AsyncStream<CodexRawFrame> { AsyncStream { $0.finish() } }
    func renewalCount() -> Int { renewals }
    func request(_ request: CodexRPCRequest) throws -> CodexRPCIncomingMessage {
        var result: JSONValue = .object([:])
        if request.method == "getAuthStatus" {
            count += 1
            if request.params["refreshToken"] == .bool(true) { renewals += 1 }
            if signsOutAt != nil && count >= signsOutAt! { result = .object(["authMethod": .null]) }
            else {
                let account = changesAccountAt != nil && count >= changesAccountAt! ? "changed" : "account"
                let claims: JSONValue = .object(["https://api.openai.com/auth": .object([
                    "chatgpt_account_id": .string(account), "user_id": .string("person")]),
                    "exp": .number(Date().timeIntervalSince1970 + 3600)])
                let payload = try JSONEncoder().encode(claims).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
                result = .object(["authMethod": .string("chatgpt"), "authToken": .string("test." + payload + ".test")])
            }
        }
        return .init(id: request.id, method: nil, params: nil, result: result, error: nil, emittedAtMs: nil)
    }
}
