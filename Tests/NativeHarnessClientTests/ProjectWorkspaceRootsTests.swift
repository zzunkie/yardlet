import Foundation
import XCTest
@testable import NativeHarnessClient

/// A project's extra roots reach each harness through its own mechanism, and only when there are
/// extra roots. A single-folder task must send exactly what it always sent.
final class ProjectWorkspaceRootsTests: XCTestCase {
    private let cwd = URL(filePath: "/tmp/multi-root-a")
    private let extraRoot = URL(filePath: "/tmp/multi-root-b")

    // MARK: - Codex

    func testCodexThreadStartOmitsRuntimeWorkspaceRootsForASingleFolderTask() {
        let request = CodexProtocol.startThread(id: 1, workspaceURL: cwd)

        XCTAssertNil(request.params["runtimeWorkspaceRoots"])
        XCTAssertEqual(request.params["cwd"]?.stringValue, cwd.path(percentEncoded: false))
    }

    func testCodexThreadStartSendsTheCwdFirstInRuntimeWorkspaceRoots() {
        let request = CodexProtocol.startThread(
            id: 1,
            workspaceURL: cwd,
            additionalRoots: [extraRoot]
        )

        XCTAssertEqual(
            request.params["runtimeWorkspaceRoots"]?.arrayValue?.compactMap(\.stringValue),
            [cwd.path(percentEncoded: false), extraRoot.path(percentEncoded: false)]
        )
        XCTAssertEqual(
            request.params["cwd"]?.stringValue,
            cwd.path(percentEncoded: false),
            "The primary folder stays the thread's cwd"
        )
    }

    func testCodexThreadResumeCarriesRuntimeWorkspaceRootsOnlyWhenExtraRootsExist() {
        let plain = CodexProtocol.resumeThread(id: 2, threadID: "thread", workspaceURL: cwd)
        XCTAssertNil(plain.params["runtimeWorkspaceRoots"])

        let multiRoot = CodexProtocol.resumeThread(
            id: 3,
            threadID: "thread",
            workspaceURL: cwd,
            excludeTurns: true,
            additionalRoots: [extraRoot]
        )
        XCTAssertEqual(
            multiRoot.params["runtimeWorkspaceRoots"]?.arrayValue?.compactMap(\.stringValue),
            [cwd.path(percentEncoded: false), extraRoot.path(percentEncoded: false)]
        )
        XCTAssertEqual(multiRoot.params["excludeTurns"]?.boolValue, true)
    }

    func testCodexAdapterSendsConfiguredRootsAndKeepsTheReportedInstructionSources() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object([
                "thread": .object(["id": .string("multi-root-thread")]),
                "instructionSources": .array([
                    .string("/tmp/multi-root-a/AGENTS.md")
                ])
            ])]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
        let localSessionID = UUID()
        await adapter.setAdditionalWorkspaceRoots([extraRoot], for: localSessionID)

        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localSessionID,
                workspaceURL: cwd,
                initialPrompt: nil
            )
        )

        let requests = await transport.requests
        let startRequest = try XCTUnwrap(requests.first { $0.method == "thread/start" })
        XCTAssertEqual(
            startRequest.params["runtimeWorkspaceRoots"]?.arrayValue?.compactMap(\.stringValue),
            [cwd.path(percentEncoded: false), extraRoot.path(percentEncoded: false)]
        )
        let sources = await adapter.instructionSources(for: localSessionID)
        XCTAssertEqual(sources, ["/tmp/multi-root-a/AGENTS.md"])
        await adapter.close(handle)
    }

    func testCodexAdapterReportsNoInstructionSourcesWhenTheRuntimeOmitsThem() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object(["thread": .object(["id": .string("quiet-thread")])])]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
        let localSessionID = UUID()

        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localSessionID,
                workspaceURL: cwd,
                initialPrompt: nil
            )
        )

        let requests = await transport.requests
        let startRequest = try XCTUnwrap(requests.first { $0.method == "thread/start" })
        XCTAssertNil(startRequest.params["runtimeWorkspaceRoots"])
        let sources = await adapter.instructionSources(for: localSessionID)
        XCTAssertNil(sources, "A silent runtime must not look like an empty answer")
        await adapter.close(handle)
    }

    // MARK: - Claude

    func testClaudeLaunchAddsAddDirOnlyForAProjectWithExtraRoots() {
        let single = ClaudeProcessTransport.arguments(for: ClaudeLaunchConfiguration(
            providerSessionID: "session-1",
            workspaceURL: cwd,
            resumesExistingSession: false
        ))
        XCTAssertFalse(single.contains("--add-dir"))

        let multiRoot = ClaudeProcessTransport.arguments(for: ClaudeLaunchConfiguration(
            providerSessionID: "session-1",
            workspaceURL: cwd,
            resumesExistingSession: false,
            additionalRoots: [extraRoot, URL(filePath: "/tmp/multi-root-c")]
        ))
        let addDirIndex = try? XCTUnwrap(multiRoot.firstIndex(of: "--add-dir"))
        XCTAssertEqual(
            addDirIndex.map { Array(multiRoot[(multiRoot.index(after: $0))...]) },
            ["/tmp/multi-root-b", "/tmp/multi-root-c"]
        )
        XCTAssertTrue(
            multiRoot.contains("--session-id=session-1"),
            "The existing launch arguments stay untouched"
        )
        XCTAssertFalse(
            multiRoot.contains(cwd.path(percentEncoded: false)),
            "The cwd is the working directory, never an added directory"
        )
    }

    func testClaudeAdapterLaunchesWithTheConfiguredAdditionalRoots() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/claude"),
            transportFactory: { _ in transport }
        )
        let localSessionID = UUID()
        await adapter.setAdditionalWorkspaceRoots([extraRoot], for: localSessionID)

        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localSessionID,
                workspaceURL: cwd,
                initialPrompt: nil
            )
        )

        let launched = await transport.configuration
        let configuration = try XCTUnwrap(launched)
        XCTAssertEqual(configuration.additionalRoots, [extraRoot])
        XCTAssertEqual(configuration.workspaceURL, cwd)
        await adapter.close(handle)
    }

    // MARK: - ACP and Pi

    /// An extra root travels by the CLI's own means. Checked against each runtime's
    /// `--help` for the subcommand Yardlet launches; none of the ACP or Pi entry points documents
    /// one, so nothing is appended and nothing is invented on the protocol request.
    func testNoACPOrPiCLIDocumentsAnExtraRootFlagSoNothingIsAppended() {
        for harness in [HarnessKind.openCode, .kimiCode, .grokBuild, .hermes, .pi] {
            XCTAssertNil(
                HarnessWorkspaceRootLaunchArguments.flag(for: harness),
                "\(harness) has no documented extra-root flag on the subcommand Yardlet launches"
            )
            XCTAssertEqual(
                HarnessWorkspaceRootLaunchArguments.arguments(for: [extraRoot], harness: harness),
                [],
                "\(harness) must not be handed a flag it does not read"
            )
        }
    }

    func testTheExtraRootExpansionRepeatsTheFlagOncePerRootInProjectOrder() {
        XCTAssertEqual(
            HarnessWorkspaceRootLaunchArguments.arguments(for: [], flag: "--add-dir"),
            []
        )
        XCTAssertEqual(
            HarnessWorkspaceRootLaunchArguments.arguments(
                for: [extraRoot, URL(filePath: "/tmp/multi-root-c")],
                flag: "--add-dir"
            ),
            ["--add-dir", "/tmp/multi-root-b", "--add-dir", "/tmp/multi-root-c"]
        )
    }

    func testACPLaunchesWithTheCatalogArgumentsWithAndWithoutExtraRoots() async throws {
        let transport = FakeACPTransport()
        let adapter = ACPAdapter(
            kind: .kimiCode,
            executableURL: URL(filePath: "/tmp/fake-kimi"),
            transportFactory: { transport }
        )
        let localSessionID = UUID()
        let catalogArguments = try XCTUnwrap(
            HarnessCatalog.descriptor(for: .kimiCode)?.launchArguments
        )
        let baseline = await adapter.launchArguments(for: localSessionID)
        XCTAssertEqual(baseline, catalogArguments)

        await adapter.setAdditionalWorkspaceRoots([extraRoot], for: localSessionID)
        let withRoots = await adapter.launchArguments(for: localSessionID)
        XCTAssertEqual(
            withRoots,
            catalogArguments,
            "`kimi acp` neither advertises nor reads --add-dir, so the launch is unchanged"
        )

        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localSessionID,
                workspaceURL: cwd,
                initialPrompt: nil
            )
        )
        let launched = await transport.configuration
        let configuration = try XCTUnwrap(launched)
        XCTAssertEqual(configuration.arguments, catalogArguments)
        XCTAssertEqual(configuration.workspaceURL, cwd, "The cwd stays the task's primary folder")
        let requestValues = await transport.requestValues
        let newSession = try XCTUnwrap(
            requestValues.first { $0["method"]?.stringValue == "session/new" }
        )
        XCTAssertNil(
            newSession["params"]?["_meta"],
            "ACP session/new has no roots field, and Yardlet must not invent a private one"
        )
        await adapter.close(handle)
    }

    func testPiLaunchesWithTheCatalogArgumentsWithAndWithoutExtraRoots() async throws {
        let transport = FakePiRPCTransport(sessionFile: "/tmp/pi-sessions/\(UUID().uuidString).jsonl")
        let adapter = PiRPCAdapter(
            kind: .pi,
            executableURL: URL(filePath: "/tmp/fake-pi"),
            transportFactory: { _ in transport }
        )
        let localSessionID = UUID()
        let catalogArguments = try XCTUnwrap(HarnessCatalog.descriptor(for: .pi)?.launchArguments)
        let baseline = await adapter.launchArguments(for: localSessionID)
        XCTAssertEqual(baseline, catalogArguments)

        await adapter.setAdditionalWorkspaceRoots([extraRoot], for: localSessionID)
        let withRoots = await adapter.launchArguments(for: localSessionID)
        XCTAssertEqual(
            withRoots,
            catalogArguments,
            "`pi --mode rpc` has no additional-directory option, so the launch is unchanged"
        )

        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localSessionID,
                workspaceURL: cwd,
                initialPrompt: nil
            )
        )
        let launched = await transport.configuration
        let configuration = try XCTUnwrap(launched)
        XCTAssertEqual(configuration.arguments, catalogArguments)
        XCTAssertEqual(configuration.workspaceURL, cwd)
        await adapter.close(handle)
    }

    // MARK: - The route the app ships

    /// The product routes every harness through a YHP wrapper, so the optional multi-root and
    /// instruction-source surfaces have to survive the cast AppModel makes on the routed adapter.
    func testTheAdaptersTheAppRoutesThroughStillOfferTheMultiRootSurfaces() async {
        let registry = HarnessRegistry()
        let executable = URL(filePath: "/tmp/yardlet-multi-root-routing-fixture")
        let codex = await registry.adapter(for: .codex, executableURL: executable)
        let claude = await registry.adapter(for: .claudeCode, executableURL: executable)

        XCTAssertTrue(codex is YHPCodexCompatibilityAdapter)
        XCTAssertTrue(claude is YHPProviderCompatibilityAdapter)
        XCTAssertNotNil(
            codex as? any HarnessWorkspaceRootsConfiguring,
            "Codex reaches the app through its protocol wrapper, which has to carry the roots"
        )
        XCTAssertNotNil(codex as? any HarnessInstructionSourceReporting)
        XCTAssertNotNil(codex as? any HarnessLaunchOptionConfiguring)
        XCTAssertNotNil(claude as? any HarnessWorkspaceRootsConfiguring)
        XCTAssertNotNil(claude as? any HarnessInstructionSourceReporting)
        XCTAssertNotNil(claude as? any HarnessLaunchOptionConfiguring)

        for harness in [HarnessKind.kimiCode, .grokBuild, .openCode, .hermes, .pi] {
            let routed = await registry.adapter(for: harness, executableURL: executable)
            XCTAssertTrue(routed is YHPProviderCompatibilityAdapter, "\(harness)")
            XCTAssertNotNil(
                routed as? any HarnessWorkspaceRootsConfiguring,
                "\(harness) reaches the app through its wrapper, which has to carry the roots"
            )
        }
    }

    /// The roots have to survive the wrapper for both families, so that the day a CLI documents
    /// an extra-root flag the only change needed is the table entry.
    func testTheACPAndPiWrappersHandTheRootsToTheAdapterTheyWrap() async throws {
        let acp = RecordingRootsAdapter(kind: .kimiCode)
        let acpRouted: any HarnessAdapter = YHPProviderCompatibilityAdapter(
            adapter: acp,
            manifest: HarnessProtocolCompatibilityManifest.acp(.kimiCode)
        )
        let acpSessionID = UUID()
        let acpConfigurable = try XCTUnwrap(acpRouted as? any HarnessWorkspaceRootsConfiguring)
        await acpConfigurable.setAdditionalWorkspaceRoots([extraRoot], for: acpSessionID)
        let acpRecorded = await acp.configuredRoots
        XCTAssertEqual(acpRecorded[acpSessionID], [extraRoot])

        let pi = RecordingRootsAdapter(kind: .pi)
        let piRouted: any HarnessAdapter = YHPProviderCompatibilityAdapter(
            adapter: pi,
            manifest: HarnessProtocolCompatibilityManifest.piRPC(.pi)
        )
        let piSessionID = UUID()
        let piConfigurable = try XCTUnwrap(piRouted as? any HarnessWorkspaceRootsConfiguring)
        await piConfigurable.setAdditionalWorkspaceRoots([extraRoot], for: piSessionID)
        let piRecorded = await pi.configuredRoots
        XCTAssertEqual(piRecorded[piSessionID], [extraRoot])
    }

    func testTheCodexRouteTheAppShipsSendsTheRootsAndReportsTheInstructionSources() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object([
                "thread": .object(["id": .string("routed-multi-root-thread")]),
                "instructionSources": .array([
                    .string("/tmp/multi-root-b/AGENTS.md")
                ])
            ])]
        ])
        let routed: any HarnessAdapter = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(
                executableURL: URL(filePath: "/tmp/codex"),
                transport: transport
            ),
            manifest: HarnessProtocolCompatibilityManifest.codex()
        )
        let localSessionID = UUID()
        let rootsConfigurable = try XCTUnwrap(routed as? any HarnessWorkspaceRootsConfiguring)
        await rootsConfigurable.setAdditionalWorkspaceRoots([extraRoot], for: localSessionID)

        let handle = try await routed.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localSessionID,
                workspaceURL: cwd,
                initialPrompt: nil
            )
        )

        let requests = await transport.requests
        let startRequest = try XCTUnwrap(requests.first { $0.method == "thread/start" })
        XCTAssertEqual(
            startRequest.params["runtimeWorkspaceRoots"]?.arrayValue?.compactMap(\.stringValue),
            [cwd.path(percentEncoded: false), extraRoot.path(percentEncoded: false)],
            "The roots have to reach the request the wrapped adapter sends"
        )
        let reporting = try XCTUnwrap(routed as? any HarnessInstructionSourceReporting)
        let sources = await reporting.instructionSources(for: localSessionID)
        XCTAssertEqual(sources, ["/tmp/multi-root-b/AGENTS.md"])
        await routed.close(handle)
    }

    func testTheClaudeRouteTheAppShipsLaunchesWithAddDir() async throws {
        let transport = FakeClaudeTransport()
        let routed: any HarnessAdapter = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(
                executableURL: URL(filePath: "/tmp/claude"),
                transportFactory: { _ in transport }
            ),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let localSessionID = UUID()
        let rootsConfigurable = try XCTUnwrap(routed as? any HarnessWorkspaceRootsConfiguring)
        await rootsConfigurable.setAdditionalWorkspaceRoots([extraRoot], for: localSessionID)

        let handle = try await routed.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localSessionID,
                workspaceURL: cwd,
                initialPrompt: nil
            )
        )

        let launched = await transport.configuration
        let configuration = try XCTUnwrap(launched)
        XCTAssertEqual(configuration.additionalRoots, [extraRoot])
        let arguments = ClaudeProcessTransport.arguments(for: configuration)
        let addDirIndex = try XCTUnwrap(arguments.firstIndex(of: "--add-dir"))
        XCTAssertEqual(
            Array(arguments[(arguments.index(after: addDirIndex))...]),
            [extraRoot.path(percentEncoded: false)]
        )
        let reporting = try XCTUnwrap(routed as? any HarnessInstructionSourceReporting)
        let sources = await reporting.instructionSources(for: localSessionID)
        XCTAssertNil(
            sources,
            "Claude Code does not report its instruction files, so the wrapper answers nothing"
        )
        await routed.close(handle)
    }

    // MARK: - Instruction sources

    func testDetectedInstructionFilesCoverTheCwdChainAndEveryExtraRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "instruction-sources-\(UUID().uuidString)", directoryHint: .isDirectory)
        let nested = root.appending(path: "packages/app", directoryHint: .isDirectory)
        let extra = root.appending(path: "shared", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try Data("root".utf8).write(to: root.appending(path: "AGENTS.md"))
        try Data("nested".utf8).write(to: nested.appending(path: "CLAUDE.md"))
        try Data("shared".utf8).write(to: extra.appending(path: "AGENTS.md"))

        let detected = InstructionSourceProjection.existingPaths(
            cwd: nested,
            additionalRoots: [extra]
        )

        XCTAssertEqual(detected, [
            nested.appending(path: "CLAUDE.md").standardizedFileURL.path(percentEncoded: false),
            root.appending(path: "AGENTS.md").standardizedFileURL.path(percentEncoded: false),
            extra.appending(path: "AGENTS.md").standardizedFileURL.path(percentEncoded: false)
        ])

        let reported = InstructionSourceProjection.sources(
            providerReported: ["/tmp/reported/AGENTS.md"],
            cwd: nested,
            additionalRoots: [extra]
        )
        XCTAssertEqual(reported.origin, .provider)
        XCTAssertEqual(reported.paths, ["/tmp/reported/AGENTS.md"])

        let fallback = InstructionSourceProjection.sources(
            providerReported: nil,
            cwd: nested,
            additionalRoots: [extra]
        )
        XCTAssertEqual(fallback.origin, .detected)
        XCTAssertEqual(fallback.paths, detected)
    }
}

/// Observes what a YHP wrapper hands down when AppModel configures a task's extra roots.
private actor RecordingRootsAdapter: HarnessAdapter, HarnessWorkspaceRootsConfiguring {
    nonisolated let kind: HarnessKind
    private(set) var configuredRoots: [UUID: [URL]] = [:]

    init(kind: HarnessKind) { self.kind = kind }

    func setAdditionalWorkspaceRoots(_ roots: [URL], for localSessionID: UUID) {
        configuredRoots[localSessionID] = roots
    }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        HarnessRuntimeDescriptor(
            harness: kind,
            executableURL: URL(filePath: "/tmp/stub"),
            version: "stub",
            capabilities: .unavailable,
            fingerprint: "stub"
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws
        -> HarnessSessionHandle {
        HarnessSessionHandle(
            harness: kind,
            localSessionID: request.localSessionID,
            providerSessionID: "stub-session",
            workspaceURL: request.workspaceURL
        )
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        HarnessSessionHandle(
            harness: kind,
            localSessionID: localSessionID,
            providerSessionID: providerSessionID,
            workspaceURL: workspaceURL
        )
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}

    func interrupt(_ session: HarnessSessionHandle) async throws {}

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {}

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func close(_ session: HarnessSessionHandle) async {}
}
