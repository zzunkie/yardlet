import Foundation
import XCTest
@testable import NativeHarnessClient

final class ClaudeAdapterLiveTests: XCTestCase {
    func testLivePermissionModeCapabilityRoundTrip() async throws {
        guard let binaryPath = ProcessInfo.processInfo.environment["NHC_CLAUDE_LIVE_BINARY"] else {
            throw XCTSkip("Set NHC_CLAUDE_LIVE_BINARY for the bounded live smoke")
        }
        let binaryURL = URL(filePath: binaryPath)
        guard try Self.isLoggedIn(binaryURL) else {
            throw XCTSkip("The selected official Claude CLI is not logged in")
        }

        let workspaceURL = FileManager.default.temporaryDirectory.appending(
            path: "nhc-claude-capability-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let adapter = ClaudeAdapter(executableURL: binaryURL)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: workspaceURL, initialPrompt: nil
        ))

        let initial = try await adapter.providerCapabilities(for: handle)
        let initialMode = try XCTUnwrap(
            initial.selectors.first { $0.id == "permissionMode" }?.currentValue
        )
        let changed = try await adapter.setProviderOption(
            id: "permissionMode", value: "plan", in: handle
        )
        XCTAssertEqual(
            changed.selectors.first { $0.id == "permissionMode" }?.currentValue,
            "plan"
        )
        _ = try await adapter.setProviderOption(
            id: "permissionMode", value: initialMode, in: handle
        )
        await adapter.close(handle)
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    /// A task launched with its saved mode starts in it, and the CLI answers the context-usage
    /// request the adapter sends after each turn. No prompt is sent and no model turn runs.
    func testLiveLaunchKeepsTheSavedModeAndAnswersContextUsage() async throws {
        guard let binaryPath = ProcessInfo.processInfo.environment["NHC_CLAUDE_LIVE_BINARY"] else {
            throw XCTSkip("Set NHC_CLAUDE_LIVE_BINARY for the bounded live smoke")
        }
        let binaryURL = URL(filePath: binaryPath)
        guard try Self.isLoggedIn(binaryURL) else {
            throw XCTSkip("The selected official Claude CLI is not logged in")
        }
        let workspaceURL = FileManager.default.temporaryDirectory.appending(
            path: "nhc-claude-saved-mode-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let localID = UUID()
        let adapter = ClaudeAdapter(executableURL: binaryURL)
        await adapter.setLaunchOptions(["permissionMode": "acceptEdits"], for: localID)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: localID, workspaceURL: workspaceURL, initialPrompt: nil
        ))
        let state = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(state.selectors.first { $0.id == "permissionMode" }?.currentValue, "acceptEdits")
        await adapter.close(handle)

        let transport = ClaudeProcessTransport(executableURL: binaryURL)
        try await transport.start(ClaudeLaunchConfiguration(
            providerSessionID: UUID().uuidString.lowercased(), workspaceURL: workspaceURL,
            resumesExistingSession: false
        ))
        _ = try await transport.request(ClaudeProtocol.initialize(id: "init"), id: "init")
        let answer = try await transport.request(ClaudeProtocol.contextUsage(id: "context"), id: "context")
        let usage = try XCTUnwrap(ClaudeProtocol.contextUsage(from: answer))
        XCTAssertGreaterThan(try XCTUnwrap(usage.contextUsedTokens), 0)
        XCTAssertGreaterThan(try XCTUnwrap(usage.contextWindowTokens), try XCTUnwrap(usage.contextUsedTokens))
        print("NHC_CLAUDE_CONTEXT_USAGE \(usage.contextUsedTokens ?? 0)/\(usage.contextWindowTokens ?? 0)")
        await transport.stop()
    }

    /// The CLI's own announcement of a mode change, which the selector follows when an approval
    /// switches the mode. Read at the wire, with no prompt sent and no model turn.
    func testLivePermissionModeChangeIsAnnouncedOnTheStream() async throws {
        guard let binaryPath = ProcessInfo.processInfo.environment["NHC_CLAUDE_LIVE_BINARY"] else {
            throw XCTSkip("Set NHC_CLAUDE_LIVE_BINARY for the bounded live smoke")
        }
        let binaryURL = URL(filePath: binaryPath)
        guard try Self.isLoggedIn(binaryURL) else {
            throw XCTSkip("The selected official Claude CLI is not logged in")
        }

        let workspaceURL = FileManager.default.temporaryDirectory.appending(
            path: "nhc-claude-mode-announcement-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let transport = ClaudeProcessTransport(executableURL: binaryURL)
        try await transport.start(ClaudeLaunchConfiguration(
            providerSessionID: UUID().uuidString.lowercased(),
            workspaceURL: workspaceURL,
            resumesExistingSession: false
        ))
        let frames = await transport.messages()
        let announcements = Task { () -> [String] in
            var modes: [String] = []
            for await frame in frames {
                guard let mode = ClaudeProtocol.announcedPermissionMode(in: frame.value) else {
                    continue
                }
                print("NHC_CLAUDE_MODE_ANNOUNCEMENT \(String(decoding: frame.data, as: UTF8.self))")
                modes.append(mode)
                if modes.suffix(2) == ["acceptEdits", "manual"] { break }
            }
            return modes
        }

        _ = try await transport.request(ClaudeProtocol.initialize(id: "live-init"), id: "live-init")
        _ = try await transport.request(
            ClaudeProtocol.setPermissionMode(id: "live-accept-edits", mode: "acceptEdits"),
            id: "live-accept-edits"
        )
        _ = try await transport.request(
            ClaudeProtocol.setPermissionMode(id: "live-manual", mode: "manual"),
            id: "live-manual"
        )
        let deadline = Task {
            try? await Task.sleep(for: .seconds(10))
            await transport.stop()
        }
        let modes = await announcements.value
        deadline.cancel()
        await transport.stop()
        // Manual comes back as `default`, which is read in the selector's value.
        XCTAssertEqual(modes.suffix(2), ["acceptEdits", "manual"])
    }

    func testLiveCreateStreamInterruptAndResume() async throws {
        guard let binaryPath = ProcessInfo.processInfo.environment["NHC_CLAUDE_LIVE_BINARY"] else {
            throw XCTSkip("Set NHC_CLAUDE_LIVE_BINARY for the bounded live smoke")
        }
        let binaryURL = URL(filePath: binaryPath)
        guard try Self.isLoggedIn(binaryURL) else {
            throw XCTSkip(
                "The selected official Claude CLI is not logged in; run `claude auth login` "
                    + "for that CLI before the bounded live smoke"
            )
        }

        let workspaceURL = FileManager.default.temporaryDirectory
            .appending(path: "nhc-claude-live-smoke", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let adapter = ClaudeAdapter(executableURL: binaryURL)
        let runtime = try await adapter.probeRuntime()
        XCTAssertEqual(runtime.harness, .claudeCode)
        XCTAssertTrue(runtime.capabilities.hasStructuredPermissions)

        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: workspaceURL,
                initialPrompt: nil
            )
        )
        try await adapter.send(
            "Reply with exactly NHC_CLAUDE_SMOKE_OK. Do not use tools.",
            to: handle
        )
        let firstPayloads = try await Self.collectTurn(
            from: await adapter.events(for: handle)
        )
        let rendered = firstPayloads.compactMap { payload -> String? in
            switch payload {
            case let .assistantDelta(text), let .assistantMessageCompleted(text): text
            default: nil
            }
        }.joined()
        XCTAssertTrue(rendered.contains("NHC_CLAUDE_SMOKE_OK"))

        try await adapter.send(
            "Use the Bash tool to run exactly "
                + "`printf NHC_PERMISSION_PROBE > nhc-permission-probe.txt; sleep 20`. "
                + "Do not do anything else.",
            to: handle
        )
        let permission = try await Self.waitForPermission(
            in: await adapter.events(for: handle)
        )
        try await adapter.respond(to: permission.id, decision: .allow, in: handle)
        try await adapter.interrupt(handle)
        _ = try await Self.collectTurn(
            from: await adapter.events(for: handle),
            completedTurnsToSkip: 1
        )

        let providerSessionID = handle.providerSessionID
        await adapter.close(handle)
        let resumed = try await adapter.resumeSession(
            providerSessionID: providerSessionID,
            localSessionID: UUID(),
            workspaceURL: workspaceURL
        )
        XCTAssertEqual(resumed.providerSessionID, providerSessionID)
        try await adapter.send(
            "Reply with exactly NHC_CLAUDE_RESUME_OK. Do not use tools.",
            to: resumed
        )
        let resumedPayloads = try await Self.collectTurn(
            from: await adapter.events(for: resumed)
        )
        XCTAssertTrue(resumedPayloads.contains { payload in
            switch payload {
            case let .assistantDelta(text), let .assistantMessageCompleted(text):
                text.contains("NHC_CLAUDE_RESUME_OK")
            default:
                false
            }
        })
        await adapter.close(resumed)
    }

    private nonisolated static func collectTurn(
        from stream: AsyncStream<HarnessEventEnvelope>,
        completedTurnsToSkip: Int = 0
    ) async throws -> [HarnessEventPayload] {
        try await withThrowingTaskGroup(of: [HarnessEventPayload].self) { group in
            group.addTask {
                var payloads: [HarnessEventPayload] = []
                var skipped = 0
                for await event in stream {
                    payloads.append(event.payload)
                    if event.payload == .turnCompleted {
                        if skipped < completedTurnsToSkip {
                            skipped += 1
                        } else {
                            return payloads
                        }
                    }
                }
                throw HarnessAdapterError.invalidProviderEvent(
                    "Claude event stream ended before turn completion"
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(90))
                throw HarnessAdapterError.invalidProviderEvent("Claude live smoke timed out")
            }
            let result = try await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    private nonisolated static func waitForPermission(
        in stream: AsyncStream<HarnessEventEnvelope>
    ) async throws -> PermissionRequest {
        try await withThrowingTaskGroup(of: PermissionRequest.self) { group in
            group.addTask {
                for await event in stream {
                    if case let .permissionRequested(request) = event.payload {
                        return request
                    }
                }
                throw HarnessAdapterError.invalidProviderEvent(
                    "Claude stream ended before permission request"
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(45))
                throw HarnessAdapterError.invalidProviderEvent(
                    "Claude permission request timed out"
                )
            }
            let result = try await group.next()
            group.cancelAll()
            guard let result else {
                throw HarnessAdapterError.invalidProviderEvent("Missing Claude permission result")
            }
            return result
        }
    }

    /// The account's plugins listed and switched with the CLI's own commands, in a temporary home
    /// and config folder holding one plugin from a local marketplace. Nothing signs in, no session
    /// starts and no model turn runs.
    func testLiveAccountPluginSwitchesInATemporaryConfigFolder() async throws {
        guard let binaryPath = ProcessInfo.processInfo.environment["NHC_CLAUDE_LIVE_BINARY"] else {
            throw XCTSkip("Set NHC_CLAUDE_LIVE_BINARY for the bounded live smoke")
        }
        let binaryURL = URL(filePath: binaryPath)
        let root = FileManager.default.temporaryDirectory.appending(path: "nhc-claude-plugins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let market = root.appending(path: "market")
        let files: [String: String] = [
            ".claude-plugin/marketplace.json":
                #"{"name": "probe-market", "owner": {"name": "probe"}, "plugins": [{"name": "demo", "source": "./demo"}]}"#,
            "demo/.claude-plugin/plugin.json": #"{"name": "demo", "version": "1.0.0", "description": "Probe plugin"}"#,
            "demo/skills/probe/SKILL.md": "---\nname: probe\ndescription: Probe skill.\n---\nSay PROBE.\n"
        ]
        for (path, text) in files {
            let url = market.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let config = root.appending(path: "config")
        let environment = ["HOME": root.appending(path: "home").path(percentEncoded: false),
                           "CLAUDE_CONFIG_DIR": config.path(percentEncoded: false)]
        for arguments in [["plugin", "marketplace", "add", market.path(percentEncoded: false)],
                          ["plugin", "install", "demo@probe-market", "--scope", "user"]] {
            let result = try await AccountCommandRunner.run(executableURL: binaryURL, arguments: arguments,
                                                            environment: environment, timeout: .seconds(60))
            XCTAssertEqual(result.exitCode, 0, result.output)
        }

        let adapter = ClaudeAdapter(executableURL: binaryURL, environmentOverrides: environment)
        let demo = HarnessAccountPlugin(id: "demo@probe-market", name: "demo", marketplace: "probe-market",
                                        description: "Probe plugin", isEnabled: true)
        var listed = try await adapter.accountPlugins()
        XCTAssertEqual(listed, [demo])
        try await adapter.setAccountPlugin(demo.id, enabled: false)
        listed = try await adapter.accountPlugins()
        XCTAssertEqual(listed.map(\.isEnabled), [false], "A plugin turned off stays listed, to turn on again")
        try await adapter.setAccountPlugin(demo.id, enabled: false)
        try await adapter.setAccountPlugin(demo.id, enabled: true)
        listed = try await adapter.accountPlugins()
        XCTAssertEqual(listed, [demo])
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: config.appending(path: "settings.json")))
        XCTAssertEqual((settings as? [String: Any])?["enabledPlugins"] as? [String: Bool], [demo.id: true],
                       "The switch is the account's user setting")
    }

    private nonisolated static func isLoggedIn(_ binaryURL: URL) throws -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = binaryURL
        process.arguments = ["auth", "status"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return value["loggedIn"] as? Bool == true
    }
}
