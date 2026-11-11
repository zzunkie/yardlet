import Foundation
import os
import XCTest
@testable import NativeHarnessClient

final class ClaudeAdapterTests: XCTestCase {
    func testCreateStreamInterruptAndResumeUseProviderSessionIdentity() async throws {
        let createdLocalID = UUID()
        let resumedLocalID = UUID()
        let createdTransport = FakeClaudeTransport()
        let resumedTransport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { localID in
                localID == createdLocalID ? createdTransport : resumedTransport
            }
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: createdLocalID,
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let recorder = ClaudePayloadRecorder()
        let received = expectation(description: "normalized Claude events")
        let collector = Task {
            let stream = await adapter.events(for: handle)
            for await event in stream {
                let count = await recorder.append(event.payload)
                if count == 6 {
                    received.fulfill()
                    break
                }
            }
        }

        try await adapter.send("hello", to: handle)
        await createdTransport.emit(
            .object([
                "type": .string("stream_event"),
                "event": .object([
                    "type": .string("content_block_delta"),
                    "delta": .object([
                        "type": .string("text_delta"),
                        "text": .string("world")
                    ])
                ])
            ])
        )
        await createdTransport.emit(
            .object([
                "type": .string("result"),
                "subtype": .string("success"),
                "is_error": .bool(false),
                "session_id": .string(handle.providerSessionID)
            ])
        )
        await fulfillment(of: [received], timeout: 2)
        collector.cancel()

        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains(.assistantDelta("world")))
        XCTAssertTrue(payloads.contains(.turnCompleted))
        XCTAssertEqual(payloads.last, .sessionStatusChanged(.ready))

        try await adapter.interrupt(handle)
        let resumed = try await adapter.resumeSession(
            providerSessionID: handle.providerSessionID,
            localSessionID: resumedLocalID,
            workspaceURL: URL(filePath: "/tmp/workspace")
        )
        XCTAssertEqual(resumed.providerSessionID, handle.providerSessionID)

        let createdConfiguration = await createdTransport.configuration
        let resumedConfiguration = await resumedTransport.configuration
        XCTAssertEqual(createdConfiguration?.resumesExistingSession, false)
        XCTAssertEqual(resumedConfiguration?.resumesExistingSession, true)
        XCTAssertEqual(resumedConfiguration?.providerSessionID, handle.providerSessionID)
        // The context-usage and MCP status reads after the result run on their own and may land
        // either side of the interrupt.
        let requestSubtypes = await createdTransport.requestSubtypes
        XCTAssertEqual(requestSubtypes.filter { !["get_context_usage", "mcp_status"].contains($0) },
                       ["initialize", "interrupt"])
    }

    func testPermissionRequestWaitsForExplicitDenial() async throws {
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
        let recorder = ClaudePayloadRecorder()
        let received = expectation(description: "Claude permission event")
        let collector = Task {
            let stream = await adapter.events(for: handle)
            for await event in stream {
                let count = await recorder.append(event.payload)
                if count == 4 {
                    received.fulfill()
                    break
                }
            }
        }

        await transport.emit(
            .object([
                "type": .string("control_request"),
                "request_id": .string("permission-1"),
                "request": .object([
                    "subtype": .string("can_use_tool"),
                    "tool_name": .string("Bash"),
                    "input": .object(["command": .string("git status")]),
                    "title": .string("Run command")
                ])
            ])
        )
        await fulfillment(of: [received], timeout: 2)
        collector.cancel()

        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains { payload in
            guard case let .permissionRequested(request) = payload else { return false }
            return request.id == "permission-1" && request.command == "git status"
        })
        XCTAssertEqual(payloads.last, .sessionStatusChanged(.waitingForApproval))

        try await adapter.respond(to: "permission-1", decision: .deny, in: handle)
        let sent = await transport.sentValues
        XCTAssertEqual(sent.last?["response"]?["response"]?["behavior"]?.stringValue, "deny")
    }

    func testErrorResultLeavesSessionFailedInsteadOfReady() async throws {
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
        let recorder = ClaudePayloadRecorder()
        let received = expectation(description: "Claude error result")
        let collector = Task {
            let stream = await adapter.events(for: handle)
            for await event in stream {
                let count = await recorder.append(event.payload)
                if count == 5 {
                    received.fulfill()
                    break
                }
            }
        }

        await transport.emit(
            .object([
                "type": .string("result"),
                "is_error": .bool(true),
                "result": .string("Not logged in")
            ])
        )
        await fulfillment(of: [received], timeout: 2)
        collector.cancel()

        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains(.error(message: "Not logged in", recoverable: true)))
        XCTAssertEqual(payloads.last, .sessionStatusChanged(.failed))
    }

    func testModelAndSafePermissionModeUseClaudeControlRequests() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/project"), initialPrompt: nil
        ))
        let state = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(state.selectors.first { $0.id == "permissionMode" }?.choices.map(\.value), ClaudePermissionMode.selectable)
        _ = try await adapter.setProviderOption(id: "model", value: "opus", in: handle)
        _ = try await adapter.setProviderOption(id: "permissionMode", value: "plan", in: handle)
        let subtypes = await transport.requestSubtypes
        XCTAssertEqual(subtypes, ["initialize", "set_model", "set_permission_mode"])
    }

    func testYHPProductRoutePreservesClaudeControlsPermissionsAndLifecycle() async throws {
        let directTransport = FakeClaudeTransport()
        let routedTransport = FakeClaudeTransport()
        let localSessionID = UUID()
        let providerSessionID = "claude-yhp-product-session"
        let direct = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { _ in directTransport }
        )
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(
                executableURL: URL(filePath: "/tmp/fake-claude"),
                transportFactory: { _ in routedTransport }
            ),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let workspaceURL = URL(filePath: "/tmp/claude-yhp-product")
        let directHandle = try await direct.resumeSession(
            providerSessionID: providerSessionID,
            localSessionID: localSessionID,
            workspaceURL: workspaceURL
        )
        let routedHandle = try await routed.resumeSession(
            providerSessionID: providerSessionID,
            localSessionID: localSessionID,
            workspaceURL: workspaceURL
        )
        XCTAssertEqual(routedHandle, directHandle)

        let directCapabilities = try await direct.providerCapabilities(for: directHandle)
        let routedCapabilities = try await routed.providerCapabilities(for: routedHandle)
        XCTAssertEqual(routedCapabilities, directCapabilities)
        let directUpdated = try await direct.setProviderOption(
            id: "permissionMode",
            value: "plan",
            in: directHandle
        )
        let routedUpdated = try await routed.setProviderOption(
            id: "permissionMode",
            value: "plan",
            in: routedHandle
        )
        XCTAssertEqual(routedUpdated, directUpdated)

        let directRecorder = ClaudeEventRecorder()
        let routedRecorder = ClaudeEventRecorder()
        let directCollector = Task {
            for await event in await direct.events(for: directHandle) {
                await directRecorder.append(event)
            }
        }
        let routedCollector = Task {
            for await event in await routed.events(for: routedHandle) {
                await routedRecorder.append(event)
            }
        }
        try await direct.send("hello", to: directHandle)
        try await routed.send("hello", to: routedHandle)
        let assistant: JSONValue = .object([
            "type": .string("stream_event"),
            "event": .object([
                "type": .string("content_block_delta"),
                "delta": .object([
                    "type": .string("text_delta"),
                    "text": .string("hello")
                ])
            ])
        ])
        let permission: JSONValue = .object([
            "type": .string("control_request"),
            "request_id": .string("permission-yhp"),
            "request": .object([
                "subtype": .string("can_use_tool"),
                "tool_name": .string("Bash"),
                "input": .object(["command": .string("git status")]),
                "title": .string("Run command")
            ])
        ])
        await directTransport.emit(assistant)
        await routedTransport.emit(assistant)
        await directTransport.emit(permission)
        await routedTransport.emit(permission)
        try await waitUntil {
            let directEvents = await directRecorder.events
            let routedEvents = await routedRecorder.events
            return directEvents.contains { event in
                if case .permissionRequested = event.payload { return true }
                return false
            } && routedEvents.contains { event in
                if case .permissionRequested = event.payload { return true }
                return false
            }
        }
        try await direct.respond(
            to: "permission-yhp",
            decision: .deny,
            in: directHandle
        )
        try await routed.respond(
            to: "permission-yhp",
            decision: .deny,
            in: routedHandle
        )
        let success = claudeSuccess(providerSessionID: providerSessionID)
        await directTransport.emit(success)
        await routedTransport.emit(success)
        try await waitUntil {
            let directEvents = await directRecorder.events
            let routedEvents = await routedRecorder.events
            return directEvents.contains { $0.payload == .turnCompleted }
                && routedEvents.contains { $0.payload == .turnCompleted }
        }
        let directEvents = await directRecorder.events
        let routedEvents = await routedRecorder.events
        XCTAssertEqual(routedEvents.map(\.payload), directEvents.map(\.payload))
        XCTAssertEqual(
            routedEvents.map { $0.rawProviderEvent != nil },
            directEvents.map { $0.rawProviderEvent != nil }
        )

        try await direct.send("cancel", to: directHandle)
        try await routed.send("cancel", to: routedHandle)
        try await direct.interrupt(directHandle)
        try await routed.interrupt(routedHandle)
        await directTransport.emit(success)
        await routedTransport.emit(success)
        try await waitUntil {
            let directEvents = await directRecorder.events
            let routedEvents = await routedRecorder.events
            return directEvents.filter { $0.payload == .turnCompleted }.count == 2
                && routedEvents.filter { $0.payload == .turnCompleted }.count == 2
        }
        let directFinal = await directRecorder.events.map(\.payload)
        let routedFinal = await routedRecorder.events.map(\.payload)
        XCTAssertEqual(routedFinal, directFinal)

        await direct.close(directHandle)
        await routed.close(routedHandle)
        directCollector.cancel()
        routedCollector.cancel()
    }

    private func claudeSuccess(providerSessionID: String) -> JSONValue {
        .object([
            "type": .string("result"),
            "subtype": .string("success"),
            "is_error": .bool(false),
            "session_id": .string(providerSessionID)
        ])
    }

    func testRestorationCompatibilityAcceptsMinimumFloorAndReportsVerification() {
        let compatibility = ClaudeRuntimeCompatibility.restorationBaseline
        XCTAssertEqual(compatibility.minimum, "2.1.0")

        // At or above the floor connects, including releases Yardlet has not exercised yet.
        XCTAssertTrue(compatibility.accepts(versionOutput: "2.1.0 (Claude Code)"))
        XCTAssertTrue(compatibility.accepts(versionOutput: "2.1.227 (Claude Code)"))
        XCTAssertTrue(compatibility.accepts(versionOutput: "2.1.275 (Claude Code)"))
        XCTAssertTrue(compatibility.accepts(versionOutput: "2.1.400 (Claude Code)"))
        XCTAssertTrue(compatibility.accepts(versionOutput: "2.2.0 (Claude Code)"))
        XCTAssertTrue(compatibility.accepts(versionOutput: "3.0.0 (Claude Code)"))

        // Below the floor, a missing marker, or an unparsable version is refused.
        XCTAssertFalse(compatibility.accepts(versionOutput: "2.0.9 (Claude Code)"))
        XCTAssertFalse(compatibility.accepts(versionOutput: "1.9.9 (Claude Code)"))
        XCTAssertFalse(compatibility.accepts(versionOutput: "2.1.275"))
        XCTAssertFalse(compatibility.accepts(versionOutput: "2.1.275 (Codex CLI)"))
        XCTAssertFalse(compatibility.accepts(versionOutput: "main (Claude Code)"))
        XCTAssertFalse(compatibility.accepts(versionOutput: ""))

        // Verification only reflects versions exercised against this source.
        for version in ["2.1.227", "2.1.239", "2.1.270", "2.1.273", "2.1.275", "2.1.281"] {
            XCTAssertTrue(compatibility.isVerified(versionOutput: "\(version) (Claude Code)"), version)
        }
        XCTAssertFalse(compatibility.isVerified(versionOutput: "2.1.276 (Claude Code)"))
        XCTAssertFalse(compatibility.isVerified(versionOutput: "2.1.280 (Claude Code)"))
        XCTAssertFalse(compatibility.isVerified(versionOutput: "2.1.282 (Claude Code)"))
        XCTAssertFalse(compatibility.isVerified(versionOutput: "2.1.0 (Claude Code)"))
        XCTAssertFalse(compatibility.isVerified(versionOutput: "2.2.0 (Claude Code)"))
        XCTAssertFalse(compatibility.isVerified(versionOutput: "2.1.275"))

        XCTAssertEqual(
            ClaudeRuntimeCompatibility.version(from: "2.1.275 (Claude Code)"),
            "2.1.275"
        )
        XCTAssertNil(ClaudeRuntimeCompatibility.version(from: "claude 2.1.275"))
        let parsed = ClaudeRuntimeCompatibility.Version("2.1.275")
        XCTAssertEqual(parsed?.major, 2)
        XCTAssertEqual(parsed?.minor, 1)
        XCTAssertEqual(parsed?.patch, 275)
        XCTAssertNil(parsed?.prerelease)
        XCTAssertNil(ClaudeRuntimeCompatibility.Version("2.1"))
    }

    func testProbeAcceptsNewerMinorAndRefusesRuntimeBelowTheFloor() async throws {
        // `--version` only; the fixture runtime starts no session and touches no home.
        let accepted = try makeVersionFixtureRuntime(output: "2.2.0 (Claude Code)")
        defer { try? FileManager.default.removeItem(at: accepted.root) }
        let descriptor = try await ClaudeAdapter(
            executableURL: accepted.executable,
            transportFactory: { _ in FakeClaudeTransport() }
        ).probeRuntime()
        XCTAssertEqual(descriptor.harness, .claudeCode)
        XCTAssertEqual(descriptor.version, "2.2.0 (Claude Code)")

        let refused = try makeVersionFixtureRuntime(output: "2.0.9 (Claude Code)")
        defer { try? FileManager.default.removeItem(at: refused.root) }
        do {
            _ = try await ClaudeAdapter(
                executableURL: refused.executable,
                transportFactory: { _ in FakeClaudeTransport() }
            ).probeRuntime()
            XCTFail("probe accepted a runtime below the supported minimum")
        } catch let error as HarnessAdapterError {
            guard case let .unsupportedRuntime(version) = error else {
                return XCTFail("unexpected probe error \(error)")
            }
            XCTAssertEqual(version, "2.0.9 (Claude Code)")
        }
    }

    /// Successful task tools now emit plans on both routes. Agent/Task lifecycle updates its
    /// activity card, while structured child-session navigation remains withheld on both.
    func testProbeClaimsOnlyWhatTheClaudeRouteCarries() async throws {
        let runtime = try makeVersionFixtureRuntime(output: "2.1.281 (Claude Code)")
        defer { try? FileManager.default.removeItem(at: runtime.root) }

        let direct = try await ClaudeAdapter(
            executableURL: runtime.executable,
            transportFactory: { _ in FakeClaudeTransport() }
        ).probeRuntime()
        XCTAssertFalse(direct.capabilities.hasSubagents)
        XCTAssertTrue(direct.capabilities.hasPlans)
        XCTAssertFalse(HarnessProtocolCompatibilityManifest.claude().supports(.subagents))
        XCTAssertTrue(HarnessProtocolCompatibilityManifest.claude().supports(.plans))

        let routed = try await YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(
                executableURL: runtime.executable,
                transportFactory: { _ in FakeClaudeTransport() }
            ),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        ).probeRuntime()
        XCTAssertEqual(routed.capabilities, direct.capabilities)
    }

    /// A late subscriber reads the newest 500 events, numbered without gaps. Closing finishes the
    /// stream and forgets the session's events, so the same local session starts again from 0.
    func testALateSubscriberReadsTheNewest500EventsAndClosingForgetsThem() async throws {
        let localID = UUID()
        let first = FakeClaudeTransport()
        let transports = OSAllocatedUnfairLock(initialState: [first, FakeClaudeTransport()])
        let adapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { _ in transports.withLock { $0.removeFirst() } }
        )
        let request = CreateHarnessSessionRequest(
            localSessionID: localID, workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil
        )
        let handle = try await adapter.createSession(request)
        var live = await adapter.events(for: handle).makeAsyncIterator()
        try await adapter.send("hello", to: handle)
        for index in 0..<600 {
            await first.emit(.object([
                "type": .string("stream_event"),
                "event": .object([
                    "type": .string("content_block_delta"),
                    "delta": .object(["type": .string("text_delta"), "text": .string("\(index)")])
                ])
            ]))
        }
        var liveEvents: [HarnessEventEnvelope] = []
        while let event = await live.next() {
            liveEvents.append(event)
            if event.payload == .assistantDelta("599") { break }
        }
        XCTAssertEqual(liveEvents.first?.payload, .sessionStarted(handle))
        XCTAssertEqual(liveEvents.map(\.sequence), Array(0..<UInt64(liveEvents.count)))
        XCTAssertGreaterThan(liveEvents.count, 600)

        var late = await adapter.events(for: handle).makeAsyncIterator()
        let replacedEnd = await live.next()
        XCTAssertNil(replacedEnd)
        var lateEvents: [HarnessEventEnvelope] = []
        for _ in 0..<500 { if let event = await late.next() { lateEvents.append(event) } }
        XCTAssertEqual(lateEvents, Array(liveEvents.suffix(500)))

        await adapter.close(handle)
        let closedEnd = await late.next()
        XCTAssertNil(closedEnd)
        let again = try await adapter.createSession(request)
        var restarted = await adapter.events(for: again).makeAsyncIterator()
        let restartedFirst = await restarted.next()
        XCTAssertEqual(restartedFirst?.sequence, 0)
        XCTAssertEqual(restartedFirst?.payload, .sessionStarted(again))
        await adapter.close(again)
    }

    private func makeVersionFixtureRuntime(output: String) throws -> (root: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-claude-version-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    /// The MCP servers a session loaded come from `system/init` at each turn and from `mcp_status`,
    /// which the adapter reads without a turn after each turn and when asked (the connector list
    /// opening). Starting a session asks nothing.
    func testMCPServersFollowInitAndMCPStatus() async throws {
        let transport = FakeClaudeTransport()
        await transport.setMCPStatusResponse(.object(["mcpServers": .array([
            .object(["name": .string("yardlet"), "status": .string("connected"),
                     "tools": .array([.object(["name": .string("browser_snapshot")])])]),
            .object(["name": .string("github"), "status": .string("connected"),
                     "tools": .array([.object(["name": .string("a")]), .object(["name": .string("b")])])]),
            .object(["name": .string("sentry"), "status": .string("failed"), "error": .string("spawn ENOENT")])
        ])]))
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil))
        let started = await transport.requestSubtypes
        XCTAssertFalse(started.contains("mcp_status"), "Starting a session reads no server status")
        let before = try await adapter.providerCapabilities(for: handle)
        XCTAssertNil(before.mcpServers)
        let read = try await adapter.mcpServers(for: handle)
        XCTAssertEqual(read.map(\.name), ["yardlet", "github", "sentry"])
        var state = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(state.mcpServers?.map(\.state), [.connected, .connected, .failed])
        XCTAssertEqual(state.mcpServers?.map(\.toolCount), [1, 2, nil])

        // A turn's `system/init` lists the servers as they stand then.
        await transport.emit(.object([
            "type": .string("system"), "subtype": .string("init"), "session_id": .string(handle.providerSessionID),
            "slash_commands": .array([]),
            "mcp_servers": .array([
                .object(["name": .string("yardlet"), "status": .string("connected")]),
                .object(["name": .string("linear"), "status": .string("needs-auth")]),
                .object(["name": .string("notion"), "status": .string("pending")]),
                .object(["name": .string("slack"), "status": .string("disabled")])
            ])
        ]))
        try await waitUntil { (try? await adapter.providerCapabilities(for: handle).mcpServers?.count) == 4 }
        state = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(state.mcpServers?.map(\.name), ["yardlet", "linear", "notion", "slack"])
        XCTAssertEqual(state.mcpServers?.map(\.state), [.connected, .needsAuthentication, .pending, .disabled])

        // The turn's end reads `mcp_status` again on its own; no message is sent for it.
        await transport.emit(.object([
            "type": .string("result"), "subtype": .string("success"), "is_error": .bool(false),
            "session_id": .string(handle.providerSessionID)
        ]))
        try await waitUntil { (try? await adapter.providerCapabilities(for: handle).mcpServers?.count) == 3 }
        state = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(state.mcpServers?.map(\.name), ["yardlet", "github", "sentry"])
        let sent = await transport.sentValues
        XCTAssertTrue(sent.isEmpty, "Reading the servers sends no message")
    }

    /// The product route wraps the adapter in YHP, whose catalogs have no place for the servers:
    /// the wrapper lays them back on and forwards the read.
    func testMCPServersCrossTheProductRoute() async throws {
        let transport = FakeClaudeTransport()
        await transport.setMCPStatusResponse(.object(["mcpServers": .array([
            .object(["name": .string("github"), "status": .string("needs-auth")])
        ])]))
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport }),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let handle = try await routed.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/claude-yhp-mcp"), initialPrompt: nil))
        let read = try await routed.mcpServers(for: handle)
        XCTAssertEqual(read.map(\.state), [.needsAuthentication])
        let state = try await routed.providerCapabilities(for: handle)
        XCTAssertEqual(state.mcpServers, [HarnessMCPServerStatus(name: "github", state: .needsAuthentication)])
    }
}

private actor ClaudePayloadRecorder {
    private(set) var payloads: [HarnessEventPayload] = []

    @discardableResult
    func append(_ payload: HarnessEventPayload) -> Int {
        payloads.append(payload)
        return payloads.count
    }
}

private actor ClaudeEventRecorder {
    private(set) var events: [HarnessEventEnvelope] = []
    func append(_ event: HarnessEventEnvelope) { events.append(event) }
}

actor FakeClaudeTransport: ClaudeTransport {
    private let stream: AsyncStream<ClaudeRawFrame>
    private let continuation: AsyncStream<ClaudeRawFrame>.Continuation
    private(set) var configuration: ClaudeLaunchConfiguration?
    private(set) var requestSubtypes: [String] = []
    private(set) var requestedValues: [JSONValue] = []
    private var taskControlError: HarnessAdapterError?
    private(set) var sentValues: [JSONValue] = []
    private(set) var stopCount = 0
    private let initializeResponse: JSONValue
    private var fileRewindResponses: [JSONValue] = []
    private var holdsRewindPreview = false
    private var heldRewindPreview: CheckedContinuation<Void, Never>?
    var hasHeldRewindPreview: Bool { heldRewindPreview != nil }
    private var fileRewindError: HarnessAdapterError?
    private var flagValues: [String: JSONValue] = [:]
    private var appliedValues: [String: JSONValue] = [:]
    private var contextUsageResponse: JSONValue?
    private var mcpStatusResponse: JSONValue?
    /// What `cancel_async_message` answers: the CLI's `{"cancelled": …}`.
    private var cancelsAsyncMessage = true
    private var holdsCancelAsyncMessage = false
    private var heldCancel: CheckedContinuation<Void, Never>?
    var hasHeldCancel: Bool { heldCancel != nil }
    /// What `interrupt` answers, such as 2.1.291's receipt for a Send now.
    private var interruptResponse: JSONValue = .object([:])
    private var holdsInterrupt = false
    private var heldInterrupt: CheckedContinuation<Void, Never>?
    var hasHeldInterrupt: Bool { heldInterrupt != nil }
    /// Holds the `initialize` answer until `answerHeldInitialize()`: a runtime still starting.
    private var holdsInitialize: Bool
    private var heldInitialize: CheckedContinuation<Void, Never>?
    var hasHeldInitialize: Bool { heldInitialize != nil }

    init(initializeResponse: JSONValue = .object(["models": .array([])]),
         effectiveSettings: [String: JSONValue] = [:], appliedSettings: [String: JSONValue] = [:],
         holdsInitialize: Bool = false) {
        self.initializeResponse = initializeResponse
        self.holdsInitialize = holdsInitialize
        self.flagValues = effectiveSettings
        self.appliedValues = appliedSettings
        let pair = AsyncStream<ClaudeRawFrame>.makeStream()
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func start(_ configuration: ClaudeLaunchConfiguration) async throws {
        self.configuration = configuration
    }

    func request(_ value: JSONValue, id: String) async throws -> JSONValue {
        let subtype = value["request"]?["subtype"]?.stringValue ?? "unknown"
        requestSubtypes.append(subtype)
        requestedValues.append(value)
        if subtype == "stop_task", let taskControlError { throw taskControlError }
        if subtype == "initialize" {
            if holdsInitialize { await withCheckedContinuation { heldInitialize = $0 } }
            return initializeResponse
        }
        if subtype == "get_context_usage", let contextUsageResponse {
            return contextUsageResponse
        }
        if subtype == "mcp_status", let mcpStatusResponse {
            return mcpStatusResponse
        }
        if subtype == "cancel_async_message" {
            if holdsCancelAsyncMessage { await withCheckedContinuation { heldCancel = $0 } }
            return .object(["cancelled": .bool(cancelsAsyncMessage)])
        }
        if subtype == "interrupt" {
            if holdsInterrupt { await withCheckedContinuation { heldInterrupt = $0 } }
            return interruptResponse
        }
        if subtype == "rewind_files" {
            if holdsRewindPreview, value["request"]?["dry_run"] == .bool(true) {
                await withCheckedContinuation { heldRewindPreview = $0 }
            }
            if let fileRewindError { throw fileRewindError }
            guard !fileRewindResponses.isEmpty else { throw HarnessAdapterError.invalidProviderEvent("No fixture rewind response") }
            return fileRewindResponses.removeFirst()
        }
        if subtype == "apply_flag_settings", let settings = value["request"]?["settings"]?.objectValue {
            for (key, val) in settings { flagValues[key] = val == .null ? nil : val }
        }
        if subtype == "get_settings" {
            return .object(["effective": .object(flagValues),
                "applied": .object(["effort": flagValues["effortLevel"] ?? .null].merging(appliedValues) { _, new in new })])
        }
        return .object([:])
    }

    func send(_ value: JSONValue) async throws {
        sentValues.append(value)
    }

    func setTaskControlError(_ error: HarnessAdapterError?) { taskControlError = error }
    func setSettings(effective: [String: JSONValue], applied: [String: JSONValue]) {
        flagValues = effective
        appliedValues = applied
    }
    func holdRewindPreview() { holdsRewindPreview = true }
    func releaseRewindPreview() {
        holdsRewindPreview = false; heldRewindPreview?.resume(); heldRewindPreview = nil
    }
    func setFileRewindResponses(_ values: [JSONValue]) { fileRewindResponses = values }
    func setContextUsageResponse(_ value: JSONValue?) { contextUsageResponse = value }
    func setMCPStatusResponse(_ value: JSONValue?) { mcpStatusResponse = value }
    func setCancelsAsyncMessage(_ cancelled: Bool) { cancelsAsyncMessage = cancelled }
    func setInterruptResponse(_ value: JSONValue) { interruptResponse = value }
    /// Holds the next `interrupt` answers until `answerHeldInterrupt()`, as when the stopped turn's
    /// result is read before the CLI's answer.
    func holdInterrupt() { holdsInterrupt = true }
    func answerHeldInitialize() {
        holdsInitialize = false
        heldInitialize?.resume()
        heldInitialize = nil
    }
    func answerHeldInterrupt() {
        holdsInterrupt = false
        heldInterrupt?.resume()
        heldInterrupt = nil
    }
    /// Holds the next `cancel_async_message` answers until `answerHeldCancel()`.
    func holdCancelAsyncMessage() { holdsCancelAsyncMessage = true }
    func answerHeldCancel() {
        holdsCancelAsyncMessage = false
        heldCancel?.resume()
        heldCancel = nil
    }
    func setFileRewindError(_ error: HarnessAdapterError?) { fileRewindError = error }

    func messages() async -> AsyncStream<ClaudeRawFrame> {
        stream
    }

    func stop() async {
        stopCount += 1
        continuation.finish()
    }

    func crash() {
        continuation.finish()
    }

    func emit(_ value: JSONValue) {
        let data = (try? ClaudeWireCodec().encodeLine(value)) ?? Data()
        continuation.yield(ClaudeRawFrame(value: value, data: data))
    }
}
