import Foundation
import XCTest
@testable import NativeHarnessClient

/// The model and effort a task will use are shown before it connects, for Claude Code and Codex
/// alike, from the account's own settings files and the list the runtime last gave Yardlet. A
/// choice made then, or on the new-task screen, runs the first turn. Fake transports stand in for
/// both CLIs; no model is asked anything and no real settings file is read.
@MainActor
final class ComposerModelVisibilityTests: XCTestCase {
    // MARK: Settings files

    func testClaudeDefaultsLayerTheAccountsSettingsUnderTheProjects() throws {
        let root = try temporaryFolder()
        let account = root.appending(path: "account"), project = root.appending(path: "project")
        try write(#"{"model":"fable","effortLevel":"xhigh","permissions":{"allow":[]}}"#, to: account.appending(path: "settings.json"))
        try write(#"{"model":"opus"}"#, to: project.appending(path: ".claude/settings.json"))
        try write(#"{"effortLevel":"high"}"#, to: project.appending(path: ".claude/settings.local.json"))

        XCTAssertEqual(HarnessModelDefaultsReader.claude(configDirectory: account, workspaceURL: nil, environment: [:]),
                       HarnessModelDefaults(model: "fable", effort: "xhigh"))
        XCTAssertEqual(HarnessModelDefaultsReader.claude(configDirectory: account, workspaceURL: project, environment: [:]),
                       HarnessModelDefaults(model: "opus", effort: "high"))
        XCTAssertEqual(HarnessModelDefaultsReader.claude(configDirectory: account, workspaceURL: project,
                                                         environment: ["ANTHROPIC_MODEL": "sonnet"]).model, "sonnet")
        XCTAssertEqual(HarnessModelDefaultsReader.claude(configDirectory: root.appending(path: "missing"),
                                                         workspaceURL: nil, environment: [:]), HarnessModelDefaults())
    }

    func testCodexDefaultsReadTheTopLevelAndTheSelectedProfileOnly() throws {
        let home = try temporaryFolder()
        let config = """
        # Codex settings
        model = "gpt-6-astra"
        model_context_window = 872000
        model_reasoning_effort = 'xhigh' # inline comment
        service_tier = "default"
        %@

        [projects."/Users/me/model"]
        model = "not-this-one"
        trust_level = "trusted"

        [profiles.deep]
        model_reasoning_effort = "max"
        """
        try write(config.replacingOccurrences(of: "%@", with: ""), to: home.appending(path: "config.toml"))
        XCTAssertEqual(HarnessModelDefaultsReader.codex(home: home),
                       HarnessModelDefaults(model: "gpt-6-astra", effort: "xhigh", serviceTier: "default"))
        try write(config.replacingOccurrences(of: "%@", with: #"profile = "deep""#), to: home.appending(path: "config.toml"))
        XCTAssertEqual(HarnessModelDefaultsReader.codex(home: home),
                       HarnessModelDefaults(model: "gpt-6-astra", effort: "max", serviceTier: "default"))
        XCTAssertEqual(HarnessModelDefaultsReader.codex(home: home.appending(path: "missing")), HarnessModelDefaults())
    }

    func testModelListsSurviveRelaunchAndStandInForAnAccountThatHasNone() throws {
        let root = try temporaryFolder()
        let file = root.appending(path: "model-catalogs.json")
        let account = ProviderConnection(id: "work", name: "work@example.test", harness: .claudeCode,
                                         providerID: nil, homePath: root.path, credentialSelector: nil)
        let store = HarnessModelCatalogStore(fileURL: file, locations: locations(root))
        store.recordClaude(ModelVisibilityFixtures.claudeModels, for: nil)
        store.recordCodex([ModelVisibilityFixtures.codexModel("gpt-test", efforts: ["low", "high"], isDefault: true)], for: nil)
        let reopened = HarnessModelCatalogStore(fileURL: file, locations: locations(root))
        XCTAssertEqual(reopened.claudeModels(for: nil), ModelVisibilityFixtures.claudeModels)
        XCTAssertEqual(reopened.claudeModels(for: account), ModelVisibilityFixtures.claudeModels, "Another account's list stands in")
        XCTAssertEqual(reopened.codexModels(for: nil).map(\.model), ["gpt-test"])
    }

    // MARK: Claude Code before it connects

    func testAClaudeTaskShowsTheModelItWillUseBeforeItConnects() async throws {
        let fixture = try await ClaudeFixture.make(settings: #"{"model":"fable","effortLevel":"xhigh"}"#, in: self)
        let model = fixture.model, session = fixture.session
        model.modelCatalogs.recordClaude(ModelVisibilityFixtures.claudeModels, for: session.connection)

        await model.refreshConversationStatus(for: session)
        XCTAssertFalse(model.isAttached(session.id))
        XCTAssertTrue(fixture.transports.all.isEmpty, "Showing the model starts no CLI")
        var menu = try claudeMenu(model, session)
        XCTAssertEqual(menu.model?.currentValue, "fable")
        XCTAssertEqual(menu.effort?.currentValue, "xhigh")
        XCTAssertEqual(menu.title, "Fable · " + L10n.string("Extra high"))
        XCTAssertTrue(menu.canChoose, "The list Claude Code last gave can be chosen from")
        XCTAssertEqual(menu.model?.choices.map(\.value), ModelVisibilityFixtures.claudeModels.map(\.value))
        XCTAssertEqual(menu.effort?.choices.map(\.value), ["default", "low", "medium", "high", "xhigh", "max"])

        // The task's own choice comes before the account's settings.
        try await model.store.updateProviderOption(id: session.id, optionID: "model", value: "haiku")
        menu = try claudeMenu(model, try current(model, session))
        XCTAssertEqual(menu.title, "Haiku", "Haiku takes no effort, so none is named")
        XCTAssertNil(menu.effort)

        // Without a list, the settings still name the model; opening the menu loads the list.
        let bare = try await ClaudeFixture.make(settings: #"{"model":"claude-opus-5-5"}"#, in: self)
        await bare.model.refreshConversationStatus(for: bare.session)
        let unlisted = try claudeMenu(bare.model, bare.session)
        XCTAssertEqual(unlisted.title, "Opus 5.5")
        XCTAssertFalse(unlisted.canChoose)
        XCTAssertTrue(bare.transports.all.isEmpty)
    }

    func testAClaudeModelAndEffortChosenBeforeConnectingRunTheFirstTurn() async throws {
        let fixture = try await ClaudeFixture.make(settings: #"{"model":"fable","effortLevel":"xhigh"}"#, in: self)
        let model = fixture.model, session = fixture.session
        model.modelCatalogs.recordClaude(ModelVisibilityFixtures.claudeModels, for: session.connection)
        await model.refreshConversationStatus(for: session)

        await model.setProviderOption("model", value: "sonnet", for: session)
        await model.setProviderOption("effort", value: "low", for: try current(model, session))
        await model.setProviderOption("effort", value: "ultra", for: try current(model, session))
        XCTAssertTrue(fixture.transports.all.isEmpty, "Choosing before connecting starts nothing")
        XCTAssertEqual(try current(model, session).providerOptions, ["model": "sonnet", "effort": "low"],
                       "A level the model does not take is not kept")
        XCTAssertEqual(try claudeMenu(model, try current(model, session)).title, "Sonnet · " + L10n.string("Low"))

        await model.send(HarnessUserInput(text: "Run the tests"), to: try current(model, session))
        let transport = try XCTUnwrap(fixture.transports.all.first)
        let launched = await transport.configuration
        let configuration = try XCTUnwrap(launched)
        XCTAssertEqual(configuration.model, "sonnet")
        let arguments = ClaudeProcessTransport.arguments(for: configuration)
        let flag = try XCTUnwrap(arguments.firstIndex(of: "--model"))
        XCTAssertEqual(arguments[flag + 1], "sonnet")
        let requests = await transport.requestedValues
        XCTAssertTrue(requests.contains {
            $0["request"]?["subtype"] == .string("apply_flag_settings")
                && $0["request"]?["settings"] == .object(["effortLevel": .string("low")])
        })
        XCTAssertFalse(requests.contains { $0["request"]?["subtype"] == .string("set_model") },
                       "The launch flag already chose the model")
        let sent = await transport.sentValues
        XCTAssertEqual(sent.last?["message"]?["content"]?.stringValue, "Run the tests")
        // Once connected, the composer reads the runtime's own selectors: the model it was launched on.
        await model.loadProviderCapabilities(for: try current(model, session))
        let live = model.providerCapabilitiesBySessionID[session.id]?.selectors
        XCTAssertEqual(live?.first { $0.id == "model" }?.currentValue, "sonnet")
        XCTAssertEqual(live?.first { $0.id == "effort" }?.currentValue, "low")
    }

    func testTheModelATaskAskedForReadsBackOverTheAccountsConfiguredModel() async throws {
        let transport = FakeClaudeTransport(initializeResponse: ModelVisibilityFixtures.claudeInitialize)
        // As Claude Code 2.1.291 answers `get_settings` after `--model sonnet`: the settings' model
        // stays effective while the session runs the one it was given.
        await transport.setSettings(effective: ["model": .string("fable"), "effortLevel": .string("xhigh")],
                                    applied: ["model": .string("claude-sonnet-5-5")])
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
        let id = UUID()
        await adapter.setLaunchOptions(["model": "sonnet", "effort": "low"], for: id)
        let handle = try await adapter.createSession(.init(localSessionID: id, workspaceURL: URL(filePath: "/tmp"),
                                                           initialPrompt: nil))
        let launched = await transport.configuration
        let configuration = try XCTUnwrap(launched)
        XCTAssertEqual(configuration.model, "sonnet")
        var state = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(state.selectors.first { $0.id == "model" }?.currentValue, "sonnet")
        let advertised = await adapter.advertisedModels(for: id)
        XCTAssertEqual(advertised, ModelVisibilityFixtures.claudeModels)

        // Restoring the model it launched on asks nothing; another model reads back as chosen.
        _ = try await adapter.setProviderOption(id: "model", value: "sonnet", in: handle)
        var requests = await transport.requestedValues
        XCTAssertFalse(requests.contains { $0["request"]?["subtype"] == .string("set_model") })
        state = try await adapter.setProviderOption(id: "model", value: "opus", in: handle)
        XCTAssertEqual(state.selectors.first { $0.id == "model" }?.currentValue, "opus")
        requests = await transport.requestedValues
        XCTAssertEqual(requests.filter { $0["request"]?["subtype"] == .string("set_model") }.count, 1)

        // A model that takes no effort has its default already: restoring "default" asks nothing.
        state = try await adapter.setProviderOption(id: "model", value: "haiku", in: handle)
        XCTAssertNil(state.selectors.first { $0.id == "effort" })
        _ = try await adapter.setProviderOption(id: "effort", value: "default", in: handle)
        await adapter.close(handle)

        XCTAssertFalse(ClaudeProcessTransport.arguments(for: ClaudeLaunchConfiguration(
            providerSessionID: "s", workspaceURL: URL(filePath: "/tmp"), resumesExistingSession: false,
            model: "default")).contains("--model"), "Claude Code's own default needs no flag")
        XCTAssertFalse(ClaudeProcessTransport.arguments(for: ClaudeLaunchConfiguration(
            providerSessionID: "s", workspaceURL: URL(filePath: "/tmp"), resumesExistingSession: false,
            model: "--dangerously-skip-permissions")).contains("--model"))
        let withServer = ClaudeProcessTransport.arguments(for: ClaudeLaunchConfiguration(
            providerSessionID: "s", workspaceURL: URL(filePath: "/tmp"), resumesExistingSession: true,
            agentToolConfigPath: "/tmp/mcp.json", model: "opus"))
        XCTAssertEqual(Array(withServer.suffix(22)), ["--model", "opus", "--allowedTools", "mcp__yardlet__spawn_task",
                                                     "mcp__yardlet__dismiss_task", "mcp__yardlet__list_tasks",
                                                     "mcp__yardlet__read_task", "mcp__yardlet__send_message_to_task",
                                                     "mcp__yardlet__wait_tasks", "mcp__yardlet__create_task",
                                                     "mcp__yardlet__run_agent", "mcp__yardlet__archive_task",
                                                     "mcp__yardlet__list_projects", "mcp__yardlet__hide_project",
                                                     "mcp__yardlet__show_project", "mcp__yardlet__list_accounts",
                                                     "mcp__yardlet__list_personal_agents", "mcp__yardlet__read_personal_agent",
                                                     "mcp__yardlet__read_personal_agent_thread",
                                                     "mcp__yardlet__list_task_runs",
                                                     "--mcp-config", "/tmp/mcp.json"],
                       "`--mcp-config` stays last")
    }

    func testAnEffortTheNewModelDoesNotTakeGoesBackToItsDefault() {
        let catalog = ModelVisibilityFixtures.claudeModels
        XCTAssertEqual(ClaudeComposerModelProjection.choosing("model", value: "haiku", model: "fable", effort: "xhigh",
                                                              catalog: catalog)?.effort, "default")
        XCTAssertEqual(ClaudeComposerModelProjection.choosing("model", value: "opus", model: "fable", effort: "xhigh",
                                                              catalog: catalog)?.effort, "xhigh")
        XCTAssertNil(ClaudeComposerModelProjection.choosing("model", value: "unknown", model: "fable", effort: nil,
                                                            catalog: catalog))
        XCTAssertNil(ClaudeComposerModelProjection.choosing("effort", value: "high", model: "haiku", effort: nil,
                                                            catalog: catalog))
    }

    /// A list kept from a resumed session names the configured model by its full ID, while the
    /// account's settings still name the alias.
    func testAnAliasTheListNamesByItsFullIDShowsThatModelsEfforts() {
        let levels = ["low", "medium", "high", "xhigh", "max"]
        let catalog: [HarnessModelOption] = [
            .init(value: "default", name: "Default (recommended)", effortLevels: levels),
            .init(value: "opus", name: "Opus 5.5", effortLevels: levels),
            .init(value: "claude-fable-5-1", name: "Fable 5.1", effortLevels: levels),
            .init(value: "claude-fable-5", name: "Fable 5", effortLevels: ["low", "high"]),
            .init(value: "claude-haiku-4-5-20251001", name: "Haiku 4.5")
        ]
        let selectors = ClaudeComposerModelProjection.selectors(
            model: nil, effort: nil, defaults: HarnessModelDefaults(model: "fable", effort: "xhigh"), catalog: catalog)
        let menu = ComposerModelMenu.provider(selectors, speed: nil, canChoose: true)
        XCTAssertEqual(menu.model?.currentValue, "claude-fable-5-1")
        XCTAssertEqual(menu.model?.choices.map(\.value), catalog.map(\.value), "The list is offered as Claude Code gave it")
        XCTAssertEqual(menu.effort?.choices.map(\.value), ["default"] + levels)
        XCTAssertEqual(menu.title, "Fable 5.1 · " + L10n.string("Extra high"))

        XCTAssertEqual(ClaudeComposerModelProjection.choosing("effort", value: "max", model: "fable", effort: "xhigh",
                                                              catalog: catalog)?.effort, "max")
        XCTAssertNil(ClaudeComposerModelProjection.option(for: "claude-fable-6", in: catalog),
                     "A full ID the list lacks is not guessed")
        XCTAssertNil(ClaudeComposerModelProjection.option(for: "sonnet", in: catalog))
    }

    // MARK: Codex before it connects

    func testACodexTaskShowsItsModelBeforeItConnectsAndItsChoiceRunsTheFirstTurn() async throws {
        let fixture = try CodexFixture(config: "model = \"gpt-test\"\nmodel_reasoning_effort = \"high\"\n", in: self)
        let model = fixture.model, session = fixture.session

        // Nothing listed yet: the configured model shows by its ID.
        await model.refreshConversationStatus(for: session)
        var menu = ComposerModelMenu.codex(model.composerCodexCapabilities(for: session).modelCatalog)
        XCTAssertEqual(menu.title, "gpt-test · " + L10n.string("High"))
        XCTAssertFalse(menu.canChoose)

        model.modelCatalogs.recordCodex([ModelVisibilityFixtures.codexModel("gpt-test", efforts: ["low", "high"], isDefault: true),
                                         ModelVisibilityFixtures.codexModel("fast", efforts: ["low"])], for: nil)
        menu = ComposerModelMenu.codex(model.composerCodexCapabilities(for: session).modelCatalog)
        XCTAssertEqual(menu.title, "Gpt-Test · " + L10n.string("High"))
        XCTAssertTrue(menu.canChoose)
        // A thread that last reported another effort resumes on it: Codex keeps a thread's settings.
        model.modelCatalogs.recordCodex(CodexModelCatalog(models: [], selection: .init(model: "gpt-test", reasoningEffort: "low")),
                                        for: session)
        menu = ComposerModelMenu.codex(model.composerCodexCapabilities(for: session).modelCatalog)
        XCTAssertEqual(menu.title, "Gpt-Test · " + L10n.string("Low"))
        // Opening the task reads its saved thread and newest turns for display
        // (CodexDetachedThreadReadTests); the model is shown from what Yardlet keeps, and nothing
        // resumes the thread or lists models.
        let readOnly = ["initialize", "thread/read", "thread/turns/list"]
        let requestsBefore = await fixture.transport.requestMethods
        XCTAssertEqual(requestsBefore, readOnly, "Showing the model connects nothing")

        await model.selectCodexModel(CodexModelSelection(model: "fast", reasoningEffort: "low"), for: session)
        let requestsAfterChoice = await fixture.transport.requestMethods
        XCTAssertEqual(requestsAfterChoice, readOnly, "Choosing before connecting starts nothing")
        XCTAssertEqual(CodexModelSelection.restored(from: try current(model, session).providerOptions),
                       CodexModelSelection(model: "fast", reasoningEffort: "low"))
        menu = ComposerModelMenu.codex(model.composerCodexCapabilities(for: try current(model, session)).modelCatalog)
        XCTAssertEqual(menu.title, "Fast · " + L10n.string("Low"))

        await model.submitCodex(CodexComposerDraft(inputs: [.text("Run the tests")]), action: .automatic,
                                to: try current(model, session))
        let turns = await fixture.transport.requests.filter { $0.method == "turn/start" }
        XCTAssertEqual(turns.first?.params["model"]?.stringValue, "fast")
        XCTAssertEqual(turns.first?.params["effort"]?.stringValue, "low")
    }

    // MARK: New task

    func testANewClaudeTaskStartsOnTheModelChosenForItsHarness() async throws {
        let fixture = try await ClaudeFixture.make(settings: #"{"model":"fable"}"#, createsSession: false, in: self)
        let draft = NewTaskDraft()
        draft.text = "Build the feature"
        draft.workspaceURL = fixture.root
        draft.harness = .claudeCode
        fixture.model.modelCatalogs.recordClaude(ModelVisibilityFixtures.claudeModels, for: fixture.connection)
        await fixture.model.modelCatalogs.refreshDefaults(for: .claudeCode, connection: fixture.connection, workspaceURL: fixture.root)

        // Choosing on the new-task screen is remembered for the harness.
        let catalogs = fixture.model.modelCatalogs
        draft.modelChoices[.claudeCode] = NewTaskModelProjection.choosing("effort", value: "high", harness: .claudeCode,
            choice: nil, catalogs: catalogs, connection: fixture.connection, workspaceURL: fixture.root)
        XCTAssertEqual(draft.modelChoices[.claudeCode], NewTaskModelChoice(model: nil, effort: "high"),
                       "Choosing only an effort leaves the model to the account's settings")
        draft.modelChoices[.claudeCode] = NewTaskModelProjection.choosing("model", value: "opus", harness: .claudeCode,
            choice: draft.modelChoices[.claudeCode], catalogs: catalogs, connection: fixture.connection,
            workspaceURL: fixture.root)
        let menu = try XCTUnwrap(NewTaskModelProjection.menu(harness: .claudeCode, choice: draft.modelChoices[.claudeCode],
            catalogs: catalogs, connection: fixture.connection, workspaceURL: fixture.root))
        XCTAssertEqual(menu.title, "Opus · " + L10n.string("High"))
        let restored = NewTaskDraft()
        restored.apply(draft.snapshot)
        XCTAssertEqual(restored.modelChoices, draft.modelChoices)

        let submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: fixture.cli, connection: fixture.connection))
        XCTAssertEqual(submission.providerOptions, ["model": "opus", "effort": "high"])
        let created = try await fixture.model.createTask(submission)
        let task = try XCTUnwrap(created)
        XCTAssertEqual(task.providerOptions, ["model": "opus", "effort": "high"])
        let transport = try XCTUnwrap(fixture.transports.all.first)
        let configuration = await transport.configuration
        XCTAssertEqual(configuration?.model, "opus")
        let requests = await transport.requestedValues
        XCTAssertTrue(requests.contains { $0["request"]?["settings"] == .object(["effortLevel": .string("high")]) })
        let sent = await transport.sentValues
        XCTAssertEqual(sent.last?["message"]?["content"]?.stringValue, "Build the feature")
    }

    func testANewCodexTaskStartsOnTheModelChosenForItsHarness() async throws {
        let fixture = try CodexFixture(config: "model = \"gpt-test\"\n", stored: false, in: self)
        let catalogs = fixture.model.modelCatalogs
        catalogs.recordCodex([ModelVisibilityFixtures.codexModel("gpt-test", efforts: ["low", "high"], isDefault: true),
                              ModelVisibilityFixtures.codexModel("fast", efforts: ["low"])], for: nil)
        await catalogs.refreshDefaults(for: .codex, connection: nil, workspaceURL: nil)
        let draft = NewTaskDraft()
        draft.text = "Build the feature"
        draft.workspaceURL = fixture.root
        draft.harness = .codex
        XCTAssertEqual(NewTaskModelProjection.menu(harness: .codex, choice: nil, catalogs: catalogs, connection: nil,
                                                   workspaceURL: fixture.root)?.title,
                       "Gpt-Test · " + L10n.string("High"), "Before a choice: config.toml's model at its default effort")
        draft.modelChoices[.codex] = NewTaskModelProjection.choosing("model", value: "fast", harness: .codex, choice: nil,
            catalogs: catalogs, connection: nil, workspaceURL: fixture.root)
        XCTAssertEqual(draft.modelChoices[.codex]?.model, "fast")
        XCTAssertNil(NewTaskModelProjection.menu(harness: .openCode, choice: nil, catalogs: catalogs, connection: nil,
                                                 workspaceURL: fixture.root), "No list exists before an OpenCode session")

        let submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: fixture.executable))
        let created = try await fixture.model.createTask(submission)
        XCTAssertNotNil(created)
        let turns = await fixture.transport.requests.filter { $0.method == "turn/start" }
        XCTAssertEqual(turns.first?.params["model"]?.stringValue, "fast")
        XCTAssertEqual(turns.first?.params["effort"]?.stringValue, "low")
    }

    // MARK: Account

    func testTheNewTaskAccountControlNamesTheAccountItWillUse() throws {
        let root = try temporaryFolder()
        let file = root.appending(path: "provider-connections.json")
        let readings = root.appending(path: ProviderConnectionStore.snapshotCacheFileName)
        let store = ProviderConnectionStore(fileURL: file, snapshotCacheURL: readings)
        XCTAssertEqual(store.choices(for: [.codex]).first?.composerTitle, L10n.string("Checking account…"),
                       "Not yet checked: said so, rather than a generic connection")
        store.publishDefaults([snapshot(.codex, label: "person@example.test")])
        XCTAssertEqual(store.choices(for: [.codex]).first?.composerTitle, "person@example.test")

        // The next launch names the account before checking it again, from the remembered reading.
        let reopened = ProviderConnectionStore(fileURL: file, snapshotCacheURL: readings)
        XCTAssertEqual(reopened.readingStatus[AccountChoice.nativeID(for: .codex)], .remembered)
        XCTAssertEqual(reopened.choices(for: [.codex]).first?.composerTitle, "person@example.test")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "account-labels.json").path),
                       "The name comes from the remembered readings, not a second file")

        // A saved account is named by its saved name until it reports, then by the account.
        let home = root.appending(path: "claude-work")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let work = try reopened.add(name: "Work", harness: .claudeCode, home: home)
        func title() -> String? { reopened.choices(for: [.claudeCode]).first { $0.connection == work }?.composerTitle }
        XCTAssertEqual(title(), "Work")
        reopened.publish(snapshot(.claudeCode, label: "work@example.test"), for: work)
        XCTAssertEqual(title(), "work@example.test")
    }

    // MARK: Helpers

    private func claudeMenu(_ model: AppModel, _ session: SessionRecord) throws -> ComposerModelMenu {
        let state = try XCTUnwrap(model.composerProviderCapabilities(for: session))
        return ComposerModelMenu.provider(ConversationSessionStatusProjection.inlineSelectors(from: state),
            speed: nil, canChoose: model.isAttached(session.id) || state.offersModelsBeforeAttach)
    }

    private func current(_ model: AppModel, _ session: SessionRecord) throws -> SessionRecord {
        try XCTUnwrap(model.store.sessions.first { $0.id == session.id })
    }

    private func snapshot(_ harness: HarnessKind, label: String) -> HarnessAccountSnapshot {
        HarnessAccountSnapshot(id: harness.rawValue, harness: harness, providerID: nil, state: .signedIn,
            accountLabel: label, detail: "", credentialOwner: harness.displayName, checkedAt: Date(),
            usage: [], canLogin: false, canLogout: true)
    }

    private func locations(_ root: URL) -> HarnessModelSettingsLocations {
        HarnessModelSettingsLocations(claudeConfigDirectory: root.appending(path: "claude-default"),
            codexHome: root.appending(path: "codex-home"), codexYardletHome: root.appending(path: "codex-yardlet"))
    }

    private func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "model-visibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

