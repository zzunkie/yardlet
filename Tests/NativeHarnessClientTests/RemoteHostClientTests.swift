import Foundation
import Network
import XCTest
@testable import YardletRemote
@testable import YardletRemoteFixtureSupport

/// Yardlet as a client of another Mac's Yardlet (`RemoteHostConnection`), against the fixture host on
/// loopback (`LoopbackStack`): pairing by link, the request and event stream in order, a removed device
/// that stops trying, and an address found on the network tried at once.
final class RemoteHostClientTests: XCTestCase {
    func testAClientPairsByLinkFollowsTasksAndStopsWhenRemoved() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret, name: "Loopback",
                                          hosts: ["127.0.0.1:\(stack.port)"])
        let parsed = try XCTUnwrap(link.url.flatMap(RemoteSecurePairingURL.parse))
        let key = RemoteKeyPair.generate()
        let hello = RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test")
        let reply = try await RemoteHostConnection.pair(parsed, clientKey: key, hello: hello)
        XCTAssertEqual(reply.paired, true)
        let deviceID = try XCTUnwrap(reply.deviceId)
        let device = await stack.devices.device(deviceID)
        XCTAssertEqual(device?.platform, "macos")
        XCTAssertEqual(device?.name, "MacBook Air")

        // The link was spent: another key cannot use it.
        do {
            _ = try await RemoteHostConnection.pair(parsed, clientKey: .generate(), hello: hello)
            XCTFail("A spent link paired a second key")
        } catch let failure as RemoteClientSocket.Failure {
            XCTAssertEqual(failure.error?.code, .pairingUnavailable, "\(failure)")
        }

        var saved = RemoteSavedHost(name: link.name, hostKey: link.macKey, direct: link.hosts)
        saved.update(from: reply)
        let connection = RemoteHostConnection(target: try XCTUnwrap(saved.target), clientKey: key, hello: hello)
        let inbox = Inbox(connection.inbound)
        await connection.start()
        let (path, connected) = try await inbox.waitFor("connected") { inbox -> (RemoteClientPath, RemoteHandshakeReply)? in
            if case let .connected(path, reply)? = inbox.lastState { return (path, reply) }
            return nil
        }
        XCTAssertEqual(path, .direct("127.0.0.1:\(stack.port)"))
        XCTAssertEqual(connected.deviceId, deviceID)
        XCTAssertNil(connected.paired)

        let sent = await connection.send(id: "1", .snapshot)
        XCTAssertTrue(sent)
        let snapshot = try await inbox.response("1")
        XCTAssertTrue(snapshot.tasks?.contains { $0.id == RemoteFixtureBridge.ID.approval } == true)

        // A subscription's page comes before the events that change it, in one stream.
        _ = await connection.send(id: "2", .subscribeTask(taskID: RemoteFixtureBridge.ID.streaming))
        let page = try await inbox.response("2")
        var items = try XCTUnwrap(page.items)
        let streamed = try await inbox.waitFor("a change to the page") { inbox -> [RemoteItem]? in
            let pageIndex = inbox.messages.firstIndex { if case let .response(r) = $0 { r.re == "2" } else { false } }
            let changes = inbox.messages.enumerated().compactMap { index, message -> RemoteEvent? in
                guard case let .event(event) = message, event.event == .conversation,
                      event.taskId == RemoteFixtureBridge.ID.streaming else { return nil }
                XCTAssertGreaterThan(index, pageIndex ?? .max)
                return event
            }
            guard !changes.isEmpty else { return nil }
            for event in changes { items = items.applying(event.changes ?? []) }
            return items
        }
        XCTAssertFalse(streamed.isEmpty)

        // Removed on the host: the connection is told so and stops.
        try await stack.server.revoke(deviceID)
        _ = try await inbox.waitFor("revoked") { $0.lastState == .revoked ? true : nil }
        let again = await connection.send(id: "3", .ping)
        XCTAssertFalse(again)
        await connection.stop()
    }

    func testAccountEnrollmentChecksTheHandshakeKeyAndKeepsDevicePermissions() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let target = RemoteHostTarget(hostKey: stack.identity.noise.publicKey, direct: ["127.0.0.1:\(stack.port)"])
        let key = RemoteKeyPair.generate()
        let grant = RemoteEncoding.base64url(Data(RemoteRandom.bytes(32)))
        var hello = RemoteHandshakeHello(name: "MacBook", platform: "macos")
        hello.accountGrant = grant
        await stack.server.setAcceptsLinks(true) { supplied, peer in supplied == grant && peer == key.publicKey }
        do {
            _ = try await RemoteHostConnection.link(target, clientKey: .generate(), hello: hello) { _ in XCTFail("Unexpected approval") }
            XCTFail("Wrong client key enrolled")
        } catch let failure as RemoteHostConnection.LinkFailure {
            guard case let .declined(error) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(error.code, .notAllowed)
        }
        let reply = try await RemoteHostConnection.link(target, clientKey: key, hello: hello) { _ in XCTFail("Unexpected approval") }
        let id = try XCTUnwrap(reply.deviceId)
        let device = await stack.devices.device(id)
        XCTAssertEqual(device?.permissions, RemoteDevicePermissions())
        let reconnect = try await stack.phone(key: key, hello: .init(name: "MacBook"))
        XCTAssertEqual(reconnect.reply.deviceId, id)
    }

    func testAnUnknownKeyIsTakenForRemoved() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let target = RemoteHostTarget(hostKey: stack.identity.noise.publicKey, direct: ["127.0.0.1:\(stack.port)"])
        let connection = RemoteHostConnection(target: target, clientKey: .generate(), hello: RemoteHandshakeHello(name: "Stranger"))
        let inbox = Inbox(connection.inbound)
        await connection.start()
        _ = try await inbox.waitFor("revoked") { $0.lastState == .revoked ? true : nil }
        await connection.stop()
    }

    /// A client the account led to a host links without a pairing link (§12.1): it shows the code the host shows,
    /// becomes a device once the host allows it, and hears a refusal or a signed-out host for what it is.
    func testAClientLinksThroughTheAccountShowingTheHostsCode() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let target = RemoteHostTarget(hostKey: stack.identity.noise.publicKey, direct: ["127.0.0.1:\(stack.port)"])
        let hello = RemoteHandshakeHello(name: "iPhone", platform: "ios", appVersion: "test")
        do {
            _ = try await RemoteHostConnection.link(target, clientKey: .generate(), hello: hello) { _ in }
            XCTFail("A host signed out of the account took a link request")
        } catch let failure as RemoteHostConnection.LinkFailure {
            guard case let .declined(error) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(error.code, .linkUnavailable)
        }

        await stack.server.setAcceptsLinks(true)
        let key = RemoteKeyPair.generate()
        let server = stack.server
        let shown = Box<String?>(nil)
        let reply = try await RemoteHostConnection.link(target, clientKey: key, hello: hello) { code in
            shown.value = code
            Task {
                let request = await server.status.linkRequest
                XCTAssertEqual(request?.code, code)
                await server.answerLink(request?.id ?? "", approve: true)
            }
        }
        XCTAssertEqual(shown.value?.count, 6)
        let deviceID = try XCTUnwrap(reply.deviceId)
        let device = await stack.devices.device(publicKey: key.publicKey)
        XCTAssertEqual(device?.id, deviceID)
        XCTAssertEqual(device?.platform, "ios")
        XCTAssertEqual(reply.server?.name, "Loopback")

        do {
            _ = try await RemoteHostConnection.link(target, clientKey: .generate(), hello: hello) { _ in
                Task {
                    let request = await server.status.linkRequest
                    await server.answerLink(request?.id ?? "", approve: false)
                }
            }
            XCTFail("A refused link request made a device")
        } catch let failure as RemoteHostConnection.LinkFailure {
            XCTAssertEqual(failure, .refused)
        }
    }

    func testRelayAddressesAndCandidates() {
        XCTAssertEqual(RemoteHostTarget.relayURL(base: "https://relay.example.test", room: "abc")?.absoluteString,
                       "wss://relay.example.test/v1/rooms/abc/connect")
        XCTAssertEqual(RemoteHostTarget.relayURL(base: "ws://127.0.0.1:8787/", room: "abc")?.absoluteString,
                       "ws://127.0.0.1:8787/v1/rooms/abc/connect")
        XCTAssertNil(RemoteHostTarget.relayURL(base: "ftp://relay.example.test", room: "abc"))
        let target = RemoteHostTarget(hostKey: Data(count: 32), direct: ["192.168.0.2:47616", "[fd7a::1]:47616", "192.168.0.2:47616"],
                                      relayURL: "https://relay.example.test", room: "abc")
        let candidates = RemoteHostConnection.candidates(target, includeRelay: true, timing: .init())
        XCTAssertEqual(candidates.map(\.url.absoluteString),
                       ["ws://192.168.0.2:47616/", "ws://[fd7a::1]:47616/", "wss://relay.example.test/v1/rooms/abc/connect"])
        XCTAssertEqual(candidates.map(\.delay), [0, 0, 0.7])
        XCTAssertEqual(RemoteHostConnection.candidates(RemoteHostTarget(hostKey: Data(count: 32), direct: [],
                                                                        relayURL: "https://relay.example.test", room: "abc"),
                                                       includeRelay: true, timing: .init()).map(\.delay), [0])
        // What Bonjour found goes first, each address once (§11.4).
        let found = RemoteHostConnection.candidates(target, discovered: ["Mac-Studio.local:47616", "192.168.0.2:47616"],
                                                    includeRelay: true, timing: .init())
        XCTAssertEqual(found.map(\.path), [.direct("Mac-Studio.local:47616"), .direct("192.168.0.2:47616"),
                                           .direct("[fd7a::1]:47616"), .relay])
        XCTAssertEqual(found.map(\.delay), [0, 0, 0, 0.7])
        var second = target
        second.alternateRelayURL = "https://alternate.relay.example.test"
        let both = RemoteHostConnection.candidates(second, includeRelay: true, timing: .init()).suffix(2)
        XCTAssertEqual(both.map(\.url.absoluteString), ["wss://relay.example.test/v1/rooms/abc/connect",
                                                        "wss://alternate.relay.example.test/v1/rooms/abc/connect"])
        XCTAssertEqual(both.map(\.delay), [0.7, 0.7])
    }

    /// Bonjour finding the host (§11.4): an address found while waiting out a backoff is tried now, and one
    /// found while on the relay moves the connection to it.
    func testAnAddressFoundOnTheNetworkIsTriedAtOnce() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret, name: "Loopback",
                                          hosts: ["127.0.0.1:\(stack.port)"])
        let key = RemoteKeyPair.generate()
        let hello = RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test")
        _ = try await RemoteHostConnection.pair(try XCTUnwrap(link.url.flatMap(RemoteSecurePairingURL.parse)), clientKey: key,
                                                hello: hello)
        let found = "127.0.0.1:\(stack.port)"
        func path(_ inbox: Inbox) -> RemoteClientPath? {
            if case let .connected(path, _)? = inbox.lastState { return path }
            return nil
        }

        // The address the host named is gone and the next attempt is ten minutes off: the found one is tried now.
        var timing = RemoteHostConnection.Timing()
        timing.backoff = [600]
        let waiting = RemoteHostConnection(target: RemoteHostTarget(hostKey: link.macKey, direct: ["127.0.0.1:1"]),
                                           clientKey: key, hello: hello, timing: timing)
        let waits = Inbox(waiting.inbound)
        await waiting.start()
        _ = try await waits.waitFor("waiting") { if case .waiting? = $0.lastState { true } else { nil } }
        await waiting.discovered([found])
        _ = try await waits.waitFor("connected") { path($0) == .direct(found) ? true : nil }
        await waiting.stop()

        // On the relay (here the same listener under the relay's path), a found address takes over.
        let relayed = RemoteHostConnection(target: RemoteHostTarget(hostKey: link.macKey, direct: [], relayURL: "ws://\(found)",
                                                                    room: "room"), clientKey: key, hello: hello)
        let inbox = Inbox(relayed.inbound)
        await relayed.start()
        _ = try await inbox.waitFor("on the relay") { path($0) == .relay ? true : nil }
        await relayed.discovered([found])
        _ = try await inbox.waitFor("on the direct path") { path($0) == .direct(found) ? true : nil }
        let sent = await relayed.send(id: "1", .snapshot)
        XCTAssertTrue(sent)
        let snapshot = try await inbox.response("1")
        XCTAssertTrue(snapshot.ok)
        await relayed.stop()
    }

    /// The relay's second address (§14.2) is raced with the first: it connects a client the first address does not
    /// answer, it comes from the pairing link and message 2, and a host that names none any more leaves only the first.
    func testAClientRacesTheRelaysSecondAddress() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let silent = SilentListener()
        let silentPort = try await silent.start()
        defer { silent.stop() }
        let ticket = await stack.server.openPairing()
        let first = "ws://127.0.0.1:\(silentPort)", second = "ws://127.0.0.1:\(stack.port)"
        // Here the same listener stands under the relay's path.
        let link = RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret, name: "Loopback", hosts: [],
                                          relayURL: first, room: "room", alternateRelayURL: second)
        let key = RemoteKeyPair.generate()
        let hello = RemoteHandshakeHello(name: "Studio", platform: "macos", appVersion: "test")
        let reply = try await RemoteHostConnection.pair(link, clientKey: key, hello: hello)
        try await waitUntil { silent.accepted == 1 }

        var host = RemoteSavedHost(name: link.name, hostKey: link.macKey, direct: [], relayURL: first, room: "room",
                                   alternateRelayURL: second)
        let connection = RemoteHostConnection(target: try XCTUnwrap(host.target), clientKey: key, hello: hello)
        let inbox = Inbox(connection.inbound)
        await connection.start()
        _ = try await inbox.waitFor("on the relay") { if case .connected(.relay, _)? = $0.lastState { true } else { nil } }
        await connection.stop()

        XCTAssertNil(reply.relay, "the listener alone names no relay")
        host.update(from: reply)
        XCTAssertNil(host.alternateRelayURL)
        var named = reply
        named.relay = RemoteHandshakeReply.Relay(url: first, room: "room", alternate: second)
        host.update(from: named)
        XCTAssertEqual(host.alternateRelayURL, second)
        let saved = try JSONDecoder.remoteDates.decode(RemoteSavedHost.self, from: JSONEncoder.remoteDates.encode(host))
        XCTAssertEqual(saved.target?.alternateRelayURL, second)
    }

    /// Asking to connect now while an attempt is under way (the app coming back from Face ID or a permission
    /// prompt) lets it go on rather than cutting its handshake and starting again.
    func testReconnectingNowLetsAnAttemptUnderWayGoOn() async throws {
        let listener = SilentListener()
        let port = try await listener.start()
        defer { listener.stop() }
        var timing = RemoteHostConnection.Timing()
        timing.directTimeout = 30
        let connection = RemoteHostConnection(target: RemoteHostTarget(hostKey: RemoteKeyPair.generate().publicKey,
                                                                       direct: ["127.0.0.1:\(port)"]),
                                              clientKey: RemoteKeyPair.generate(),
                                              hello: RemoteHandshakeHello(name: "iPhone", platform: "ios"), timing: timing)
        let inbox = Inbox(connection.inbound)
        await connection.start()
        try await waitUntil { listener.accepted == 1 }
        await connection.reconnectNow()
        await connection.reconnectNow()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(listener.accepted, 1, "reconnectNow started the attempt over")
        XCTAssertEqual(inbox.lastState, .connecting)
        await connection.stop()
    }

    /// A retry asked for during a race that the relay then wins does not send the connection back to the direct
    /// address that did not answer; only an address Bonjour found meanwhile is worth trying from the relay.
    func testARetryDuringARaceTheRelayWinsDoesNotTryTheSameAddressAgain() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret, name: "Loopback",
                                          hosts: ["127.0.0.1:\(stack.port)"])
        let key = RemoteKeyPair.generate()
        let hello = RemoteHandshakeHello(name: "iPhone", platform: "ios", appVersion: "test")
        _ = try await RemoteHostConnection.pair(link, clientKey: key, hello: hello)
        let silent = SilentListener()
        let port = try await silent.start()
        defer { silent.stop() }
        var timing = RemoteHostConnection.Timing()
        timing.directTimeout = 30
        let connection = RemoteHostConnection(target: RemoteHostTarget(hostKey: link.macKey, direct: ["127.0.0.1:\(port)"],
                                                                       relayURL: "ws://127.0.0.1:\(stack.port)", room: "room"),
                                              clientKey: key, hello: hello, timing: timing)
        let inbox = Inbox(connection.inbound)
        await connection.start()
        try await waitUntil { silent.accepted == 1 }
        await connection.reconnectNow()
        _ = try await inbox.waitFor("on the relay") { if case .connected(.relay, _)? = $0.lastState { true } else { nil } }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(silent.accepted, 1, "the direct address that did not answer was tried again")
        await connection.stop()
    }

    /// A file goes up only while the host takes it forward (§15.20): an answer that holds no more than before, or more
    /// than the file, ends the upload instead of sending the same part again, and removing the attachment stops it.
    func testAFileGoesUpOnlyWhileTheHostTakesItForward() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString).bin")
        let size = RemoteProtocol.maxUploadPartBytes + 1000
        try Data(repeating: 7, count: size).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        final class Parts: @unchecked Sendable {
            private let lock = NSLock()
            private var offsets: [Int] = []
            private var entered = 0
            var sent: [Int] { lock.withLock { offsets } }
            var started: Int { lock.withLock { entered } }
            func start() { lock.withLock { entered += 1 } }
            /// Records a part and answers as `received` says; after five parts it refuses, so a client that resends
            /// forever stops here and the test reads what it sent.
            func answer(_ part: RemoteUploadPart, received: (RemoteUploadPart) -> Int?) -> RemoteResponse {
                let count = lock.withLock { offsets.append(part.offset); return offsets.count }
                if count > 5 { return .failure("", RemoteError(.badRequest)) }
                var response = RemoteResponse(re: "")
                response.received = received(part)
                return response
            }
        }

        let whole = Parts()
        let done = await RemoteFileUpload.send(file, mediaType: "application/octet-stream", uploadID: "u1") {
            whole.answer($0) { $0.offset + $0.data.count }
        }
        XCTAssertEqual(done, .success("u1"))
        XCTAssertEqual(whole.sent, [0, RemoteProtocol.maxUploadPartBytes])

        for received in [0, -1, size + 1] {
            let parts = Parts()
            let result = await RemoteFileUpload.send(file, mediaType: "application/octet-stream") { part in
                parts.answer(part) { _ in received }
            }
            XCTAssertEqual(result, .failure(.refused(nil)), "received \(received)")
            XCTAssertEqual(parts.sent, [0], "received \(received)")
        }

        let removed = Parts()
        let upload = Task {
            await RemoteFileUpload.send(file, mediaType: "application/octet-stream") { part in
                removed.start()
                try? await Task.sleep(for: .seconds(5))
                return removed.answer(part) { $0.offset + $0.data.count }
            }
        }
        try await waitUntil { removed.started == 1 }
        upload.cancel()
        let result = await upload.value
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertEqual(removed.sent.count, 1)
    }

    /// A file comes down in order from where each part ended (§15.22), starts over when it changes on the host between
    /// parts, waits out the host's read budget and a connection that comes back, and leaves nothing behind when it does
    /// not finish.
    func testAFileComesDownWholeOrLeavesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        /// A host serving `versions` of a file 4 bytes a part, the version read chosen by how many parts were asked,
        /// and errors answered in place of the parts asked for at the given counts.
        final class Host: @unchecked Sendable {
            private let lock = NSLock()
            private var asked: [Int] = []
            let versions: [(after: Int, text: String, modifiedAt: Int64)]
            let errors: [Int: RemoteError]
            init(_ versions: [(after: Int, text: String, modifiedAt: Int64)], errors: [Int: RemoteError] = [:]) {
                self.versions = versions
                self.errors = errors
            }
            var offsets: [Int] { lock.withLock { asked } }
            func answer(_ offset: Int) -> RemoteResponse {
                let count = lock.withLock { asked.append(offset); return asked.count }
                if let error = errors[count] { return .failure("", error) }
                guard let version = versions.last(where: { $0.after < count }) else { return .failure("", RemoteError(.notFound)) }
                let bytes = Data(version.text.utf8)
                var response = RemoteResponse(re: "")
                response.path = "/Users/example/notes.txt"
                response.name = "notes.txt"
                response.mediaType = "text/plain"
                response.size = bytes.count
                response.offset = offset
                response.modifiedAt = version.modifiedAt
                response.data = bytes.subdata(in: min(offset, bytes.count)..<min(offset + 4, bytes.count))
                return response
            }
        }
        func read(_ host: Host, into folder: URL) async -> Result<RemoteFileDownload.File, RemoteFileDownload.Failure> {
            await RemoteFileDownload.read(into: folder, pause: .zero, through: { host.answer($0) }, reconnected: { true })
        }

        let whole = Host([(0, "one two three", 1)])
        let file = try await read(whole, into: root.appending(path: "a")).get()
        XCTAssertEqual(whole.offsets, [0, 4, 8, 12])
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), "one two three")
        XCTAssertEqual(file.url, root.appending(path: "a/notes.txt"))
        XCTAssertEqual([file.path, file.mediaType], ["/Users/example/notes.txt", "text/plain"])

        let changed = Host([(0, "one two three", 1), (1, "four five", 2)])
        let second = try await read(changed, into: root.appending(path: "b")).get()
        XCTAssertEqual(changed.offsets, [0, 4, 0, 4, 8])
        XCTAssertEqual(try String(contentsOf: second.url, encoding: .utf8), "four five")
        XCTAssertEqual(second.modifiedAt, 2)

        let waited = Host([(0, "one two three", 1)], errors: [2: RemoteError(.rateLimited), 3: RemoteError(.unavailable)])
        let third = try await read(waited, into: root.appending(path: "c")).get()
        XCTAssertEqual(waited.offsets, [0, 4, 4, 4, 8, 12])
        XCTAssertEqual(try String(contentsOf: third.url, encoding: .utf8), "one two three")

        let changing = Host((0..<20).map { ($0, "version \($0) of it", Int64($0)) })
        let gone = root.appending(path: "d")
        let result = await read(changing, into: gone)
        XCTAssertEqual(result, .failure(.changing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path(percentEncoded: false)))

        let refused = await read(Host([]), into: root.appending(path: "e"))
        XCTAssertEqual(refused, .failure(.refused(RemoteError(.notFound))))
        let dropped = await read(Host([(0, "one", 1)], errors: [1: RemoteError(.unavailable)]), into: root.appending(path: "f"))
        XCTAssertEqual(dropped, .failure(.notConnected), "a connection lost before the first part is not waited for")
        XCTAssertEqual(RemoteFileDownload.safeName("../a/b\u{7}.pdf"), "..ab.pdf")
    }

    func testSavedHostsLiveInOnePrivateFileThatGoesWithTheLastHost() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-hosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "hosts.json")
        let store = RemoteHostStore(fileURL: file)
        var host = RemoteSavedHost(name: "Mac Studio", hostKey: Data(repeating: 7, count: 32), direct: ["10.0.0.2:47616"])
        store.save(host)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        var reply = RemoteHandshakeReply(ok: true)
        reply.server = RemoteServerInfo(name: "Office Mac", appVersion: "1")
        reply.direct = ["10.0.0.3:47616"]
        reply.deviceId = "D1"
        host.update(from: reply)
        store.save(host)
        let reread = RemoteHostStore(fileURL: file)
        XCTAssertEqual(reread.all().map(\.name), ["Office Mac"])
        XCTAssertEqual(reread.host(key: Data(repeating: 7, count: 32))?.direct, ["10.0.0.3:47616", "10.0.0.2:47616"])
        XCTAssertEqual(reread.all().first?.deviceID, "D1")
        reread.remove(host.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // A file this version cannot read is kept aside, not lost to the next save, and the app hears of both.
        try Data("{\"version\": 2, \"computers\": []}".utf8).write(to: file)
        final class Events: @unchecked Sendable { var all: [RemoteHostStore.FileEvent] = [] }
        let events = Events()
        let later = RemoteHostStore(fileURL: file) { events.all.append($0) }
        XCTAssertTrue(later.all().isEmpty)
        later.save(host)
        XCTAssertEqual(events.all, [.unreadable, .saved(true)])
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("hosts-unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: try XCTUnwrap(aside.first))),
                       Data("{\"version\": 2, \"computers\": []}".utf8))
    }
}

/// What a connection's stream delivered, in order, read by the test as it arrives.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [RemoteHostConnection.Inbound] = []
    private var reader: Task<Void, Never>?

    init(_ stream: AsyncStream<RemoteHostConnection.Inbound>) {
        reader = Task { [weak self] in
            for await inbound in stream { self?.lock.withLock { self?.received.append(inbound) } }
        }
    }

    deinit { reader?.cancel() }

    var messages: [RemoteHostConnection.Inbound] { lock.withLock { received } }

    var lastState: RemoteHostConnection.State? {
        messages.reversed().lazy.compactMap { if case let .state(state) = $0 { state } else { nil } }.first
    }

    func response(_ id: String) async throws -> RemoteResponse {
        try await waitFor("response \(id)") { inbox in
            inbox.messages.lazy.compactMap { if case let .response(response) = $0, response.re == id { response } else { nil } }.first
        }
    }

    func waitFor<Value>(_ what: String, timeout: TimeInterval = 10, _ read: (Inbox) -> Value?) async throws -> Value {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = read(self) { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestChannel.TimedOut(description: "Timed out waiting for \(what)")
    }
}

/// A TCP listener on loopback that accepts connections and never answers, so a client's handshake waits.
final class SilentListener: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var held: [NWConnection] = []
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "silent-listener")

    var accepted: Int { lock.withLock { count } }

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            lock.withLock {
                count += 1
                held.append(connection)
            }
            connection.start(queue: queue)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case let .failed(error): if once.take() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        lock.withLock { held.forEach { $0.cancel() } }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }
}
