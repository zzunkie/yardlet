import XCTest
@testable import NativeHarnessClient

final class CommandPaletteTests: XCTestCase {
    func testDownArrowStartsAtFirstAndWrapsAtEnd() {
        XCTAssertEqual(
            CommandPaletteSelection.movedIndex(currentIndex: nil, count: 3, offset: 1),
            0
        )
        XCTAssertEqual(
            CommandPaletteSelection.movedIndex(currentIndex: 2, count: 3, offset: 1),
            0
        )
    }

    func testUpArrowStartsAtLastAndWrapsAtBeginning() {
        XCTAssertEqual(
            CommandPaletteSelection.movedIndex(currentIndex: nil, count: 3, offset: -1),
            2
        )
        XCTAssertEqual(
            CommandPaletteSelection.movedIndex(currentIndex: 0, count: 3, offset: -1),
            2
        )
    }

    /// ⌘K finds tasks as the Codex app's command menu finds chats: first when searching, after the
    /// commands and only the most recent without a query.
    func testTasksComeFirstWhenSearchingAndAfterTheCommandsWithoutAQuery() {
        func item(_ title: String, _ subtitle: String, isTask: Bool = false) -> CommandPaletteItem {
            CommandPaletteItem(id: title, title: title, subtitle: subtitle, systemName: "", isTask: isTask, action: {})
        }
        let commands = [item("New task", "Choose a project"), item("Settings", "App preferences")]
        let tasks = (1...8).map { item("Fix login \($0)", "web", isTask: true) } + [item("Notes", "Settings app", isTask: true)]

        XCTAssertEqual(CommandPaletteSelection.shown(commands: commands, tasks: tasks, query: "").map(\.id),
                       ["New task", "Settings"] + (1...6).map { "Fix login \($0)" })
        XCTAssertEqual(CommandPaletteSelection.shown(commands: commands, tasks: tasks, query: " settings ").map(\.id),
                       ["Notes", "Settings"], "a task's project counts, and tasks lead")
    }

    func testSelectionReturnsNilForEmptyPalette() {
        XCTAssertNil(
            CommandPaletteSelection.movedIndex(currentIndex: nil, count: 0, offset: 1)
        )
    }
}
