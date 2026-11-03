import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote
@testable import YardletRemoteFixtureSupport

/// A task's settings, slash commands, edit and fork from another Yardlet (docs/REMOTE_PROTOCOL.md §15.23), on
/// loopback: the host is the app's own model behind the remote server (`AppModelRemoteBridge`, on a fake adapter so no
/// provider runs), the client a host window's model. Each control acts through the path the host's own menu takes, a
/// choice the host asks about first is refused until confirmed, and nothing the host shows switches to what the
/// client started.
@MainActor
final class RemoteTaskControlsTests: XCTestCase {
    func testACodexTasksSettingsCommandsEditAndForkGoThroughTheHostsOwnPaths() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(.object([
            "id": .string("provider-thread"), "turns": .array([Self.codexTurn(1), Self.codexTurn(2)])
        ]), to: &state))
        let session = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/remote-task-controls"),
                                    runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Tidy the parser",
                                    providerSessionID: "provider-thread")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteTaskControlsTests.codex")))
        let host = AppModel(store: SessionStore(sessions: [session], repository: InMemorySessionRepository()),
                            runtimeSelections: RuntimeSelectionStore(defaults: defaults), registry: HarnessRegistry { _, _ in adapter },
                            initialCodexPresentation: [session.id: state],
                            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
                            sessionTitleResolver: { _ in nil }, restoresIndexOnLaunch: false)
        // The thread the App Server shows once the task connects.
        await adapter.emitPresentation(state, for: session.id)
        let (client, close) = try await Self.connect(to: host)
        defer { close() }
        let taskID = session.id.uuidString
        try await waitUntil { client.task(taskID) != nil && client.taskControls }
        client.select(.task(taskID))
        let conversation = try XCTUnwrap(client.conversations[taskID])
        try await waitUntil { conversation.isLoaded && client.taskSettings[taskID] != nil }

        // The bottom row's settings: the sandbox policy, Full access asked about first, and the model menu, which reads
        // its list once opened.
        let permission = try XCTUnwrap(client.taskSettings[taskID]?.first { $0.role == "permission" })
        XCTAssertEqual(permission.value, CodexRunLocation.automatic.rawValue)
        XCTAssertEqual(permission.choices.map(\.value), CodexRunLocation.allCases.map(\.rawValue))
        XCTAssertEqual(permission.choices.last?.confirm?.title, L10n.string("Allow full access?"))
        await client.readTaskSettings(taskID, prepare: true)
        let effort = try XCTUnwrap(client.taskSettings[taskID]?.first { $0.role == "effort" })
        XCTAssertEqual(effort.choices.map(\.value), ["low", "high"])
        XCTAssertNil(effort.prepare)

        client.setTaskSetting(taskID, id: effort.id, value: "high", confirmed: false)
        try await waitUntil { client.taskSettings[taskID]?.first { $0.role == "effort" }?.value == "high" }
        XCTAssertEqual(host.composerCodexCapabilities(for: try XCTUnwrap(host.store.sessions.first)).modelCatalog.effort, "high")

        // Full access waits for its confirmation, as the host's menu does.
        let unconfirmed = await client.response(to: .setTaskSetting(taskID: taskID, setting: permission.id,
                                                                    value: CodexRunLocation.dangerFullAccess.rawValue))
        XCTAssertEqual(unconfirmed.error?.code, .notAllowed)
        XCTAssertEqual(host.store.sessions.first?.providerOptions[CodexRunLocation.storageKey], nil)
        client.setTaskSetting(taskID, id: permission.id, value: CodexRunLocation.dangerFullAccess.rawValue, confirmed: true)
        try await waitUntil { client.taskSettings[taskID]?.first { $0.role == "permission" }?.elevated == true }
        XCTAssertEqual(host.store.sessions.first?.providerOptions[CodexRunLocation.storageKey],
                       CodexRunLocation.dangerFullAccess.rawValue)
        // A change on the host's own menu reaches the client.
        await host.selectCodexRunLocation(.readOnly, for: try XCTUnwrap(host.store.sessions.first))
        try await waitUntil {
            client.taskSettings[taskID]?.first { $0.role == "permission" }?.value == CodexRunLocation.readOnly.rawValue
        }

        // The commands that may run from here, and none that edits files or needs the host's window.
        let listed = await client.composerCommands(taskID)
        let commands = try XCTUnwrap(listed)
        XCTAssertEqual(Set(commands.map(\.name)).intersection(["compact", "fork", "new", "init", "review-mode", "rename", "status"]),
                       ["compact", "fork", "new"])
        XCTAssertTrue(commands.allSatisfy { $0.runs == true })
        let compacted = await client.runComposerCommand(taskID, name: "compact", arguments: nil)
        XCTAssertTrue(compacted)
        try await waitUntil { await adapter.compactedSessionIDs == [session.id] }

        // The turns offer what the host's turns offer: Codex forks from any finished turn and edits its latest request.
        let turns = conversation.presentation.turns
        XCTAssertEqual(turns.map(\.actions.canFork), [true, true])
        XCTAssertEqual(turns.map { $0.actions.editLatest?.text }, [nil, "Request 2"])

        // The edit goes as the host's composer sends one, and the host's own words come back afterwards.
        let hostDraft = host.composerDrafts.tasks.draft(for: session.id)
        hostDraft.text = "Words typed on the host"
        let edited = await client.editMessage(taskID, turnID: "turn-2", text: "Request 2, the parser only")
        XCTAssertTrue(edited, client.commandError ?? "")
        let edits = await adapter.preparedEditTargets
        XCTAssertEqual(edits.first, "turn-2")
        let submitted = await adapter.codexSubmissions.last?.0.text
        XCTAssertEqual(submitted, "Request 2, the parser only")
        XCTAssertEqual(hostDraft.text, "Words typed on the host")
        XCTAssertNil(hostDraft.editState)

        // A fork from the first turn opens on the client; the host stays on what it showed.
        let shownOnHost = host.store.selectedSessionID
        client.fork(taskID, turnID: "turn-1")
        try await waitUntil {
            if case let .task(id) = client.selection { return id != taskID }
            return false
        }
        guard case let .task(forkID) = client.selection else { return XCTFail() }
        XCTAssertEqual(client.task(forkID)?.parentTaskId, taskID)
        let boundaries = await adapter.forkedThroughTurnIDs
        XCTAssertEqual(boundaries, ["turn-1"])
        XCTAssertEqual(host.store.selectedSessionID, shownOnHost)
        await host.shutdown()
    }

    /// A Claude Code task: its permission mode reads its choices first while the task is not connected, Bypass
    /// permissions waits for its confirmation, `/compact` goes as the composer sends it, and `/clear` starts a new chat the
    /// host does not switch to.
    func testAClaudeTasksPermissionModeAndCommandsGoThroughTheHostsOwnPaths() async throws {
        let adapter = FakeHarnessAdapter(kind: .claudeCode)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteTaskControlsTests.claude")))
        // A task from before this run, not connected to its harness yet.
        let session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/remote-task-controls"),
                                    runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Write the guide",
                                    providerSessionID: "claude-session")
        let host = AppModel(store: SessionStore(sessions: [session], repository: InMemorySessionRepository()),
                            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
                            registry: HarnessRegistry { _, _ in adapter },
                            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
                            sessionTitleResolver: { _ in nil }, restoresIndexOnLaunch: false)
        let (client, close) = try await Self.connect(to: host)
        defer { close() }
        let taskID = session.id.uuidString
        try await waitUntil { client.task(taskID) != nil && client.taskControls }
        client.select(.task(taskID))
        try await waitUntil { client.taskSettings[taskID]?.contains { $0.role == "permission" } == true }

        // Not connected yet: the menu reads its choices first, as the host's does, and nothing applies before then.
        let detached = try XCTUnwrap(client.taskSettings[taskID]?.first { $0.role == "permission" })
        XCTAssertEqual(detached.prepare, true)
        let early = await client.response(to: .setTaskSetting(taskID: taskID, setting: detached.id, value: "acceptEdits"))
        XCTAssertEqual(early.error?.code, .notAllowed)
        await client.readTaskSettings(taskID, prepare: true)
        let permission = try XCTUnwrap(client.taskSettings[taskID]?.first { $0.role == "permission" })
        XCTAssertNil(permission.prepare)
        XCTAssertEqual(permission.choices.first { $0.value == ClaudePermissionMode.bypassPermissions }?.confirm?.button,
                       L10n.string("Use bypass permissions"))

        let unconfirmed = await client.response(to: .setTaskSetting(taskID: taskID, setting: permission.id,
                                                                    value: ClaudePermissionMode.bypassPermissions))
        XCTAssertEqual(unconfirmed.error?.code, .notAllowed)
        client.setTaskSetting(taskID, id: permission.id, value: ClaudePermissionMode.bypassPermissions, confirmed: true)
        try await waitUntil { client.taskSettings[taskID]?.first { $0.role == "permission" }?.elevated == true }
        let selections = await adapter.providerOptionSelections
        XCTAssertEqual(selections[permission.id], ClaudePermissionMode.bypassPermissions)

        let listed = await client.composerCommands(taskID)
        let commands = try XCTUnwrap(listed)
        XCTAssertEqual(commands.map(\.name), ["compact", "clear"])
        XCTAssertNil(commands.first?.runs)
        let compacted = await client.runComposerCommand(taskID, name: "compact", arguments: "Keep the API notes")
        XCTAssertTrue(compacted, client.commandError ?? "")
        try await waitUntil { await adapter.sentPrompts.contains("/compact Keep the API notes") }
        let refused = await client.response(to: .runComposerCommand(taskID: taskID, command: "clear", arguments: "now"))
        XCTAssertEqual(refused.error?.code, .notAllowed)
        try await host.store.updateSession(id: session.id, status: .ready)

        let shownOnHost = host.store.selectedSessionID
        let cleared = await client.runComposerCommand(taskID, name: "clear", arguments: nil)
        XCTAssertTrue(cleared)
        guard case let .task(newID) = client.selection else { return XCTFail() }
        XCTAssertNotEqual(newID, taskID)
        XCTAssertNotNil(client.task(newID))
        XCTAssertEqual(host.store.selectedSessionID, shownOnHost)
        await host.shutdown()
    }

    /// The fixture host acts the controls out for phones (§9, §17): a task's settings change and Bypass permissions waits
    /// for its confirmation, a task not connected reads them first, Plan mode comes and goes with its command, and an idle
    /// task's latest message is edited and forked.
    func testTheFixtureHostOffersATasksControls() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Loopback", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let directory = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await directory.pair(link: link.absoluteString)
        defer { directory.close(paired.id) }
        let client = try XCTUnwrap(directory.model(for: paired.id))
        try await waitUntil { client.hasSnapshot && client.taskControls }

        let idle = RemoteFixtureBridge.ID.idle
        client.select(.task(idle))
        let conversation = try XCTUnwrap(client.conversations[idle])
        try await waitUntil { conversation.isLoaded && client.taskSettings[idle] != nil }
        XCTAssertEqual(client.taskSettings[idle]?.compactMap(\.role), ["permission", "model", "effort"])
        let refused = await client.response(to: .setTaskSetting(taskID: idle, setting: "permissionMode", value: "bypassPermissions"))
        XCTAssertEqual(refused.error?.code, .notAllowed)
        client.setTaskSetting(idle, id: "permissionMode", value: "bypassPermissions", confirmed: true)
        try await waitUntil { client.taskSettings[idle]?.first?.elevated == true }

        // The latest turn offers its edit and fork; the edit starts it again with the new words.
        let latest = try XCTUnwrap(conversation.presentation.turns.last)
        XCTAssertEqual(latest.actions.editLatest?.text, "Find the footer links that 404")
        XCTAssertTrue(latest.actions.canFork)
        let edited = await client.editMessage(idle, turnID: latest.id, text: "Find the footer links that 404 on mobile")
        XCTAssertTrue(edited)
        try await waitUntil {
            conversation.presentation.turns.last?.prompt.contains {
                if case let .userMessage(text, _) = $0.kind { text == "Find the footer links that 404 on mobile" } else { false }
            } == true
        }

        // A task not connected yet reads its settings once a menu opens.
        let child = RemoteFixtureBridge.ID.child
        client.select(.task(child))
        try await waitUntil { client.taskSettings[child] != nil }
        XCTAssertEqual(client.taskSettings[child]?.first?.prepare, true)
        await client.readTaskSettings(child, prepare: true)
        XCTAssertNil(client.taskSettings[child]?.first?.prepare)

        // Codex's Plan mode is a command; the indicator comes and goes with it.
        let codex = RemoteFixtureBridge.ID.history
        client.select(.task(codex))
        let codexConversation = try XCTUnwrap(client.conversations[codex])
        try await waitUntil { codexConversation.isLoaded && client.taskSettings[codex] != nil }
        let planned = await client.runComposerCommand(codex, name: "plan-mode", arguments: nil)
        XCTAssertTrue(planned)
        try await waitUntil { client.taskSettings[codex]?.first?.role == "plan" }
        let first = try XCTUnwrap(codexConversation.presentation.turns.first)
        XCTAssertTrue(first.actions.canFork)
        XCTAssertNil(first.actions.editLatest)
        client.fork(codex, turnID: first.id)
        try await waitUntil {
            if case let .task(id) = client.selection { return client.task(id)?.parentTaskId == codex }
            return false
        }
    }

    // MARK: - Support

    /// The client paired with a server in front of `host`, and what closes both.
    private static func connect(to host: AppModel) async throws -> (RemoteHostModel, () -> Void) {
        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let directory = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await directory.pair(link: link.absoluteString)
        let client = try XCTUnwrap(directory.model(for: paired.id))
        return (client, {
            directory.close(paired.id)
            stack.stop()
        })
    }

    /// A finished Codex turn: its request and its answer.
    static func codexTurn(_ index: Int) -> JSONValue {
        .object([
            "id": .string("turn-\(index)"), "status": .string("completed"), "durationMs": .integer(4_000),
            "startedAt": .integer(1_700_000_000 + Int64(index) * 60), "completedAt": .integer(1_700_000_004 + Int64(index) * 60),
            "itemsView": .string("full"), "error": .null,
            "items": .array([
                .object(["id": .string("user-\(index)"), "type": .string("userMessage"),
                         "content": .array([.object(["type": .string("text"), "text": .string("Request \(index)")])])]),
                .object(["id": .string("answer-\(index)"), "type": .string("agentMessage"),
                         "text": .string("Answer \(index)"), "phase": .string("final_answer")])
            ])
        ])
    }
}
