import ImageIO
import UniformTypeIdentifiers
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

    /// An input request's answer is posted once with its fingerprint. An expired login after it left is
    /// an uncertain outcome, not a reason to renew and post again; a changed account stops it before.
    func testInputRequestAnswersArePostedOnceAndNeverRetried() async throws {
        let result = DotsInputResult(action: .cancel, content: .null,
                                     meta: .object(["codex_approval_cancellation_reason": .string("user")]))
        let fixture = DotsHTTPRecorder(postStatuses: [401])
        let broker = DotsTestBroker()
        let service = makeService(fixture, broker: broker)
        let inspection = try await service.inspectRequest(in: "message", for: agent)
        XCTAssertEqual(inspection.fingerprint, "fingerprint")
        XCTAssertTrue(inspection.isAnswerable)
        let read = try XCTUnwrap(fixture.requests.last)
        XCTAssertEqual(read.url?.path, "/backend-api/messaging/rooms/room/messages/message/elicitation")
        XCTAssertEqual(read.url?.query, "inspect=true")
        do { _ = try await service.respond(result, fingerprint: "fingerprint", in: "message", for: agent); XCTFail("Expected uncertainty") }
        catch { XCTAssertEqual(error as? DotsResponseFailure, .uncertain(.signInRequired)) }
        let posts = fixture.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.url?.path, "/backend-api/messaging/rooms/room/messages/message/elicitation/response")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: fixture.body(try XCTUnwrap(posts.first))),
                       .object(["request_fingerprint": .string("fingerprint"), "result": result.json]))
        let renewals = await broker.renewalCount()
        XCTAssertEqual(renewals, 0)
        await service.stop()

        let applied = DotsHTTPRecorder()
        let accepting = makeService(applied, broker: DotsTestBroker())
        let outcome = try await accepting.respond(result, fingerprint: "fingerprint", in: "message", for: agent)
        XCTAssertEqual(outcome, .applied)
        await accepting.stop()

        let unsent = DotsHTTPRecorder()
        let changed = makeService(unsent, broker: DotsTestBroker(changesAccountAt: 1))
        do { _ = try await changed.respond(result, fingerprint: "fingerprint", in: "message", for: agent); XCTFail("Expected no dispatch") }
        catch { XCTAssertEqual(error as? DotsResponseFailure, .notDispatched(.accountChanged)) }
        XCTAssertTrue(unsent.requests.isEmpty)
        await changed.stop()
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

    func testUploadSendsOneMultipartFileAndAMessageMayCarryOnlyItsID() async throws {
        let fixture = DotsHTTPRecorder()
        let service = makeService(fixture, broker: DotsTestBroker())
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
        let uploaded = try await service.upload(.init(data: bytes, name: "보고서 \"최종\".png", mimeType: "image/png"), to: agent)
        XCTAssertEqual(uploaded, .init(fileID: "file_1", name: "보고서 \"최종\".png", mimeType: "image/png", sizeBytes: bytes.count))
        let post = try XCTUnwrap(fixture.requests.first { $0.httpMethod == "POST" })
        XCTAssertEqual(post.url?.path, "/backend-api/messaging/rooms/room/files")
        XCTAssertNotNil(post.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(post.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account")
        XCTAssertNil(post.value(forHTTPHeaderField: "Cookie"))
        let type = try XCTUnwrap(post.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(type.dropFirst("multipart/form-data; boundary=".count))
        var expected = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"보고서 %22최종%22.png\"\r\n".utf8)
        expected.append(Data("Content-Type: image/png\r\n\r\n".utf8))
        expected.append(bytes)
        expected.append(Data("\r\n--\(boundary)--\r\n".utf8))
        XCTAssertEqual(fixture.body(post), expected, "One field named file; no upload URL, reservation or second request")

        // A file alone is a message: empty words and the room's file ID, under one request identity.
        let submission = PersonalAgentSubmission(text: "", attachments: [uploaded])
        _ = try await service.send(submission, to: agent)
        let send = try XCTUnwrap(fixture.requests.last { $0.httpMethod == "POST" })
        XCTAssertEqual(send.url?.path, "/backend-api/messaging/rooms/room/messages")
        let body = try JSONDecoder().decode(JSONValue.self, from: fixture.body(send))
        XCTAssertEqual(body["content"], .object(["text": .string(""),
            "attachments": .array([.object(["type": .string("file"), "file_id": .string("file_1")])])]))
        XCTAssertEqual(body["idempotency_token"]?.stringValue, submission.requestID)
        XCTAssertEqual(fixture.requests.filter { $0.httpMethod == "POST" }.count, 2)

        // Out of the provider's size range, nothing is requested at all.
        for size in [0, PersonalAgentFileRules.maximumBytes + 1] {
            do { _ = try await service.upload(.init(data: Data(count: size), name: "a.bin", mimeType: "application/octet-stream"), to: agent); XCTFail() }
            catch { XCTAssertEqual(error as? PersonalAgentFailure, .attachmentLimit) }
        }
        XCTAssertEqual(fixture.requests.filter { $0.httpMethod == "POST" }.count, 2)
        await service.stop()

        // The provider's names for the lifecycle, in its order; a value it does not know says nothing.
        let lifecycle = { (raw: String) in DotsProjection.roomLifecycle(try! JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))) }
        XCTAssertEqual(lifecycle(#"{"dmLifecycleState":"","dm_lifecycle_state":"share_only"}"#), "share_only")
        XCTAssertNil(lifecycle(#"{"dm_lifecycle_state":"archived"}"#))
        XCTAssertTrue(DotsProjection.allowsAttachments(lifecycle: nil))
        XCTAssertTrue(DotsProjection.allowsAttachments(lifecycle: "accepted"))

        // Another room's binding, or a room that takes no files, gets no upload and no message with a file.
        let dm = #""type":"DM","app_source":"chatgpt:messaging","members":[]"#
        for (room, failure) in [(#"{"id":"other","aeon_id":"dot","# + dm + "}", PersonalAgentFailure.invalidResponse),
                                (#"{"id":"room","aeon_id":"dot","type":"GROUP","app_source":"chatgpt:messaging","members":[]}"#, .invalidResponse),
                                (#"{"id":"room","aeon_id":"dot","dm_lifecycle_state":"share_only","# + dm + "}", .attachmentsNotAllowed),
                                (#"{"id":"room","aeon_id":"dot","dmLifecycleState":"pending_request","dm_lifecycle_state":"connected","#
                                    + dm + "}", .attachmentsNotAllowed)] {
            let gated = DotsHTTPRecorder(room: room)
            let service = makeService(gated, broker: DotsTestBroker())
            do { _ = try await service.upload(.init(data: bytes, name: "a.png", mimeType: "image/png"), to: agent); XCTFail() }
            catch { XCTAssertEqual(error as? PersonalAgentFailure, failure) }
            do { _ = try await service.send(submission, to: agent); XCTFail() }
            catch { XCTAssertEqual(error as? PersonalAgentFailure, failure) }
            XCTAssertTrue(gated.requests.allSatisfy { $0.httpMethod == "GET" })
            await service.stop()
        }
    }

    /// The provider composer's preparation: HEIC becomes a JPEG under the same stem, a large picture is
    /// drawn again at most 2048 pixels on its long side, and a small one goes as it is.
    func testPicturesArePreparedAsTheProviderComposerPreparesThem() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func picture(_ width: Int, _ height: Int, _ type: UTType, _ name: String) throws -> URL {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let url = folder.appending(path: name)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return url
        }
        func size(_ data: Data) -> (Int?, Int?) {
            let properties = CGImageSourceCreateWithData(data as CFData, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            return (properties?[kCGImagePropertyPixelWidth] as? Int, properties?[kCGImagePropertyPixelHeight] as? Int)
        }
        let wide = try PersonalAgentImagePreparation.prepared(try picture(3000, 1200, .png, "wide.png"), name: "wide.png", mimeType: "image/png")
        XCTAssertEqual(wide.name, "wide.png")
        XCTAssertEqual(wide.mimeType, "image/png")
        XCTAssertEqual(size(wide.data).0, 2048)
        XCTAssertEqual(size(wide.data).1, 819)
        let small = try picture(200, 100, .png, "small.png")
        XCTAssertEqual(try PersonalAgentImagePreparation.prepared(small, name: "small.png", mimeType: "image/png").data,
                       try Data(contentsOf: small))
        let heic = try picture(400, 300, .heic, "photo.heic")
        let converted = try PersonalAgentImagePreparation.prepared(heic, name: "photo.heic", mimeType: "image/heic")
        XCTAssertEqual(converted.name, "photo.jpg")
        XCTAssertEqual(converted.mimeType, "image/jpeg")
        XCTAssertEqual(Array(converted.data.prefix(2)), [0xFF, 0xD8])
        let broken = folder.appending(path: "broken.heic")
        try Data("not a picture".utf8).write(to: broken)
        XCTAssertThrowsError(try PersonalAgentImagePreparation.prepared(broken, name: "broken.heic", mimeType: "image/heic")) {
            XCTAssertEqual($0 as? PersonalAgentFailure, .filePreparation)
        }
        let document = folder.appending(path: "notes.txt")
        try Data("text".utf8).write(to: document)
        XCTAssertEqual(try PersonalAgentImagePreparation.prepared(document, name: "notes.txt", mimeType: "text/plain").data, Data("text".utf8))
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

    /// The room's state rides the messaging socket: its topic is subscribed there, its stream opens
    /// only once that subscription is answered, and only the subscription the stream names is shown.
    /// A reply for the room's topic is told from the messaging one by its command id, not by its type.
    func testRoomLiveRidesTheMessagingSocketAndShowsOnlyItsBoundSubscription() async throws {
        let hub = DotsLiveHub()
        DotsLiveHub.current = hub
        let sockets = DotsSocketFactory(answersSubscriptions: false)
        let service = makeService(DotsHTTPRecorder(), broker: DotsTestBroker(), sockets: sockets, timing: Self.fastLive)
        let messaging = DotsCollected(await service.updates(for: agent))
        try await waitUntil { sockets.sockets.first?.command("subscribe", topic: "calpico-chatgpt-messaging") != nil }
        let first = sockets.sockets[0]
        first.push(#"[{"id":2,"reply":{"type":"subscribe","topic_id":"calpico-chatgpt-messaging","recovered":false}}]"#)
        try await waitUntil { messaging.values.contains { if case .connected = $0 { true } else { false } } }

        let live = DotsCollected(await service.liveState(for: agent))
        let topic = "calpico-room-live:room"
        try await waitUntil { first.command("subscribe", topic: topic) != nil }
        let subscribe = try XCTUnwrap(first.command("subscribe", topic: topic))
        XCTAssertGreaterThan(subscribe, 2, "The room's topic has its own command")
        // Before the stream names its subscription: another one's newer state, then this one's, newest kept.
        first.push(Self.state(subscription: "other", revision: 9, label: "Someone else's work"))
        first.push(Self.state(subscription: "s1", revision: 3, label: "Drafting the plan"))
        first.push(Self.state(subscription: "s1", revision: 2, label: "An older state"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(hub.count, 0, "Nothing registers before the topic is subscribed")
        first.push(#"[{"id":\#(subscribe),"reply":{"type":"subscribe","topic_id":"\#(topic)","recovered":false}}]"#)
        try await waitUntil { hub.count == 1 }
        let post = try XCTUnwrap(hub.requests.first)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.url?.path, "/backend-api/messaging/rooms/room/live")
        XCTAssertNil(post.httpBody, "The observer's request carries no body")
        XCTAssertNil(post.httpBodyStream)
        XCTAssertEqual(post.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertNotNil(post.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(post.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account")
        XCTAssertNil(post.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(messaging.values.filter { if case .connected = $0 { true } else { false } }.count, 1,
                       "The room's subscription reply does not count as the conversation's")

        hub.ready("s1")
        try await waitUntil { live.states.last??.revision == 3 }
        XCTAssertEqual(live.states.compactMap { $0 }.map(\.subscriptionID), ["s1"], "Only the bound subscription is shown")
        XCTAssertEqual(live.states.last??.threads.first?.activityLabel, "Drafting the plan")
        // A repeated revision and another subscription change nothing; a newer revision does.
        first.push(Self.state(subscription: "s1", revision: 3, label: "Repeated"))
        first.push(Self.state(subscription: "other", revision: 10, label: "Someone else's work"))
        first.push(Self.state(subscription: "s1", revision: 4, label: "Reviewing", active: false, turn: "completed"))
        try await waitUntil { live.states.last??.revision == 4 }
        XCTAssertEqual(live.states.compactMap { $0 }.map(\.revision), [3, 4])

        // The socket drops: what was shown is cleared, and on the next socket the topic and the stream
        // register again, with a new subscription whose revisions start over.
        first.drop()
        try await waitUntil { live.states.last == .some(nil) }
        try await waitUntil(timeout: .seconds(10)) { sockets.sockets.count == 2 }
        let second = sockets.sockets[1]
        try await waitUntil { second.command("subscribe", topic: "calpico-chatgpt-messaging") != nil }
        second.push(#"[{"id":2,"reply":{"type":"subscribe","topic_id":"calpico-chatgpt-messaging","recovered":false}}]"#)
        try await waitUntil { second.command("subscribe", topic: topic) != nil }
        let again = try XCTUnwrap(second.command("subscribe", topic: topic))
        second.push(#"[{"id":\#(again),"reply":{"type":"subscribe","topic_id":"\#(topic)","recovered":true}}]"#)
        try await waitUntil { hub.count == 2 }
        XCTAssertEqual(hub.openCount, 1, "The first attempt's stream was cancelled with it")
        hub.ready("s2")
        second.push(Self.state(subscription: "s2", revision: 0, label: "Working again"))
        try await waitUntil { live.states.last??.subscriptionID == "s2" }

        // A state for another room ends the observation for good: the topic is left and nothing registers again.
        second.push(Self.state(subscription: "s2", revision: 1, label: "Elsewhere", room: "elsewhere"))
        try await waitUntil { live.states.last == .some(nil) && second.command("unsubscribe", topic: topic) != nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(hub.count, 2)
        XCTAssertEqual(hub.openCount, 0)
        XCTAssertEqual(messaging.values.filter { if case .connected = $0 { true } else { false } }.count, 2)
        await service.stop()
    }

    /// Statuses the provider's client registers again after, and ones it does not; a stream's end, an
    /// error event, a room the server cannot show, another account and a cancelled observer.
    func testRoomLiveRegistersAgainOnlyWhereTheProvidersClientDoes() async throws {
        // A server error, a stream that says it is done, and a temporary unavailability each register again.
        let hub = DotsLiveHub(replies: [(503, "application/json"), (200, "text/event-stream"), (200, "text/event-stream"),
                                        (429, "application/json")])
        DotsLiveHub.current = hub
        let sockets = DotsSocketFactory()
        let service = makeService(DotsHTTPRecorder(), broker: DotsTestBroker(), sockets: sockets, timing: Self.fastLive)
        let messaging = DotsCollected(await service.updates(for: agent))
        try await waitUntil { messaging.values.contains { if case .connected = $0 { true } else { false } } }
        let live = DotsCollected(await service.liveState(for: agent))
        try await waitUntil { hub.count == 2 }
        hub.ready("s1")
        let socket = sockets.sockets[0]
        socket.push(Self.state(subscription: "s1", revision: 1, label: "Working"))
        try await waitUntil { live.states.last??.revision == 1 }
        hub.send("data: [DONE]\n\n")
        try await waitUntil { hub.count == 3 }
        hub.ready("s2")
        socket.push(#"[{"type":"message","topic_id":"calpico-room-live:room","payload":{"type":"calpico-room-live","payload":{"type":"calpico-room-live-error","version":1,"room_id":"room","subscription_id":"s2","revision":0,"code":"temporarily_unavailable"}}}]"#)
        try await waitUntil { hub.count == 4 }
        // The fourth attempt's 429 registers a fifth; the hub answers it with a stream again.
        try await waitUntil { hub.count == 5 }
        live.cancel()
        try await waitUntil { hub.openCount == 0 && socket.command("unsubscribe", topic: "calpico-room-live:room") != nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(hub.count, 5, "An ended observer registers nothing")
        await service.stop()

        // Each of these ends the observation for good.
        let endings: [(String, [(Int, String)], (DotsLiveHub, DotsFakeSocket) -> Void)] = [
            ("not found", [(404, "application/json")], { _, _ in }),
            ("not an event stream", [(200, "application/json")], { _, _ in }),
            ("error event", [], { hub, _ in hub.send(#"data: {"error":"denied"}"# + "\n\n") }),
            ("room unavailable", [], { hub, socket in
                hub.ready("s1")
                socket.push(#"[{"type":"message","topic_id":"calpico-room-live:room","payload":{"type":"calpico-room-live","payload":{"type":"calpico-room-live-error","version":1,"room_id":"room","subscription_id":"s1","revision":0,"code":"room_unavailable"}}}]"#)
            }),
            ("another room's ready", [], { hub, _ in hub.ready("s1", room: "elsewhere") })
        ]
        for (name, replies, end) in endings {
            let hub = DotsLiveHub(replies: replies)
            DotsLiveHub.current = hub
            let sockets = DotsSocketFactory()
            let service = makeService(DotsHTTPRecorder(), broker: DotsTestBroker(), sockets: sockets, timing: Self.fastLive)
            let messaging = DotsCollected(await service.updates(for: agent))
            try await waitUntil { messaging.values.contains { if case .connected = $0 { true } else { false } } }
            let live = DotsCollected(await service.liveState(for: agent))
            try await waitUntil { hub.count == 1 }
            end(hub, sockets.sockets[0])
            try await waitUntil { sockets.sockets[0].command("unsubscribe", topic: "calpico-room-live:room") != nil }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(hub.count, 1, "\(name) registers nothing again")
            XCTAssertTrue(live.states.allSatisfy { $0 == nil }, "\(name) shows nothing")
            await service.stop()
        }

        // Another account by the time the stream would open: nothing is sent.
        let other = DotsLiveHub()
        DotsLiveHub.current = other
        let switching = DotsSocketFactory()
        let switched = makeService(DotsHTTPRecorder(), broker: DotsTestBroker(changesAccountAt: 4), sockets: switching,
                                   timing: Self.fastLive)
        let switchedMessages = DotsCollected(await switched.updates(for: agent))
        try await waitUntil { switchedMessages.values.contains { if case .connected = $0 { true } else { false } } }
        // Read only after the observer has ended: the failure is its last word, not overwritten.
        let switchedLive = await switched.liveState(for: agent)
        try await waitUntil { switching.sockets[0].command("unsubscribe", topic: "calpico-room-live:room") != nil }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(other.count, 0, "A changed account opens no stream")
        // The window hears of it, as it does from any read, and clears the account's reading.
        var heard = switchedLive.makeAsyncIterator()
        let last = await heard.next()
        XCTAssertEqual(last, .failed(.accountChanged))
        let after = await heard.next()
        XCTAssertNil(after, "Nothing follows the failure")
        await switched.stop()
    }

    /// An attempt that sees no state in time registers again.
    func testRoomLiveRegistersAgainWhenNoStateArrivesInTime() async throws {
        let hub = DotsLiveHub()
        DotsLiveHub.current = hub
        let sockets = DotsSocketFactory()
        var timing = Self.fastLive
        timing.watchdog = .milliseconds(300)
        let service = makeService(DotsHTTPRecorder(), broker: DotsTestBroker(), sockets: sockets, timing: timing)
        let messaging = DotsCollected(await service.updates(for: agent))
        try await waitUntil { messaging.values.contains { if case .connected = $0 { true } else { false } } }
        let live = DotsCollected(await service.liveState(for: agent))
        try await waitUntil { hub.count == 1 }
        hub.ready("s1")
        try await waitUntil { hub.count == 2 }
        XCTAssertEqual(hub.openCount, 1)
        XCTAssertTrue(live.states.allSatisfy { $0 == nil })
        await service.stop()
    }

    private static let fastLive = DotsLiveTiming(watchdog: .seconds(5), firstRetry: .milliseconds(20),
                                                 longestRetry: .milliseconds(80), computerHold: .milliseconds(150),
                                                 resubscribe: .milliseconds(50))

    /// A room-live state as the socket frames it: one attached thread on an in-progress turn.
    private static func state(subscription: String, revision: Int, label: String, active: Bool = true,
                              turn: String = "in_progress", room: String = "room") -> String {
        let payload: JSONValue = .object([
            "type": .string("calpico-room-live-state"), "version": .integer(1), "room_id": .string(room),
            "subscription_id": .string(subscription), "revision": .integer(Int64(revision)),
            "threads": .array([.object([
                "thread_id": .string("thread"), "stream_state": .string("attached"), "turn_id": .string("turn"),
                "turn_status": .string(turn), "is_active": .bool(active), "unread_extra": .string("ignored"),
                "activity_status": .object(["status_type": .string("Working"), "status_label": .string(label)])])])])
        let frame: JSONValue = .array([.object(["type": .string("message"), "topic_id": .string("calpico-room-live:room"),
            "payload": .object(["type": .string("calpico-room-live"), "payload": payload])])])
        return String(decoding: try! JSONEncoder().encode(frame), as: UTF8.self)
    }

    private var agent: PersonalAgent {
        .init(id: .init(accountID: "account", userID: "person", agentID: "dot", roomID: "room"),
              name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
    }

    private func makeService(_ fixture: DotsHTTPRecorder, broker: DotsTestBroker, sockets: DotsSocketFactory? = nil,
                             timing: DotsLiveTiming = .init()) -> DotsService {
        DotsHTTPProtocol.current = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DotsHTTPProtocol.self]
        var socket: (@Sendable (URL, URLSession) -> any DotsEventSocket)?
        if let sockets { socket = { _, _ in sockets.make() } }
        return DotsService(executable: URL(filePath: "/usr/bin/false"), environmentManager: nil, connection: nil,
                           transport: broker, configuration: configuration, liveTiming: timing, socket: socket)
    }
}

private final class DotsHTTPRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var statuses: [Int]
    private let room: String
    init(postStatuses: [Int] = [200],
         room: String = #"{"id":"room","aeon_id":"dot","type":"DM","app_source":"chatgpt:messaging","members":[{"account_user_id":"person","role":"user"}]}"#) {
        statuses = postStatuses
        self.room = room
    }
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
            if request.url?.path == "/backend-api/celsius/ws/user" {
                return (200, Data(#"{"websocket_url":"wss://ws.chatgpt.com/ws/user"}"#.utf8))
            }
            if request.url?.path.hasSuffix("/files/file") == true {
                return (200, Data(#"{"name":"report.txt","download_url":"https://files.oaiusercontent.com/file"}"#.utf8))
            }
            if request.httpMethod == "POST", request.url?.path.hasSuffix("/files") == true {
                return (200, Data(#"{"id":"file_1","status":"ready"}"#.utf8))
            }
            if request.url?.path.hasSuffix("/elicitation/response") == true {
                return (statuses.isEmpty ? 200 : statuses.removeFirst(), Data(#"{"status":"applied"}"#.utf8))
            }
            if request.url?.path.hasSuffix("/elicitation") == true {
                return (200, Data(#"{"elicitation":{"request_id":"request","thread_id":"thread","turn_id":null,"status":"pending","params":{"threadId":"thread","message":"Confirm"}},"can_respond":true,"runtime_status":"pending","request_fingerprint":"fingerprint"}"#.utf8))
            }
            if request.httpMethod == "POST" {
                let status = statuses.isEmpty ? 200 : statuses.removeFirst()
                let body = (try? JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())) ?? .null
                let result: JSONValue = .object(["id": .string("server-message"), "account_user_id": .string("person"),
                    "request_id": body["request_id"] ?? .null, "content": body["content"] ?? .null])
                return (status, try! JSONEncoder().encode(result))
            }
            return (200, Data(room.utf8))
        }
    }
}

private final class DotsHTTPProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var current: DotsHTTPRecorder?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var loadingThread: Thread?
    override func startLoading() {
        if request.url?.path.hasSuffix("/live") == true, let hub = DotsLiveHub.current {
            loadingThread = .current
            let (status, type) = hub.open(self)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if status != 200 { client?.urlProtocolDidFinishLoading(self) }
            return
        }
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
    override func stopLoading() { DotsLiveHub.current?.close(self) }

    /// Events and the end of a room-live stream, on the thread the stream loads on.
    func deliver(_ text: String) {
        guard let thread = loadingThread else { return }
        perform(#selector(load(_:)), on: thread, with: Data(text.utf8) as NSData, waitUntilDone: false)
    }

    func end() {
        guard let thread = loadingThread else { return }
        perform(#selector(finish), on: thread, with: nil, waitUntilDone: false)
    }

    @objc private func load(_ data: NSData) { client?.urlProtocol(self, didLoad: data as Data) }
    @objc private func finish() { client?.urlProtocolDidFinishLoading(self) }
}

/// The room-live streams the service opened, in order: each one's request, and whether it is still open.
private final class DotsLiveHub: @unchecked Sendable {
    nonisolated(unsafe) static var current: DotsLiveHub?
    private let lock = NSLock()
    private var streams: [(request: URLRequest, stream: DotsHTTPProtocol, open: Bool)] = []
    /// Each stream's status and content type, in order; then 200 and an event stream.
    private var replies: [(Int, String)]
    init(replies: [(Int, String)] = []) { self.replies = replies }

    var requests: [URLRequest] { lock.withLock { streams.map(\.request) } }
    var count: Int { lock.withLock { streams.count } }
    var openCount: Int { lock.withLock { streams.filter(\.open).count } }

    func open(_ stream: DotsHTTPProtocol) -> (Int, String) {
        lock.withLock {
            let reply = replies.isEmpty ? (200, "text/event-stream") : replies.removeFirst()
            streams.append((stream.request, stream, reply.0 == 200))
            return reply
        }
    }

    func close(_ stream: DotsHTTPProtocol) {
        lock.withLock { if let index = streams.firstIndex(where: { $0.stream === stream }) { streams[index].open = false } }
    }

    /// Sends `text` on the newest stream.
    func send(_ text: String) { lock.withLock { streams.last?.stream }?.deliver(text) }
    func end() { lock.withLock { streams.last?.stream }?.end() }
    func ready(_ subscription: String, room: String = "room") {
        send("event: ping\ndata: {}\n\n")
        send(#"data: {"type":"calpico-room-live-ready","version":1,"room_id":"\#(room)","subscription_id":"\#(subscription)"}"# + "\n\n")
    }
}

/// The user's event socket as a test stands in for it: what Yardlet sent, and what the provider says.
/// Subscriptions can be answered as the provider answers them.
private final class DotsFakeSocket: DotsEventSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [JSONValue] = []
    private var incoming: [String] = []
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var closed = false
    let answersSubscriptions: Bool
    init(answersSubscriptions: Bool) { self.answersSubscriptions = answersSubscriptions }

    var commands: [JSONValue] { lock.withLock { sent } }
    func command(_ type: String, topic: String) -> Int64? {
        commands.last { $0["command"]?["type"]?.stringValue == type && $0["command"]?["topic_id"]?.stringValue == topic }
            .flatMap { if case let .integer(id)? = $0["id"] { id } else { nil } }
    }

    func resume() { }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case let .string(text) = message, case let .array(frames)? = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        else { return }
        lock.withLock { sent += frames }
        guard answersSubscriptions else { return }
        for frame in frames where frame["command"]?["type"]?.stringValue == "subscribe" {
            let reply: JSONValue = .array([.object(["id": frame["id"] ?? .null, "reply": .object([
                "type": .string("subscribe"), "topic_id": frame["command"]?["topic_id"] ?? .null, "recovered": .bool(false)])])])
            push(String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if !incoming.isEmpty { continuation.resume(returning: .string(incoming.removeFirst())) }
                else if closed { continuation.resume(throwing: URLError(.networkConnectionLost)) }
                else { waiter = continuation }
            }
        }
    }

    func push(_ text: String) {
        lock.withLock {
            if let waiter { self.waiter = nil; waiter.resume(returning: .string(text)) } else { incoming.append(text) }
        }
    }

    /// The provider drops the connection.
    func drop() {
        lock.withLock {
            closed = true
            waiter?.resume(throwing: URLError(.networkConnectionLost))
            waiter = nil
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { drop() }
}

private final class DotsSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [DotsFakeSocket] = []
    let answersSubscriptions: Bool
    init(answersSubscriptions: Bool = true) { self.answersSubscriptions = answersSubscriptions }
    var sockets: [DotsFakeSocket] { lock.withLock { made } }
    func make() -> DotsFakeSocket {
        let socket = DotsFakeSocket(answersSubscriptions: answersSubscriptions)
        lock.withLock { made.append(socket) }
        return socket
    }
}

private extension DotsCollected where Value == PersonalAgentLiveUpdate {
    /// The states shown, without the failures.
    var states: [PersonalAgentLiveState?] { values.compactMap { if case let .state(state) = $0 { state } else { nil } } }
}

/// Everything a stream yields, as it yields it.
private final class DotsCollected<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [Value] = []
    private var task: Task<Void, Never>?
    init(_ stream: AsyncStream<Value>) {
        task = Task { [weak self] in for await value in stream { self?.lock.withLock { self?.collected.append(value) } } }
    }
    var values: [Value] { lock.withLock { collected } }
    func cancel() { task?.cancel() }
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
