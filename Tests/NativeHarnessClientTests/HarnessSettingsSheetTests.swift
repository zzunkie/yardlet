import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The one per-task harness settings sheet (plan B6): which sections and rows each harness gets,
/// and that each row's command reaches the app model call the former Codex and provider sheets made.
@MainActor
final class HarnessSettingsSheetTests: XCTestCase {
    // MARK: - Sections per harness

    func testCodexSheetHasControlsSkillsAndPlugins() throws {
        var state = HarnessSettingsFixtures.codexState
        let plan = try XCTUnwrap(state.modes.first { $0.mode == "plan" })
        state.selectedModeID = plan.id
        state.errors = ["Plugins unavailable: offline"]
        state.actionMessage = L10n.format("Mode selected: %@", "Plan")

        let content = HarnessSettingsSheetProjection.content(
            source: HarnessSettingsSource(harness: .codex), codex: state,
            provider: HarnessSettingsFixtures.claudeState, canBranch: true
        )

        XCTAssertEqual(content.sections, [.controls, .skills, .plugins])
        XCTAssertEqual(content.controls.map(\.id), ["codex.collaborationMode", "fork", "codex.review"])
        guard case let .selector(currentTitle, choices) = content.controls[0].kind else {
            return XCTFail("The collaboration mode is a selector")
        }
        XCTAssertEqual(currentTitle, "Plan")
        XCTAssertEqual(choices.map(\.title), [L10n.string("Harness default"), "Default", "Plan"])
        XCTAssertEqual(choices.map(\.startsGroup), [false, true, false], "Presets follow the default after a divider")
        let modeCommands = state.modes.map { HarnessSettingsCommand.selectCodexMode($0.id) }
        XCTAssertEqual(choices.map(\.command), [HarnessSettingsCommand.selectCodexMode(nil)] + modeCommands)
        XCTAssertEqual(content.controls[1].kind, .action(buttonTitle: L10n.string("Fork"), command: .fork))
        XCTAssertEqual(content.controls[2].kind,
                       .action(buttonTitle: L10n.string("Start review"), command: .reviewCodexWorkingTree))
        XCTAssertTrue(content.notes.isEmpty)

        XCTAssertEqual(content.skills?.map(\.title), ["OpenAI Docs", "Verification", "Drafts"])
        XCTAssertEqual(content.skills?.map(\.detail), ["user", "plugin", "repo"])
        XCTAssertEqual(content.skills?.map(\.switchState), [
            .init(target: .codexSkill(path: "/fixture/openai-docs/SKILL.md"), isOn: true),
            .init(target: .codexSkill(path: "/fixture/verification/SKILL.md"), isOn: true),
            .init(target: .codexSkill(path: "/fixture/drafts/SKILL.md"), isOn: false)
        ], "Each skill has a switch showing whether Codex has it on")
        XCTAssertEqual(content.skills?.map(\.badges), [[], [], []], "The switch says what a badge said")
        XCTAssertEqual(content.switchNote, L10n.string("Applies to all tasks on this account, starting with new tasks."))
        XCTAssertNil(content.skills?.last?.description, "An empty description is left out")
        XCTAssertEqual(content.plugins?.map(\.title), ["GitHub", "Linear", "Figma"])
        let installed = L10n.string("Installed"), disabled = L10n.string("Disabled")
        XCTAssertEqual(content.plugins?.map { $0.badges.map(\.text) },
                       [[installed], [installed, disabled], [L10n.string("Available")]])
        XCTAssertEqual(content.plugins?.map { $0.badges.map(\.tone) },
                       [[.positive], [.positive, .warning], [.neutral]])
        XCTAssertEqual(content.plugins?.compactMap(\.switchState), [], "Codex only installs and removes plugins")
        XCTAssertEqual(content.errors, ["Plugins unavailable: offline"])
        XCTAssertEqual(content.actionMessage, L10n.format("Mode selected: %@", "Plan"))
    }

    func testCodexSheetFallsBackToTheHarnessDefaultAndOffersForkOnlyWhenTheTaskCanBranch() {
        var state = HarnessSettingsFixtures.codexState
        state.selectedModeID = "a preset the runtime no longer lists"
        let content = HarnessSettingsSheetProjection.codexContent(state, canBranch: false)

        XCTAssertEqual(content.controls.map(\.id), ["codex.collaborationMode", "codex.review"])
        guard case let .selector(currentTitle, _) = content.controls[0].kind else {
            return XCTFail("The collaboration mode is a selector")
        }
        XCTAssertEqual(currentTitle, L10n.string("Harness default"))

        let empty = HarnessSettingsSheetProjection.codexContent(.empty, canBranch: false)
        XCTAssertEqual(empty.sections, [.controls, .skills, .plugins],
                       "Codex reports skills and plugins; an empty list shows its empty state")
        XCTAssertEqual(empty.skills, [])
        XCTAssertEqual(empty.plugins, [])
        guard case let .selector(_, choices) = empty.controls[0].kind else {
            return XCTFail("The collaboration mode is a selector")
        }
        XCTAssertEqual(choices.map(\.command), [.selectCodexMode(nil)])
    }

    func testClaudeCodeSheetHasControlsOnly() {
        let content = HarnessSettingsSheetProjection.content(
            source: HarnessSettingsSource(harness: .claudeCode), codex: HarnessSettingsFixtures.codexState,
            provider: HarnessSettingsFixtures.claudeState, canBranch: true
        )

        XCTAssertEqual(content.sections, [.controls])
        XCTAssertNil(content.skills)
        XCTAssertNil(content.plugins)
        XCTAssertEqual(content.controls.map(\.id), ["option.model", "option.permissionMode", "fork"])
        XCTAssertEqual(content.controls.map(\.systemImage),
                       ["cpu", "switch.2", "point.topleft.down.to.point.bottomright.curvepath"])
        XCTAssertEqual(content.controls[0].kind, .selector(currentTitle: "Sonnet", choices: [
            HarnessSettingsChoice(id: "sonnet", title: "Sonnet",
                                  command: .setProviderOption(id: "model", value: "sonnet")),
            HarnessSettingsChoice(id: "opus", title: "Opus", command: .setProviderOption(id: "model", value: "opus"))
        ]))
        XCTAssertEqual(content.controls[0].description, "Change the model for the active Claude Code session.")
        XCTAssertEqual(content.controls[2].kind, .action(buttonTitle: L10n.string("Fork"), command: .fork),
                       "The fork row is the same row Codex has")
        XCTAssertEqual(content.notes, ["Skills, agents, plugins, hooks, and MCP remain owned by Claude Code settings."])
        XCTAssertNil(content.switchNote)

        // Once the sheet has read the account's plugins, each has a switch, off ones included.
        let switches = HarnessSwitchState(accountPlugins: HarnessSettingsFixtures.claudePlugins, reach: .sharedSettings,
                                          errors: ["Couldn't turn on demo: refused"])
        let listed = HarnessSettingsSheetProjection.content(
            source: .provider, codex: .empty, provider: HarnessSettingsFixtures.claudeState, switches: switches,
            canBranch: true
        )
        XCTAssertEqual(listed.sections, [.controls, .plugins])
        XCTAssertNil(listed.skills, "Claude Code skills outside plugins have no switch of the harness's own")
        XCTAssertEqual(listed.plugins?.map(\.title), ["frontend-design", "playwright"])
        XCTAssertEqual(listed.plugins?.map(\.detail), ["claude-plugins-official", "claude-plugins-official"])
        XCTAssertEqual(listed.plugins?.map(\.switchState), [
            .init(target: .accountPlugin(id: "frontend-design@claude-plugins-official"), isOn: true),
            .init(target: .accountPlugin(id: "playwright@claude-plugins-official"), isOn: false)
        ])
        XCTAssertEqual(listed.switchNote, L10n.string(
            "Applies to all tasks on the accounts that share these settings, starting with new tasks."))
        XCTAssertEqual(listed.errors, ["Couldn't turn on demo: refused"])
    }

    func testACPSheetShowsTheSessionsOwnOptionsAndActions() throws {
        var state = HarnessSettingsFixtures.openCodeState
        state.actions = [HarnessSettingsFixtures.compactAction]
        state.errors = ["The agent closed the session."]
        let content = HarnessSettingsSheetProjection.content(
            source: HarnessSettingsSource(harness: .openCode), codex: .empty, provider: state, canBranch: false
        )

        XCTAssertEqual(content.sections, [.controls])
        XCTAssertEqual(content.controls.map(\.id), ["option.mode", "option.model", "action.compact"])
        guard case let .selector(currentTitle, choices) = content.controls[0].kind else {
            return XCTFail("An ACP config option is a selector")
        }
        XCTAssertEqual(currentTitle, "Ask")
        XCTAssertEqual(choices.map(\.command), [.setProviderOption(id: "mode", value: "ask"),
                                                .setProviderOption(id: "mode", value: "code")])
        XCTAssertEqual(content.controls[2].kind,
                       .action(buttonTitle: L10n.string("Run"), command: .performProviderAction(id: "compact")))
        XCTAssertEqual(content.controls[2].description, "Summarize older context while preserving the active session.")
        XCTAssertEqual(content.controls[2].systemImage, HarnessSettingsFixtures.compactAction.systemImage)
        XCTAssertEqual(content.notes, [L10n.string("These controls are provided by the active ACP session.")])
        XCTAssertEqual(content.errors, ["The agent closed the session."])
    }

    func testAProviderWithoutLiveControlsShowsOnlyItsNotes() {
        let unsupported = ProviderCapabilityState(notes: ["Cursor Agent did not expose configurable options."])
        let content = HarnessSettingsSheetProjection.providerContent(unsupported, canBranch: false)

        XCTAssertTrue(content.controls.isEmpty, "Nothing is offered that the provider did not report")
        XCTAssertEqual(content.notes, ["Cursor Agent did not expose configurable options."])
        XCTAssertEqual(content.sections, [.controls])

        let unknownValue = ProviderCapabilityState(selectors: [ProviderCapabilitySelector(
            id: "mode", name: "Mode", description: nil, category: nil, currentValue: "future-mode", choices: []
        )])
        XCTAssertEqual(HarnessSettingsSheetProjection.providerContent(unknownValue, canBranch: false).controls[0].kind,
                       .selector(currentTitle: "future-mode", choices: []))
    }

    func testTheSourceAndTheInitialSectionFollowWhatTheProviderReports() {
        XCTAssertEqual(HarnessSettingsSource(harness: .codex), .codex)
        for harness in [HarnessKind.claudeCode, .openCode, .grokBuild, .pi, .cursorAgent] {
            XCTAssertEqual(HarnessSettingsSource(harness: harness), .provider, harness.rawValue)
        }

        let codex = HarnessSettingsSheetProjection.codexContent(HarnessSettingsFixtures.codexState, canBranch: true)
        let claude = HarnessSettingsSheetProjection.providerContent(HarnessSettingsFixtures.claudeState, canBranch: true)
        XCTAssertEqual(codex.section(named: "plugins"), .plugins)
        XCTAssertEqual(codex.section(named: "history"), .controls, "History moved to the import sheet (B18)")
        XCTAssertEqual(codex.section(named: nil), .controls)
        XCTAssertEqual(claude.section(named: "skills"), .controls, "A section the provider does not report is not opened")
    }

    // MARK: - Routing

    func testEachCommandReachesTheCallTheFormerSheetsMade() async {
        let recorder = HarnessSettingsCallRecorder()
        let actions = recorder.actions()
        let commands: [HarnessSettingsCommand] = [
            .selectCodexMode("plan|plan||"), .selectCodexMode(nil),
            .setProviderOption(id: "model", value: "opus"), .performProviderAction(id: "compact"),
            .fork, .reviewCodexWorkingTree, .setSwitch(.accountPlugin(id: "demo@market"), enabled: false)
        ]
        for command in commands { await actions.run(command) }
        await actions.refresh(.codex)
        await actions.refresh(.provider)
        await actions.open(.provider, sourceIsLoaded: true)
        await actions.open(.codex, sourceIsLoaded: false)

        XCTAssertEqual(recorder.calls, [
            "selectCodexMode(plan|plan||)", "selectCodexMode(default)",
            "setProviderOption(model, opus)", "performProviderAction(compact)",
            "fork", "reviewCodexWorkingTree", "setSwitch(accountPlugin(id: \"demo@market\"), false)",
            "loadCodex", "loadSwitches", "loadProvider", "loadSwitches",
            "loadSwitches", "loadCodex", "loadSwitches"
        ], "Opening reads the switches every time, and the source only when the task lacks it")
        XCTAssertTrue(recorder.dismissals == 0, "Running a command does not close the sheet by itself")
    }

    func testForkAndReviewCloseTheSheetBeforeTheyStart() async {
        for command in [HarnessSettingsCommand.fork, .reviewCodexWorkingTree] {
            let recorder = HarnessSettingsCallRecorder()
            recorder.actions().perform(command)
            XCTAssertEqual(recorder.dismissals, 1, "\(command)")
            XCTAssertEqual(recorder.calls, [], "The sheet closes first; the call follows in a task")
            await recorder.waitForCalls(1)
            XCTAssertEqual(recorder.calls.count, 1)
        }
        for command in [HarnessSettingsCommand.selectCodexMode(nil), .setProviderOption(id: "model", value: "opus"),
                        .performProviderAction(id: "compact"), .setSwitch(.codexSkill(path: "/fixture/SKILL.md"), enabled: true)] {
            let recorder = HarnessSettingsCallRecorder()
            recorder.actions().perform(command)
            await recorder.waitForCalls(1)
            XCTAssertEqual(recorder.dismissals, 0, "\(command) keeps the sheet open")
        }
    }

    // MARK: - Through the app model

    func testCodexSheetActionsReachTheAppModel() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter }
        )
        let created = await model.createSession(
            harness: .codex, workspaceURL: URL(filePath: "/fixture/harness-settings"),
            runtimeExecutableURL: URL(filePath: "/fixture/codex"), title: "Settings source"
        )
        let session = try XCTUnwrap(created)
        var dismissals = 0
        let actions = HarnessSettingsActions(model: model, session: session, dismiss: { dismissals += 1 })

        XCTAssertFalse(model.hasLoadedHarnessSettings(for: session))
        await model.loadCodexModels(for: session)
        XCTAssertNotNil(model.codexCapabilitiesBySessionID[session.id])
        XCTAssertFalse(model.hasLoadedHarnessSettings(for: session),
                       "The composer's model read does not stand in for the sheet's listing")
        let pluginReadsBefore = await adapter.composerPluginReads
        await actions.refresh(HarnessSettingsSource(harness: session.harness))
        XCTAssertTrue(model.hasLoadedHarnessSettings(for: session))
        let pluginReadsAfter = await adapter.composerPluginReads
        XCTAssertEqual(pluginReadsAfter - pluginReadsBefore, 1, "Refresh lists the sheet's capabilities")

        var content = model.harnessSettings(for: session)
        XCTAssertEqual(content.sections, [.controls, .skills, .plugins])
        XCTAssertEqual(content.controls.map(\.id), ["codex.collaborationMode", "fork", "codex.review"])
        guard case let .selector(_, choices) = content.controls[0].kind, let plan = choices.last else {
            return XCTFail("The collaboration mode is a selector with the runtime's presets")
        }
        XCTAssertEqual(plan.title, "Plan")

        await actions.run(plan.command)
        let selected = await adapter.selectedCollaborationPresets
        XCTAssertEqual(selected.map { $0?.name }, ["Plan"])
        content = model.harnessSettings(for: session)
        XCTAssertEqual(content.controls[0].kind.currentTitle, "Plan")
        XCTAssertEqual(content.actionMessage, L10n.format("Mode selected: %@", "Plan"))

        await actions.run(.reviewCodexWorkingTree)
        XCTAssertEqual(model.harnessSettings(for: session).actionMessage, L10n.string("Working tree review started"))

        // An App Server that cannot write the skill's setting leaves the list as it was and says why.
        let skillsBefore = model.harnessSettings(for: session).skills
        await actions.run(.setSwitch(.codexSkill(path: "/fixture/SKILL.md"), enabled: false))
        content = model.harnessSettings(for: session)
        XCTAssertEqual(content.skills, skillsBefore)
        XCTAssertEqual(content.errors, [L10n.format("Couldn't turn off %@: %@", "/fixture/SKILL.md",
                                                    L10n.string("This harness cannot turn skills on or off"))])

        await actions.run(.fork)
        let forkedFrom = await adapter.forkedFromSessionIDs
        XCTAssertEqual(forkedFrom, [session.id])
        XCTAssertNotEqual(model.store.selectedSessionID, session.id, "The fork opens as its own task")
        XCTAssertEqual(dismissals, 0)
        await model.shutdown()
    }

    func testProviderSheetActionsReachTheAppModelAndFailClosed() async throws {
        let session = SessionRecord(
            harness: .cursorAgent, workspaceURL: URL(filePath: "/fixture/harness-settings-provider"),
            runtimeExecutableURL: URL(filePath: "/fixture/cursor-agent"), title: "Cursor task",
            providerSessionID: "cursor-session"
        )
        let adapter = FakeHarnessAdapter(kind: .cursorAgent)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let model = AppModel(
            store: SessionStore(sessions: [session], repository: InMemorySessionRepository(sessions: [session])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            restoresIndexOnLaunch: false
        )
        let actions = HarnessSettingsActions(model: model, session: session, dismiss: {})

        await actions.refresh(HarnessSettingsSource(harness: session.harness))
        var content = model.harnessSettings(for: session)
        XCTAssertEqual(content.sections, [.controls])
        XCTAssertEqual(content.controls.map(\.id), ["option.\(StructuredHeadlessOptionID.executionMode)"],
                       "No fork: this adapter cannot branch")
        XCTAssertEqual(content.controls[0].kind.currentTitle, "Default")

        await actions.run(.setProviderOption(id: StructuredHeadlessOptionID.executionMode, value: "plan"))
        let selections = await adapter.providerOptionSelections
        XCTAssertEqual(selections[StructuredHeadlessOptionID.executionMode], "plan")
        XCTAssertEqual(model.store.sessions.first?.providerOptions[StructuredHeadlessOptionID.executionMode], "plan")
        content = model.harnessSettings(for: session)
        XCTAssertEqual(content.controls[0].kind.currentTitle, "Plan")

        await actions.run(.performProviderAction(id: "compact"))
        content = model.harnessSettings(for: session)
        XCTAssertEqual(content.actionMessage, "fixture action unavailable",
                       "A refused action reports the provider's reason and changes nothing")
        XCTAssertEqual(content.controls.map(\.id), ["option.\(StructuredHeadlessOptionID.executionMode)"])
        await model.shutdown()
    }
}

@MainActor
final class HarnessSettingsSwitchTests: XCTestCase {
    /// A Claude Code task's plugin switches: listed from the account's adapter without starting the
    /// task, changed through it, and a refused change leaves the row as the harness last listed it.
    /// The note says the change reaches every account reading the same settings file.
    func testClaudeCodePluginSwitchesGoThroughTheHarnessAndFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "harness-switches-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultFolder = root.appending(path: "default-claude"), accountFolder = root.appending(path: "account")
        for folder in [defaultFolder, accountFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: defaultFolder.appending(path: "settings.json"))
        // An account folder Yardlet made reads the default folder's settings through a link.
        try FileManager.default.createSymbolicLink(at: accountFolder.appending(path: "settings.json"),
                                                   withDestinationURL: defaultFolder.appending(path: "settings.json"))
        let connections = ProviderConnectionStore()
        connections.defaultLoginEnvironment = ["CLAUDE_CONFIG_DIR": defaultFolder.path(percentEncoded: false)]
        connections.homeURL = root
        let account = ProviderConnection(id: "work", name: "Work", harness: .claudeCode, providerID: nil,
                                         homePath: accountFolder.path(percentEncoded: false), credentialSelector: nil)
        let session = SessionRecord(
            harness: .claudeCode, workspaceURL: URL(filePath: "/fixture/harness-switches"),
            runtimeExecutableURL: URL(filePath: "/fixture/claude"), title: "Plugins", connection: account
        )
        let adapter = FakeHarnessAdapter(kind: .claudeCode)
        await adapter.stageAccountPlugins(HarnessSettingsFixtures.claudePlugins)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let model = AppModel(
            store: SessionStore(sessions: [session], repository: InMemorySessionRepository(sessions: [session])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            connections: connections,
            restoresIndexOnLaunch: false
        )
        let actions = HarnessSettingsActions(model: model, session: session, dismiss: {})

        await actions.open(.provider, sourceIsLoaded: true)
        var content = model.harnessSettings(for: session)
        XCTAssertFalse(model.isAttached(session.id), "Listing the account's plugins starts no session")
        XCTAssertEqual(content.sections, [.controls, .plugins])
        XCTAssertEqual(content.plugins?.map { $0.switchState?.isOn }, [true, false])
        XCTAssertEqual(content.switchNote, L10n.string(
            "Applies to all tasks on the accounts that share these settings, starting with new tasks."))

        await actions.run(.setSwitch(.accountPlugin(id: "playwright@claude-plugins-official"), enabled: true))
        content = model.harnessSettings(for: session)
        XCTAssertEqual(content.plugins?.map { $0.switchState?.isOn }, [true, true], "The row follows the harness")
        XCTAssertEqual(content.errors, [])

        await adapter.refuseAccountPluginSwitches("settings.json is read-only")
        await actions.run(.setSwitch(.accountPlugin(id: "frontend-design@claude-plugins-official"), enabled: false))
        content = model.harnessSettings(for: session)
        XCTAssertEqual(content.plugins?.map { $0.switchState?.isOn }, [true, true], "A refused switch stays where it was")
        XCTAssertEqual(content.errors, [L10n.format("Couldn't turn off %@: %@", "frontend-design",
                                                    "settings.json is read-only")])
        let asked = await adapter.accountPluginSwitches
        XCTAssertEqual(asked, ["playwright@claude-plugins-official=true", "frontend-design@claude-plugins-official=false"])

        // A folder with its own settings file reaches only its own tasks.
        try FileManager.default.removeItem(at: accountFolder.appending(path: "settings.json"))
        try Data("{}".utf8).write(to: accountFolder.appending(path: "settings.json"))
        await actions.open(.provider, sourceIsLoaded: true)
        XCTAssertEqual(model.harnessSettings(for: session).switchNote,
                       L10n.string("Applies to all tasks on this account, starting with new tasks."))
        await model.shutdown()
    }
}

/// Window-less renders of the sheet for Codex, Claude Code and an ACP harness (OpenCode), light
/// and dark, under `.build/harness-settings-qa/`, and what each exposes to accessibility. Names
/// start with the language the run draws in (`-AppleLanguages '(ko)'` for Korean).
@MainActor
final class HarnessSettingsSheetRenderingTests: XCTestCase {
    private let size = NSSize(width: 680, height: 520)

    func testTheSheetDrawsTheSameLayoutForEveryHarness() throws {
        let directory = try WindowlessRender.directory("harness-settings-qa")
        let fixture = VisualFixtureScenario.makeConversation(
            workspaceURL: URL(filePath: "/fixture/yardlet"), initialTaskSurface: nil
        )
        let codexSession = try XCTUnwrap(fixture.sessions.first { $0.harness == .codex })
        let claudeSession = try XCTUnwrap(fixture.sessions.first { $0.harness == .claudeCode })
        let openCodeSession = SessionRecord(
            harness: .openCode, workspaceURL: URL(filePath: "/fixture/yardlet"),
            runtimeExecutableURL: URL(filePath: "/fixture/opencode"), title: "Tidy the ACP settings"
        )
        var codexState = try XCTUnwrap(fixture.codexCapabilities[codexSession.id])
        codexState.actionMessage = L10n.format("Mode selected: %@", "Plan")
        codexState.selectedModeID = codexState.modes.last?.id
        let codex = HarnessSettingsSheetProjection.codexContent(codexState, canBranch: true)
        let claude = HarnessSettingsSheetProjection.providerContent(
            try XCTUnwrap(fixture.providerCapabilities[claudeSession.id]), canBranch: true
        )
        let openCode = HarnessSettingsSheetProjection.providerContent(
            HarnessSettingsFixtures.openCodeState, canBranch: false
        )
        // The account's plugins, one off, after a switch the harness refused.
        let claudePlugins = HarnessSettingsSheetProjection.providerContent(
            try XCTUnwrap(fixture.providerCapabilities[claudeSession.id]),
            switches: HarnessSwitchState(
                accountPlugins: HarnessSettingsFixtures.claudePlugins, reach: .sharedSettings,
                errors: [L10n.format("Couldn't turn on %@: %@", "playwright",
                                     "Plugin \"playwright@claude-plugins-official\" was not found in its marketplace")]),
            canBranch: true
        )
        let language = L10n.string("Done") == "완료" ? "ko" : "en"

        let renders: [(name: String, session: SessionRecord, content: HarnessSettingsSheetContent, section: String?)] = [
            ("codex-controls", codexSession, codex, nil),
            ("codex-skills", codexSession, codex, "skills"),
            ("codex-plugins", codexSession, codex, "plugins"),
            ("claude-code-controls", claudeSession, claude, nil),
            ("claude-code-plugins", claudeSession, claudePlugins, "plugins"),
            ("opencode-controls", openCodeSession, openCode, nil)
        ]
        var axLists: [String] = []
        for render in renders {
            let captures = try WindowlessRender.hostedInBothAppearances("\(language)-\(render.name)", in: directory,
                                                                        size: size) {
                sheet(render.session, render.content, section: render.section)
                    .environment(\.colorScheme, $0.colorScheme)
            }
            for capture in captures {
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 24), render.name)
            }
            let host = WindowlessRender.Host(sheet(render.session, render.content, section: render.section), size: size)
            host.settle()
            let elements = host.accessibilityElements()
            host.close()
            axLists.append("# \(render.name)\n" + elements.map(\.description).joined(separator: "\n"))

            // The same header for every harness: its name, the task, refresh and Done.
            XCTAssertTrue(elements.contains { $0.value == render.session.harness.displayName }, render.name)
            XCTAssertTrue(elements.contains { $0.label == L10n.string("Refresh capabilities") }, render.name)
            XCTAssertTrue(elements.contains { $0.role == "AXButton" && $0.label == L10n.string("Done") }, render.name)
            // Every control row has its control at the trailing edge: a menu showing the current
            // choice for a selector, a button named after the row for an action.
            if render.section == nil {
                for control in render.content.controls {
                    let found = switch control.kind {
                    case let .selector(currentTitle, _):
                        elements.contains { $0.role == "AXMenuButton" && $0.value == currentTitle }
                    case .action:
                        elements.contains { $0.role == "AXButton" && $0.label == control.title }
                    }
                    XCTAssertTrue(found, "\(render.name): \(control.title)")
                }
            }
            // A row with a switch offers it under the row's name, with the note saying whose tasks it reaches.
            let rows = render.section == "skills" ? render.content.skills : render.section == "plugins" ? render.content.plugins : nil
            for row in rows ?? [] where row.switchState != nil {
                XCTAssertTrue(elements.contains { $0.role == "AXCheckBox" && $0.label == row.title },
                              "\(render.name): \(row.title)")
            }
            if let note = render.content.switchNote, rows?.contains(where: { $0.switchState != nil }) == true {
                XCTAssertTrue(elements.contains { $0.label.contains(note) || $0.value.contains(note) }, render.name)
            }
            // The section picker appears only when there is more than one section.
            let hasPicker = elements.contains { $0.label == L10n.string("Harness settings sections") }
            XCTAssertEqual(hasPicker, render.content.sections.count > 1, render.name)
        }
        try axLists.joined(separator: "\n\n").write(to: directory.appending(path: "\(language)-sheets-ax.txt"),
                                                     atomically: true, encoding: .utf8)
    }

    private func sheet(
        _ session: SessionRecord, _ content: HarnessSettingsSheetContent, section: String?
    ) -> HarnessSettingsSheet {
        HarnessSettingsSheet(session: session, content: content, onRefresh: {}, onCommand: { _ in },
                             onDismiss: {}, initialSection: section)
    }
}

// MARK: - Fixtures

@MainActor
private final class HarnessSettingsCallRecorder {
    private(set) var calls: [String] = []
    private(set) var dismissals = 0

    func actions() -> HarnessSettingsActions {
        HarnessSettingsActions(
            loadCodex: { self.calls.append("loadCodex") },
            loadProvider: { self.calls.append("loadProvider") },
            selectCodexMode: { self.calls.append("selectCodexMode(\($0 ?? "default"))") },
            setProviderOption: { self.calls.append("setProviderOption(\($0), \($1))") },
            performProviderAction: { self.calls.append("performProviderAction(\($0))") },
            fork: { self.calls.append("fork") },
            reviewCodexWorkingTree: { self.calls.append("reviewCodexWorkingTree") },
            loadSwitches: { self.calls.append("loadSwitches") },
            setSwitch: { self.calls.append("setSwitch(\($0), \($1))") },
            dismiss: { self.dismissals += 1 }
        )
    }

    func waitForCalls(_ count: Int) async {
        for _ in 0..<200 where calls.count < count {
            await Task.yield()
        }
    }
}

private extension HarnessSettingsControl.Kind {
    var currentTitle: String? {
        if case let .selector(currentTitle, _) = self { return currentTitle }
        return nil
    }
}

private enum HarnessSettingsFixtures {
    static var codexState: CodexCapabilityState {
        CodexCapabilityState(
            modes: [
                CodexCollaborationPreset(name: "Default", mode: "default", model: nil, reasoningEffort: nil),
                CodexCollaborationPreset(name: "Plan", mode: "plan", model: nil, reasoningEffort: nil)
            ],
            skills: [
                CodexSkillSummary(name: "openai-docs", displayName: "OpenAI Docs",
                                  description: "Use official OpenAI developer documentation.", enabled: true,
                                  scope: "user", path: "/fixture/openai-docs/SKILL.md"),
                CodexSkillSummary(name: "verification", displayName: "Verification",
                                  description: "Verify the complete product flow end to end.", enabled: true,
                                  scope: "plugin", path: "/fixture/verification/SKILL.md"),
                CodexSkillSummary(name: "drafts", displayName: "Drafts", description: "", enabled: false,
                                  scope: "repo", path: "/fixture/drafts/SKILL.md")
            ],
            plugins: [
                CodexPluginSummary(id: "github", name: "github", displayName: "GitHub",
                                   description: "Repository workflows.", installed: true, enabled: true,
                                   availability: "AVAILABLE", marketplace: "OpenAI Curated"),
                CodexPluginSummary(id: "linear", name: "linear", displayName: "Linear",
                                   description: "Issue workflows.", installed: true, enabled: false,
                                   availability: "AVAILABLE", marketplace: "OpenAI Curated"),
                CodexPluginSummary(id: "figma", name: "figma", displayName: "Figma", description: nil,
                                   installed: false, enabled: false, availability: "AVAILABLE",
                                   marketplace: "OpenAI Curated")
            ]
        )
    }

    static var claudeState: ProviderCapabilityState {
        ProviderCapabilityState(
            selectors: [
                ProviderCapabilitySelector(
                    id: "model", name: "Model", description: "Change the model for the active Claude Code session.",
                    category: "model", currentValue: "sonnet",
                    choices: [ProviderCapabilityChoice(value: "sonnet", name: "Sonnet", description: nil),
                              ProviderCapabilityChoice(value: "opus", name: "Opus", description: nil)]
                ),
                ProviderCapabilitySelector(
                    id: "permissionMode", name: "Permission mode",
                    description: "Controls how Claude Code asks before using tools.", category: "mode",
                    currentValue: "manual",
                    choices: [ProviderCapabilityChoice(value: "manual", name: "Manual", description: nil),
                              ProviderCapabilityChoice(value: "plan", name: "Plan", description: nil)]
                )
            ],
            notes: ["Skills, agents, plugins, hooks, and MCP remain owned by Claude Code settings."]
        )
    }

    static let claudePlugins = [
        HarnessAccountPlugin(id: "frontend-design@claude-plugins-official", name: "frontend-design",
                             marketplace: "claude-plugins-official",
                             description: "Frontend design skill for UI/UX implementation", isEnabled: true),
        HarnessAccountPlugin(id: "playwright@claude-plugins-official", name: "playwright",
                             marketplace: "claude-plugins-official", description: nil, isEnabled: false)
    ]

    /// What OpenCode's ACP session reports, through the adapter's own projector.
    static var openCodeState: ProviderCapabilityState {
        func option(_ id: String, _ name: String, category: String, current: String,
                    _ values: [(String, String)]) -> JSONValue {
            .object([
                "id": .string(id), "name": .string(name), "type": .string("select"),
                "category": .string(category), "currentValue": .string(current),
                "options": .array(values.map { .object(["value": .string($0.0), "name": .string($0.1)]) })
            ])
        }
        return ACPCapabilityProjector().state(from: .object(["configOptions": .array([
            option("mode", "Mode", category: "mode", current: "ask", [("ask", "Ask"), ("code", "Code")]),
            option("model", "Model", category: "model", current: "sonnet-4",
                   [("sonnet-4", "Claude Sonnet 4"), ("gpt-5", "GPT-5")])
        ])]), harness: .openCode)
    }

    static let compactAction = ProviderCapabilityAction(
        id: ProviderCapabilityActionID.compact,
        title: "Compact conversation",
        description: "Summarize older context while preserving the active session.",
        systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
    )
}
