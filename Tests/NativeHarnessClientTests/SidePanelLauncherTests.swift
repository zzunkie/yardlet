import Foundation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The side panel's launcher and other tasks' tabs: what the launcher offers and in which order (the
/// Codex app's panel launcher), which tasks it lists, how a tab names its task, and how Review reads
/// a folder that no repository holds.
@MainActor
final class SidePanelLauncherTests: XCTestCase {
    func testTheLauncherOffersReviewOnlyWhereARepositoryOrATurnHasChangesInTheCodexAppsOrder() {
        let inRepository = TaskSidePanelTabs.choices(canOpenSideChat: true, offersReview: true)
        XCTAssertEqual(inRepository.map(\.id), ["diff", "terminal", "browser", "files", "sideChat"])
        XCTAssertEqual(inRepository.map(\.shortcut), ["⌘2", "⌘J", "⌘4", nil, nil])
        // Not known yet: as in a repository, so nothing moves once it is.
        XCTAssertEqual(TaskSidePanelTabs.choices(canOpenSideChat: true).map(\.id), inRepository.map(\.id))
        let elsewhere = TaskSidePanelTabs.choices(canOpenSideChat: false, offersReview: false)
        XCTAssertEqual(elsewhere.map(\.id), ["files", "sideChat", "browser", "terminal"])
        XCTAssertEqual(elsewhere.first { $0.id == "sideChat" }?.isAvailable, false)
    }

    func testTheLauncherListsRecentTasksAndFindsOthersByTitleOrProject() {
        let tasks = (0..<9).map { index in
            WorkSurfaceTab(id: "task:\(index)", title: index == 7 ? "Tidy the release notes" : "Task \(index)",
                           systemName: "text.bubble", detail: index == 8 ? "yardlet" : "landing")
        }
        XCTAssertEqual(SidePanelLauncher.shown(tasks, query: "").map(\.id), (0..<6).map { "task:\($0)" })
        XCTAssertEqual(SidePanelLauncher.shown(tasks, query: " release ").map(\.id), ["task:7"])
        XCTAssertEqual(SidePanelLauncher.shown(tasks, query: "YARD").map(\.id), ["task:8"])
        XCTAssertEqual(SidePanelLauncher.shown(tasks, query: "missing task"), [])
    }

    func testATaskTabNamesItsTaskWithItsHarnessAndProject() {
        let older = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/index"),
                                  runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "Fix the session index migration")
        let newer = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/notes"),
                                  runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "Tidy the release notes")
        let services = SidePanelTaskServices(
            record: { id in [older, newer].first { $0.id == id } },
            choices: { [newer, older] },
            projectName: { $0.workspaceURL.lastPathComponent },
            tab: { _, _ in AnyView(EmptyView()) })
        let tabs = services.choiceTabs()
        XCTAssertEqual(tabs.map(\.id), [newer, older].map { TaskSurfaceNavigationProjection.taskTabID($0.id) })
        XCTAssertEqual(tabs.map(\.title), ["Tidy the release notes", "Fix the session index migration"])
        XCTAssertEqual(tabs.map(\.harness), [.claudeCode, .codex])
        XCTAssertEqual(tabs.map(\.detail), ["notes", "index"])
        XCTAssertEqual(services.choiceTabs(limit: 1).count, 1)
    }

    func testFocusGoesToTheLauncherAndToAnotherTasksTab() {
        let launcher = TaskSurfaceNavigationProjection.showing(TaskSurfaceNavigationProjection.launcherID, in: .init())
        XCTAssertEqual(TaskFocusTarget.visibleContent(in: launcher), .launcher)
        let tab = TaskSurfaceNavigationProjection.showing(TaskSurfaceNavigationProjection.taskTabID(UUID()), in: .init())
        XCTAssertEqual(TaskFocusTarget.visibleContent(in: tab), .taskTab)
    }

    /// Git ends with 128 for a folder that no repository holds; Review says so quietly instead of
    /// showing Git's error, and the launcher leaves Review out.
    func testAFolderNoRepositoryHoldsIsNoRepositoryNotAGitFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "yardlet-no-repository-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            _ = try await GitDiffService().load(workspaceURL: folder)
            XCTFail("A folder outside Git has no diff")
        } catch let error as GitDiffServiceError {
            XCTAssertEqual(error, .notARepository)
            XCTAssertEqual(error.localizedDescription, L10n.string("Changes need a Git repository"))
        }
        let found = try await GitDiffService().repositories(containing: [folder])
        XCTAssertEqual(found, [])
    }
}
