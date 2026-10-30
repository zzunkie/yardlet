import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Opens the composer's model menu in a real window, as a click does, and counts what its popover
/// lists against the model lists Yardlet keeps (`model-catalogs.json`, in the shape the app saves
/// it): every model and every effort level, for Claude Code and Codex, in the task composer and the
/// new-task composer. Each menu is opened twice: with the lists already kept, and before them, when
/// opening the menu reads them and the choices arrive in the open popover. The second is how the
/// installed app showed one model and no effort levels: the popover kept the height of its
/// loading row and the lists, left to their scroll views, got none of it.
///
/// The window is ordered in off screen and transparent (a popover needs a window on screen); no
/// provider is contacted and no task attaches.
@MainActor
final class ComposerModelMenuWindowTests: XCTestCase {
    private enum Arrival: String { case kept, whenOpened }

    /// Not an async test: the menu reads its list in a main-actor task, which runs only while the
    /// test turns the run loop outside one.
    func testTheTaskComposersMenuListsEveryModelAndEffort() throws {
        for harness in [HarnessKind.claudeCode, .codex] {
            for arrival in [Arrival.kept, .whenOpened] {
                let fixture = try CatalogFixture(arrival: arrival, in: self)
                let session = SessionRecord(harness: harness, workspaceURL: fixture.root,
                    runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "Saved", status: .completed,
                    providerSessionID: "saved")
                let model = try makeModel(catalogs: fixture.catalogs, sessions: [session])
                let view = TaskComposerUnderTest(model: model, session: session, draft: TaskComposerDraft(),
                                                 prepare: { fixture.arrive() })
                try checkMenu(of: harness, in: view, size: NSSize(width: 760, height: 640),
                              name: "task \(harness.rawValue) \(arrival.rawValue)")
                XCTAssertFalse(model.isAttached(session.id))
            }
        }
    }

    func testTheNewTaskComposersMenuListsEveryModelAndEffort() throws {
        for harness in [HarnessKind.claudeCode, .codex] {
            for arrival in [Arrival.kept, .whenOpened] {
                let fixture = try CatalogFixture(arrival: arrival, in: self)
                let suite = testDefaultsSuite("ModelMenuWindow")
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false,
                                                     loadsPersistedSelections: false)
                runtimes.select(URL(filePath: "/usr/bin/true"), for: harness)
                let connections = ProviderConnectionStore()
                connections.usesFixtureSnapshots = true
                let project = Project(name: "yardlet-sandbox", primaryRoot: fixture.root)
                let draft = NewTaskDraft()
                draft.workspaceURL = fixture.root
                draft.projectID = project.id
                draft.harness = harness
                let view = NewTaskHome(recentSessions: [], projects: [project], draft: draft, runtimeSelections: runtimes,
                    connections: connections,
                    models: NewTaskModelSource(catalogs: fixture.catalogs) { _, _, _, _ in fixture.arrive() },
                    onSelectSession: { _ in }, onChooseWorkspace: { _ in }, onShowHarnesses: {}, onCreate: { _ in nil })
                try checkMenu(of: harness, in: view, size: NSSize(width: 1500, height: 640),
                              name: "new task \(harness.rawValue) \(arrival.rawValue)")
            }
        }
    }

    /// Task › Select model (⌃⇧M, the Codex app's `composer.openModelPicker`) asks the shown task's
    /// keyboard focus for the model menu, and the composer's control opens it at the effort; the
    /// session rail's copy of the control does not take the request.
    func testTheTaskMenusKeyOpensTheComposersModelMenu() throws {
        let fixture = try CatalogFixture(arrival: .kept, in: self)
        let session = SessionRecord(harness: .codex, workspaceURL: fixture.root,
            runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "Saved", status: .completed,
            providerSessionID: "saved")
        let model = try makeModel(catalogs: fixture.catalogs, sessions: [session])
        let focus = TaskKeyboardFocus()
        let view = TaskComposerUnderTest(model: model, session: session, draft: TaskComposerDraft(), prepare: {})
            .environment(\.taskKeyboardFocus, focus)
        let size = NSSize(width: 760, height: 640)
        let host = WindowlessRender.Host(view.frame(width: size.width, height: size.height), size: size)
        defer {
            host.close()
            host.settle(passes: 2)
        }
        host.window.alphaValue = 0
        host.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        host.window.orderFrontRegardless()
        host.settle()
        XCTAssertNil(host.window.childWindows?.first { $0.className.contains("Popover") })

        XCTAssertEqual(TaskCommandShortcut.openModelMenu.key, KeyEquivalent("m"))
        XCTAssertEqual(TaskCommandShortcut.openModelMenu.modifiers, [.control, .shift])
        focus.move(to: .modelMenu)
        let expected = ModelMenuCatalogFixture.expected(for: .codex)
        let popover = try XCTUnwrap(waitForPopover(of: host, rows: expected.efforts), "No popover")
        XCTAssertEqual(popover.buttons(in: expected.efforts), expected.efforts)
        XCTAssertNil(focus.request, "Taken once")
    }

    // MARK: - The check

    private func checkMenu<Content: View>(of harness: HarnessKind, in view: Content, size: NSSize, name: String) throws {
        let host = WindowlessRender.Host(view.frame(width: size.width, height: size.height), size: size)
        defer {
            host.close()
            host.settle(passes: 2)
        }
        host.window.alphaValue = 0
        host.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        host.window.orderFrontRegardless()
        host.settle()

        let trigger = try XCTUnwrap(host.hosting.accessibilityElement(labelled: L10n.string("Model")), name)
        let triggerFrame = trigger.accessibilityFrame?() ?? .zero
        XCTAssertTrue(trigger.accessibilityPerformPress?() ?? false, name)
        let expected = ModelMenuCatalogFixture.expected(for: harness)

        // The effort list opens first, under the chosen model.
        let popover = try XCTUnwrap(waitForPopover(of: host, rows: expected.efforts), "\(name): no popover")
        XCTAssertEqual(popover.buttons(in: expected.efforts), expected.efforts, "\(name): effort rows")
        XCTAssertEqual(popover.buttons(in: expected.efforts, visibleOnly: true), expected.efforts,
                       "\(name): effort rows inside the popover")
        try popover.write("\(name) effort")
        // The popover is the task window's own child window, so it is drawn in front of the
        // composer card, and it opens above the control rather than over the composer's row.
        XCTAssertTrue(host.window.childWindows?.contains(popover.window) == true, name)
        XCTAssertGreaterThanOrEqual(popover.window.frame.minY, triggerFrame.maxY - 1,
                                    "\(name): \(popover.window.frame) covers \(triggerFrame)")

        // The model row opens the model list.
        let modelRow = try XCTUnwrap(popover.content.accessibilityElement(labelled: L10n.string("Model")), name)
        XCTAssertTrue(modelRow.accessibilityPerformPress?() ?? false, name)
        let models = try XCTUnwrap(waitForPopover(of: host, rows: expected.models), "\(name): no model list")
        XCTAssertEqual(models.buttons(in: expected.models), expected.models, "\(name): model rows")
        host.settle(passes: 12, interval: 0.03) // past the list's slide, for the picture
        try models.write("\(name) models")
        let visible = models.buttons(in: expected.models, visibleOnly: true)
        XCTAssertEqual(visible, Array(expected.models.prefix(visible.count)), name)
        XCTAssertGreaterThanOrEqual(visible.count, min(expected.models.count, Self.visibleRowsAtLeast),
                                    "\(name): visible model rows")
    }

    /// A list longer than this scrolls inside the popover (280 pt of 32 pt rows).
    private static let visibleRowsAtLeast = 8

    @MainActor
    private struct Popover {
        let window: NSWindow
        let content: NSView

        /// The popover as drawn, for review, in `.build/model-menu-window-qa/`.
        func write(_ name: String) throws {
            let file = name.replacingOccurrences(of: " ", with: "-") + ".png"
            try WindowlessRender.writePNG(try WindowlessRender.capture(content),
                                          to: try WindowlessRender.directory("model-menu-window-qa").appending(path: file))
        }

        /// The rows among `names`, in the order the popover lists them.
        func buttons(in names: [String], visibleOnly: Bool = false) -> [String] {
            WindowlessRender.accessibilityElements(in: content, within: visibleOnly ? window.frame : nil)
                .filter { $0.role == NSAccessibility.Role.button.rawValue && names.contains($0.label) }
                .map(\.label)
        }
    }

    /// The host's popover once it shows `rows` (as many as fit), or as it is after a few seconds.
    private func waitForPopover<Content: View>(of host: WindowlessRender.Host<Content>, rows: [String]) -> Popover? {
        var popover: Popover?
        for _ in 0..<100 {
            host.settle(passes: 1, interval: 0.03)
            guard let window = host.window.childWindows?.first(where: { $0.className.contains("Popover") }),
                  let content = window.contentView else { continue }
            popover = Popover(window: window, content: content)
            if popover?.buttons(in: rows, visibleOnly: true).count == min(rows.count, Self.visibleRowsAtLeast) { break }
        }
        return popover
    }

    // MARK: - Fixtures

    private func makeModel(catalogs: HarnessModelCatalogStore, sessions: [SessionRecord]) throws -> AppModel {
        let suite = testDefaultsSuite("ModelMenuWindow")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(
            store: SessionStore(sessions: sessions),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { kind, url in UnsupportedHarnessAdapter(kind: kind, executableURL: url) },
            modelCatalogs: catalogs,
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }
        return model
    }

    /// A catalog store read from the fixture file, or an empty one that the fixture's lists reach
    /// when the menu asks for them, as a model list read does.
    @MainActor
    private struct CatalogFixture {
        let root: URL
        let catalogs: HarnessModelCatalogStore
        private let kept: HarnessModelCatalogStore

        init(arrival: Arrival, in test: XCTestCase) throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "model-menu-window-\(UUID().uuidString)")
            self.root = root
            test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appending(path: "model-catalogs.json")
            try ModelMenuCatalogFixture.json.write(to: file)
            let locations = HarnessModelSettingsLocations(
                claudeConfigDirectory: root.appending(path: "claude"), codexHome: root.appending(path: "codex"),
                codexYardletHome: root.appending(path: "codex-yardlet"))
            kept = HarnessModelCatalogStore(fileURL: file, locations: locations, environment: [:])
            catalogs = arrival == .kept ? kept : HarnessModelCatalogStore(locations: locations, environment: [:])
        }

        /// What a model list read leaves in the store.
        func arrive() {
            catalogs.recordClaude(kept.claudeModels(for: nil), for: nil)
            catalogs.recordCodex(kept.codexModels(for: nil), for: nil)
        }
    }
}

/// A task's composer as the task screen builds it: its model choices come from the app model,
/// which reads the catalog store, so a list that arrives redraws it.
private struct TaskComposerUnderTest: View {
    let model: AppModel
    let session: SessionRecord
    let draft: TaskComposerDraft
    let prepare: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            PromptComposer(
                harness: session.harness, composerDraft: draft,
                modelCatalog: model.composerCodexCapabilities(for: session).modelCatalog,
                providerSession: session, providerCapabilities: model.composerProviderCapabilities(for: session),
                isProviderAttached: model.isAttached(session.id), isRunning: false,
                codexHasThread: session.providerSessionID != nil, workspaceURL: session.workspaceURL,
                actions: ComposerActions(prepareProviderSettings: { prepare() }))
        }
    }
}

/// `~/.yardlet/model-catalogs.json` in the shape the app keeps it: seven Codex models with six
/// efforts each under the native scope, and thirteen Claude Code models with five effort levels
/// each under an account's scope.
enum ModelMenuCatalogFixture {
    static let codexEfforts = ["low", "medium", "high", "xhigh", "max", "ultra"]
    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    static let claudeScope = "29D9F1F4-2404-418D-BDFF-9FE16A4B9F37"
    static let codexModels: [(id: String, name: String)] = [
        ("gpt-6-astra", "GPT-6-Astra"), ("gpt-6-sol", "GPT-6-Sol"), ("gpt-6-luna", "GPT-6-Luna"),
        ("gpt-5.6-sol", "GPT-5.6-Sol"), ("gpt-5.6-terra", "GPT-5.6-Terra"), ("gpt-5.6-luna", "GPT-5.6-Luna"),
        ("gpt-daybreak-blue-latest", "GPT-Daybreak-Blue")
    ]
    static let claudeModels: [(value: String, name: String)] = [
        ("default", "Default (recommended)"), ("opus", "Opus 5.5"), ("claude-fable-5-1", "Fable 5.1"),
        ("sonnet", "Sonnet 5.5"), ("haiku", "Haiku 5.5"), ("claude-haiku-5", "Haiku 5"),
        ("claude-sonnet-5", "Sonnet 5"), ("claude-opus-5", "Opus 5"), ("claude-fable-5", "Fable 5"),
        ("claude-opus-4-8", "Opus 4.8"), ("claude-opus-4-7", "Opus 4.7"), ("claude-opus-4-6", "Opus 4.6"),
        ("claude-sonnet-4-6", "Sonnet 4.6")
    ]

    static var json: Data {
        let codex: [[String: Any]] = codexModels.enumerated().map { index, model in
            ["id": model.id, "model": model.id, "displayName": model.name, "isDefault": index == 0,
             "defaultReasoningEffort": "medium", "supportedReasoningEfforts": codexEfforts,
             "serviceTiers": [["id": "priority", "name": "Fast", "description": "2x speed, increased usage"]]]
        }
        let claude: [[String: Any]] = claudeModels.map { model in
            ["value": model.value, "name": model.name, "description": "\(model.name) description",
             "effortLevels": claudeEfforts]
        }
        let object: [String: Any] = ["version": 1, "codex": ["default": codex], "claude": [claudeScope: claude]]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// The rows the menu lists, as it names them: the model list, and the effort list of the model
    /// a task starts on (Claude Code's default model, with its own Default level first; Codex's
    /// default model).
    static func expected(for harness: HarnessKind) -> (models: [String], efforts: [String]) {
        switch harness {
        case .codex:
            return (codexModels.map(\.name), codexEfforts.map(CodexReasoningLabel.name))
        default:
            return (claudeModels.map(\.name), [L10n.string("Default")] + claudeEfforts.map(CodexReasoningLabel.name))
        }
    }
}

private extension NSView {
    /// The first accessibility element under the view with this label, found as an assistive app
    /// finds it (`AXEnhancedUserInterface` on while looking).
    func accessibilityElement(labelled label: String) -> AnyObject? {
        WindowlessRender.withAccessibilityTree {
            func visit(_ node: AnyObject) -> AnyObject? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if (child.accessibilityLabel?() ?? nil) == label { return child }
                    if let found = visit(child) { return found }
                }
                return nil
            }
            return visit(self)
        }
    }
}
