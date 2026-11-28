import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders Yardlet instructions offscreen into `.build/yardlet-instructions-qa`, light and dark,
/// with a temporary store.
@MainActor
final class YardletInstructionsRenderingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-instructions-render-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func settings(_ store: YardletInstructionsStore, evaluation: RoutingEvaluationStore? = nil,
                          size: NSSize) -> some View {
        SettingsCenterView(size: CGSize(width: size.width, height: size.height),
                           initialSection: SettingsSection.instructions.rawValue,
                           notificationCenter: MenuBarQuietNotificationCenter(), instructions: store,
                           evaluation: evaluation)
    }

    /// `settings-instructions-evaluation-*.png`: the routing evaluation's card on, after one run.
    func testTheRoutingEvaluationCardDrawsOffAndAfterARun() async throws {
        let directory = try WindowlessRender.directory("yardlet-instructions-qa")
        let defaults = SuggestionVolatileDefaults()
        let store = YardletInstructionsStore(directory: root.appending(path: "instructions", directoryHint: .isDirectory),
                                             defaults: defaults)
        store.text = "- Prefer Opus 5.5 for implementation, Argon for review."
        let evaluation = RoutingEvaluationStore(directory: root.appending(path: "evaluation", directoryHint: .isDirectory),
                                                defaults: defaults)
        let size = NSSize(width: 820, height: 620)
        try WindowlessRender.hostedInBothAppearances("settings-instructions-evaluation-off", in: directory, size: size, content: { appearance in
            settings(store, evaluation: evaluation, size: size).environment(\.colorScheme, appearance.colorScheme)
        })
        evaluation.isEnabled = true
        let now = Date()
        let choice = RoutingChoice(kind: .review, harness: "codex", model: "gpt-6-astra", decidedAt: now, reason: "2 judges agree")
        await evaluation.finish(RoutingEvaluationResult(routing: [choice], changed: [choice], report: "# Report\n"),
                                evaluatedThrough: now, at: now)
        for capture in try WindowlessRender.hostedInBothAppearances("settings-instructions-evaluation", in: directory, size: size, content: { appearance in
            settings(store, evaluation: evaluation, size: size).environment(\.colorScheme, appearance.colorScheme)
        }) { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }

        let host = WindowlessRender.Host(settings(store, evaluation: evaluation, size: size), size: size)
        host.settle()
        let labels = host.accessibilityElements().map(\.label)
        host.close()
        XCTAssertTrue(labels.contains(L10n.string("Choose harnesses and models by daily evaluation")), labels.description)
        XCTAssertTrue(labels.contains(L10n.string("Open Report")), labels.description)
    }

    func testTheSettingsSectionAndTheProjectSheetDrawInBothAppearances() throws {
        let directory = try WindowlessRender.directory("yardlet-instructions-qa")
        let store = YardletInstructionsStore(directory: root.appending(path: "instructions", directoryHint: .isDirectory),
                                             defaults: SuggestionVolatileDefaults())
        store.text = "- Prefer Opus 5.5 for implementation, Argon for review."

        let size = NSSize(width: 820, height: 620)
        for capture in try WindowlessRender.hostedInBothAppearances("settings-instructions", in: directory, size: size, content: { appearance in
            settings(store, size: size).environment(\.colorScheme, appearance.colorScheme)
        }) { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }

        let host = WindowlessRender.Host(settings(store, size: size), size: size)
        host.settle()
        let labels = host.accessibilityElements().map(\.label)
        host.close()
        XCTAssertTrue(labels.contains(L10n.string("Use Yardlet instructions")), labels.description)
        XCTAssertTrue(labels.contains(L10n.string("Yardlet Instructions")), labels.description)

        store.isEnabled = false
        try WindowlessRender.hostedInBothAppearances("settings-instructions-off", in: directory, size: size, content: { appearance in
            settings(store, size: size).environment(\.colorScheme, appearance.colorScheme)
        })
        store.isEnabled = true

        let folder = root.appending(path: "yardlet", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = Project(name: "yardlet", primaryRoot: folder,
                              additionalRoots: [root.appending(path: "yardlet-docs", directoryHint: .isDirectory)])
        let projects = ProjectStore(repository: InMemoryProjectRepository(snapshot: ProjectSnapshot(projects: [project])),
                                    chatWorkspaceHome: root)
        store.setProjectText("- Write this repository's docs in plain English.\n- Build with `swift build --build-system native`.", for: project.id)
        let sheetSize = NSSize(width: 520, height: 560)
        func sheet(_ appearance: WindowlessRender.Appearance) -> some View {
            ProjectEditSheet(projects: projects, projectID: project.id, instructions: store)
                .frame(width: sheetSize.width, height: sheetSize.height, alignment: .top)
                .background(ParityTheme.canvas)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        for capture in try WindowlessRender.hostedInBothAppearances("project-instructions", in: directory, size: sheetSize,
                                                                    content: sheet) {
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
        }
        store.setDisabled(true, forProject: project.id)
        try WindowlessRender.hostedInBothAppearances("project-instructions-off", in: directory, size: sheetSize, content: sheet)
        XCTAssertNil(store.delivery(forProject: project.id))
    }
}
