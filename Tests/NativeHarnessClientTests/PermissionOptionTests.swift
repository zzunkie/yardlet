import Foundation
import XCTest
@testable import NativeHarnessClient

final class PermissionOptionTests: XCTestCase {
    func testACPForwardsEveryProviderOptionAndAnswersWithTheSelectedOne() async throws {
        let transport = PermissionOptionTransport()
        let adapter = ACPAdapter(
            kind: .openCode,
            executableURL: URL(filePath: "/unused"),
            transportFactory: { transport }
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: FileManager.default.temporaryDirectory,
                initialPrompt: nil
            )
        )
        let events = await adapter.events(for: handle)
        await transport.emitPermission(
            providerSessionID: handle.providerSessionID,
            options: [
                ("allow-always", "Always allow", "allow_always"),
                ("allow-once", "Allow once", "allow_once"),
                ("reject-always", "Always reject", "reject_always"),
                ("reject-once", "Reject", "reject_once")
            ]
        )
        var request: PermissionRequest?
        for await event in events {
            if case let .permissionRequested(value) = event.payload {
                request = value
                break
            }
        }
        let permission = try XCTUnwrap(request)
        XCTAssertEqual(
            permission.actions.map(\.id),
            ["allow-always", "allow-once", "reject-always", "reject-once"]
        )
        XCTAssertEqual(permission.actions.map(\.label).first, "Always allow")
        XCTAssertEqual(
            permission.actions.map(\.decision),
            [.allow, .allow, .deny, .deny]
        )

        try await adapter.respond(
            to: permission.id,
            selectedActionID: "allow-always",
            in: handle
        )
        let sent = await transport.sentMessages
        XCTAssertTrue(sent.contains {
            $0["result"]?["outcome"]?["optionId"]?.stringValue == "allow-always"
        })
        await adapter.close(handle)
    }

    func testACPPlainAllowNeverPicksTheAlwaysOptionListedFirst() async throws {
        let transport = PermissionOptionTransport()
        let adapter = ACPAdapter(
            kind: .openCode,
            executableURL: URL(filePath: "/unused"),
            transportFactory: { transport }
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: FileManager.default.temporaryDirectory,
                initialPrompt: nil
            )
        )
        let events = await adapter.events(for: handle)
        await transport.emitPermission(
            providerSessionID: handle.providerSessionID,
            options: [
                ("allow-always", "Always allow", "allow_always"),
                ("allow-once", "Allow once", "allow_once"),
                ("reject-always", "Always reject", "reject_always"),
                ("reject-once", "Reject", "reject_once")
            ]
        )
        var requestID: String?
        for await event in events {
            if case let .permissionRequested(value) = event.payload {
                requestID = value.id
                break
            }
        }
        try await adapter.respond(
            to: try XCTUnwrap(requestID),
            decision: .allow,
            in: handle
        )
        let sent = await transport.sentMessages
        XCTAssertTrue(sent.contains {
            $0["result"]?["outcome"]?["optionId"]?.stringValue == "allow-once"
        })
        XCTAssertFalse(sent.contains {
            $0["result"]?["outcome"]?["optionId"]?.stringValue == "allow-always"
        })
        await adapter.close(handle)
    }

    func testFallbackPrefersTheNarrowestScopeForEveryProviderVocabulary() {
        let acp = [
            PermissionRequestAction(id: "allow-always", label: "Always", decision: .allow, kind: "allow_always"),
            PermissionRequestAction(id: "allow-once", label: "Once", decision: .allow, kind: "allow_once"),
            PermissionRequestAction(id: "reject-always", label: "Never", decision: .deny, kind: "reject_always"),
            PermissionRequestAction(id: "reject-once", label: "Reject", decision: .deny, kind: "reject_once")
        ]
        XCTAssertEqual(
            PermissionActionPreference.preferred(from: acp, decision: .allow)?.id,
            "allow-once"
        )
        XCTAssertEqual(
            PermissionActionPreference.preferred(from: acp, decision: .deny)?.id,
            "reject-once"
        )

        let msp = [
            PermissionRequestAction(id: "allow_session", label: "Allow for session", decision: .allow, kind: "approvedForSession"),
            PermissionRequestAction(id: "allow_once", label: "Allow once", decision: .allow, kind: "approved"),
            PermissionRequestAction(id: "abort", label: "Abort", decision: .deny, kind: "abort")
        ]
        XCTAssertEqual(
            PermissionActionPreference.preferred(from: msp, decision: .allow)?.id,
            "allow_once"
        )
        XCTAssertEqual(
            PermissionActionPreference.preferred(from: msp, decision: .deny)?.id,
            "abort"
        )
    }

    func testCompatibilityFallbackPairStaysHiddenFromTheCard() async throws {
        let adapter = TwoButtonPermissionAdapter()
        let bridged = YHPProviderCompatibilityAdapter(
            adapter: adapter,
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let handle = try await bridged.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: NSTemporaryDirectory()),
                initialPrompt: nil
            )
        )
        var request: PermissionRequest?
        for await event in await bridged.events(for: handle) {
            if case let .permissionRequested(value) = event.payload {
                request = value
                break
            }
        }
        await bridged.close(handle)
        XCTAssertEqual(request?.actions.isEmpty, true)
    }
}

private actor PermissionOptionTransport: ACPTransport {
    private let channel = AsyncStream<ACPRawFrame>.makeStream()
    private(set) var sentMessages: [JSONValue] = []

    func start(_ configuration: ACPLaunchConfiguration) {}

    func send(_ value: JSONValue) {
        sentMessages.append(value)
    }

    func messages() -> AsyncStream<ACPRawFrame> { channel.stream }

    func stop() { channel.continuation.finish() }

    func request(_ value: JSONValue, id: Int64) throws -> JSONValue {
        switch value["method"]?.stringValue {
        case "initialize":
            return .object([
                "protocolVersion": .integer(1),
                "agentCapabilities": .object([:])
            ])
        case "session/new":
            return .object(["sessionId": .string("fixture")])
        default:
            return .object([:])
        }
    }

    func emitPermission(
        providerSessionID: String,
        options: [(String, String, String)]
    ) {
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .string("permission-rpc-1"),
            "method": .string("session/request_permission"),
            "params": .object([
                "sessionId": .string(providerSessionID),
                "toolCall": .object([
                    "toolCallId": .string("tool-1"),
                    "title": .string("Run command"),
                    "kind": .string("execute"),
                    "rawInput": .object(["command": .string("git status")])
                ]),
                "options": .array(options.map { option in
                    .object([
                        "optionId": .string(option.0),
                        "name": .string(option.1),
                        "kind": .string(option.2)
                    ])
                })
            ])
        ])
        channel.continuation.yield(
            ACPRawFrame(value: frame, data: (try? JSONEncoder().encode(frame)) ?? Data())
        )
    }
}

/// A provider that offers no options of its own. The bridge synthesizes an allow/deny pair for
/// the protocol, and the card must keep showing its plain two buttons.
private actor TwoButtonPermissionAdapter: HarnessAdapter {
    nonisolated let kind = HarnessKind.claudeCode

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        HarnessRuntimeDescriptor(
            harness: kind,
            executableURL: URL(filePath: "/usr/bin/true"),
            version: "0",
            capabilities: HarnessCapabilities(
                canResume: true,
                canInterrupt: true,
                hasStructuredPermissions: true,
                hasStructuredActivities: true,
                hasPlans: false,
                acceptsImages: false,
                hasSubagents: false
            ),
            fingerprint: "two-button"
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        HarnessSessionHandle(
            harness: kind,
            localSessionID: request.localSessionID,
            providerSessionID: "two-button",
            workspaceURL: request.workspaceURL
        )
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        try await createSession(
            CreateHarnessSessionRequest(
                localSessionID: localSessionID,
                workspaceURL: workspaceURL,
                initialPrompt: nil
            )
        )
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}
    func interrupt(_ session: HarnessSessionHandle) async throws {}

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {}

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        let stream = AsyncStream<HarnessEventEnvelope>.makeStream()
        stream.continuation.yield(
            HarnessEventEnvelope(
                localSessionID: session.localSessionID,
                sequence: 0,
                payload: .sessionStarted(session)
            )
        )
        stream.continuation.yield(
            HarnessEventEnvelope(
                localSessionID: session.localSessionID,
                sequence: 1,
                payload: .permissionRequested(
                    PermissionRequest(
                        id: "permission-1",
                        title: "Use a tool",
                        detail: nil,
                        command: "git status"
                    )
                )
            )
        )
        return stream.stream
    }

    func close(_ session: HarnessSessionHandle) async {}
}
