import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Review images of the one composer: the task composer for Codex, Claude Code and an ACP agent,
/// and the new-task composer, in both appearances, under `.build/composer-unify-qa/`.
@MainActor
final class ComposerSessionControlsRenderingTests: XCTestCase {
    private static let folder = "composer-unify-qa"

    func testTaskComposersDrawInBothAppearances() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        for scenario in ComposerUnificationFixtures.taskScenarios {
            let elements = try ComposerUnificationFixtures.render(scenario, into: directory)
            XCTAssertFalse(elements.isEmpty, scenario.name)
        }
    }

    /// The bottom row reads the same for every harness: the same controls in the same order,
    /// each with the provider's own value. The differences are listed here and are the intended
    /// ones: Codex's Plan indicator (only while Plan mode is on) and Skills (from Codex's
    /// `skills/list`), and an ACP agent's own mode selector, labelled as the agent names it.
    func testTheBottomRowIsTheSameForEveryHarnessApartFromTheListedDifferences() throws {
        typealias F = ComposerUnificationFixtures
        let composers: [(String, AnyView)] = [
            ("codex", AnyView(PromptComposer(harness: .codex, composerDraft: F.draft("Fix it"), skills: F.skills,
                modes: [F.planPreset, F.defaultPreset], selectedModeID: F.planPreset.id, modelCatalog: F.codexCatalog,
                runLocation: .workspaceWrite, providerSession: F.session(.codex), isProviderAttached: true,
                isRunning: false, codexHasThread: true, codexTokenUsage: F.codexTokenUsage, actions: F.codexActions))),
            ("claude", AnyView(PromptComposer(harness: .claudeCode, composerDraft: F.draft("Fix it"),
                providerSession: F.session(.claudeCode), providerCapabilities: F.claudeLiveCapabilities,
                providerUsage: F.providerUsage, isProviderAttached: true, isRunning: false, actions: F.claudeActions))),
            ("opencode", AnyView(PromptComposer(harness: .openCode, composerDraft: F.draft("Fix it"),
                providerSession: F.session(.openCode), providerCapabilities: F.acpCapabilities,
                providerUsage: F.providerUsage, isProviderAttached: true, isRunning: false)))
        ]
        var rows: [String: [WindowlessRender.AccessibilityElement]] = [:]
        for (name, view) in composers {
            let host = WindowlessRender.Host(view.frame(width: 760, height: 150, alignment: .bottom),
                                             size: NSSize(width: 760, height: 150))
            host.settle()
            let elements = host.accessibilityElements()
            host.close()
            let field = try XCTUnwrap(elements.firstIndex { $0.role == "AXTextField" }, name)
            rows[name] = Array(elements[(field + 1)...])
        }
        let shared = [L10n.string("Add files and more"), L10n.string("Permissions"),
                      L10n.string("Context window"), L10n.string("Model"), L10n.string("Send")]
        let intended: [String: Set<String>] = [
            "codex": [L10n.string("Plan mode indicator"), L10n.string("Skills")],
            "claude": [],
            "opencode": ["Mode"]
        ]
        for (name, row) in rows.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(row.allSatisfy { $0.role == "AXButton" }, "\(name): \(row)")
            let labels = row.map(\.label)
            XCTAssertEqual(labels.filter { !(intended[name] ?? []).contains($0) }, shared, "\(name): \(row)")
            XCTAssertEqual(Set(labels).subtracting(shared), intended[name], name)
        }
        // The places differ only by the listed controls, which sit where Codex puts its own.
        XCTAssertEqual(rows["codex"]?.map(\.label), [L10n.string("Add files and more"),
            L10n.string("Plan mode indicator"), L10n.string("Permissions"), L10n.string("Skills"),
            L10n.string("Context window"), L10n.string("Model"), L10n.string("Send")])
        XCTAssertEqual(rows["opencode"]?.map(\.label), [L10n.string("Add files and more"), "Mode",
            L10n.string("Permissions"), L10n.string("Context window"), L10n.string("Model"), L10n.string("Send")])
        // Each value is the provider's own.
        func value(_ name: String, _ label: String) -> String? { rows[name]?.first { $0.label == label }?.value }
        XCTAssertEqual(value("codex", L10n.string("Permissions")), CodexRunLocation.workspaceWrite.displayName)
        XCTAssertEqual(value("claude", L10n.string("Permissions")), L10n.string("Accept edits"))
        XCTAssertEqual(value("opencode", L10n.string("Permissions")), L10n.string("On request"))
        XCTAssertEqual(value("codex", L10n.string("Model")), "GPT-6.1-Sol, \(L10n.string("High"))")
        XCTAssertEqual(value("claude", L10n.string("Model")), "Opus, High")
        XCTAssertEqual(value("opencode", L10n.string("Model")), "Sonnet, Medium")
        // The Claude app's numbers: "64k / 256k (25%)".
        XCTAssertEqual(value("codex", L10n.string("Context window"))?.hasSuffix("(25%)"), true)
        XCTAssertEqual(value("claude", L10n.string("Context window"))?.hasSuffix("(60%)"), true)
    }

    func testNewTaskComposersDrawInBothAppearances() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "composer-unify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeHome = root.appending(path: "claude"), codexHome = root.appending(path: "codex")
        try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data(#"{"model":"fable","effortLevel":"xhigh"}"#.utf8).write(to: claudeHome.appending(path: "settings.json"))
        try Data("model = \"gpt-6.1-sol\"\nmodel_reasoning_effort = \"high\"\n".utf8)
            .write(to: codexHome.appending(path: "config.toml"))
        let catalogs = HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
            claudeConfigDirectory: claudeHome, codexHome: codexHome, codexYardletHome: root.appending(path: "y")),
            environment: [:])
        catalogs.recordClaude(ModelVisibilityFixtures.claudeModels, for: nil)
        catalogs.recordCodex(ComposerUnificationFixtures.codexCatalog.models, for: nil)

        let suite = testDefaultsSuite("ComposerUnification")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        for harness in [HarnessKind.claudeCode, .codex, .openCode] { runtimes.select(URL(filePath: "/usr/bin/true"), for: harness) }
        let connections = ProviderConnectionStore()
        connections.usesFixtureSnapshots = true
        let project = Project(name: "yardlet-sandbox", primaryRoot: ComposerUnificationFixtures.workspace)

        let directory = try WindowlessRender.directory(Self.folder)
        for harness in [HarnessKind.claudeCode, .codex, .openCode] {
            let draft = NewTaskDraft()
            draft.workspaceURL = ComposerUnificationFixtures.workspace
            draft.projectID = project.id
            draft.harness = harness
            draft.text = "Explain the build"
            await catalogs.refreshDefaults(for: harness, connection: nil, workspaceURL: ComposerUnificationFixtures.workspace)
            let scenario = ComposerUnificationFixtures.Scenario(name: "new-task-\(harness.rawValue)",
                                                                size: NSSize(width: 860, height: 280)) {
                AnyView(NewTaskHome(recentSessions: [], projects: [project], draft: draft, runtimeSelections: runtimes,
                    connections: connections, models: NewTaskModelSource(catalogs: catalogs) { _, _, _, _ in },
                    onSelectSession: { _ in }, onChooseWorkspace: { _ in }, onShowHarnesses: {},
                    onCreate: { _ in nil }))
            }
            let elements = try ComposerUnificationFixtures.render(scenario, into: directory)
            // The same session controls as the task composer, for what the task can start with:
            // Claude Code's permission mode (its launch flag), and no Codex sandbox policy, which
            // applies to a running thread's turns.
            let permissions = elements.first { $0.label == L10n.string("Permissions") }
            XCTAssertEqual(permissions?.value, harness == .claudeCode ? L10n.string("Manual") : nil, harness.rawValue)
            XCTAssertEqual(elements.contains { $0.label == L10n.string("Model") }, harness != .openCode, harness.rawValue)
        }
    }
}
