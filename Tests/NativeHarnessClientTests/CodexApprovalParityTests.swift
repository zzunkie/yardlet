import Foundation
import XCTest
@testable import NativeHarnessClient

/// Codex permissions (as the Codex app 26.1027 sends them), MCP tool approvals and stopping (26.1016).
final class CodexApprovalParityTests: XCTestCase {
    // MARK: - Permissions

    func testEachPermissionSendsWhatTheCodexAppSends() {
        // The app's agent modes (its `EX` table): a built-in profile, the policy and who reviews.
        let expected: [(CodexRunLocation, String?, String?, String?)] = [
            (.askForApproval, ":workspace", "on-request", "user"),
            (.approveForMe, ":workspace", "on-request", "guardian_subagent"),
            (.dangerFullAccess, ":danger-full-access", "never", "user"),
            (.readOnly, ":read-only", "on-request", "user"),
            (.custom, nil, nil, nil)
        ]
        let url = URL(filePath: "/tmp/w")
        for (location, profile, policy, reviewer) in expected {
            for request in [
                CodexProtocol.startThread(id: 1, workspaceURL: url, runLocation: location),
                CodexProtocol.resumeThread(id: 2, threadID: "thread", workspaceURL: url, runLocation: location),
                CodexProtocol.startTurn(id: 3, threadID: "thread", prompt: "go", runLocation: location)
            ] {
                XCTAssertEqual(request.params["permissions"]?.stringValue, profile, "\(location) \(request.method)")
                XCTAssertEqual(request.params["approvalPolicy"]?.stringValue, policy, "\(location) \(request.method)")
                XCTAssertEqual(request.params["approvalsReviewer"]?.stringValue, reviewer, "\(location) \(request.method)")
                // A profile cannot be combined with a sandbox; Custom leaves both to config.toml.
                XCTAssertNil(request.params["sandbox"])
                XCTAssertNil(request.params["sandboxPolicy"])
            }
        }
        // A task that chose nothing is Ask for approval, from its thread's start to every turn.
        XCTAssertEqual(CodexProtocol.startTurn(id: 4, threadID: "thread", prompt: "go").params["permissions"]?.stringValue,
                       ":workspace")
    }

    @MainActor
    func testATasksSavedPermissionIsItsLevelAndItsChildsOnCodex() {
        // What earlier versions kept: no value and "automatic" (Default) and Workspace write started their
        // threads in the workspace sandbox asking on request, as Ask for approval does.
        for stored in [nil, "automatic", "workspaceWrite", "nonsense"] {
            XCTAssertEqual(CodexRunLocation.restored(from: [CodexRunLocation.storageKey: stored].compactMapValues { $0 }),
                           .askForApproval, stored ?? "nil")
        }
        XCTAssertEqual(CodexRunLocation.restored(from: [CodexRunLocation.storageKey: "readOnly"]), .readOnly)
        XCTAssertEqual(CodexRunLocation.restored(from: [CodexRunLocation.storageKey: "approveForMe"]), .approveForMe)
        XCTAssertNil(CodexRunLocation.askForApproval.storedValue)
        let saved = [CodexRunLocation.storageKey: CodexRunLocation.dangerFullAccess.rawValue]
        XCTAssertEqual(CodexRunLocation.restored(from: saved), .dangerFullAccess)
        // Approve for me keeps the sandbox: a standard task, which a reviewer answers for as Auto's classifier does.
        XCTAssertEqual(TaskPermissionLevel.level(harness: .codex, options: [CodexRunLocation.storageKey: "approveForMe"]),
                       .standard)
        XCTAssertEqual(CodexRunLocation.approveForMe.freedom, ClaudePermissionMode.freedom(ClaudePermissionMode.auto))

        var session = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/w"),
                                    runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Codex")
        XCTAssertEqual(TaskPermissionLevel.level(of: session), .standard)
        session.providerOptions = saved
        XCTAssertEqual(TaskPermissionLevel.level(of: session), .elevated)

        // A Codex child of a Codex task starts with its permission; another harness does not.
        XCTAssertEqual(AppModel.inheritedOptions(saved, harness: .codex, chosen: [:])[CodexRunLocation.storageKey],
                       CodexRunLocation.dangerFullAccess.rawValue)
    }

    func testTheSavedPermissionGoesIntoTheResumeAndEveryTurn() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/resume": [.object(["thread": .object(["id": .string("thread-full")])])],
            "thread/items/list": [.object(["data": .array([])])],
            "turn/start": [.object(["turn": .object(["id": .string("turn-full")])])]
        ])
        let adapter = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.codex())
        let localID = UUID()
        await adapter.setLaunchOptions([CodexRunLocation.storageKey: "approveForMe"], for: localID)
        let handle = try await adapter.resumeSession(providerSessionID: "thread-full", localSessionID: localID,
                                                     workspaceURL: URL(filePath: "/tmp/w"))
        try await adapter.send("again", to: handle)

        let requests = await transport.requests
        for method in ["thread/resume", "turn/start"] {
            let request = try XCTUnwrap(requests.first { $0.method == method })
            XCTAssertEqual(request.params["permissions"]?.stringValue, ":workspace", method)
            XCTAssertEqual(request.params["approvalPolicy"]?.stringValue, "on-request", method)
            XCTAssertEqual(request.params["approvalsReviewer"]?.stringValue, "guardian_subagent", method)
        }
        await adapter.close(handle)
    }

    @MainActor
    func testChoosingAPermissionKeepsItWithTheTask() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
                             runtimeSelections: RuntimeSelectionStore(defaults: defaults),
                             registry: HarnessRegistry { _, _ in adapter })
        let created = await model.createSession(harness: .codex, workspaceURL: URL(filePath: "/tmp/run-location"),
                                                runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Full access")
        let task = try XCTUnwrap(created)
        await model.selectCodexRunLocation(.dangerFullAccess, for: task)

        let saved = try XCTUnwrap(model.store.sessions.first { $0.id == task.id })
        XCTAssertEqual(saved.providerOptions[CodexRunLocation.storageKey], "dangerFullAccess")
        // What the composer and the session tools read once the in-memory state is gone (a restart).
        XCTAssertEqual(model.composerCodexCapabilities(for: saved).selectedRunLocation, .dangerFullAccess)
        XCTAssertEqual(model.sessionToolPermission(of: saved), .elevated)
        // Ask for approval is kept as no value, as tasks from before kept their Default.
        await model.selectCodexRunLocation(.askForApproval, for: saved)
        XCTAssertNil(model.store.sessions.first { $0.id == task.id }?.providerOptions[CodexRunLocation.storageKey])
        await model.shutdown()
    }

    // MARK: - MCP tool approvals

    private func elicitation(connector: String, persist: JSONValue?, thread: String = "thread",
                             turn: String = "turn") -> CodexServerRequestState {
        var meta: [String: JSONValue] = [
            "codex_approval_kind": .string("mcp_tool_call"),
            "connector_id": .string(connector),
            "tool_name": .string("js"),
            "tool_params": .object(["app": .string("com.naver.Whale")])
        ]
        if let persist { meta["persist"] = persist }
        return CodexServerRequestState(
            id: "s:1", method: "mcpServer/elicitation/request", kind: .mcpElicitation,
            threadID: thread, turnID: turn, itemID: nil,
            params: .object([
                "threadId": .string(thread), "turnId": .string(turn), "serverName": .string("cua_repl"),
                "mode": .string("form"), "message": .string("Allow Computer Use to use \"Whale\"?"),
                "requestedSchema": .object(["type": .string("object"), "properties": .object([:])]),
                "_meta": .object(meta)
            ]),
            resolution: .pending)
    }

    private func results(_ responses: [ConversationRequestResponse]) -> [JSONValue?] {
        responses.map { response in
            guard case let .codex(answer) = response.route else { return nil }
            return answer.result(for: "mcpServer/elicitation/request")
        }
    }

    func testComputerUseAsksOnceForTheConversationOrForGood() {
        let responses = CodexRequestResponseProjection.responses(
            for: elicitation(connector: "computer-use", persist: .array([.string("session"), .string("always")])))
        XCTAssertEqual(responses.map(\.title),
                       [L10n.string("Deny"), L10n.string("Always allow"), L10n.string("Allow this conversation")])
        XCTAssertEqual(responses.map(\.role), [.destructive, .secondary, .primary])
        XCTAssertEqual(results(responses), [
            .object(["action": .string("decline")]),
            .object(["action": .string("accept"), "content": .object([:]),
                     "_meta": .object(["persist": .string("always")])]),
            .object(["action": .string("accept"), "content": .object([:]),
                     "_meta": .object(["persist": .string("session")])])
        ])

        // Without the persistent choice, the conversation is still the main answer.
        let sessionOnly = CodexRequestResponseProjection.responses(
            for: elicitation(connector: "computer-use", persist: .string("session")))
        XCTAssertEqual(sessionOnly.map(\.title), [L10n.string("Deny"), L10n.string("Allow this conversation")])
    }

    func testAnotherToolApprovalAllowsOnceByDefault() {
        let responses = CodexRequestResponseProjection.responses(
            for: elicitation(connector: "github", persist: .array([.string("session")])))
        XCTAssertEqual(responses.map(\.title),
                       [L10n.string("Deny"), L10n.string("Allow this conversation"), L10n.string("Allow once")])
        XCTAssertEqual(responses.map(\.role), [.destructive, .secondary, .primary])
        XCTAssertEqual(results(responses).last, .object(["action": .string("accept"), "content": .object([:])]))

        let noPersist = CodexRequestResponseProjection.responses(for: elicitation(connector: "github", persist: nil))
        XCTAssertEqual(noPersist.map(\.title), [L10n.string("Deny"), L10n.string("Allow once")])
    }

    /// Codex's words name a Yardlet connector's tool; the card also names the account the call acts in,
    /// which a tool its service's accounts share carries only in its input.
    @MainActor
    func testAYardletConnectorApprovalNamesTheAccountTheCallActsIn() {
        ConnectorToolLabels.shared.update([ConnectorRecord(
            name: "Gmail", slug: "gmail", serverURL: URL(string: "https://gmail.googleapis.com/gmail/v1/")!,
            status: .connected, presetID: "gmail", localService: .gmail, account: "person@example.test")])
        defer { ConnectorToolLabels.shared.update([]) }
        func approval(server: String, account: String?) -> CodexServerRequestState {
            var parameters: [String: JSONValue] = ["to": .string("bob@example.com")]
            parameters["account"] = account.map(JSONValue.string)
            return CodexServerRequestState(
                id: "s:3", method: "mcpServer/elicitation/request", kind: .mcpElicitation,
                threadID: "thread", turnID: "turn", itemID: nil,
                params: .object([
                    "threadId": .string("thread"), "turnId": .string("turn"), "serverName": .string(server),
                    "mode": .string("form"), "message": .string("Allow the yardlet MCP server to run tool \"gmail_send_message\"?"),
                    "requestedSchema": .object(["type": .string("object"), "properties": .object([:])]),
                    "_meta": .object(["codex_approval_kind": .string("mcp_tool_call"), "tool_name": .string("gmail_send_message"),
                                      "tool_params": .object(parameters)])
                ]),
                resolution: .pending)
        }
        XCTAssertEqual(CodexRequestResponseProjection.request(approval(server: "yardlet", account: "work@example.test")).detail,
                       L10n.format("Account: %@", "work@example.test"))
        XCTAssertNil(CodexRequestResponseProjection.request(approval(server: "yardlet", account: nil)).detail)
        XCTAssertNil(CodexRequestResponseProjection.request(approval(server: "gmail", account: "work@example.test")).detail,
                     "Another server's tool is its own")
    }

    func testAnElicitationThatIsNotAToolApprovalKeepsItsAnswers() {
        let request = CodexServerRequestState(
            id: "s:2", method: "mcpServer/elicitation/request", kind: .mcpElicitation,
            threadID: "thread", turnID: nil, itemID: nil,
            params: .object(["mode": .string("form"), "message": .string("Pick one"),
                             "requestedSchema": .object(["type": .string("object"), "properties": .object([:])])]),
            resolution: .pending)
        XCTAssertEqual(CodexRequestResponseProjection.responses(for: request).map(\.title),
                       [L10n.string("Decline"), L10n.string("Cancel"), L10n.string("Submit")])
    }

    func testThePersistChoiceReachesCodexThroughTheYHPRoute() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object(["thread": .object(["id": .string("thread-cua")])])]
        ])
        let adapter = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.codex())
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/w"), initialPrompt: nil))
        // The routed presentation is read while something watches it, as the task view does.
        let presentation = try await adapter.presentationStates(for: handle)
        let watcher = Task { for await _ in presentation {} }
        defer { watcher.cancel() }
        let params = try XCTUnwrap(elicitation(connector: "computer-use", persist: .array([.string("session")]),
                                               thread: "thread-cua").params)
        await transport.emitServerRequest(id: .integer(7), method: "mcpServer/elicitation/request", params: params)
        try await waitUntil { (try? await adapter.presentationState(for: handle))?.serverRequestsByID["i:7"] != nil }

        try await adapter.respond(to: "i:7", response: CodexMCPToolApproval.accept("session"), in: handle)
        let sent = await transport.sentResponses.last?.result
        XCTAssertEqual(sent, .object(["action": .string("accept"), "content": .object([:]),
                                      "_meta": .object(["persist": .string("session")])]))
        await adapter.close(handle)
    }

    // MARK: - Stopping

    func testStoppingDeclinesWhatWaitsBeforeTheTurnIsInterrupted() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object(["thread": .object(["id": .string("thread-stop")])])],
            "turn/start": [.object(["turn": .object(["id": .string("turn-stop")])])],
            "turn/interrupt": [.object([:])]
        ])
        let adapter = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.codex())
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/w"), initialPrompt: nil))
        let presentation = try await adapter.presentationStates(for: handle)
        let watcher = Task { for await _ in presentation {} }
        defer { watcher.cancel() }
        try await adapter.send("use Whale", to: handle)
        let params = try XCTUnwrap(elicitation(connector: "computer-use", persist: .array([.string("session")]),
                                               thread: "thread-stop", turn: "turn-stop").params)
        await transport.emitServerRequest(id: .integer(8), method: "mcpServer/elicitation/request", params: params)
        await transport.emitServerRequest(id: .integer(9), method: "item/commandExecution/requestApproval", params: .object([
            "threadId": .string("thread-stop"), "turnId": .string("turn-stop"), "command": .string("open -a Whale")
        ]))
        try await waitUntil {
            let state = try? await adapter.presentationState(for: handle)
            return state?.serverRequestsByID["i:8"] != nil && state?.serverRequestsByID["i:9"] != nil
        }

        await transport.suspendNextRequest("turn/interrupt")
        let stop = Task { try await adapter.interrupt(handle) }
        try await waitUntil { await transport.isRequestSuspended }
        // Both were answered before the interrupt went out.
        let answered = await transport.sentResponses.map(\.result)
        XCTAssertEqual(answered.count, 2)
        XCTAssertTrue(answered.contains(.object(["action": .string("decline")])))
        XCTAssertTrue(answered.contains(.object(["decision": .string("decline")])))
        await transport.releaseSuspendedRequest()
        try await stop.value
        let state = try await adapter.presentationState(for: handle)
        XCTAssertEqual(state.serverRequestsByID["i:8"]?.resolution, .resolved(.object(["action": .string("decline")])))
        XCTAssertEqual(CodexRequestResponseProjection.state(try XCTUnwrap(state.serverRequestsByID["i:9"]).resolution),
                       .denied)
        await adapter.close(handle)
    }

    func testStoppingWithOnlyARequestLeftAnswersItInsteadOfFailing() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object(["thread": .object(["id": .string("thread-idle")])])]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/w"), initialPrompt: nil))
        var params = try XCTUnwrap(elicitation(connector: "computer-use", persist: nil).params?.objectValue)
        params["threadId"] = .string("thread-idle")
        params["turnId"] = .null
        await transport.emitServerRequest(id: .integer(3), method: "mcpServer/elicitation/request", params: .object(params))
        try await waitUntil { (try? await adapter.presentationState(for: handle))?.serverRequestsByID["i:3"] != nil }

        try await adapter.interrupt(handle)
        let answered = await transport.sentResponses.map(\.result)
        XCTAssertEqual(answered, [.object(["action": .string("decline")])])
        let methods = await transport.requestMethods
        XCTAssertFalse(methods.contains("turn/interrupt"))
        await adapter.close(handle)
    }
}
