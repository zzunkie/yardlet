import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Antigravity's composer controls: the folded model menu and its efforts, the permission modes
/// with Bypass permissions asked about first and drawn in orange, before and after the task
/// connects and on the new-task screen; and the windowless review renders of an Antigravity task
/// (`.build/antigravity-qa/`).
@MainActor
final class AntigravityComposerTests: XCTestCase {
    private typealias Fixtures = ComposerUnificationFixtures

    private static let expectedConfirmation = ComposerPermissionSlot.Confirmation(
        title: L10n.string("Bypass permission checks?"),
        message: L10n.string("Antigravity will change files and run commands without asking."),
        confirm: L10n.string("Use bypass permissions"))

    // MARK: - Permission

    /// Over ACP the agent asks, so every Antigravity menu offers Default and Bypass permissions, and
    /// a task keeps Plan where it had it; Accept edits and Auto, which ACP has no counterpart for, ask.
    func testEveryAntigravityPermissionMenuOffersAskingAndBypassAndAsksBeforeTheBypass() throws {
        let attached = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .antigravityCLI, session: Fixtures.session(.antigravityCLI),
            providerCapabilities: Self.liveCapabilities(mode: "default"), providerUsage: nil, isAttached: true).permission)
        let detached = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .antigravityCLI, session: Fixtures.session(.antigravityCLI, options: ["executionMode": "accept-edits"]),
            providerCapabilities: nil, providerUsage: nil, isAttached: false).permission)
        let newTask = try XCTUnwrap(ComposerSessionOptionsProjection.newTask(
            harness: .antigravityCLI, choice: nil, catalogs: Self.catalogs(), connection: nil, workspaceURL: nil).permission)
        for (name, slot) in [("attached", attached), ("detached", detached), ("new task", newTask)] {
            XCTAssertEqual(slot.selector?.choices.map(\.value), ["default", "bypass"], name)
            XCTAssertEqual(slot.selector?.choices.last?.name, L10n.string("Bypass permissions"), name)
            XCTAssertEqual(slot.confirmations, ["bypass": Self.expectedConfirmation], name)
            XCTAssertEqual(slot.apply.choice(id: "permissionMode", value: "bypass"),
                           .providerOption(id: "permissionMode", value: "bypass"), name)
            XCTAssertFalse(slot.isElevated, name)
        }
        // Before it connects, the menu reads the mode saved under the earlier key: Accept edits asks.
        XCTAssertEqual(detached.title, L10n.string("Default"))
        let plan = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .antigravityCLI, session: Fixtures.session(.antigravityCLI, options: ["permissionMode": "plan"]),
            providerCapabilities: nil, providerUsage: nil, isAttached: false).permission)
        XCTAssertEqual(plan.selector?.choices.map(\.value), ["default", "plan", "bypass"])
        XCTAssertEqual(plan.title, L10n.string("Plan"))
        XCTAssertFalse(detached.canChoose)
        XCTAssertTrue(detached.preparesBeforeOpening)
        XCTAssertTrue(attached.canChoose)
        XCTAssertTrue(newTask.canChoose)

        let bypass = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .antigravityCLI, session: Fixtures.session(.antigravityCLI),
            providerCapabilities: Self.liveCapabilities(mode: "bypass"), providerUsage: nil, isAttached: true).permission)
        XCTAssertTrue(bypass.isElevated)
        XCTAssertEqual(bypass.title, L10n.string("Bypass permissions"))
        XCTAssertEqual(L10n.string("Antigravity will change files and run commands without asking.", languageCode: "ko"),
                       "Antigravity가 묻지 않고 파일을 바꾸고 명령을 실행합니다.")

        // Claude keeps its own words and other providers ask nothing new.
        XCTAssertEqual(Array(ComposerSessionOptionsProjection.permissionConfirmations(for: .claudeCode).keys), ["bypassPermissions"])
        XCTAssertTrue(ComposerSessionOptionsProjection.permissionConfirmations(for: .cursorAgent).isEmpty)
    }

    func testTheHarnessSettingsSheetAsksBeforeTheAntigravityBypassToo() throws {
        let content = HarnessSettingsSheetProjection.providerContent(Self.liveCapabilities(mode: "default"), canBranch: false)
        let control = try XCTUnwrap(content.controls.first { $0.id == "option.permissionMode" })
        guard case let .selector(_, choices) = control.kind else { return XCTFail("The mode is a selector") }
        XCTAssertEqual(choices.map(\.id), ["default", "bypass"])
        XCTAssertEqual(choices.last?.confirmation, Self.expectedConfirmation)
        XCTAssertTrue(choices.dropLast().allSatisfy { $0.confirmation == nil })
    }

    // MARK: - Model and effort

    func testTheModelMenuIsTheFoldedListAndTheChosenModelsEfforts() throws {
        let menu = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .antigravityCLI, session: Fixtures.session(.antigravityCLI),
            providerCapabilities: Self.liveCapabilities(mode: "default"), providerUsage: nil, isAttached: true).model?.menu)
        XCTAssertEqual(menu.model?.choices.map(\.value), ["default", "gemini-3.8-flash", "claude-opus-4-6-thinking"])
        XCTAssertEqual(menu.effort?.choices.map(\.value), ["default", "low", "medium", "high"])
        XCTAssertEqual(menu.title, "Gemini 3.8 Flash · \(L10n.string("Low"))")
        XCTAssertTrue(menu.canChoose)

        // Before the task lists its models in this run: its own choice by ID, and opening reads the list.
        let detached = try XCTUnwrap(ComposerSessionOptionsProjection.make(
            harness: .antigravityCLI, session: Fixtures.session(.antigravityCLI),
            providerCapabilities: ProviderCapabilityState(selectors: AntigravityDetachedSelectors.model(
                options: ["model": "gemini-3.8-flash", "reasoningEffort": "low"])),
            providerUsage: nil, isAttached: false).model?.menu)
        XCTAssertEqual(detached.model?.currentValue, "gemini-3.8-flash")
        XCTAssertEqual(detached.effort?.currentValue, "low")
        XCTAssertFalse(detached.canChoose)
        XCTAssertEqual(AntigravityDetachedSelectors.model(options: [:]).map(\.currentValue), ["default"])
    }

    /// The new-task screen offers the list a task last read, and the choice becomes the task's own
    /// options under the keys the task's menus keep them.
    func testTheNewTaskScreenStartsTheTaskOnTheChosenModelEffortAndMode() throws {
        let catalogs = Self.catalogs()
        let empty = try XCTUnwrap(ComposerSessionOptionsProjection.newTask(
            harness: .antigravityCLI, choice: nil, catalogs: Self.catalogs(models: []), connection: nil, workspaceURL: nil).model)
        XCTAssertFalse(empty.menu.canChoose, "Opening the menu reads the list first")

        var choice: NewTaskModelChoice? = nil
        func choose(_ id: String, _ value: String) {
            choice = NewTaskModelProjection.choosing(id, value: value, harness: .antigravityCLI, choice: choice,
                                                     catalogs: catalogs, connection: nil, workspaceURL: nil) ?? choice
        }
        choose("model", "gemini-3.8-flash")
        choose("reasoningEffort", "low")
        choose("permissionMode", "bypass")
        XCTAssertEqual(choice?.providerOptions(for: .antigravityCLI),
                       ["model": "gemini-3.8-flash", "reasoningEffort": "low", "permissionMode": "bypass"])
        let menu = try XCTUnwrap(ComposerSessionOptionsProjection.newTask(
            harness: .antigravityCLI, choice: choice, catalogs: catalogs, connection: nil, workspaceURL: nil).model?.menu)
        XCTAssertEqual(menu.effort?.currentValue, "low")
        // A model without efforts drops the effort, as the CLI would refuse it.
        choose("model", "claude-opus-4-6-thinking")
        XCTAssertNil(choice?.effort)
        XCTAssertNil(NewTaskModelProjection.choosing("reasoningEffort", value: "high", harness: .antigravityCLI,
                                                     choice: choice, catalogs: catalogs, connection: nil, workspaceURL: nil))
        XCTAssertNil(NewTaskModelProjection.choosing("permissionMode", value: "auto", harness: .antigravityCLI,
                                                     choice: choice, catalogs: catalogs, connection: nil, workspaceURL: nil))
        choose("permissionMode", "default")
        XCTAssertEqual(choice?.providerOptions(for: .antigravityCLI), ["model": "claude-opus-4-6-thinking"])
    }

    // MARK: - Review renders

    /// An Antigravity task as `agy` 1.4.0's stream draws it — a command with its parameters and
    /// output, a denied command, the "not run without approval" row and the answer — and its
    /// composer with the folded model menu and the bypass on, in both appearances.
    /// Review images: `.build/antigravity-qa/`.
    func testReviewRenders() throws {
        let directory = try WindowlessRender.directory("antigravity-qa")
        let entries = Self.streamedConversation()
        XCTAssertTrue(entries.contains { if case let .activity(activity, _) = $0.content { activity.kind == "denied_actions" } else { false } })
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                TaskConversationView(harness: .antigravityCLI, workspaceURL: Fixtures.workspace, entries: entries,
                                     sessionStatus: .ready, latestTurnIsComplete: true,
                                     actions: ConversationActions(chooseOption: { _, _ in }, answer: { _, _ in }))
                    .environment(\.transcriptWorkspaceURL, Fixtures.workspace),
                size: NSSize(width: 760, height: 900), appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "task-\(appearance.suffix).png"))
            XCTAssertTrue(drawing.elements.contains { $0.role == "AXGroup" && $0.label == L10n.string("You") })
        }

        // The permission menu as it opens, over ACP: Default and Bypass permissions.
        for appearance in WindowlessRender.Appearance.allCases {
            let menu = ComposerProviderOptionMenu(selector: AntigravityPermissionMode.askingSelector(current: "default"),
                                                  isEnabled: true, onSelect: { _, _ in }, onDismiss: {})
                .frame(width: 264).environment(\.colorScheme, appearance.colorScheme)
            let image = try WindowlessRender.image(menu)
            let bitmap = NSBitmapImageRep(cgImage: image)
            XCTAssertTrue(WindowlessRender.drawsContent(bitmap, step: 5, from: 10))
            try WindowlessRender.writePNG(bitmap, to: directory.appending(path: "permission-menu-\(appearance.suffix).png"))
        }

        var orange: [String: Int] = [:]
        for mode in ["default", "bypass"] {
            let captures = try WindowlessRender.hostedInBothAppearances("composer-\(mode)", in: directory,
                                                                        size: NSSize(width: 760, height: 150)) {
                PromptComposer(harness: .antigravityCLI, composerDraft: Fixtures.draft("Run the tests"),
                    providerSession: Fixtures.session(.antigravityCLI), providerCapabilities: Self.liveCapabilities(mode: mode),
                    providerUsage: nil, isProviderAttached: true, isRunning: false, actions: Fixtures.claudeActions)
                    .environment(\.colorScheme, $0.colorScheme)
                    .frame(width: 760, height: 150, alignment: .bottom)
                    .background(ParityTheme.canvas)
            }
            for (appearance, capture) in zip(WindowlessRender.Appearance.allCases, captures) {
                orange["\(mode)-\(appearance.suffix)"] = Self.orangePixels(in: capture.bitmap)
            }
        }
        for appearance in WindowlessRender.Appearance.allCases {
            XCTAssertEqual(orange["default-\(appearance.suffix)"], 0, appearance.suffix)
            XCTAssertGreaterThan(orange["bypass-\(appearance.suffix)"] ?? 0, 20, appearance.suffix)
        }
    }

    // MARK: - Fixtures

    /// The adapter's events for two turns of `agy` 1.4.0 (shapes from the sandbox turns, values made
    /// up): a command that ran with its output and an answer, then a command the headless run
    /// refused, after which the CLI stopped without a word, as the sandbox turns did.
    private static func streamedConversation() -> [TranscriptEntry] {
        let projector = StructuredHeadlessEventProjector(flavor: .antigravity)
        let turns: [(String, [String])] = [
            ("Build the package.", [
                #"{"event":"init","conversation_id":"agy-review","init":{"model":"gemini-3.8-flash-low","cwd":"/tmp/composer-unify-project","tools":["run_command"],"permission_mode":"request-review"}}"#,
                #"{"event":"step_update","step_update":{"conversation_id":"agy-review","step_index":0,"state":"DONE","step_type":"user_input"}}"#,
                #"{"event":"step_update","step_update":{"conversation_id":"agy-review","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"swift build"}}}}"#,
                #"{"event":"step_update","step_update":{"conversation_id":"agy-review","step_index":2,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":12.5,"tool_info":{"name":"run_command","parameters":{"CommandLine":"swift build"},"output":"Build complete! (12.40s)"}}}"#,
                #"{"event":"step_update","step_update":{"conversation_id":"agy-review","step_index":3,"state":"ACTIVE","step_type":"agent_response","text_delta":"The package builds."}}"#,
                #"{"event":"result","result":{"conversation_id":"agy-review","status":"SUCCESS","response":"The package builds.","duration_seconds":14,"num_turns":1,"usage":{"input_tokens":4200,"output_tokens":20,"thinking_tokens":40,"cache_read_tokens":0,"total_tokens":4260}}}"#
            ]),
            ("Run its tests.", [
                #"{"event":"init","conversation_id":"agy-review","init":{"model":"gemini-3.8-flash-low","cwd":"/tmp/composer-unify-project","tools":["run_command"],"permission_mode":"request-review"}}"#,
                #"{"event":"step_update","step_update":{"conversation_id":"agy-review","step_index":4,"state":"DONE","step_type":"user_input"}}"#,
                #"{"event":"step_update","step_update":{"conversation_id":"agy-review","step_index":6,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"swift test"}}}}"#,
                #"{"event":"step_update","step_update":{"conversation_id":"agy-review","step_index":6,"state":"ERROR","step_type":"tool","tool_name":"run_command","duration_seconds":0.1,"tool_info":{"name":"run_command","parameters":{"CommandLine":"swift test"},"error":{"type":"TOOL_ERROR","message":"Permission to run this command was not granted in a headless run."}}}}"#,
                #"{"event":"result","result":{"conversation_id":"agy-review","status":"SUCCESS","response":"","duration_seconds":2,"num_turns":1,"usage":{"input_tokens":4300,"output_tokens":10,"thinking_tokens":0,"cache_read_tokens":4000,"total_tokens":4310},"denied_actions":[{"action":"command","display_name":"Run command"}]}}"#
            ])
        ]
        var builder = TranscriptBuilder()
        for (request, lines) in turns {
            builder.appendUser(request)
            var hasText = false
            for line in lines {
                let value = try! JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                for payload in projector.project(value, hasAssistantText: hasText).payloads {
                    if case .assistantDelta = payload { hasText = true }
                    builder.apply(payload)
                }
            }
            builder.apply(.sessionStatusChanged(.ready))
        }
        return builder.entries
    }

    private static func liveCapabilities(mode: String) -> ProviderCapabilityState {
        ProviderCapabilityState(selectors: [
            ProviderCapabilitySelector(id: "model", name: L10n.string("Model"), description: nil, category: "model",
                currentValue: "gemini-3.8-flash",
                choices: [.init(value: "default", name: L10n.string("Default"), description: nil),
                          .init(value: "gemini-3.8-flash", name: "Gemini 3.8 Flash", description: nil),
                          .init(value: "claude-opus-4-6-thinking", name: "Claude Opus 4.6 (Thinking)", description: nil)]),
            ProviderCapabilitySelector(id: "reasoningEffort", name: L10n.string("Reasoning effort"), description: nil,
                category: "thought_level", currentValue: "low",
                choices: [.init(value: "default", name: L10n.string("Default"), description: nil),
                          .init(value: "low", name: L10n.string("Low"), description: nil),
                          .init(value: "medium", name: L10n.string("Medium"), description: nil),
                          .init(value: "high", name: L10n.string("High"), description: nil)]),
            AntigravityPermissionMode.askingSelector(current: mode),
            ProviderCapabilitySelector(id: "sandbox", name: L10n.string("Sandbox mode"), description: nil, category: "mode",
                currentValue: "default",
                choices: [.init(value: "default", name: L10n.string("Default"), description: nil),
                          .init(value: "enabled", name: L10n.string("Enabled"), description: nil)])
        ])
    }

    private static func catalogs(models: [HarnessModelOption]? = nil) -> HarnessModelCatalogStore {
        let store = HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
            claudeConfigDirectory: URL(filePath: "/tmp/antigravity-composer-none/claude"),
            codexHome: URL(filePath: "/tmp/antigravity-composer-none/codex"),
            codexYardletHome: URL(filePath: "/tmp/antigravity-composer-none/y")), environment: [:])
        store.recordAntigravity(models ?? [
            HarnessModelOption(value: "gemini-3.8-flash", name: "Gemini 3.8 Flash", effortLevels: ["low", "medium", "high"]),
            HarnessModelOption(value: "claude-opus-4-6-thinking", name: "Claude Opus 4.6 (Thinking)")
        ])
        return store
    }

    private static func orangePixels(in bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent
                if red > 0.6, red - blue > 0.4, red - green > 0.15 { count += 1 }
            }
        }
        return count
    }
}
