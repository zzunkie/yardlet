import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote
@testable import YardletRemoteFixtureSupport

/// A host's window model (`RemoteHostModel`) following the fixture host on loopback: pairing by its link,
/// the task list, a conversation read into the app's conversation model, an approval answered with the
/// host card's own answer, a line's output read when it opens, and a long conversation changed in
/// proportion to the change.
@MainActor
final class RemoteHostModelTests: XCTestCase {
    func testAWindowPairsFollowsATaskAndAnswersItsApprovalAsTheHostsCard() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Loopback", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let keys = RemoteMemoryClientKeys()
        let directory = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: keys,
                                            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        do {
            _ = try await directory.pair(link: "yardlet-remote://pair?v=2")
            XCTFail("A link without a key paired")
        } catch let failure as RemoteHostDirectory.PairingFailure {
            XCTAssertEqual(failure, .notALink)
        }
        let host = try await directory.pair(link: link.absoluteString)
        XCTAssertEqual(directory.hosts.map(\.name), ["Loopback"])
        XCTAssertNotNil(keys.load(hostID: host.id))
        let model = try XCTUnwrap(directory.model(for: host.id))
        try await waitUntil { model.hasSnapshot }
        XCTAssertEqual(model.connection, .connected(.direct("127.0.0.1:\(stack.port)")))
        XCTAssertEqual(model.projects.map(\.kind), [.project, .project, .chats])
        XCTAssertEqual(model.task(RemoteFixtureBridge.ID.child)?.parentTaskId, RemoteFixtureBridge.ID.idle)

        // The waiting task's conversation draws its request with the host card's answers, in its order.
        model.select(.task(RemoteFixtureBridge.ID.approval))
        let conversation = try XCTUnwrap(model.conversations[RemoteFixtureBridge.ID.approval])
        try await waitUntil { conversation.isLoaded }
        let request = try XCTUnwrap(conversation.presentation.turns.last?.requests.first)
        XCTAssertEqual(request.responses.map(\.title),
                       ["Deny", "Always allow in this project (saved to .claude/settings.local.json)", "Allow for session", "Allow"])
        XCTAssertEqual(request.responses.map(\.role), [.destructive, .secondary, .secondary, .primary])
        XCTAssertEqual(request.command, "swift test --filter Migration")
        XCTAssertTrue(conversation.presentation.pendingRequestIDs.contains(request.id))
        guard case let .providerAction(standing)? = request.responses.dropFirst().first?.route else { return XCTFail() }
        XCTAssertEqual(standing.kind, RemoteTurnProjection.Route.standing)

        // "Allow" is the host's own answer: the request moves into the work as allowed and the answer streams.
        model.respond(taskID: RemoteFixtureBridge.ID.approval, requestID: request.id, route: try XCTUnwrap(request.responses.last?.route))
        try await waitUntil {
            let turn = conversation.presentation.turns.last
            return turn?.requests.isEmpty == true && turn?.status == .completed
                && turn?.answers.contains { if case let .answer(text, false) = $0.kind { text.contains("migration tests pass") } else { false } } == true
        }
        let answered = conversation.presentation.turns.last?.work.compactMap { item -> ConversationRequest? in
            if case let .request(request) = item.kind { return request }
            return nil
        }
        XCTAssertEqual(answered?.first?.state, .allowed)

        // A command's line reads its output once opened, a file change's line its diff.
        let lines = conversation.presentation.turns.flatMap(\.work).filter { item in
            if case let .tool(tool) = item.kind { return tool.loadsDetailOnOpen }
            return false
        }
        XCTAssertEqual(lines.count, 2)
        for line in lines { model.loadDetail(RemoteFixtureBridge.ID.approval, itemID: line.id) }
        try await waitUntil {
            let tools = conversation.presentation.turns.flatMap(\.work).compactMap { item -> ConversationTool? in
                guard lines.contains(where: { $0.id == item.id }), case let .tool(tool) = item.kind else { return nil }
                return tool
            }
            return tools.contains { $0.output?.isEmpty == false } && tools.contains { !$0.diffs.isEmpty }
        }

        // Removing the host asks it to forget this Mac, and leaves nothing here.
        let deviceID = try XCTUnwrap(model.host.deviceID)
        await directory.forget(host.id)
        let device = await stack.devices.device(deviceID)
        XCTAssertNil(device)
        XCTAssertTrue(directory.hosts.isEmpty)
        XCTAssertNil(keys.load(hostID: host.id))
    }

    /// Two Yardlets on loopback: the host is the app's own model behind the remote server
    /// (`AppModelRemoteBridge`, on a fake adapter so no provider runs), the client a host window's model.
    /// A message goes through the host's composer, and the request card's answer through the host's card.
    func testTwoYardletsOnLoopbackSendAndAnswerThroughTheHostsOwnPaths() async throws {
        let adapter = FakeHarnessAdapter(kind: .claudeCode)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteHostModelTests")))
        let host = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
                            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
                            registry: HarnessRegistry { _, _ in adapter }, restoresIndexOnLaunch: false)
        let created = await host.createSession(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/remote-desktop-e2e"),
                                               runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Migrate the index")
        let session = try XCTUnwrap(created)
        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let directory = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await directory.pair(link: link.absoluteString)
        let client = try XCTUnwrap(directory.model(for: paired.id))
        let taskID = session.id.uuidString
        try await waitUntil { client.task(taskID)?.title == "Migrate the index" }
        XCTAssertEqual(client.name, "Mac Studio")

        // Typed in the client's composer: the host sends it as its own composer would.
        client.select(.task(taskID))
        let conversation = try XCTUnwrap(client.conversations[taskID])
        try await waitUntil { conversation.isLoaded }
        let sent = await client.perform(.sendMessage(taskID: taskID, text: "Run the migration tests"))
        XCTAssertTrue(sent)
        try await waitUntil { await adapter.sentPrompts == ["Run the migration tests"] }

        // The host's request reaches the client's card with the host card's answers; the client's answer is the card's.
        let permission = PermissionRequest(id: "bash-1", title: "Bash", detail: "Run the migration tests",
                                           command: "swift test --filter Migration")
        await adapter.emit(.permissionRequested(permission), for: session.id, sequence: 1)
        await adapter.emit(.sessionStatusChanged(.waitingForApproval), for: session.id, sequence: 2)
        try await waitUntil { conversation.presentation.turns.last?.requests.first?.id == "bash-1" }
        try await waitUntil { client.task(taskID)?.indicator == .awaitingApproval }
        let request = try XCTUnwrap(conversation.presentation.turns.last?.requests.first)
        XCTAssertEqual(request.command, "swift test --filter Migration")
        let allow = try XCTUnwrap(request.responses.first { $0.role == .primary })
        client.respond(taskID: taskID, requestID: "bash-1", route: allow.route)
        try await waitUntil { await adapter.permissionDecisions["bash-1"] == .allow }
        try await waitUntil {
            conversation.presentation.turns.last?.requests.isEmpty == true
                && conversation.presentation.turns.last?.work.contains { item in
                    if case let .request(answered) = item.kind { return answered.id == "bash-1" && answered.state == .allowed }
                    return false
                } == true
        }
        XCTAssertTrue(host.transcriptBySessionID[session.id]?.contains { $0.content == .permission(permission, state: .allowed) } == true)
        directory.close(paired.id)
        await host.shutdown()
    }

    func testALongConversationProjectsOnlyTheTurnsAChangeTouches() throws {
        let conversation = RemoteConversationModel(taskID: "T", harness: .claudeCode, hostName: "Mac Studio")
        var page: [RemoteItem] = []
        for turn in 0..<300 {
            let turnID = "t\(turn)"
            var user = RemoteItem(id: "u\(turn)", turnId: turnID, kind: .user)
            user.text = "Message \(turn)"
            var header = RemoteItem(id: "turn:\(turnID)", turnId: turnID, kind: .turn)
            header.status = "completed"
            header.durationMs = 1000
            page += [user, header]
            for step in 0..<7 {
                var line = RemoteItem(id: "l\(turn)-\(step)", turnId: turnID, kind: .activity)
                line.activity = "command"
                line.title = "Ran step \(step)"
                line.status = "completed"
                line.inWork = true
                page.append(line)
            }
            var answer = RemoteItem(id: "a\(turn)", turnId: turnID, kind: .assistant)
            answer.role = "answer"
            answer.text = "Done \(turn)"
            page.append(answer)
        }
        XCTAssertEqual(page.count, 3000)
        conversation.load(page, cursor: nil, hasOlder: false)
        XCTAssertEqual(conversation.projectedTurnCount, 300)
        let before = conversation.presentation

        final class Count: @unchecked Sendable { var value = 0 }
        let publications = Count()
        func observe() {
            withObservationTracking { _ = conversation.presentation } onChange: { publications.value += 1 }
        }
        // The last answer streams: each event projects the one turn it changed and publishes once.
        for index in 0..<200 {
            observe()
            var streaming = RemoteItem(id: "a299", turnId: "t299", kind: .assistant)
            streaming.role = "answer"
            streaming.text = "Done 299" + String(repeating: " word", count: index)
            streaming.streaming = true
            XCTAssertTrue(conversation.apply([.upsert(streaming, after: "l299-6")]))
        }
        XCTAssertEqual(publications.value, 200)
        XCTAssertEqual(conversation.projectedTurnCount, 500)
        let after = conversation.presentation
        XCTAssertEqual(after.turns.count, 300)
        for index in 0..<299 { XCTAssertTrue(after.turns[index].isUnchanged(from: before.turns[index])) }

        // A new turn after the last: one more turn projected.
        var user = RemoteItem(id: "u300", turnId: "t300", kind: .user)
        user.text = "Next"
        XCTAssertTrue(conversation.apply([.upsert(user, after: "a299")]))
        XCTAssertEqual(conversation.projectedTurnCount, 501)
        XCTAssertEqual(conversation.presentation.turns.map(\.id).suffix(2), ["t299", "t300"])

        // A change after an item not held: out of step, nothing guessed.
        var stray = RemoteItem(id: "x", turnId: "t300", kind: .notice)
        stray.text = "?"
        XCTAssertFalse(conversation.apply([.upsert(stray, after: "missing")]))
    }

    func testRunsKeepTheHostsOrderThroughMovesAndRemovals() {
        func item(_ id: String, _ turn: String) -> RemoteItem { RemoteItem(id: id, turnId: turn, kind: .activity) }
        var items = RemoteConversationItems([item("a1", "A"), item("a2", "A"), item("b1", "B")])
        XCTAssertTrue(items.apply([.upsert(item("a3", "A"), after: "a2"), .remove("b1"), .upsert(item("b2", "B"), after: "a3")]))
        XCTAssertEqual(items.items.map(\.id), ["a1", "a2", "a3", "b2"])
        // An item of another turn placed inside a run splits it, and a removal joins it again.
        XCTAssertTrue(items.apply([.upsert(item("c1", "C"), after: "a1")]))
        XCTAssertEqual(items.runs.map(\.turnID), ["A", "C", "A", "B"])
        XCTAssertTrue(items.apply([.remove("c1")]))
        XCTAssertEqual(items.runs.map(\.turnID), ["A", "B"])
        XCTAssertEqual(items.items.map(\.id), ["a1", "a2", "a3", "b2"])
        // An existing item replaced in place under another turn stays where it was.
        XCTAssertTrue(items.apply([.upsert(item("a3", "B"), after: nil)]))
        XCTAssertEqual(items.items.map(\.id), ["a1", "a2", "a3", "b2"])
        XCTAssertEqual(items.runs.map(\.turnID), ["A", "B"])
        items.prepend([item("z1", "Z"), item("a0", "A")])
        XCTAssertEqual(items.items.map(\.id), ["z1", "a0", "a1", "a2", "a3", "b2"])
        XCTAssertEqual(items.runs.map(\.turnID), ["Z", "A", "B"])
    }
}
