import Foundation
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
            XCTAssertEqual(failure.error?.code, .pairingUnavailable)
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
        await stack.server.revoke(deviceID)
        _ = try await inbox.waitFor("revoked") { $0.lastState == .revoked ? true : nil }
        let again = await connection.send(id: "3", .ping)
        XCTAssertFalse(again)
        await connection.stop()
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
