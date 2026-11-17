import XCTest
@testable import NativeHarnessClient

@MainActor
final class NewTaskDraftTests: XCTestCase {
    private let firstProject = URL(filePath: "/tmp/project-a")
    private let secondProject = URL(filePath: "/tmp/project-b")
    private let runtime = URL(filePath: "/usr/bin/true")

    private func makeDraft() -> NewTaskDraft {
        let draft = NewTaskDraft()
        draft.prepare(defaultWorkspaceURL: firstProject, availableHarnesses: [.codex, .openCode])
        draft.text = "  홈 초안 👩🏽‍💻\n  keep indentation\n"
        return draft
    }

    func testADraftInAHiddenProjectStartsOverInTheFirstVisibleProject() {
        let visible = Project(name: "Visible", primaryRoot: secondProject)
        let hidden = Project(name: "Hidden", primaryRoot: firstProject, isHidden: true)
        let draft = makeDraft()
        draft.projectID = hidden.id
        draft.dropUnavailableProject(visible: [visible])
        XCTAssertEqual(draft.workspaceURL, secondProject)
        XCTAssertEqual(draft.projectID, visible.id)
        let text = draft.text
        draft.dropUnavailableProject(visible: [visible])
        XCTAssertEqual(draft.workspaceURL, secondProject, "A visible destination is kept")
        XCTAssertEqual(draft.text, text)
        let folderOnly = makeDraft()
        folderOnly.workspaceURL = secondProject
        folderOnly.projectID = nil
        folderOnly.dropUnavailableProject(visible: [visible])
        XCTAssertEqual(folderOnly.workspaceURL, secondProject, "A folder inside a visible project is kept")
    }

    func testReturningHomeKeepsTextAndExplicitProjectAndHarnessSelections() {
        let draft = makeDraft()
        let text = draft.text
        draft.workspaceURL = secondProject
        draft.harness = .openCode
        draft.prepare(defaultWorkspaceURL: firstProject, availableHarnesses: [.codex, .openCode])
        XCTAssertEqual(draft.text, text)
        XCTAssertEqual(draft.workspaceURL, secondProject)
        XCTAssertEqual(draft.harness, .openCode)
        XCTAssertFalse(draft.isCreating)
        XCTAssertTrue(NewTaskDraft().text.isEmpty)
    }

    func testSelectionSurvivesHomePreparationAndDestinationChangesWithoutPersistence() throws {
        let draft = makeDraft()
        let original = draft.text
        let range = try XCTUnwrap(original.range(of: "초안 👩🏽‍💻"))
        var writes = 0
        draft.onChange = { writes += 1 }
        draft.rememberSelection(NSRange(range, in: original), in: original)
        XCTAssertEqual(writes, 0)
        draft.workspaceURL = secondProject
        draft.harness = .openCode
        draft.prepare(defaultWorkspaceURL: firstProject, availableHarnesses: [.codex])
        XCTAssertEqual(draft.selection.map { String(draft.text[$0]) }, "초안 👩🏽‍💻")
        XCTAssertEqual(draft.text, original)
        draft.apply(draft.snapshot)
        XCTAssertNil(draft.selection, "A restored snapshot must not reuse an old editor range.")
    }

    func testHomeSelectionRejectsStaleTextAndRetainsOnlyValidNewCaret() throws {
        let draft = makeDraft()
        let previous = draft.text
        draft.rememberSelection(NSRange(location: 2, length: 2), in: previous)
        XCTAssertNotNil(draft.selection)
        draft.text = "  새 문장 👩🏽‍💻\n  끝"
        XCTAssertNil(draft.selection)
        draft.rememberSelection(NSRange(location: 2, length: 2), in: previous)
        XCTAssertNil(draft.selection)
        let caret = try XCTUnwrap(draft.text.range(of: "문장")).upperBound
        draft.rememberSelection(NSRange(caret..<caret, in: draft.text), in: draft.text)
        XCTAssertEqual(draft.selection, caret..<caret)
        draft.rememberSelection(NSRange(location: NSNotFound, length: 0), in: draft.text)
        XCTAssertEqual(draft.selection, caret..<caret)
    }

    func testExplicitProjectEntryBeforeFirstAppearanceWinsOverRecentProject() {
        let draft = NewTaskDraft()
        draft.workspaceURL = secondProject
        draft.prepare(defaultWorkspaceURL: firstProject, availableHarnesses: [.openCode, .codex])
        XCTAssertEqual(draft.workspaceURL, secondProject)
        XCTAssertEqual(draft.harness, .openCode)
        draft.workspaceURL = nil
        draft.prepare(defaultWorkspaceURL: firstProject, availableHarnesses: [.codex])
        XCTAssertNil(draft.workspaceURL, "A removed project must not be silently selected again.")
    }

    func testUnavailableSelectedHarnessIsPreservedUntilUserChoosesAnother() {
        let draft = makeDraft()
        draft.harness = .openCode
        draft.prepare(defaultWorkspaceURL: firstProject, availableHarnesses: [.codex])
        XCTAssertEqual(draft.harness, .openCode)
        XCTAssertFalse(draft.canCreate(runtimeURL: nil))
        XCTAssertNil(draft.beginSubmission(runtimeURL: nil))
        XCTAssertFalse(draft.isCreating)
    }

    func testFirstHarnessCanBecomeAvailableAfterOpeningAnEmptyHome() {
        let draft = NewTaskDraft()
        draft.prepare(defaultWorkspaceURL: nil, availableHarnesses: [])
        draft.text = "Keep my input"
        draft.prepare(defaultWorkspaceURL: firstProject, availableHarnesses: [.codex])
        XCTAssertEqual(draft.harness, .codex)
        XCTAssertNil(draft.workspaceURL)
        XCTAssertEqual(draft.text, "Keep my input")
        XCTAssertTrue(draft.startsChat, "With no project to start in, the task starts as a chat")
        draft.workspaceURL = firstProject
        draft.text = " \n "
        XCTAssertNil(draft.beginSubmission(runtimeURL: runtime))
    }

    func testStartSnapshotSurvivesNavigationAndBlocksDuplicateSubmission() throws {
        let draft = makeDraft()
        let original = draft.text
        let submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: runtime))
        draft.prepare(defaultWorkspaceURL: secondProject, availableHarnesses: [.openCode])
        XCTAssertTrue(draft.isCreating)
        XCTAssertNil(draft.beginSubmission(runtimeURL: runtime))
        XCTAssertEqual(submission.originalText, original)
        XCTAssertEqual(submission.prompt, "홈 초안 👩🏽‍💻\n  keep indentation")
        XCTAssertEqual(submission.harness, .codex)
        XCTAssertEqual(submission.workspaceURL, firstProject)
        XCTAssertEqual(submission.runtimeURL, runtime)
        draft.complete(submission, succeeded: false)
        XCTAssertFalse(draft.isCreating)
        XCTAssertTrue(draft.creationFailed)
        XCTAssertEqual(draft.text, original)
        XCTAssertNotNil(draft.beginSubmission(runtimeURL: runtime))
        XCTAssertFalse(draft.creationFailed)
    }

    func testSuccessfulStartClearsOnlySubmittedTextAndKeepsSelections() throws {
        let draft = makeDraft()
        let submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: runtime))
        draft.complete(submission, succeeded: true)
        XCTAssertTrue(draft.text.isEmpty)
        XCTAssertEqual(draft.workspaceURL, firstProject)
        XCTAssertEqual(draft.harness, .codex)
        XCTAssertFalse(draft.isCreating)
        XCTAssertFalse(draft.creationFailed)
    }

    func testLateSuccessDoesNotEraseAnEditedDraftOrChangedDestination() throws {
        for change in 0..<3 {
            let draft = makeDraft()
            let submission = try XCTUnwrap(draft.beginSubmission(runtimeURL: runtime))
            switch change {
            case 0: draft.text = "Next request"
            case 1: draft.workspaceURL = secondProject
            default: draft.harness = .openCode
            }
            let edited = draft.text
            draft.complete(submission, succeeded: true)
            XCTAssertEqual(draft.text, edited)
            XCTAssertFalse(draft.isCreating)
        }
    }

    func testStaleCompletionCannotChangeANewerSubmission() throws {
        let draft = makeDraft()
        let failed = try XCTUnwrap(draft.beginSubmission(runtimeURL: runtime))
        draft.complete(failed, succeeded: false)
        let retry = try XCTUnwrap(draft.beginSubmission(runtimeURL: runtime))
        draft.complete(failed, succeeded: true)
        XCTAssertTrue(draft.isCreating)
        XCTAssertFalse(draft.text.isEmpty)
        draft.complete(retry, succeeded: true)
        draft.text = "Another task"
        draft.complete(retry, succeeded: false)
        XCTAssertEqual(draft.text, "Another task")
        XCTAssertFalse(draft.creationFailed)
    }
}
