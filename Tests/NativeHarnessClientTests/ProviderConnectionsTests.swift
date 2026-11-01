import XCTest
@testable import NativeHarnessClient

@MainActor final class ProviderConnectionsTests: XCTestCase {
    func testSelectedAccountSurvivesDraftRestartAndSubmissionCapturesIt() throws {
        let repository = InMemoryComposerDraftRepository()
        let catalog = ProviderConnectionStore()
        let connection = ProviderConnection(id: "a", name: "A", harness: .pi,
            providerID: "anthropic", homePath: "/tmp/pi-a", credentialSelector: nil)
        try catalog.save(connection)
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false), connections: catalog,
            composerDraftRepository: repository)
        let draft = model.composerDrafts.home
        draft.text = "Preserve this input"
        draft.harness = .pi
        draft.workspaceURL = URL(filePath: "/tmp/project")
        catalog.selection[.pi] = connection.id
        model.composerDrafts.persistNow()
        XCTAssertEqual(ComposerDrafts(repository: repository).home.connectionSelection[.pi], connection.id)
        let submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: URL(filePath: "/usr/bin/true"), connection: catalog.selected(for: .pi)))
        catalog.selection[.pi] = nil
        XCTAssertEqual(submission.connection, connection)
        XCTAssertEqual(submission.originalText, "Preserve this input")
    }

    func testAHostClaudeSessionsVariablesAreNotInheritedButOrdinaryOnesAre() {
        let host = ["CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDE_CODE_SESSION_ID": "x",
                    "CLAUDE_CONFIG_DIR": "/accounts/a", "ENABLE_CLAUDEAI_MCP_SERVERS": "false", "CLAUDE_AGENT_SDK_VERSION": "1",
                    "HOME": "/Users/me", "PATH": "/usr/bin", "SSH_AUTH_SOCK": "/tmp/agent"]
        XCTAssertEqual(HostSessionEnvironment.hostVariables(in: host), ["CLAUDECODE", "CLAUDE_AGENT_SDK_VERSION",
            "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CONFIG_DIR", "ENABLE_CLAUDEAI_MCP_SERVERS"])
        XCTAssertEqual(HostSessionEnvironment.hostVariables(in: ["CLAUDE_CONFIG_DIR": "/mine", "HOME": "/Users/me"]), [],
            "Without a host session a person's own setting is kept")
    }

    func testMetadataRoundTripAndCorruptionNeverOverwriteAuthOrOriginalStore() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appending(path: "auth.json")
        try Data("fixture-secret-must-stay-here".utf8).write(to: auth)
        let url = root.appending(path: "connections.json")
        let store = ProviderConnectionStore(fileURL: url)
        let connection = try store.add(name: "Work", harness: .pi, home: root, providerID: "anthropic")
        let reopened = ProviderConnectionStore(fileURL: url)
        XCTAssertEqual(reopened.connections, [connection])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("fixture-secret"))
        // A removed harness's saved accounts and remembered readings are dropped when the store
        // loads; the other accounts stay and the store still reads.
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        saved.append(["id": "gjc:/tmp/gjc:anthropic/id:1", "name": "Removed", "harness": "gajae-code",
                      "providerID": "anthropic", "homePath": "/tmp/gjc", "credentialSelector": "anthropic/id:1"])
        try JSONSerialization.data(withJSONObject: saved).write(to: url)
        let readings = root.appending(path: "readings.json")
        try Data(#"{"version":1,"entries":{"native:oh-my-pi":{"harness":"oh-my-pi","state":"signedOut","checkedAt":"2026-10-01T00:00:00Z","usage":[]}}}"#.utf8)
            .write(to: readings)
        let pruned = ProviderConnectionStore(fileURL: url, snapshotCacheURL: readings)
        XCTAssertEqual(pruned.connections, [connection])
        XCTAssertNil(pruned.errorMessage)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("gajae-code"))
        XCTAssertFalse(try String(contentsOf: readings, encoding: .utf8).contains("oh-my-pi"))
        let corrupt = Data("not valid json".utf8)
        try corrupt.write(to: url)
        let broken = ProviderConnectionStore(fileURL: url)
        XCTAssertThrowsError(try broken.save(connection))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertEqual(try String(contentsOf: auth, encoding: .utf8), "fixture-secret-must-stay-here")
    }

    func testCodexWindowsRemainSeparateAndMissingUsageIsNotZero() {
        let usage = HarnessAccountBroker.codexRateLimitUsage(from: .object(["rateLimitsByLimitId": .object([
            "codex": .object(["primary": .object(["usedPercent": .integer(10), "windowDurationMins": .integer(300)]),
                "secondary": .object(["usedPercent": .integer(97), "windowDurationMins": .integer(10_080)])]),
            "unknown": .object(["primary": .object(["resetsAt": .integer(42)])])
        ])]))
        XCTAssertEqual(usage.map(\.id), ["codex:primary", "codex:secondary"])
        XCTAssertEqual(usage.map(\.usedFraction), [0.1, 0.97])
        XCTAssertEqual(usage.map(\.label), [L10n.format("%.0f hour limit", 5.0), L10n.format("%.0f day limit", 7.0)],
                       "A bucket without windows does not make the one that has them need its name")
    }

    func testExplicitAccountEnvironmentDoesNotUseInheritedModelCredentials() throws {
        let connection = ProviderConnection(id: "claude-b", name: "B", harness: .claudeCode,
            providerID: nil, homePath: "/tmp/account-b", credentialSelector: nil)
        let base = ["HOME": "/tmp/native", "ANTHROPIC_API_KEY": "dummy", "OPENAI_API_KEY": "dummy", "GIT_AUTHOR_NAME": "kept"]
        let values = RuntimeProcessEnvironment.values(executableURL: URL(filePath: "/tmp/claude"), base: base, overrides: connection.environment)
        XCTAssertNil(values["ANTHROPIC_API_KEY"])
        XCTAssertNil(values["OPENAI_API_KEY"])
        XCTAssertEqual(values["GIT_AUTHOR_NAME"], "kept")
        XCTAssertEqual(values["HOME"], "/tmp/native")
        XCTAssertEqual(values["CLAUDE_CONFIG_DIR"], "/tmp/account-b")
        XCTAssertThrowsError(try connection.validate(for: .pi))

        // Kimi Code and Grok Build move their login and history with one variable each; Cursor
        // Agent and Antigravity CLI keep their login in one fixed Keychain item, so they take none.
        for (harness, variable) in [(HarnessKind.kimiCode, "KIMI_CODE_HOME"), (.grokBuild, "GROK_HOME")] {
            let account = ProviderConnection(id: "\(harness.rawValue)-b", name: "B", harness: harness,
                providerID: nil, homePath: "/tmp/account-b", credentialSelector: nil)
            XCTAssertNoThrow(try account.validate(for: harness))
            let launched = RuntimeProcessEnvironment.values(executableURL: URL(filePath: "/tmp/cli"),
                base: base.merging(["XAI_API_KEY": "dummy"]) { $1 }, overrides: account.environment)
            XCTAssertEqual(launched[variable], "/tmp/account-b")
            XCTAssertNil(launched["XAI_API_KEY"])
        }
        for harness in [HarnessKind.cursorAgent, .antigravityCLI, .museCode] {
            XCTAssertThrowsError(try ProviderConnection(id: "b", name: "B", harness: harness, providerID: nil,
                homePath: "/tmp/account-b", credentialSelector: nil).validate(for: harness))
        }
    }

    func testAccountLoginAndProbeReceiveSamePiProviderAndHome() async throws {
        let connection = ProviderConnection(id: "pi-a", name: "A", harness: .pi,
            providerID: "anthropic", homePath: "/tmp/pi-a", credentialSelector: nil)
        let broker = HarnessAccountBroker(connection: connection)
        let result = await broker.loginCommand(for: .pi, executableURL: URL(filePath: "/tmp/pi"))
        let command = try XCTUnwrap(result)
        XCTAssertEqual(command.initialInput, "/login anthropic\r")
        XCTAssertEqual(command.environment["PI_CODING_AGENT_DIR"], "/tmp/pi-a")
        XCTAssertEqual(connection.launchArguments, ["--provider", "anthropic"])
    }
}
