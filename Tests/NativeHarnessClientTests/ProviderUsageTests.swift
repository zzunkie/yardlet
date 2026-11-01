import Foundation
import XCTest
@testable import NativeHarnessClient

final class ProviderUsageTests: XCTestCase {
    func testClaudeResultPublishesTokensAndCost() throws {
        let value = try ClaudeWireCodec().decodeLine(Data(
            #"{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.0312,"usage":{"input_tokens":120,"cache_read_input_tokens":14337,"output_tokens":540},"modelUsage":{"claude-opus":{"contextWindow":200000}}}"#.utf8
        ))
        let payloads = ClaudeEventProjector().payloads(from: value)
        guard case let .usageUpdated(usage) = payloads.first else {
            return XCTFail("expected usage before the turn completes")
        }
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.cachedInputTokens, 14_337)
        XCTAssertEqual(usage.outputTokens, 540)
        XCTAssertEqual(usage.totalCostUSD, 0.0312)
        XCTAssertEqual(usage.contextWindowTokens, 200_000)
        XCTAssertNil(usage.contextUsedTokens)
        XCTAssertTrue(payloads.contains(.turnCompleted))
    }

    func testClaudeResultWithoutUsagePublishesNothing() throws {
        let value = try ClaudeWireCodec().decodeLine(Data(
            #"{"type":"result","subtype":"success","is_error":false}"#.utf8
        ))
        XCTAssertEqual(ClaudeEventProjector().payloads(from: value), [.turnCompleted])
    }

    func testPiPublishesSessionStatsAfterTheTurnSettles() async throws {
        let localSessionID = UUID()
        let transport = FakePiRPCTransport(sessionFile: "/tmp/pi-usage.jsonl")
        let adapter = PiRPCAdapter(
            kind: .pi,
            executableURL: URL(filePath: "/tmp/fake-pi"),
            transportFactory: { _ in transport }
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localSessionID,
                workspaceURL: URL(filePath: "/tmp/project"),
                initialPrompt: nil
            )
        )
        let events = await adapter.events(for: handle)
        try await adapter.send("hello", to: handle)
        await transport.emit(.object(["type": .string("agent_start")]))
        await transport.emit(.object(["type": .string("agent_settled")]))

        var usage: HarnessProtocolUsage?
        for await event in events {
            if case let .usageUpdated(value) = event.payload {
                usage = value
                break
            }
        }
        await adapter.close(handle)
        let requested = await transport.requestTypes
        XCTAssertTrue(requested.contains("get_session_stats"))
        XCTAssertEqual(usage?.inputTokens, 1_200)
        XCTAssertEqual(usage?.outputTokens, 300)
        XCTAssertEqual(usage?.cachedInputTokens, 50)
        XCTAssertEqual(usage?.totalCostUSD, 0.0421)
        XCTAssertEqual(usage?.contextUsedTokens, 1_550)
        XCTAssertEqual(usage?.contextWindowTokens, 200_000)
    }

    func testPiStatsWithoutAnyKnownFieldIsNotPublished() {
        XCTAssertNil(
            PiRPCEventProjector().usage(from: .object(["unrelated": .string("value")]))
        )
    }

    func testMuseContextUsageKeepsAnUnlimitedWindowUnknownAndIgnoresEmptyTotals() {
        let projector = MuseEventProjector()
        let unlimited = projector.usage(fromContextUsage: .object([
            "sessionId": .string("0198f0aa-1111-7000-8000-0000000000aa"),
            "usedTokens": .integer(4_096),
            "pressure": .string("normal")
        ]))
        XCTAssertEqual(unlimited?.contextUsedTokens, 4_096)
        XCTAssertNil(unlimited?.contextWindowTokens)
        XCTAssertNil(projector.usage(fromContextUsage: .object(["pressure": .string("normal")])))
        XCTAssertNil(projector.usage(fromTokenUsage: .object([
            "usage": .object(["inputTokens": .integer(10), "outputTokens": .integer(2)])
        ])))
    }

    /// `SubscriptionUsage` member names from the MSP v1 schema in Muse Code 1.4.0-R4161.1
    /// (`window`, `weekly`, `tier`, `observedAtMs`; `usedPercent`, `windowDurationMins`,
    /// `resetsAtMs`). Assembled from that schema, not recorded from a host.
    static let museUsageRead = #"{"usage":{"window":{"usedPercent":42,"windowDurationMins":300,"resetsAtMs":1790440000000},"weekly":{"usedPercent":107,"resetsAtMs":1790900000000},"tier":"muse_pro","observedAtMs":1790430000000}}"#

    func testMuseSubscriptionUsageFollowsTheSchemaAndFailsClosed() throws {
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(Self.museUsageRead.utf8))
        let usage = try XCTUnwrap(MuseSubscriptionUsage(result["usage"]))
        XCTAssertEqual(usage.window, MuseSubscriptionUsage.Window(
            usedPercent: 42,
            durationMinutes: 300,
            resetsAt: Date(timeIntervalSince1970: 1_790_440_000)
        ))
        // The weekly block has no length on the wire, and a percentage above 100 is kept.
        XCTAssertEqual(usage.weekly, MuseSubscriptionUsage.Window(
            usedPercent: 107,
            durationMinutes: nil,
            resetsAt: Date(timeIntervalSince1970: 1_790_900_000)
        ))
        XCTAssertEqual(usage.tier, "muse_pro")
        XCTAssertEqual(usage.observedAt, Date(timeIntervalSince1970: 1_790_430_000))

        // `usage/read` omits `usage` while the host has observed nothing.
        XCTAssertNil(MuseSubscriptionUsage(JSONValue.object([:])["usage"]))
        var object = result["usage"]?.objectValue ?? [:]
        object.removeValue(forKey: "observedAtMs")
        XCTAssertNil(MuseSubscriptionUsage(.object(object)), "an observation needs its arrival stamp")
        XCTAssertNil(MuseSubscriptionUsage(.object([
            "observedAtMs": .integer(1_790_430_000_000),
            "window": .object(["usedPercent": .integer(-1)]),
            "tier": .string("muse_pro")
        ])))
    }

    func testMuseSubscriptionUsageShowsAsProviderQuotaAsOfTheHostsObservation() async throws {
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(Self.museUsageRead.utf8))
        let usage = try XCTUnwrap(MuseSubscriptionUsage(result["usage"]))
        XCTAssertEqual(HarnessAccountBroker.museSubscriptionUsage(from: usage), [
            AccountUsageMetric(
                id: "muse:window",
                label: L10n.format("%.0f hour limit", 5.0),
                usedFraction: 0.42,
                detail: L10n.format("%.0f%% remaining", 58.0),
                resetsAt: Date(timeIntervalSince1970: 1_790_440_000),
                evidence: .exactQuota,
                windowMinutes: 300
            ),
            AccountUsageMetric(
                id: "muse:weekly",
                label: L10n.format("%.0f day limit", 7.0),
                usedFraction: 1,
                detail: L10n.format("%.0f%% remaining", 0.0),
                resetsAt: Date(timeIntervalSince1970: 1_790_900_000),
                evidence: .exactQuota,
                windowMinutes: 10_080
            )
        ])

        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-muse-usage-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "muse")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .museCode))
        let store = MuseSubscriptionUsageStore()
        let broker = HarnessAccountBroker(museUsageStore: store)

        // Before a session has read anything there is no usage row and no guessed quota; a runtime
        // that cannot answer `muse usage` leaves the login unknown.
        let before = await broker.snapshot(for: descriptor, executableURL: executable)
        XCTAssertEqual(before.state, .unknown)
        XCTAssertEqual(before.usage, [])

        await store.record(usage, for: .museCode)
        let after = await broker.snapshot(for: descriptor, executableURL: executable)
        XCTAssertEqual(after.state, .unknown)
        XCTAssertEqual(after.usage, HarnessAccountBroker.museSubscriptionUsage(from: usage))
        XCTAssertEqual(after.checkedAt, usage.observedAt)
        // The account tab's usage block reads the same quota rows.
        let blocks = AccountGroupProjection.usageBlocks(for: [
            AccountChoice(harness: .museCode, connection: nil, snapshot: after)
        ])
        XCTAssertEqual(blocks.map(\.metrics), [after.usage])
        XCTAssertEqual(blocks.first?.checkedAt, usage.observedAt)

        // `muse usage --json` is the login's evidence: "not logged in" (as Muse 1.4.14 prints it)
        // is signed out, and an answer is signed in with the allowance it read, newer than the
        // session's.
        func answer(_ script: String) throws {
            try ("#!/bin/sh\n[ \"$1 $2\" = \"usage --json\" ] || exit 9\n" + script).write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        try answer("echo 'muse usage: not logged in: run `muse login` first' >&2\nexit 1\n")
        let signedOut = await broker.snapshot(for: descriptor, executableURL: executable)
        XCTAssertEqual(signedOut.state, .signedOut)
        XCTAssertTrue(signedOut.canLogin)
        XCTAssertFalse(signedOut.canLogout)
        let fresh = Self.museUsageRead.replacingOccurrences(of: "1790430000000", with: "1790435000000")
            .replacingOccurrences(of: #""usedPercent":42"#, with: #""usedPercent":10"#)
        try answer("cat <<'EOF'\n\(fresh)\nEOF\n")
        let signedIn = await broker.snapshot(for: descriptor, executableURL: executable)
        XCTAssertEqual(signedIn.state, .signedIn)
        XCTAssertFalse(signedIn.canLogin)
        XCTAssertTrue(signedIn.canLogout)
        XCTAssertEqual(signedIn.usage.first?.usedFraction, 0.10)
        XCTAssertEqual(signedIn.checkedAt, Date(timeIntervalSince1970: 1_790_435_000))
    }

    func testClaudeAndPiManifestsDeclareUsageSoTheBridgeCanRelayIt() {
        XCTAssertTrue(HarnessProtocolCompatibilityManifest.claude().supports(.usage))
        XCTAssertTrue(HarnessProtocolCompatibilityManifest.piRPC(.pi).supports(.usage))
        XCTAssertTrue(HarnessProtocolCompatibilityManifest.msp(.museCode).supports(.usage))
        XCTAssertTrue(HarnessProtocolCompatibilityManifest.msp(.museCode).supports(.reasoning))
        XCTAssertTrue(HarnessProtocolCompatibilityManifest.claude().supports(.reasoning))
        XCTAssertTrue(HarnessProtocolCompatibilityManifest.acp(.openCode).supports(.reasoning))
    }
}
