import XCTest
@testable import NativeHarnessClient

/// Where a link another app opens with Yardlet, the person's default browser, goes (`AppModel.openExternalLinks`): a new
/// tab in the shown task's side panel, the new-task screen when the task has no room, another browser when neither has.
@MainActor
final class DefaultBrowserLinkTests: XCTestCase {
    private typealias Navigation = TaskSurfaceNavigationProjection

    func testALinkOpensBesideTheShownTaskThenOnTheNewTaskScreenThenElsewhere() throws {
        let task = SessionRecord(harness: .claudeCode, workspaceURL: FileManager.default.temporaryDirectory,
                                 runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Shown")
        let model = AppModel(store: SessionStore(sessions: [task]),
                             runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false),
                             restoresIndexOnLaunch: false, browserClient: { nil })
        model.splits.activate(.session(task.id))
        var elsewhere: [URL] = []
        func shownAddress(_ workspace: TaskWorkspaceState) -> String? {
            Navigation.browserKey(inTab: workspace.panels.trailingSurfaceID).flatMap { workspace.browserTabs.tab($0)?.address }
        }

        // A page opened in a panel asks the window to show its tasks; one sent elsewhere does not.
        var reveals = model.taskSurfaceRevealRequest
        let first = try XCTUnwrap(URL(string: "https://example.test/first"))
        model.openExternalLinks([first], elsewhere: { elsewhere.append($0) })
        XCTAssertEqual(model.taskSurfaceRevealRequest, reveals + 1)
        reveals = model.taskSurfaceRevealRequest
        let workspace = model.taskWorkspaces.state(for: task.id)
        XCTAssertEqual(shownAddress(workspace), first.absoluteString, "a new tab of the shown task's panel shows the page")
        XCTAssertEqual(model.splits.selection, .session(task.id), "the window keeps the task")

        while workspace.openBrowserTab() != nil {}
        let second = try XCTUnwrap(URL(string: "https://example.test/second"))
        model.openExternalLinks([second], elsewhere: { elsewhere.append($0) })
        XCTAssertEqual(shownAddress(model.taskWorkspaces.draft), second.absoluteString)
        XCTAssertEqual(model.splits.selection, .home, "the new-task screen shows it, in a tab of its own")
        XCTAssertEqual(model.taskSurfaceRevealRequest, reveals + 1)
        reveals = model.taskSurfaceRevealRequest
        XCTAssertTrue(model.splits.tabs.contains(.session(task.id)), "the task keeps its tab")

        while model.taskWorkspaces.draft.openBrowserTab() != nil {}
        let third = try XCTUnwrap(URL(string: "https://example.test/third"))
        model.openExternalLinks([third], elsewhere: { elsewhere.append($0) })
        XCTAssertEqual(elsewhere, [third], "with no room anywhere the link goes to another browser")
        XCTAssertEqual(model.taskSurfaceRevealRequest, reveals, "a link sent elsewhere leaves the window as it is")
    }
}
