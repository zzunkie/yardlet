import Foundation
import XCTest
@testable import NativeHarnessClient

/// Claude Code offers "don't ask again" as `permission_suggestions` on its `can_use_tool` request
/// and applies that choice when the allow answer returns them as `updatedPermissions`. These cover
/// reading the offer, naming where it is kept, the answer's wire shape, the card's choices, and the
/// YHP route the app ships. The suggestion shapes are the ones Claude Code 2.1.281 builds.
final class ClaudePermissionSuggestionTests: XCTestCase {
    private let bashPrefixRule: JSONValue = .object([
        "type": .string("addRules"),
        "rules": .array([.object([
            "toolName": .string("Bash"),
            "ruleContent": .string("npm run test:*")
        ])]),
        "behavior": .string("allow"),
        "destination": .string("localSettings")
    ])

    private let acceptEditsForSession: JSONValue = .object([
        "type": .string("setMode"),
        "mode": .string("acceptEdits"),
        "destination": .string("session")
    ])

    private let outsideReadForSession: JSONValue = .object([
        "type": .string("addRules"),
        "rules": .array([.object([
            "toolName": .string("Read"),
            "ruleContent": .string("//tmp/outside/**")
        ])]),
        "behavior": .string("allow"),
        "destination": .string("session")
    ])

    private let outsideDirectoryForSession: JSONValue = .object([
        "type": .string("addDirectories"),
        "directories": .array([.string("/tmp/outside")]),
        "destination": .string("session")
    ])

    // MARK: - Reading the offer

    func testSessionOnlySuggestionsAreOfferedForTheSession() throws {
        let offer = try XCTUnwrap(ClaudePermissionSuggestions.offer(from: request(
            suggestions: [outsideReadForSession, outsideDirectoryForSession]
        )))
        XCTAssertEqual(offer.action.id, "allow_session")
        XCTAssertEqual(offer.action.kind, "allow_session")
        XCTAssertEqual(offer.action.decision, .allow)
        XCTAssertEqual(offer.action.label, L10n.string("Allow for session"))
        // The CLI's list comes back exactly as it was sent.
        XCTAssertEqual(offer.updates, [outsideReadForSession, outsideDirectoryForSession])
    }

    func testASessionModeSwitchSaysWhichModeItSwitchesTo() throws {
        let offer = try XCTUnwrap(ClaudePermissionSuggestions.offer(from: request(
            suggestions: [acceptEditsForSession, outsideDirectoryForSession]
        )))
        XCTAssertEqual(offer.action.id, "allow_session")
        XCTAssertEqual(
            offer.action.label,
            L10n.format(
                "Allow and switch to %@ mode for this session",
                L10n.string("Accept edits")
            )
        )
    }

    func testASuggestionKeptInASettingsFileNamesThatFile() throws {
        let local = try XCTUnwrap(ClaudePermissionSuggestions.offer(from: request(
            suggestions: [bashPrefixRule, outsideDirectoryForSession]
        )))
        XCTAssertEqual(local.action.id, "allow_always")
        XCTAssertEqual(local.action.kind, "allow_always")
        XCTAssertEqual(
            local.action.label,
            L10n.format("Always allow in this project (saved to %@)", ".claude/settings.local.json")
        )
        XCTAssertEqual(local.updates, [bashPrefixRule, outsideDirectoryForSession])

        // A tool allowed only for a while (a browser tool that acts in a page) keeps the same rules for the session.
        let forSession = try XCTUnwrap(ClaudePermissionSuggestions.sessionOffer(from: request(
            suggestions: [bashPrefixRule, outsideDirectoryForSession]
        )))
        XCTAssertEqual(forSession.action.id, "allow_session")
        XCTAssertEqual(forSession.updates.compactMap { $0["destination"]?.stringValue }, ["session", "session"])

        let everywhere = try XCTUnwrap(ClaudePermissionSuggestions.offer(from: request(
            suggestions: [rule(destination: "localSettings"), rule(destination: "userSettings")]
        )))
        XCTAssertEqual(
            everywhere.action.label,
            L10n.format(
                "Always allow in every project (saved to %@)",
                ".claude/settings.local.json, " + L10n.string("Claude Code user settings")
            )
        )

        let shared = try XCTUnwrap(ClaudePermissionSuggestions.offer(from: request(
            suggestions: [rule(destination: "projectSettings")]
        )))
        XCTAssertEqual(
            shared.action.label,
            L10n.format(
                "Always allow in this project (saved to %@)",
                L10n.string("shared .claude/settings.json")
            )
        )
    }

    func testNoOfferWhereTheChoiceCannotBeNamedOrMustNotBeShown() {
        // Nothing to offer.
        XCTAssertNil(ClaudePermissionSuggestions.offer(from: request(suggestions: nil)))
        XCTAssertNil(ClaudePermissionSuggestions.offer(from: request(suggestions: [])))
        // The CLI asks hosts to omit the persistent choice for this ask.
        XCTAssertNil(ClaudePermissionSuggestions.offer(from: request(
            suggestions: [bashPrefixRule],
            extra: ["suppress_always_allow_rule": .bool(true)]
        )))
        // A safety check requires manual approval; the native dialog narrows the list itself.
        XCTAssertNil(ClaudePermissionSuggestions.offer(from: request(
            suggestions: [bashPrefixRule],
            extra: ["classifier_approvable": .bool(false)]
        )))
        // A destination this client cannot name.
        XCTAssertNil(ClaudePermissionSuggestions.offer(from: request(
            suggestions: [rule(destination: "policySettings")]
        )))
        // The bypass is chosen only in the selector, which asks first; a suggestion would not.
        XCTAssertNil(ClaudePermissionSuggestions.offer(from: request(suggestions: [.object([
            "type": .string("setMode"),
            "mode": .string("bypassPermissions"),
            "destination": .string("session")
        ])])))
        // A mode written to a settings file would change every later session's default.
        XCTAssertNil(ClaudePermissionSuggestions.offer(from: request(suggestions: [.object([
            "type": .string("setMode"),
            "mode": .string("acceptEdits"),
            "destination": .string("localSettings")
        ])])))
        // A file rule and a session mode switch are two scopes one label cannot name.
        XCTAssertNil(ClaudePermissionSuggestions.offer(from: request(
            suggestions: [bashPrefixRule, acceptEditsForSession]
        )))
        // Replacing or removing rules, or adding a deny rule, is not an allow.
        XCTAssertNil(ClaudePermissionSuggestions.offer(from: request(suggestions: [.object([
            "type": .string("replaceRules"),
            "rules": .array([.object(["toolName": .string("Bash")])]),
            "behavior": .string("allow"),
            "destination": .string("localSettings")
        ])])))
        XCTAssertNil(ClaudePermissionSuggestions.offer(from: request(suggestions: [.object([
            "type": .string("addRules"),
            "rules": .array([.object(["toolName": .string("Bash")])]),
            "behavior": .string("deny"),
            "destination": .string("session")
        ])])))
    }

    // MARK: - The shape the answer goes back in

    func testTheSuggestionsReturnAsUpdatedPermissionsBesideTheOriginalInput() throws {
        let input: JSONValue = .object(["command": .string("npm run test:unit")])
        let applied = ClaudeProtocol.permissionResponse(
            requestID: "permission-1",
            decision: .allow,
            originalInput: input,
            updatedPermissions: [bashPrefixRule]
        )
        XCTAssertEqual(applied["type"]?.stringValue, "control_response")
        XCTAssertEqual(applied["response"]?["request_id"]?.stringValue, "permission-1")
        let payload = try XCTUnwrap(applied["response"]?["response"])
        XCTAssertEqual(payload.objectValue?.keys.sorted(), ["behavior", "updatedInput", "updatedPermissions"])
        XCTAssertEqual(payload["behavior"]?.stringValue, "allow")
        XCTAssertEqual(payload["updatedInput"], input)
        XCTAssertEqual(payload["updatedPermissions"], .array([bashPrefixRule]))

        // A plain allow carries no permission update at all.
        let once = ClaudeProtocol.permissionResponse(
            requestID: "permission-2",
            decision: .allow,
            originalInput: input
        )
        XCTAssertEqual(
            once["response"]?["response"]?.objectValue?.keys.sorted(),
            ["behavior", "updatedInput"]
        )
    }

    // MARK: - The card's choices

    func testTheCardOffersAllowOnceTheSuggestionAndDenyAndAllowStaysOnce() throws {
        let offer = try XCTUnwrap(ClaudePermissionSuggestions.offer(from: request(
            suggestions: [bashPrefixRule]
        )))
        let actions = ClaudePermissionSuggestions.actions(for: offer)
        XCTAssertEqual(actions.map(\.id), ["allow", "allow_always", "deny"])
        XCTAssertEqual(actions.map(\.decision), [.allow, .allow, .deny])
        XCTAssertEqual(actions.map(\.label).first, L10n.string("Allow"))
        XCTAssertEqual(actions.map(\.label).last, L10n.string("Deny"))
        // The card's prominent button and every plain allow resolve to the one-time choice, never
        // to the one that outlasts the call, whichever order the choices are listed in.
        for ordering in [actions, actions.reversed()] {
            XCTAssertEqual(
                PermissionActionPreference.preferred(from: ordering, decision: .allow)?.id,
                "allow"
            )
            XCTAssertEqual(
                PermissionActionPreference.preferred(from: ordering, decision: .deny)?.id,
                "deny"
            )
        }
        let session = try XCTUnwrap(ClaudePermissionSuggestions.offer(from: request(
            suggestions: [acceptEditsForSession]
        )))
        XCTAssertEqual(
            PermissionActionPreference.preferred(
                from: ClaudePermissionSuggestions.actions(for: session),
                decision: .allow
            )?.id,
            "allow"
        )
    }

    // MARK: - Adapter

    func testTheAdapterOffersTheChoiceAndAppliesTheCLIsOwnSuggestions() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { _ in transport }
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let recorder = SuggestionEventRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        defer { collector.cancel() }

        let input: JSONValue = .object(["command": .string("npm run test:unit")])
        await transport.emit(canUseTool(
            requestID: "bash-1",
            toolName: "Bash",
            input: input,
            suggestions: [bashPrefixRule]
        ))
        let request = try await waitForPermission(in: recorder, id: "bash-1")
        XCTAssertEqual(request.actions.map(\.id), ["allow", "allow_always", "deny"])
        XCTAssertNil(request.structured)

        try await adapter.respond(to: "bash-1", selectedActionID: "allow_always", in: handle)
        let applied = try await Self.lastResponse(transport)
        XCTAssertEqual(applied["behavior"]?.stringValue, "allow")
        XCTAssertEqual(applied["updatedInput"], input)
        XCTAssertEqual(applied["updatedPermissions"], .array([bashPrefixRule]))

        // Allow once and deny keep their plain answers.
        await transport.emit(canUseTool(
            requestID: "bash-2",
            toolName: "Bash",
            input: input,
            suggestions: [bashPrefixRule]
        ))
        _ = try await waitForPermission(in: recorder, id: "bash-2")
        try await adapter.respond(to: "bash-2", selectedActionID: "allow", in: handle)
        let once = try await Self.lastResponse(transport)
        XCTAssertEqual(once.objectValue?.keys.sorted(), ["behavior", "updatedInput"])

        await transport.emit(canUseTool(
            requestID: "bash-3",
            toolName: "Bash",
            input: input,
            suggestions: [bashPrefixRule]
        ))
        _ = try await waitForPermission(in: recorder, id: "bash-3")
        try await adapter.respond(to: "bash-3", selectedActionID: "deny", in: handle)
        let denied = try await Self.lastResponse(transport)
        XCTAssertEqual(denied["behavior"]?.stringValue, "deny")
        XCTAssertNil(denied["updatedPermissions"])

        // A choice the request never offered is refused rather than guessed at.
        await transport.emit(canUseTool(
            requestID: "bash-4",
            toolName: "Bash",
            input: input,
            suggestions: nil
        ))
        let plain = try await waitForPermission(in: recorder, id: "bash-4")
        XCTAssertTrue(plain.actions.isEmpty)
        do {
            try await adapter.respond(to: "bash-4", selectedActionID: "allow_always", in: handle)
            XCTFail("a request without suggestions accepted a lasting choice")
        } catch let error as HarnessAdapterError {
            guard case .invalidProviderEvent = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        await adapter.close(handle)
    }

    func testQuestionAndPlanCardsNeverCarryTheOffer() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { _ in transport }
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let recorder = SuggestionEventRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        defer { collector.cancel() }

        await transport.emit(canUseTool(
            requestID: "plan-1",
            toolName: "ExitPlanMode",
            input: .object(["plan": .string("## Steps\n1. Edit")]),
            suggestions: [acceptEditsForSession]
        ))
        let plan = try await waitForPermission(in: recorder, id: "plan-1")
        XCTAssertEqual(plan.structured, .plan("## Steps\n1. Edit"))
        XCTAssertTrue(plan.actions.isEmpty)
        try await adapter.respond(to: "plan-1", decision: .allow, in: handle)
        let approved = try await Self.lastResponse(transport)
        XCTAssertNil(approved["updatedPermissions"])

        // A question call whose form could not be read stays a plain approval, still without
        // the offer, because its tool is not one whose approval has a scope to keep.
        await transport.emit(canUseTool(
            requestID: "question-1",
            toolName: "AskUserQuestion",
            input: .object(["questions": .array([])]),
            suggestions: [acceptEditsForSession]
        ))
        let question = try await waitForPermission(in: recorder, id: "question-1")
        XCTAssertNil(question.structured)
        XCTAssertTrue(question.actions.isEmpty)
        await adapter.close(handle)
    }

    // MARK: - The route the app ships

    func testTheChoiceAndItsAnswerCrossTheYHPRouteTheAppShips() async throws {
        let transport = FakeClaudeTransport()
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(
                executableURL: URL(filePath: "/tmp/fake-claude"),
                transportFactory: { _ in transport }
            ),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let handle = try await routed.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let recorder = SuggestionEventRecorder()
        let collector = Task {
            for await event in await routed.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        defer { collector.cancel() }

        let input: JSONValue = .object(["file_path": .string("/tmp/outside/notes.md")])
        let suggestions = [acceptEditsForSession, outsideDirectoryForSession]
        await transport.emit(canUseTool(
            requestID: "edit-yhp",
            toolName: "Edit",
            input: input,
            suggestions: suggestions
        ))
        let request = try await waitForPermission(in: recorder, id: "edit-yhp")
        let offer = try XCTUnwrap(ClaudePermissionSuggestions.offer(from: .object([
            "permission_suggestions": .array(suggestions)
        ])))
        // The choices reach the card exactly as the adapter defined them.
        XCTAssertEqual(request.actions, ClaudePermissionSuggestions.actions(for: offer))

        try await routed.respond(to: "edit-yhp", selectedActionID: "allow_session", in: handle)
        let applied = try await Self.lastResponse(transport)
        XCTAssertEqual(applied["behavior"]?.stringValue, "allow")
        XCTAssertEqual(applied["updatedInput"], input)
        XCTAssertEqual(applied["updatedPermissions"], .array(suggestions))

        // A plain allow over the same route picks the one-time choice and applies nothing.
        await transport.emit(canUseTool(
            requestID: "edit-yhp-2",
            toolName: "Edit",
            input: input,
            suggestions: suggestions
        ))
        _ = try await waitForPermission(in: recorder, id: "edit-yhp-2")
        try await routed.respond(to: "edit-yhp-2", decision: .allow, in: handle)
        let once = try await Self.lastResponse(transport)
        XCTAssertEqual(once["behavior"]?.stringValue, "allow")
        XCTAssertNil(once["updatedPermissions"])

        // A request without suggestions keeps the plain card, and its plain answers still reach
        // the CLI now that the adapter also answers by choice.
        await transport.emit(canUseTool(
            requestID: "bash-yhp",
            toolName: "Bash",
            input: .object(["command": .string("git status")]),
            suggestions: nil
        ))
        let plain = try await waitForPermission(in: recorder, id: "bash-yhp")
        XCTAssertTrue(plain.actions.isEmpty)
        try await routed.respond(to: "bash-yhp", decision: .deny, in: handle)
        let denied = try await Self.lastResponse(transport)
        XCTAssertEqual(denied["behavior"]?.stringValue, "deny")
        XCTAssertEqual(denied["message"]?.stringValue, "User denied this action")
        await routed.close(handle)
    }

    @MainActor
    func testTheCardsChoiceReachesTheCLIThroughTheAppModel() async throws {
        let runtime = try makeVersionFixtureRuntime(output: "2.1.281 (Claude Code)")
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let transport = FakeClaudeTransport()
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(
                executableURL: runtime.executable,
                transportFactory: { _ in transport }
            ),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in routed }
        )
        await model.createSession(
            harness: .claudeCode,
            workspaceURL: URL(filePath: "/tmp/claude-suggestion-card"),
            runtimeExecutableURL: runtime.executable,
            title: "Suggestion card"
        )
        let session = try XCTUnwrap(model.store.selectedSession)

        await transport.emit(canUseTool(
            requestID: "bash-card",
            toolName: "Bash",
            input: .object(["command": .string("npm run test:unit")]),
            suggestions: [bashPrefixRule]
        ))
        var pending: PermissionRequest?
        let deadline = ContinuousClock.now + testWaitLimit
        while pending == nil, ContinuousClock.now < deadline {
            pending = model.transcriptBySessionID[session.id]?.lazy.compactMap { entry in
                guard case let .permission(request, .pending) = entry.content,
                      request.id == "bash-card" else { return nil }
                return request
            }.first
            if pending == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let request = try XCTUnwrap(pending)
        let lasting = try XCTUnwrap(request.actions.first { $0.id == "allow_always" })

        await model.respond(to: request.id, action: lasting, in: session)
        let applied = try await Self.lastResponse(transport)
        XCTAssertEqual(applied["updatedPermissions"], .array([bashPrefixRule]))
        XCTAssertTrue(model.transcriptBySessionID[session.id]?.contains { entry in
            entry.content == .permission(request, state: .allowed)
        } == true)
        await model.shutdown()
    }

    // MARK: - Helpers

    /// The body of the last answer the adapter wrote to the CLI.
    private static func lastResponse(_ transport: FakeClaudeTransport) async throws -> JSONValue {
        let sent = await transport.sentValues
        return try XCTUnwrap(sent.last?["response"]?["response"])
    }

    private func rule(destination: String) -> JSONValue {
        .object([
            "type": .string("addRules"),
            "rules": .array([.object(["toolName": .string("WebSearch")])]),
            "behavior": .string("allow"),
            "destination": .string(destination)
        ])
    }

    private func request(
        suggestions: [JSONValue]?,
        extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var request: [String: JSONValue] = [
            "subtype": .string("can_use_tool"),
            "tool_name": .string("Bash"),
            "input": .object(["command": .string("npm run test:unit")]),
            "tool_use_id": .string("toolu_1")
        ]
        if let suggestions { request["permission_suggestions"] = .array(suggestions) }
        request.merge(extra) { _, new in new }
        return .object(request)
    }

    private func canUseTool(
        requestID: String,
        toolName: String,
        input: JSONValue,
        suggestions: [JSONValue]?
    ) -> JSONValue {
        var request: [String: JSONValue] = [
            "subtype": .string("can_use_tool"),
            "tool_name": .string(toolName),
            "input": input,
            "tool_use_id": .string("toolu-\(requestID)")
        ]
        if let suggestions { request["permission_suggestions"] = .array(suggestions) }
        return .object([
            "type": .string("control_request"),
            "request_id": .string(requestID),
            "request": .object(request)
        ])
    }

    private func waitForPermission(
        in recorder: SuggestionEventRecorder,
        id: String,
        timeout: Duration = testWaitLimit
    ) async throws -> PermissionRequest {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let request = await recorder.permission(id: id) { return request }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("no permission request arrived")
        throw HarnessAdapterError.invalidProviderEvent("no permission request arrived")
    }

    private func makeVersionFixtureRuntime(output: String) throws -> (root: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-claude-suggestion-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "fixture-claude")
        let script = """
        #!/bin/sh
        printf '%s\\n' '\(output)'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        return (root, executable)
    }
}

private actor SuggestionEventRecorder {
    private var payloads: [HarnessEventPayload] = []

    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }

    func permission(id: String) -> PermissionRequest? {
        payloads.compactMap { payload -> PermissionRequest? in
            guard case let .permissionRequested(request) = payload,
                  request.id == id else { return nil }
            return request
        }.last
    }
}
