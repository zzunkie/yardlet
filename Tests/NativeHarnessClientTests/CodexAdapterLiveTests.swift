import Foundation
import XCTest
@testable import NativeHarnessClient

final class CodexAdapterLiveTests: XCTestCase {
    func testLiveCreateStreamInterruptAndResume() async throws {
        guard let binaryPath = ProcessInfo.processInfo.environment["NHC_CODEX_LIVE_BINARY"] else {
            throw XCTSkip("Set NHC_CODEX_LIVE_BINARY for the bounded live smoke")
        }

        let binaryURL = URL(filePath: binaryPath)
        let workspaceURL = FileManager.default.temporaryDirectory
            .appending(path: "nhc-codex-live-smoke", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )

        let adapter = CodexAdapter(executableURL: binaryURL)
        let runtime = try await adapter.probeRuntime()
        XCTAssertEqual(runtime.harness, .codex)
        XCTAssertTrue(runtime.capabilities.canResume)

        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: workspaceURL,
                initialPrompt: nil
            )
        )
        try await adapter.send(
            "Reply with exactly NHC_SMOKE_OK. Do not use tools.",
            to: handle
        )
        let firstStream = await adapter.events(for: handle)
        let firstPayloads = try await Self.collectTurn(from: firstStream)
        let rendered = firstPayloads.compactMap { payload -> String? in
            guard case let .assistantDelta(delta) = payload else { return nil }
            return delta
        }.joined()
        XCTAssertTrue(rendered.contains("NHC_SMOKE_OK"))

        try await adapter.send(
            "Use the shell tool to run `sleep 20`. Do not do anything else.",
            to: handle
        )
        let activityStream = await adapter.events(for: handle)
        try await Self.waitForCommandActivity(in: activityStream)
        try await adapter.interrupt(handle)
        let secondStream = await adapter.events(for: handle)
        _ = try await Self.collectTurn(from: secondStream, completedTurnsToSkip: 1)

        let resumed = try await adapter.resumeSession(
            providerSessionID: handle.providerSessionID,
            localSessionID: UUID(),
            workspaceURL: workspaceURL
        )
        XCTAssertEqual(resumed.providerSessionID, handle.providerSessionID)

        await adapter.close(handle)
        await adapter.close(resumed)
    }

    private nonisolated static func collectTurn(
        from stream: AsyncStream<HarnessEventEnvelope>,
        completedTurnsToSkip: Int = 0
    ) async throws -> [HarnessEventPayload] {
        try await withThrowingTaskGroup(of: [HarnessEventPayload].self) { group in
            group.addTask {
                var payloads: [HarnessEventPayload] = []
                var skippedCompletedTurns = 0
                for await event in stream {
                    payloads.append(event.payload)
                    if event.payload == .turnCompleted {
                        if skippedCompletedTurns < completedTurnsToSkip {
                            skippedCompletedTurns += 1
                        } else {
                            return payloads
                        }
                    }
                }
                throw HarnessAdapterError.invalidProviderEvent(
                    "Codex event stream ended before turn completion"
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(90))
                throw HarnessAdapterError.invalidProviderEvent(
                    "Codex live smoke timed out"
                )
            }

            let result = try await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    /// A skill turned off and on again with `skills/config/write`, in a temporary Codex home. Nothing
    /// signs in and no thread starts.
    func testLiveSkillSwitchInATemporaryHome() async throws {
        guard let binaryPath = ProcessInfo.processInfo.environment["NHC_CODEX_LIVE_BINARY"] else {
            throw XCTSkip("Set NHC_CODEX_LIVE_BINARY for the bounded live smoke")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "nhc-codex-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "codex"), workspace = root.appending(path: "work")
        let skill = home.appending(path: "skills/probe-skill/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("---\nname: probe-skill\ndescription: Probe skill.\n---\nSay PROBE.\n".utf8).write(to: skill)
        let transport = CodexProcessTransport(
            executableURL: URL(filePath: binaryPath),
            environmentManager: CodexEnvironmentManager(paths: CodexEnvironmentPaths(
                nativeHomeURL: home, yardletRootURL: root.appending(path: "yardlet"))),
            environmentScope: .native
        )
        let adapter = CodexAdapter(executableURL: URL(filePath: binaryPath), transport: transport)
        func probe() async throws -> CodexSkillSummary {
            let skills = try await adapter.skills(in: workspace)
            return try XCTUnwrap(skills.first { $0.name == "probe-skill" })
        }
        var listed = try await probe()
        XCTAssertTrue(listed.enabled)
        try await adapter.setSkill(at: listed.path, enabled: false)
        listed = try await probe()
        XCTAssertFalse(listed.enabled, "A skill turned off stays listed, to turn on again")
        let config = try String(contentsOf: home.appending(path: "config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("[[skills.config]]") && config.contains("enabled = false"), config)
        try await adapter.setSkill(at: listed.path, enabled: true)
        listed = try await probe()
        XCTAssertTrue(listed.enabled)
        await transport.stop()
    }

    private nonisolated static func waitForCommandActivity(
        in stream: AsyncStream<HarnessEventEnvelope>
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in stream {
                    if case let .activityStarted(activity) = event.payload,
                       activity.kind == "commandExecution" {
                        return
                    }
                }
                throw HarnessAdapterError.invalidProviderEvent(
                    "Codex stream ended before command activity"
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw HarnessAdapterError.invalidProviderEvent(
                    "Codex command activity timed out"
                )
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }
}
