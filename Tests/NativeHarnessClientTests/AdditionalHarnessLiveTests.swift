import Foundation
import XCTest
@testable import NativeHarnessClient

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
