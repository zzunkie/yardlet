import Foundation
import XCTest
@testable import NativeHarnessClient

/// Claude in Chrome is the CLI's own `--chrome` flag, offered as one session option. Yardlet
/// never builds a browser of its own, and it never guesses whether the extension is there: the
/// CLI's own refusal is what the task shows.
@MainActor
final class ClaudeChromeIntegrationTests: XCTestCase {
    private let workspace = URL(filePath: "/tmp/claude-chrome-workspace")

    func testTheChromeFlagIsPassedOnlyWhenTheSessionAskedForIt() throws {
        let off = ClaudeProcessTransport.arguments(for: ClaudeLaunchConfiguration(
            providerSessionID: "session-1",
            workspaceURL: workspace,
            resumesExistingSession: false
        ))
        XCTAssertFalse(off.contains("--chrome"))
        XCTAssertFalse(
            off.contains("--no-chrome"),
            "Leaving the flag out keeps the CLI's own default instead of forcing it off"
        )

        let on = ClaudeProcessTransport.arguments(for: ClaudeLaunchConfiguration(
            providerSessionID: "session-1",
            workspaceURL: workspace,
            resumesExistingSession: false,
            chromeIntegration: true
        ))
        XCTAssertEqual(
            on,
            off + ["--chrome"],
            "The existing launch arguments stay untouched"
        )

        let resumedWithRoots = ClaudeProcessTransport.arguments(for: ClaudeLaunchConfiguration(
            providerSessionID: "session-1",
            workspaceURL: workspace,
            resumesExistingSession: true,
            additionalRoots: [URL(filePath: "/tmp/claude-chrome-extra")],
            chromeIntegration: true
        ))
        XCTAssertTrue(resumedWithRoots.contains("--resume=session-1"))
        XCTAssertEqual(
            resumedWithRoots.suffix(3),
            ["--add-dir", "/tmp/claude-chrome-extra", "--chrome"],
            "A project's extra roots keep their own argument pair"
        )
    }

    /// A context limit is the CLI's own `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, in the environment of the
    /// task's own process. The task's choice comes first; a task without one takes the limit in
    /// Settings, read as the CLI starts, and with Claude Code's default there the variable stays
    /// unset. Only a limit the menu offers gets there.
    func testAContextLimitGoesInTheEnvironmentFromTheTaskOrElseFromSettings() async throws {
        let variable = "CLAUDE_CODE_AUTO_COMPACT_WINDOW"
        XCTAssertNil(ClaudeProcessTransport.environment(base: [:], overrides: [:])[variable])
        XCTAssertEqual(ClaudeProcessTransport.environment(base: [:], overrides: [:], contextLimit: 200_000)[variable],
                       "200000")
        XCTAssertEqual(ClaudeProcessTransport.environment(base: [variable: "500000"], overrides: [:])[variable], "500000",
                       "One the person set outside Yardlet stays for a task that chose nothing")

        let cases: [(setting: UInt64?, saved: String?, launched: UInt64?)] = [
            (nil, "400000", 400_000), (nil, "600000", 600_000), (nil, "123", nil), (nil, "default", nil), (nil, nil, nil),
            (600_000, nil, 600_000), (600_000, "default", 600_000), (600_000, "200000", 200_000), (600_000, "123", 600_000)
        ]
        for (setting, saved, launched) in cases {
            let transport = FakeClaudeTransport()
            let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport },
                                        defaultContextLimit: { setting })
            let id = UUID()
            await adapter.setLaunchOptions(saved.map { [ClaudeLaunchOption.contextLimit: $0] } ?? [:], for: id)
            let handle = try await adapter.createSession(
                CreateHarnessSessionRequest(localSessionID: id, workspaceURL: workspace, initialPrompt: nil))
            let configuration = await transport.configuration
            XCTAssertEqual(configuration?.contextLimit, launched, "Settings \(String(describing: setting)), task \(saved ?? "none")")
            // Restoring the saved options after the launch is not refused.
            if let saved {
                _ = try await adapter.setProviderOption(id: ClaudeLaunchOption.contextLimit, value: saved, in: handle)
            }
            await adapter.close(handle)
        }

        // Settings writes the limit where the launch reads it, and its Claude Code default reads as none.
        let context = YardletSettingsContext(defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("ContextLimit"))))
        XCTAssertEqual(YardletSetting.claudeContextLimit.value(in: context), ClaudeLaunchOption.defaultContextLimit)
        XCTAssertNil(ClaudeContextLimitPreference.tokens(in: context.defaults))
        XCTAssertEqual(YardletSetting.claudeContextLimit.choices.map(\.value), ["default", "200000", "400000", "600000"])
        _ = await YardletSetting.claudeContextLimit.set("600000", in: context)
        XCTAssertEqual(ClaudeContextLimitPreference.tokens(in: context.defaults), 600_000)
        _ = await YardletSetting.claudeContextLimit.set(ClaudeLaunchOption.defaultContextLimit, in: context)
        XCTAssertNil(ClaudeContextLimitPreference.tokens(in: context.defaults))
    }

    /// The task's title is the name Claude Code's other sessions list and message it by. At launch it
    /// goes in the environment on one line and never as `--name`, which would also write it into the
    /// conversation as a title the person gave. A task without a title keeps the CLI's own name. A
    /// rename the person makes while the CLI runs reaches it at once, through the route the app ships,
    /// as the person's own: `rename_session` from the host, for this session only.
    func testTheTaskTitleNamesTheSessionAtLaunchAndThePersonsRenameReachesTheRunningCLI() async throws {
        let variable = "CLAUDE_CODE_SESSION_NAME"
        XCTAssertNil(ClaudeProcessTransport.environment(base: [:], overrides: [:])[variable])
        let cases: [(title: String?, launched: String?)] = [("Fix the\nlogin  bug ", "Fix the login bug"), (" \n", nil), (nil, nil)]
        for (title, launched) in cases {
            let transport = FakeClaudeTransport()
            let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport },
                                        asksForNextMessageSuggestions: { false }, defaultContextLimit: { nil })
            let id = UUID()
            await adapter.setLaunchOptions(title.map { [ClaudeLaunchOption.sessionName: $0] } ?? [:], for: id)
            let handle = try await adapter.createSession(
                CreateHarnessSessionRequest(localSessionID: id, workspaceURL: workspace, initialPrompt: nil))
            let launch = await transport.configuration
            let configuration = try XCTUnwrap(launch)
            XCTAssertEqual(ClaudeProcessTransport.environment(base: [:], overrides: [:],
                                                              sessionName: configuration.sessionName)[variable], launched)
            XCTAssertFalse(ClaudeProcessTransport.arguments(for: configuration).contains { $0 == "-n" || $0.hasPrefix("--name") })
            await adapter.close(handle)
        }

        let transport = FakeClaudeTransport()
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport },
                                   asksForNextMessageSuggestions: { false }, defaultContextLimit: { nil }),
            manifest: HarnessProtocolCompatibilityManifest.claude())
        let handle = try await routed.createSession(
            CreateHarnessSessionRequest(localSessionID: UUID(), workspaceURL: workspace, initialPrompt: nil))
        try await routed.renameRunningSession(handle, to: "Fix the\nlogin bug")
        let rename = await transport.requestedValues.last?["request"]
        XCTAssertEqual(rename, .object(["subtype": .string("rename_session"), "title": .string("Fix the login bug"),
                                        "source": .string("host"), "session_id": .string(handle.providerSessionID)]))
        await routed.close(handle)
    }

    func testTheChromeOptionIsOneOffOrOnSelectorThatStartsOff() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { _ in transport }
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: workspace,
                initialPrompt: nil
            )
        )

        let state = try await adapter.providerCapabilities(for: handle)
        let selector = try XCTUnwrap(
            state.selectors.first { $0.id == ClaudeLaunchOption.chromeIntegration }
        )
        XCTAssertEqual(selector.choices.map(\.value), [ClaudeLaunchOption.off, ClaudeLaunchOption.on])
        XCTAssertEqual(selector.currentValue, ClaudeLaunchOption.off)
        let configuration = await transport.configuration
        XCTAssertEqual(
            configuration?.chromeIntegration,
            false,
            "A task that never asked for the integration launches exactly as before"
        )
        await adapter.close(handle)
    }

    func testTurningTheOptionOnAppliesToTheNextStartRatherThanTheRunningProcess() async throws {
        let firstLocalID = UUID()
        let resumedLocalID = UUID()
        let firstTransport = FakeClaudeTransport()
        let resumedTransport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { localID in
                localID == firstLocalID ? firstTransport : resumedTransport
            }
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: firstLocalID,
                workspaceURL: workspace,
                initialPrompt: nil
            )
        )

        let updated = try await adapter.setProviderOption(
            id: ClaudeLaunchOption.chromeIntegration,
            value: ClaudeLaunchOption.on,
            in: handle
        )
        XCTAssertEqual(
            updated.selectors.first { $0.id == ClaudeLaunchOption.chromeIntegration }?.currentValue,
            ClaudeLaunchOption.on
        )
        XCTAssertEqual(
            updated.actionMessage,
            L10n.string("Claude Code applies this setting the next time the task starts")
        )
        let firstSubtypes = await firstTransport.requestSubtypes
        XCTAssertEqual(
            firstSubtypes,
            ["initialize"],
            "A launch flag is not sent to the running CLI as a session setting"
        )
        let firstConfiguration = await firstTransport.configuration
        XCTAssertEqual(firstConfiguration?.chromeIntegration, false)
        await adapter.close(handle)

        // The saved option is what the next start reads, exactly as the task stored it.
        await adapter.setLaunchOptions(
            [ClaudeLaunchOption.chromeIntegration: ClaudeLaunchOption.on],
            for: resumedLocalID
        )
        let resumed = try await adapter.resumeSession(
            providerSessionID: handle.providerSessionID,
            localSessionID: resumedLocalID,
            workspaceURL: workspace
        )
        let resumedConfiguration = await resumedTransport.configuration
        XCTAssertEqual(resumedConfiguration?.chromeIntegration, true)
        let resumedState = try await adapter.providerCapabilities(for: resumed)
        XCTAssertEqual(
            resumedState.selectors.first { $0.id == ClaudeLaunchOption.chromeIntegration }?.currentValue,
            ClaudeLaunchOption.on
        )
        await adapter.close(resumed)
    }

    func testSavedOptionsRestoreAcrossRelaunchAndOffRemovesTheFlagAgain() async throws {
        let repository = InMemorySessionRepository()
        let store = SessionStore(repository: repository)
        let session = try await store.createSession(
            harness: .claudeCode,
            workspaceURL: workspace,
            runtimeExecutableURL: URL(filePath: "/tmp/fake-claude"),
            title: "Chrome task"
        )
        try await store.updateProviderOption(
            id: session.id,
            optionID: ClaudeLaunchOption.chromeIntegration,
            value: ClaudeLaunchOption.on
        )
        let persisted = try await repository.loadSessions()
        let savedOptions = try XCTUnwrap(persisted.first?.providerOptions)
        XCTAssertEqual(savedOptions[ClaudeLaunchOption.chromeIntegration], ClaudeLaunchOption.on)

        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { _ in transport }
        )
        await adapter.setLaunchOptions(savedOptions, for: session.id)
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: session.id,
                workspaceURL: workspace,
                initialPrompt: nil
            )
        )
        let launched = await transport.configuration
        XCTAssertEqual(launched?.chromeIntegration, true)

        // Restoring the value this session already launched with announces no pending change.
        let restored = try await adapter.setProviderOption(
            id: ClaudeLaunchOption.chromeIntegration,
            value: ClaudeLaunchOption.on,
            in: handle
        )
        XCTAssertNotEqual(
            restored.actionMessage,
            L10n.string("Claude Code applies this setting the next time the task starts")
        )

        _ = try await adapter.setProviderOption(
            id: ClaudeLaunchOption.chromeIntegration,
            value: ClaudeLaunchOption.off,
            in: handle
        )
        try await store.updateProviderOption(
            id: session.id,
            optionID: ClaudeLaunchOption.chromeIntegration,
            value: ClaudeLaunchOption.off
        )
        await adapter.close(handle)

        let offTransport = FakeClaudeTransport()
        let offAdapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { _ in offTransport }
        )
        let offOptions = try XCTUnwrap(store.sessions.first?.providerOptions)
        await offAdapter.setLaunchOptions(offOptions, for: session.id)
        let offHandle = try await offAdapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: session.id,
                workspaceURL: workspace,
                initialPrompt: nil
            )
        )
        let relaunched = await offTransport.configuration
        XCTAssertEqual(relaunched?.chromeIntegration, false)
        await offAdapter.close(offHandle)
    }

    func testTheProtocolRouteTheAppShipsStillCarriesTheLaunchFlag() async throws {
        let transport = FakeClaudeTransport()
        let claude = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { _ in transport }
        )
        let routed = YHPProviderCompatibilityAdapter(
            adapter: claude,
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let localSessionID = UUID()
        let configurable = try XCTUnwrap(routed as (any HarnessLaunchOptionConfiguring)?)
        await configurable.setLaunchOptions(
            [ClaudeLaunchOption.chromeIntegration: ClaudeLaunchOption.on],
            for: localSessionID
        )
        _ = try await routed.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localSessionID,
                workspaceURL: workspace,
                initialPrompt: nil
            )
        )

        let configuration = await transport.configuration
        XCTAssertEqual(
            configuration?.chromeIntegration,
            true,
            "The option has to survive the protocol adapter the app routes Claude through"
        )
    }

    func testACLIThatRefusesTheFlagSurfacesItsOwnMessage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-claude-chrome-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "fake-claude")
        // Stands in for a CLI without the Chrome extension: it refuses the flag on stderr and
        // exits, which is the only thing Yardlet knows about the failure.
        let script = #"""
        #!/bin/sh
        for argument in "$@"; do
          if [ "$argument" = "--chrome" ]; then
            printf '%s\n' 'Error: Claude in Chrome requires the Claude extension in Chrome.' >&2
            exit 2
          fi
        done
        cat > /dev/null
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )

        let transport = ClaudeProcessTransport(
            executableURL: executable,
            requestTimeout: .seconds(5)
        )
        try await transport.start(ClaudeLaunchConfiguration(
            providerSessionID: "session-1",
            workspaceURL: root,
            resumesExistingSession: false,
            chromeIntegration: true
        ))
        // The refusal happens before any frame arrives; the stream ending is the CLI exiting.
        for await _ in await transport.messages() {}
        do {
            _ = try await transport.request(
                ClaudeProtocol.initialize(id: "initialize-1"),
                id: "initialize-1"
            )
            XCTFail("A refused launch must not report a ready session")
        } catch let error as HarnessAdapterError {
            guard case let .processExited(code, message) = error else {
                await transport.stop()
                return XCTFail("The CLI's exit is what the task reports")
            }
            XCTAssertEqual(code, 2)
            XCTAssertTrue(
                message.contains("Claude in Chrome requires the Claude extension in Chrome."),
                "The CLI's own words reach the task instead of a guess: \(message)"
            )
            XCTAssertTrue(error.localizedDescription.contains(message))
        }
        await transport.stop()
    }
}
