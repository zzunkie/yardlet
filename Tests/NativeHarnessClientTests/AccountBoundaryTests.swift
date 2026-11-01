import Foundation
import Security
import XCTest
@testable import NativeHarnessClient

@MainActor
final class AccountBoundaryTests: XCTestCase {
    func testSignedOutCodexAccountDoesNotRequireAuthenticatedUsageReads() {
        let account: JSONValue = .object(["account": .null])

        XCTAssertFalse(HarnessAccountBroker.codexAccountIsSignedIn(account))

        let snapshot = HarnessAccountBroker.codexSnapshot(
            account: account,
            rateLimits: nil,
            accountUsage: nil
        )
        XCTAssertEqual(snapshot.state, .signedOut)
        XCTAssertTrue(snapshot.canLogin)
        XCTAssertFalse(snapshot.canLogout)
    }

    func testPiAccountCheckDoesNotRequestCredentialMaterial() async {
        let broker = HarnessAccountBroker()
        let command = await broker.loginCommand(
            for: .pi,
            executableURL: URL(filePath: "/tmp/pi")
        )
        XCTAssertEqual(command?.initialInput, "/login\r")
        XCTAssertFalse(command?.arguments.contains("--credentials") ?? true)
    }

    func testOpenCodeConnectPreservesProviderPicker() async {
        let broker = HarnessAccountBroker()
        let command = await broker.loginCommand(
            for: .openCode,
            executableURL: URL(filePath: "/tmp/opencode")
        )

        XCTAssertEqual(command?.arguments, ["auth", "login"])
        XCTAssertEqual(command?.interaction, .terminalRequired)
        XCTAssertNil(command?.initialInput)
    }

    func testAntigravityLoginUsesOfficialAgyAndExplainsQuietBrowserHandoff() async {
        let broker = HarnessAccountBroker()
        let command = await broker.loginCommand(
            for: .antigravityCLI,
            executableURL: URL(filePath: "/tmp/agy")
        )

        XCTAssertEqual(command?.arguments, [])
        XCTAssertEqual(command?.initialInput, "\r")
        XCTAssertEqual(command?.initialInputTrigger, "Select login method:")
        XCTAssertEqual(command?.usesPseudoTerminal, true)
        XCTAssertEqual(command?.interaction, .guided)
        XCTAssertTrue(command?.startupMessage?.contains("Antigravity") ?? false)
        let legacyCommand = await broker.loginCommand(
            for: .antigravityCLI,
            executableURL: URL(filePath: "/tmp/antigravity")
        )
        XCTAssertNil(legacyCommand)
    }

    func testOpenCodeProviderStateRequiresStoredConnectionInsteadOfInheritedEnvironmentKey() {
        let environmentBackedProvider = """
        Credentials ~/.local/share/opencode/auth.json
        0 credentials

        Environment
        Google GEMINI_API_KEY
        1 environment variable
        """
        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .openCode,
                result: AccountCommandResult(exitCode: 0, output: environmentBackedProvider)
            ),
            .signedOut
        )
        XCTAssertEqual(
            HarnessAccountBroker.openCodeProviderEvidence(from: environmentBackedProvider.lowercased()),
            HarnessAccountBroker.OpenCodeProviderEvidence(
                persistedCredentialCount: 0,
                environmentVariableCount: 1
            )
        )
        XCTAssertEqual(
            HarnessAccountBroker.openCodePersistedCredentialCount(
                from: environmentBackedProvider.lowercased()
            ),
            0
        )
        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .openCode,
                result: AccountCommandResult(
                    exitCode: 0,
                    output: "0 credentials\n0 environment variables\n"
                )
            ),
            .signedOut
        )
        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .openCode,
                result: AccountCommandResult(
                    exitCode: 0,
                    output: "1 credential\n0 environment variables\n"
                )
            ),
            .signedIn
        )
    }

    func testOpenCodeProviderEvidenceReadsDecoratedCountFooterInsteadOfCredentialsHeading() {
        // OpenCode 1.18.18 keeps the box-drawing heading even with NO_COLOR=1.
        for count in [0, 1, 12] {
            let output = """
            \u{1B}[0m
            ┌  Credentials \u{1B}[90m/Users/person2026/.local/share/opencode/auth.json
            │
            └  \(count) credentials

            ┌  Environment
            │
            ●  Google \u{1B}[90mGEMINI_API_KEY
            │
            └  1 environment variable
            """
            let normalized = AccountLoginController.stripANSI(output).lowercased()
            XCTAssertEqual(
                HarnessAccountBroker.openCodeProviderEvidence(from: normalized),
                .init(persistedCredentialCount: count, environmentVariableCount: 1)
            )
            XCTAssertEqual(
                HarnessAccountBroker.commandAccountState(
                    for: .openCode,
                    result: AccountCommandResult(exitCode: 0, output: output)
                ),
                count > 0 ? .signedIn : .signedOut
            )
        }
    }

    func testOpenCodeProviderEvidenceDoesNotInferCountFromHeadingOrUnrelatedNumbers() {
        for output in [
            "┌  Credentials /Users/person2026/.local/share/opencode/auth.json",
            "OpenCode 1.18.18\nWarning: failed to read 2 credentials",
            "●  Provider 3 credentials oauth",
            "└  1 credentials unavailable"
        ] {
            XCTAssertNil(HarnessAccountBroker.openCodeProviderEvidence(from: output.lowercased()))
            XCTAssertEqual(
                HarnessAccountBroker.commandAccountState(
                    for: .openCode,
                    result: AccountCommandResult(exitCode: 0, output: output)
                ),
                .unknown
            )
        }
    }

    func testOpenCodeDecoratedAuthListPublishesConnectedSnapshotThroughCommandRunner() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "opencode")
        try Data("""
        #!/bin/sh
        [ "$1" = "auth" ] && [ "$2" = "list" ] || exit 2
        cat <<'OUTPUT'
        ┌  Credentials ~/.local/share/opencode/auth.json
        │
        ●  OpenAI oauth
        │
        └  1 credentials
        OUTPUT
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let descriptor = try XCTUnwrap(HarnessCatalog.builtIns.first { $0.id == .openCode })
        let snapshot = await HarnessAccountBroker().snapshot(for: descriptor, executableURL: executable)
        XCTAssertEqual(snapshot.state, .signedIn)
        XCTAssertTrue(snapshot.canLogout)
        XCTAssertTrue(snapshot.canLogin)
    }

    func testAntigravityAccountTruthUsesKeychainItemIdentityWithoutCredentialData() {
        XCTAssertEqual(
            HarnessAccountBroker.antigravityCredentialState(keychainStatus: errSecSuccess),
            .signedIn
        )
        XCTAssertEqual(
            HarnessAccountBroker.antigravityCredentialState(keychainStatus: errSecItemNotFound),
            .signedOut
        )
        XCTAssertEqual(
            HarnessAccountBroker.antigravityCredentialState(keychainStatus: errSecInteractionNotAllowed),
            .unknown
        )
    }

    func testMuseCodeAccountBoundaryFailsClosedWithoutReadingCredentials() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-muse-account-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "muse")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .museCode))
        let broker = HarnessAccountBroker()
        let snapshot = await broker.snapshot(for: descriptor, executableURL: executable)

        XCTAssertEqual(snapshot.state, .unknown)
        XCTAssertEqual(snapshot.harness, .museCode)
        XCTAssertTrue(snapshot.canLogin)
        XCTAssertFalse(snapshot.canLogout)
        let loginCommand = await broker.loginCommand(
            for: .museCode,
            executableURL: executable
        )
        let logoutCommand = await broker.logoutCommand(
            for: .museCode,
            executableURL: executable
        )
        XCTAssertEqual(loginCommand?.arguments, ["login"])
        XCTAssertNil(loginCommand?.initialInput)
        // `muse logout` removes the saved Meta credential; it is offered once a login is read.
        XCTAssertEqual(logoutCommand?.arguments, ["logout"])
    }

    func testProviderConnectionPresentationDoesNotCallOpenCodeOrPiAProductAccount() {
        let openCode = HarnessAccountSnapshot(
            id: "opencode",
            harness: .openCode,
            providerID: nil,
            state: .signedOut,
            accountLabel: nil,
            detail: "No provider",
            credentialOwner: "OpenCode",
            checkedAt: Date(timeIntervalSince1970: 0),
            usage: [],
            canLogin: true,
            canLogout: false
        )
        let codex = HarnessAccountSnapshot.unavailable(
            for: HarnessCatalog.descriptor(for: .codex)!
        )

        XCTAssertEqual(
            AccountConnectionPresentation.status(for: openCode),
            L10n.string("Provider not connected")
        )
        XCTAssertEqual(
            AccountConnectionPresentation.connectAction(for: .pi),
            L10n.string("Connect provider")
        )
        XCTAssertEqual(
            AccountConnectionPresentation.connectAction(for: .codex),
            L10n.string("Sign in")
        )
        XCTAssertEqual(AccountConnectionPresentation.status(for: codex), codex.state.displayName)
        XCTAssertTrue(AccountConnectionPresentation.usesProviderLanguage(.hermes))
    }

    func testProviderAccessibilityUsesConnectionLanguage() {
        let snapshot = HarnessAccountSnapshot(
            id: "pi:openai-codex",
            harness: .pi,
            providerID: "openai-codex",
            state: .signedIn,
            accountLabel: nil,
            detail: "OAuth ready",
            credentialOwner: "Pi",
            checkedAt: Date(timeIntervalSince1970: 0),
            usage: [],
            canLogin: false,
            canLogout: true
        )

        let value = AccountAccessibilityProjection.value(for: snapshot)
        XCTAssertTrue(value.contains(L10n.string("Provider connected")))
        XCTAssertFalse(value.contains(L10n.string("Signed in")))
    }

    func testSuccessfulModelOrProviderListingDoesNotProveAuthentication() {
        let successfulListing = AccountCommandResult(
            exitCode: 0,
            output: "Available models:\nmodel-a\nmodel-b\n"
        )

        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .grokBuild,
                result: successfulListing
            ),
            .unknown
        )
        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .antigravityCLI,
                result: successfulListing
            ),
            .unknown
        )
        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .kimiCode,
                result: AccountCommandResult(
                    exitCode: 0,
                    output: "Providers:\nmoonshot\nopenai\n"
                )
            ),
            .unknown
        )
        // Kimi Code 0.36's own rows: `kimi login` adds the managed provider; none is signed out.
        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .kimiCode,
                result: AccountCommandResult(
                    exitCode: 0,
                    output: "managed:kimi-code  type=kimi  models=3  source=oauth\n\nDefault model: kimi-code/k2\n"
                )
            ),
            .signedIn
        )
        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .kimiCode,
                result: AccountCommandResult(exitCode: 0, output: "No providers configured.\n")
            ),
            .signedOut
        )
    }

    func testCommandAccountStateRequiresExplicitPositiveOrNegativeEvidence() {
        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .claudeCode,
                result: AccountCommandResult(
                    exitCode: 0,
                    output: #"{"loggedIn":true,"subscriptionType":"pro"}"#
                )
            ),
            .signedIn
        )
        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .cursorAgent,
                result: AccountCommandResult(exitCode: 0, output: "Logged in as owner@example.test")
            ),
            .signedIn
        )
        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .cursorAgent,
                result: AccountCommandResult(
                    exitCode: 0,
                    output: #"{"status":"authenticated","message":"Logged in"}"#
                )
            ),
            .signedIn
        )
        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .cursorAgent,
                result: AccountCommandResult(
                    exitCode: 0,
                    output: #"{"status":"unauthenticated","message":"Not logged in"}"#
                )
            ),
            .signedOut
        )
        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .openCode,
                result: AccountCommandResult(exitCode: 0, output: "0 credentials")
            ),
            .signedOut
        )
        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .claudeCode,
                result: AccountCommandResult(
                    exitCode: 0,
                    output: #"{"loggedIn": false}"#
                )
            ),
            .signedOut
        )
        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .openCode,
                result: AccountCommandResult(exitCode: 1, output: "unexpected response")
            ),
            .unknown
        )
    }

    func testGrokCredentialPresenceUsesMetadataWithoutReadingCredentialValues() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            HarnessAccountBroker.grokCredentialState(
                environment: ["GROK_HOME": root.path(percentEncoded: false)],
                fileManager: .default
            ),
            .signedOut
        )
        let authURL = root.appending(path: "auth.json")
        try Data("opaque credential payload".utf8).write(to: authURL)
        XCTAssertEqual(
            HarnessAccountBroker.grokCredentialState(
                environment: ["GROK_HOME": root.path(percentEncoded: false)],
                fileManager: .default
            ),
            .signedIn
        )
    }

    func testGrokEnvironmentAPIKeyCountsAsConfiguredWithoutPersistedOAuth() {
        XCTAssertEqual(
            HarnessAccountBroker.grokCredentialState(
                environment: ["XAI_API_KEY": "configured"],
                fileManager: .default
            ),
            .signedIn
        )
    }

    func testStructuredAccountTruthWinsOverUnrelatedCommandNoise() {
        let output = """
        Warning: optional helper is not authenticated.
        {
          "loggedIn": true,
          "authMethod": "claude.ai",
          "email": "owner@example.test"
        }
        Update check complete.
        """

        XCTAssertEqual(
            HarnessAccountBroker.commandAccountState(
                for: .claudeCode,
                result: AccountCommandResult(exitCode: 0, output: output)
            ),
            .signedIn
        )
    }

    func testLoginOutputStripsTerminalEscapesAndFindsDeviceURL() {
        let value = "\u{1B}[32mOpen https://auth.example.test/device\u{1B}[0m\r\n"
        XCTAssertEqual(
            AccountLoginController.stripANSI(value),
            "Open https://auth.example.test/device\n"
        )
        XCTAssertEqual(
            AccountLoginController.firstHTTPSURL(in: value)?.absoluteString,
            "https://auth.example.test/device"
        )
        XCTAssertTrue(AccountLoginController.outputRequiresInput(
            "Login method\n● ChatGPT Pro/Plus (browser)\n○ Manually enter API Key"
        ))
        XCTAssertTrue(AccountLoginController.outputRequiresInput("Select authentication method for Anthropic:"))
        XCTAssertFalse(AccountLoginController.outputRequiresInput(
            "Preparing browser authentication…"
        ))
    }

    func testSnapshotsEncodeNoCredentialFields() throws {
        let snapshot = HarnessAccountSnapshot(
            id: "pi:openai-codex",
            harness: .pi,
            providerID: "openai-codex",
            state: .signedOut,
            accountLabel: nil,
            detail: "credentials_not_configured",
            credentialOwner: "Pi",
            checkedAt: Date(timeIntervalSince1970: 0),
            usage: [],
            canLogin: true,
            canLogout: false
        )
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("access_token"))
        XCTAssertFalse(encoded.contains("refresh_token"))
        XCTAssertFalse(encoded.contains("apiKey"))
    }

    func testCodexAccountUsageProjectsLockedSummaryAndDailyBuckets() {
        let usage = HarnessAccountBroker.codexAccountUsage(from: .object([
            "summary": .object([
                "lifetimeTokens": .integer(12_345),
                "peakDailyTokens": .integer(900),
                "currentStreakDays": .integer(3),
                "longestStreakDays": .integer(8)
            ]),
            "dailyUsageBuckets": .array([
                .object([
                    "startDate": .string("2026-08-15"),
                    "tokens": .integer(420)
                ])
            ])
        ]))

        XCTAssertEqual(
            usage.map(\.id),
            [
                "account-lifetime",
                "account-peak-daily",
                "account-current-streak",
                "account-longest-streak",
                "account-daily-2026-08-15"
            ]
        )
        XCTAssertEqual(usage[0].detail, L10n.format("%lld tokens", Int64(12_345)))
        XCTAssertEqual(usage[2].detail, L10n.format("%lld days", Int64(3)))
        XCTAssertTrue(usage.allSatisfy { $0.evidence == .accountUsage })
        XCTAssertTrue(usage.allSatisfy { $0.usedFraction == nil })
    }

    func testCodexAccountUsageIgnoresUnsupportedOrPartialRows() {
        let usage = HarnessAccountBroker.codexAccountUsage(from: .object([
            "summary": .object(["lifetimeTokens": .string("not-an-integer")]),
            "dailyUsageBuckets": .array([
                .object(["startDate": .string("missing-tokens")]),
                .object(["tokens": .integer(10)])
            ])
        ]))

        XCTAssertTrue(usage.isEmpty)
    }

    func testAccountUsageOverviewPromotesOnlyAccountHistoryAndSortsStably() {
        let codex = HarnessAccountSnapshot(
            id: "codex",
            harness: .codex,
            providerID: "openai-codex",
            state: .signedIn,
            accountLabel: "owner@example.test",
            detail: "ChatGPT pro plan",
            credentialOwner: "Codex CLI",
            checkedAt: Date(timeIntervalSince1970: 0),
            usage: [
                AccountUsageMetric(
                    id: "codex-quota",
                    label: "Quota",
                    usedFraction: 0.25,
                    detail: "25% used",
                    resetsAt: nil,
                    evidence: .exactQuota
                ),
                AccountUsageMetric(
                    id: "account-lifetime",
                    label: "Lifetime tokens",
                    usedFraction: nil,
                    detail: "12,345 tokens",
                    resetsAt: nil,
                    evidence: .accountUsage
                )
            ],
            canLogin: false,
            canLogout: true
        )
        let pi = HarnessAccountSnapshot(
            id: "pi:openai-codex",
            harness: .pi,
            providerID: "openai-codex",
            state: .signedIn,
            accountLabel: "owner@example.test",
            detail: "Codex account",
            credentialOwner: "Pi",
            checkedAt: Date(timeIntervalSince1970: 0),
            usage: [
                AccountUsageMetric(
                    id: "account-daily-2026-08-15",
                    label: "2026-08-15",
                    usedFraction: nil,
                    detail: "420 tokens",
                    resetsAt: nil,
                    evidence: .accountUsage
                )
            ],
            canLogin: false,
            canLogout: true
        )

        let rows = AccountUsageOverviewProjection.rows(from: [pi, codex])

        XCTAssertEqual(
            rows.map(\.id),
            ["codex:account-lifetime", "pi:openai-codex:account-daily-2026-08-15"]
        )
        XCTAssertTrue(rows.allSatisfy { $0.metric.evidence == .accountUsage })
        XCTAssertTrue(rows.allSatisfy { $0.metric.usedFraction == nil })
    }

    func testLocalSessionUsageProjectsExactCodexBreakdownWithoutQuotaClaim() throws {
        let session = SessionRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000AA01")!,
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/yardlet-fixture"),
            runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
            title: "Local task",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            providerSessionID: "thread-local"
        )
        let usage = CodexThreadTokenUsage(
            total: CodexTokenUsageBreakdown(
                inputTokens: 100,
                cachedInputTokens: 20,
                cacheWriteInputTokens: 4,
                outputTokens: 50,
                reasoningOutputTokens: 10,
                totalTokens: 164
            ),
            last: CodexTokenUsageBreakdown(
                inputTokens: 40,
                cachedInputTokens: 8,
                cacheWriteInputTokens: 2,
                outputTokens: 20,
                reasoningOutputTokens: 5,
                totalTokens: 67
            ),
            modelContextWindow: 128_000
        )
        let state = CodexTaskState(
            thread: CodexThreadState(
                id: "thread-local",
                sessionID: "thread-local",
                name: nil,
                preview: "",
                workspacePath: session.workspaceURL.path,
                cliVersion: nil,
                modelProvider: nil,
                parentThreadID: nil,
                forkedFromID: nil,
                status: .idle,
                canAcceptDirectInput: true,
                createdAt: nil,
                updatedAt: nil,
                turns: [CodexTurnState(
                    id: "turn-local",
                    status: .completed,
                    startedAt: nil,
                    completedAt: nil,
                    durationMilliseconds: nil,
                    itemsView: .full,
                    items: [],
                    itemsNextCursor: nil,
                    plan: nil,
                    tokenUsage: usage,
                    error: nil,
                    raw: .object([:])
                )],
                turnsNextCursor: nil,
                turnsBackwardsCursor: nil,
                itemsBackwardsCursor: nil,
                raw: .object([:])
            )
        )

        let overview = try XCTUnwrap(
            LocalSessionUsageProjection.overview(session: session, state: state)
        )

        XCTAssertEqual(overview.sessionID, session.id)
        XCTAssertEqual(overview.taskTitle, session.title)
        XCTAssertEqual(overview.metrics.map(\.id), [
            "local-last-total",
            "local-cumulative-total",
            "local-last-input",
            "local-last-cached-input",
            "local-last-cache-hit",
            "local-last-cache-write",
            "local-last-output",
            "local-last-reasoning",
            "local-context-window"
        ])
        XCTAssertEqual(overview.metrics.first?.detail, L10n.format("%lld tokens", Int64(67)))
        XCTAssertEqual(
            overview.metrics.first(where: { $0.id == "local-last-cache-hit" })?.detail,
            L10n.format("%.1f%% of input", 20.0)
        )
        XCTAssertTrue(overview.metrics.allSatisfy { $0.evidence == .localSession })
        XCTAssertTrue(overview.metrics.allSatisfy { $0.usedFraction == nil && $0.resetsAt == nil })
    }

    func testCacheHitFractionRequiresProviderCountsToFormAValidSubset() {
        func usage(input: Int64, cached: Int64) -> CodexTokenUsageBreakdown {
            CodexTokenUsageBreakdown(
                inputTokens: input,
                cachedInputTokens: cached,
                cacheWriteInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: input
            )
        }

        XCTAssertEqual(usage(input: 40, cached: 8).cacheHitFraction, 0.2)
        XCTAssertEqual(usage(input: 40, cached: 0).cacheHitFraction, 0)
        XCTAssertNil(usage(input: 0, cached: 0).cacheHitFraction)
        XCTAssertNil(usage(input: 40, cached: -1).cacheHitFraction)
        XCTAssertNil(usage(input: 40, cached: 41).cacheHitFraction)
    }

    func testLocalSessionUsageDoesNotInventDataForOtherHarnessOrMissingUsage() {
        let session = SessionRecord(
            id: UUID(),
            harness: .claudeCode,
            workspaceURL: URL(filePath: "/tmp/yardlet-fixture"),
            runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
            title: "Claude task",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            providerSessionID: nil
        )

        XCTAssertNil(LocalSessionUsageProjection.overview(session: session, state: .empty))
        XCTAssertNil(LocalSessionUsageProjection.overview(session: nil, state: .empty))
    }

    func testAccountAccessibilityProjectionCombinesOnlyNonSecretCardFields() throws {
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .codex))
        let snapshot = HarnessAccountSnapshot(
            id: descriptor.id.rawValue,
            harness: descriptor.id,
            providerID: "openai-codex",
            state: .signedIn,
            accountLabel: "fixture@example.test",
            detail: "Pro plan",
            credentialOwner: "Codex CLI",
            checkedAt: Date(timeIntervalSince1970: 1_755_321_600),
            usage: [],
            canLogin: false,
            canLogout: true
        )

        let value = AccountAccessibilityProjection.value(for: snapshot)
        XCTAssertTrue(value.contains(snapshot.state.displayName))
        XCTAssertTrue(value.contains(snapshot.detail))
        XCTAssertTrue(value.contains(snapshot.providerID ?? ""))
        XCTAssertTrue(value.contains(snapshot.credentialOwner))
        XCTAssertTrue(value.contains(snapshot.accountLabel ?? ""))
    }

    func testAccountUsageAccessibilityProjectionCombinesEvidenceDetailAndReset() {
        let metric = AccountUsageMetric(
            id: "codex-quota",
            label: "Codex weekly",
            usedFraction: 0.42,
            detail: "42% used",
            resetsAt: Date(timeIntervalSince1970: 1_755_321_600),
            evidence: .exactQuota
        )

        let value = AccountUsageAccessibilityProjection.value(for: metric)

        XCTAssertTrue(value.contains(metric.evidence.displayName))
        XCTAssertTrue(value.contains(metric.detail))
        XCTAssertTrue(value.contains(L10n.format(
            "Resets %@",
            metric.resetsAt!.formatted(date: .abbreviated, time: .shortened)
        )))
    }

    func testAccountUsageAccessibilityProjectionDoesNotInventResetForHistoryMetric() {
        let metric = AccountUsageMetric(
            id: "account-lifetime",
            label: "Lifetime tokens",
            usedFraction: nil,
            detail: "12,345 tokens",
            resetsAt: nil,
            evidence: .accountUsage
        )

        let value = AccountUsageAccessibilityProjection.value(for: metric)

        XCTAssertTrue(value.contains(metric.evidence.displayName))
        XCTAssertTrue(value.contains(metric.detail))
        XCTAssertEqual(value, [metric.evidence.displayName, metric.detail].joined(separator: ", "))
    }

    func testCodexRateLimitUsageFallsBackToInstalledSingleBucketView() {
        let usage = HarnessAccountBroker.codexRateLimitUsage(from: .object([
            "rateLimits": .object([
                "limitId": .string("codex"),
                "limitName": .string("Codex weekly"),
                "primary": .object([
                    "usedPercent": .integer(42),
                    "resetsAt": .integer(1_800_000_000)
                ])
            ])
        ]))

        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.id, "codex:primary")
        XCTAssertEqual(usage.first?.usedFraction, 0.42)
        XCTAssertEqual(usage.first?.detail, L10n.format("%.0f%% remaining", 58.0))
        XCTAssertEqual(usage.first?.evidence, .exactQuota)
    }

    func testCodexRateLimitUsagePrefersKeyedBucketsWhenBothViewsExist() {
        let usage = HarnessAccountBroker.codexRateLimitUsage(from: .object([
            "rateLimits": .object([
                "limitId": .string("legacy"),
                "primary": .object(["usedPercent": .integer(99)])
            ]),
            "rateLimitsByLimitId": .object([
                "codex": .object([
                    "limitName": .string("Codex"),
                    "primary": .object(["usedPercent": .integer(7)])
                ])
            ])
        ]))

        XCTAssertEqual(usage.map(\.id), ["codex:primary"])
        XCTAssertEqual(usage.first?.usedFraction, 0.07)
    }

    func testCodexRateLimitNotificationMergesSparseWindowWithoutErasingMetadata() {
        let previous = JSONValue.object([
            "rateLimits": .object([
                "limitId": .string("codex"),
                "limitName": .string("Codex weekly"),
                "planType": .string("pro"),
                "primary": .object([
                    "usedPercent": .integer(42),
                    "resetsAt": .integer(1_800_000_000),
                    "windowDurationMins": .integer(10_080)
                ])
            ]),
            "rateLimitsByLimitId": .object([
                "codex": .object([
                    "limitId": .string("codex"),
                    "limitName": .string("Codex weekly"),
                    "primary": .object([
                        "usedPercent": .integer(42),
                        "resetsAt": .integer(1_800_000_000)
                    ])
                ])
            ])
        ])
        let update = JSONValue.object([
            "rateLimits": .object([
                "limitId": .string("codex"),
                "limitName": .null,
                "primary": .object([
                    "usedPercent": .integer(75),
                    "resetsAt": .null
                ])
            ])
        ])

        let merged = HarnessAccountBroker.mergedCodexRateLimits(
            previous: previous,
            update: update
        )
        XCTAssertEqual(merged?["rateLimits"]?["limitName"]?.stringValue, "Codex weekly")
        XCTAssertEqual(merged?["rateLimits"]?["primary"]?["usedPercent"]?.integerValue, 75)
        XCTAssertEqual(
            merged?["rateLimits"]?["primary"]?["resetsAt"]?.integerValue,
            1_800_000_000
        )
        XCTAssertEqual(
            merged?["rateLimitsByLimitId"]?["codex"]?["primary"]?["usedPercent"]?.integerValue,
            75
        )
    }

    func testCodexRateLimitNotificationDoesNotGuessAmongMultipleUnknownBuckets() {
        let previous = JSONValue.object([
            "rateLimits": .object([
                "primary": .object(["usedPercent": .integer(12)])
            ]),
            "rateLimitsByLimitId": .object([
                "codex": .object(["primary": .object(["usedPercent": .integer(12)])]),
                "other": .object(["primary": .object(["usedPercent": .integer(34)])])
            ])
        ])
        let update = JSONValue.object([
            "rateLimits": .object([
                "primary": .object(["usedPercent": .integer(90)])
            ])
        ])

        let merged = HarnessAccountBroker.mergedCodexRateLimits(
            previous: previous,
            update: update
        )
        XCTAssertEqual(
            merged?["rateLimitsByLimitId"]?["codex"]?["primary"]?["usedPercent"]?.integerValue,
            12
        )
        XCTAssertEqual(
            merged?["rateLimitsByLimitId"]?["other"]?["primary"]?["usedPercent"]?.integerValue,
            34
        )
    }

    func testCodexAccountMonitorPublishesInitialSnapshotAndSparseUpdates() async throws {
        let transport = FakeCodexAccountTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "account/read": [
                .object([
                    "account": .object([
                        "email": .string("owner@example.test"),
                        "planType": .string("pro")
                    ])
                ]),
                .object([
                    "account": .object([
                        "email": .string("updated@example.test"),
                        "planType": .string("team")
                    ])
                ])
            ],
            "account/rateLimits/read": [.object([
                "rateLimits": .object([
                    "limitId": .string("codex"),
                    "limitName": .string("Codex weekly"),
                    "primary": .object(["usedPercent": .integer(20)])
                ])
            ])]
        ])
        let monitor = CodexAccountMonitor(
            executableURL: URL(filePath: "/tmp/codex"),
            transport: transport
        )
        let stream = try await monitor.start()
        var iterator = stream.makeAsyncIterator()
        let initialValue = await iterator.next()
        let initial = try XCTUnwrap(initialValue)
        XCTAssertEqual(initial.accountLabel, "owner@example.test")
        XCTAssertEqual(initial.usage.first?.usedFraction, 0.2)

        await transport.emit(
            method: "account/rateLimits/updated",
            params: .object([
                "rateLimits": .object([
                    "limitId": .string("codex"),
                    "primary": .object(["usedPercent": .integer(80)])
                ])
            ])
        )
        let updatedValue = await iterator.next()
        let updated = try XCTUnwrap(updatedValue)
        XCTAssertEqual(updated.usage.first?.usedFraction, 0.8)

        await transport.emit(
            method: "account/updated",
            params: .object(["planType": .string("team")])
        )
        let accountUpdatedValue = await iterator.next()
        let accountUpdated = try XCTUnwrap(accountUpdatedValue)
        XCTAssertEqual(accountUpdated.accountLabel, "updated@example.test")

        await monitor.stop()
        let didStop = await transport.didStop
        XCTAssertTrue(didStop)
        let requestMethods = await transport.requestMethods
        XCTAssertFalse(requestMethods.contains("thread/start"))
        XCTAssertFalse(requestMethods.contains("turn/start"))
    }

    /// Codex resets go through each account's own App Server (`scripts/fixtures/codex-usage-reset.py`):
    /// the count and the reset that expires first come with the limits, a use names that reset and
    /// one attempt ID, the account is read again afterwards, an attempt without an answer is sent
    /// again with the same ID, and another account's home sees none of it.
    func testCodexResetsAreReadAndUsedUnderEachAccountsOwnLogin() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-usage-reset-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "codex")
        let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "scripts/fixtures/codex-usage-reset.py")
        try Data(String(contentsOf: source, encoding: .utf8)
            .replacingOccurrences(of: "#!/usr/bin/env python3", with: "#!/usr/bin/python3").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path())

        func account(_ name: String, plan: String, limits: JSONValue) throws -> ProviderConnection {
            let home = root.appending(path: name)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try JSONEncoder().encode(JSONValue.object(["planType": .string(plan)])).write(to: home.appending(path: "account.json"))
            try JSONEncoder().encode(limits).write(to: home.appending(path: "rate-limits.json"))
            return ProviderConnection(id: name, name: name, harness: .codex, providerID: nil,
                                      homePath: home.path(percentEncoded: false), credentialSelector: nil)
        }
        func credit(_ id: String, expiresAt: Int64, status: String = "available") -> JSONValue {
            .object(["id": .string(id), "resetType": .string("codexRateLimits"), "status": .string(status),
                     "grantedAt": .integer(1), "expiresAt": .integer(expiresAt), "title": .string("Full reset")])
        }
        func answer(_ value: JSONValue, for connection: ProviderConnection) throws {
            try JSONEncoder().encode(value).write(to: URL(filePath: connection.homePath!).appending(path: "consume.json"))
        }
        func requests(_ connection: ProviderConnection) throws -> [JSONValue] {
            let log = URL(filePath: connection.homePath!).appending(path: "consume-requests.jsonl")
            guard FileManager.default.fileExists(atPath: log.path()) else { return [] }
            return try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
                .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        }
        let weeklyCap = JSONValue.object(["limitId": .string("codex"),
            "primary": .object(["usedPercent": .integer(100), "windowDurationMins": .integer(10_080)])])
        let personal = try account("personal", plan: "pro", limits: .object([
            "rateLimits": weeklyCap,
            "rateLimitResetCredits": .object(["availableCount": .integer(2), "credits": .array([
                credit("later", expiresAt: 2_000_000_000), credit("sooner", expiresAt: 1_900_000_000),
                credit("spent", expiresAt: 1_800_000_000, status: "redeemed")
            ])])
        ]))
        let team = try account("team", plan: "team", limits: .object([
            "rateLimits": weeklyCap,
            "rateLimitResetCredits": .object(["availableCount": .integer(0), "credits": .array([])])
        ]))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests.UsageReset")))
        let selections = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        selections.select(executable, for: .codex)
        let store = ProviderConnectionStore()
        try store.save(personal)
        try store.save(team)

        await store.check(defaultsOf: [], savedOf: [.codex], runtimeSelections: selections)
        let resets = try XCTUnwrap(store.snapshots["personal"]?.usageResets)
        XCTAssertEqual(resets.availableCount, 2)
        XCTAssertEqual(resets.resets.map(\.id), ["sooner", "later"], "Available resets, the one expiring first first")
        XCTAssertEqual(resets.next?.title, "Full reset")
        XCTAssertEqual(resets.purchaseURL, HarnessAccountBroker.codexResetPurchaseURL)
        XCTAssertEqual(resets.restores, ["codex:primary"], "A reset restores the general Codex limit")
        XCTAssertEqual(store.snapshots["team"]?.usageResets?.availableCount, 0)
        XCTAssertNil(store.snapshots["team"]?.usageResets?.purchaseURL, "A team plan is not sold an instant reset")
        XCTAssertTrue(MenuBarMenuProjection.usage(choices: store.choices(for: [.codex]))
            .contains { $0.detail.contains(UsageResetText.available(2)) })

        let choice = store.choice(for: .codex, connection: personal)
        await store.useUsageReset(choice, runtimeSelections: selections)
        XCTAssertEqual(store.usageResetStates["personal"], .answered(.reset, left: 1))
        XCTAssertEqual(store.snapshots["personal"]?.usageResets?.availableCount, 1, "The account is read again")
        let first = try requests(personal)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?["creditId"]?.stringValue, "sooner")
        XCTAssertFalse(first.first?["idempotencyKey"]?.stringValue?.isEmpty ?? true)
        XCTAssertEqual(try requests(team), [], "Another account's App Server is not asked")

        try answer(.object(["outcome": .string("nothingToReset")]), for: personal)
        await store.useUsageReset(choice, runtimeSelections: selections)
        XCTAssertEqual(store.usageResetStates["personal"], .answered(.nothingToReset, left: 1))
        try answer(.object(["outcome": .string("noCredit")]), for: personal)
        await store.useUsageReset(choice, runtimeSelections: selections)
        XCTAssertEqual(store.usageResetStates["personal"], .answered(.noResets, left: 1))

        // No answer: the next use sends the same attempt, which the service may already have done.
        try answer(.object(["error": .object(["code": .integer(-32000), "message": .string("upstream timeout")])]),
                   for: personal)
        await store.useUsageReset(choice, runtimeSelections: selections)
        guard case .failed? = store.usageResetStates["personal"] else {
            return XCTFail("A use without an answer fails: \(String(describing: store.usageResetStates["personal"]))")
        }
        try answer(.object(["outcome": .string("alreadyRedeemed")]), for: personal)
        await store.useUsageReset(choice, runtimeSelections: selections)
        XCTAssertEqual(store.usageResetStates["personal"], .answered(.reset, left: 1))
        let keys = try requests(personal).compactMap { $0["idempotencyKey"]?.stringValue }
        XCTAssertEqual(keys.count, 5)
        XCTAssertEqual(Set(keys.prefix(3)).count, 3, "Each answered use is its own attempt")
        XCTAssertEqual(keys[3], keys[4], "The retry sends the unanswered attempt again")
        XCTAssertFalse(keys.prefix(3).contains(keys[3]))

        store.dismissUsageReset(for: choice)
        XCTAssertNil(store.usageResetStates["personal"])
        XCTAssertEqual(try requests(team), [])
    }

    func testPiUnavailableSnapshotUsesThePiDescriptorIdentity() async throws {
        let store = ProviderConnectionStore()
        let defaults = UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests.AccountBoundary"))!
        let selections = RuntimeSelectionStore(
            defaults: defaults,
            discoversRuntimes: false,
            loadsPersistedSelections: false
        )
        await store.check(savedOf: [], runtimeSelections: selections)

        XCTAssertEqual(store.defaultSnapshots[.pi]?.state, .unavailable)
        XCTAssertEqual(store.defaultSnapshots[.pi]?.id, "pi:openai-codex")
    }
}

private actor FakeCodexAccountTransport: CodexTransport {
    private var responses: [String: [JSONValue]]
    private let stream: AsyncStream<CodexRawFrame>
    private let continuation: AsyncStream<CodexRawFrame>.Continuation
    private(set) var didStop = false
    private(set) var requestMethods: [String] = []

    init(responses: [String: [JSONValue]]) {
        self.responses = responses
        let pair = AsyncStream<CodexRawFrame>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func start() async throws {}

    func request(_ request: CodexRPCRequest) async throws -> CodexRPCIncomingMessage {
        requestMethods.append(request.method)
        guard var values = responses[request.method], !values.isEmpty else {
            throw HarnessAdapterError.invalidProviderEvent(
                "Missing fake response for \(request.method)"
            )
        }
        let result = values.removeFirst()
        responses[request.method] = values
        return CodexRPCIncomingMessage(
            id: request.id,
            method: nil,
            params: nil,
            result: result,
            error: nil,
            emittedAtMs: nil
        )
    }

    func sendResponse(_ response: CodexRPCResponse) async throws {}
    func sendErrorResponse(_ response: CodexRPCErrorResponse) async throws {}
    func notifications() async -> AsyncStream<CodexRawFrame> { stream }

    func stop() async {
        didStop = true
        continuation.finish()
    }

    func emit(method: String, params: JSONValue) {
        continuation.yield(CodexRawFrame(
            message: CodexRPCIncomingMessage(
                id: nil,
                method: method,
                params: params,
                result: nil,
                error: nil,
                emittedAtMs: nil
            ),
            data: Data()
        ))
    }
}
