import Foundation
import Observation
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote
@testable import YardletRemoteFixtureSupport

/// A host's window model (`RemoteHostModel`) following the fixture host on loopback: pairing by its link,
/// the task list, a conversation read into the app's conversation model, an approval answered with the
/// host card's own answer, a line's output read when it opens, a long conversation changed in proportion to
/// the change, and what a window showed shown again when it reopens.
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

    /// A host task's browser in the window's panel (§15.25): the handoff's card shows the handed tab, its pictures come
    /// one after another as the window takes each, and a click, typing, Tab and the trackpad reach the page in the order
    /// made, the trackpad's movements added up. The password field's focus reaches the panel, and the handoff's bar
    /// answers the host. Closing the panel lets the tab go.
    func testAHostTasksBrowserShowsItsTabAndTakesInput() async throws {
        typealias ID = RemoteFixtureBridge.ID
        let stack = try await LoopbackStack(name: "Mac Studio", bridge: RemoteFixtureBridge(speed: 25))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let directory = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await directory.pair(link: link.absoluteString)
        let model = try XCTUnwrap(directory.model(for: paired.id))
        defer { directory.close(paired.id) }
        try await waitUntil { model.hasSnapshot }
        XCTAssertTrue(model.offersBrowser)

        model.select(.task(ID.handoff))
        let conversation = try XCTUnwrap(model.conversations[ID.handoff])
        try await waitUntil { conversation.presentation.turns.last?.requests.isEmpty == false }
        let request = try XCTUnwrap(conversation.presentation.turns.last?.requests.first)
        XCTAssertEqual(request.responses.map(\.title), ["Decline", "Show Tab", "I'm done"].map(L10n.string))
        let show = try XCTUnwrap(request.responses.first { $0.title == L10n.string("Show Tab") })
        model.respond(taskID: ID.handoff, requestID: request.id, route: show.route)
        let browser = model.browser
        XCTAssertEqual(browser.taskID, ID.handoff)
        try await waitUntil { browser.frame != nil && browser.isListed }
        XCTAssertEqual(browser.tabID, RemoteFixtureTabs.signInTab)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertEqual(browser.watchedTab?.requestId, request.id, "the tab carries the handoff the bar answers")
        let first = try XCTUnwrap(browser.frame)

        // A frame changes the panel's picture only: the conversation and what shows the panel are not drawn again.
        let redrawn = SignalRecorder()
        withObservationTracking {
            _ = conversation.presentation
            _ = browser.taskID
        } onChange: { redrawn.record(.tasks) }

        // Drawn 320 points wide, the picture's point (100, 72) is the page's (200, 144): the username field.
        let field = try XCTUnwrap(browser.pagePoint(x: 100, y: 72.5, drawnWidth: 320))
        XCTAssertEqual(field.x, 200)
        browser.input(.click(x: field.x, y: field.y))
        browser.input(.text("octo"))
        browser.input(.text("cat"))
        browser.input(.key("Tab"))
        try await waitUntil { browser.watchedTab?.passwordField == true }
        // Each frame follows the one the window took.
        try await waitUntil { (browser.frame?.number ?? 0) > first.number }
        XCTAssertTrue(redrawn.changes.isEmpty, "frames and the list redraw only the browser panel")
        for _ in 0..<5 { browser.scroll(x: 10, y: 10, deltaX: 0, deltaY: 30) }
        browser.input(.text("hunter2"))
        browser.input(.key("Enter"))
        try await waitUntil { browser.watchedTab?.title == "New release · acme/web" }
        XCTAssertNil(browser.refusal)

        // The bar's I'm done answers the handoff on the host.
        model.send(.answerHandoff(taskID: ID.handoff, requestID: request.id, answer: .done))
        try await waitUntil { browser.watchedTab?.requestId == nil }
        try await waitUntil { conversation.presentation.turns.last?.requests.isEmpty == true }

        browser.hide()
        XCTAssertNil(browser.taskID)
        XCTAssertNil(browser.frame)
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

    /// What a window last showed stays for its next opening (docs/REMOTE_PROTOCOL.md §18): the list and an open
    /// conversation show before the host is reached, the host's own replace them once it is, here found on a
    /// new port by a stand-in for Bonjour, and removing the host removes them.
    func testAReopenedWindowShowsWhatItLastShowedUntilTheHostAnswers() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let root = FileManager.default.temporaryDirectory.appending(path: "remote-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let finder = FakeDiscovery()
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Loopback", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let directory = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"),
                                            cacheRoot: root, discovery: finder.discovery)
        let host = try await directory.pair(link: link.absoluteString)
        let idle = RemoteFixtureBridge.ID.idle
        func prompt(_ conversation: RemoteConversationModel) -> String? {
            conversation.presentation.turns.flatMap(\.prompt).lazy.compactMap { item -> String? in
                if case let .userMessage(text, _) = item.kind { return text }
                return nil
            }.first
        }

        let first = try XCTUnwrap(directory.model(for: host.id))
        XCTAssertEqual(finder.watched, [RemoteIdentity.discoveryID(for: stack.identity.noise.publicKey)])
        try await waitUntil { first.hasSnapshot }
        let approval = RemoteFixtureBridge.ID.approval
        first.select(.task(approval))
        try await waitUntil { first.conversations[approval]?.isLoaded == true }
        first.select(.task(idle))
        let read = try XCTUnwrap(first.conversations[idle])
        try await waitUntil { read.isLoaded }
        XCTAssertEqual(prompt(read), "Find the footer links that 404")
        // Written as the window closes, in a folder only this user can read.
        directory.close(host.id)
        XCTAssertFalse(finder.isWatching)
        let folder = root.appending(path: host.id, directoryHint: .isDirectory)
        let listFile = folder.appending(path: "list.json")
        let pageFile = folder.appending(path: "conversation-\(RemoteEncoding.base64url(Data(idle.utf8))).json")
        try await waitUntil { FileManager.default.fileExists(atPath: listFile.path) }
        func mode(_ url: URL) throws -> Int? { try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int }
        XCTAssertEqual(try mode(folder), 0o700)
        XCTAssertEqual(try mode(listFile), 0o600)
        XCTAssertEqual(try mode(pageFile), 0o600)

        // Marked here, so the test tells what the cache shows from what the host sends.
        var list = try JSONDecoder().decode(RemoteHostCache.List.self, from: Data(contentsOf: listFile))
        XCTAssertEqual(Set(list.conversations), [idle, approval])
        let index = try XCTUnwrap(list.tasks.firstIndex { $0.id == idle })
        list.tasks[index].title = "Fix the footer links (cached)"
        try JSONEncoder().encode(list).write(to: listFile)
        var page = try JSONDecoder().decode(RemoteHostCache.Page.self, from: Data(contentsOf: pageFile))
        let user = try XCTUnwrap(page.items.firstIndex { $0.kind == .user })
        page.items[user].text = "Find the footer links (cached)"
        try JSONEncoder().encode(page).write(to: pageFile)

        // The host can't be reached where it was: the window shows what it last showed, at once.
        stack.listener.stop()
        let second = try XCTUnwrap(directory.model(for: host.id))
        try await waitUntil { second.task(idle)?.title == "Fix the footer links (cached)" }
        XCTAssertFalse(second.hasSnapshot)
        XCTAssertFalse(second.isConnected)
        second.select(.task(idle))
        let shown = try XCTUnwrap(second.conversations[idle])
        XCTAssertTrue(shown.isLoaded)
        XCTAssertEqual(prompt(shown), "Find the footer links (cached)")
        // A line opened while the host is away reads nothing, and asks again once it is back.
        second.select(.task(approval))
        let cached = try XCTUnwrap(second.conversations[approval])
        let line = try XCTUnwrap(cached.presentation.turns.flatMap(\.work).first { item in
            if case let .tool(tool) = item.kind { return tool.loadsDetailOnOpen }
            return false
        })
        second.loadDetail(approval, itemID: line.id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(cached.details[line.id], "Nothing kept for a read the host never answered")
        second.select(.task(idle))

        // Found on the network on another port: the host's own list and page replace them, and the found
        // address is not saved as one the host named.
        let moved = RemoteSecureListener(server: stack.server, staticKey: stack.identity.noise, port: 0, advertisement: nil,
                                         loopbackOnly: true)
        moved.start()
        defer { moved.stop() }
        let address = "127.0.0.1:\(try await RemoteSecureTests.waitForPort(moved))"
        finder.report([address])
        try await waitUntil { second.hasSnapshot && second.task(idle)?.title == "Fix the footer links" }
        XCTAssertEqual(second.connection, .connected(.direct(address)))
        try await waitUntil { prompt(shown) == "Find the footer links that 404" }
        second.select(.task(approval))
        let live = try XCTUnwrap(second.conversations[approval])
        try await waitUntil { live.presentation.turns.flatMap(\.work).contains { $0.id == line.id } }
        second.loadDetail(approval, itemID: line.id)
        try await waitUntil { live.details[line.id]?.output != nil || live.details[line.id]?.diffs.isEmpty == false }
        XCTAssertFalse(directory.host(host.id)?.direct.contains(address) ?? true)

        // Removing the host removes what it showed, and the folder of all hosts with its last one.
        await directory.forget(host.id)
        try await waitUntil { !FileManager.default.fileExists(atPath: root.path) }
    }

    /// What phase one left to the host, now done in the window through the host's own paths: an MCP form
    /// filled in on the card and sent with the host's Submit, a suggested task started there, "Allow once"
    /// from a notification, the host's scheduled tasks run and resumed, and a task's outputs and the files its
    /// conversation names read into a private copy here, which goes with the window.
    func testAWindowFillsAFormStartsASuggestionAllowsOnceAndReadsTheHostsSchedulesAndFiles() async throws {
        typealias ID = RemoteFixtureBridge.ID
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Loopback", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let directory = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let host = try await directory.pair(link: link.absoluteString)
        let model = try XCTUnwrap(directory.model(for: host.id))
        try await waitUntil { model.hasSnapshot }
        XCTAssertTrue(model.offersSchedules)
        XCTAssertTrue(model.offersTaskFiles)

        // The form draws as the card's own, checks its fields as the card does, and Submit sends the values.
        model.select(.task(ID.form))
        let form = try XCTUnwrap(model.conversations[ID.form])
        try await waitUntil { form.isLoaded }
        let request = try XCTUnwrap(form.presentation.turns.last?.requests.first)
        guard case let .mcpForm(fields)? = request.form else { return XCTFail("No form: \(String(describing: request.form))") }
        XCTAssertEqual(fields.fields.map(\.id), ["repo", "private", "team"])
        XCTAssertEqual(fields.fields.first?.isRequired, true)
        XCTAssertEqual(request.responses.map(\.title), ["Decline", "Submit"])
        let submit = try XCTUnwrap(request.responses.last)
        XCTAssertNil(request.route(for: submit, input: ConversationRequestFormInput()), "Submit without the required field")
        var input = ConversationRequestFormInput()
        input.fields = ["repo": .text("acme/billing"), "team": .picked(["web"])]
        model.respond(taskID: ID.form, requestID: request.id, route: try XCTUnwrap(request.route(for: submit, input: input)))
        try await waitUntil {
            form.presentation.turns.last?.requests.isEmpty == true && form.presentation.turns.last?.answers.contains {
                if case let .answer(text, _) = $0.kind { text.contains("**acme/billing** (private)") } else { false }
            } == true
        }

        // The suggested task's chip reads what became of it from the host, and Start starts it there.
        model.select(.task(ID.idle))
        let idle = try XCTUnwrap(model.conversations[ID.idle])
        try await waitUntil { idle.isLoaded }
        let chip = idle.presentation.turns.flatMap { $0.work + $0.answers }.first { item in
            if case .taskSuggestion = item.kind { true } else { false }
        }
        guard case let .taskSuggestion(suggestion)? = chip?.kind else { return XCTFail("No suggestion chip") }
        XCTAssertEqual(suggestion.title, "Add a link checker to CI")
        XCTAssertNil(idle.suggestions[suggestion.id].flatMap(RemoteSuggestionState.resolution))
        model.send(.actOnSuggestion(taskID: ID.idle, suggestionID: suggestion.id, action: .start))
        try await waitUntil { idle.suggestions[suggestion.id].flatMap(RemoteSuggestionState.resolution)?.outcome == .started }
        let started = try XCTUnwrap(idle.suggestions[suggestion.id].flatMap(RemoteSuggestionState.resolution)?.startedTaskID)
        try await waitUntil { model.task(started.uuidString)?.parentTaskId == ID.idle }

        // An approval's notification offers "Allow once", the host card's narrowest allow, and says which request.
        model.select(.task(ID.approval))
        let approval = try XCTUnwrap(model.conversations[ID.approval])
        try await waitUntil { approval.isLoaded }
        var waiting = RemoteEvent(.attention)
        waiting.taskId = ID.approval
        waiting.title = "Approve the index migration"
        waiting.state = .waiting
        waiting.pendingRequest = .approval
        waiting.requestId = "toolu_fixture_1"
        XCTAssertTrue(model.offersAllowOnce(waiting))
        let notice = try XCTUnwrap(RemoteAttentionNotice.notification(hostID: host.id, hostName: model.name, event: waiting,
                                                                      offersAllowOnce: model.offersAllowOnce(waiting)))
        XCTAssertTrue(notice.offersAllowOnce)
        XCTAssertEqual(SystemNotificationTarget(userInfo: notice.target.userInfo), notice.target)
        XCTAssertEqual(notice.target.requestID, "toolu_fixture_1")
        // A finish the host keeps quiet about posts nothing and takes the wait's notification back, as the host's do.
        var finished = waiting
        finished.previousState = .waiting
        finished.state = .unread
        XCTAssertNotNil(RemoteAttentionNotice.notification(hostID: host.id, hostName: model.name, event: finished))
        XCTAssertNil(RemoteAttentionNotice.withdrawn(hostID: host.id, event: finished))
        finished.announces = false
        XCTAssertNil(RemoteAttentionNotice.notification(hostID: host.id, hostName: model.name, event: finished))
        XCTAssertEqual(RemoteAttentionNotice.withdrawn(hostID: host.id, event: finished), notice.identifier)
        var question = waiting
        question.taskId = ID.question
        question.pendingRequest = .input
        XCTAssertFalse(model.offersAllowOnce(question))
        let allowed = await directory.allowOnce(hostID: host.id, taskID: ID.approval, requestID: "toolu_fixture_1")
        XCTAssertTrue(allowed)
        try await waitUntil { approval.presentation.turns.last?.requests.isEmpty == true }
        let again = await directory.allowOnce(hostID: host.id, taskID: ID.approval, requestID: "toolu_fixture_1")
        XCTAssertFalse(again, "An answered request is not answered twice")

        // The host's schedules in its list's groups; Resume and Run now act there, and the list follows.
        model.schedules.load()
        try await waitUntil { model.schedules.list?.count == 4 }
        XCTAssertEqual(model.schedules.list?.map(\.id), [ID.morningSchedule, ID.footerSchedule, ID.screenshotsSchedule,
                                                         ID.reminderSchedule])
        XCTAssertEqual(model.schedules.list?.map(\.section), [.upcoming, .off, .off, .finished])
        model.schedules.setEnabled(ID.footerSchedule, true)
        try await waitUntil { model.schedules.schedule(ID.footerSchedule)?.enabled == true }
        let lastRun = model.schedules.schedule(ID.morningSchedule)?.lastRun?.at
        model.schedules.runNow(ID.morningSchedule)
        try await waitUntil { model.schedules.schedule(ID.morningSchedule)?.lastRun?.at != lastRun }

        // A task's outputs, read as the host's card lists them, and its files copied here, privately.
        model.files.loadOutputs(ID.history)
        try await waitUntil { model.files.outputs[ID.history]?.count == 2 }
        let summary = try XCTUnwrap(model.files.outputs[ID.history]?.first)
        XCTAssertEqual(summary.name, "crash-summary.pdf")
        let copy = try await model.files.copy(taskID: ID.history, path: summary.path).get()
        XCTAssertEqual(copy.lastPathComponent, "crash-summary.pdf")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: URL(filePath: summary.path)))
        let permissions = try FileManager.default.attributesOfItem(atPath: copy.path(percentEncoded: false))[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        // A path as the conversation writes it, with a line, relative to the task's folder.
        let notes = try await model.files.copy(taskID: ID.history, path: "reports/crash-notes.txt:12").get()
        XCTAssertEqual(notes.lastPathComponent, "crash-notes.txt")
        let outside = await model.files.copy(taskID: ID.history, path: "../Desktop/private-notes.txt")
        XCTAssertEqual(outside, .failure(.notServed))
        directory.close(host.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.path(percentEncoded: false)))
    }

    /// A host task's "Allow once" goes to its host; where the host does not take it, the task opens instead.
    func testAHostTasksAllowOnceAnswersThereOrOpensTheTask() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteHostModelTests.allowOnce")))
        let app = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
                           runtimeSelections: RuntimeSelectionStore(defaults: defaults), restoresIndexOnLaunch: false)
        var answered: [String] = []
        var opened: [String] = []
        var takes = true
        app.allowRemoteOnce = { _, taskID, requestID in
            answered.append("\(taskID)/\(requestID)")
            return takes
        }
        app.openRemoteTask = { _, taskID in opened.append(taskID) }
        let target = SystemNotificationTarget(remoteTask: RemoteTaskReveal(hostID: "H", taskID: "T"), requestID: "R")
        await app.handleNotificationResponse(SystemNotificationResponse(target: target, action: .allowOnce))
        XCTAssertEqual(answered, ["T/R"])
        XCTAssertEqual(opened, [])
        takes = false
        await app.handleNotificationResponse(SystemNotificationResponse(target: target, action: .allowOnce))
        XCTAssertEqual(opened, ["T"])
        await app.handleNotificationResponse(SystemNotificationResponse(target: target, action: .open))
        XCTAssertEqual(answered.count, 2)
        XCTAssertEqual(opened, ["T", "T"])
        await app.shutdown()
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

/// A stand-in for Bonjour: the test says when the host is found and where.
@MainActor
private final class FakeDiscovery {
    private(set) var watched: [String] = []
    private var found: RemoteHostDiscovery.Found?

    var isWatching: Bool { found != nil }

    var discovery: RemoteHostDiscovery {
        RemoteHostDiscovery { [self] discoveryID, found in
            watched.append(discoveryID)
            self.found = found
            return { [self] in self.found = nil }
        }
    }

    func report(_ addresses: [String]) {
        found?(addresses)
    }
}
