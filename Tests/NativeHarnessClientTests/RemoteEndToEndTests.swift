import Foundation
import XCTest
@testable import YardletRemote
@testable import YardletRemoteFixtureSupport

/// The remote end to end on loopback: the Noise listener (`RemoteSecureListener`) bound to 127.0.0.1 on a
/// free port, the fixture bridge behind it, and `URLSessionWebSocketTask` with a Noise initiator as the
/// phone. Nothing listens on any other address, and no provider runs.
final class RemoteEndToEndTests: XCTestCase {
    func testAPhonePairsFollowsATaskAndAnswersItsApproval() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let phoneKey = RemoteKeyPair.generate()
        let phone = try await stack.phone(key: phoneKey, hello: RemoteHandshakeHello(name: "Emulator",
                                                                                     pair: RemoteEncoding.base64url(ticket.secret)))
        defer { phone.close() }
        XCTAssertTrue(phone.reply.ok, "\(phone.reply)")
        XCTAssertEqual(phone.reply.paired, true)

        try await phone.send(#"{"id":"2","type":"snapshot"}"#)
        let snapshot = try await phone.response("2")
        let approval = try XCTUnwrap(snapshot.tasks?.first { $0.id == RemoteFixtureBridge.ID.approval })
        XCTAssertEqual(approval.attention, .waiting)
        XCTAssertEqual(approval.indicator, .awaitingApproval)
        XCTAssertEqual(snapshot.projects?.map(\.kind), [.project, .project, .chats])
        XCTAssertEqual(snapshot.tasks?.first { $0.id == RemoteFixtureBridge.ID.child }?.parentTaskId, RemoteFixtureBridge.ID.idle)

        try await phone.send(#"{"id":"3","type":"subscribeTask","taskId":"\#(RemoteFixtureBridge.ID.approval)"}"#)
        let subscribed = try await phone.response("3")
        var items = try XCTUnwrap(subscribed.items)
        let request = try XCTUnwrap(items.first { $0.kind == .approval && $0.status == "pending" })
        XCTAssertEqual(request.options?.contains("allowOnce"), true)

        try await phone.send(#"{"id":"4","type":"answerApproval","taskId":"\#(RemoteFixtureBridge.ID.approval)","requestId":"\#(request.requestId ?? "")","answer":"allowOnce"}"#)
        let awaited25 = try await phone.response("4").ok
        XCTAssertTrue(awaited25)

        // The command runs and the answer streams in as changes, until the turn completes.
        let finished = try await phone.waitFor("the finished answer") { () -> [RemoteItem]? in
            for event in phone.takeEvents(.conversation) { items = items.applying(event.changes ?? []) }
            let answer = items.last { $0.kind == .assistant && $0.role == "answer" }
            return answer?.streaming == nil && answer?.text?.contains("migration tests pass") == true ? items : nil
        }
        XCTAssertEqual(finished.first { $0.id == request.id }?.status, "allowed")
        XCTAssertEqual(finished.first { $0.kind == .activity && $0.activity == "command" }?.exitCode, 0)
        let attention = try await phone.waitFor("attention") {
            phone.events(.attention).first { $0.taskId == RemoteFixtureBridge.ID.approval && $0.state == .unread }
        }
        // Snapshots are coalesced: a fast turn can go from waiting to unread between two of them.
        XCTAssertTrue([.active, .waiting].contains(attention.previousState), "\(attention)")

        // A second connection authenticates with the phone's key alone.
        let again = try await stack.phone(key: phoneKey, hello: RemoteHandshakeHello(name: "Emulator"))
        defer { again.close() }
        XCTAssertEqual(again.reply.deviceId, phone.reply.deviceId)
        try await again.send(#"{"id":"2","type":"stopTurn","taskId":"\#(RemoteFixtureBridge.ID.idle)"}"#)
        let awaited27 = try await again.response("2").error?.code
        XCTAssertEqual(awaited27, .notRunning)
    }

    func testABrowserHandshakeIsRefused() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let started = Date()
        let browser = stack.socket(origin: "https://example.test")
        defer { browser.cancel(with: .normalClosure, reason: nil) }
        do {
            try await browser.send(.data(Data([1, 2, 3])))
            _ = try await browser.receive()
            XCTFail("A handshake with Origin was accepted")
        } catch {
            // Refused before any frame, and the socket let go at once.
            XCTAssertEqual((browser.response as? HTTPURLResponse)?.statusCode, 400)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let status = await stack.server.status
        XCTAssertTrue(status.connectedDeviceIDs.isEmpty)
    }

    func testTextAndOversizedFramesCloseTheConnection() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let text = stack.socket()
        defer { text.cancel(with: .normalClosure, reason: nil) }
        try? await text.send(.string(#"{"id":"1","type":"ping"}"#))
        try await Self.waitUntilClosed(text)

        let big = stack.socket()
        defer { big.cancel(with: .normalClosure, reason: nil) }
        try? await big.send(.data(Data(count: RemoteNoise.maxMessageLength + 10)))
        try await Self.waitUntilClosed(big)
        let closed = await stack.server.status.connectedDeviceIDs
        XCTAssertTrue(closed.isEmpty)
    }

    private static func waitUntilClosed(_ task: URLSessionWebSocketTask) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            do { _ = try await task.receive() } catch { return }
        }
        throw TestChannel.TimedOut(description: "The socket stayed open")
    }
}

/// A server on 127.0.0.1 with the fixture tasks, run fast.
final class LoopbackStack: @unchecked Sendable {
    let server: RemoteServer
    let identity: RemoteIdentity
    let listener: RemoteSecureListener
    let port: UInt16

    init() async throws {
        identity = try RemoteIdentity(noisePrivateKey: Data(RemoteRandom.bytes(32)), relayPrivateKey: Data(RemoteRandom.bytes(32)))
        server = RemoteServer(
            configuration: RemoteServer.Configuration(server: RemoteServerInfo(name: "Loopback", appVersion: "test"),
                                                      macKey: identity.noise.publicKey),
            bridge: RemoteFixtureBridge(speed: 25), devices: RemoteDeviceStore(fileURL: nil))
        await server.start()
        listener = RemoteSecureListener(server: server, staticKey: identity.noise, port: 0, advertisement: nil, loopbackOnly: true)
        listener.start()
        port = try await RemoteSecureTests.waitForPort(listener)
    }

    /// A socket that has not shaken hands.
    func socket(origin: String? = nil) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/")!)
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return task
    }

    /// A phone that has done the Noise handshake with `hello` as message 1's payload.
    func phone(key: RemoteKeyPair, hello: RemoteHandshakeHello) async throws -> PhoneSocket {
        try await PhoneSocket.connect(task: socket(), phoneKey: key, macKey: identity.noise.publicKey, hello: hello)
    }

    func stop() {
        listener.stop()
    }
}

/// `URLSessionWebSocketTask` with a Noise initiator as a phone: every message it receives, decrypted and read
/// as responses and events.
final class PhoneSocket: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    let reply: RemoteHandshakeReply
    private let lock = NSLock()
    private var sender: RemoteNoiseCipher
    private var receiver: RemoteNoiseCipher
    private var joiner = RemoteNoiseFraming.Joiner(limit: RemoteProtocol.maxServerMessageBytes)
    private var texts: [String] = []
    private var consumed: [RemoteEvent.Name: Int] = [:]
    private var ended = false

    private init(task: URLSessionWebSocketTask, reply: RemoteHandshakeReply, sender: RemoteNoiseCipher, receiver: RemoteNoiseCipher) {
        self.task = task
        self.reply = reply
        self.sender = sender
        self.receiver = receiver
    }

    static func connect(task: URLSessionWebSocketTask, phoneKey: RemoteKeyPair, macKey: Data,
                        hello: RemoteHandshakeHello) async throws -> PhoneSocket {
        task.maximumMessageSize = RemoteNoise.maxMessageLength
        var noise = try RemoteNoiseHandshake(role: .initiator, localStatic: phoneKey, remoteStatic: macKey)
        try await task.send(.data(noise.writeMessage1(payload: Data(RemoteJSON.string(hello).utf8))))
        guard case let .data(message2) = try await task.receive() else { throw RemoteNoise.Failure("Expected binary") }
        let reply = try JSONDecoder().decode(RemoteHandshakeReply.self, from: noise.readMessage2(message2))
        let (sender, receiver) = noise.split()
        let phone = PhoneSocket(task: task, reply: reply, sender: sender, receiver: receiver)
        phone.receive()
        return phone
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(.data(frame)):
                lock.withLock {
                    // Nil until a message's last chunk is in.
                    if let message = try? joiner.add(frame, with: &receiver) { texts.append(String(decoding: message, as: UTF8.self)) }
                }
                receive()
            case .success:
                receive()
            case .failure:
                lock.withLock { ended = true }
            }
        }
    }

    func send(_ text: String) async throws {
        let frames = try lock.withLock { try RemoteNoiseFraming.seal(Data(text.utf8), with: &sender) }
        for frame in frames { try await task.send(.data(frame)) }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
    func response(_ id: String) async throws -> RemoteResponse {
        try await waitFor("response \(id)") {
            self.lock.withLock { self.texts }.lazy
                .compactMap { try? JSONDecoder().decode(RemoteResponse.self, from: Data($0.utf8)) }
                .first { $0.re == id }
        }
    }

    /// The events of a name not yet taken, in order.
    func events(_ name: RemoteEvent.Name) -> [RemoteEvent] {
        let (received, taken) = lock.withLock { (texts, consumed[name, default: 0]) }
        return Array(Self.events(name, in: received).dropFirst(taken))
    }

    /// The events of a name not yet taken, in order, marked taken in the same read: one that arrives meanwhile
    /// is left for the next call rather than marked taken unseen.
    func takeEvents(_ name: RemoteEvent.Name) -> [RemoteEvent] {
        let (received, taken) = lock.withLock { (texts, consumed[name, default: 0]) }
        let all = Self.events(name, in: received)
        lock.withLock { consumed[name] = all.count }
        return Array(all.dropFirst(taken))
    }

    private static func events(_ name: RemoteEvent.Name, in texts: [String]) -> [RemoteEvent] {
        texts.compactMap { try? JSONDecoder().decode(RemoteEvent.self, from: Data($0.utf8)) }.filter { $0.event == name }
    }

    func waitUntilClosed() async throws {
        _ = try await waitFor("close") { self.lock.withLock { self.ended } ? true : nil }
    }

    func waitFor<Value>(_ what: String, timeout: TimeInterval = 10, _ read: () -> Value?) async throws -> Value {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = read() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestChannel.TimedOut(description: "Timed out waiting for \(what): \(lock.withLock { texts.suffix(5) })")
    }
}
