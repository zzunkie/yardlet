import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders, into `.build/model-visibility-qa` in both appearances, the composers of a Claude task
/// and a Codex task that have not connected, the new-task composer for each harness, and the
/// shared model menu each opens. The composers draw in a borderless window that is never put on
/// screen, so their text fields draw; the menus draw with ImageRenderer. No provider is contacted.
@MainActor
final class ComposerModelVisibilityRenderingTests: XCTestCase {
    private let directory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: ".build/model-visibility-qa")
    private let workspace = URL(filePath: "/tmp/yardlet-sandbox")

    func testTaskComposersShowTheModelBeforeTheirTaskConnects() throws {
        let claude = SessionRecord(harness: .claudeCode, workspaceURL: workspace, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Saved", status: .completed, providerSessionID: "saved", providerOptions: ["permissionMode": "acceptEdits"])
        var state = ProviderCapabilityState()
        state.selectors = ClaudeComposerModelProjection.selectors(model: nil, effort: nil,
            defaults: HarnessModelDefaults(model: "fable", effort: "xhigh"), catalog: ModelVisibilityFixtures.claudeModels)
        state.offersModelsBeforeAttach = true
        for (name, width) in [("task-claude-unattached", 760.0), ("task-claude-unattached-narrow", 400.0)] {
            try render(name: name, size: NSSize(width: width, height: 130)) {
                PromptComposer(harness: .claudeCode, composerDraft: TaskComposerDraft(),
                    providerSession: claude, providerCapabilities: state, isProviderAttached: false, isRunning: false)
            }
        }

        let catalog = CodexComposerModelProjection.catalog(live: CodexModelCatalog(), stored: nil,
            defaults: HarnessModelDefaults(model: "gpt-6-astra", effort: "xhigh", serviceTier: "default"), cached: codexModels)
        XCTAssertEqual(ComposerModelMenu.codex(catalog).title, "GPT-6-Astra · " + L10n.string("Extra high"))
        try render(name: "task-codex-unattached", size: NSSize(width: 760, height: 130)) {
            PromptComposer(harness: .codex, composerDraft: TaskComposerDraft(), modelCatalog: catalog,
                isRunning: false, codexHasThread: true, workspaceURL: workspace)
        }
    }

    func testTheNewTaskComposerShowsTheModelAndAccountForEachHarness() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "model-visibility-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeHome = root.appending(path: "claude"), codexHome = root.appending(path: "codex")
        try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data(#"{"model":"fable","effortLevel":"xhigh"}"#.utf8).write(to: claudeHome.appending(path: "settings.json"))
        try Data("model = \"gpt-6-astra\"\nmodel_reasoning_effort = \"xhigh\"\n".utf8)
            .write(to: codexHome.appending(path: "config.toml"))
        let catalogs = HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
            claudeConfigDirectory: claudeHome, codexHome: codexHome, codexYardletHome: root.appending(path: "y")),
            environment: [:])
        catalogs.recordClaude(ModelVisibilityFixtures.claudeModels, for: nil)
        catalogs.recordCodex(codexModels, for: nil)

        let suite = testDefaultsSuite("ModelVisibilityRendering")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        runtimes.select(URL(filePath: "/usr/bin/true"), for: .claudeCode)
        runtimes.select(URL(filePath: "/usr/bin/true"), for: .codex)
        let connections = ProviderConnectionStore()
        connections.usesFixtureSnapshots = true
        connections.publishDefaults([account(.claudeCode, "developer@example.test"), account(.codex, "person@example.test")])
        let project = Project(name: "yardlet-sandbox", primaryRoot: workspace)

        for harness in [HarnessKind.claudeCode, .codex] {
            let draft = NewTaskDraft()
            draft.workspaceURL = workspace
            draft.projectID = project.id
            draft.harness = harness
            draft.text = harness == .codex ? "Fix the flaky test" : "Explain the build"
            await catalogs.refreshDefaults(for: harness, connection: nil, workspaceURL: workspace)
            let menu = try XCTUnwrap(NewTaskModelProjection.menu(harness: harness, choice: nil, catalogs: catalogs,
                connection: nil, workspaceURL: workspace))
            XCTAssertEqual(menu.title, harness == .codex ? "GPT-6-Astra · " + L10n.string("Extra high")
                                                         : "Fable · " + L10n.string("Extra high"))
            try render(name: "new-task-\(harness == .codex ? "codex" : "claude")", size: NSSize(width: 820, height: 260)) {
                NewTaskHome(recentSessions: [], projects: [project], draft: draft, runtimeSelections: runtimes,
                    connections: connections, models: NewTaskModelSource(catalogs: catalogs) { _, _, _, _ in },
                    onSelectSession: { _ in }, onChooseWorkspace: { _ in }, onShowHarnesses: {},
                    onCreate: { _ in nil })
            }
        }
    }

    func testTheSharedModelMenuOpensWithEachHarnesssOwnChoices() throws {
        let claude = ComposerModelMenu.provider(ClaudeComposerModelProjection.selectors(model: nil, effort: nil,
            defaults: HarnessModelDefaults(model: "fable", effort: "xhigh"), catalog: ModelVisibilityFixtures.claudeModels),
            speed: nil, canChoose: true)
        let codex = ComposerModelMenu.codex(CodexComposerModelProjection.catalog(live: CodexModelCatalog(), stored: nil,
            defaults: HarnessModelDefaults(model: "gpt-6-astra", effort: "xhigh"), cached: codexModels))
        XCTAssertEqual(claude.effort?.choices.map(\.value), ["default", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(codex.effort?.choices.map(\.value), ["low", "medium", "high", "xhigh", "max", "ultra"])
        // The effort list scrolls, which ImageRenderer does not draw, so the menus draw in the window too.
        for (name, menu) in [("menu-claude", claude), ("menu-codex", codex)] {
            try render(name: name, size: NSSize(width: 284, height: 300)) {
                HarnessIntelligencePicker(modelSelector: menu.model, reasoningSelector: menu.effort,
                    isAttached: true, onSetOption: { _, _ in }, onDismiss: {}, speedSelector: menu.speed)
                    .frame(width: 284)
            }
        }
    }

    private var codexModels: [CodexModelOption] {
        [CodexModelOption(id: "gpt-6.1-sol", model: "gpt-6.1-sol", displayName: "GPT-6.1-Sol", defaultReasoningEffort: "low",
                          supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"], isDefault: true,
                          serviceTiers: [CodexServiceTier(id: "priority", name: "Fast", description: "2x speed, increased usage")]),
         CodexModelOption(id: "gpt-6-astra", model: "gpt-6-astra", displayName: "GPT-6-Astra", defaultReasoningEffort: "medium",
                          supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"], isDefault: false),
         CodexModelOption(id: "gpt-6-luna", model: "gpt-6-luna", displayName: "GPT-6-Luna", defaultReasoningEffort: "medium",
                          supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"], isDefault: false)]
    }

    private func account(_ harness: HarnessKind, _ label: String) -> HarnessAccountSnapshot {
        HarnessAccountSnapshot(id: harness.rawValue, harness: harness, providerID: nil, state: .signedIn,
            accountLabel: label, detail: "", credentialOwner: harness.displayName, checkedAt: Date(),
            usage: [], canLogin: false, canLogout: true)
    }

    private func render<Content: View>(name: String, size: NSSize, @ViewBuilder content: () -> Content) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for appearance in [ColorScheme.light, .dark] {
            let view = content()
                .environment(\.colorScheme, appearance)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.canvas)
            let hosting = NSHostingView(rootView: view)
            // Never ordered on screen: a borderless backing window lets AppKit-backed fields and
            // scroll views draw, which ImageRenderer replaces with placeholders.
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            defer { window.close() }
            for _ in 0..<8 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appending(path: "\(name)-\(appearance == .dark ? "dark" : "light").png"))
        }
    }
}
