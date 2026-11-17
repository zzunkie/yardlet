import Foundation
import XCTest
@testable import NativeHarnessClient

final class StructuredHeadlessAdapterTests: XCTestCase {
    func testFlavorArgumentsPreserveProviderSessionIdentity() {
        XCTAssertEqual(
            StructuredHeadlessFlavor.cursor.arguments(
                prompt: "hello",
                providerSessionID: "cursor-chat"
            ),
            [
                "--print", "--output-format", "stream-json", "--stream-partial-output",
                "--resume=cursor-chat", "hello"
            ]
        )
        // A prompt is never read as one of the CLI's options.
        let arguments = StructuredHeadlessFlavor.cursor.arguments(prompt: "--force", providerSessionID: "chat")
        XCTAssertFalse(arguments.contains("--force"))
        XCTAssertTrue(arguments.contains("\n--force"))
    }

    func testRuntimeProbeDeclaresTheSameCapabilitiesAsTheCompatibilityManifest() async throws {
        let flavors: [(HarnessKind, StructuredHeadlessFlavor)] = [(.cursorAgent, .cursor)]
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

    /// The result arrives before the process exits; a prompt sent right after it, as a queued
    /// follow-up would be, waits for that exit instead of being refused as already running.
    func testAPromptSentBetweenAResultAndItsProcessExitWaitsForTheExit() async throws {
        let fixture = try makeFixtureExecutable(flavor: .cursor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: fixture.executable)
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
        let fixture = try makeFixtureExecutable(flavor: .cursor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: fixture.executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: fixture.root,
            initialPrompt: nil
        ))

        let initial = try await adapter.providerCapabilities(for: handle)
        XCTAssertTrue(initial.selectors.contains { $0.id == StructuredHeadlessOptionID.model })
        XCTAssertTrue(initial.selectors.contains { $0.id == StructuredHeadlessOptionID.executionMode })
        _ = try await adapter.setProviderOption(id: StructuredHeadlessOptionID.model, value: "cursor-model", in: handle)
        _ = try await adapter.setProviderOption(id: StructuredHeadlessOptionID.executionMode, value: "plan", in: handle)
        _ = try await adapter.setProviderOption(id: StructuredHeadlessOptionID.sandbox, value: "enabled", in: handle)
        _ = try await adapter.setProviderOption(id: StructuredHeadlessOptionID.reviewPolicy, value: "auto-review", in: handle)

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
        XCTAssertTrue(invocation.contains("--auto-review"))
        XCTAssertTrue(invocation.contains("--sandbox enabled"))
        await adapter.close(handle)
    }

    func testInterruptReturnsHeadlessSessionToReadyWithoutFalseFailure() async throws {
        let fixture = try makeFixtureExecutable(flavor: .cursor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: fixture.executable)
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
        let fixture = try makeFixtureExecutable(flavor: .cursor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: fixture.executable)
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
        let fixture = try makeFixtureExecutable(flavor: .cursor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: fixture.executable)
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
        let fixture = try makeFixtureExecutable(flavor: .cursor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: fixture.executable)
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
        let fixture = try makeFixtureExecutable(flavor: .cursor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: fixture.executable)
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

    func testTerminalResultCompletesOwnedRunningActivity() async throws {
        let fixture = try makeFixtureExecutable(flavor: .cursor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: fixture.executable)
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
            return activity.kind == "ShellToolCall"
        })
        XCTAssertTrue(payloads.contains { payload in
            guard case let .activityCompleted(activity) = payload else { return false }
            return activity.kind == "ShellToolCall"
        })
        XCTAssertTrue(payloads.contains(.sessionStatusChanged(.ready)))
        XCTAssertFalse(payloads.contains { payload in
            if case .error = payload { return true }
            return payload == .sessionStatusChanged(.failed)
        })

        await adapter.close(handle)
        collector.cancel()
    }

    func testProcessExitCompletesOwnedActivityWithoutMarkingSuccess() async throws {
        let fixture = try makeFixtureExecutable(flavor: .cursor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: fixture.executable)
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
            return activity.kind == "ShellToolCall"
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

    /// A runtime that answers the stop with an error result ("interrupted") and exits 1: the person
    /// asked for the stop, so the turn ends stopped and the task is ready, not failed.
    func testAStopAnsweredWithAnErrorResultIsNotAFailure() async throws {
        let fixture = try makeFixtureExecutable(flavor: .cursor)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let adapter = StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: fixture.executable)
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

    /// A Cursor Agent stand-in: `create-chat`, `--list-models`, and a turn whose prompt (the last
    /// argument) picks what the run does.
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
        let initLine = #"{"type":"system","subtype":"init","session_id":"00000000-0000-0000-0000-000000000601"}"#
        let toolOpenLine = #"{"type":"tool_call","subtype":"started","call_id":"cursor-call","tool_call":{"ShellToolCall":{"args":{"command":"ls"}}},"session_id":"00000000-0000-0000-0000-000000000601"}"#
        let successLine = #"{"type":"result","subtype":"success","result":"hello","session_id":"00000000-0000-0000-0000-000000000601"}"#
        let interruptedLine = #"{"type":"result","subtype":"error","is_error":true,"result":"interrupted","session_id":"00000000-0000-0000-0000-000000000601"}"#
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
            for prompt; do :; done
            case "$prompt" in
              *error-result*)
                printf '%s\\n' '\(initLine)'
                printf '%s\\n' '{"type":"result","subtype":"error","is_error":true,"result":"fixture cursor failure","session_id":"00000000-0000-0000-0000-000000000601"}'
                exit 0
                ;;
              slow-result)
                interrupted() {
                  printf '%s\\n' '\(interruptedLine)'
                  exit 1
                }
                trap interrupted INT TERM
                printf '%s\\n' '\(initLine)'
                printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"part"}]}}'
                while :; do sleep 1; done
                ;;
              slow)
                trap 'exit 130' INT TERM
                while :; do sleep 1; done
                ;;
              slow-child)
                trap 'exit 130' INT TERM
                printf '%s\\n' "$$" > "$0.pid"
                sh -c 'printf "%s\\n" "$$" > "$1"; exec sleep 30' sh "$0.child"
                exit 0
                ;;
              fail)
                printf '%s\\n' 'fixture headless failure' >&2
                exit 7
                ;;
              empty)
                exit 0
                ;;
              linger)
                printf '%s\\n' '\(initLine)'
                printf '%s\\n' '\(successLine)'
                sleep 0.4
                exit 0
                ;;
              tool-open)
                printf '%s\\n' '\(initLine)'
                printf '%s\\n' '\(toolOpenLine)'
                printf '%s\\n' '\(successLine)'
                exit 0
                ;;
              tool-open-exit)
                printf '%s\\n' '\(initLine)'
                printf '%s\\n' '\(toolOpenLine)'
                exit 0
                ;;
            esac
            printf '%s\\n' '\(initLine)'
            printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}'
            printf '%s\\n' '\(successLine)'
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
