import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

final class AdditionalHarnessLiveTests: XCTestCase {
    func testLiveOpenCodeACPCreateAndStream() async throws {
        guard let binaryPath = ProcessInfo.processInfo.environment["NHC_OPENCODE_LIVE_BINARY"] else {
            throw XCTSkip("Set NHC_OPENCODE_LIVE_BINARY for the bounded OpenCode ACP smoke")
        }
        let rootURL = try makeTemporaryRoot(named: "opencode")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let adapter = ACPAdapter(
            kind: .openCode,
            executableURL: URL(filePath: binaryPath),
            launchArguments: ["acp", "--pure"]
        )
        let runtime = try await adapter.probeRuntime()
        XCTAssertEqual(runtime.harness, .openCode)

        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: rootURL,
                initialPrompt: nil
            )
        )
        do {
            try await adapter.send(
                "Reply with exactly NHC_OPENCODE_ACP_OK. Do not use tools.",
                to: handle
            )
            let payloads = try await Self.collectTurn(
                from: await adapter.events(for: handle),
                harnessName: "OpenCode ACP"
            )
            XCTAssertTrue(Self.assistantText(in: payloads).contains("NHC_OPENCODE_ACP_OK"))
        } catch {
            await adapter.close(handle)
            throw error
        }
        await adapter.close(handle)
    }

    /// Antigravity CLI over ACP, as Yardlet runs it from 1.4.11: a new task, an approval the agent
    /// asks for, a Yardlet tool reached through `yardlet-mcp` and the app's socket, the conversation
    /// continued by another process, and `/usage`, with three short turns on the account already
    /// signed in. It runs `agy acp` with a temporary `--gemini-dir`, so nothing is added to the
    /// person's conversations, and leaves the sign-in as it is.
    @MainActor
    func testLiveAntigravityACPAsksCallsYardletToolsAndContinues() async throws {
        guard let binaryPath = ProcessInfo.processInfo.environment["NHC_ANTIGRAVITY_LIVE_BINARY"] else {
            throw XCTSkip("Set NHC_ANTIGRAVITY_LIVE_BINARY for the bounded Antigravity ACP smoke (three short turns)")
        }
        let executable = URL(filePath: binaryPath)
        let routing = HarnessRegistry(versions: RuntimeVersionCache(defaults: nil))
        let servesACP = await routing.servesACP(.antigravityCLI, executableURL: executable)
        XCTAssertTrue(servesACP, "This runtime's version runs over ACP")

        let rootURL = try makeTemporaryRoot(named: "antigravity")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let workspace = rootURL.appending(path: "work", directoryHint: .isDirectory)
        let geminiDirectory = rootURL.appending(path: "gemini", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let arguments = ["acp", "--gemini-dir", geminiDirectory.path(percentEncoded: false)]

        // Yardlet's tools, as a task gets them: `yardlet-mcp` reaching the broker over a socket.
        // A socket path has to stay short, so it gets a folder of its own.
        let socketDirectory = FileManager.default.temporaryDirectory.appending(path: "yag-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: socketDirectory) }
        let socket = socketDirectory.appending(path: "tools.sock").path(percentEncoded: false)
        let suggestions = LiveSuggestionRecorder()
        let broker = AgentToolBroker(
            environment: AgentToolBroker.Environment(
                executableURL: URL(filePath: ProcessInfo.processInfo.environment["NHC_YARDLET_MCP_BINARY"]
                    ?? Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appending(path: "yardlet-mcp")
                        .path(percentEncoded: false)),
                endpoint: socket, privateDirectory: rootURL, isEnabled: { false }),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in BrowserAgentPage(cdp: ScriptedCDP()) }))
        broker.suggestions = suggestions
        let listener = try UnixSocketListener(path: socket) { body, peer in await broker.respond(to: body, peer: peer) }
        defer { listener.stop() }

        let localID = UUID()
        let adapter = ACPAdapter(kind: .antigravityCLI, executableURL: executable, launchArguments: arguments)
        await adapter.setAgentToolServer(broker.agentToolServer(for: localID, workspaceRoots: [workspace]), for: localID)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: localID, workspaceURL: workspace, initialPrompt: nil))
        let capabilities = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(capabilities.selectors.first { $0.id == AntigravityPermissionMode.optionID }?.choices.map(\.value),
                       [AntigravityPermissionMode.standard, AntigravityPermissionMode.bypass])
        let session = LiveApprovingSession(adapter: adapter, handle: handle)
        await session.start()

        let first = try await session.turn("Create a file named hello.txt containing the word hi in the current folder. "
                                           + "Then reply with just DONE.")
        XCTAssertGreaterThan(first.approvals, 0, "The agent asked before writing the file")
        XCTAssertEqual(try String(contentsOf: workspace.appending(path: "hello.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), "hi")

        _ = try await session.turn("Call the spawn_task tool of the yardlet MCP server once, with title \"Check the live "
                                   + "ACP run\", tldr \"A live check suggested this.\" and prompt \"Nothing to do.\". "
                                   + "Then reply with just DONE.")
        XCTAssertEqual(suggestions.calls.first, "spawn_task", "The agent reached Yardlet's tool through yardlet-mcp")
        await session.stop()
        await adapter.close(handle)

        // Another process continues the same conversation.
        let resumedAdapter = ACPAdapter(kind: .antigravityCLI, executableURL: executable, launchArguments: arguments)
        let resumed = try await resumedAdapter.resumeSession(providerSessionID: handle.providerSessionID,
                                                             localSessionID: localID, workspaceURL: workspace)
        let resumedSession = LiveApprovingSession(adapter: resumedAdapter, handle: resumed)
        await resumedSession.start()
        let third = try await resumedSession.turn("What is the name of the file you created earlier in this conversation? "
                                                  + "Reply with just the file name.")
        XCTAssertTrue(third.text.contains("hello.txt"), third.text)
        await resumedSession.stop()
        await resumedAdapter.close(resumed)

        // The plan limits, without a turn.
        let usage = try await AccountCommandRunner.run(executableURL: executable, arguments: AntigravityUsage.arguments,
                                                       timeout: .seconds(30))
        let metrics = try XCTUnwrap(AntigravityUsage.metrics(fromOutput: usage.output))
        XCTAssertTrue(metrics.allSatisfy { $0.id.hasPrefix("antigravity:") && $0.usedFraction != nil })
    }

    func testLivePiRPCSessionEventProjectionAndResume() async throws {
        guard let binaryPath = ProcessInfo.processInfo.environment["NHC_PI_LIVE_BINARY"] else {
            throw XCTSkip("Set NHC_PI_LIVE_BINARY for the bounded Pi RPC smoke")
        }
        let rootURL = try makeTemporaryRoot(named: "pi")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sessionDirectory = rootURL.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )

        let adapter = PiRPCAdapter(
            kind: .pi,
            executableURL: URL(filePath: binaryPath),
            launchArguments: [
                "--mode", "rpc",
                "--provider", "google",
                "--model", "gemini-2.5-flash",
                "--session-dir", sessionDirectory.path,
                "--no-tools",
                "--no-extensions",
                "--no-skills",
                "--no-prompt-templates",
                "--no-themes",
                "--no-context-files"
            ]
        )
        let runtime = try await adapter.probeRuntime()
        XCTAssertEqual(runtime.harness, .pi)

        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: rootURL,
                initialPrompt: nil
            )
        )
        try await adapter.send(
            "Reply with exactly NHC_PI_RPC_OK. Do not use tools.",
            to: handle
        )
        let firstPayloads = try await Self.collectTurn(
            from: await adapter.events(for: handle),
            harnessName: "Pi RPC",
            allowProviderError: true
        )
        try Self.assertAssistantTextOrProviderError(
            in: firstPayloads,
            expectedText: "NHC_PI_RPC_OK"
        )

        let providerSessionID = handle.providerSessionID
        await adapter.close(handle)
        let resumed = try await adapter.resumeSession(
            providerSessionID: providerSessionID,
            localSessionID: UUID(),
            workspaceURL: rootURL
        )
        XCTAssertEqual(resumed.providerSessionID, providerSessionID)
        try await adapter.send(
            "Reply with exactly NHC_PI_RPC_RESUME_OK. Do not use tools.",
            to: resumed
        )
        let resumedPayloads = try await Self.collectTurn(
            from: await adapter.events(for: resumed),
            harnessName: "Pi RPC resume",
            allowProviderError: true
        )
        try Self.assertAssistantTextOrProviderError(
            in: resumedPayloads,
            expectedText: "NHC_PI_RPC_RESUME_OK"
        )
        await adapter.close(resumed)
    }

    /// `muse serve` has no `--provider echo` (1.4.0 selects its provider from its own
    /// configuration, and `session/start.providerId` is recorded metadata only), so the
    /// model-free boundary is the handshake, an empty session, and the model catalog. The real
    /// adapter runs behind the product YHP route in a throwaway home with outbound IP traffic
    /// denied by the kernel sandbox; no turn is started and the user's Muse home is untouched.
    func testLiveMuseAttachesInAnIsolatedHomeWithoutAModelTurn() async throws {
        guard let binaryPath = ProcessInfo.processInfo.environment["NHC_MUSE_LIVE_BINARY"],
              !binaryPath.isEmpty else {
            throw XCTSkip("Set NHC_MUSE_LIVE_BINARY for the isolated, model-free Muse MSP attach")
        }
        let rootURL = try makeTemporaryRoot(named: "muse")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let homeURL = rootURL.appending(path: "home", directoryHint: .isDirectory)
        let workspaceURL = rootURL.appending(path: "workspace", directoryHint: .isDirectory)
        let temporaryURL = rootURL.appending(path: "tmp", directoryHint: .isDirectory)
        for directory in [homeURL, workspaceURL, temporaryURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func path(_ url: URL, _ component: String? = nil) -> String {
            Self.shellQuoted((component.map { url.appending(path: $0) } ?? url)
                .path(percentEncoded: false))
        }
        let launcherURL = rootURL.appending(path: "muse-isolated")
        let noNetwork = "(version 1)(allow default)(deny network-outbound (remote ip))"
        try """
        #!/bin/sh
        exec /usr/bin/env -i \\
          PATH=/usr/bin:/bin:/usr/sbin:/sbin \\
          HOME=\(path(homeURL)) \\
          XDG_CONFIG_HOME=\(path(homeURL, ".config")) \\
          XDG_DATA_HOME=\(path(homeURL, ".local/share")) \\
          XDG_STATE_HOME=\(path(homeURL, ".local/state")) \\
          XDG_CACHE_HOME=\(path(homeURL, ".cache")) \\
          TMPDIR=\(path(temporaryURL)) \\
          MUSE_NO_AUTO_UPDATE=1 \\
          LANG=en_US.UTF-8 \\
          /usr/bin/sandbox-exec -p \(Self.shellQuoted(noNetwork)) \(Self.shellQuoted(binaryPath)) "$@"

        """.write(to: launcherURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcherURL.path(percentEncoded: false)
        )

        let adapter = YHPProviderCompatibilityAdapter(
            adapter: MuseAdapter(executableURL: launcherURL),
            manifest: HarnessProtocolCompatibilityManifest.msp(.museCode)
        )
        let runtime = try await adapter.probeRuntime()
        XCTAssertEqual(runtime.harness, .museCode)
        XCTAssertTrue(runtime.version.hasPrefix("Muse Code"), runtime.version)
        XCTAssertTrue(runtime.capabilities.acceptsImages)

        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: workspaceURL,
                initialPrompt: nil
            )
        )
        do {
            let payloads = try await Self.collectUntilReady(
                from: await adapter.events(for: handle),
                harnessName: "Muse MSP"
            )
            XCTAssertTrue(payloads.contains { payload in
                guard case let .sessionStarted(session) = payload else { return false }
                return session.providerSessionID == handle.providerSessionID
            })
            XCTAssertFalse(handle.providerSessionID.isEmpty)

            // `model/list` answers even when the throwaway home has no provider login.
            let capabilities = try await adapter.providerCapabilities(for: handle)
            XCTAssertEqual(capabilities.errors, [])
            XCTAssertTrue(capabilities.selectors.contains { $0.id == "approvalMode" })
            XCTAssertTrue(capabilities.selectors.contains { $0.id == "reasoningEffort" })

            // The host resolved its Muse home inside the throwaway root.
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: homeURL.appending(path: ".local/share/muse").path(percentEncoded: false)
            ))
        } catch {
            await adapter.close(handle)
            throw error
        }
        await adapter.close(handle)
    }

    private nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func collectUntilReady(
        from stream: AsyncStream<HarnessEventEnvelope>,
        harnessName: String
    ) async throws -> [HarnessEventPayload] {
        try await withThrowingTaskGroup(of: [HarnessEventPayload].self) { group in
            group.addTask {
                var payloads: [HarnessEventPayload] = []
                for await event in stream {
                    payloads.append(event.payload)
                    if event.payload == .sessionStatusChanged(.ready) { return payloads }
                }
                throw HarnessAdapterError.invalidProviderEvent(
                    "\(harnessName) stream ended before the session was ready"
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw HarnessAdapterError.invalidProviderEvent(
                    "\(harnessName) session was not ready within 30 seconds"
                )
            }
            let result = try await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    private func makeTemporaryRoot(named harness: String) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(
                path: "nhc-\(harness)-live-smoke-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private nonisolated static func collectTurn(
        from stream: AsyncStream<HarnessEventEnvelope>,
        harnessName: String,
        allowProviderError: Bool = false
    ) async throws -> [HarnessEventPayload] {
        try await withThrowingTaskGroup(of: [HarnessEventPayload].self) { group in
            group.addTask {
                var payloads: [HarnessEventPayload] = []
                for await event in stream {
                    payloads.append(event.payload)
                    if event.payload == .turnCompleted { return payloads }
                    if case let .error(message, _, _) = event.payload,
                       !allowProviderError {
                        throw HarnessAdapterError.invalidProviderEvent(message)
                    }
                }
                throw HarnessAdapterError.invalidProviderEvent(
                    "\(harnessName) stream ended before turn completion"
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(90))
                throw HarnessAdapterError.invalidProviderEvent("\(harnessName) live smoke timed out")
            }
            let result = try await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    private nonisolated static func assistantText(
        in payloads: [HarnessEventPayload]
    ) -> String {
        payloads.compactMap { payload -> String? in
            switch payload {
            case let .assistantDelta(text), let .assistantMessageCompleted(text): text
            default: nil
            }
        }.joined()
    }

    private nonisolated static func assertAssistantTextOrProviderError(
        in payloads: [HarnessEventPayload],
        expectedText: String
    ) throws {
        if assistantText(in: payloads).contains(expectedText) { return }
        let errors = payloads.compactMap { payload -> String? in
            guard case let .error(message, _, _) = payload else { return nil }
            return message
        }
        guard errors.contains(where: { !$0.isEmpty }) else {
            throw HarnessAdapterError.invalidProviderEvent(
                "Pi live turn produced neither assistant text nor a provider error"
            )
        }
    }
}

/// The task suggestion tools' answers in a live run: it keeps which tools were called.
private final class LiveSuggestionRecorder: TaskSuggestionToolHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var called: [String] = []

    var calls: [String] { lock.withLock { called } }

    func callTaskSuggestionTool(named name: String, arguments: ToolJSON, sessionID: UUID) async -> AgentToolResult {
        lock.withLock { called.append(name) }
        return .text("Suggested.")
    }
}

/// One live ACP session's events, read by a single consumer that allows every approval the agent
/// asks for, so each turn can wait for its own completion.
private actor LiveApprovingSession {
    struct Turn {
        let text: String
        let approvals: Int
    }

    private let adapter: ACPAdapter
    private let handle: HarnessSessionHandle
    private var consumer: Task<Void, Never>?
    private var payloads: [HarnessEventPayload] = []
    private var approvals = 0
    private var completed = 0
    private var failure: String?

    init(adapter: ACPAdapter, handle: HarnessSessionHandle) {
        self.adapter = adapter
        self.handle = handle
    }

    func start() async {
        let events = await adapter.events(for: handle)
        consumer = Task { [weak self] in
            for await event in events { await self?.accept(event.payload) }
        }
    }

    func stop() {
        consumer?.cancel()
    }

    func turn(_ prompt: String) async throws -> Turn {
        let start = payloads.count
        let approvalsBefore = approvals
        let completedBefore = completed
        try await adapter.send(prompt, to: handle)
        try await waitUntil(timeout: .seconds(180)) { completed > completedBefore || failure != nil }
        if let failure { throw HarnessAdapterError.invalidProviderEvent(failure) }
        let text = payloads[start...].compactMap { payload -> String? in
            if case let .assistantMessageCompleted(text) = payload { return text }
            return nil
        }.joined(separator: "\n")
        return Turn(text: text, approvals: approvals - approvalsBefore)
    }

    private func accept(_ payload: HarnessEventPayload) async {
        payloads.append(payload)
        switch payload {
        case let .permissionRequested(request):
            approvals += 1
            try? await adapter.respond(to: request.id, decision: .allow, in: handle)
        case .turnCompleted:
            completed += 1
        case let .error(message, _, _):
            failure = message
        default:
            break
        }
    }
}
