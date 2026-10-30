import Foundation
import XCTest
@testable import NativeHarnessClient

/// The sidebar's projection at the size people actually run Yardlet at — over a hundred tasks
/// across a few dozen projects: what it keeps answers as a fresh projection does.
/// `SidebarProjectionPerformanceTests` times a redraw of the same sidebar.
@MainActor
final class SidebarProjectionTests: XCTestCase {
    /// The kept groups and chats answer exactly as a fresh projection does, and follow any change to
    /// the tasks or the projects.
    func testTheKeptSidebarFollowsEveryChangeToTasksAndProjects() throws {
        let (projects, sessions) = sidebarFixture()
        let store = ProjectStore(repository: InMemoryProjectRepository(snapshot: ProjectSnapshot(projects: projects)),
                                 chatWorkspaceHome: sidebarHome)
        func fresh(_ sessions: [SessionRecord]) -> ([WorkspaceGroup], [SessionRecord]) {
            (ProjectProjection.visibleGroups(sessions: sessions, projects: store.projects, home: sidebarHome),
             ProjectProjection.chats(from: sessions, projects: store.projects, home: sidebarHome))
        }
        XCTAssertEqual(store.visibleGroups(sessions: sessions), fresh(sessions).0)
        XCTAssertEqual(store.chats(sessions: sessions), fresh(sessions).1)

        // A task with new activity brings its group to the top.
        var moved = sessions
        moved[2].updatedAt = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertNotEqual(store.visibleGroups(sessions: moved), store.visibleGroups(sessions: sessions))
        XCTAssertEqual(store.visibleGroups(sessions: moved), fresh(moved).0)

        // A new project takes the loose folder's tasks; a renamed one shows its new name.
        let loose = try XCTUnwrap(sessions.first { $0.workspaceURL.lastPathComponent.hasPrefix("loose-folder") })
        let added = store.ensureProject(forRoot: loose.workspaceURL, name: "Loose")
        XCTAssertTrue(store.visibleGroups(sessions: sessions).contains { $0.project?.id == added.id })
        store.rename(projects[0].id, to: "Renamed")
        XCTAssertEqual(store.visibleGroups(sessions: sessions).first { $0.project?.id == projects[0].id }?.displayName,
                       "Renamed")
        XCTAssertEqual(store.visibleGroups(sessions: sessions), fresh(sessions).0)
        XCTAssertEqual(store.chats(sessions: sessions), fresh(sessions).1)
    }

    /// A folder spelled relative to different bases is two folders, whatever was asked before.
    func testAKeptFolderSpellingIsTheFoldersOwn() {
        let first = URL(filePath: "repo", relativeTo: URL(filePath: "/Users/sidebar-test/a/"))
        let second = URL(filePath: "repo", relativeTo: URL(filePath: "/Users/sidebar-test/b/"))
        XCTAssertEqual(ProjectSidebarPresentation.normalizedPath(for: first), "/Users/sidebar-test/a/repo")
        XCTAssertEqual(ProjectSidebarPresentation.normalizedPath(for: second), "/Users/sidebar-test/b/repo")
        XCTAssertEqual(ProjectSidebarPresentation.normalizedPath(for: URL(filePath: "/Users/sidebar-test/a/x/../repo/")),
                       "/Users/sidebar-test/a/repo")
    }
}

/// That sidebar redrawn the way the main window redraws it: the groups and chats read by several
/// views in one pass, and each task row asking for its move options.
@MainActor
final class SidebarProjectionPerformanceTests: XCTestCase {
    /// One main-window redraw's worth of sidebar reads.
    private func redraw(_ store: ProjectStore, sessions: [SessionRecord]) -> Int {
        var work = 0
        for _ in 0..<5 { work += store.visibleGroups(sessions: sessions).count }
        for _ in 0..<3 { work += store.chats(sessions: sessions).count }
        for session in sessions {
            let visible = store.visibleGroups(sessions: sessions).compactMap(\.project)
            work += TaskProjectMove.options(for: session, visibleProjects: visible,
                                            projects: store.projects, home: sidebarHome).destinations.count
        }
        return work
    }

    /// Before the sidebar kept its projection, this took about 7 seconds per redraw in a debug
    /// build (every read projected every task against every project root again); kept, it takes a
    /// few milliseconds. The bound leaves room for a loaded machine and still catches a return to
    /// projecting per read.
    func testARedrawOfAHundredTasksStaysWithinAFewFrames() {
        let (projects, sessions) = sidebarFixture()
        let store = ProjectStore(repository: InMemoryProjectRepository(snapshot: ProjectSnapshot(projects: projects)),
                                 chatWorkspaceHome: sidebarHome)
        _ = redraw(store, sessions: sessions)
        let clock = ContinuousClock()
        let rounds = 20
        let elapsed = clock.measure {
            for _ in 0..<rounds { _ = redraw(store, sessions: sessions) }
        }
        let perRedraw = elapsed / rounds
        print("Sidebar redraw with \(sessions.count) tasks and \(projects.count) projects: \(perRedraw)")
        XCTAssertLessThan(perRedraw, .milliseconds(50))
    }
}

private let sidebarHome = URL(filePath: "/Users/sidebar-test")

/// 130 tasks across 30 projects: worktrees, chats, loose folders and tasks moved into a project.
private func sidebarFixture() -> (projects: [Project], sessions: [SessionRecord]) {
    let workspace = sidebarHome.appending(path: "Desktop/workspace")
    let projects = (0..<30).map { index in
        Project(name: "Project \(index)",
                primaryRoot: workspace.appending(path: "project-\(index)"),
                additionalRoots: [workspace.appending(path: "project-\(index)-docs")],
                isPinned: index == 3)
    }
    var sessions: [SessionRecord] = []
    for index in 0..<130 {
        let project = projects[index % projects.count]
        let workspaceURL: URL
        var origin: String?
        switch index % 5 {
        case 0:
            // A worktree of the project's repository.
            workspaceURL = project.primaryRoot.appending(path: ".claude/worktrees/agent-\(index)")
            origin = project.primaryRoot.path(percentEncoded: false)
        case 1:
            workspaceURL = sidebarHome.appending(path: "Documents/Codex/2026-10-\(index % 28 + 1)/new-chat-\(index)")
        case 2:
            workspaceURL = workspace.appending(path: "loose-folder-\(index % 7)")
        default:
            workspaceURL = project.primaryRoot
        }
        sessions.append(SessionRecord(
            harness: index.isMultiple(of: 2) ? .claudeCode : .codex,
            workspaceURL: workspaceURL,
            runtimeExecutableURL: URL(filePath: "/tmp/runtime"),
            title: "Task \(index)",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index * 7 % 130)),
            projectID: index % 5 == 3 ? project.id : nil,
            originWorkspacePath: origin
        ))
    }
    return (projects, sessions)
}
