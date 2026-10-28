import Foundation
import XCTest
@testable import NativeHarnessClient

final class StructuredHeadlessAdapterTests: XCTestCase {
    func testFlavorArgumentsPreserveProviderSessionIdentity() {
        XCTAssertEqual(
            StructuredHeadlessFlavor.cursor.arguments(
                prompt: "hello",
                providerSessionID: "cursor-chat",
                isFirstTurn: false
            ),
            [
                "--print", "--output-format", "stream-json", "--stream-partial-output",
                "--resume=cursor-chat", "hello"
            ]
        )
        XCTAssertFalse(
            StructuredHeadlessFlavor.antigravity.arguments(
                prompt: "first",
                providerSessionID: "local-placeholder",
                isFirstTurn: true
            ).contains("--conversation=local-placeholder")
        )
        XCTAssertTrue(
            StructuredHeadlessFlavor.antigravity.arguments(
                prompt: "again",
                providerSessionID: "agy-conversation",
                isFirstTurn: false
            ).contains("--conversation=agy-conversation")
        )
    }

    func testRuntimeProbeDeclaresTheSameCapabilitiesAsTheCompatibilityManifest() async throws {
        let flavors: [(HarnessKind, StructuredHeadlessFlavor)] = [
            (.cursorAgent, .cursor),
            (.antigravityCLI, .antigravity)
        ]
        for (kind, flavor) in flavors {
            let fixture = try makeFixtureExecutable(flavor: flavor)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let runtime = try await StructuredHeadlessAdapter(
                kind: kind,
                executableURL: fixture.executable
            ).probeRuntime()

            XCTAssertFalse(runtime.capabilities.hasSubagents, kind.rawValue)
            XCTAssertEqual(
                Set(runtime.capabilities.protocolCapabilities()),
                Set(HarnessProtocolCompatibilityManifest.structuredHeadless(kind).capabilities),
                kind.rawValue
            )
        }
    }

    func testAntigravityCreateStreamsAndResumeKeepsProviderIdentity() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let localID = UUID()
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: localID,
            workspaceURL: fixture.root,
            initialPrompt: nil
        ))
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }

        try await adapter.send("hello", to: handle)
        try await waitUntil {
            await recorder.payloads.contains(.turnCompleted)
        }
        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains(.assistantDelta("ready")))

        await adapter.close(handle)
        collector.cancel()

        let resumedLocalID = UUID()
        let resumed = try await adapter.resumeSession(
            providerSessionID: "agy-existing",
            localSessionID: resumedLocalID,
            workspaceURL: fixture.root
        )
        XCTAssertEqual(resumed.providerSessionID, "agy-existing")
        await adapter.close(resumed)
    }

    /// The result arrives before the process exits; a prompt sent right after it, as a queued
    /// follow-up would be, waits for that exit instead of being refused as already running.
    func testAPromptSentBetweenAResultAndItsProcessExitWaitsForTheExit() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: fixture.root, initialPrompt: nil))
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) { await recorder.append(event.payload) }
        }
        defer { collector.cancel() }
        try await adapter.send("linger", to: handle)
        try await waitUntil { await recorder.payloads.filter { $0 == .turnCompleted }.count == 1 }
        try await adapter.send("after-result", to: handle)
        try await waitUntil { await recorder.payloads.filter { $0 == .turnCompleted }.count == 2 }
        let invocations = try String(contentsOf: fixture.executable.appendingPathExtension("log"), encoding: .utf8)
        XCTAssertTrue(invocations.contains("after-result"))
    }

    func testAntigravityRestoredBeforeItsFirstPromptStartsAConversation() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let logURL = fixture.executable.appendingPathExtension("log")
        let localID = UUID()
        let created = try await StructuredHeadlessAdapter(
            kind: .antigravityCLI,
            executableURL: fixture.executable
        ).createSession(CreateHarnessSessionRequest(
            localSessionID: localID,
            workspaceURL: fixture.root,
            initialPrompt: nil
        ))

        // A restart restores the identity saved before any prompt ran.
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.resumeSession(
            providerSessionID: created.providerSessionID,
            localSessionID: localID,
            workspaceURL: fixture.root
        )
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        try await adapter.send("first-after-restart", to: handle)
        try await waitUntil {
            await recorder.payloads.filter { $0 == .turnCompleted }.count == 1
        }
        try await adapter.send("second-after-restart", to: handle)
        try await waitUntil {
            await recorder.payloads.filter { $0 == .turnCompleted }.count == 2
        }

        let invocations = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let first = try XCTUnwrap(invocations.first { $0.contains("first-after-restart") })
        let second = try XCTUnwrap(invocations.first { $0.contains("second-after-restart") })
        XCTAssertFalse(first.contains("--conversation"))
        XCTAssertTrue(second.contains("--conversation=agy-conversation"))
        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains { payload in
            guard case let .sessionStarted(started) = payload else { return false }
            return started.providerSessionID == "agy-conversation"
        })

        await adapter.close(handle)
        collector.cancel()
    }

    func testAntigravityResumedConversationContinuesTheProviderConversation() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.resumeSession(
            providerSessionID: "agy-existing",
            localSessionID: UUID(),
            workspaceURL: fixture.root
        )
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        try await adapter.send("continue-existing", to: handle)
        try await waitUntil {
            await recorder.payloads.contains(.turnCompleted)
        }
        let invocation = try XCTUnwrap(
            try String(
                contentsOf: fixture.executable.appendingPathExtension("log"),
                encoding: .utf8
            )
            .split(separator: "\n")
            .first { $0.contains("continue-existing") }
        )
        XCTAssertTrue(invocation.contains("--conversation=agy-existing"))

        await adapter.close(handle)
        collector.cancel()
    }

    func testCursorCreateStreamsAndHeadlessPermissionsFailClosed() async throws {
        let fixture = try makeFixtureExecutable(flavor: .cursor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: fixture.executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: fixture.root,
            initialPrompt: nil
        ))
        XCTAssertEqual(handle.providerSessionID, "00000000-0000-0000-0000-000000000601")

        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        try await adapter.send("hello", to: handle)
        try await waitUntil {
            await recorder.payloads.contains(.turnCompleted)
        }
        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains(.assistantDelta("hello")))

        do {
            try await adapter.respond(to: "permission", decision: .allow, in: handle)
            XCTFail("Expected structured permission response to remain unavailable")
        } catch let error as HarnessAdapterError {
            guard case .capabilityUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await adapter.close(handle)
        collector.cancel()
    }

    func testCursorCreateChatReadsAnIdentifierWrittenLateAcrossSeveralWrites() async throws {
        let fixture = try makeFixtureExecutable(
            flavor: .cursor,
            cursorCreateChat: """
            sleep 0.2
            printf '%s' '00000000-0000-'
            sleep 0.3
            printf '%s\\n' '0000-0000-000000000601'
            exit 0
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: fixture.executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: fixture.root,
            initialPrompt: nil
        ))
        XCTAssertEqual(handle.providerSessionID, "00000000-0000-0000-0000-000000000601")
        await adapter.close(handle)
    }

    func testCursorCreateChatTimeoutStopsTheProcessAndFailsClearly() async throws {
        let fixture = try makeFixtureExecutable(
            flavor: .cursor,
            cursorCreateChat: """
            printf '%s\\n' "$$" > "$0.pid"
            exec sleep 30
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(
            kind: .cursorAgent,
            executableURL: fixture.executable,
            // Room for the fixture's shell to start and write its pid on a busy Mac; at 500 ms a loaded
            // machine stopped it before it wrote one.
            cursorChatTimeout: .seconds(2)
        )
        let started = ContinuousClock.now
        do {
            _ = try await adapter.createSession(CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: fixture.root,
                initialPrompt: nil
            ))
            XCTFail("Expected a stalled create-chat to time out")
        } catch let error as HarnessAdapterError {
            XCTAssertEqual(
                error,
                .invalidProviderEvent(L10n.string("Cursor did not create a chat in time"))
            )
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))

        let pidText = try String(
            contentsOf: fixture.executable.appendingPathExtension("pid"),
            encoding: .utf8
        )
        let pid = try XCTUnwrap(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { _ = Darwin.kill(pid, SIGKILL) }
        try await waitUntil { Darwin.kill(pid, 0) != 0 }
    }

    func testCursorCreateChatFailureReportsTheExitAndItsOutput() async throws {
        let fixture = try makeFixtureExecutable(
            flavor: .cursor,
            cursorCreateChat: """
            printf '%s\\n' 'fixture create-chat failure' >&2
            exit 3
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: fixture.executable)
        do {
            _ = try await adapter.createSession(CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: fixture.root,
                initialPrompt: nil
            ))
            XCTFail("Expected a failed create-chat to fail session creation")
        } catch let error as HarnessAdapterError {
            XCTAssertEqual(
                error,
                .processExited(code: 3, message: "fixture create-chat failure")
            )
        }
    }

    func testCursorErrorResultFailsTheTurnOnDirectAndProductRoutes() async throws {
        let fixture = try makeFixtureExecutable(flavor: .cursor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapters: [any HarnessAdapter] = [
            StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: fixture.executable),
            await HarnessRegistry().adapter(for: .cursorAgent, executableURL: fixture.executable)
        ]
        for adapter in adapters {
            let handle = try await adapter.createSession(CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: fixture.root,
                initialPrompt: nil
            ))
            let recorder = HeadlessPayloadRecorder()
            let collector = Task {
                for await event in await adapter.events(for: handle) {
                    await recorder.append(event.payload)
                }
            }

            try await adapter.send("error-result", to: handle)
            try await waitUntil {
                await recorder.payloads.contains(.sessionStatusChanged(.failed))
            }
            let payloads = await recorder.payloads
            XCTAssertTrue(payloads.contains(
                .error(message: "fixture cursor failure", recoverable: true)
            ))
            XCTAssertFalse(payloads.contains(.turnCompleted))
            let running = try XCTUnwrap(payloads.firstIndex(of: .sessionStatusChanged(.running)))
            XCTAssertFalse(payloads[running...].contains(.sessionStatusChanged(.ready)))

            await adapter.close(handle)
            collector.cancel()
        }
    }

    func testOfficialHeadlessSettingsAreProjectedAndAppliedWithoutBypassFlags() async throws {
        for flavor in [StructuredHeadlessFlavor.cursor, .antigravity] {
            let fixture = try makeFixtureExecutable(flavor: flavor)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let harness: HarnessKind = flavor == .cursor ? .cursorAgent : .antigravityCLI
            let adapter = StructuredHeadlessAdapter(kind: harness, executableURL: fixture.executable)
            let handle = try await adapter.createSession(CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: fixture.root,
                initialPrompt: nil
            ))

            let initial = try await adapter.providerCapabilities(for: handle)
            XCTAssertTrue(initial.selectors.contains { $0.id == StructuredHeadlessOptionID.model })
            XCTAssertTrue(initial.selectors.contains {
                $0.id == (flavor == .cursor ? StructuredHeadlessOptionID.executionMode
                                            : StructuredHeadlessOptionID.permissionMode)
            })
            _ = try await adapter.setProviderOption(
                id: StructuredHeadlessOptionID.model,
                value: flavor == .cursor ? "cursor-model" : "agy-model",
                in: handle
            )
            _ = try await adapter.setProviderOption(
                id: flavor == .cursor ? StructuredHeadlessOptionID.executionMode : StructuredHeadlessOptionID.permissionMode,
                value: "plan",
                in: handle
            )
            _ = try await adapter.setProviderOption(
                id: StructuredHeadlessOptionID.sandbox,
                value: "enabled",
                in: handle
            )
            if flavor == .cursor {
                _ = try await adapter.setProviderOption(
                    id: StructuredHeadlessOptionID.reviewPolicy,
                    value: "auto-review",
                    in: handle
                )
            } else {
                _ = try await adapter.setProviderOption(
                    id: StructuredHeadlessOptionID.reasoningEffort,
                    value: "high",
                    in: handle
                )
            }

            try await adapter.send("settings-check", to: handle)
            let logURL = fixture.executable.appendingPathExtension("log")
            try await waitUntil {
                guard let data = FileManager.default.contents(atPath: logURL.path) else {
                    return false
                }
                return String(decoding: data, as: UTF8.self).contains("settings-check")
            }
            let invocation = try String(contentsOf: logURL, encoding: .utf8)
            XCTAssertTrue(invocation.contains("--model"))
            XCTAssertTrue(invocation.contains("plan"))
            XCTAssertTrue(invocation.contains("settings-check"))
            XCTAssertFalse(invocation.contains("--force"))
            XCTAssertFalse(invocation.contains("--yolo"))
            XCTAssertFalse(invocation.contains("--dangerously-skip-permissions"))
            if flavor == .cursor {
                XCTAssertTrue(invocation.contains("--auto-review"))
                XCTAssertTrue(invocation.contains("--sandbox enabled"))
            } else {
                // The high variant of the chosen model, never `--effort` beside it.
                XCTAssertTrue(invocation.contains("--model agy-model-high"))
                XCTAssertFalse(invocation.contains("--effort"))
                XCTAssertTrue(invocation.contains("--mode plan"))
                XCTAssertTrue(invocation.contains("--sandbox"))
            }
            await adapter.close(handle)
        }
    }

    func testInterruptReturnsHeadlessSessionToReadyWithoutFalseFailure() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: fixture.root,
            initialPrompt: nil
        ))
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }

        try await adapter.send("slow", to: handle)
        try await waitUntil {
            await recorder.payloads.contains(.sessionStatusChanged(.running))
        }
        try await adapter.interrupt(handle)
        try await waitUntil {
            let payloads = await recorder.payloads
            return payloads.filter { $0 == .sessionStatusChanged(.ready) }.count >= 2
        }
        let payloads = await recorder.payloads
        XCTAssertFalse(payloads.contains { payload in
            if case .error = payload { return true }
            return payload == .sessionStatusChanged(.failed)
        })

        await adapter.close(handle)
        collector.cancel()
    }

    func testInterruptAlsoStopsAToolProcessTheRuntimeStarted() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: fixture.root,
            initialPrompt: nil
        ))
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }

        try await adapter.send("slow-child", to: handle)
        let childURL = fixture.executable.appendingPathExtension("child")
        try await waitUntil {
            guard let text = try? String(contentsOf: childURL, encoding: .utf8) else {
                return false
            }
            return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
        let childPID = try XCTUnwrap(pid_t(
            String(contentsOf: childURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { _ = Darwin.kill(childPID, SIGKILL) }

        try await adapter.interrupt(handle)
        try await waitUntil {
            let payloads = await recorder.payloads
            return payloads.filter { $0 == .sessionStatusChanged(.ready) }.count >= 2
        }
        try await waitUntil { Darwin.kill(childPID, 0) != 0 }
        let payloads = await recorder.payloads
        XCTAssertFalse(payloads.contains { payload in
            if case .error = payload { return true }
            return payload == .sessionStatusChanged(.failed)
        })

        await adapter.close(handle)
        collector.cancel()
    }

    func testCloseStopsARunningTurnAndItsToolProcessPromptly() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: fixture.root,
            initialPrompt: nil
        ))

        try await adapter.send("slow-child", to: handle)
        let rootURL = fixture.executable.appendingPathExtension("pid")
        let childURL = fixture.executable.appendingPathExtension("child")
        try await waitUntil {
            Self.processID(at: rootURL) != nil && Self.processID(at: childURL) != nil
        }
        let rootPID = try XCTUnwrap(Self.processID(at: rootURL))
        let childPID = try XCTUnwrap(Self.processID(at: childURL))

        let started = ContinuousClock.now
        await adapter.close(handle)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        // `kill(pid, 0)` still succeeds for a zombie, so a failure also shows the turn was reaped.
        try await waitUntil { Darwin.kill(childPID, 0) != 0 }
        try await waitUntil { Darwin.kill(rootPID, 0) != 0 }
    }

    func testAbruptHeadlessExitSurfacesBoundedFailure() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: fixture.root,
            initialPrompt: nil
        ))
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }

        try await adapter.send("fail", to: handle)
        try await waitUntil {
            await recorder.payloads.contains(.sessionStatusChanged(.failed))
        }
        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains { payload in
            guard case let .error(message, recoverable, _) = payload else { return false }
            return recoverable && message.contains("fixture headless failure")
        })

        await adapter.close(handle)
        collector.cancel()
    }

    func testZeroExitWithoutTerminalResultSurfacesRecoverableFailure() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: fixture.root,
            initialPrompt: nil
        ))
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }

        try await adapter.send("empty", to: handle)
        try await waitUntil {
            await recorder.payloads.contains(.sessionStatusChanged(.failed))
        }
        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains { payload in
            guard case let .error(message, recoverable, _) = payload else { return false }
            return recoverable
                && message == L10n.string("Harness process exited without a terminal result")
        })
        XCTAssertFalse(payloads.contains(.turnCompleted))

        await adapter.close(handle)
        collector.cancel()
    }

    func testAntigravityStructuredToolErrorIsVisibleAndAllowsSuccessfulFollowUp() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: fixture.root,
            initialPrompt: nil
        ))
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }

        try await adapter.send("tool-error", to: handle)
        try await waitUntil {
            await recorder.payloads.contains(.turnCompleted)
        }
        let payloads = await recorder.payloads
        let activity = try XCTUnwrap(payloads.compactMap { payload -> HarnessActivity? in
            guard case let .activityCompleted(activity) = payload else { return nil }
            return activity
        }.first)
        XCTAssertEqual(activity.kind, "list_dir")
        XCTAssertEqual(activity.detail, Self.observedAntigravityToolError)
        XCTAssertFalse(activity.detail?.contains(String(repeating: "x", count: 400)) == true)
        XCTAssertTrue(payloads.contains(.assistantDelta("I could not list that directory.")))
        XCTAssertTrue(payloads.contains(.sessionStatusChanged(.ready)))
        XCTAssertFalse(payloads.contains { payload in
            if case .error = payload { return true }
            return payload == .sessionStatusChanged(.failed)
                || payload == .activityStarted(activity)
        })

        await adapter.close(handle)
        collector.cancel()
    }

    func testAntigravityTerminalResultCompletesOwnedRunningActivity() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: fixture.root,
            initialPrompt: nil
        ))
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }

        try await adapter.send("tool-open", to: handle)
        try await waitUntil {
            await recorder.payloads.contains(.turnCompleted)
        }
        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains { payload in
            guard case let .activityStarted(activity) = payload else { return false }
            return activity.kind == "list_dir"
        })
        XCTAssertTrue(payloads.contains { payload in
            guard case let .activityCompleted(activity) = payload else { return false }
            return activity.kind == "list_dir"
        })
        XCTAssertTrue(payloads.contains(.sessionStatusChanged(.ready)))
        XCTAssertFalse(payloads.contains { payload in
            if case .error = payload { return true }
            return payload == .sessionStatusChanged(.failed)
        })

        await adapter.close(handle)
        collector.cancel()
    }

    func testAntigravityProcessExitCompletesOwnedActivityWithoutMarkingSuccess() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: fixture.root,
            initialPrompt: nil
        ))
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }

        try await adapter.send("tool-open-exit", to: handle)
        try await waitUntil {
            await recorder.payloads.contains(.sessionStatusChanged(.failed))
        }
        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains { payload in
            guard case let .activityCompleted(activity) = payload else { return false }
            return activity.kind == "list_dir"
        })
        XCTAssertTrue(payloads.contains { payload in
            guard case let .error(message, recoverable, _) = payload else { return false }
            return recoverable
                && message == L10n.string("Harness process exited without a terminal result")
        })
        XCTAssertFalse(payloads.contains(.turnCompleted))

        await adapter.close(handle)
        collector.cancel()
    }

    // MARK: - Antigravity CLI 1.4.0

    /// `agy` 1.4.0 answers SIGINT with a result whose status is ERROR ("interrupted") and exits 1.
    /// The person asked for the stop, so the turn ends stopped and the task is ready, not failed.
    func testAntigravityStopAnsweredWithAnInterruptedResultIsNotAFailure() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: fixture.root, initialPrompt: nil))
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) { await recorder.append(event.payload) }
        }
        defer { collector.cancel() }

        try await adapter.send("slow-result", to: handle)
        try await waitUntil { await recorder.payloads.contains(.assistantDelta("part")) }
        try await adapter.interrupt(handle)
        try await waitUntil {
            await recorder.payloads.filter { $0 == .sessionStatusChanged(.ready) }.count >= 2
        }
        let payloads = await recorder.payloads
        XCTAssertFalse(payloads.contains { payload in
            if case .error = payload { return true }
            return payload == .sessionStatusChanged(.failed) || payload == .turnCompleted
        })
        XCTAssertTrue(payloads.contains(.assistantDelta("part")))
        await adapter.close(handle)
    }

    /// What a headless run could not ask about is one failed row, and the turn still completes.
    func testAntigravityDeniedActionsAreOneFailedRowAndTheTurnCompletes() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: fixture.root, initialPrompt: nil))
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) { await recorder.append(event.payload) }
        }
        defer { collector.cancel() }

        try await adapter.send("denied", to: handle)
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }
        let completed = await recorder.payloads.compactMap { payload -> HarnessActivity? in
            guard case let .activityCompleted(activity) = payload else { return nil }
            return activity
        }
        let command = try XCTUnwrap(completed.first { $0.kind == "run_command" })
        XCTAssertEqual(command.outcome, .failed)
        XCTAssertEqual(command.input, "ls -la")
        let denied = try XCTUnwrap(completed.first { $0.kind == "denied_actions" })
        XCTAssertEqual(denied.outcome, .failed)
        XCTAssertEqual(denied.detail, "Run command")
        XCTAssertEqual(denied.title, L10n.string("Not run without approval"))
        let payloads = await recorder.payloads
        XCTAssertFalse(payloads.contains { payload in
            if case .error = payload { return true }
            return payload == .sessionStatusChanged(.failed)
        })
        await adapter.close(handle)
    }

    /// Each invocation's arguments and environment: the prompt and stream flags, the provider
    /// conversation, Yardlet's three display variables, and nothing that carries an MCP server or a
    /// folder of Yardlet's. `agy` records `--add-dir` folders in the conversation and revives them
    /// when it is continued elsewhere, so Yardlet passes none (the approval-hook branch was removed).
    func testAntigravityLaunchArgumentsAndEnvironmentCarryNoMCPServer() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.resumeSession(
            providerSessionID: "agy-existing", localSessionID: UUID(), workspaceURL: fixture.root)
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) { await recorder.append(event.payload) }
        }
        defer { collector.cancel() }

        try await adapter.send("environment", to: handle)
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }
        let invocation = try String(contentsOf: fixture.executable.appendingPathExtension("log"), encoding: .utf8)
        XCTAssertEqual(invocation, "--print environment --output-format stream-json --conversation=agy-existing\n")
        let environment = try String(contentsOf: fixture.executable.appendingPathExtension("env"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        for expected in ["NO_COLOR=1", "PAGER=cat", "GIT_PAGER=cat"] {
            XCTAssertTrue(environment.contains(expected), expected)
        }
        XCTAssertFalse(invocation.lowercased().contains("mcp"))
        XCTAssertFalse(environment.contains { $0.uppercased().hasPrefix("YARDLET_MCP") || $0.contains("mcp_config") })
        XCTAssertFalse(environment.contains { $0.hasPrefix("YARDLET_TOOLS_") })
        XCTAssertFalse(invocation.contains("--add-dir"))
        XCTAssertNil(AgentToolInjectionRoute.route(for: .antigravityCLI))
        await adapter.close(handle)
    }

    /// The model list folds `agy-model-high`/`-low` into one model whose efforts are those
    /// variants; a model without variants has no effort control. A choice launches the variant's
    /// own ID, and never `--effort` beside a model, which the CLI refuses.
    func testAntigravityModelMenuFoldsEffortVariantsAndLaunchesTheVariant() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.resumeSession(
            providerSessionID: "agy-conversation", localSessionID: UUID(), workspaceURL: fixture.root)

        let initial = try await adapter.providerCapabilities(for: handle)
        let models = try XCTUnwrap(initial.selectors.first { $0.id == StructuredHeadlessOptionID.model })
        XCTAssertEqual(models.choices.map(\.value), ["default", "agy-model", "agy-plain"])
        XCTAssertEqual(models.choices.map(\.name), [L10n.string("Default"), "Antigravity Model", "Plain Model"])
        XCTAssertNil(initial.selectors.first { $0.id == StructuredHeadlessOptionID.reasoningEffort })
        // The permission mode comes before the sandbox, so it is the composer's permission control.
        let ids = initial.selectors.map(\.id)
        XCTAssertLessThan(try XCTUnwrap(ids.firstIndex(of: StructuredHeadlessOptionID.permissionMode)),
                          try XCTUnwrap(ids.firstIndex(of: StructuredHeadlessOptionID.sandbox)))

        let chosen = try await adapter.setProviderOption(id: StructuredHeadlessOptionID.model, value: "agy-model", in: handle)
        let efforts = try XCTUnwrap(chosen.selectors.first { $0.id == StructuredHeadlessOptionID.reasoningEffort })
        XCTAssertEqual(efforts.choices.map(\.value), ["default", "low", "high"])
        XCTAssertEqual(efforts.category, "thought_level")
        _ = try await adapter.setProviderOption(id: StructuredHeadlessOptionID.reasoningEffort, value: "low", in: handle)
        try await sendAndWait("first", adapter: adapter, handle: handle, fixture: fixture)

        // A model without variants drops the effort, and an effort it does not have is refused.
        let plain = try await adapter.setProviderOption(id: StructuredHeadlessOptionID.model, value: "agy-plain", in: handle)
        XCTAssertNil(plain.selectors.first { $0.id == StructuredHeadlessOptionID.reasoningEffort })
        do {
            _ = try await adapter.setProviderOption(id: StructuredHeadlessOptionID.reasoningEffort, value: "high", in: handle)
            XCTFail("A model without efforts took one")
        } catch HarnessAdapterError.capabilityUnavailable {}
        try await sendAndWait("second", adapter: adapter, handle: handle, fixture: fixture)

        // A variant saved before the list was folded is that model and effort.
        let saved = try await adapter.setProviderOption(id: StructuredHeadlessOptionID.model, value: "agy-model-high", in: handle)
        XCTAssertEqual(saved.selectors.first { $0.id == StructuredHeadlessOptionID.model }?.currentValue, "agy-model")
        XCTAssertEqual(saved.selectors.first { $0.id == StructuredHeadlessOptionID.reasoningEffort }?.currentValue, "high")
        try await sendAndWait("third", adapter: adapter, handle: handle, fixture: fixture)

        let lines = try String(contentsOf: fixture.executable.appendingPathExtension("log"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first { $0.hasPrefix("--print first") },
                       "--print first --output-format stream-json --model agy-model-low --conversation=agy-conversation")
        XCTAssertEqual(lines.first { $0.hasPrefix("--print second") },
                       "--print second --output-format stream-json --model agy-plain --conversation=agy-conversation")
        XCTAssertEqual(lines.first { $0.hasPrefix("--print third") },
                       "--print third --output-format stream-json --model agy-model-high --conversation=agy-conversation")
        XCTAssertFalse(lines.contains { $0.hasPrefix("--print ") && $0.contains("--effort") })
        await adapter.close(handle)
    }

    /// The permission modes are the CLI's: its default, `--mode accept-edits`, `--mode plan`, Auto
    /// only where the CLI says the account has it, and Bypass permissions as
    /// `--dangerously-skip-permissions`. A task saved with the earlier `executionMode` still applies.
    func testAntigravityPermissionModesPassTheCLIsOwnFlags() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let handle = try await adapter.resumeSession(
            providerSessionID: "agy-conversation", localSessionID: UUID(), workspaceURL: fixture.root)

        let state = try await adapter.providerCapabilities(for: handle)
        let modes = try XCTUnwrap(state.selectors.first { $0.id == StructuredHeadlessOptionID.permissionMode })
        XCTAssertEqual(modes.choices.map(\.value), ["default", "accept-edits", "plan", "bypass"])
        XCTAssertEqual(modes.choices.last?.name, L10n.string("Bypass permissions"))
        XCTAssertEqual(modes.currentValue, "default")
        do {
            _ = try await adapter.setProviderOption(id: StructuredHeadlessOptionID.permissionMode, value: "auto", in: handle)
            XCTFail("Auto was taken where the CLI said the account does not have it")
        } catch HarnessAdapterError.capabilityUnavailable {}

        _ = try await adapter.setProviderOption(id: StructuredHeadlessOptionID.permissionMode, value: "bypass", in: handle)
        try await sendAndWait("bypass-turn", adapter: adapter, handle: handle, fixture: fixture)
        _ = try await adapter.setProviderOption(id: StructuredHeadlessOptionID.executionMode, value: "accept-edits", in: handle)
        try await sendAndWait("edits-turn", adapter: adapter, handle: handle, fixture: fixture)
        _ = try await adapter.setProviderOption(id: StructuredHeadlessOptionID.permissionMode, value: "default", in: handle)
        try await sendAndWait("default-turn", adapter: adapter, handle: handle, fixture: fixture)

        let lines = try String(contentsOf: fixture.executable.appendingPathExtension("log"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first { $0.hasPrefix("--print bypass-turn") },
                       "--print bypass-turn --output-format stream-json --dangerously-skip-permissions --conversation=agy-conversation")
        XCTAssertEqual(lines.first { $0.hasPrefix("--print edits-turn") },
                       "--print edits-turn --output-format stream-json --mode accept-edits --conversation=agy-conversation")
        XCTAssertEqual(lines.first { $0.hasPrefix("--print default-turn") },
                       "--print default-turn --output-format stream-json --conversation=agy-conversation")
        await adapter.close(handle)

        // Where the account has Auto, it is one of the modes.
        let autoFixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: autoFixture.root) }
        FileManager.default.createFile(atPath: autoFixture.executable.appendingPathExtension("auto").path, contents: Data())
        let autoAdapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: autoFixture.executable)
        let autoHandle = try await autoAdapter.resumeSession(
            providerSessionID: "agy-conversation", localSessionID: UUID(), workspaceURL: autoFixture.root)
        let autoState = try await autoAdapter.providerCapabilities(for: autoHandle)
        XCTAssertEqual(autoState.selectors.first { $0.id == StructuredHeadlessOptionID.permissionMode }?.choices.map(\.value),
                       ["default", "accept-edits", "auto", "plan", "bypass"])
        let chosen = try await autoAdapter.setProviderOption(
            id: StructuredHeadlessOptionID.permissionMode, value: "auto", in: autoHandle)
        XCTAssertEqual(chosen.selectors.first { $0.id == StructuredHeadlessOptionID.permissionMode }?.currentValue, "auto")
        await autoAdapter.close(autoHandle)
    }

    /// The runtime's tasks share one read of the lists for a while instead of each starting three
    /// more `agy` processes.
    func testAntigravityTasksShareOneReadOfTheLists() async throws {
        let fixture = try makeFixtureExecutable(flavor: .antigravity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .antigravityCLI, executableURL: fixture.executable)
        let first = try await adapter.resumeSession(
            providerSessionID: "agy-one", localSessionID: UUID(), workspaceURL: fixture.root)
        let second = try await adapter.resumeSession(
            providerSessionID: "agy-two", localSessionID: UUID(), workspaceURL: fixture.root)
        _ = try await adapter.providerCapabilities(for: first)
        let state = try await adapter.providerCapabilities(for: second)
        XCTAssertTrue(state.selectors.contains { $0.id == StructuredHeadlessOptionID.model })
        let lines = try String(contentsOf: fixture.executable.appendingPathExtension("log"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0 == "models" }.count, 1)
        XCTAssertEqual(lines.filter { $0 == "agents" }.count, 1)
        XCTAssertEqual(lines.filter { $0.contains("/model") }.count, 1)
        await adapter.close(first)
        await adapter.close(second)
    }

    /// Sends one prompt and waits for its turn to complete (the next send waits for the exit).
    private func sendAndWait(
        _ prompt: String, adapter: StructuredHeadlessAdapter, handle: HarnessSessionHandle,
        fixture: (root: URL, executable: URL)
    ) async throws {
        let recorder = HeadlessPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) { await recorder.append(event.payload) }
        }
        defer { collector.cancel() }
        // A new subscriber is first given the session's earlier events.
        try await Task.sleep(for: .milliseconds(50))
        let before = await recorder.payloads.filter { $0 == .turnCompleted }.count
        try await adapter.send(prompt, to: handle)
        try await waitUntil { await recorder.payloads.filter { $0 == .turnCompleted }.count > before }
    }

    private static let observedAntigravityToolError =
        "permission check failed for read_file \"/tmp/yardlet-fixture\": user denied permission for read_file(/tmp/yardlet-fixture)"

    private func makeFixtureExecutable(
        flavor: StructuredHeadlessFlavor,
        cursorCreateChat: String = """
        printf '%s\\n' '00000000-0000-0000-0000-000000000601'
        exit 0
        """
    ) throws -> (root: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-headless-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "fixture-headless")
        let script: String
        switch flavor {
        case .cursor:
            script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$0.log"
            if [ "$1" = "create-chat" ]; then
            \(cursorCreateChat)
            fi
            if [ "$1" = "--list-models" ]; then
              printf '%s\\t%s\\n' 'cursor-model' 'Cursor Model'
              exit 0
            fi
            case "$*" in
              *error-result*)
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"00000000-0000-0000-0000-000000000601"}'
                printf '%s\\n' '{"type":"result","subtype":"error","is_error":true,"result":"fixture cursor failure","session_id":"00000000-0000-0000-0000-000000000601"}'
                exit 0
                ;;
            esac
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"00000000-0000-0000-0000-000000000601"}'
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","result":"hello","session_id":"00000000-0000-0000-0000-000000000601"}'
            """
        case .antigravity:
            let padding = String(repeating: "x", count: 400)
            let toolErrorLine = #"{"event":"step_update","step_update":{"conversation_id":"agy-conversation","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"list_dir","tool_info":{"name":"list_dir","parameters":{"DirectoryPath":"/tmp/yardlet-fixture","padding":"\#(padding)"},"error":{"type":"TOOL_ERROR","message":"permission check failed for read_file \"/tmp/yardlet-fixture\": user denied permission for read_file(/tmp/yardlet-fixture)"}}}}"#
            let toolOpenLine = #"{"event":"step_update","step_update":{"conversation_id":"agy-conversation","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"list_dir","tool_info":{"name":"list_dir","parameters":{"DirectoryPath":"/tmp/yardlet-fixture"}}}}"#
            // The shapes `agy` 1.4.0 printed in the sandbox turns (values are fixtures).
            let interruptedLine = #"{"event":"result","result":{"conversation_id":"agy-conversation","status":"ERROR","response":"part","error":"interrupted","usage":{"input_tokens":10,"output_tokens":2,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":12}}}"#
            let deniedToolLine = #"{"event":"step_update","step_update":{"conversation_id":"agy-conversation","step_index":3,"state":"ERROR","step_type":"tool","tool_name":"run_command","duration_seconds":0.1,"tool_info":{"name":"run_command","parameters":{"CommandLine":"ls -la"},"error":{"type":"TOOL_ERROR","message":"fixture: permission denied in a headless run"}}}}"#
            let deniedResultLine = #"{"event":"result","result":{"conversation_id":"agy-conversation","status":"SUCCESS","response":"","duration_seconds":1,"num_turns":1,"usage":{"input_tokens":10,"output_tokens":2,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":12},"denied_actions":[{"action":"command","display_name":"Run command"}]}}"#
            script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$0.log"
            if [ "$1" = "models" ]; then
              printf '%s\\t%s\\n' 'agy-model-high' 'Antigravity Model (High)' 'agy-model-low' 'Antigravity Model (Low)' 'agy-plain' 'Plain Model'
              exit 0
            fi
            if [ "$1" = "agents" ]; then
              printf '%s\\t%s\\n' 'agy-agent' 'Antigravity Agent'
              exit 0
            fi
            if [ "$2" = "/model" ]; then
              if [ ! -f "$0.auto" ]; then
                printf '%s\\n' 'warning: --mode auto is not available for this account; continuing in the default mode.' >&2
              fi
              printf '%s\\n' '{"event":"result","result":{"conversation_id":"","status":"SUCCESS","response":""}}'
              exit 0
            fi
            if [ "$2" = "environment" ]; then
              env > "$0.env"
            fi
            if [ "$2" = "slow-result" ]; then
              interrupted() {
                printf '%s\\n' '\(interruptedLine)'
                exit 1
              }
              trap interrupted INT TERM
              printf '%s\\n' '{"event":"init","conversation_id":"agy-conversation","init":{"cwd":"/tmp"}}'
              printf '%s\\n' '{"event":"step_update","step_update":{"conversation_id":"agy-conversation","step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":"part"}}'
              while :; do sleep 1; done
            fi
            if [ "$2" = "denied" ]; then
              printf '%s\\n' '{"event":"init","conversation_id":"agy-conversation","init":{"cwd":"/tmp"}}'
              printf '%s\\n' '\(deniedToolLine)'
              printf '%s\\n' '\(deniedResultLine)'
              exit 0
            fi
            if [ "$2" = "empty" ]; then
              exit 0
            fi
            if [ "$2" = "fail" ]; then
              printf '%s\\n' 'fixture headless failure' >&2
              exit 7
            fi
            if [ "$2" = "slow" ]; then
              trap 'exit 130' INT TERM
              while :; do sleep 1; done
            fi
            if [ "$2" = "slow-child" ]; then
              trap 'exit 130' INT TERM
              printf '%s\\n' "$$" > "$0.pid"
              sh -c 'printf "%s\\n" "$$" > "$1"; exec sleep 30' sh "$0.child"
              exit 0
            fi
            if [ "$2" = "tool-error" ]; then
              printf '%s\\n' '{"event":"init","conversation_id":"agy-conversation","init":{"cwd":"/tmp"}}'
              printf '%s\\n' '\(toolErrorLine)'
              printf '%s\\n' '{"event":"step_update","step_update":{"conversation_id":"agy-conversation","step_index":3,"state":"DONE","step_type":"agent_response","text_delta":"I could not list that directory."}}'
              printf '%s\\n' '{"event":"result","result":{"conversation_id":"agy-conversation","status":"SUCCESS","response":"I could not list that directory."}}'
              exit 0
            fi
            if [ "$2" = "tool-open" ]; then
              printf '%s\\n' '{"event":"init","conversation_id":"agy-conversation","init":{"cwd":"/tmp"}}'
              printf '%s\\n' '\(toolOpenLine)'
              printf '%s\\n' '{"event":"result","result":{"conversation_id":"agy-conversation","status":"SUCCESS","response":"ready"}}'
              exit 0
            fi
            if [ "$2" = "linger" ]; then
              printf '%s\\n' '{"event":"init","conversation_id":"agy-conversation","init":{"cwd":"/tmp"}}'
              printf '%s\\n' '{"event":"result","result":{"conversation_id":"agy-conversation","status":"SUCCESS","response":"done"}}'
              sleep 0.4
              exit 0
            fi
            if [ "$2" = "tool-open-exit" ]; then
              printf '%s\\n' '{"event":"init","conversation_id":"agy-conversation","init":{"cwd":"/tmp"}}'
              printf '%s\\n' '\(toolOpenLine)'
              exit 0
            fi
            printf '%s\\n' '{"event":"init","conversation_id":"agy-conversation","init":{"cwd":"/tmp"}}'
            printf '%s\\n' '{"event":"step_update","step_update":{"conversation_id":"agy-conversation","step_index":1,"state":"DONE","step_type":"agent_response","text_delta":"ready"}}'
            printf '%s\\n' '{"event":"result","result":{"conversation_id":"agy-conversation","status":"SUCCESS","response":"ready"}}'
            """
        }
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        return (root, executable)
    }

    private static func processID(at url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private actor HeadlessPayloadRecorder {
    private(set) var payloads: [HarnessEventPayload] = []
    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }
}
