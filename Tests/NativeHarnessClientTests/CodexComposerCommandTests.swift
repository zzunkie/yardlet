import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The Codex app's composer slash commands in a Codex task: the list, its search, availability
/// while idle or running, and the native request each command sends.
@MainActor
final class CodexComposerCommandTests: XCTestCase {
    // MARK: - Catalog

    func testCatalogOffersTheCodexAppCommandsWithItsIDsWordingAndOrder() {
        let rows = CodexComposerCommands.catalog(fullContext())
        let fixed = rows.filter { $0.group == nil }
        XCTAssertEqual(Set(fixed.map(\.name)), ["archive", "review-mode", "compact", "service-tier:priority", "fork", "init",
            "model", "new", "pin", "plan-mode", "reasoning", "rename", "side", "status"])
        XCTAssertEqual(fixed.map(\.displayTitle), fixed.map(\.displayTitle).sorted(), "Listed by title, as the Codex app sorts")
        XCTAssertEqual(rows.filter { $0.group != nil }.map(\.name), ["skill:docs", "skill:release-notes"],
                       "Skills follow the commands under their own heading")
        XCTAssertTrue(rows.allSatisfy { $0.title != nil && $0.argumentHint.isEmpty })
        XCTAssertEqual(rows.last?.group, L10n.string("Skills"))

        func row(_ name: String) -> ProviderComposerCommand? { rows.first { $0.name == name } }
        XCTAssertEqual(row("compact")?.title, L10n.string("Compact slash command"))
        XCTAssertEqual(row("compact")?.description, L10n.format("Compact this chat's context (%lld%% full)", Int64(25)))
        XCTAssertEqual(row("reasoning")?.description, CodexReasoningLabel.name("high"))
        XCTAssertEqual(row("model")?.description, "")
        XCTAssertEqual(row("service-tier:priority")?.title, "Fast")
        XCTAssertEqual(row("service-tier:priority")?.description, "2x speed, increased usage")
        XCTAssertEqual(row("plan-mode")?.description, L10n.string("Turn plan mode on"))
        XCTAssertEqual(row("fork")?.description, L10n.string("Fork this chat"))
        XCTAssertEqual(row("skill:release-notes")?.title, "Release notes")

        // The Codex app's own English and Korean wording.
        let wording: [(String, String, String)] = [
            ("Compact slash command", "Compact", "압축"),
            ("Compact this chat's context", "Compact this chat's context", "이 채팅의 컨텍스트를 압축합니다"),
            ("Compact is disabled while a chat is in progress", "Compact is disabled while a chat is in progress",
             "채팅이 진행 중일 때는 Compact를 사용할 수 없습니다"),
            ("Code review", "Code review", "코드 검토"),
            ("Review uncommitted changes or compare against a branch", "Review uncommitted changes or compare against a branch",
             "커밋되지 않은 변경 사항을 검토하거나 브랜치와 비교합니다"),
            ("Fork chat", "Fork chat", "채팅 포크하기"), ("Fork this chat", "Fork this chat", "이 채팅 포크하기"),
            ("New chat", "New chat", "새 채팅"),
            ("Start a blank chat in the same workspace", "Start a blank chat in the same workspace", "같은 워크스페이스에서 빈 채팅 시작"),
            ("Rename", "Rename", "이름 변경"), ("Rename the current chat", "Rename the current chat", "현재 채팅 이름을 변경합니다"),
            ("Pin chat", "Pin chat", "채팅 고정"), ("Keep this chat in the sidebar", "Keep this chat in the sidebar", "이 채팅을 사이드바에 유지합니다"),
            ("Archive", "Archive", "보관"), ("Archive the current chat", "Archive the current chat", "현재 채팅을 보관합니다"),
            ("Model", "Model", "모델"), ("Reasoning slash command", "Reasoning", "추론 수준"),
            ("Plan mode", "Plan mode", "계획 모드"), ("Turn plan mode on", "Turn plan mode on", "계획 모드 켜기"),
            ("Turn plan mode off", "Turn plan mode off", "계획 모드 끄기"),
            ("Init", "Init", "초기화"),
            ("Create an AGENTS.md file with instructions for Codex", "Create an AGENTS.md file with instructions for Codex",
             "Codex용 지침이 담긴 AGENTS.md 파일을 작성합니다"),
            ("Side", "Side", "사이드"), ("Start a temporary side chat", "Start a temporary side chat", "임시 별도 채팅을 시작합니다"),
            ("Plan mode indicator", "Plan", "계획"), ("Create a plan", "Create a plan", "플랜 생성")
        ]
        for (key, english, korean) in wording {
            XCTAssertEqual(L10n.string(key, languageCode: "en"), english, key)
            XCTAssertEqual(L10n.string(key, languageCode: "ko"), korean, key)
        }
        XCTAssertEqual(String(format: L10n.string("Compact this chat's context (%lld%% full)", languageCode: "ko"), Int64(25)),
                       "이 채팅의 컨텍스트를 압축합니다(25% 참)")
        XCTAssertEqual(String(format: L10n.string("Turn off %@ and return to standard speed", languageCode: "ko"), "Fast"),
                       "Fast을(를) 끄고 표준 속도로 돌아갑니다")
    }

    func testAvailabilityFollowsTheCodexAppWhileIdleRunningOrWithDraftText() {
        var context = fullContext()
        context.isRunning = true
        var names = Set(CodexComposerCommands.catalog(context).map(\.name))
        XCTAssertFalse(names.contains("init"), "Init is hidden while a turn runs")
        XCTAssertTrue(names.isSuperset(of: ["compact", "review-mode", "fork", "new", "side"]),
                      "Compact stays listed and explains itself when chosen mid-turn")

        context = fullContext()
        context.hasDraftContent = true
        names = Set(CodexComposerCommands.catalog(context).map(\.name))
        XCTAssertTrue(names.isDisjoint(with: ["compact", "review-mode", "fork", "new", "rename", "pin", "archive", "init"]))
        XCTAssertTrue(names.isSuperset(of: ["model", "reasoning", "service-tier:priority", "plan-mode", "side", "skill:docs"]))

        context = fullContext()
        context.hasThread = false
        names = Set(CodexComposerCommands.catalog(context).map(\.name))
        XCTAssertTrue(names.isDisjoint(with: ["compact", "fork", "side"]), "They need a started chat")
        XCTAssertTrue(names.contains("new"))

        context = fullContext()
        context.isGitRepository = false
        context.canOpenSideChat = false
        context.modes = []
        context.modelCatalog = CodexModelCatalog()
        context.skills = []
        names = Set(CodexComposerCommands.catalog(context).map(\.name))
        XCTAssertTrue(names.isDisjoint(with: ["review-mode", "side", "plan-mode"]))
        XCTAssertFalse(names.contains { $0.hasPrefix("service-tier:") || $0.hasPrefix("skill:") })
        XCTAssertEqual(CodexComposerCommands.catalog(context).first { $0.name == "reasoning" }?.description, "")

        for folder in [URL(filePath: "/"), FileManager.default.homeDirectoryForCurrentUser] {
            context = fullContext()
            context.workspaceURL = folder
            XCTAssertFalse(CodexComposerCommands.catalog(context).contains { $0.name == "init" }, folder.path)
        }

        context = fullContext()
        context.selectedModeID = planPreset.id
        context.modelCatalog.selection?.serviceTier = "priority"
        let rows = CodexComposerCommands.catalog(context)
        XCTAssertEqual(rows.first { $0.name == "plan-mode" }?.description, L10n.string("Turn plan mode off"))
        XCTAssertEqual(rows.first { $0.name == "service-tier:priority" }?.description,
                       L10n.format("Turn off %@ and return to standard speed", "Fast"))
        XCTAssertTrue(context.isPlanModeActive)
        context.tokenUsage = nil
        XCTAssertEqual(CodexComposerCommands.catalog(context).first { $0.name == "compact" }?.description,
                       L10n.string("Compact this chat's context"))
    }

    func testTypingFiltersByIDAndTitleAndKeepsGroupsInOrder() {
        let rows = CodexComposerCommands.catalog(fullContext())
        XCTAssertEqual(ComposerCommands.matching(rows, query: "compact").first?.name, "compact")
        XCTAssertEqual(ComposerCommands.matching(rows, query: "review").first?.name, "review-mode", "The Codex ID is typed")
        XCTAssertEqual(ComposerCommands.matching(rows, query: "plan").first?.name, "plan-mode")
        XCTAssertEqual(ComposerCommands.matching(rows, query: "fast").map(\.name), ["service-tier:priority"],
                       "A command without a matching ID is found by its title")
        XCTAssertTrue(ComposerCommands.matching(rows, query: "sidebar").isEmpty,
                      "As in the Codex app, a titled command's description is not searched")
        let mixed = ComposerCommands.matching(rows, query: "re")
        XCTAssertEqual(mixed.last?.name, "skill:release-notes", "A matching skill stays under the Skills heading")
        XCTAssertTrue(mixed.dropLast().allSatisfy { $0.group == nil })
        XCTAssertEqual(Set(mixed.prefix(3).map(\.name)), ["review-mode", "reasoning", "rename"])

        let korean = [ProviderComposerCommand(name: "compact", description: "", argumentHint: "", title: "압축"),
                      ProviderComposerCommand(name: "fork", description: "", argumentHint: "", title: "채팅 포크하기")]
        XCTAssertEqual(ComposerCommands.matching(korean, query: "압").map(\.name), ["compact"])
        XCTAssertEqual(ComposerCommands.matching(korean, query: "포크").map(\.name), ["fork"], "A later word of the title matches")

        // Claude's provider list keeps its existing search, including descriptions.
        let claude = [ProviderComposerCommand(name: "context", description: "Show context usage", argumentHint: "")]
        XCTAssertEqual(ComposerCommands.matching(claude, query: "usage").map(\.name), ["context"])
    }

    func testEveryRowRunsItsOwnCommand() {
        let context = fullContext()
        for row in CodexComposerCommands.catalog(context) {
            let command = CodexComposerCommands.command(for: row, in: context)
            XCTAssertEqual(command?.name, row.name, row.name)
        }
        let skill = CodexComposerCommands.catalog(context).first { $0.name == "skill:release-notes" }!
        XCTAssertEqual(CodexComposerCommands.command(for: skill, in: context), .skill(name: "release-notes", path: "/skills/release/SKILL.md"))
        XCTAssertNil(CodexComposerCommands.command(for: ProviderComposerCommand(name: "mcp", description: "", argumentHint: ""), in: context),
                     "Codex app commands without a Yardlet surface are not run")
        XCTAssertTrue(CodexComposerCommands.isBuiltin(" /compact "))
        XCTAssertTrue(CodexComposerCommands.isBuiltin("/review"))
        XCTAssertFalse(CodexComposerCommands.isBuiltin("/new"), "Only the two typed commands Yardlet already ran on send")
        XCTAssertTrue(CodexInitPrompt.text.hasPrefix("Generate a file named AGENTS.md"))
        XCTAssertTrue(CodexInitPrompt.text.hasSuffix("Agent-Specific Instructions.\n"))
    }

    // MARK: - Native requests

    func testListPreparationReadsCatalogModesAndSkillsWithoutATurnAndNeverStartsAThread() async throws {
        for routed in [false, true] {
            let fixture = try CommandFixture(routed: routed)
            defer { fixture.cleanup() }
            await fixture.model.prepareCodexComposerCommands(for: fixture.session)
            let state = try XCTUnwrap(fixture.model.codexCapabilitiesBySessionID[fixture.session.id])
            XCTAssertEqual(state.modelCatalog.fastTier?.id, "priority")
            XCTAssertEqual(state.modes.map(\.mode), ["plan", "default"])
            XCTAssertEqual(state.skills.map(\.name), ["docs"])
            let methods = await fixture.transport.requestMethods
            XCTAssertTrue(methods.contains("thread/resume"))
            XCTAssertEqual(methods.filter { ["model/list", "collaborationMode/list", "skills/list"].contains($0) }.count, 3)
            XCTAssertFalse(methods.contains { ["turn/start", "thread/start", "turn/steer"].contains($0) })
            await fixture.model.prepareCodexComposerCommands(for: fixture.session)
            let again = await fixture.transport.requestMethods
            XCTAssertEqual(again.count, methods.count, "A loaded list is not read again")
            await fixture.model.shutdown()

            // A task that has not started its Codex thread is not attached for the list.
            let fresh = try CommandFixture(routed: routed, providerSessionID: nil)
            defer { fresh.cleanup() }
            await fresh.model.prepareCodexComposerCommands(for: fresh.session)
            let none = await fresh.transport.requestMethods
            XCTAssertTrue(none.isEmpty)
            XCTAssertFalse(fresh.model.isAttached(fresh.session.id))
            await fresh.model.shutdown()
        }
    }

    func testCompactFastAndPlanModeSendTheirNativeShapesThroughBothRoutes() async throws {
        for routed in [false, true] {
            let fixture = try CommandFixture(routed: routed)
            defer { fixture.cleanup() }
            let model = fixture.model, session = fixture.session
            let draft = model.composerDrafts.tasks.draft(for: session.id)
            let image = CodexUserInput.localImage(fixture.root.appending(path: "keep.png"), detail: .auto)
            draft.attachments = [image]
            let before = draft.snapshot
            await model.prepareCodexComposerCommands(for: session)

            await model.runCodexComposerCommand(.compact, in: try current(model, session))
            var requests = await fixture.transport.requests
            XCTAssertEqual(requests.filter { $0.method == "thread/compact/start" }.map(\.params),
                           [.object(["threadId": .string("original")])])
            XCTAssertEqual(draft.snapshot, before, "Compact leaves the draft's attachments where they were")
            XCTAssertNil(draft.notice)

            await model.runCodexComposerCommand(.serviceTier("priority"), in: try current(model, session))
            XCTAssertTrue(model.codexCapabilitiesBySessionID[session.id]?.modelCatalog.isFast == true)
            await model.runCodexComposerCommand(.planMode, in: try current(model, session))
            XCTAssertEqual(model.codexCapabilitiesBySessionID[session.id]?.selectedModeID, planPreset.id)
            XCTAssertNil(draft.notice)
            try await model.store.updateSession(id: session.id, status: .completed)
            draft.attachments = []
            await model.submitCodex(.init(inputs: [.text("Plan the change")]), action: .automatic, to: try current(model, session))
            requests = await fixture.transport.requests
            let start = try XCTUnwrap(requests.last { $0.method == "turn/start" })
            XCTAssertEqual(start.params["serviceTier"], .string("priority"))
            XCTAssertEqual(start.params["collaborationMode"]?["mode"], .string("plan"))
            XCTAssertFalse(requests.contains { $0.method == "thread/fork" || $0.method == "review/start" })

            // Choosing Plan mode again returns to the provider's Default preset.
            await model.runCodexComposerCommand(.planMode, in: try current(model, session))
            let state = try XCTUnwrap(model.codexCapabilitiesBySessionID[session.id])
            XCTAssertEqual(state.modes.first { $0.id == state.selectedModeID }?.mode, "default")
            await model.shutdown()
        }
    }

    /// The installed App Server (codex-cli 0.157.1) lists its presets without a model, recorded from
    /// `collaborationMode/list`. Both stay selectable, and a turn in one runs on the chat's own model
    /// and effort, as the Codex app fills `collaborationMode.settings`.
    func testPlanModeFromTheInstalledServersModellessPresetsRunsOnTheChatsModel() async throws {
        let recorded = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            {"data": [{"name": "Plan", "mode": "plan", "model": null, "reasoning_effort": "medium"},
                      {"name": "Default", "mode": "default", "model": null, "reasoning_effort": null}]}
            """#.utf8))
        for routed in [false, true] {
            let fixture = try CommandFixture(routed: routed, collaborationModes: recorded)
            defer { fixture.cleanup() }
            let model = fixture.model, session = fixture.session
            await model.prepareCodexComposerCommands(for: session)
            XCTAssertEqual(model.codexCapabilitiesBySessionID[session.id]?.modes.map(\.mode), ["plan", "default"])
            await model.selectCodexModel(.init(model: "gpt-test", reasoningEffort: "low"), for: try current(model, session))

            await model.runCodexComposerCommand(.planMode, in: try current(model, session))
            var state = try XCTUnwrap(model.codexCapabilitiesBySessionID[session.id])
            XCTAssertEqual(state.modes.first { $0.id == state.selectedModeID }?.mode, "plan")
            XCTAssertNil(model.composerDrafts.tasks.draft(for: session.id).notice)
            await model.submitCodex(.init(inputs: [.text("Plan the change")]), action: .automatic, to: try current(model, session))
            var requests = await fixture.transport.requests
            var start = try XCTUnwrap(requests.last { $0.method == "turn/start" })
            XCTAssertEqual(start.params["collaborationMode"], .object([
                "mode": .string("plan"),
                "settings": .object(["model": .string("gpt-test"), "reasoning_effort": .string("low")])
            ]))

            await fixture.transport.emit(method: "turn/completed", params: .object(["threadId": .string("original"),
                "turn": .object(["id": .string("turn-1"), "status": .string("completed"), "items": .array([])])]))
            try await waitUntil { try current(model, session).status == .ready }
            XCTAssertEqual(try current(model, session).status, .ready)
            await model.runCodexComposerCommand(.planMode, in: try current(model, session))
            state = try XCTUnwrap(model.codexCapabilitiesBySessionID[session.id])
            XCTAssertEqual(state.modes.first { $0.id == state.selectedModeID }?.mode, "default")
            await model.submitCodex(.init(inputs: [.text("Now build it")]), action: .automatic, to: try current(model, session))
            requests = await fixture.transport.requests
            start = try XCTUnwrap(requests.last { $0.method == "turn/start" })
            XCTAssertEqual(start.params["collaborationMode"]?["mode"], .string("default"))
            XCTAssertEqual(start.params["collaborationMode"]?["settings"]?["model"], .string("gpt-test"))
            await model.shutdown()
        }
    }

    func testIdleOnlyCommandsAreExplainedOrHeldWhileATurnRuns() async throws {
        let fixture = try CommandFixture(routed: false)
        defer { fixture.cleanup() }
        let model = fixture.model
        try await model.store.updateSession(id: fixture.session.id, status: .running)
        let session = try current(model, fixture.session)
        let draft = model.composerDrafts.tasks.draft(for: session.id)

        await model.runCodexComposerCommand(.compact, in: session)
        XCTAssertEqual(draft.notice, L10n.string("Compact is disabled while a chat is in progress"))
        draft.notice = nil
        await model.runCodexComposerCommand(.codeReview, in: session)
        XCTAssertEqual(draft.notice, L10n.string("Use this command with an empty composer while the chat is idle."))
        XCTAssertNil(model.pendingCodexReview)
        draft.notice = nil
        await model.runCodexComposerCommand(.initialize, in: session)
        XCTAssertNil(draft.notice)
        let methods = await fixture.transport.requestMethods
        XCTAssertFalse(methods.contains { ["thread/compact/start", "review/start", "turn/start", "turn/steer"].contains($0) })

        // New chat does not wait for the turn, as in the Codex app; the running chat is untouched.
        let next = await model.branch(session, at: .start)
        let created = try XCTUnwrap(next)
        XCTAssertEqual(model.store.selectedSessionID, created.id)
        XCTAssertNil(created.providerSessionID)
        XCTAssertEqual(created.harness, .codex)
        XCTAssertEqual(created.workspaceURL, session.workspaceURL)
        XCTAssertEqual(created.connection, session.connection)
        XCTAssertEqual(created.environmentScope, session.environmentScope)
        XCTAssertEqual(created.projectID, session.projectID)
        XCTAssertEqual(created.providerOptions, session.providerOptions)
        XCTAssertEqual(try current(model, session).status, .running)
        let after = await fixture.transport.requestMethods
        XCTAssertEqual(after, methods, "A blank chat starts no thread until its first message")

        // Once idle, Code review opens the target sheet and keeps the rest of the draft.
        try await model.store.updateSession(id: session.id, status: .completed)
        draft.text = ""
        await model.runCodexComposerCommand(.codeReview, in: try current(model, session))
        XCTAssertEqual(model.pendingCodexReview?.session.id, session.id)
        XCTAssertNil(model.pendingCodexReview?.draft)
        await model.shutdown()
    }

    func testInitSendsTheCodexPromptOnlyWithoutAnAgentsFile() async throws {
        for routed in [false, true] {
            let fixture = try CommandFixture(routed: routed)
            defer { fixture.cleanup() }
            let model = fixture.model
            let agents = fixture.root.appending(path: "AGENTS.md")
            try Data("# Existing\n".utf8).write(to: agents)
            await model.runCodexComposerCommand(.initialize, in: try current(model, fixture.session))
            let draft = model.composerDrafts.tasks.draft(for: fixture.session.id)
            XCTAssertEqual(draft.notice, L10n.string("AGENTS.md already exists here. Skipping /init to avoid overwriting it"))
            var starts = await fixture.transport.requests.filter { $0.method == "turn/start" }
            XCTAssertTrue(starts.isEmpty)
            XCTAssertEqual(try String(contentsOf: agents, encoding: .utf8), "# Existing\n")

            try FileManager.default.removeItem(at: agents)
            draft.notice = nil
            await model.runCodexComposerCommand(.initialize, in: try current(model, fixture.session))
            starts = await fixture.transport.requests.filter { $0.method == "turn/start" }
            XCTAssertEqual(starts.count, 1)
            XCTAssertEqual(starts.first?.params["threadId"], .string("original"))
            XCTAssertEqual(starts.first?.params["input"]?.arrayValue?.first?["text"], .string(CodexInitPrompt.text))
            await model.shutdown()
        }
    }

    func testForkPinAndArchiveUseTheirExistingTaskActions() async throws {
        for routed in [false, true] {
            let fixture = try CommandFixture(routed: routed)
            defer { fixture.cleanup() }
            let model = fixture.model, session = fixture.session
            await model.runCodexComposerCommand(.fork, in: try current(model, session))
            var requests = await fixture.transport.requests
            XCTAssertEqual(requests.first { $0.method == "thread/fork" }?.params["threadId"], .string("original"))
            let fork = try XCTUnwrap(model.store.sessions.first { $0.providerSessionID == "child" })
            XCTAssertEqual(model.store.selectedSessionID, fork.id)
            XCTAssertEqual(fork.workspaceURL, session.workspaceURL)

            await model.runCodexComposerCommand(.pin, in: try current(model, session))
            XCTAssertTrue(try current(model, session).isPinned)
            // Let the two attached tasks' first status saves land before one of them leaves the index.
            try await Task.sleep(for: .milliseconds(300))
            await model.runCodexComposerCommand(.archive, in: try current(model, session))
            requests = await fixture.transport.requests
            XCTAssertEqual(requests.first { $0.method == "thread/archive" }?.params["threadId"], .string("original"))
            XCTAssertFalse(model.store.sessions.contains { $0.id == session.id })
            XCTAssertFalse(requests.contains { $0.method == "turn/start" })
            await model.shutdown()
        }
    }

    // MARK: - Rendering

    func testWindowlessPickerRenderInLightAndDark() throws {
        var context = fullContext()
        context.selectedModeID = planPreset.id
        let rows = CodexComposerCommands.catalog(context)
        let directory = try WindowlessRender.directory("codex-slash-qa")
        for language in ["en", "ko"] {
            // The test process may run in either language; each image shows one of them.
            let translated = rows.map { row in
                ProviderComposerCommand(name: row.name, description: description(row, language), argumentHint: "", builtin: true,
                    title: title(row, language), group: row.group.map { _ in L10n.string("Skills", languageCode: language) })
            }
            let localized = translated.filter { $0.group == nil }.sorted { $0.displayTitle < $1.displayTitle }
                + translated.filter { $0.group != nil }
            for appearance in [ColorScheme.light, .dark] {
                let view = VStack(alignment: .leading, spacing: 0) {
                    ComposerCommandRows(commands: localized, highlightedIndex: 1)
                    Divider().padding(.vertical, 6)
                    ComposerCommandRows(commands: ComposerCommands.matching(localized, query: "re"), highlightedIndex: 0)
                }
                .padding(8).frame(width: 380).background(ParityTheme.input)
                .environment(\.colorScheme, appearance)
                let image = try WindowlessRender.image(view)
                XCTAssertEqual(image.width, 760)
                XCTAssertGreaterThan(image.height, 900)
                try WindowlessRender.writePNG(image,
                    to: directory.appending(path: "picker-\(language)-\(appearance == .dark ? "dark" : "light").png"))
            }
        }
    }

    /// The real composer in an unshown window, driven by synthesized keys to that window.
    func testTheCodexComposerRunsTheHighlightedCommandOnReturnOrTab() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            let draft = TaskComposerDraft()
            draft.attachments = [.localImage(URL(filePath: "/tmp/keep.png"), detail: .auto)]
            var ran: [CodexComposerCommand] = []
            var submitted = 0
            let catalog = fullContext().modelCatalog
            let harness = try mount(PromptComposer(
                harness: .codex, composerDraft: draft, modes: [planPreset, defaultPreset], modelCatalog: catalog,
                isRunning: false, codexHasThread: true, canOpenSideChat: true, workspaceURL: repository,
                actions: ComposerActions(submitCodex: { _, _ in submitted += 1 }, runCodexCommand: { ran.append($0) })
            ), appearance: appearance)
            type("/", into: harness)
            try snapshot(harness, "composer-list-\(suffix).png")

            type("fo", into: harness)
            try snapshot(harness, "composer-filtered-\(suffix).png")
            try press("\r", keyCode: 36, in: harness)
            XCTAssertEqual(ran, [.fork])
            XCTAssertEqual(draft.text, "", "The typed command leaves the draft")
            XCTAssertEqual(draft.attachments.count, 1, "The rest of the draft stays")

            type("/re", into: harness)
            try press(down, keyCode: 125, in: harness)
            try snapshot(harness, "composer-highlight-\(suffix).png")
            draft.text = ""
            settle()

            // Pin chat and Plan mode both match; the list's language decides their order.
            type("/p", into: harness)
            var context = fullContext()
            context.workspaceURL = repository
            context.tokenUsage = nil
            context.skills = []
            let expected = ComposerCommands.matching(CodexComposerCommands.catalog(context), query: "p")
            XCTAssertEqual(Set(expected.prefix(2).map(\.name)), ["pin", "plan-mode"])
            try press(down, keyCode: 125, in: harness)
            try press("\t", keyCode: 48, in: harness)
            XCTAssertEqual(ran.last?.name, expected[1].name, "Tab runs the highlighted row")
            XCTAssertEqual(draft.text, "")

            // The model picker belongs to the composer: Model opens it here and nothing leaves.
            let count = ran.count
            type("/model", into: harness)
            try press("\r", keyCode: 36, in: harness)
            XCTAssertEqual(ran.count, count)
            XCTAssertEqual(draft.text, "")
            XCTAssertEqual(submitted, 0, "Running a command sends nothing")
        }

        // While a turn runs, Init is not offered and Compact still is.
        let draft = TaskComposerDraft()
        var ran: [CodexComposerCommand] = []
        let harness = try mount(PromptComposer(
            harness: .codex, composerDraft: draft, isRunning: true,
            codexHasThread: true, workspaceURL: repository, actions: ComposerActions(runCodexCommand: { ran.append($0) })
        ))
        type("/init", into: harness)
        try snapshot(harness, "composer-running-init.png")
        try press("\r", keyCode: 36, in: harness)
        XCTAssertTrue(ran.isEmpty)
        XCTAssertEqual(draft.text, "/init")
        draft.text = ""
        settle()
        type("/compact", into: harness)
        try press("\r", keyCode: 36, in: harness)
        XCTAssertEqual(ran, [.compact])

        // Plan mode on: the Codex app's "Plan" footer indicator, which turns it off.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let harness = try mount(PromptComposer(
                harness: .codex, composerDraft: TaskComposerDraft(), modes: [planPreset, defaultPreset],
                selectedModeID: planPreset.id, modelCatalog: fullContext().modelCatalog, isRunning: false,
                codexHasThread: true, workspaceURL: repository, actions: ComposerActions(runCodexCommand: { _ in })
            ), appearance: appearance)
            try snapshot(harness, "composer-plan-indicator-\(appearance == .darkAqua ? "dark" : "light").png")
        }
    }

    // MARK: - Mounted composer

    private struct Harness {
        let window: NSWindow
        let hosting: NSView
        let editor: NSTextView
    }

    private func mount<Content: View>(_ content: Content, appearance: NSAppearance.Name = .aqua) throws -> Harness {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: content.frame(width: 640, height: 640, alignment: .bottom)
            .background(ParityTheme.canvas))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        settle()
        let field = try XCTUnwrap(views(NSTextField.self, in: hosting).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        settle()
        addTeardownBlock { @MainActor in window.contentView = nil }
        return Harness(window: window, hosting: hosting, editor: try XCTUnwrap(window.firstResponder as? NSTextView))
    }

    private func type(_ text: String, into harness: Harness) {
        let end = NSRange(location: (harness.editor.string as NSString).length, length: 0)
        harness.editor.insertText(text, replacementRange: end)
        settle(0.3)
    }

    private func press(_ characters: String, keyCode: UInt16, in harness: Harness) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
        harness.window.sendEvent(event)
        settle()
    }

    private let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    private func settle(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ([root] + root.subviews.flatMap { views(NSView.self, in: $0) }).compactMap { $0 as? T }
    }

    private func snapshot(_ harness: Harness, _ name: String) throws {
        let bitmap = try WindowlessRender.capture(harness.hosting)
        try WindowlessRender.writePNG(bitmap, to: WindowlessRender.directory("codex-slash-qa").appending(path: name))
    }

    // MARK: - Fixtures

    private let planPreset = CodexCollaborationPreset(name: "Plan", mode: "plan", model: "gpt-test", reasoningEffort: "high")
    private let defaultPreset = CodexCollaborationPreset(name: "Default", mode: "default", model: "gpt-test", reasoningEffort: nil)

    private func fullContext() -> CodexComposerCommandContext {
        let model = CodexModelOption(id: "gpt-test", model: "gpt-test", displayName: "GPT Test", defaultReasoningEffort: "high",
            supportedReasoningEfforts: ["low", "high"], isDefault: true,
            serviceTiers: [.init(id: "priority", name: "Fast", description: "2x speed, increased usage")])
        return CodexComposerCommandContext(
            hasThread: true, isRunning: false, hasDraftContent: false, canOpenSideChat: true, isGitRepository: true,
            workspaceURL: URL(filePath: "/tmp/codex-slash-project"),
            modelCatalog: CodexModelCatalog(models: [model], selection: .init(model: "gpt-test", reasoningEffort: "high", serviceTier: "default")),
            modes: [planPreset, defaultPreset], selectedModeID: nil,
            tokenUsage: CodexThreadTokenUsage(total: usage(64_000), last: usage(64_000), modelContextWindow: 256_000),
            skills: [
                CodexSkillSummary(name: "release notes", displayName: "Release notes", description: "Draft release notes",
                                  enabled: true, scope: "repo", path: "/skills/release/SKILL.md"),
                CodexSkillSummary(name: "docs", displayName: "Docs", description: "Official docs",
                                  enabled: true, scope: "user", path: "/skills/docs/SKILL.md"),
                CodexSkillSummary(name: "off", displayName: "Disabled", description: "", enabled: false, scope: "user", path: "/skills/off/SKILL.md")
            ])
    }

    private func usage(_ total: Int64) -> CodexTokenUsageBreakdown {
        CodexTokenUsageBreakdown(inputTokens: total, cachedInputTokens: 0, cacheWriteInputTokens: 0,
                                 outputTokens: 0, reasoningOutputTokens: 0, totalTokens: total)
    }

    private func title(_ row: ProviderComposerCommand, _ language: String) -> String {
        let keys = ["compact": "Compact slash command", "review-mode": "Code review", "fork": "Fork chat", "new": "New chat",
                    "rename": "Rename", "pin": "Pin chat", "archive": "Archive", "model": "Model",
                    "reasoning": "Reasoning slash command", "plan-mode": "Plan mode", "init": "Init", "side": "Side",
                    "status": "Status slash command"]
        return keys[row.name].map { L10n.string($0, languageCode: language) } ?? row.displayTitle
    }

    private func description(_ row: ProviderComposerCommand, _ language: String) -> String {
        let keys = ["review-mode": "Review uncommitted changes or compare against a branch", "fork": "Fork this chat",
                    "new": "Start a blank chat in the same workspace", "rename": "Rename the current chat",
                    "pin": "Keep this chat in the sidebar", "archive": "Archive the current chat",
                    "plan-mode": "Turn plan mode off", "init": "Create an AGENTS.md file with instructions for Codex",
                    "side": "Start a temporary side chat", "status": "Show chat ID, context usage, and rate limits"]
        if row.name == "compact" {
            return String(format: L10n.string("Compact this chat's context (%lld%% full)", languageCode: language), Int64(25))
        }
        if row.name == "reasoning" { return L10n.string("High", languageCode: language) }
        return keys[row.name].map { L10n.string($0, languageCode: language) } ?? row.description
    }

    private func current(_ model: AppModel, _ session: SessionRecord) throws -> SessionRecord {
        try XCTUnwrap(model.store.sessions.first { $0.id == session.id })
    }
}

/// An AppModel whose Codex task talks to a fake App Server, directly or through YHP.
@MainActor
struct CommandFixture {
    let root: URL
    let transport: FakeCodexTransport
    let session: SessionRecord
    let model: AppModel

    init(routed: Bool, providerSessionID: String? = "original", collaborationModes: JSONValue? = nil,
         collaborationModeListings: [JSONValue]? = nil, providerOptions: [String: String] = [:],
         repository: (([SessionRecord]) -> any SessionRepository)? = nil) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "Yardlet.CodexSlash.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "codex")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.160.0\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var responses = Self.responses(collaborationModes: collaborationModes)
        if let collaborationModeListings { responses["collaborationMode/list"] = collaborationModeListings }
        transport = FakeCodexTransport(responses: responses)
        let direct = CodexAdapter(executableURL: executable, transport: transport)
        let adapter: any HarnessAdapter = routed
            ? YHPCodexCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.codex()) : direct
        session = SessionRecord(harness: .codex, workspaceURL: root, runtimeExecutableURL: executable, title: "Commands",
            status: .completed, providerSessionID: providerSessionID, providerOptions: providerOptions,
            environmentScope: .yardlet, projectID: UUID())
        let defaults = UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests.CodexSlash"))!
        model = AppModel(store: SessionStore(sessions: [session],
                                             repository: repository?([session]) ?? InMemorySessionRepository(sessions: [session])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults), registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            restoresIndexOnLaunch: false)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func responses(collaborationModes: JSONValue? = nil) -> [String: [JSONValue]] {
        let thread = JSONValue.object(["thread": .object(["id": .string("original"), "status": .object(["type": .string("idle")]),
            "historyMode": .string("paginated"), "turns": .array([])]), "model": .string("gpt-test"), "reasoningEffort": .string("high")])
        let child = JSONValue.object(["thread": .object(["id": .string("child"), "status": .object(["type": .string("idle")]),
            "turns": .array([])]), "model": .string("gpt-test"), "reasoningEffort": .string("high")])
        let model = JSONValue.object(["id": .string("gpt-test"), "model": .string("gpt-test"), "displayName": .string("GPT Test"),
            "defaultReasoningEffort": .string("high"), "isDefault": .bool(true),
            "supportedReasoningEfforts": .array([.object(["reasoningEffort": .string("low")]), .object(["reasoningEffort": .string("high")])]),
            "serviceTiers": .array([.object(["id": .string("priority"), "name": .string("Fast"), "description": .string("2x speed, increased usage")])])])
        let modes = collaborationModes ?? JSONValue.object(["data": .array([
            .object(["name": .string("Plan"), "mode": .string("plan"), "model": .string("gpt-test"), "reasoning_effort": .string("high")]),
            .object(["name": .string("Default"), "mode": .string("default"), "model": .string("gpt-test")])])])
        let skills = JSONValue.object(["data": .array([.object(["skills": .array([.object([
            "name": .string("docs"), "path": .string("/skills/docs/SKILL.md"), "enabled": .bool(true), "scope": .string("user"),
            "interface": .object(["displayName": .string("Docs"), "shortDescription": .string("Official docs")])])])])])])
        let empty = JSONValue.object(["data": .array([]), "nextCursor": .null])
        return ["initialize": [.object(["platformOs": .string("macos")])],
                "thread/resume": [thread], "thread/read": Array(repeating: thread, count: 6),
                "thread/items/list": Array(repeating: empty, count: 4), "thread/turns/list": Array(repeating: empty, count: 4),
                "model/list": [.object(["data": .array([model]), "nextCursor": .null])],
                // The YHP route reads the provider's presets again to resolve each selection.
                "collaborationMode/list": Array(repeating: modes, count: 4), "skills/list": [skills],
                "thread/compact/start": [.object([:])], "thread/fork": [child], "thread/archive": [.object([:])],
                "turn/start": [.object(["turn": .object(["id": .string("turn-1")])]), .object(["turn": .object(["id": .string("turn-2")])])]]
    }
}
