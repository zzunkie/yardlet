import Foundation
import XCTest
@testable import NativeHarnessClient

/// Yardlet instructions reach each harness through its own per-process or per-session route, through the
/// YHP wrappers the app routes every harness through: the global text then the task's project's,
/// the same bytes on every launch, and nothing at all when a switch is off or the harness has no
/// route. No model turn runs; every transport is a fake.
@MainActor
final class YardletInstructionsTests: XCTestCase {
    private var root: URL!
    private let text = "- Prefer Opus 5.5 for implementation.\n- Review with Argon."

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-instructions-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var workspace: URL { root.appending(path: "app", directoryHint: .isDirectory) }

    private func store(_ defaults: UserDefaults = SuggestionVolatileDefaults()) -> YardletInstructionsStore {
        YardletInstructionsStore(directory: root.appending(path: "instructions", directoryHint: .isDirectory), defaults: defaults)
    }

    // MARK: - Routes

    func testFiveHarnessesHaveARouteAndSettingsListsTheRest() {
        XCTAssertEqual(YardletInstructionsRoute.route(for: .claudeCode), .claudeAppendSystemPrompt)
        XCTAssertEqual(YardletInstructionsRoute.route(for: .codex), .codexDeveloperInstructions)
        XCTAssertEqual(YardletInstructionsRoute.route(for: .grokBuild), .grokSessionRules)
        XCTAssertEqual(YardletInstructionsRoute.route(for: .pi), .piAppendSystemPrompt)
        XCTAssertEqual(YardletInstructionsRoute.route(for: .antigravityCLI), .antigravitySystemPrompt)
        XCTAssertEqual(YardletInstructionsRoute.unsupportedHarnesses,
                       [.museCode, .openCode, .cursorAgent, .kimiCode, .hermes],
                       "Every other built-in harness is named as not supported, in catalog order")
        XCTAssertEqual(Set(HarnessCatalog.builtIns.map(\.id)),
                       Set(YardletInstructionsRoute.unsupportedHarnesses + [.claudeCode, .codex, .grokBuild, .pi, .antigravityCLI]))
    }

    // MARK: - Claude Code

    func testClaudeStartsAndResumesWithTheTextAppendedAndWithoutItWhenOff() async throws {
        let transport = FakeClaudeTransport()
        let routed: any HarnessAdapter = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport }),
            manifest: HarnessProtocolCompatibilityManifest.claude())
        let id = UUID()
        let configurable = try XCTUnwrap(routed as? any HarnessYardletInstructionsConfiguring,
                                         "The route has to survive the protocol wrapper")
        await configurable.setYardletInstructions(YardletInstructionsDelivery(text: text), for: id)
        _ = try await routed.createSession(CreateHarnessSessionRequest(localSessionID: id, workspaceURL: workspace, initialPrompt: nil))
        let launched = await transport.configuration
        let configuration = try XCTUnwrap(launched)
        XCTAssertEqual(configuration.appendSystemPrompt, text)

        let started = ClaudeProcessTransport.arguments(for: configuration)
        XCTAssertTrue(started.contains("--append-system-prompt=\(text)"), started.description)
        var resumed = ClaudeLaunchConfiguration(providerSessionID: "s-1", workspaceURL: workspace, resumesExistingSession: true,
                                                agentToolConfigPath: "/tmp/claude-tools.json", appendSystemPrompt: text)
        let resumeArguments = ClaudeProcessTransport.arguments(for: resumed)
        XCTAssertTrue(resumeArguments.contains("--resume=s-1"))
        XCTAssertEqual(resumeArguments.filter { $0.hasPrefix("--append-system-prompt") }, ["--append-system-prompt=\(text)"],
                       "A resume carries the same flag, once")
        XCTAssertEqual(Array(resumeArguments.suffix(2)), ["--mcp-config", "/tmp/claude-tools.json"],
                       "--mcp-config stays last, where nothing is read as one of its values")
        XCTAssertEqual(ClaudeProcessTransport.arguments(for: resumed), resumeArguments, "Every relaunch is byte for byte the same")

        let dashed = "-- An instruction that starts with dashes"
        XCTAssertEqual(YardletInstructionsLaunch.claudeArguments(dashed), ["--append-system-prompt=\(dashed)"],
                       "Text that starts with a dash stays the flag's value")

        resumed.appendSystemPrompt = nil
        XCTAssertFalse(ClaudeProcessTransport.arguments(for: resumed).contains { $0.hasPrefix("--append-system-prompt") },
                       "Off, the launch is what it always was")
        let offTransport = FakeClaudeTransport()
        let off: any HarnessAdapter = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in offTransport }),
            manifest: HarnessProtocolCompatibilityManifest.claude())
        await (off as? any HarnessYardletInstructionsConfiguring)?.setYardletInstructions(nil, for: id)
        _ = try await off.createSession(CreateHarnessSessionRequest(localSessionID: id, workspaceURL: workspace, initialPrompt: nil))
        let offConfiguration = await offTransport.configuration
        XCTAssertNil(offConfiguration?.appendSystemPrompt)
    }

    // MARK: - Codex

    private func routedCodex(_ transport: FakeCodexTransport) -> YHPCodexCompatibilityAdapter {
        YHPCodexCompatibilityAdapter(adapter: CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport),
                                     manifest: HarnessProtocolCompatibilityManifest.codex())
    }

    private func developerInstructions(in method: String, of requests: [CodexRPCRequest]) -> JSONValue? {
        requests.first { $0.method == method }?.params["developerInstructions"]
    }

    func testCodexSendsDeveloperInstructionsOnStartResumeAndForkAfterTheConfiguredOnes() async throws {
        let configured: JSONValue = .object(["config": .object(["developer_instructions": .string("Answer in Korean.")])])
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "config/read": [configured, configured],
            "thread/start": [.object(["thread": .object(["id": .string("thread-a")])])],
            "thread/fork": [.object(["thread": .object(["id": .string("thread-b")])])]
        ])
        let routed = routedCodex(transport)
        let source = UUID()
        let fork = UUID()
        await routed.setYardletInstructions(YardletInstructionsDelivery(text: text), for: source)
        let handle = try await routed.createSession(
            CreateHarnessSessionRequest(localSessionID: source, workspaceURL: workspace, initialPrompt: nil))
        await routed.setYardletInstructions(YardletInstructionsDelivery(text: text), for: fork)
        _ = try? await routed.fork(handle, newLocalSessionID: fork)
        let requests = await transport.requests
        let expected = JSONValue.string("Answer in Korean.\n\n" + text)
        XCTAssertEqual(developerInstructions(in: "thread/start", of: requests), expected,
                       "The configuration's own developer instructions stay first; AGENTS.md is Codex's separate message")
        XCTAssertEqual(developerInstructions(in: "thread/fork", of: requests), expected)
        let read = try XCTUnwrap(requests.first { $0.method == "config/read" })
        XCTAssertEqual(read.params["cwd"], .string(workspace.standardizedFileURL.path(percentEncoded: false)),
                       "The folder's own configuration, project layers included")

        let resumeTransport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "config/read": [.object(["config": .object([:])])],
            "thread/resume": [.object(["thread": .object(["id": .string("thread-a")])])]
        ])
        let resumer = routedCodex(resumeTransport)
        let resumed = UUID()
        await resumer.setYardletInstructions(YardletInstructionsDelivery(text: text), for: resumed)
        _ = try? await resumer.resumeSession(providerSessionID: "thread-a", localSessionID: resumed, workspaceURL: workspace)
        let resumeRequests = await resumeTransport.requests
        XCTAssertEqual(developerInstructions(in: "thread/resume", of: resumeRequests), .string(text),
                       "Without configured developer instructions the text goes alone")
    }

    func testCodexSendsNothingWhenOffOrWhenItsConfigurationCannotBeRead() async throws {
        let unreadable = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object(["thread": .object(["id": .string("thread-a")])])]
        ])
        let routed = routedCodex(unreadable)
        let id = UUID()
        await routed.setYardletInstructions(YardletInstructionsDelivery(text: text), for: id)
        _ = try await routed.createSession(CreateHarnessSessionRequest(localSessionID: id, workspaceURL: workspace, initialPrompt: nil))
        let requests = await unreadable.requests
        XCTAssertNil(developerInstructions(in: "thread/start", of: requests),
                     "Never replace developer instructions Yardlet could not read")

        let off = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object(["thread": .object(["id": .string("thread-a")])])]
        ])
        let offRouted = routedCodex(off)
        await offRouted.setYardletInstructions(nil, for: id)
        _ = try await offRouted.createSession(CreateHarnessSessionRequest(localSessionID: id, workspaceURL: workspace, initialPrompt: nil))
        let offMethods = await off.requestMethods
        XCTAssertEqual(offMethods, ["initialize", "thread/start"], "Off, no configuration is read and the request is unchanged")
        XCTAssertNil(CodexProtocol.startThread(id: 1, workspaceURL: workspace).params["developerInstructions"])
        XCTAssertNil(CodexProtocol.resumeThread(id: 1, threadID: "t", workspaceURL: workspace).params["developerInstructions"])
    }

    // MARK: - ACP

    private actor RecordingACPTransport: ACPTransport {
        private let channel = AsyncStream<ACPRawFrame>.makeStream()
        private(set) var requests: [JSONValue] = []
        private(set) var configuration: ACPLaunchConfiguration?

        func start(_ configuration: ACPLaunchConfiguration) { self.configuration = configuration }
        func send(_ value: JSONValue) {}
        func messages() -> AsyncStream<ACPRawFrame> { channel.stream }
        func stop() { channel.continuation.finish() }

        func request(_ value: JSONValue, id: Int64) throws -> JSONValue {
            requests.append(value)
            switch value["method"]?.stringValue {
            case "initialize":
                return .object(["protocolVersion": .integer(1), "agentCapabilities": .object(["loadSession": .bool(true)])])
            case "session/new":
                return .object(["sessionId": .string("acp-1")])
            default:
                return .object([:])
            }
        }

        func meta(in method: String) -> JSONValue? {
            requests.first { $0["method"]?.stringValue == method }?["params"]?["_meta"]
        }
    }

    private func routedACP(_ kind: HarnessKind, _ transport: RecordingACPTransport) -> any HarnessAdapter {
        YHPProviderCompatibilityAdapter(adapter: ACPAdapter(kind: kind, executableURL: URL(filePath: "/tmp/acp"), transportFactory: { transport }),
                                        manifest: HarnessProtocolCompatibilityManifest.acp(kind))
    }

    func testGrokGetsRulesOnNewAndLoadAntigravityOnNewOnlyAndOtherACPAgentsGetNothing() async throws {
        let transport = RecordingACPTransport()
        let grok = routedACP(.grokBuild, transport)
        let configurable = try XCTUnwrap(grok as? any HarnessYardletInstructionsConfiguring)
        let created = UUID()
        let loaded = UUID()
        await configurable.setYardletInstructions(YardletInstructionsDelivery(text: text), for: created)
        await configurable.setYardletInstructions(YardletInstructionsDelivery(text: text), for: loaded)
        _ = try await grok.createSession(CreateHarnessSessionRequest(localSessionID: created, workspaceURL: workspace, initialPrompt: nil))
        _ = try await grok.resumeSession(providerSessionID: "acp-0", localSessionID: loaded, workspaceURL: workspace)
        let newMeta = await transport.meta(in: "session/new")
        let loadMeta = await transport.meta(in: "session/load")
        XCTAssertEqual(newMeta, .object(["rules": .string(text)]))
        XCTAssertEqual(loadMeta, .object(["rules": .string(text)]))
        let launch = await transport.configuration
        XCTAssertEqual(launch?.arguments, ["agent", "stdio"], "Grok's launch itself is unchanged")

        let antigravityTransport = RecordingACPTransport()
        let antigravity = routedACP(.antigravityCLI, antigravityTransport)
        await (antigravity as? any HarnessYardletInstructionsConfiguring)?
            .setYardletInstructions(YardletInstructionsDelivery(text: text), for: created)
        await (antigravity as? any HarnessYardletInstructionsConfiguring)?
            .setYardletInstructions(YardletInstructionsDelivery(text: text), for: loaded)
        _ = try await antigravity.createSession(CreateHarnessSessionRequest(localSessionID: created, workspaceURL: workspace, initialPrompt: nil))
        _ = try await antigravity.resumeSession(providerSessionID: "acp-0", localSessionID: loaded, workspaceURL: workspace)
        let antigravityNewMeta = await antigravityTransport.meta(in: "session/new")
        let antigravityLoadMeta = await antigravityTransport.meta(in: "session/load")
        XCTAssertEqual(antigravityNewMeta, .object(["antigravity": .object(["systemPrompt": .object(["append": .string(text)])])]))
        XCTAssertNil(antigravityLoadMeta, "The CLI keeps the text a conversation started with; sent again it would come twice")

        let openCodeTransport = RecordingACPTransport()
        let openCode = routedACP(.openCode, openCodeTransport)
        await (openCode as? any HarnessYardletInstructionsConfiguring)?
            .setYardletInstructions(YardletInstructionsDelivery(text: text), for: created)
        _ = try await openCode.createSession(CreateHarnessSessionRequest(localSessionID: created, workspaceURL: workspace, initialPrompt: nil))
        let openCodeMeta = await openCodeTransport.meta(in: "session/new")
        XCTAssertNil(openCodeMeta, "An agent without a documented route receives nothing")
        let openCodeLaunch = await openCodeTransport.configuration
        XCTAssertNil(openCodeLaunch?.environmentOverrides["OPENCODE_CONFIG_CONTENT"])

        let offTransport = RecordingACPTransport()
        let off = routedACP(.grokBuild, offTransport)
        await (off as? any HarnessYardletInstructionsConfiguring)?.setYardletInstructions(nil, for: created)
        _ = try await off.createSession(CreateHarnessSessionRequest(localSessionID: created, workspaceURL: workspace, initialPrompt: nil))
        let offMeta = await offTransport.meta(in: "session/new")
        XCTAssertNil(offMeta)
    }

    // MARK: - Pi

    func testPiAppendsTheTextAfterItsOwnGlobalFileAndLeavesAProjectFileAlone() async throws {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let global = "/Users/someone/.pi/agent/APPEND_SYSTEM.md"
        let project = workspace.appending(path: ".pi/APPEND_SYSTEM.md").path(percentEncoded: false)
        XCTAssertEqual(YardletInstructionsLaunch.piArguments(text, workspaceURL: workspace, environment: [:], homeURL: home,
                                                             fileExists: { _ in false }),
                       ["--append-system-prompt", text])
        XCTAssertEqual(YardletInstructionsLaunch.piArguments(text, workspaceURL: workspace, environment: [:], homeURL: home,
                                                             fileExists: { $0 == global }),
                       ["--append-system-prompt", global, "--append-system-prompt", text],
                       "Pi's own APPEND_SYSTEM.md, which the flag would otherwise replace, comes first")
        XCTAssertEqual(YardletInstructionsLaunch.piArguments(text, workspaceURL: workspace,
                                                             environment: ["PI_CODING_AGENT_DIR": "/opt/pi-agent"], homeURL: home,
                                                             fileExists: { $0 == "/opt/pi-agent/APPEND_SYSTEM.md" }),
                       ["--append-system-prompt", "/opt/pi-agent/APPEND_SYSTEM.md", "--append-system-prompt", text])
        XCTAssertEqual(YardletInstructionsLaunch.piArguments(text, workspaceURL: workspace, environment: [:], homeURL: home,
                                                             fileExists: { $0 == project || $0 == global }), [],
                       "A project with its own APPEND_SYSTEM.md launches as it always did: only Pi knows whether it trusts it")
        XCTAssertEqual(YardletInstructionsLaunch.piArguments(nil, workspaceURL: workspace, environment: [:], homeURL: home,
                                                             fileExists: { _ in true }), [])

        let transport = FakePiRPCTransport(sessionFile: "/tmp/pi-session.jsonl")
        let pi = PiRPCAdapter(kind: .pi, executableURL: URL(filePath: "/usr/bin/true"), transportFactory: { _ in transport })
        let routed: any HarnessAdapter = YHPProviderCompatibilityAdapter(adapter: pi,
                                                                         manifest: HarnessProtocolCompatibilityManifest.piRPC(.pi))
        let id = UUID()
        await (routed as? any HarnessYardletInstructionsConfiguring)?
            .setYardletInstructions(YardletInstructionsDelivery(text: text), for: id)
        _ = try await routed.createSession(CreateHarnessSessionRequest(localSessionID: id, workspaceURL: workspace, initialPrompt: nil))
        let launched = await transport.configuration
        let arguments = try XCTUnwrap(launched?.arguments)
        XCTAssertEqual(Array(arguments.prefix(2)), ["--mode", "rpc"])
        XCTAssertEqual(Array(arguments.suffix(2)), ["--append-system-prompt", text])
    }

    // MARK: - Store

    func testTheStoreStartsEmptyAndCombinesTheGlobalThenTheProjectTextInOneBlock() throws {
        let defaults = SuggestionVolatileDefaults()
        defaults.set(true, forKey: YardletInstructionsStore.retiredSeededKey)
        let first = store(defaults)
        XCTAssertEqual(first.text, "", "No one's guideline is put in the editor")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.sourceURL.path(percentEncoded: false)),
                       "Nothing is written until the person types")
        XCTAssertNil(defaults.object(forKey: YardletInstructionsStore.retiredSeededKey), "The old seed mark is removed")
        XCTAssertTrue(first.isEnabled, "On by default")
        first.text = "- my routing"
        XCTAssertEqual(store(defaults).text, "- my routing", "A saved text is kept as it is")

        let project = UUID()
        first.text = "  global  \n"
        first.setProjectText("\nproject\n", for: project)
        XCTAssertEqual(first.delivery(forProject: project), YardletInstructionsDelivery(text: "global\n\nproject"))
        XCTAssertEqual(first.delivery(forProject: nil), YardletInstructionsDelivery(text: "global"), "A chat gets the global text")
        XCTAssertEqual(first.delivery(forProject: UUID()), YardletInstructionsDelivery(text: "global"),
                       "A project without its own text gets the global text")
        first.text = ""
        XCTAssertEqual(first.delivery(forProject: project), YardletInstructionsDelivery(text: "project"))
        XCTAssertNil(first.delivery(forProject: nil), "No text, nothing sent")

        first.text = "global"
        let reopened = store(defaults)
        XCTAssertEqual(reopened.projectText(for: project), "\nproject\n", "Each project's text is kept in Yardlet's folder")
        XCTAssertEqual(reopened.delivery(forProject: project), first.delivery(forProject: project))
        XCTAssertEqual(Data(try XCTUnwrap(reopened.delivery(forProject: project)).text.utf8),
                       Data(try XCTUnwrap(first.delivery(forProject: project)).text.utf8),
                       "The same bytes on every launch and turn until the person edits a text")

        first.setProjectText("", for: project)
        StateFileWriter.shared.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.projectFileURL(for: project).path(percentEncoded: false)),
                       "Empty project text leaves no file")
    }

    func testTheSwitchTurnsOffBothLevelsAndAProjectCanTurnItselfOff() {
        let defaults = SuggestionVolatileDefaults()
        let instructions = store(defaults)
        let project = UUID()
        let other = UUID()
        instructions.text = "global"
        instructions.setProjectText("project", for: project)

        instructions.setDisabled(true, forProject: project)
        XCTAssertNil(instructions.delivery(forProject: project), "Turned off in this project: neither level")
        XCTAssertEqual(instructions.delivery(forProject: other)?.text, "global", "Other projects are unaffected")
        XCTAssertTrue(store(defaults).isDisabled(forProject: project), "Kept across launches")
        instructions.setDisabled(false, forProject: project)
        XCTAssertEqual(instructions.delivery(forProject: project)?.text, "global\n\nproject")

        instructions.isEnabled = false
        XCTAssertNil(instructions.delivery(forProject: project))
        XCTAssertNil(instructions.delivery(forProject: nil))
        XCTAssertFalse(store(defaults).isEnabled, "Kept across launches")
        XCTAssertEqual(store(defaults).text, "global", "Turning it off keeps the text")
    }

    // MARK: - AppModel

    private actor RecordingInstructionsAdapter: HarnessAdapter, HarnessYardletInstructionsConfiguring {
        nonisolated let kind: HarnessKind
        private(set) var received: [UUID: [YardletInstructionsDelivery?]] = [:]

        init(kind: HarnessKind) { self.kind = kind }

        func setYardletInstructions(_ instructions: YardletInstructionsDelivery?, for localSessionID: UUID) {
            received[localSessionID, default: []].append(instructions)
        }

        func probeRuntime() async throws -> HarnessRuntimeDescriptor {
            HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                     capabilities: .unavailable, fingerprint: "stub")
        }

        func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
            HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                                 providerSessionID: "stub-\(request.localSessionID)", workspaceURL: request.workspaceURL)
        }

        func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws -> HarnessSessionHandle {
            HarnessSessionHandle(harness: kind, localSessionID: localSessionID, providerSessionID: providerSessionID,
                                 workspaceURL: workspaceURL)
        }

        func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}
        func interrupt(_ session: HarnessSessionHandle) async throws {}
        func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle) async throws {}
        func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> { AsyncStream { $0.finish() } }
        func close(_ session: HarnessSessionHandle) async {}
    }

    private func model(adapter: RecordingInstructionsAdapter, project: Project, sessions: [SessionRecord] = []) -> AppModel {
        let defaults = SuggestionVolatileDefaults()
        return AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false),
            registry: HarnessRegistry { _, _ in adapter },
            preferences: defaults,
            projectRepository: InMemoryProjectRepository(snapshot: ProjectSnapshot(projects: [project])),
            chatWorkspaceHome: root,
            restoresIndexOnLaunch: false)
    }

    func testEveryTaskLaunchGetsItsProjectsBlockAndNothingWhereTheHarnessHasNoRoute() async throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let chatFolder = ChatWorkspaces.yardletRoot(home: root).appending(path: "2026-10-16/chat", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: chatFolder, withIntermediateDirectories: true)
        let app = Project(name: "app", primaryRoot: workspace)
        let resumable = SessionRecord(harness: .claudeCode, workspaceURL: workspace, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                      title: "Resume me", providerSessionID: "claude-session-1", projectID: app.id)
        let claude = RecordingInstructionsAdapter(kind: .claudeCode)
        let model = model(adapter: claude, project: app, sessions: [resumable])
        let instructions = store()
        instructions.text = "global"
        instructions.setProjectText("app only", for: app.id)
        model.yardletInstructions = instructions

        let createdTask = await model.createSession(harness: .claudeCode, workspaceURL: workspace,
                                                    runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Task")
        let task = try XCTUnwrap(createdTask)
        let createdChat = await model.createSession(harness: .claudeCode, workspaceURL: chatFolder,
                                                    runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Chat")
        let chat = try XCTUnwrap(createdChat)
        await model.resume(resumable)
        var received = await claude.received
        XCTAssertEqual(received[task.id], [YardletInstructionsDelivery(text: "global\n\napp only")])
        XCTAssertEqual(received[chat.id], [YardletInstructionsDelivery(text: "global")], "A chat has no project")
        XCTAssertEqual(received[resumable.id], [YardletInstructionsDelivery(text: "global\n\napp only")], "A resume carries it too")

        await model.resume(resumable)
        received = await claude.received
        XCTAssertEqual(Set(received[resumable.id] ?? []).count, 1, "Each launch of the task carries the same bytes")

        instructions.setDisabled(true, forProject: app.id)
        let createdDisabled = await model.createSession(harness: .claudeCode, workspaceURL: workspace,
                                                        runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Off here")
        let disabled = try XCTUnwrap(createdDisabled)
        instructions.setDisabled(false, forProject: app.id)
        instructions.isEnabled = false
        let createdOff = await model.createSession(harness: .claudeCode, workspaceURL: chatFolder,
                                                   runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Off")
        let off = try XCTUnwrap(createdOff)
        received = await claude.received
        XCTAssertEqual(received[disabled.id], [nil], "Turned off in the project, the launch is cleared")
        XCTAssertEqual(received[off.id], [nil], "Turned off, the launch is cleared")
        await model.shutdown()

        let cursor = RecordingInstructionsAdapter(kind: .cursorAgent)
        let cursorModel = self.model(adapter: cursor, project: app)
        instructions.isEnabled = true
        cursorModel.yardletInstructions = instructions
        let createdCursor = await cursorModel.createSession(harness: .cursorAgent, workspaceURL: workspace,
                                                            runtimeExecutableURL: URL(filePath: "/tmp/cursor"), title: "Cursor")
        let cursorTask = try XCTUnwrap(createdCursor)
        let cursorReceived = await cursor.received
        XCTAssertEqual(cursorReceived[cursorTask.id], [nil], "A harness without a route is handed nothing")
        await cursorModel.shutdown()
    }

    func testASubagentGetsTheBlockOfItsFoldersProject() async throws {
        let fixture = try SessionToolTests.Fixture()
        defer { fixture.tearDown() }
        let model = fixture.model
        let instructions = store()
        instructions.text = "global"
        instructions.setProjectText("app only", for: fixture.app.id)
        model.yardletInstructions = instructions
        let arguments = try suggestionToolJSON(["harness": "claude-code", "prompt": "Count the TODOs", "background": true])
        let started = await model.callSessionTool(named: "run_agent", arguments: arguments, callerID: fixture.caller.id)
        XCTAssertFalse(started.isError, started.text)
        let clock = ContinuousClock()
        let deadline = clock.now + testWaitLimit
        while model.sessionTools.runs(hostedBy: fixture.caller.id).isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let run = try XCTUnwrap(model.sessionTools.runs(hostedBy: fixture.caller.id).last)
        var received: YardletInstructionsDelivery??
        while received == nil, clock.now < deadline {
            received = await fixture.adapter.instructions[run.id]
            if received == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(received, .some(YardletInstructionsDelivery(text: "global\n\napp only")),
                       "run_agent is a launch Yardlet makes, so its subagent carries the block too")
        await model.shutdown()
    }
}
