import Foundation
import XCTest
@testable import NativeHarnessClient

final class YHPCompatibilityAdapterTests: XCTestCase {
    func testCursorDirectAndYHPRoutesProduceEquivalentLifecycle() async throws {
        let fixture = try makeCursorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let direct = StructuredHeadlessAdapter(
            kind: .cursorAgent,
            executableURL: fixture.executable
        )
        let routed = YHPCompatibilityAdapter(
            adapter: StructuredHeadlessAdapter(
                kind: .cursorAgent,
                executableURL: fixture.executable
            ),
            manifest: HarnessProtocolCompatibilityManifest.structuredHeadless(.cursorAgent),
            interruptEventPolicy: .synthesizeCanceled
        )

        let directRuntime = try await direct.probeRuntime()
        let routedRuntime = try await routed.probeRuntime()
        XCTAssertEqual(routedRuntime, directRuntime)

        let localSessionID = UUID()
        let directEvents = try await runCompletedTurn(
            adapter: direct,
            localSessionID: localSessionID,
            workspaceURL: fixture.root
        )
        let routedEvents = try await runCompletedTurn(
            adapter: routed,
            localSessionID: localSessionID,
            workspaceURL: fixture.root
        )

        XCTAssertEqual(routedEvents.map(\.payload), directEvents.map(\.payload))
        XCTAssertEqual(
            routedEvents.map { $0.rawProviderEvent != nil },
            directEvents.map { $0.rawProviderEvent != nil }
        )
        XCTAssertEqual(routedEvents.map(\.sequence), Array(0..<UInt64(routedEvents.count)))
    }

    func testCursorDirectAndYHPInterruptRoutesReturnToReadyWithoutSyntheticLegacyEvent() async throws {
        let fixture = try makeCursorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let direct = StructuredHeadlessAdapter(
            kind: .cursorAgent,
            executableURL: fixture.executable
        )
        let routed = YHPCompatibilityAdapter(
            adapter: StructuredHeadlessAdapter(
                kind: .cursorAgent,
                executableURL: fixture.executable
            ),
            manifest: HarnessProtocolCompatibilityManifest.structuredHeadless(.cursorAgent),
            interruptEventPolicy: .synthesizeCanceled
        )

        let localSessionID = UUID()
        let directPayloads = try await runInterruptedTurn(
            adapter: direct,
            localSessionID: localSessionID,
            workspaceURL: fixture.root
        )
        let routedPayloads = try await runInterruptedTurn(
            adapter: routed,
            localSessionID: localSessionID,
            workspaceURL: fixture.root
        )
        XCTAssertEqual(routedPayloads, directPayloads)
    }

    func testRegistryDefaultsEveryBuiltInToYHPAndKeepsExplicitLegacyRollback() async {
        let executable = URL(filePath: "/tmp/yardlet-routing-fixture")
        let productRegistry = HarnessRegistry()
        let codex = await productRegistry.adapter(for: .codex, executableURL: executable)
        let cursor = await productRegistry.adapter(for: .cursorAgent, executableURL: executable)
        let antigravity = await productRegistry.adapter(
            for: .antigravityCLI,
            executableURL: executable
        )
        let unsupported = await productRegistry.adapter(
            for: HarnessKind(rawValue: "routing-fixture-unsupported"),
            executableURL: executable
        )

        XCTAssertTrue(codex is YHPCodexCompatibilityAdapter)
        XCTAssertTrue(cursor is YHPProviderCompatibilityAdapter)
        XCTAssertTrue(antigravity is YHPProviderCompatibilityAdapter)
        let openCode = await productRegistry.adapter(
            for: .openCode,
            executableURL: executable
        )
        XCTAssertTrue(openCode is YHPProviderCompatibilityAdapter)
        let pi = await productRegistry.adapter(for: .pi, executableURL: executable)
        XCTAssertTrue(pi is YHPProviderCompatibilityAdapter)
        let claude = await productRegistry.adapter(for: .claudeCode, executableURL: executable)
        XCTAssertTrue(claude is YHPProviderCompatibilityAdapter)
        XCTAssertTrue(unsupported is UnsupportedHarnessAdapter)

        let rollbackRegistry = HarnessRegistry(routingPolicy: .legacy)
        let legacyCodex = await rollbackRegistry.adapter(
            for: .codex,
            executableURL: executable
        )
        let legacyCursor = await rollbackRegistry.adapter(
            for: .cursorAgent,
            executableURL: executable
        )
        XCTAssertTrue(legacyCodex is CodexAdapter)
        XCTAssertTrue(legacyCursor is StructuredHeadlessAdapter)
        let legacyOpenCode = await rollbackRegistry.adapter(
            for: .openCode,
            executableURL: executable
        )
        XCTAssertTrue(legacyOpenCode is ACPAdapter)
        let legacyPi = await rollbackRegistry.adapter(for: .pi, executableURL: executable)
        XCTAssertTrue(legacyPi is PiRPCAdapter)
        let legacyClaude = await rollbackRegistry.adapter(
            for: .claudeCode,
            executableURL: executable
        )
        XCTAssertTrue(legacyClaude is ClaudeAdapter)

        // Antigravity CLI runs over ACP from the version that serves `agy acp`, in print mode before
        // it, and in print mode when no version was read.
        let agy = FileManager.default.temporaryDirectory.appending(path: "yardlet-routing-agy-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: agy.path(percentEncoded: false), contents: Data())
        defer { try? FileManager.default.removeItem(at: agy) }
        for (version, servesACP) in [("1.4.12", true), ("1.4.11", true), ("1.4.10", false), (nil, false)] {
            let registry = HarnessRegistry(routingPolicy: .legacy,
                                           versions: RuntimeVersionCache(defaults: nil, read: { _ in version }))
            let adapter = await registry.adapter(for: .antigravityCLI, executableURL: agy)
            XCTAssertEqual(adapter is ACPAdapter, servesACP, version ?? "unread")
            XCTAssertEqual(adapter is StructuredHeadlessAdapter, !servesACP, version ?? "unread")
        }
    }

    private func runCompletedTurn(
        adapter: any HarnessAdapter,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> [HarnessEventEnvelope] {
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: localSessionID,
            workspaceURL: workspaceURL,
            initialPrompt: nil
        ))
        let recorder = YHPCompatibilityEventRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event)
            }
        }

        try await adapter.send("hello", to: handle)
        try await waitUntil {
            await recorder.events.contains { $0.payload == .turnCompleted }
        }
        let events = await recorder.events
        await adapter.close(handle)
        collector.cancel()
        return events
    }

    private func runInterruptedTurn(
        adapter: any HarnessAdapter,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> [HarnessEventPayload] {
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: localSessionID,
            workspaceURL: workspaceURL,
            initialPrompt: nil
        ))
        let recorder = YHPCompatibilityEventRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event)
            }
        }

        try await adapter.send("slow", to: handle)
        try await waitUntil {
            await recorder.events.contains { $0.payload == .sessionStatusChanged(.running) }
        }
        try await adapter.interrupt(handle)
        try await waitUntil {
            let payloads = await recorder.events.map(\.payload)
            return payloads.filter { $0 == .sessionStatusChanged(.ready) }.count >= 2
        }
        let payloads = await recorder.events.map(\.payload)
        await adapter.close(handle)
        collector.cancel()
        return payloads
    }

    private func makeCursorFixture() throws -> (root: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "yardlet-yhp-routing-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "fixture-cursor")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf '%s\\n' 'fixture 1.0.0'
          exit 0
        fi
        if [ "$1" = "create-chat" ]; then
          printf '%s\\n' '00000000-0000-0000-0000-000000000721'
          exit 0
        fi
        if [ "$6" = "slow" ] || [ "$5" = "slow" ]; then
          trap 'exit 130' INT TERM
          while :; do sleep 1; done
        fi
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"00000000-0000-0000-0000-000000000721"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}'
        printf '%s\\n' '{"type":"result","subtype":"success","session_id":"00000000-0000-0000-0000-000000000721"}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        return (root, executable)
    }
}

private actor YHPCompatibilityEventRecorder {
    private(set) var events: [HarnessEventEnvelope] = []
    func append(_ event: HarnessEventEnvelope) { events.append(event) }
}
