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

    /// An ordinary reply names only the message it answers; an option answer also names its choice;
    /// any other mix, half an option answer included, sends nothing. A thread's pages read on their
    /// own cursor, which ends where the provider names none or repeats one.
    func testOrdinaryRepliesAndOptionAnswersAreSeparateAndThreadPagesEndOnTheirOwnCursor() async throws {
        let fixture = DotsHTTPRecorder(postStatuses: [200, 200])
        let service = makeService(fixture, broker: DotsTestBroker())
        var reply = PersonalAgentSubmission(text: "Please check this section.")
        reply.replyTarget = .init(messageID: "parent", rootID: "root")
        _ = try await service.send(reply, to: agent)
        var answer = PersonalAgentSubmission(text: "Tuesday")
        answer.replyToMessageID = "question"
        answer.optionSelection = 1
        _ = try await service.send(answer, to: agent)
        let bodies = try fixture.requests.filter { $0.httpMethod == "POST" }.map {
            try JSONDecoder().decode(JSONValue.self, from: fixture.body($0))
        }
        XCTAssertEqual(bodies.map { $0["reply_to"] }, [.object(["message_id": .string("parent")]),
                                                     .object(["message_id": .string("question")])])
        XCTAssertNil(bodies[0]["message_metadata"], "An ordinary reply carries no option")
        XCTAssertEqual(bodies[1]["message_metadata"], .object(["option_picker": .object(["selection": .integer(1)])]))
        XCTAssertEqual(bodies[0]["idempotency_token"]?.stringValue, reply.requestID)

        var mixed = reply
        mixed.optionSelection = 0
        var half = PersonalAgentSubmission(text: "Tuesday")
        half.optionSelection = 1
        var unchosen = PersonalAgentSubmission(text: "Tuesday")
        unchosen.replyToMessageID = "question"
        for refused in [mixed, half, unchosen] {
            do { _ = try await service.send(refused, to: agent); XCTFail("Expected a refusal") }
            catch { XCTAssertEqual(error as? PersonalAgentFailure, .sendRejected) }
        }
        XCTAssertEqual(fixture.requests.filter { $0.httpMethod == "POST" }.count, 2, "A mixed request is never posted")
        await service.stop()

        // A room only shared with the person takes no reply, as it takes no file; nothing is posted.
        let shared = DotsHTTPRecorder(room: #"{"id":"room","aeon_id":"dot","type":"DM","app_source":"chatgpt:messaging","dm_lifecycle_state":"share_only","members":[]}"#)
        let gated = makeService(shared, broker: DotsTestBroker())
        do { _ = try await gated.send(reply, to: agent); XCTFail("Expected the room to refuse a reply") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .repliesNotAllowed) }
        _ = try await gated.send(.init(text: "A plain message still goes"), to: agent)
        XCTAssertEqual(shared.requests.filter { $0.httpMethod == "POST" }.count, 1)
        await gated.stop()

        // The latest page names its parent and its thread apart; the earlier page names no cursor, which
        // ends the thread rather than falling back to its oldest message.
        let item = { (id: String, extra: String) in
            #"{"id":"\#(id)","account_user_id":"person","created_at":"2026-10-31T01:00:00Z","content":{"text":"\#(id)","attachments":[]}\#(extra)}"#
        }
        let threaded = DotsHTTPRecorder(pages: [
            "": #"{"items":["# + item("r2", #","reply_root_message_id":"root","reply_to":{"message_id":"r1","message":{"id":"r1","deleted_at":"2026-10-31T01:05:00Z","content":{"text":"Gone","attachments":[]},"reply_to":{"message_id":"root"}}}"#)
                + "," + item("r3", #","reply_root_message_id":"root","reply_to":{"message_id":"root","message":{"id":"root","content":{"text":"Question","attachments":[{"type":"file","file_id":"f"}]}}}"#)
                + #"],"prev_cursor":"c1"}"#,
            "c1": #"{"items":["# + item("r1", #","reply_root_message_id":"root","reply_to":{"message_id":"root"}"#) + #"],"prev_cursor":null}"#,
            "loop": #"{"items":["# + item("r0", "") + #"],"prev_cursor":"loop"}"#
        ])
        let reader = makeService(threaded, broker: DotsTestBroker())
        let latest = try await reader.replies(to: "root", for: agent, before: nil)
        XCTAssertEqual(latest.messages.map(\.replyToMessageID), ["r1", "root"])
        XCTAssertEqual(latest.messages.map(\.replyRootMessageID), ["root", "root"])
        XCTAssertEqual(latest.messages[0].replyPreview, .init(messageID: "r1", text: "", hasAttachments: false, isDeleted: true),
                       "A deleted parent's preview keeps nothing of what it said")
        XCTAssertEqual(latest.messages[1].replyPreview, .init(messageID: "root", text: "Question", hasAttachments: true, isDeleted: false))
        XCTAssertEqual(latest.before, "c1")
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(threaded.requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(Set(query), [.init(name: "limit", value: "20"), .init(name: "reply_root_message_id", value: "root")])
        let earlier = try await reader.replies(to: "root", for: agent, before: "c1")
        XCTAssertEqual(earlier.messages.map(\.id), ["r1"])
        XCTAssertNil(earlier.before, "A thread page without a cursor is the thread's first")
        let repeated = try await reader.replies(to: "root", for: agent, before: "loop")
        XCTAssertNil(repeated.before, "A cursor that comes back unchanged ends the thread")
        XCTAssertFalse(threaded.requests.contains { $0.url?.query?.contains("after=") == true || $0.url?.query?.contains("around=") == true })
        // The room's own pages keep their fallback to the oldest message.
        let room = try await reader.messages(for: agent, before: "c1")
        XCTAssertEqual(room.before, "r1")
        await reader.stop()
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
        // A picture's thumbnail is the same room file read, with the same credentials, and only a picture.
        let photo = PersonalAgentAttachment(fileID: "photo", name: "photo.png", type: "file", mimeType: "image/png")
        let photoData = try await service.image(photo, for: agent)
        XCTAssertEqual(photoData, Data("PNG".utf8))
        let photoRead = try XCTUnwrap(fixture.requests.first { $0.url?.path == "/photo" })
        XCTAssertNil(photoRead.value(forHTTPHeaderField: "Authorization"), "A signed picture is read without the account token")
        let disguised = PersonalAgentAttachment(fileID: "file", name: "chart.png", type: "file", mimeType: "image/png")
        do { _ = try await service.image(disguised, for: agent); XCTFail("Storage that answers with no picture is refused") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .attachmentUnavailable) }
        let before = fixture.requests.count
        let notes = PersonalAgentAttachment(fileID: "file", name: "notes.png", type: "file", mimeType: "text/plain")
        do { _ = try await service.image(notes, for: agent); XCTFail("A file declared as another type is no picture") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .attachmentUnavailable) }
        XCTAssertEqual(fixture.requests.count, before, "A file that is no picture is not read for one")
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

    /// The app's watch rides the same messaging topic for several rooms, each change naming its room;
    /// a room it did not ask for is not reported, and another login's dots are not watched at all.
    func testRoomUpdatesNameTheChangedRoomOnTheSameTopic() async throws {
        let sockets = DotsSocketFactory(answersSubscriptions: false)
        let service = makeService(DotsHTTPRecorder(), broker: DotsTestBroker(), sockets: sockets)
        let second = PersonalAgent(id: .init(accountID: "account", userID: "person", agentID: "dot-2", roomID: "room-2"),
                                   name: "Second", rootThreadID: nil, isPaused: false, isPrimary: false)
        let mixed = PersonalAgent(id: .init(accountID: "elsewhere", userID: "person", agentID: "dot", roomID: "room-3"),
                                  name: "Other", rootThreadID: nil, isPaused: false, isPrimary: false)
        let none = DotsCollected(await service.roomUpdates(for: [agent, mixed]))
        let updates = DotsCollected(await service.roomUpdates(for: [agent, second]))
        try await waitUntil { sockets.sockets.first?.command("subscribe", topic: "calpico-chatgpt-messaging") != nil }
        let socket = sockets.sockets[0]
        socket.push(#"[{"id":2,"reply":{"type":"subscribe","topic_id":"calpico-chatgpt-messaging","recovered":false}}]"#)
        for room in ["room-2", "elsewhere", "room"] {
            socket.push(#"[{"type":"message","topic_id":"calpico-chatgpt-messaging","payload":{"type":"x","payload":{"room_id":"\#(room)"}}}]"#)
        }
        try await waitUntil { updates.values.count == 3 }
        XCTAssertEqual(updates.values, [.connected, .changed(roomID: "room-2"), .changed(roomID: "room")])
        XCTAssertTrue(none.values.isEmpty)
        XCTAssertEqual(sockets.sockets.count, 1)
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

    /// A task's execution record is read from the provider's history host, only for a task this reader
    /// saw in the dot's own Activity, under the same login, with GETs only and nothing else: no cookie,
    /// no message, no write. Each read names the thread's product as the provider's app does, and a
    /// reply that names another thread, or none, is not the record.
    func testActivityHistoryReadsOnlyListedTasksFromTheHistoryHost() async throws {
        let fixture = DotsHTTPRecorder()
        let service = makeService(fixture, broker: DotsTestBroker())
        do { _ = try await service.activityThread("task", for: agent); XCTFail("Nothing listed yet") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .accessDenied) }
        XCTAssertTrue(fixture.requests.isEmpty)
        let dots = try await service.agents()
        let dot = try XCTUnwrap(dots.first)
        _ = try await service.activity(for: dot, cursor: nil)

        let thread = try await service.activityThread("task", for: dot)
        XCTAssertTrue(thread.turns.isEmpty, "The metadata's turns never stand for the record")
        let turns = try await service.activityTurns("task", cursor: nil, for: dot)
        XCTAssertEqual(turns.turns.map(\.id), ["t1", "t2"], "Asked newest first, kept oldest first")
        let items = try await service.activityItems("task", turnID: "t2", cursor: nil, for: dot)
        XCTAssertEqual(items.entries.map(\.item.id), ["i"])
        _ = try await service.activityTurns("root", cursor: nil, for: dot)
        _ = try await service.activityThread("plain", for: dot)
        _ = try await service.activityTurns("plain", cursor: nil, for: dot)

        let history = fixture.requests.filter { $0.url?.host == "codex-cloud-backend.chatgpt.com" }
        XCTAssertEqual(history.map { $0.url!.path }, ["/v1/threads/task", "/v2/threads/task/turns", "/v2/threads/task/items",
                                                     "/v2/threads/root/turns", "/v1/threads/plain", "/v2/threads/plain/turns"])
        XCTAssertEqual(history.map { $0.value(forHTTPHeaderField: "X-OpenAI-Product-Sku") },
                       ["unknown", "aeon", "aeon", "aeon", "unknown", "codex"])
        func query(_ request: URLRequest) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        }
        XCTAssertEqual(query(history[1]), ["limit": "5", "sortDirection": "desc", "itemsView": "notLoaded"])
        XCTAssertEqual(query(history[2]), ["turnId": "t2", "limit": "100", "sortDirection": "asc"])
        for request in fixture.requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.url!.path.contains("/messaging/"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization") != nil,
                           ["chatgpt.com", "codex-cloud-backend.chatgpt.com"].contains(request.url!.host), "\(request.url!)")
        }

        // Another thread's metadata, a missing task, another dot's or account's task.
        do { _ = try await service.activityThread("other-task", for: dot); XCTFail("Another thread's metadata") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .invalidResponse) }
        do { _ = try await service.activityThread("gone", for: dot); XCTFail("A task the provider no longer has") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .missing) }
        let otherDot = PersonalAgent(id: .init(accountID: "account", userID: "person", agentID: "dot-2", roomID: "room-2"),
                                     name: "Juniper", rootThreadID: nil, isPaused: false, isPrimary: false)
        let otherAccount = PersonalAgent(id: .init(accountID: "elsewhere", userID: "person", agentID: "dot", roomID: "room"),
                                         name: "Atlas", rootThreadID: "root", isPaused: false, isPrimary: true)
        let before = fixture.requests.count
        for (forged, expected) in [(otherDot, PersonalAgentFailure.accessDenied), (otherAccount, .accountChanged)] {
            do { _ = try await service.activityItems("task", turnID: "t2", cursor: nil, for: forged); XCTFail("\(forged.id)") }
            catch { XCTAssertEqual(error as? PersonalAgentFailure, expected) }
        }
        XCTAssertEqual(fixture.requests.count, before, "Nothing is asked for a task this reader did not list")
        await service.stop()
    }

    /// The Outputs read only the dot's own threads: its root, once its profile names this dot and root,
    /// the threads the profile binds, and a child whose metadata names one of them as its parent, by
    /// `parentThreadId` or its subagent spawn. Nothing widens the Activity's list, and a thread outside
    /// these is refused before anything is asked.
    func testOutputsReadOnlyTheDotsBoundThreadsAndVerifiedChildren() async throws {
        let fixture = DotsHTTPRecorder()
        let service = makeService(fixture, broker: DotsTestBroker())
        let dots = try await service.agents()
        let dot = try XCTUnwrap(dots.first)
        let threads = try await service.outputThreads(for: dot)
        XCTAssertEqual(threads, ["root", "bound", "plain"], "The root first, each bound thread once, across pages")
        XCTAssertEqual(fixture.requests.filter { $0.url!.path == "/backend-api/tbo/dot/threads" }
            .map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "cursor" }?.value },
                       [nil, "next"])
        _ = try await service.outputTurns("bound", cursor: nil, for: dot)
        let child = try await service.outputChild("child", of: "bound", for: dot)
        XCTAssertEqual(child?.id, "child")
        _ = try await service.outputItems("child", turnID: "t2", cursor: nil, for: dot)
        let stranger = try await service.outputChild("stranger", of: "bound", for: dot)
        XCTAssertNil(stranger, "A thread naming another parent is not this one's child")
        let before = fixture.requests.count
        do { _ = try await service.outputTurns("stranger", cursor: nil, for: dot); XCTFail("Not admitted") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .accessDenied) }
        do { _ = try await service.activityTurns("bound", cursor: nil, for: dot); XCTFail("The Activity's list is its own") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .accessDenied) }
        XCTAssertEqual(fixture.requests.count, before, "Nothing is asked for a thread outside the dot's")
        XCTAssertTrue(fixture.requests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Cookie") == nil })

        // A profile that names another root is not this dot's.
        let moved = DotsHTTPRecorder(profile: #"{"id":"dot","active_root_thread_id":"elsewhere"}"#)
        let other = makeService(moved, broker: DotsTestBroker())
        let others = try await other.agents()
        let same = try XCTUnwrap(others.first)
        do { _ = try await other.outputThreads(for: same); XCTFail("Another root") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .invalidResponse) }
        XCTAssertFalse(moved.requests.contains { $0.url!.path == "/backend-api/tbo/dot/threads" })
        await service.stop()
        await other.stop()
    }

    /// A file on the dot's computer is read over the execution host's socket as Yardlet: its own name,
    /// no app verification, metadata then bytes, on the computer its thread's metadata names, or its
    /// verified parent's when it names none. Asked to verify the app, it refuses and stops; a file too
    /// large is refused whole; a computer that cannot be told opens no socket.
    func testRemoteOutputFilesAreReadOverTheExecutionSocketAsYardlet() async throws {
        let fixture = DotsHTTPRecorder()
        let durable = DotsDurableSockets()
        let service = makeService(fixture, broker: DotsTestBroker(), durable: durable)
        let dots = try await service.agents()
        let dot = try XCTUnwrap(dots.first)
        _ = try await service.outputThreads(for: dot)
        _ = try await service.outputChild("child", of: "bound", for: dot)

        durable.script = .file(Data("report".utf8))
        let file = PersonalAgentRemoteFile(path: "/mnt/data/report.pdf", threadID: "root", environmentID: "env")
        let download = try await service.outputFile(file, for: dot)
        XCTAssertEqual(download.data, Data("report".utf8))
        XCTAssertEqual(download.name, "report.pdf")
        let first = try XCTUnwrap(durable.sockets.first)
        XCTAssertEqual(first.sent.map { $0["method"]?.stringValue }, ["initialize", "fs/getMetadata", "fs/readFile"])
        XCTAssertEqual(first.sent[0]["params"]?["clientInfo"]?["name"]?.stringValue, "yardlet")
        XCTAssertEqual(first.sent[0]["params"]?["capabilities"], .object(["experimentalApi": .bool(true), "requestAttestation": .bool(false)]))
        XCTAssertEqual(first.sent[2]["params"], .object(["environmentId": .string("env"), "path": .string("/mnt/data/report.pdf")]))
        XCTAssertNil(first.sent.first { $0["method"]?.stringValue == "initialized" }, "No separate initialized notice")
        let request = try XCTUnwrap(durable.requests.first)
        XCTAssertEqual(request.url, DotsDurableFiles.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "The credential rides only in the socket's protocol")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(first.closed)

        // A child whose metadata names no computer reads on its verified parent's.
        durable.script = .file(Data())
        let empty = try await service.outputFile(.init(path: "/mnt/data/empty.txt", threadID: "child", environmentID: "bound-env"), for: dot)
        XCTAssertEqual(empty.data, Data(), "An empty file is empty, not missing")
        XCTAssertEqual(durable.sockets.last?.sent.last?["params"]?["environmentId"]?.stringValue, "bound-env")

        // Asked to verify the app, before or after the host is ready: refused, and the read ends.
        for early in [true, false] {
            durable.script = .attestation(early: early)
            do { _ = try await service.outputFile(file, for: dot); XCTFail("Verification is not supported") }
            catch {
                XCTAssertEqual(error as? DotsRemoteFileError,
                               .init(stage: early ? .initialize : .metadata, code: nil, failure: .verificationUnsupported))
            }
            let socket = try XCTUnwrap(durable.sockets.last)
            XCTAssertEqual(socket.sent.last?["error"]?["code"], .integer(-32601))
            XCTAssertFalse(socket.sent.contains { $0["method"]?.stringValue == "fs/readFile" })
            XCTAssertTrue(socket.closed)
        }
        durable.script = .encoded(String(repeating: "A", count: (DotsDurableFiles.maximumBytes + 2) / 3 * 4 + 4))
        do { _ = try await service.outputFile(file, for: dot); XCTFail("Too large") }
        catch { XCTAssertEqual(error as? DotsRemoteFileError, .init(stage: .contents, code: nil, failure: .fileTooLarge)) }
        durable.script = .encoded("not base64!")
        do { _ = try await service.outputFile(file, for: dot); XCTFail("Not Base64") }
        catch { XCTAssertEqual(error as? DotsRemoteFileError, .init(stage: .contents, code: nil, failure: .invalidResponse)) }

        // The host's refusal at any step is a failed read at that step with its code, never a missing
        // file, and its words are not kept; an answer out of turn is not taken for the file.
        for (method, stage, code) in [("initialize", DotsRemoteFileError.Stage.initialize, Int64(-32600)),
                                      ("fs/getMetadata", .metadata, -32601), ("fs/readFile", .contents, -32000)] {
            durable.script = .refuse(method: method, code: code)
            do { _ = try await service.outputFile(file, for: dot); XCTFail(method) }
            catch {
                let failure = try XCTUnwrap(error as? DotsRemoteFileError, method)
                XCTAssertEqual(failure, .init(stage: stage, code: code, failure: .remoteFile))
                XCTAssertFalse(failure.description.contains("secret"))
            }
        }
        durable.script = .outOfTurn
        do { _ = try await service.outputFile(file, for: dot); XCTFail("Out of turn") }
        catch { XCTAssertEqual(error as? DotsRemoteFileError, .init(stage: .metadata, code: nil, failure: .invalidResponse)) }
        XCTAssertFalse(durable.sockets.last?.sent.contains { $0["method"]?.stringValue == "fs/readFile" } ?? true)
        durable.script = .directory
        do { _ = try await service.outputFile(file, for: dot); XCTFail("A directory") }
        catch { XCTAssertEqual(error as? DotsRemoteFileError, .init(stage: .metadata, code: nil, failure: .remoteFile)) }

        // Another computer than the one the file was found on, or one that cannot be told, opens nothing.
        let opened = durable.sockets.count
        for (thread, environment) in [("root", "elsewhere"), ("plain", nil)] {
            do {
                _ = try await service.outputFile(.init(path: "/mnt/data/report.pdf", threadID: thread, environmentID: environment), for: dot)
                XCTFail("\(thread)")
            } catch { XCTAssertEqual(error as? PersonalAgentFailure, .computerUnavailable, thread) }
        }
        do { _ = try await service.outputFile(.init(path: "/mnt/../etc/passwd", threadID: "root", environmentID: "env"), for: dot); XCTFail("Path") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .remoteFile) }
        do { _ = try await service.outputFile(.init(path: "/mnt/data/report.pdf", threadID: "stranger", environmentID: nil), for: dot); XCTFail("Scope") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .accessDenied) }
        XCTAssertEqual(durable.sockets.count, opened)
        await service.stop()
    }

    /// A page of items too large to carry, by the provider's own words or by its size, is asked for
    /// again from the same cursor with half as many items, down to one; past that the read fails as
    /// too large. No other refusal is asked again.
    func testATooLargeItemPageIsAskedForInHalvesAndNothingElseIsRetried() async throws {
        let fixture = DotsHTTPRecorder()
        let service = makeService(fixture, broker: DotsTestBroker())
        let dots = try await service.agents()
        let dot = try XCTUnwrap(dots.first)
        _ = try await service.activity(for: dot, cursor: nil)
        func limits(_ thread: String) -> [String] {
            fixture.requests.filter { $0.url?.path == "/v2/threads/\(thread)/items" }.map { request in
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(items.first { $0.name == "cursor" }?.value, "same", "Every attempt asks from the same cursor")
                return items.first { $0.name == "limit" }?.value ?? ""
            }
        }
        let big = try await service.activityItems("big", turnID: "t2", cursor: "same", for: dot)
        XCTAssertEqual(big.entries.map(\.item.id), ["i"])
        XCTAssertEqual(limits("big"), ["100", "50", "25"])
        _ = try await service.activityItems("bulky", turnID: "t2", cursor: "same", for: dot)
        XCTAssertEqual(limits("bulky"), ["100", "50"])
        do { _ = try await service.activityItems("huge", turnID: "t2", cursor: "same", for: dot); XCTFail("Too large at one item") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .tooLarge) }
        XCTAssertEqual(limits("huge"), ["100", "50", "25", "12", "6", "3", "1"])
        do { _ = try await service.activityItems("refused", turnID: "t2", cursor: "same", for: dot); XCTFail("Refused") }
        catch { XCTAssertEqual(error as? PersonalAgentFailure, .unavailable) }
        XCTAssertEqual(limits("refused"), ["100"])
        await service.stop()
    }

    private var agent: PersonalAgent {
        .init(id: .init(accountID: "account", userID: "person", agentID: "dot", roomID: "room"),
              name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
    }

    private func makeService(_ fixture: DotsHTTPRecorder, broker: DotsTestBroker, sockets: DotsSocketFactory? = nil,
                             timing: DotsLiveTiming = .init(), durable: DotsDurableSockets? = nil) -> DotsService {
        DotsHTTPProtocol.current = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DotsHTTPProtocol.self]
        var socket: (@Sendable (URL, URLSession) -> any DotsEventSocket)?
        if let sockets { socket = { _, _ in sockets.make() } }
        var durableSocket: (@Sendable (URLRequest, URLSession) -> any DotsEventSocket)?
        if let durable { durableSocket = { request, _ in durable.make(request) } }
        return DotsService(executable: URL(filePath: "/usr/bin/false"), environmentManager: nil, connection: nil,
                           transport: broker, configuration: configuration, liveTiming: timing, socket: socket,
                           durableSocket: durableSocket)
    }
}

private final class DotsHTTPRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var statuses: [Int]
    private let room: String
    /// Message pages by their `before` cursor, "" for the latest; none answers with the room.
    private let pages: [String: String]
    private let profile: String
    init(postStatuses: [Int] = [200], profile: String = #"{"id":"dot","active_root_thread_id":"root"}"#,
         room: String = #"{"id":"room","aeon_id":"dot","type":"DM","app_source":"chatgpt:messaging","members":[{"account_user_id":"person","role":"user"}]}"#,
         pages: [String: String] = [:]) {
        statuses = postStatuses
        self.profile = profile
        self.room = room
        self.pages = pages
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
                return (200, Data((["/avatar", "/sheet", "/photo"].contains(request.url?.path) ? "PNG" : "Preview text").utf8))
            }
            if request.url?.host == "cdn.openai.com" { return (200, Data("PNG".utf8)) }
            if request.url?.host == "codex-cloud-backend.chatgpt.com" {
                let bodies: [String: String] = [
                    "/v1/threads/root": #"{"thread":{"id":"root","environments":[{"environmentId":"env","cwd":"/workspace"}]}}"#,
                    "/v1/threads/bound": #"{"thread":{"id":"bound","environments":[{"environmentId":"managed"}],"connectedEnvironmentIds":["bound-env"]}}"#,
                    "/v1/threads/child": #"{"thread":{"id":"child","source":{"subAgent":{"thread_spawn":{"parent_thread_id":"bound"}}}}}"#,
                    "/v1/threads/stranger": #"{"thread":{"id":"stranger","parentThreadId":"root"}}"#,
                    "/v2/threads/child/items": #"{"data":[],"nextCursor":null,"backwardsCursor":null}"#,
                    "/v1/threads/task": #"{"thread":{"id":"task","threadSource":"aeon","turns":[{"id":"hidden"}]}}"#,
                    "/v1/threads/plain": #"{"thread":{"id":"plain"}}"#,
                    "/v1/threads/other-task": #"{"thread":{"id":"another"}}"#,
                    "/v2/threads/task/items": #"{"data":[{"turnId":"t2","item":{"id":"i","type":"agentMessage","text":"Done."}}],"nextCursor":null,"backwardsCursor":null}"#
                ]
                let path = request.url?.path ?? ""
                if path == "/v1/threads/gone" { return (404, Data("{}".utf8)) }
                let limit = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "limit" }?.value ?? "") ?? 0
                let tooLarge = Data(#"{"error":{"code":"internal","message":"decoded message length too large: 9000000"}}"#.utf8)
                let small = Data(#"{"data":[{"turnId":"t2","item":{"id":"i","type":"agentMessage","text":"Done."}}],"nextCursor":null,"backwardsCursor":null}"#.utf8)
                switch path {
                case "/v2/threads/big/items": return limit > 25 ? (400, tooLarge) : (200, small)
                case "/v2/threads/huge/items": return (400, tooLarge)
                case "/v2/threads/bulky/items": return limit == 100 ? (200, Data(repeating: 0x20, count: 8 * 1024 * 1024 + 1)) : (200, small)
                case "/v2/threads/refused/items": return (400, Data(#"{"error":{"code":"bad_request","message":"Bad request"}}"#.utf8))
                default: break
                }
                if path.hasSuffix("/turns") {
                    return (200, Data(#"{"data":[{"id":"t2","status":"completed"},{"id":"t1","status":"completed"}],"nextCursor":null,"backwardsCursor":null}"#.utf8))
                }
                return (200, Data((bodies[path] ?? "{}").utf8))
            }
            switch request.url?.path {
            case "/backend-api/tbo":
                return (200, Data(#"{"items":[{"id":"dot","aeon_kind":"orbit","messaging_room_id":"room","active_root_thread_id":"root"}]}"#.utf8))
            case "/backend-api/tbo/primary": return (200, Data(#"{"profile":{"id":"dot"}}"#.utf8))
            case "/backend-api/tbo/by-thread/root": return (200, Data(profile.utf8))
            case "/backend-api/tbo/dot/threads":
                return (200, Data((request.url?.query?.contains("cursor=next") == true
                    ? #"{"items":[{"thread_id":"plain"},{"thread_id":"bound"}],"cursor":null}"#
                    : #"{"items":[{"thread_id":"root"},{"thread_id":"bound"}],"cursor":"next"}"#).utf8))
            case "/backend-api/tbo/dot/activity":
                return (200, Data(#"{"data":[{"thread_id":"task"},{"thread_id":"root"},{"thread_id":"plain"},{"thread_id":"gone"},{"thread_id":"other-task"},{"thread_id":"big"},{"thread_id":"huge"},{"thread_id":"bulky"},{"thread_id":"refused"}],"next_cursor":null}"#.utf8))
            default: break
            }
            if request.url?.path == "/backend-api/pets" {
                return (200, Data((request.url?.query?.contains("cursor=next") == true
                    ? #"{"pets":[{"id":"pet","artwork_revision":"2","updated_at":"2026-10-29T06:00:00Z","spritesheet_url":"https://files.oaiusercontent.com/sheet"}]}"#
                    : #"{"pets":[{"id":"other","spritesheet_url":"https://files.oaiusercontent.com/other"}],"cursor":"next"}"#).utf8))
            }
            if request.url?.path == "/backend-api/celsius/ws/user" {
                return (200, Data(#"{"websocket_url":"wss://ws.chatgpt.com/ws/user"}"#.utf8))
            }
            if request.url?.path.hasSuffix("/files/photo") == true {
                return (200, Data(#"{"name":"photo.png","download_url":"https://files.oaiusercontent.com/photo"}"#.utf8))
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
            if request.httpMethod == "GET", request.url?.path.hasSuffix("/messages") == true, !pages.isEmpty {
                let before = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "before" }?.value ?? ""
                return (200, Data((pages[before] ?? #"{"items":[]}"#).utf8))
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
                                       headerFields: ["Content-Type": ["/avatar", "/sheet", "/photo"].contains(request.url?.path) || request.url?.host == "cdn.openai.com"
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

/// The execution host's socket as a test stands in for it: it answers each request Yardlet sends as
/// the script says, and records what was sent and whether it was closed.
private final class DotsDurableSockets: @unchecked Sendable {
    enum Script {
        case file(Data), encoded(String), attestation(early: Bool)
        /// The host answers `method` with an error of `code`.
        case refuse(method: String, code: Int64)
        /// After initializing, the host answers the read Yardlet has not asked for yet.
        case outOfTurn
        case directory
    }
    private let lock = NSLock()
    private var made: [DotsDurableSocket] = []
    private var madeRequests: [URLRequest] = []
    var script: Script = .file(Data())
    var sockets: [DotsDurableSocket] { lock.withLock { made } }
    var requests: [URLRequest] { lock.withLock { madeRequests } }
    func make(_ request: URLRequest) -> DotsDurableSocket {
        let socket = DotsDurableSocket(script: script)
        lock.withLock { made.append(socket); madeRequests.append(request) }
        return socket
    }
}

private final class DotsDurableSocket: DotsEventSocket, @unchecked Sendable {
    private let lock = NSLock()
    private let script: DotsDurableSockets.Script
    private var recorded: [JSONValue] = []
    private var incoming: [JSONValue] = []
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var isClosed = false
    init(script: DotsDurableSockets.Script) { self.script = script }
    var sent: [JSONValue] { lock.withLock { recorded } }
    var closed: Bool { lock.withLock { isClosed } }

    func resume() { }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case let .string(text) = message, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return }
        lock.withLock { recorded.append(value) }
        let id = value["id"] ?? .null
        let attestation: JSONValue = .object(["id": .string("server-1"), "method": .string("attestation/generate"), "params": .object([:])])
        if case let .refuse(method, code) = script, value["method"]?.stringValue == method {
            return push(.object(["id": id, "error": .object(["code": .integer(code), "message": .string("Refused at /secret/path")])]))
        }
        switch (value["method"]?.stringValue, script) {
        case ("initialize", .attestation(early: true)): push(attestation)
        case ("initialize", .outOfTurn):
            push(.object(["id": id, "result": .object([:])]))
            push(.object(["id": .string(DotsDurableFiles.readID), "result": .object(["dataBase64": .string("ZXhhbXBsZQ==")])]))
        case ("fs/getMetadata", .directory): push(.object(["id": id, "result": .object(["isFile": .bool(false), "isDirectory": .bool(true)])]))
        case ("initialize", _): push(.object(["id": id, "result": .object(["userAgent": .string("host")])]))
        case ("fs/getMetadata", .attestation(early: false)): push(attestation)
        case ("fs/getMetadata", _): push(.object(["id": id, "result": .object(["isFile": .bool(true), "isDirectory": .bool(false)])]))
        case let ("fs/readFile", .file(data)): push(.object(["id": id, "result": .object(["dataBase64": .string(data.base64EncodedString())])]))
        case let ("fs/readFile", .encoded(text)): push(.object(["id": id, "result": .object(["dataBase64": .string(text)])]))
        default: break
        }
    }

    private func push(_ value: JSONValue) {
        let text = String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
        lock.withLock {
            if let waiter { self.waiter = nil; waiter.resume(returning: .string(text)) } else { incoming.append(value) }
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if !incoming.isEmpty {
                    continuation.resume(returning: .string(String(decoding: try! JSONEncoder().encode(incoming.removeFirst()), as: UTF8.self)))
                } else if isClosed { continuation.resume(throwing: URLError(.networkConnectionLost)) }
                else { waiter = continuation }
            }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock {
            isClosed = true
            waiter?.resume(throwing: URLError(.networkConnectionLost))
            waiter = nil
        }
    }
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
