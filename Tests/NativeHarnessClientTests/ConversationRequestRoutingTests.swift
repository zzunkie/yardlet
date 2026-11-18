import Foundation
import XCTest
@testable import NativeHarnessClient

/// Every request kind × every answer the one request card offers → the exact response the provider
/// receives (plan B4, M12a). The Codex answers are the ones the Codex request cards sent; the shared
/// transcript's are the ones its permission card sent. Each answer goes through the card's own route
/// (`ConversationRequest.route(for:input:)`, `ConversationActions.respond(_:_:)`), and the end-to-end
/// cases carry it on to a provider adapter with a fake transport and read the frame it wrote.
@MainActor
final class ConversationRequestRoutingTests: XCTestCase {
    // MARK: - Codex, per kind

    func testEveryCodexKindsAnswersSendWhatTheCodexCardsSent() throws {
        let requested: JSONValue = .object(["fileSystem": .object(["write": .array([.string("/tmp/out")])])])
        let denied = L10n.string("Denied")
        let cases: [(CodexServerRequestKind, String, JSONValue, [(String, ConversationRequestResponse.Role, JSONValue)])] = [
            (.commandExecutionApproval, "item/commandExecution/requestApproval",
             .object(["command": .string("swift test"), "cwd": .string("/tmp/work")]), [
                (L10n.string("Deny"), .destructive, .object(["decision": .string("decline")])),
                (L10n.string("Allow for session"), .secondary, .object(["decision": .string("acceptForSession")])),
                (L10n.string("Allow"), .primary, .object(["decision": .string("accept")]))
             ]),
            (.fileChangeApproval, "item/fileChange/requestApproval", .object(["reason": .string("Edit a file")]), [
                (L10n.string("Deny"), .destructive, .object(["decision": .string("decline")])),
                (L10n.string("Allow for session"), .secondary, .object(["decision": .string("acceptForSession")])),
                (L10n.string("Allow"), .primary, .object(["decision": .string("accept")]))
            ]),
            (.permissionsApproval, "item/permissions/requestApproval", .object(["permissions": requested]), [
                (L10n.string("Deny"), .destructive, .object(["permissions": .object([:]), "scope": .string("turn")])),
                (L10n.string("Allow for session"), .secondary, .object(["permissions": requested, "scope": .string("session")])),
                (L10n.string("Allow"), .primary, .object(["permissions": requested, "scope": .string("turn")]))
            ]),
            (.applyPatchApproval, "applyPatchApproval", .object(["reason": .string("Patch")]), [
                (L10n.string("Deny"), .destructive, .object(["decision": .object(["denied": .object(["rejection": .string(denied)])])])),
                (L10n.string("Allow for session"), .secondary, .object(["decision": .string("approved_for_session")])),
                (L10n.string("Allow"), .primary, .object(["decision": .string("approved")]))
            ]),
            (.execCommandApproval, "execCommandApproval",
             .object(["command": .array([.string("git"), .string("status")])]), [
                (L10n.string("Deny"), .destructive, .object(["decision": .object(["denied": .object(["rejection": .string(denied)])])])),
                (L10n.string("Allow for session"), .secondary, .object(["decision": .string("approved_for_session")])),
                (L10n.string("Allow"), .primary, .object(["decision": .string("approved")]))
             ]),
            // A form without fields submits `{}`; one without a schema is never accepted empty.
            (.mcpElicitation, "mcpServer/elicitation/request", .object([
                "message": .string("Sign in?"),
                "requestedSchema": .object(["type": .string("object"), "properties": .object([:])])]), [
                (L10n.string("Decline"), .destructive, .object(["action": .string("decline")])),
                (L10n.string("Cancel"), .secondary, .object(["action": .string("cancel")])),
                (L10n.string("Submit"), .primary, .object(["action": .string("accept"), "content": .object([:])]))
            ]),
            (.mcpElicitation, "mcpServer/elicitation/request", .object(["message": .string("Sign in?")]), [
                (L10n.string("Decline"), .destructive, .object(["action": .string("decline")])),
                (L10n.string("Cancel"), .secondary, .object(["action": .string("cancel")]))
            ]),
            (.dynamicToolCall, "item/tool/call", .object(["tool": .string("lookup")]), [
                (L10n.string("Deny"), .destructive, .object(["contentItems": .array([]), "success": .bool(false)])),
                (L10n.string("Allow"), .primary, .object(["contentItems": .array([]), "success": .bool(true)]))
            ])
        ]
        for (kind, method, params, expected) in cases {
            let request = CodexRequestResponseProjection.request(serverRequest(kind, method: method, params: params))
            XCTAssertEqual(request.title, kind.cardTitle)
            XCTAssertEqual(request.state, .pending)
            XCTAssertNil(request.unanswerableReason, "\(kind)")
            XCTAssertEqual(request.responses.map(\.title), expected.map(\.0), "\(kind)")
            XCTAssertEqual(request.responses.map(\.role), expected.map(\.1), "\(kind)")
            for (response, answer) in zip(request.responses, expected) {
                guard case let .codex(sent)? = request.route(for: response, input: ConversationRequestFormInput()) else {
                    XCTFail("\(kind) \(response.title) does not answer Codex")
                    continue
                }
                XCTAssertEqual(sent.result(for: method), answer.2, "\(kind) \(response.title)")
            }
        }
        // The command a request would run reads as Codex sent it, an older review's argument list joined.
        XCTAssertEqual(CodexRequestResponseProjection.request(serverRequest(
            .commandExecutionApproval, method: "item/commandExecution/requestApproval",
            params: .object(["command": .string("swift test")])
        )).command, "swift test")
        XCTAssertEqual(CodexRequestResponseProjection.request(serverRequest(
            .execCommandApproval, method: "execCommandApproval", params: .object(["command": .array([.string("git"), .string("status")])])
        )).command, "git status")
    }

    func testCodexFreeTextQuestionsAnswerEveryQuestionUnderItsID() throws {
        let method = "item/tool/requestUserInput"
        let request = CodexRequestResponseProjection.request(serverRequest(.toolUserInput, method: method, params: .object([
            "questions": .array([
                .object(["id": .string("branch"), "question": .string("Which branch?")]),
                .object(["id": .string("why"), "text": .string("Why?")])
            ])
        ])))
        XCTAssertEqual(request.form, .freeText([
            ConversationRequestQuestion(id: "branch", text: "Which branch?"),
            ConversationRequestQuestion(id: "why", text: "Why?")
        ]))
        let send = try XCTUnwrap(request.responses.first)
        XCTAssertEqual(request.responses.map(\.title), [L10n.string("Send answer")])
        XCTAssertEqual(send.role, .primary)
        // Nothing goes back until every question has an answer.
        XCTAssertNil(request.route(for: send, input: ConversationRequestFormInput()))
        XCTAssertNil(request.route(for: send, input: ConversationRequestFormInput(text: ["branch": "main", "why": "  "])))
        guard case let .codex(answer)? = request.route(
            for: send, input: ConversationRequestFormInput(text: ["branch": "main", "why": "release"])
        ) else { return XCTFail("the answer does not go to Codex") }
        XCTAssertEqual(answer.result(for: method), .object(["answers": .object([
            "branch": .object(["answers": .array([.string("main")])]),
            "why": .object(["answers": .array([.string("release")])])
        ])]))

        // A question without text reads as Codex asking; a request without questions is one answer.
        XCTAssertEqual(CodexRequestResponseProjection.questions(.object(["questions": .array([.object(["id": .string("q")])])])),
                       [ConversationRequestQuestion(id: "q", text: L10n.string("Codex requests an answer"))])
        let bare = CodexRequestResponseProjection.request(serverRequest(.toolUserInput, method: method, params: nil))
        guard case let .codex(unnamed)? = bare.route(
            for: try XCTUnwrap(bare.responses.first), input: ConversationRequestFormInput(text: ["answer": "yes"])
        ) else { return XCTFail("the unnamed answer does not go to Codex") }
        XCTAssertEqual(unnamed, .toolUserInput(answers: ["answer": ["yes"]]))
    }

    func testCodexKindsYardletDoesNotAnswerFailClosedInTheCardsWords() {
        for kind in [CodexServerRequestKind.authenticationRefresh, .attestation, .currentTime, .unknown("future/request")] {
            let request = CodexRequestResponseProjection.request(serverRequest(kind, method: kind.wireName, params: nil))
            XCTAssertTrue(request.responses.isEmpty, "\(kind)")
            XCTAssertEqual(request.unanswerableReason, L10n.string("This Codex request needs a structured response."))
            XCTAssertTrue(request.offeredResponses(canChooseOption: true, canAnswer: true).isEmpty)
        }
    }

    func testCodexApprovalsAndAnsweredRequestsReadAsTheirAnswer() {
        let approval = CodexRequestResponseProjection.request(CodexApprovalState(
            id: "approval", method: "item/commandExecution/requestApproval", threadID: "thread", turnID: "turn",
            itemID: "item", resolution: .pending, raw: .object(["command": .string("rm -rf .build")])
        ))
        XCTAssertEqual(approval.responses.map(\.route), [.decision(.deny), .decision(.allow)])
        XCTAssertEqual(approval.command, "rm -rf .build")

        let states: [(JSONValue?, ConversationRequestState)] = [
            (.object(["decision": .string("accept")]), .allowed),
            (.object(["decision": .string("acceptForSession")]), .allowed),
            (.object(["decision": .string("approved_for_session")]), .allowed),
            (.object(["decision": .string("decline")]), .denied),
            (.object(["decision": .string("cancel")]), .denied),
            (.object(["decision": .object(["denied": .object(["rejection": .string("No")])])]), .denied),
            (.object(["decision": .object(["acceptWithExecpolicyAmendment": .object([:])])]), .allowed),
            (.object(["permissions": .object(["network": .bool(true)]), "scope": .string("turn")]), .allowed),
            (.object(["permissions": .object([:]), "scope": .string("turn")]), .denied),
            (.object(["contentItems": .array([]), "success": .bool(false)]), .denied),
            (.object(["answers": .object([:])]), .answered),
            (.object(["action": .string("accept")]), .answered),
            (nil, .answered)
        ]
        for (response, state) in states {
            XCTAssertEqual(CodexRequestResponseProjection.state(.resolved(response)), state, "\(String(describing: response))")
        }
        XCTAssertEqual(CodexRequestResponseProjection.state(.rejected(code: CodexPendingServerRequest.expiredRuntimeCode, message: "Gone")),
                       .expired(message: "Gone"))
        XCTAssertEqual(CodexRequestResponseProjection.state(.rejected(code: -1, message: "No")), .rejected(message: "No"))
        // An answered request offers nothing more.
        var answered = serverRequest(.commandExecutionApproval, method: "item/commandExecution/requestApproval", params: nil)
        answered.resolution = .resolved(.object(["decision": .string("accept")]))
        XCTAssertTrue(CodexRequestResponseProjection.request(answered).responses.isEmpty)
    }

    // MARK: - The shared transcript's answers

    func testTranscriptRequestsOfferWhatTheHostCanCarryBack() throws {
        let options = [
            PermissionRequestAction(id: "allow-once", label: "Allow once", decision: .allow, kind: "allow_once"),
            PermissionRequestAction(id: "allow-always", label: "Always allow", decision: .allow, kind: "allow_always"),
            PermissionRequestAction(id: "reject-once", label: "Reject", decision: .deny, kind: "reject_once")
        ]
        let withOptions = try transcriptRequest(PermissionRequest(
            id: "options", title: "Run", detail: nil, command: "swift test", actions: options
        ))
        XCTAssertEqual(withOptions.command, "swift test")
        // The denial first and the narrowest allow last, as both apps end the row with "Allow once".
        XCTAssertEqual(withOptions.responses.map(\.title), ["Reject", "Always allow", "Allow once"])
        XCTAssertEqual(withOptions.responses.map(\.role), [.destructive, .secondary, .primary])
        XCTAssertEqual(withOptions.responses.map(\.route), [
            .providerAction(options[2]), .providerAction(options[1]), .providerAction(options[0])
        ])
        // A host that cannot forward the provider's own option offers plain deny and allow.
        XCTAssertEqual(withOptions.offeredResponses(canChooseOption: false, canAnswer: true).map(\.route),
                       [.decision(.deny), .decision(.allow)])

        let question = PermissionQuestion(
            question: "Which tests?", header: "Tests",
            options: [.init(label: "Only calc"), .init(label: "Lint"), .init(label: "All")],
            allowsMultipleSelections: true
        )
        let questions = try transcriptRequest(PermissionRequest(
            id: "question", title: "AskUserQuestion", detail: nil, command: nil, structured: .questions([question])
        ))
        let submit = try XCTUnwrap(questions.responses.first)
        XCTAssertEqual(questions.responses.map(\.title), [L10n.string("Submit answers")])
        XCTAssertNil(questions.route(for: submit, input: ConversationRequestFormInput()))
        // Picked options go back in the provider's own option order.
        XCTAssertEqual(questions.route(for: submit, input: ConversationRequestFormInput(selections: ["Which tests?": ["All", "Only calc"]])),
                       .answer(.questions([PermissionQuestionAnswer(question: "Which tests?", selectedLabels: ["Only calc", "All"])])))
        // A host that cannot return the answer keeps plain approval controls rather than dropping it.
        XCTAssertEqual(questions.offeredResponses(canChooseOption: false, canAnswer: false).map(\.route),
                       [.decision(.deny), .decision(.allow)])

        let plan = try transcriptRequest(PermissionRequest(
            id: "plan", title: "ExitPlanMode", detail: nil, command: nil, structured: .plan("## Plan")
        ))
        XCTAssertEqual(plan.responses.map(\.title), [L10n.string("Keep planning"), L10n.string("Approve plan")])
        let keep = plan.responses[0]
        XCTAssertEqual(plan.route(for: keep, input: ConversationRequestFormInput()), .decision(.deny))
        XCTAssertEqual(plan.route(for: keep, input: ConversationRequestFormInput(reason: "  Split step 2 ")),
                       .answer(.denial(reason: "Split step 2")))
        XCTAssertEqual(plan.route(for: plan.responses[1], input: ConversationRequestFormInput()), .decision(.allow))
    }

    func testEveryRouteReachesItsOneAction() {
        let recorder = RouteRecorder()
        let actions = recorder.actions()
        let option = PermissionRequestAction(id: "allow-once", label: "Allow once", decision: .allow, kind: "allow_once")
        actions.respond("a", .decision(.deny))
        actions.respond("b", .providerAction(option))
        actions.respond("c", .answer(.denial(reason: "No")))
        actions.respond("d", .codex(.command(.accept)))
        actions.respond("e", .structured)
        XCTAssertEqual(recorder.calls, [
            .decision("a", .deny), .option("b", option), .answer("c", .denial(reason: "No")), .codex("d", .command(.accept))
        ])
        // Without the provider's option route the option is not guessed at.
        var plain = recorder.actions()
        plain.chooseOption = nil
        plain.respond("f", .providerAction(option))
        XCTAssertEqual(recorder.calls.count, 4)
    }

    // MARK: - End to end: Codex

    func testCodexCardAnswersReachTheRuntimeAsTheCodexCardsDid() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object(["thread": .object(["id": .string("thread-routing")])])]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil
        ))
        func params(_ extra: [String: JSONValue]) -> JSONValue {
            .object(["threadId": .string("thread-routing"), "turnId": .string("turn-1"), "itemId": .string("item-1")]
                .merging(extra) { _, new in new })
        }
        // Every answer of a command approval, each on its own request.
        let commandMethod = "item/commandExecution/requestApproval"
        for (index, title) in [L10n.string("Deny"), L10n.string("Allow for session"), L10n.string("Allow")].enumerated() {
            let id = "command-\(index)"
            await transport.emitServerRequest(id: .string(id), method: commandMethod,
                                              params: params(["command": .string("git status")]))
            let request = try await codexRequest("s:\(id)", in: adapter, handle: handle)
            let response = try XCTUnwrap(request.responses.first { $0.title == title })
            try await send(try XCTUnwrap(request.route(for: response, input: ConversationRequestFormInput())),
                           for: request.id, codex: adapter, handle: handle)
            let sent = await transport.sentResponses.last
            XCTAssertEqual(sent?.id, .string(id))
            let expected = ["decline", "acceptForSession", "accept"][index]
            XCTAssertEqual(sent?.result, .object(["decision": .string(expected)]), title)
        }
        // A free-text question.
        await transport.emitServerRequest(id: .string("input-1"), method: "item/tool/requestUserInput", params: params([
            "questions": .array([.object(["id": .string("q1"), "question": .string("Which branch?")])])
        ]))
        let question = try await codexRequest("s:input-1", in: adapter, handle: handle)
        let route = try XCTUnwrap(question.route(
            for: try XCTUnwrap(question.responses.first), input: ConversationRequestFormInput(text: ["q1": "main"])
        ))
        try await send(route, for: question.id, codex: adapter, handle: handle)
        let answered = await transport.sentResponses.last
        XCTAssertEqual(answered?.id, .string("input-1"))
        XCTAssertEqual(answered?.result, .object(["answers": .object(["q1": .object(["answers": .array([.string("main")])])])]))
        // An approval answered through the permission control (a thread's approval without a server
        // request card) sends the same decision.
        await transport.emitServerRequest(id: .string("decision-1"), method: commandMethod, params: params([:]))
        _ = try await codexRequest("s:decision-1", in: adapter, handle: handle)
        try await send(.decision(.allow), for: "s:decision-1", codex: adapter, handle: handle)
        let decided = await transport.sentResponses.last
        XCTAssertEqual(decided?.result, .object(["decision": .string("accept")]))
        await adapter.close(handle)
    }

    // MARK: - End to end: Claude Code

    func testClaudeCardAnswersReachTheCLIAsPermissionCardDid() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil
        ))
        let recorder = PermissionRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                if case let .permissionRequested(request) = event.payload { await recorder.append(request) }
            }
        }
        defer { collector.cancel() }
        let rule: JSONValue = .object([
            "type": .string("addRules"),
            "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("npm run test:*")])]),
            "behavior": .string("allow"),
            "destination": .string("localSettings")
        ])
        let bash: JSONValue = .object(["command": .string("npm run test:unit")])

        // The provider's own options: deny, allow once, and the lasting choice it suggested.
        let expectations: [(String, String, JSONValue?)] = [
            ("deny", "deny", nil), ("allow", "allow", nil), ("allow_always", "allow", .array([rule]))
        ]
        for (index, (actionID, behavior, permissions)) in expectations.enumerated() {
            let id = "bash-\(index)"
            await transport.emit(canUseTool(id, tool: "Bash", input: bash, suggestions: [rule]))
            let request = try await transcriptRequest(try await recorder.wait(for: id))
            let response = try XCTUnwrap(request.responses.first {
                if case let .providerAction(action) = $0.route { return action.id == actionID }
                return false
            })
            try await send(try XCTUnwrap(request.route(for: response, input: ConversationRequestFormInput())),
                           for: id, claude: adapter, handle: handle)
            let sent = try await lastClaudeResponse(transport)
            XCTAssertEqual(sent["behavior"]?.stringValue, behavior, actionID)
            XCTAssertEqual(sent["updatedPermissions"], permissions, actionID)
            if behavior == "allow" { XCTAssertEqual(sent["updatedInput"], bash) }
        }

        // A question form returns the picked options beside the provider's own input.
        let questionInput: JSONValue = .object(["questions": .array([.object([
            "question": .string("Which library?"), "header": .string("Library"), "multiSelect": .bool(false),
            "options": .array([.object(["label": .string("date-fns")]), .object(["label": .string("Luxon")])])
        ])])])
        await transport.emit(canUseTool("question-1", tool: "AskUserQuestion", input: questionInput, suggestions: nil))
        let question = try await transcriptRequest(try await recorder.wait(for: "question-1"))
        let picked = try XCTUnwrap(question.route(
            for: try XCTUnwrap(question.responses.first),
            input: ConversationRequestFormInput(selections: ["Which library?": ["Luxon"]])
        ))
        try await send(picked, for: "question-1", claude: adapter, handle: handle)
        let answered = try await lastClaudeResponse(transport)
        XCTAssertEqual(answered["behavior"]?.stringValue, "allow")
        XCTAssertEqual(answered["updatedInput"]?["answers"]?["Which library?"], .string("Luxon"))

        // A plan review: keep planning with the reason, keep planning without one, approve.
        let planInput: JSONValue = .object(["plan": .string("## Steps\n1. Fix it")])
        let plans: [(String, String, String?, JSONValue?)] = [
            ("plan-1", "Split step 1", "Split step 1", nil),
            ("plan-2", "", "User denied this action", nil),
            ("plan-3", "", nil, planInput)
        ]
        for (index, (id, reason, message, updatedInput)) in plans.enumerated() {
            await transport.emit(canUseTool(id, tool: "ExitPlanMode", input: planInput, suggestions: nil))
            let plan = try await transcriptRequest(try await recorder.wait(for: id))
            let response = plan.responses[index == 2 ? 1 : 0]
            try await send(try XCTUnwrap(plan.route(for: response, input: ConversationRequestFormInput(reason: reason))),
                           for: id, claude: adapter, handle: handle)
            let sent = try await lastClaudeResponse(transport)
            XCTAssertEqual(sent["behavior"]?.stringValue, index == 2 ? "allow" : "deny", id)
            XCTAssertEqual(sent["message"]?.stringValue, message, id)
            if let updatedInput { XCTAssertEqual(sent["updatedInput"], updatedInput, id) }
        }
        await adapter.close(handle)
    }

    // MARK: - Helpers

    private func serverRequest(_ kind: CodexServerRequestKind, method: String, params: JSONValue?) -> CodexServerRequestState {
        CodexServerRequestState(id: "request-1", method: method, kind: kind, threadID: "thread", turnID: "turn-1",
                                itemID: "item-1", params: params, resolution: .pending)
    }

    /// `request` as a waiting entry of a shared transcript, projected.
    private func transcriptRequest(_ request: PermissionRequest) throws -> ConversationRequest {
        let presentation = TranscriptConversationProjection.presentation(
            from: [TranscriptEntry(content: .user(text: "Go")), TranscriptEntry(content: .permission(request, state: .pending))],
            harness: .claudeCode, status: .waitingForApproval, latestTurnIsComplete: false
        )
        return try XCTUnwrap(presentation.turns.last?.requests.first)
    }

    private func codexRequest(_ id: String, in adapter: CodexAdapter, handle: HarnessSessionHandle) async throws
        -> ConversationRequest {
        for _ in 0..<100 {
            if let request = try await adapter.presentationState(for: handle).serverRequestsByID[id] {
                return CodexRequestResponseProjection.request(request)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("the request \(id) did not arrive")
        throw HarnessAdapterError.invalidProviderEvent("no request")
    }

    /// The answer through the conversation's actions, then on to the adapter as the window's actions
    /// carry each one (`MainWindow.conversationActions` → `AppModel.respond…`).
    private func send(_ route: ConversationRequestRoute, for id: String, codex adapter: CodexAdapter,
                      handle: HarnessSessionHandle) async throws {
        let recorder = RouteRecorder()
        recorder.actions().respond(id, route)
        switch recorder.calls.last {
        case let .codex(requestID, response)?:
            try await adapter.respond(to: requestID, response: response, in: handle)
        case let .decision(requestID, decision)?:
            try await adapter.respond(to: requestID, decision: decision, in: handle)
        default:
            XCTFail("\(route) did not reach a Codex action")
        }
    }

    private func send(_ route: ConversationRequestRoute, for id: String, claude adapter: ClaudeAdapter,
                      handle: HarnessSessionHandle) async throws {
        let recorder = RouteRecorder()
        recorder.actions().respond(id, route)
        switch recorder.calls.last {
        case let .decision(requestID, decision)?:
            try await adapter.respond(to: requestID, decision: decision, in: handle)
        case let .option(requestID, action)?:
            try await adapter.respond(to: requestID, selectedActionID: action.id, in: handle)
        case let .answer(requestID, answer)?:
            try await adapter.respond(to: requestID, answer: answer, in: handle)
        default:
            XCTFail("\(route) did not reach a Claude action")
        }
    }

    /// The permission answer the CLI was last sent.
    private func lastClaudeResponse(_ transport: FakeClaudeTransport) async throws -> JSONValue {
        let values = await transport.sentValues
        return try XCTUnwrap(values.last?["response"]?["response"])
    }

    private func canUseTool(_ id: String, tool: String, input: JSONValue, suggestions: [JSONValue]?) -> JSONValue {
        var request: [String: JSONValue] = [
            "subtype": .string("can_use_tool"), "tool_name": .string(tool), "input": input,
            "tool_use_id": .string("toolu-\(id)")
        ]
        if let suggestions { request["permission_suggestions"] = .array(suggestions) }
        return .object(["type": .string("control_request"), "request_id": .string(id), "request": .object(request)])
    }
}

/// Which of the conversation's actions an answer reached.
@MainActor
final class RouteRecorder {
    enum Call: Equatable {
        case decision(String, PermissionDecision)
        case option(String, PermissionRequestAction)
        case answer(String, PermissionStructuredAnswer)
        case codex(String, CodexServerRequestResponse)
    }

    private(set) var calls: [Call] = []

    func actions() -> ConversationActions {
        ConversationActions(
            decide: { [unowned self] in calls.append(.decision($0, $1)) },
            chooseOption: { [unowned self] in calls.append(.option($0, $1)) },
            answer: { [unowned self] in calls.append(.answer($0, $1)) },
            respondToCodexRequest: { [unowned self] in calls.append(.codex($0, $1)) }
        )
    }
}

private actor PermissionRecorder {
    private var requests: [PermissionRequest] = []

    func append(_ request: PermissionRequest) { requests.append(request) }

    func wait(for id: String) async throws -> PermissionRequest {
        let deadline = ContinuousClock.now + testWaitLimit
        while ContinuousClock.now < deadline {
            if let request = requests.last(where: { $0.id == id }) { return request }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HarnessAdapterError.invalidProviderEvent("no permission request \(id)")
    }
}
