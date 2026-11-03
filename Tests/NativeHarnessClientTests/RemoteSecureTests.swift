import CryptoKit
import Foundation
import Network
import XCTest
@testable import YardletRemote

/// The protocol (docs/REMOTE_PROTOCOL.md §11–§17): the Noise IK vectors both the Mac and the phone app
/// check byte for byte, pairing by QR and then by the phone's key, link requests a paired phone approves,
/// encrypted pushes to phones that are away, and real socket round trips.
final class RemoteSecureTests: XCTestCase {
    // MARK: - Vectors (§17)

    func testTheCacophonyVectorPasses() throws {
        let vectors = try Self.vectors()
        let noise = try XCTUnwrap(vectors["noise"] as? [[String: Any]])
        XCTAssertFalse(noise.isEmpty)
        for vector in noise {
            func hex(_ key: String) throws -> Data { try XCTUnwrap(RemoteEncoding.data(hex: vector[key] as? String ?? "")) }
            var initiator = try RemoteNoiseHandshake(
                role: .initiator, localStatic: RemoteKeyPair(privateKey: hex("init_static")),
                remoteStatic: hex("init_remote_static"), prologue: hex("init_prologue"),
                ephemeral: RemoteKeyPair(privateKey: hex("init_ephemeral")))
            var responder = try RemoteNoiseHandshake(
                role: .responder, localStatic: RemoteKeyPair(privateKey: hex("resp_static")), prologue: hex("resp_prologue"),
                ephemeral: RemoteKeyPair(privateKey: hex("resp_ephemeral")))
            let messages = try XCTUnwrap(vector["messages"] as? [[String: String]])
            func bytes(_ index: Int, _ key: String) throws -> Data { try XCTUnwrap(RemoteEncoding.data(hex: messages[index][key] ?? "")) }

            XCTAssertEqual(try initiator.writeMessage1(payload: bytes(0, "payload")), try bytes(0, "ciphertext"))
            XCTAssertEqual(try responder.readMessage1(bytes(0, "ciphertext")), try bytes(0, "payload"))
            XCTAssertEqual(try responder.writeMessage2(payload: bytes(1, "payload")), try bytes(1, "ciphertext"))
            XCTAssertEqual(try initiator.readMessage2(bytes(1, "ciphertext")), try bytes(1, "payload"))
            XCTAssertEqual(initiator.handshakeHash, try hex("handshake_hash"))
            XCTAssertEqual(responder.handshakeHash, try hex("handshake_hash"))

            var (initiatorSend, initiatorReceive) = initiator.split()
            var (responderSend, responderReceive) = responder.split()
            for index in 2..<messages.count {
                let fromInitiator = index % 2 == 0
                let sealed = fromInitiator ? try initiatorSend.encrypt(bytes(index, "payload"))
                    : try responderSend.encrypt(bytes(index, "payload"))
                XCTAssertEqual(sealed, try bytes(index, "ciphertext"), "message \(index)")
                let opened = fromInitiator ? try responderReceive.decrypt(sealed) : try initiatorReceive.decrypt(sealed)
                XCTAssertEqual(opened, try bytes(index, "payload"))
            }
        }
    }

    /// The Yardlet vector: this protocol's prologue and payloads, chunking, the derived names and a
    /// sealed push. The phone app checks the same file. `YARDLET_WRITE_REMOTE_VECTORS=1` writes it.
    func testTheYardletVectorPasses() throws {
        let made = try Self.makeYardletVector()
        if ProcessInfo.processInfo.environment["YARDLET_WRITE_REMOTE_VECTORS"] == "1" {
            var vectors = try Self.vectors()
            vectors["yardlet"] = made
            let data = try JSONSerialization.data(withJSONObject: vectors, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: Self.vectorsURL)
        }
        let stored = try XCTUnwrap(try Self.vectors()["yardlet"] as? [String: Any], "Run once with YARDLET_WRITE_REMOTE_VECTORS=1")
        XCTAssertEqual(NSDictionary(dictionary: stored), NSDictionary(dictionary: made))
    }

    func testALargeMessageGoesInChunksAndComesBackWhole() throws {
        var (phone, mac) = try Self.handshakePair()
        let message = Data(String(repeating: "x", count: RemoteNoise.maxChunkLength * 2 + 10).utf8)
        let frames = try RemoteNoiseFraming.seal(message, with: &mac.send)
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0.count <= RemoteNoise.maxMessageLength })
        var joiner = RemoteNoiseFraming.Joiner(limit: RemoteProtocol.maxServerMessageBytes)
        XCTAssertNil(try joiner.add(frames[0], with: &phone.receive))
        XCTAssertNil(try joiner.add(frames[1], with: &phone.receive))
        XCTAssertEqual(try joiner.add(frames[2], with: &phone.receive), message)

        var small = RemoteNoiseFraming.Joiner(limit: 100)
        let tooBig = try RemoteNoiseFraming.seal(Data(repeating: 1, count: 200), with: &mac.send)
        XCTAssertThrowsError(try small.add(tooBig[0], with: &phone.receive))
        // A frame from someone else's key does not open.
        var stranger = try Self.handshakePair().mac
        let forged = try RemoteNoiseFraming.seal(Data("{}".utf8), with: &stranger.send)
        XCTAssertThrowsError(try joiner.add(forged[0], with: &phone.receive))
    }

    func testTheV2PairingURLReadsBack() throws {
        let identity = RemoteIdentity.generate()
        let pairing = RemoteSecurePairingURL(macKey: identity.noise.publicKey, secret: Data(repeating: 7, count: 32),
                                             name: "MacBook Pro", hosts: ["192.168.1.20:47616", "[fd7a:115c:a1e0::1]:47616"],
                                             relayURL: "wss://relay.example.test", room: identity.room)
        let url = try XCTUnwrap(pairing.url)
        XCTAssertTrue(url.absoluteString.hasPrefix("yardlet-remote://pair?v=2&k="))
        XCTAssertEqual(RemoteSecurePairingURL.parse(url), pairing)
        XCTAssertNil(RemoteSecurePairingURL.parse(try XCTUnwrap(URL(string: "yardlet-remote://pair?v=1&code=ABCDE-12345&port=1"))))
        XCTAssertEqual(identity.room.count, 32)
        XCTAssertTrue(identity.room.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) })

        // A crafted link: it takes 8 plain `host:port` addresses at most, a name cut to 64 characters, and no room that
        // is not one path segment.
        var crafted = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let junk = ["evil.example/x?y:80", "user@host:80", "host:0", "host:65536", "host", "[fd7a::1:80", " host:80", ":80"]
        let many = (1...20).map { "10.0.0.\($0):47616" }
        crafted.queryItems = (crafted.queryItems ?? []).filter { $0.name != "h" && $0.name != "n" }
            + (junk + many).map { URLQueryItem(name: "h", value: $0) } + [URLQueryItem(name: "n", value: String(repeating: "M", count: 500))]
        let read = try XCTUnwrap(RemoteSecurePairingURL.parse(try XCTUnwrap(crafted.url)))
        XCTAssertEqual(read.hosts, Array(many.prefix(RemoteSavedHost.maxDirectAddresses)))
        XCTAssertEqual(read.name.count, RemoteSecurePairingURL.maxNameLength)
        XCTAssertEqual(read.room, identity.room)
        for room in ["../../v1/auth", "room/connect", "", String(repeating: "a", count: 129), "방"] {
            crafted.queryItems = (crafted.queryItems ?? []).filter { $0.name != "i" } + [URLQueryItem(name: "i", value: room)]
            XCTAssertNil(RemoteSecurePairingURL.parse(try XCTUnwrap(crafted.url)), room)
        }
    }

    // MARK: - Pairing and devices (§12, §13.1)

    func testAPhonePairsByQRThenConnectsByItsKey() async throws {
        let harness = try await SecureHarness()
        let ticket = await harness.server.openPairing()
        let phoneKey = RemoteKeyPair.generate()
        let secret = RemoteEncoding.base64url(ticket.secret)

        let first = try await harness.phone(key: phoneKey, hello: RemoteHandshakeHello(name: "Pixel 9", platform: "android", pair: secret))
        XCTAssertEqual(first.reply.ok, true)
        XCTAssertEqual(first.reply.paired, true)
        XCTAssertEqual(first.reply.server?.protocolVersion, 2)
        XCTAssertEqual(first.reply.direct, ["192.168.1.20:47616"])
        let deviceID = try XCTUnwrap(first.reply.deviceId)
        let snapshot = try await first.request(#"{"id":"1","type":"snapshot"}"#)
        XCTAssertEqual(snapshot.tasks?.count, 2)
        XCTAssertNotNil(snapshot.newTask)
        let devices = await harness.devices.all()
        XCTAssertEqual(devices.map(\.name), ["Pixel 9"])
        XCTAssertEqual(devices.first?.publicKey, RemoteEncoding.base64url(phoneKey.publicKey))

        // The same phone again, without the secret: its key is enough.
        let again = try await harness.phone(key: phoneKey, hello: RemoteHandshakeHello(name: "Pixel 9"))
        XCTAssertEqual(again.reply.deviceId, deviceID)
        XCTAssertNil(again.reply.paired)
        // The same phone repeating the pairing (it lost the answer) is the same device.
        let repeated = try await harness.phone(key: phoneKey, hello: RemoteHandshakeHello(name: "Pixel 9", pair: secret))
        XCTAssertEqual(repeated.reply.deviceId, deviceID)
        // Another phone with the spent secret is refused.
        let other = try await harness.phone(key: .generate(), hello: RemoteHandshakeHello(name: "Other", pair: secret))
        XCTAssertEqual(other.reply.error?.code, .pairingUnavailable)
        try await other.waitUntilClosed(.unauthenticated)
        // A phone nobody paired.
        let stranger = try await harness.phone(key: .generate(), hello: RemoteHandshakeHello(name: "Stranger"))
        XCTAssertEqual(stranger.reply.error?.code, .unknownDevice)
        try await stranger.waitUntilClosed(.revoked)

        // Removing the device closes its connection and its key stops working.
        await harness.server.revoke(deviceID)
        try await first.waitUntilClosed(.revoked)
        let removed = try await harness.phone(key: phoneKey, hello: RemoteHandshakeHello(name: "Pixel 9"))
        XCTAssertEqual(removed.reply.error?.code, .unknownDevice)
    }

    func testAWrongSecretOrAnotherMacsKeyIsRefused() async throws {
        let harness = try await SecureHarness()
        _ = await harness.server.openPairing()
        let wrong = try await harness.phone(key: .generate(), hello: RemoteHandshakeHello(pair: RemoteEncoding.base64url(Data(count: 32))))
        XCTAssertEqual(wrong.reply.error?.code, .pairingInvalid)
        // Message 1 made for another Mac's key cannot be read: closed without an answer.
        let elsewhere = try await harness.phone(key: .generate(), hello: RemoteHandshakeHello(), macKey: RemoteKeyPair.generate().publicKey,
                                                expectsReply: false)
        try await elsewhere.waitUntilClosed(.unauthenticated)
    }

    func testALinkRequestWaitsForAPairedPhonesApproval() async throws {
        let harness = try await SecureHarness()
        let paired = try await harness.pairedPhone()
        _ = try await paired.request(#"{"id":"s","type":"snapshot"}"#)

        let refusedWhileSignedOut = try await harness.phone(key: .generate(), hello: RemoteHandshakeHello(name: "Tablet", link: true))
        XCTAssertEqual(refusedWhileSignedOut.reply.error?.code, .linkUnavailable)

        await harness.server.setAcceptsLinks(true)
        // A phone that commits to no nonce is told to update.
        let uncommitted = try await harness.phone(key: .generate(), hello: RemoteHandshakeHello(name: "Tablet", link: true))
        XCTAssertEqual(uncommitted.reply.error?.code, .unsupportedVersion)
        // Nothing is shown before the phone reveals its nonce, and a nonce other than the committed one ends it.
        let changed = try await PipePhone.link(server: harness.server, macStatic: harness.identity.noise, name: "Tablet",
                                               revealing: Data(RemoteRandom.bytes(32)))
        XCTAssertEqual(changed.reveal?.error?.code, .badRequest)
        try await changed.phone.waitUntilClosed(.unauthenticated)
        let shownEarly = await harness.server.status.linkRequest
        XCTAssertNil(shownEarly)

        let (newPhone, linkCode, reveal) = try await PipePhone.link(server: harness.server, macStatic: harness.identity.noise,
                                                                     name: "Pixel 10", platform: "android")
        XCTAssertEqual(reveal?.ok, true)
        let code = try XCTUnwrap(linkCode)
        XCTAssertEqual(code.count, 6)
        // Waiting: nothing but ping.
        let early = try await newPhone.request(#"{"id":"1","type":"snapshot"}"#)
        XCTAssertEqual(early.error?.code, .unauthenticated)

        let request = try await paired.event(.linkRequest)
        XCTAssertEqual(request.code, code)
        XCTAssertEqual(request.name, "Pixel 10")
        // A phone that connects while it waits is asked too.
        let late = try await harness.pairedPhone()
        let lateRequest = try await late.event(.linkRequest)
        XCTAssertEqual(lateRequest.requestId, request.requestId)
        let status = await harness.server.status
        XCTAssertEqual(status.linkRequest?.code, code)
        let approved = try await paired.request(#"{"id":"2","type":"answerLink","requestId":"\#(request.requestId ?? "")","approve":true}"#)
        XCTAssertTrue(approved.ok)
        let linked = try await newPhone.event(.linked)
        XCTAssertNotNil(linked.deviceId)
        let now = try await newPhone.request(#"{"id":"3","type":"snapshot"}"#)
        XCTAssertEqual(now.tasks?.count, 2)
        let resolved = try await paired.event(.linkResolved)
        XCTAssertEqual(resolved.approved, true)

        // Refused from the Mac's Settings.
        let declined = try await PipePhone.link(server: harness.server, macStatic: harness.identity.noise, name: "Unknown").phone
        let waiting = await harness.server.status.linkRequest
        await harness.server.answerLink(try XCTUnwrap(waiting?.id), approve: false)
        _ = try await declined.event(.linkRefused)
        try await declined.waitUntilClosed(.revoked)

        // A shown request outlives the time a connection has to authenticate.
        let patient = try await PipePhone.link(server: harness.server, macStatic: harness.identity.noise, name: "Patient").phone
        harness.clock.advance(by: 60)
        await harness.server.sweep()
        let stillWaiting = await harness.server.status.linkRequest
        XCTAssertEqual(stillWaiting?.name, "Patient")
        patient.disconnect()
        try await Self.waitUntilNoLinkRequest(harness.server)

        // Five requests in ten minutes; the next one waits.
        let fifth = try await PipePhone.link(server: harness.server, macStatic: harness.identity.noise, name: "Fifth").phone
        fifth.disconnect()
        try await Self.waitUntilNoLinkRequest(harness.server)
        let limited = try await PipePhone.link(server: harness.server, macStatic: harness.identity.noise, name: "Sixth")
        XCTAssertEqual(limited.phone.reply.error?.code, .rateLimited)
    }

    func testNewRequestsReachTheBridge() async throws {
        let harness = try await SecureHarness()
        let phone = try await harness.pairedPhone()
        let created = try await phone.request(#"{"id":"1","type":"createTask","projectId":"P","text":"  Add a dark mode toggle  "}"#)
        XCTAssertEqual(created.taskId, "NEW-1")
        let slash = try await phone.request(#"{"id":"2","type":"createTask","projectId":"P","text":"/clear"}"#)
        XCTAssertEqual(slash.error?.code, .unsupportedCommand)
        _ = try await phone.request(#"{"id":"3","type":"answerQuestion","taskId":"A","requestId":"q1","answers":[{"questionId":"q","options":["Juniper"]}]}"#)
        _ = try await phone.request(#"{"id":"4","type":"reviewPlan","taskId":"A","requestId":"p1","decision":"keepPlanning","reason":"Split it"}"#)
        _ = try await phone.request(#"{"id":"5","type":"setPinned","taskId":"A","pinned":true}"#)
        await harness.bridge.setDetail(RemoteItemDetail(output: "ok"), task: "A", item: "i:1")
        let detail = try await phone.request(#"{"id":"6","type":"itemDetail","taskId":"A","itemId":"i:1"}"#)
        XCTAssertEqual(detail.output, "ok")
        let commands = await harness.bridge.commands
        XCTAssertEqual(commands, [
            .answerQuestion(taskID: "A", requestID: "q1", answers: [RemoteQuestionAnswer(questionId: "q", options: ["Juniper"])]),
            .reviewPlan(taskID: "A", requestID: "p1", decision: .keepPlanning, reason: "Split it"),
            .setPinned(taskID: "A", pinned: true)
        ])
        let createdTasks = await harness.bridge.createdTasks
        XCTAssertEqual(createdTasks.map(\.text), ["Add a dark mode toggle"])

        // Since 2026-10-27 (§15.13–§15.15): a photo larger than v1's 64 KB frame comes through in chunks, a
        // file that is not one is refused, and a denial carries its note.
        let photo = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 7, count: 300_000)
        let sent = try await phone.request(#"{"id":"7","type":"sendMessage","taskId":"A","text":"","followUp":"queue","images":[{"type":"image/jpeg","data":"\#(photo.base64EncodedString())"}]}"#)
        XCTAssertTrue(sent.ok, "\(String(describing: sent.error))")
        let text = try await phone.request(#"{"id":"8","type":"sendMessage","taskId":"A","text":"Hi","images":[{"type":"image/png","data":"aGVsbG8="}]}"#)
        XCTAssertEqual(text.error?.code, .badRequest)
        _ = try await phone.request(#"{"id":"9","type":"answerApproval","taskId":"A","requestId":"r","answer":"deny","note":"Run only the unit tests"}"#)
        let later = await harness.bridge.commands.dropFirst(3)
        XCTAssertEqual(Array(later), [
            .sendMessage(taskID: "A", text: "", images: [RemoteImage(type: "image/jpeg", data: photo)], followUp: .queue),
            .answerApproval(taskID: "A", requestID: "r", answer: .deny, note: "Run only the unit tests")
        ])

        // A file goes up in parts (§15.20): a part sent again after a dropped connection adds nothing, and the
        // message takes the finished file from a folder of its own, readable by the person only.
        defer { try? FileManager.default.removeItem(at: harness.uploads) }
        harness.clock.advance(by: 60) // The commands above spent the burst (§7).
        let upload = UUID().uuidString
        let first = Data(repeating: 1, count: 3_000_000), second = Data(repeating: 2, count: 1_000)
        func part(_ id: String, offset: Int, _ data: Data, first: Bool = false) -> String {
            let head = first ? #","name":"../../notes/report.pdf","mediaType":"application/pdf","size":\#(3_001_000)"# : ""
            return #"{"id":"\#(id)","type":"uploadFile","uploadId":"\#(upload)","offset":\#(offset),"data":"\#(data.base64EncodedString())"\#(head)}"#
        }
        let one = try await phone.request(part("10", offset: 0, first, first: true))
        XCTAssertEqual(one.received, 3_000_000)
        let again = try await phone.request(part("11", offset: 0, first))
        XCTAssertEqual(again.received, 3_000_000, "The same part again adds nothing")
        let early = try await phone.request(#"{"id":"12","type":"sendMessage","taskId":"A","text":"Read this","files":["\#(upload)"]}"#)
        XCTAssertEqual(early.error?.code, .notFound, "An unfinished upload is not a file yet")
        let two = try await phone.request(part("13", offset: 3_000_000, second))
        XCTAssertEqual(two.received, 3_001_000)
        let sentFile = try await phone.request(#"{"id":"14","type":"sendMessage","taskId":"A","text":"Read this","files":["\#(upload)"]}"#)
        XCTAssertTrue(sentFile.ok, "\(String(describing: sentFile.error))")
        guard case let .sendMessage(_, _, _, _, files)? = await harness.bridge.commands.last else { return XCTFail("No message") }
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.name, "report.pdf")
        XCTAssertEqual(file.url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                       harness.uploads.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: file.url), first + second)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600, "Readable by the person, never executable")
        let reused = try await phone.request(#"{"id":"15","type":"sendMessage","taskId":"A","text":"Again","files":["\#(upload)"]}"#)
        XCTAssertEqual(reused.error?.code, .notFound, "A message took it")
        let huge = try await phone.request(#"{"id":"16","type":"uploadFile","uploadId":"\#(UUID().uuidString)","name":"big.bin","size":\#(RemoteProtocol.maxFileBytes + 1),"offset":0,"data":""}"#)
        XCTAssertEqual(huge.error?.code, .tooLarge)
    }

    // MARK: - Push (§16)

    func testAttentionIsPushedSealedToPhonesThatAreAway() async throws {
        let harness = try await SecureHarness()
        let sent = PushRecorder()
        await harness.server.setPushSender { await sent.record($0) }
        let phone = try await harness.pairedPhone()
        let registered = try await phone.request(#"{"id":"1","type":"registerPush","provider":"fcm","token":"fcm-token-1"}"#)
        let key = try XCTUnwrap(registered.pushKey.flatMap(RemoteEncoding.data(base64url:)))
        XCTAssertEqual(registered.pushKeyId, RemotePushSeal.keyID(key))

        // Connected: no push.
        try await harness.change(task: "A", to: .waiting, request: "r1")
        try await Task.sleep(for: .milliseconds(100))
        let whileConnected = await sent.requests
        XCTAssertTrue(whileConnected.isEmpty)

        phone.disconnect()
        try await waitUntil { await harness.server.status.connectedDeviceIDs.isEmpty }
        try await harness.change(task: "A", to: .waiting, request: "r2")
        let push = try await sent.first()
        XCTAssertEqual(push.token, "fcm-token-1")
        XCTAssertTrue(push.urgent)
        XCTAssertEqual(push.collapse, RemotePushSeal.collapseKey(taskID: "A"))
        let opened = try RemotePushSeal.open(push.sealed, key: key)
        let event = try JSONDecoder().decode(RemoteEvent.self, from: opened)
        XCTAssertEqual(event.state, .waiting)
        XCTAssertEqual(event.taskId, "A")
        XCTAssertEqual(event.macName, "Test Mac")

        // A token the push service forgot is dropped.
        await sent.answer(.unregistered)
        try await harness.change(task: "A", to: .unread, request: nil)
        _ = try await sent.count(2)
        try await waitUntil { await harness.devices.all().allSatisfy { $0.push == nil } }
        let pushes = await harness.devices.all().compactMap(\.push)
        XCTAssertTrue(pushes.isEmpty)
    }

    /// A desktop in use holds the phone's pushes; once it is not, each task's latest change goes (§18).
    func testPushesWaitWhileADesktopIsInUse() async throws {
        let harness = try await SecureHarness()
        let sent = PushRecorder()
        await harness.server.setPushSender { await sent.record($0) }
        let phone = try await harness.pairedPhone()
        _ = try await phone.request(#"{"id":"1","type":"registerPush","provider":"fcm","token":"fcm-token-1"}"#)
        phone.disconnect()
        let desktop = try await harness.pairedPhone()
        let snapshot = try await desktop.request(#"{"id":"1","type":"snapshot"}"#)
        XCTAssertEqual(snapshot.presence, true)
        let present = try await desktop.request(#"{"id":"2","type":"presence","active":true}"#)
        XCTAssertTrue(present.ok)

        // In use: a request that starts waiting, and then a newer one, wait with the desktop.
        try await harness.change(task: "A", to: .waiting, request: "r1")
        try await harness.change(task: "A", to: .waiting, request: "r2")
        try await Task.sleep(for: .milliseconds(150))
        let held = await sent.requests
        XCTAssertTrue(held.isEmpty)

        // No longer in use: the task's latest change goes, once.
        _ = try await desktop.request(#"{"id":"3","type":"presence","active":false}"#)
        let push = try await sent.first()
        XCTAssertTrue(push.urgent)
        let registrations = await harness.devices.all().compactMap(\.push)
        let registration = try XCTUnwrap(registrations.first)
        let key = try XCTUnwrap(RemoteEncoding.data(base64url: registration.key))
        let opened = try JSONDecoder().decode(RemoteEvent.self, from: RemotePushSeal.open(push.sealed, key: key))
        XCTAssertEqual(opened.requestId, "r2")
        try await Task.sleep(for: .milliseconds(150))
        let afterRelease = await sent.requests
        XCTAssertEqual(afterRelease.count, 1)

        // A desktop in use that drops its connection lets the held pushes go too.
        _ = try await desktop.request(#"{"id":"4","type":"presence","active":true}"#)
        try await harness.change(task: "A", to: .unread, request: nil)
        try await Task.sleep(for: .milliseconds(150))
        let whileInUse = await sent.requests
        XCTAssertEqual(whileInUse.count, 1)
        desktop.disconnect()
        _ = try await sent.count(2)
        let malformed = try await harness.pairedPhone().request(#"{"id":"5","type":"presence"}"#)
        XCTAssertEqual(malformed.error?.code, .badRequest)
    }

    func testOnlyWorthwhileChangesArePushed() {
        func event(_ from: RemoteAttention?, _ to: RemoteAttention) -> RemoteEvent {
            var event = RemoteEvent(.attention)
            event.previousState = from
            event.state = to
            return event
        }
        XCTAssertTrue(RemoteServer.pushes(event(.active, .waiting)) == (true, true))
        XCTAssertTrue(RemoteServer.pushes(event(.active, .unread)) == (true, true))
        XCTAssertTrue(RemoteServer.pushes(event(.waiting, .active)) == (true, false))
        XCTAssertTrue(RemoteServer.pushes(event(.idle, .active)) == (false, false))
        XCTAssertTrue(RemoteServer.pushes(event(.unread, .idle)) == (false, false))
        // A finish the Mac keeps quiet about rings nothing; one that ends a wait takes its notification back.
        var quiet = event(.active, .unread)
        quiet.announces = false
        XCTAssertTrue(RemoteServer.pushes(quiet) == (false, false))
        quiet.previousState = .waiting
        XCTAssertTrue(RemoteServer.pushes(quiet) == (true, false))
    }

    // MARK: - Sockets (§11.1)

    func testAPhoneConnectsOverTheSecureListener() async throws {
        let harness = try await SecureHarness()
        let ticket = await harness.server.openPairing()
        let listener = RemoteSecureListener(server: harness.server, staticKey: harness.identity.noise, port: 0,
                                            advertisement: nil, loopbackOnly: true)
        listener.start()
        defer { listener.stop() }
        let port = try await Self.waitForPort(listener)
        let started = ContinuousClock.now
        let socket = try await SocketPhone.connect(port: port, macKey: harness.identity.noise.publicKey,
                                                   hello: RemoteHandshakeHello(name: "Pixel 9", pair: RemoteEncoding.base64url(ticket.secret)))
        XCTAssertEqual(socket.reply.ok, true)
        let snapshot = try await socket.request(#"{"id":"1","type":"snapshot"}"#)
        let elapsed = ContinuousClock.now - started
        XCTAssertEqual(snapshot.tasks?.count, 2)
        // Loopback, a fresh handshake and the first list: the target over Wi-Fi is one second.
        XCTAssertLessThan(elapsed, .seconds(1), "handshake and snapshot took \(elapsed)")
        print("RemoteSecureTests: handshake and first snapshot over loopback in \(elapsed)")
        socket.close()
    }

    /// A phone that asks and never reads: once more than 32 MiB of its answers wait at the Mac, the Mac drops the
    /// connection rather than hold them (§7). File parts are the largest answers, and a device's budget lets 32 MiB of
    /// them through at once (§15.22); the file is sparse, so nothing fills the disk.
    func testAPhoneThatNeverReadsIsDroppedOverTheSecureListener() async throws {
        let files = try TaskFiles()
        defer { files.remove() }
        let large = files.folder + "/large.mov"
        XCTAssertTrue(FileManager.default.createFile(atPath: large, contents: nil))
        let handle = try FileHandle(forWritingTo: URL(filePath: large))
        try handle.truncate(atOffset: UInt64(RemoteProtocol.maxReadFileBytes))
        try handle.close()
        let harness = try await SecureHarness()
        await harness.bridge.setFiles(files.scope, outputs: [], for: "A")
        let connected = ConnectionCounts()
        await harness.server.setStatusHandler { connected.record($0.connectedDeviceIDs.count) }
        let ticket = await harness.server.openPairing()
        let listener = RemoteSecureListener(server: harness.server, staticKey: harness.identity.noise, port: 0,
                                            advertisement: nil, loopbackOnly: true)
        listener.start()
        defer { listener.stop() }
        let port = try await Self.waitForPort(listener)
        let socket = try await SocketPhone.connect(port: port, macKey: harness.identity.noise.publicKey,
                                                   hello: RemoteHandshakeHello(name: "Pixel 9", pair: RemoteEncoding.base64url(ticket.secret)))
        defer { socket.close() }
        let parts = RemoteProtocol.readFileBudgetBytes / RemoteProtocol.maxReadPartBytes
        for index in 0..<parts {
            try await socket.send(#"{"id":"\#(index)","type":"readFile","taskId":"A","path":"large.mov","offset":\#(index * RemoteProtocol.maxReadPartBytes)}"#)
        }
        try await waitUntil { connected.wasConnectedThenNot }
    }

    /// Through a relay running locally (`relay/`, `npx wrangler dev --local --port 8787`): the Mac opens
    /// its room with its signature, a phone comes in through the room and pairs, and reads the list. The Mac's
    /// way to the relay is then cut with a reset, as it sometimes is (§14.2): the phone is closed with 4404, the
    /// room opens again at once, and the phone comes back through it with its key. Last, it is told to close when
    /// the Mac removes it. Runs only with `YARDLET_REMOTE_RELAY_TEST=ws://127.0.0.1:8787`.
    func testAPhoneConnectsThroughALocalRelay() async throws {
        guard let relay = ProcessInfo.processInfo.environment["YARDLET_REMOTE_RELAY_TEST"].flatMap(URL.init(string:)),
              let relayPort = relay.port.flatMap({ NWEndpoint.Port(rawValue: UInt16($0)) }) else {
            throw XCTSkip("Set YARDLET_REMOTE_RELAY_TEST to a local relay")
        }
        let proxy = try CuttableProxy(to: relayPort)
        defer { proxy.stop() }
        try await waitUntil { proxy.port != nil }
        let harness = try await SecureHarness()
        let client = RemoteRelayClient(server: harness.server, identity: harness.identity,
                                       baseURL: try XCTUnwrap(URL(string: "ws://127.0.0.1:\(try XCTUnwrap(proxy.port))")))
        client.start()
        defer { client.stop() }
        try await waitUntil { client.currentState == .connected }
        XCTAssertEqual(client.currentState, .connected)

        let ticket = await harness.server.openPairing()
        let room = relay.appending(path: "v1/rooms/\(harness.identity.room)/connect")
        let phoneKey = RemoteKeyPair.generate()
        let started = ContinuousClock.now
        let phone = try await SocketPhone.connect(url: room, macKey: harness.identity.noise.publicKey, phoneKey: phoneKey,
                                                  hello: RemoteHandshakeHello(name: "Pixel 9", pair: RemoteEncoding.base64url(ticket.secret)))
        XCTAssertEqual(phone.reply.ok, true)
        let snapshot = try await phone.request(#"{"id":"1","type":"snapshot"}"#)
        let elapsed = ContinuousClock.now - started
        XCTAssertEqual(snapshot.tasks?.count, 2)
        print("RemoteSecureTests: through the local relay, handshake and first snapshot in \(elapsed)")
        let status = await harness.server.status
        XCTAssertEqual(status.connectedPaths.values.first, .relay)

        let cut = ContinuousClock.now
        proxy.cut()
        let dropped = try await phone.closeCode()
        XCTAssertEqual(dropped, Int(RemoteCloseCode.macOffline.rawValue))
        try await waitUntil { client.currentState == .connected }
        let reopened = ContinuousClock.now - cut
        let again = try await SocketPhone.connect(url: room, macKey: harness.identity.noise.publicKey, phoneKey: phoneKey,
                                                  hello: RemoteHandshakeHello(name: "Pixel 9"))
        XCTAssertEqual(again.reply.ok, true)
        let after = try await again.request(#"{"id":"2","type":"snapshot"}"#)
        XCTAssertEqual(after.tasks?.count, 2)
        print("RemoteSecureTests: the room opened again \(reopened) after the cut, the phone was back \(ContinuousClock.now - cut) after it")
        XCTAssertLessThan(reopened, .seconds(3))

        await harness.server.revoke(try XCTUnwrap(again.reply.deviceId))
        let closed = try await again.closeCode()
        XCTAssertEqual(closed, Int(RemoteCloseCode.revoked.rawValue))
    }

    // MARK: - Helpers

    static let vectorsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "Fixtures/RemoteNoiseVectors.json")

    static func vectors() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: vectorsURL)) as? [String: Any])
    }

    static func handshakePair() throws -> (phone: (send: RemoteNoiseCipher, receive: RemoteNoiseCipher),
                                           mac: (send: RemoteNoiseCipher, receive: RemoteNoiseCipher)) {
        let macKey = RemoteKeyPair.generate()
        var phone = try RemoteNoiseHandshake(role: .initiator, localStatic: .generate(), remoteStatic: macKey.publicKey)
        var mac = try RemoteNoiseHandshake(role: .responder, localStatic: macKey)
        _ = try mac.readMessage1(phone.writeMessage1(payload: Data()))
        _ = try phone.readMessage2(mac.writeMessage2(payload: Data()))
        let phoneCiphers = phone.split()
        let macCiphers = mac.split()
        return ((phoneCiphers.send, phoneCiphers.receive), (macCiphers.send, macCiphers.receive))
    }

    /// The Yardlet vector from fixed keys (§17).
    static func makeYardletVector() throws -> [String: Any] {
        func key(_ byte: UInt8) -> Data { Data((0..<32).map { UInt8(truncatingIfNeeded: Int(byte) &+ $0) }) }
        let mac = try RemoteKeyPair(privateKey: key(0x10))
        let phone = try RemoteKeyPair(privateKey: key(0x40))
        let phoneEphemeral = try RemoteKeyPair(privateKey: key(0x70))
        let macEphemeral = try RemoteKeyPair(privateKey: key(0xA0))
        let relayKey = key(0xD0)
        let linkMacNonce = key(0x60)
        let linkPhoneNonce = key(0x90)
        let identity = try RemoteIdentity(noisePrivateKey: mac.privateKey, relayPrivateKey: relayKey)
        let secret = key(0x33)

        let hello = #"{"appVersion":"0.2.0","name":"Pixel 9","pair":"\#(RemoteEncoding.base64url(secret))","platform":"android","v":2}"#
        let reply = #"{"deviceId":"B0D2","direct":["192.168.1.20:47616"],"ok":true,"paired":true,"server":{"app":"Yardlet","appVersion":"1.0","name":"MacBook Pro","protocolVersion":2},"serverTime":1792158000000}"#
        var initiator = try RemoteNoiseHandshake(role: .initiator, localStatic: phone, remoteStatic: mac.publicKey,
                                                 ephemeral: phoneEphemeral)
        var responder = try RemoteNoiseHandshake(role: .responder, localStatic: mac, ephemeral: macEphemeral)
        let message1 = try initiator.writeMessage1(payload: Data(hello.utf8))
        _ = try responder.readMessage1(message1)
        let message2 = try responder.writeMessage2(payload: Data(reply.utf8))
        _ = try initiator.readMessage2(message2)
        var phoneSend = initiator.split().send
        var macSend = responder.split().send
        let request = #"{"id":"1","type":"snapshot"}"#
        let requestFrames = try RemoteNoiseFraming.seal(Data(request.utf8), with: &phoneSend)
        // A message longer than one chunk: 70,000 bytes of JSON.
        let large = #"{"re":"1","ok":true,"pad":""# + String(repeating: "y", count: 70_000 - 30) + #""}"#
        let largeFrames = try RemoteNoiseFraming.seal(Data(large.utf8), with: &macSend)
        func digest(_ data: Data) -> String { RemoteEncoding.hex(Data(SHA256.hash(data: data))) }

        let pushKey = key(0x55)
        let pushPlaintext = #"{"event":"attention","state":"waiting","taskId":"4C1F","title":"Approve the index migration"}"#
        let pushNonce = Data((0..<12).map { UInt8($0) })
        return [
            "prologue": RemoteEncoding.hex(RemoteNoise.prologue),
            "macStaticPrivate": RemoteEncoding.hex(mac.privateKey),
            "macStaticPublic": RemoteEncoding.hex(mac.publicKey),
            "phoneStaticPrivate": RemoteEncoding.hex(phone.privateKey),
            "phoneStaticPublic": RemoteEncoding.hex(phone.publicKey),
            "phoneEphemeralPrivate": RemoteEncoding.hex(phoneEphemeral.privateKey),
            "macEphemeralPrivate": RemoteEncoding.hex(macEphemeral.privateKey),
            "message1Payload": hello,
            "message1": RemoteEncoding.hex(message1),
            "message2Payload": reply,
            "message2": RemoteEncoding.hex(message2),
            "handshakeHash": RemoteEncoding.hex(initiator.handshakeHash),
            "request": request,
            "requestFrames": requestFrames.map(RemoteEncoding.hex),
            "largeMessageLength": large.utf8.count,
            "largeMessageSHA256": digest(Data(large.utf8)),
            "largeFrames": largeFrames.map { ["length": $0.count, "sha256": digest($0)] as [String: Any] },
            "relayPrivateKey": RemoteEncoding.hex(relayKey),
            "relayPublicKey": RemoteEncoding.hex(identity.relayPublicKey),
            "room": identity.room,
            "discoveryId": identity.discoveryID,
            "linkMacNonce": RemoteEncoding.hex(linkMacNonce),
            "linkPhoneNonce": RemoteEncoding.hex(linkPhoneNonce),
            "linkCommit": RemoteEncoding.base64url(RemoteLinkCode.commitment(phoneKey: phone.publicKey, nonce: linkPhoneNonce)),
            "linkCode": RemoteLinkCode.code(macKey: mac.publicKey, phoneKey: phone.publicKey, macNonce: linkMacNonce,
                                            phoneNonce: linkPhoneNonce),
            "pushKey": RemoteEncoding.hex(pushKey),
            "pushKeyId": RemotePushSeal.keyID(pushKey),
            "pushNonce": RemoteEncoding.hex(pushNonce),
            "pushPlaintext": pushPlaintext,
            "pushSealed": try RemotePushSeal.seal(Data(pushPlaintext.utf8), key: pushKey, nonce: pushNonce),
            "collapseTaskId": "4C1F",
            "collapseKey": RemotePushSeal.collapseKey(taskID: "4C1F"),
            "pairingURL": RemoteSecurePairingURL(macKey: mac.publicKey, secret: secret, name: "MacBook Pro",
                                                 hosts: ["192.168.1.20:47616", "100.64.12.34:47616"],
                                                 relayURL: "wss://relay.example.test", room: identity.room).url?.absoluteString ?? ""
        ]
    }

    static func waitUntilNoLinkRequest(_ server: RemoteServer) async throws {
        for _ in 0..<200 {
            if await server.status.linkRequest == nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestChannel.TimedOut(description: "The link request stayed")
    }

    static func waitForPort(_ listener: RemoteSecureListener) async throws -> UInt16 {
        let deadline = ContinuousClock.now + testWaitLimit
        while ContinuousClock.now < deadline {
            if case let .ready(port) = listener.currentState { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestChannel.TimedOut(description: "The secure listener never became ready: \(listener.currentState)")
    }
}

// MARK: - Harness

/// A server with a fixed Mac identity, and phones that speak Noise to it through a frame pipe.
struct SecureHarness {
    let server: RemoteServer
    let bridge = FakeBridge()
    let devices = RemoteDeviceStore(fileURL: nil)
    let identity = RemoteIdentity.generate()
    let clock = RemoteTestClock()
    let uploads = FileManager.default.temporaryDirectory.appending(path: "remote-uploads-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() async throws {
        var configuration = RemoteServer.Configuration(server: RemoteServerInfo(name: "Test Mac", appVersion: "test"),
                                                       macKey: identity.noise.publicKey)
        configuration.uploadDirectory = uploads
        configuration.tasksInterval = .milliseconds(10)
        configuration.conversationInterval = .milliseconds(10)
        configuration.sweepInterval = .seconds(3600)
        configuration.windowLimits = .init(maxTurns: 10)
        let clock = self.clock
        server = RemoteServer(configuration: configuration, bridge: bridge, devices: devices, now: { clock.now })
        await server.start()
        await server.setDirectory(direct: ["192.168.1.20:47616"], relay: nil)
    }

    func phone(key: RemoteKeyPair, hello: RemoteHandshakeHello, macKey: Data? = nil, expectsReply: Bool = true) async throws -> PipePhone {
        try await PipePhone.connect(server: server, macStatic: identity.noise, phoneKey: key, hello: hello,
                                    targetKey: macKey ?? identity.noise.publicKey, expectsReply: expectsReply)
    }

    func pairedPhone() async throws -> PipePhone {
        let ticket = await server.openPairing()
        return try await phone(key: .generate(), hello: RemoteHandshakeHello(name: "Phone", pair: RemoteEncoding.base64url(ticket.secret)))
    }

    /// Moves one task's attention, as the app's model would.
    func change(task: String, to attention: RemoteAttention, request: String?) async throws {
        var snapshot = FakeBridge.snapshot
        let index = try XCTUnwrap(snapshot.tasks.firstIndex { $0.id == task })
        snapshot.tasks[index].attention = attention
        snapshot.tasks[index].lastActivityAt += 1
        if let request {
            snapshot.newestRequestIDs[task] = request
            snapshot.tasks[index].pendingRequest = .approval
        }
        await bridge.setSnapshot(snapshot)
        await bridge.signal(.tasks)
    }
}

/// A frame transport the test holds: what the Mac sends lands here, what the phone sends goes to the Mac.
final class FramePipe: RemoteFrameChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    private(set) var closeCode: RemoteCloseCode?

    func sendFrame(_ frame: Data) { lock.withLock { frames.append(frame) } }
    func close(_ code: RemoteCloseCode) { lock.withLock { if closeCode == nil { closeCode = code } } }

    func take() -> [Data] {
        lock.withLock {
            defer { frames = [] }
            return frames
        }
    }

    var closed: RemoteCloseCode? { lock.withLock { closeCode } }
}

/// A phone over a `FramePipe`: the initiator's handshake, then encrypted JSON both ways.
final class PipePhone: @unchecked Sendable {
    let pipe: FramePipe
    let connection: RemoteSecureConnection
    private(set) var reply = RemoteHandshakeReply(ok: false)
    private var send: RemoteNoiseCipher?
    private var receive: RemoteNoiseCipher?
    private var joiner = RemoteNoiseFraming.Joiner(limit: RemoteProtocol.maxServerMessageBytes)
    private var received: [String] = []

    private init(connection: RemoteSecureConnection, pipe: FramePipe) {
        self.connection = connection
        self.pipe = pipe
    }

    static func connect(server: RemoteServer, macStatic: RemoteKeyPair, phoneKey: RemoteKeyPair, hello: RemoteHandshakeHello,
                        targetKey: Data, expectsReply: Bool) async throws -> PipePhone {
        let pipe = FramePipe()
        let connection = RemoteSecureConnection(transport: pipe, server: server, staticKey: macStatic, path: .local)
        let phone = PipePhone(connection: connection, pipe: pipe)
        var noise = try RemoteNoiseHandshake(role: .initiator, localStatic: phoneKey, remoteStatic: targetKey)
        connection.receive(try noise.writeMessage1(payload: Data(RemoteJSON.string(hello).utf8)))
        guard expectsReply else { return phone }
        let message2 = try await phone.nextFrame()
        phone.reply = try JSONDecoder().decode(RemoteHandshakeReply.self, from: noise.readMessage2(message2))
        let (send, receive) = noise.split()
        phone.send = send
        phone.receive = receive
        return phone
    }

    /// Asks to link (§12.1): commits to a nonce in message 1 and reveals it once message 2 is in. The code is
    /// the one the phone shows; nil when the Mac refused in message 2.
    static func link(server: RemoteServer, macStatic: RemoteKeyPair, phoneKey: RemoteKeyPair = .generate(), name: String,
                     platform: String? = nil, nonce: Data = Data(RemoteRandom.bytes(32)),
                     revealing revealed: Data? = nil) async throws -> (phone: PipePhone, code: String?, reveal: RemoteResponse?) {
        let commitment = RemoteLinkCode.commitment(phoneKey: phoneKey.publicKey, nonce: nonce)
        let hello = RemoteHandshakeHello(name: name, platform: platform, link: true, linkCommit: RemoteEncoding.base64url(commitment))
        let phone = try await connect(server: server, macStatic: macStatic, phoneKey: phoneKey, hello: hello,
                                      targetKey: macStatic.publicKey, expectsReply: true)
        guard phone.reply.pending == true, let macNonce = phone.reply.linkNonce.flatMap(RemoteEncoding.data(base64url:)) else {
            return (phone, nil, nil)
        }
        let response = try await phone.request(#"{"id":"reveal","type":"revealLink","nonce":"\#(RemoteEncoding.base64url(revealed ?? nonce))"}"#)
        let code = RemoteLinkCode.code(macKey: macStatic.publicKey, phoneKey: phoneKey.publicKey, macNonce: macNonce, phoneNonce: nonce)
        return (phone, code, response)
    }

    private var transport: FramePipe { pipe }

    private var pending: [Data] = []

    private func nextFrame(timeout: TimeInterval = testWaitLimitSeconds) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            pending += transport.take()
            if !pending.isEmpty { return pending.removeFirst() }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestChannel.TimedOut(description: "No frame from the Mac")
    }

    /// Decrypts what has arrived.
    private func pump() throws {
        pending += transport.take()
        while !pending.isEmpty, var receive {
            let frame = pending.removeFirst()
            if let message = try joiner.add(frame, with: &receive) {
                received.append(String(decoding: message, as: UTF8.self))
            }
            self.receive = receive
        }
    }

    func request(_ json: String) async throws -> RemoteResponse {
        guard var send else { throw TestChannel.TimedOut(description: "Not connected") }
        for frame in try RemoteNoiseFraming.seal(Data(json.utf8), with: &send) { connection.receive(frame) }
        self.send = send
        let id = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])["id"] as? String
        return try await wait("response \(id ?? "")") {
            self.received.compactMap { try? JSONDecoder().decode(RemoteResponse.self, from: Data($0.utf8)) }.first { $0.re == id }
        }
    }

    func event(_ name: RemoteEvent.Name) async throws -> RemoteEvent {
        try await wait("event \(name)") {
            self.received.compactMap { try? JSONDecoder().decode(RemoteEvent.self, from: Data($0.utf8)) }.first { $0.event == name }
        }
    }

    func waitUntilClosed(_ code: RemoteCloseCode) async throws {
        let closed = try await wait("close") { self.transport.closed }
        XCTAssertEqual(closed, code)
    }

    func disconnect() {
        connection.transportClosed()
    }

    private func wait<Value>(_ what: String, timeout: TimeInterval = testWaitLimitSeconds,
                             _ read: () -> Value?) async throws -> Value {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try pump()
            if let value = read() { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestChannel.TimedOut(description: "Timed out waiting for \(what): \(received)")
    }
}

actor PushRecorder {
    private(set) var requests: [RemotePushRequest] = []
    private var result = RemotePushResult.sent

    func record(_ request: RemotePushRequest) -> RemotePushResult {
        requests.append(request)
        return result
    }

    func answer(_ result: RemotePushResult) { self.result = result }

    func first() async throws -> RemotePushRequest {
        try await count(1)[0]
    }

    func count(_ count: Int) async throws -> [RemotePushRequest] {
        let deadline = ContinuousClock.now + testWaitLimit
        while ContinuousClock.now < deadline {
            if requests.count >= count { return requests }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestChannel.TimedOut(description: "Only \(requests.count) pushes")
    }
}

/// How many devices the server said were connected, in order.
final class ConnectionCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []

    func record(_ count: Int) { lock.withLock { counts.append(count) } }

    /// A device connected, and later none was.
    var wasConnectedThenNot: Bool {
        lock.withLock {
            guard let first = counts.firstIndex(where: { $0 > 0 }) else { return false }
            return counts[first...].contains(0)
        }
    }
}

/// A phone over a real WebSocket to the secure listener.
final class SocketPhone: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    let reply: RemoteHandshakeReply
    private var send: RemoteNoiseCipher
    private var receive: RemoteNoiseCipher

    private init(task: URLSessionWebSocketTask, reply: RemoteHandshakeReply, send: RemoteNoiseCipher, receive: RemoteNoiseCipher) {
        self.task = task
        self.reply = reply
        self.send = send
        self.receive = receive
    }

    static func connect(port: UInt16, macKey: Data, hello: RemoteHandshakeHello) async throws -> SocketPhone {
        try await connect(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/")), macKey: macKey, hello: hello)
    }

    static func connect(url: URL, macKey: Data, phoneKey: RemoteKeyPair = .generate(),
                        hello: RemoteHandshakeHello) async throws -> SocketPhone {
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        var noise = try RemoteNoiseHandshake(role: .initiator, localStatic: phoneKey, remoteStatic: macKey)
        try await task.send(.data(noise.writeMessage1(payload: Data(RemoteJSON.string(hello).utf8))))
        guard case let .data(message2) = try await task.receive() else { throw RemoteNoise.Failure("Expected binary") }
        let reply = try JSONDecoder().decode(RemoteHandshakeReply.self, from: noise.readMessage2(message2))
        let (send, receive) = noise.split()
        return SocketPhone(task: task, reply: reply, send: send, receive: receive)
    }

    /// Sends a request and reads nothing.
    func send(_ json: String) async throws {
        for frame in try RemoteNoiseFraming.seal(Data(json.utf8), with: &send) { try await task.send(.data(frame)) }
    }

    func request(_ json: String) async throws -> RemoteResponse {
        try await send(json)
        var joiner = RemoteNoiseFraming.Joiner(limit: RemoteProtocol.maxServerMessageBytes)
        while true {
            guard case let .data(frame) = try await task.receive() else { continue }
            if let message = try joiner.add(frame, with: &receive),
               let response = try? JSONDecoder().decode(RemoteResponse.self, from: message) {
                return response
            }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// Reads until the socket closes, and its close code.
    func closeCode(timeout: TimeInterval = testWaitLimitSeconds) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                _ = try await task.receive()
            } catch {
                return task.closeCode.rawValue
            }
        }
        throw TestChannel.TimedOut(description: "The socket stayed open")
    }
}

/// A loopback TCP proxy in front of a local relay that can cut every connection through it at once, as the way to
/// the relay is sometimes cut (§14.2).
final class CuttableProxy: @unchecked Sendable {
    private let listener: NWListener
    private let target: NWEndpoint
    private let queue = DispatchQueue(label: "yardlet.test.proxy")
    private var connections: [NWConnection] = []

    init(to port: NWEndpoint.Port) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        target = .hostPort(host: "127.0.0.1", port: port)
        listener.newConnectionHandler = { [weak self] inbound in self?.accept(inbound) }
        listener.start(queue: queue)
    }

    var port: UInt16? { listener.port?.rawValue }

    /// Ends every connection through the proxy without a word to either side.
    func cut() {
        queue.sync {
            for connection in connections { connection.forceCancel() }
            connections = []
        }
    }

    func stop() {
        listener.cancel()
        cut()
    }

    private func accept(_ inbound: NWConnection) {
        let outbound = NWConnection(to: target, using: .tcp)
        connections += [inbound, outbound]
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pipe(from: inbound, to: outbound)
        pipe(from: outbound, to: inbound)
    }

    private func pipe(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty { destination.send(content: data, completion: .idempotent) }
            if isComplete || error != nil {
                destination.cancel()
                return
            }
            self?.pipe(from: source, to: destination)
        }
    }
}
