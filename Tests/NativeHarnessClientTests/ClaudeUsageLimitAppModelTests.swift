import Foundation
import XCTest
@testable import NativeHarnessClient

/// A Claude task stopped by a plan limit, through the app model on the product route: the card,
/// continuing under another account that shares the history, the automatic continue once the
/// limit resets, and the retry and warning lines while the task runs.
@MainActor final class ClaudeUsageLimitAppModelTests: XCTestCase {
    func testContinuingUnderAnotherAccountSwitchesThenAsksClaudeToPickUp() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let created = await model.createSession(harness: .claudeCode, workspaceURL: fixture.shared,
            runtimeExecutableURL: fixture.cli, title: "Limit", connection: fixture.first)
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")
        let providerID = try XCTUnwrap(task.providerSessionID)
        model.composerDrafts.tasks.draft(for: task.id).text = "Keep my draft"

        let transport = try XCTUnwrap(fixture.transports.all.first)
        for frame in limitFrames(resetsAt: Date().addingTimeInterval(3_600)) { await transport.emit(frame) }
        let card = try await waitForLimitCard(in: model, task: task)
        try await waitUntil { model.store.sessions.first?.status == .failed }
        XCTAssertFalse(model.transcriptBySessionID[task.id]?.contains {
            if case .error = $0.content { return true }
            return false
        } ?? true, "The card takes the place of a generic error")

        XCTAssertEqual(Set(model.usageLimitAccounts(for: task)), [fixture.next, fixture.signedOut],
            "Only accounts sharing the history are offered, never the current one")

        // A refused switch leaves the task where it was and says why on the card.
        await model.continueAfterUsageLimit(using: fixture.signedOut, for: task)
        XCTAssertEqual(model.store.sessions.first?.connection, fixture.first)
        XCTAssertEqual(model.usageLimitSwitchErrorBySessionID[task.id], ProviderConnectionError.signedOut.localizedDescription)
        let nothingSent = await transport.sentValues
        XCTAssertTrue(nothingSent.isEmpty)
        XCTAssertEqual(model.transcriptBySessionID[task.id]?.last?.id, card)

        await model.continueAfterUsageLimit(using: fixture.next, for: task)
        XCTAssertNil(model.usageLimitSwitchErrorBySessionID[task.id])

        let switched = try XCTUnwrap(model.store.sessions.first)
        XCTAssertEqual(switched.connection, fixture.next)
        XCTAssertEqual(switched.providerSessionID, providerID)
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: task.id).text, "Keep my draft")
        let resumedTransport = try XCTUnwrap(fixture.transports.all.last)
        XCTAssertFalse(resumedTransport === transport)
        let sent = await resumedTransport.sentValues.compactMap { $0["message"]?["content"]?.stringValue }
        XCTAssertEqual(sent, [UsageLimitContinuation.afterAccountSwitch])
        XCTAssertEqual(model.transcriptBySessionID[task.id]?.last?.content,
            .user(text: UsageLimitContinuation.afterAccountSwitch))
        XCTAssertNotEqual(model.transcriptBySessionID[task.id]?.last?.id, card)
    }

    func testTheAutomaticContinueWaitsForTheResetAndThenAsksClaudeToPickUp() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        model.usageLimitResumeGrace = .zero
        let task = try await limitedTask(in: fixture)
        let transport = try XCTUnwrap(fixture.transports.all.first)
        let card = try await waitForLimitCard(in: model, task: task)

        model.setUsageLimitAutoContinue(true, entryID: card, resetsAt: Date().addingTimeInterval(0.3), for: task)
        XCTAssertEqual(model.usageLimitAutoContinue[task.id]?.entryID, card)
        let early = await transport.sentValues.count
        XCTAssertEqual(early, 0, "Nothing is sent before the reset")
        try await waitUntil {
            await transport.sentValues.contains { $0["message"]?["content"]?.stringValue == UsageLimitContinuation.afterReset }
        }
        XCTAssertNil(model.usageLimitAutoContinue[task.id])
        XCTAssertEqual(model.transcriptBySessionID[task.id]?.last?.content, .user(text: UsageLimitContinuation.afterReset))
    }

    func testTheAutomaticContinueStaysQuietWhenTheTaskChangedMeanwhile() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        model.usageLimitResumeGrace = .zero
        let task = try await limitedTask(in: fixture)
        let transport = try XCTUnwrap(fixture.transports.all.first)
        let card = try await waitForLimitCard(in: model, task: task)

        // Something arrived after the card: the task is no longer where the limit left it.
        model.setUsageLimitAutoContinue(true, entryID: card, resetsAt: Date().addingTimeInterval(0.3), for: task)
        await transport.emit(.object([
            "type": .string("assistant"),
            "message": .object(["content": .array([.object(["type": .string("text"), "text": .string("Late note")])])])
        ]))
        try await waitUntil { model.usageLimitAutoContinue[task.id] == nil }
        try await Task.sleep(for: .milliseconds(200))
        let afterChange = await transport.sentValues
        XCTAssertTrue(afterChange.isEmpty)

        // A message the user sends takes over from an armed continue at once.
        model.setUsageLimitAutoContinue(true, entryID: card, resetsAt: Date().addingTimeInterval(0.3), for: task)
        await model.send(HarnessUserInput(text: "Use the other approach"), to: task)
        XCTAssertNil(model.usageLimitAutoContinue[task.id])
        try await Task.sleep(for: .milliseconds(600))
        let sent = await transport.sentValues.compactMap { $0["message"]?["content"]?.stringValue }
        XCTAssertEqual(sent, ["Use the other approach"])
    }

    func testRetriesWarningsAndReportsFollowTheRunningTask() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        model.connections.publish(HarnessAccountSnapshot(id: fixture.first.id, harness: .claudeCode, providerID: nil,
            state: .signedIn, accountLabel: "first@example.test", detail: "", credentialOwner: "Claude Code",
            checkedAt: Date(), usage: ClaudeUsageProbe.usage([], updatedBy: HarnessRateLimit(
                status: .allowed, window: .session, usedFraction: 0.1)), canLogin: false, canLogout: true), for: fixture.first)
        let created = await model.createSession(harness: .claudeCode, workspaceURL: fixture.shared,
            runtimeExecutableURL: fixture.cli, title: "Retry", connection: fixture.first)
        let task = try XCTUnwrap(created)
        let transport = try XCTUnwrap(fixture.transports.all.first)
        await model.send(HarnessUserInput(text: "Go"), to: task)

        await transport.emit(try json(#"""
        {"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":800,"error_status":529,
          "error":"overloaded","uuid":"r1","session_id":"s"}
        """#))
        try await waitUntil { model.providerRetryBySessionID[task.id] != nil }
        XCTAssertEqual(model.providerRetryBySessionID[task.id], HarnessProviderRetry(attempt: 2, maxRetries: 10, cause: .overloaded))

        await transport.emit(try json(#"""
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":4102444800,
          "rateLimitType":"five_hour","utilization":0.91},"uuid":"w1","session_id":"s"}
        """#))
        try await waitUntil { model.rateLimitWarningBySessionID[task.id] != nil }
        XCTAssertNotNil(model.providerRetryBySessionID[task.id], "A limit report says nothing about the retry")
        XCTAssertEqual(try XCTUnwrap(model.connections.snapshots[fixture.first.id]?.usage.first?.usedFraction),
            0.91, accuracy: 0.0001, "The account list follows the session's own report")

        await transport.emit(try json(#"""
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Back"}}}
        """#))
        try await waitUntil { model.providerRetryBySessionID[task.id] == nil }

        await transport.emit(try json(#"""
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":4102444800,
          "rateLimitType":"five_hour","utilization":0.2},"uuid":"w2","session_id":"s"}
        """#))
        try await waitUntil { model.rateLimitWarningBySessionID[task.id] == nil }

        // A turn a sign-in failure ended has nothing to retry. One its retries could not get past has:
        // Retry sends the Claude app's retry message as the person's and leaves the draft alone.
        model.composerDrafts.tasks.draft(for: task.id).text = "Keep my draft"
        await transport.emit(try json(#"""
        {"type":"result","subtype":"success","is_error":true,"api_error_status":401,"terminal_reason":"api_error",
          "result":"Failed to authenticate. API Error: 401","session_id":"s"}
        """#))
        try await waitUntil { model.store.sessions.first?.status == .failed }
        let beforeRetry = await transport.sentValues.count
        await model.retryTurn("latest", in: task)
        let refused = await transport.sentValues.count
        XCTAssertEqual(refused, beforeRetry)

        await transport.emit(try json(#"""
        {"type":"result","subtype":"success","is_error":true,"api_error_status":529,"terminal_reason":"api_error",
          "result":"API Error: Repeated 529 Overloaded errors","session_id":"s"}
        """#))
        try await waitUntil {
            model.transcriptBySessionID[task.id]?.last?.content == .error(
                message: "API Error: Repeated 529 Overloaded errors", recoverable: true, transient: true)
        }
        await model.retryTurn("latest", in: task)
        let retried = await transport.sentValues.dropFirst(beforeRetry).compactMap { $0["message"]?["content"]?.stringValue }
        XCTAssertEqual(retried, [RestartContinuation.claudeRetry])
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: task.id).text, "Keep my draft")
    }

    func testATaskResumesInTheModeItLastChose() async throws {
        let fixture = try makeFixture(currentPermissionMode: "acceptEdits")
        let model = fixture.model
        let session = try await model.store.createSession(harness: .claudeCode, workspaceURL: fixture.shared,
            runtimeExecutableURL: fixture.cli, title: "Mode", titleOrigin: .manual,
            providerOptions: ["permissionMode": "acceptEdits"], connection: fixture.first)
        await model.resume(session)
        let transport = try XCTUnwrap(fixture.transports.all.first)
        let configuration = await transport.configuration
        XCTAssertEqual(configuration?.permissionMode, "acceptEdits")
        let subtypes = await transport.requestSubtypes
        XCTAssertFalse(subtypes.contains("set_permission_mode"), "The launch already carried the saved mode")
        await model.loadProviderCapabilities(for: session)
        XCTAssertEqual(model.providerCapabilitiesBySessionID[session.id]?.selectors
            .first { $0.id == "permissionMode" }?.currentValue, "acceptEdits")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let model: AppModel
        let shared: URL
        let cli: URL
        let first: ProviderConnection
        let next: ProviderConnection
        let signedOut: ProviderConnection
        let transports: TransportLog
    }

    private final class TransportLog: @unchecked Sendable {
        private let lock = NSLock()
        private var transports: [FakeClaudeTransport] = []
        private let initializeResponse: JSONValue
        init(initializeResponse: JSONValue) { self.initializeResponse = initializeResponse }
        func make() -> FakeClaudeTransport {
            let transport = FakeClaudeTransport(initializeResponse: initializeResponse)
            lock.withLock { transports.append(transport) }
            return transport
        }
        var all: [FakeClaudeTransport] { lock.withLock { transports } }
    }

    private func makeFixture(currentPermissionMode: String? = nil) throws -> Fixture {
        let shared = try directory()
        let projects = shared.appending(path: "projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let first = try account(linkingTo: projects, signedIn: true)
        let next = try account(linkingTo: projects, signedIn: true)
        let signedOut = try account(linkingTo: projects, signedIn: false)
        let separate = try directory()
        try FileManager.default.createDirectory(at: separate.appending(path: "projects"), withIntermediateDirectories: true)
        let cli = shared.appending(path: "claude-fixture")
        try Data("""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo '2.1.291 (Claude Code)'; exit 0; fi
        if [ "$1" = "auth" ] && [ -f "$CLAUDE_CONFIG_DIR/.signed-in" ]; then echo '{"loggedIn":true}'; else echo '{"loggedIn":false}'; fi

        """.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        var initialize: [String: JSONValue] = ["models": .array([])]
        if let currentPermissionMode { initialize["current_permission_mode"] = .string(currentPermissionMode) }
        let transports = TransportLog(initializeResponse: .object(initialize))
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false),
            registry: HarnessRegistry { _, url in
                YHPProviderCompatibilityAdapter(
                    adapter: ClaudeAdapter(executableURL: url, transportFactory: { _ in transports.make() }),
                    manifest: HarnessProtocolCompatibilityManifest.claude()
                )
            }, restoresIndexOnLaunch: false)
        for home in [first, next, signedOut, separate] { try model.connections.save(connection(home)) }
        addTeardownBlock { await model.shutdown() }
        return Fixture(model: model, shared: shared, cli: cli, first: connection(first), next: connection(next),
            signedOut: connection(signedOut), transports: transports)
    }

    private func limitedTask(in fixture: Fixture) async throws -> SessionRecord {
        let created = await fixture.model.createSession(harness: .claudeCode, workspaceURL: fixture.shared,
            runtimeExecutableURL: fixture.cli, title: "Limit", connection: fixture.first)
        _ = try XCTUnwrap(created, fixture.model.errorBySessionID.values.first ?? "Missing task")
        let transport = try XCTUnwrap(fixture.transports.all.first)
        for frame in limitFrames(resetsAt: Date().addingTimeInterval(3_600)) { await transport.emit(frame) }
        try await waitUntil { fixture.model.store.sessions.first?.status == .failed }
        return try XCTUnwrap(fixture.model.store.sessions.first)
    }

    /// The frames Claude Code 2.1.291 writes when a request is refused by the session limit.
    private func limitFrames(resetsAt: Date) -> [JSONValue] {
        let reset = Int64(resetsAt.timeIntervalSince1970)
        let text = "You've hit your session limit · resets 3pm (Asia/Seoul)"
        return [
            .object([
                "type": .string("rate_limit_event"),
                "rate_limit_info": .object([
                    "status": .string("rejected"), "resetsAt": .integer(reset), "rateLimitType": .string("five_hour"),
                    "utilization": .number(1.0), "isUsingOverage": .bool(false), "overageStatus": .string("rejected")
                ]),
                "uuid": .string(UUID().uuidString), "session_id": .string("s")
            ]),
            .object([
                "type": .string("assistant"), "parent_tool_use_id": .null, "error": .string("rate_limit"),
                "message": .object(["role": .string("assistant"), "model": .string("<synthetic>"),
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])])]),
                "uuid": .string(UUID().uuidString), "session_id": .string("s")
            ]),
            .object([
                "type": .string("result"), "subtype": .string("success"), "is_error": .bool(true),
                "result": .string(text), "session_id": .string("s")
            ])
        ]
    }

    private func waitForLimitCard(in model: AppModel, task: SessionRecord) async throws -> UUID {
        var card: UUID?
        try await waitUntil {
            card = model.transcriptBySessionID[task.id]?.last { entry in
                if case .usageLimit = entry.content { return true }
                return false
            }?.id
            return card != nil
        }
        return try XCTUnwrap(card)
    }


    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func account(linkingTo projects: URL, signedIn: Bool) throws -> URL {
        let root = try directory()
        try FileManager.default.createSymbolicLink(at: root.appending(path: "projects"), withDestinationURL: projects)
        if signedIn { try Data().write(to: root.appending(path: ".signed-in")) }
        return root
    }

    private func connection(_ home: URL) -> ProviderConnection {
        ProviderConnection(id: home.lastPathComponent, name: home.lastPathComponent, harness: .claudeCode,
            providerID: nil, homePath: home.path, credentialSelector: nil)
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
