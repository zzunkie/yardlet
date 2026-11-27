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
                runLocation: .approveForMe, providerSession: F.session(.codex), isProviderAttached: true,
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
            let field = try XCTUnwrap(elements.firstIndex { $0.role == "AXTextArea" }, name)
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
        XCTAssertEqual(value("codex", L10n.string("Permissions")), CodexRunLocation.approveForMe.shortName)
        XCTAssertEqual(value("claude", L10n.string("Permissions")), L10n.string("Accept edits"))
        XCTAssertEqual(value("opencode", L10n.string("Permissions")), L10n.string("On request"))
        XCTAssertEqual(value("codex", L10n.string("Model")), "GPT-6.1-Sol, \(L10n.string("High"))")
        XCTAssertEqual(value("claude", L10n.string("Model")), "Opus, High")
        XCTAssertEqual(value("opencode", L10n.string("Model")), "Sonnet, Medium")
        // The Claude app's numbers: "64k / 256k (25%)".
        XCTAssertEqual(value("codex", L10n.string("Context window"))?.hasSuffix("(25%)"), true)
        XCTAssertEqual(value("claude", L10n.string("Context window"))?.hasSuffix("(60%)"), true)
        // In a pane too narrow for the row, Send stays in view: the model control drops its effort and
        // then shortens, as both apps' do, rather than push Send past the composer's edge.
        for (name, view) in composers {
            let size = NSSize(width: 220, height: 220)
            let host = WindowlessRender.Host(view.frame(width: size.width, height: size.height, alignment: .bottom), size: size)
            host.settle()
            let send = try XCTUnwrap(Self.frame(of: L10n.string("Send"), in: host.hosting), name)
            XCTAssertTrue(host.window.frame.contains(send), "\(name): \(send) outside \(host.window.frame)")
            host.close()
        }
    }

    /// The screen frame of the first element the accessibility tree names `label`.
    private static func frame(of label: String, in root: NSView) -> NSRect? {
        WindowlessRender.withAccessibilityTree {
            func find(_ node: AnyObject) -> NSRect? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if (child.accessibilityLabel?() ?? nil) == label { return child.accessibilityFrame?() }
                    if let frame = find(child) { return frame }
                }
                return nil
            }
            return find(root)
        }
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
                    onSelectSession: { _ in }, onShowHarnesses: {},
                    onCreate: { _ in nil }))
            }
            let elements = try ComposerUnificationFixtures.render(scenario, into: directory)
            // The same session controls as the task composer, for what the task can start with:
            // Claude Code's permission mode (its launch flag) and Codex's permission (its thread's).
            let permissions = elements.first { $0.label == L10n.string("Permissions") }
            let expected: [HarnessKind: String] = [.claudeCode: L10n.string("Manual"), .codex: L10n.string("Ask for approval")]
            XCTAssertEqual(permissions?.value, expected[harness], harness.rawValue)
            XCTAssertEqual(elements.contains { $0.label == L10n.string("Model") }, harness != .openCode, harness.rawValue)
            // The task composer's "+", for files before the task exists, as in a new chat in both apps.
            XCTAssertTrue(elements.contains { $0.label == L10n.string("Add files and more") }, harness.rawValue)
        }

        // Codex with Full access chosen, and its menu as the control opens it: the Codex app's choices.
        let draft = NewTaskDraft()
        draft.workspaceURL = ComposerUnificationFixtures.workspace
        draft.projectID = project.id
        draft.harness = .codex
        draft.text = "Clean up the release branches"
        draft.modelChoices[.codex] = NewTaskModelChoice(model: nil, permissionMode: CodexRunLocation.dangerFullAccess.rawValue)
        let slot = try XCTUnwrap(ComposerSessionOptionsProjection.newTask(harness: .codex, choice: draft.modelChoices[.codex],
            catalogs: catalogs, connection: nil, workspaceURL: draft.workspaceURL).permission)
        let scenario = ComposerUnificationFixtures.Scenario(name: "new-task-codex-full-access", size: NSSize(width: 860, height: 600)) {
            AnyView(VStack(alignment: .leading, spacing: 12) {
                NewTaskHome(recentSessions: [], projects: [project], draft: draft, runtimeSelections: runtimes,
                    connections: connections, models: NewTaskModelSource(catalogs: catalogs) { _, _, _, _ in },
                    onSelectSession: { _ in }, onShowHarnesses: {},
                    onCreate: { _ in nil })
                    .frame(height: 280)
                PermissionMenuPreview(slot: slot)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.leading, 24)
            })
        }
        let elements = try ComposerUnificationFixtures.render(scenario, into: directory)
        XCTAssertEqual(elements.first { $0.label == L10n.string("Permissions") }?.value, L10n.string("Full access"))
        for location in CodexRunLocation.menu(current: .dangerFullAccess, config: CodexPermissionConfig()) {
            XCTAssertTrue(elements.contains { $0.label.contains(location.displayName) }, location.rawValue)
        }

        // In a split pane the row wraps, and the model shortens, rather than widen the screen past the
        // pane or run past the composer's edges: half of a 1360 point window beside the sidebar, and the
        // narrowest pane.
        connections.publishDefaults([HarnessAccountSnapshot(
            id: HarnessKind.codex.rawValue, harness: .codex, providerID: "openai-codex", state: .signedIn,
            accountLabel: "jordan.at.work@example.com", accountPlan: "Pro", detail: "", credentialOwner: "Codex CLI",
            checkedAt: Date(), usage: [], canLogin: false, canLogout: false)])
        let long = CodexModelOption(id: "gpt-6.1-sol-long", model: "gpt-6.1-sol-long", displayName: "GPT-6.1-Sol-Long-Context",
                                    defaultReasoningEffort: "xhigh", supportedReasoningEfforts: ["high", "xhigh"], isDefault: false)
        catalogs.recordCodex(ComposerUnificationFixtures.codexCatalog.models + [long], for: nil)
        let narrow = NewTaskDraft()
        narrow.workspaceURL = ComposerUnificationFixtures.workspace
        narrow.projectID = project.id
        narrow.harness = .codex
        narrow.text = "Clean up the release branches"
        narrow.modelChoices[.codex] = NewTaskModelChoice(model: long.model, effort: "xhigh")
        for width in [560, SplitLayoutMetrics.minimumPaneWidth] {
            let size = NSSize(width: width, height: 560)
            let host = WindowlessRender.Host(
                NewTaskHome(recentSessions: [], projects: [project], draft: narrow, runtimeSelections: runtimes,
                    connections: connections, models: NewTaskModelSource(catalogs: catalogs) { _, _, _, _ in },
                    onSelectSession: { _ in }, onShowHarnesses: {}, onCreate: { _ in nil })
                    .frame(width: size.width, height: size.height)
                    .background(ParityTheme.canvas),
                size: size, appearance: .light)
            defer { host.close() }
            host.settle()
            try WindowlessRender.writePNG(try host.capture().bitmap,
                to: directory.appending(path: "new-task-codex-\(Int(width)).png"))
            for label in ["Add files and more", "Permissions", "Model", "Start task"].map(L10n.string) {
                let frame = try XCTUnwrap(frame(of: label, in: host), "\(label) at \(width)")
                XCTAssertGreaterThanOrEqual(frame.minX, NewTaskHomeLayout.inset, "\(label) at \(width)")
                XCTAssertLessThanOrEqual(frame.maxX, width - NewTaskHomeLayout.inset, "\(label) at \(width)")
            }
        }
    }

    /// The frame, from the window's left edge, of the element labelled `label`.
    private func frame(of label: String, in host: WindowlessRender.Host<some View>) -> NSRect? {
        host.hosting.layoutSubtreeIfNeeded()
        return WindowlessRender.withAccessibilityTree {
            func visit(_ node: AnyObject) -> NSRect? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if (child.accessibilityLabel?() ?? nil) == label, let frame = child.accessibilityFrame?() { return frame }
                    if let found = visit(child) { return found }
                }
                return nil
            }
            return visit(host.hosting)?.offsetBy(dx: -host.window.frame.minX, dy: 0)
        }
    }

    /// A running Codex task's permission menu as its control opens it: the Codex app's choices with their
    /// descriptions, and the same menu where `config.toml` sets permissions of its own (Custom) and turns
    /// Approve for me off.
    func testACodexTasksPermissionMenuDrawsInBothAppearances() throws {
        typealias F = ComposerUnificationFixtures
        let standard = ComposerSessionOptionsProjection.codexPermission(.approveForMe, config: CodexPermissionConfig())
        let custom = ComposerSessionOptionsProjection.codexPermission(
            .custom, config: CodexPermissionConfig(offersApproveForMe: false, offersCustom: true))
        let scenario = F.Scenario(name: "task-codex-permissions", size: NSSize(width: 760, height: 470)) {
            AnyView(VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    PermissionMenuPreview(slot: standard).clipShape(RoundedRectangle(cornerRadius: 10))
                    PermissionMenuPreview(slot: custom).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.leading, 24)
                PromptComposer(harness: .codex, composerDraft: F.draft(""), modelCatalog: F.codexCatalog,
                    runLocation: .approveForMe, providerSession: F.session(.codex, status: .running),
                    isProviderAttached: true, isRunning: true, canSteer: true, codexQueue: F.queue,
                    codexHasThread: true, codexTokenUsage: F.codexTokenUsage, workspaceURL: F.workspace, actions: F.codexActions)
                    .frame(height: 190)
            }.frame(maxHeight: .infinity, alignment: .bottom))
        }
        let elements = try F.render(scenario, into: try WindowlessRender.directory(Self.folder))
        XCTAssertEqual(elements.first { $0.label == L10n.string("Permissions") }?.value, L10n.string("Approve for me"))
        for location in CodexRunLocation.allCases where location != .readOnly {
            XCTAssertTrue(elements.contains { $0.label.contains(location.displayName) }, location.rawValue)
            XCTAssertTrue(elements.contains { $0.label.contains(location.choiceDescription) }, location.rawValue)
        }
    }
}

/// The permission control's menu drawn on its own, as its popover shows it, so a render needs no window of its own.
private struct PermissionMenuPreview: View {
    let slot: ComposerPermissionSlot
    @FocusState private var focused: String?

    var body: some View {
        ComposerPermissionMenu(slot: slot, focusedChoice: $focused) { _, _, _ in }
    }
}
