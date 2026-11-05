import CSQLite
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// "Detach to top level" (the Claude app's row menu item, `XP5vxiZixk`): a task listed under the
/// task it was started from moves to the top level and stays there. Yardlet's index keeps the mark
/// (`SessionRecord.isLineageDetached`, column `lineage_detached`), so no later link from a harness
/// or another app nests it again. Moving a task one level up or under another task in the sidebar
/// (`TaskNesting`) keeps the same mark, and so do the tasks a move places flat to keep the sidebar's
/// levels. Nothing is written outside the index.
@MainActor
final class TaskDetachTests: XCTestCase {
    private let folder = URL(filePath: "/tmp/detach-qa/project", directoryHint: .isDirectory)
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(_ title: String, harness: HarnessKind = .claudeCode, parent: SessionRecord? = nil,
                      minutesAgo: Double, providerSessionID: String? = nil, in workspace: URL? = nil) -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: workspace ?? folder, runtimeExecutableURL: URL(filePath: "/tmp/agent"),
                      title: title, titleOrigin: .provider, updatedAt: clock.addingTimeInterval(-minutesAgo * 60),
                      providerSessionID: providerSessionID ?? UUID().uuidString.lowercased(), parentTaskID: parent?.id)
    }

    private func titles(_ rows: [SidebarRow]) -> [String] {
        rows.flatMap(\.rowsWithChildren).map { ($0.isNestedChild ? "  " : "") + $0.title }
    }

    /// Each row of the first project as "title@depth", in the order shown.
    private func placed(_ store: SessionStore, other: [SessionRecord] = []) -> [String] {
        layout(store, other: other).sections[0].rows.flatMap(\.rowsWithChildren)
            .map { "\($0.title)@\($0.familyPlace?.depth ?? 0)" }
    }

    /// The sidebar of the store's tasks in this test's project, and `other` in a second project.
    private func layout(_ store: SessionStore, other: [SessionRecord] = []) -> SidebarProjection.Layout {
        let groups = [WorkspaceGroup(workspaceURL: folder, sessions: store.sessions.filter { $0.workspaceURL == folder }),
                      WorkspaceGroup(workspaceURL: other.first?.workspaceURL ?? folder, sessions: other)]
            .filter { !$0.sessions.isEmpty }
        return SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false,
                                        archivedParents: store.archivedParentIDs)
    }

    /// Detaching takes the task out of its family to the top level, where its own family follows it.
    /// It is not activity: the task keeps its place in recency order.
    func testDetachingMovesATaskToTheTopLevelWithItsOwnFamily() async throws {
        let parent = task("Plan the release", minutesAgo: 30)
        let child = task("Tag the build", parent: parent, minutesAgo: 10)
        let grandchild = task("Check the tag", parent: child, minutesAgo: 20)
        let store = SessionStore(sessions: [parent, child, grandchild])
        func layoutTitles() -> [String] {
            let groups = [WorkspaceGroup(workspaceURL: folder, sessions: store.sessions)]
            return titles(SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [],
                                                   isFiltering: false).sections[0].rows)
        }
        XCTAssertEqual(layoutTitles(), ["Plan the release", "  Tag the build", "  Check the tag"])

        let detached = try await store.detachFromParent(id: child.id)
        XCTAssertNil(detached?.parentTaskID)
        XCTAssertEqual(detached?.isLineageDetached, true)
        XCTAssertEqual(detached?.updatedAt, child.updatedAt, "Detaching is not activity")
        XCTAssertEqual(store.sessions.first { $0.id == grandchild.id }?.parentTaskID, child.id,
                       "The tasks started from it stay with it")
        XCTAssertEqual(layoutTitles(), ["Tag the build", "  Check the tag", "Plan the release"])
    }

    /// Moving a task in the sidebar's families, as Finder and Mail move a folder: its row's menu offers
    /// one level up, the top level and the tasks of its list it can go under; a drop on a row puts it
    /// under that row's task, and on the row's top or bottom edge beside it, at that row's level. It
    /// never goes under itself or a task under it, nor into another project's list. The tasks under
    /// it go with it, the move is not activity, and no link read later moves it back.
    func testATaskMovesUpALevelUnderAnotherOrBesideARowButNeverUnderItself() async throws {
        let plan = task("Plan the release", minutesAgo: 30)
        let tag = task("Tag the build", parent: plan, minutesAgo: 10)
        let check = task("Check the tag", parent: tag, minutesAgo: 20)
        let notes = task("Write the notes", minutesAgo: 40)
        let elsewhere = task("Elsewhere", minutesAgo: 5,
                             in: URL(filePath: "/tmp/detach-qa/other", directoryHint: .isDirectory))
        let store = SessionStore(sessions: [plan, tag, check, notes])
        XCTAssertEqual(placed(store), ["Plan the release@0", "Tag the build@1", "Check the tag@2", "Write the notes@0"])

        // The menu: one level up and the tasks it can go under, in the order shown.
        var shown = layout(store, other: [elsewhere])
        XCTAssertEqual(TaskNesting.options(for: check.id, in: shown),
                       TaskNesting.Options(levelUp: plan.id, isNested: true,
                                           parents: [.init(id: plan.id, title: "Plan the release"),
                                                     .init(id: notes.id, title: "Write the notes")]))
        XCTAssertEqual(TaskNesting.options(for: tag.id, in: shown).levelUp, nil, "Detach to top level is that move")
        XCTAssertEqual(TaskNesting.options(for: plan.id, in: shown),
                       TaskNesting.Options(parents: [.init(id: notes.id, title: "Write the notes")]),
                       "Not under the tasks under it")
        XCTAssertEqual(TaskNesting.options(for: elsewhere.id, in: shown).parents, [], "Only its own project's tasks")

        // Drops: the middle of a row is under it, its top and bottom quarters beside it.
        XCTAssertEqual([2, 15, 28].map { TaskNesting.drop(at: $0, height: 30) }, [.above, .under, .below])
        XCTAssertEqual(TaskNesting.parent(of: check.id, dropped: .above, on: tag.id, in: shown), .some(plan.id))
        XCTAssertEqual(TaskNesting.parent(of: notes.id, dropped: .under, on: tag.id, in: shown), .some(tag.id))
        XCTAssertNil(TaskNesting.parent(of: notes.id, dropped: .under, on: check.id, in: shown),
                     "Nothing goes under a task at the deepest level")
        XCTAssertEqual(TaskNesting.parent(of: tag.id, dropped: .below, on: notes.id, in: shown), .some(nil))
        XCTAssertNil(TaskNesting.parent(of: check.id, dropped: .under, on: tag.id, in: shown), "Already there")
        XCTAssertNil(TaskNesting.parent(of: notes.id, dropped: .above, on: plan.id, in: shown), "Already there")
        XCTAssertNil(TaskNesting.parent(of: plan.id, dropped: .under, on: check.id, in: shown), "Under a task under it")
        XCTAssertNil(TaskNesting.parent(of: plan.id, dropped: .below, on: check.id, in: shown), "Beside a task under it")
        XCTAssertNil(TaskNesting.parent(of: check.id, dropped: .under, on: check.id, in: shown))
        XCTAssertNil(TaskNesting.parent(of: elsewhere.id, dropped: .under, on: plan.id, in: shown), "Another project")

        // One level up: the task goes beside its parent, under its parent's parent.
        let moved = try await store.nest(id: check.id, under: plan.id)
        XCTAssertEqual(moved?.isLineageDetached, true)
        XCTAssertNil(moved?.startedFromTaskID, "The person placed it: no task is known to have started it")
        XCTAssertEqual(moved?.updatedAt, check.updatedAt, "Moving is not activity")
        XCTAssertEqual(placed(store), ["Plan the release@0", "Tag the build@1", "Check the tag@1", "Write the notes@0"])

        // A top-level task under another, with the tasks under it; one the move would leave deeper than
        // the sidebar draws goes under the task it is drawn under.
        try await store.nest(id: tag.id, under: notes.id)
        XCTAssertEqual(placed(store), ["Write the notes@0", "Tag the build@1", "Plan the release@0", "Check the tag@1"])
        let flat = try XCTUnwrap(TaskNesting.flattening(moving: notes.id, under: check.id, in: layout(store)))
        XCTAssertEqual(flat, [tag.id: check.id])
        try await store.nest(id: notes.id, under: check.id, flattening: flat)
        XCTAssertEqual(placed(store), ["Plan the release@0", "Check the tag@1", "Tag the build@2", "Write the notes@2"])
        XCTAssertEqual(store.sessions.first { $0.id == tag.id }?.parentTaskID, check.id,
                       "Beside the task it was under, the more recently active first")
        shown = layout(store)
        XCTAssertEqual(TaskNesting.options(for: tag.id, in: shown).levelUp, plan.id)

        // Never under itself or a task under it, and no link read later replaces the person's.
        let underItsOwn = try await store.nest(id: plan.id, under: tag.id)
        let underItself = try await store.nest(id: notes.id, under: notes.id)
        XCTAssertNil(underItsOwn)
        XCTAssertNil(underItself)
        XCTAssertNil(store.sessions.first { $0.id == plan.id }?.parentTaskID)
        let linked = try await store.linkParents([check.id: tag.id, tag.id: plan.id])
        XCTAssertEqual(linked, [])
        XCTAssertEqual(placed(store), ["Plan the release@0", "Check the tag@1", "Tag the build@2", "Write the notes@2"])
    }

    /// 2026-11-05 report: the sidebar draws three levels and a task further down at the third, so a task with tasks
    /// under it moved under another left them deeper than drawn, where "Move up one level" changed nothing in view.
    /// The row's menu and drops now go by the rows as drawn and put nothing under a task at the deepest level, and a
    /// move places the tasks it would leave deeper flat under the task they are drawn under: the index holds what the
    /// sidebar draws, and the phone, `list_tasks` and `read_task` say the same. A task placed that way still knows who
    /// started it; one an agent started further down keeps its link until the person moves it. Drawn into
    /// `.build/task-nesting-qa`, light and dark: `deep-family-*.png` (as the agent left it), `deep-moved-*.png` (its
    /// third level moved under the other family's second) and `deep-up-*.png` (then one of them a level up).
    func testAMoveKeepsEveryTaskWithinTheLevelsDrawnAndOneLevelUpIsOneLevelUpInView() async throws {
        let plan = task("Plan the release", minutesAgo: 10)
        let tag = task("Tag the build", parent: plan, minutesAgo: 20)
        let check = task("Check the tag", parent: tag, minutesAgo: 30)
        let sign = task("Sign the binary", parent: check, minutesAgo: 40)
        let notarize = task("Notarize it", parent: sign, minutesAgo: 50)
        let docs = task("Update the docs", minutesAgo: 60)
        let site = task("Publish the site", parent: docs, minutesAgo: 70)
        let sessions = [plan, tag, check, sign, notarize, docs, site]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TaskDetachTests")))
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in FakeHarnessAdapter(kind: .claudeCode) },
            restoresIndexOnLaunch: false)
        func drawn() -> [String] {
            model.sidebarLists.sections[0].rows.flatMap(\.rowsWithChildren)
                .map { "\($0.title)@\($0.familyPlace?.depth ?? 0)" }
        }
        func stored(_ task: SessionRecord) -> SessionRecord? { model.store.sessions.first { $0.id == task.id } }
        let directory = try WindowlessRender.directory("task-nesting-qa")
        func render(_ name: String) throws {
            let lists = model.sidebarLists
            let groups = model.projects.visibleGroups(sessions: model.store.listedSessions)
            try WindowlessRender.hostedInBothAppearances(name, in: directory,
                                                         size: NSSize(width: ParityTheme.sidebarWidth, height: 520)) {
                TaskSidebar(layout: lists, allGroups: groups, isRestoring: false, selection: .home,
                    searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                    projects: model.projects, onEditProject: { _ in }, onArchiveProjectChats: { _ in },
                    onRemoveProject: { _ in }, onTogglePinned: { _ in }, onArchive: { _ in }, onDelete: { _ in },
                    onRename: { _ in }, onMarkRead: { _ in })
                    .tint(Color.primary)
                    .environment(\.colorScheme, $0.colorScheme)
                    .frame(width: ParityTheme.sidebarWidth, height: 520, alignment: .top)
                    .background(ParityTheme.sidebar)
            }
        }
        /// The index, the phone and `list_tasks` name for each task the task the sidebar draws it under.
        func agree(file: StaticString = #filePath, line: UInt = #line) async throws {
            let drawnUnder = model.sidebarLists.nestingParents
            let phone = Dictionary(uniqueKeysWithValues: AppModelRemoteBridge(model: model).snapshot().tasks.map {
                ($0.id, $0.parentTaskId)
            })
            let listed = await model.callSessionTool(named: "list_tasks", arguments: try suggestionToolJSON(["scope": "all"]),
                                                     callerID: plan.id)
            let listing = try JSONDecoder().decode(Listing.self, from: Data(listed.text.utf8))
            for session in model.store.sessions {
                let under = drawnUnder[session.id]?.uuidString
                XCTAssertEqual(session.parentTaskID?.uuidString, under, "\(session.title) in the index", file: file, line: line)
                XCTAssertEqual(phone[session.id.uuidString], .some(under), "\(session.title) on the phone", file: file, line: line)
                XCTAssertEqual(listing.tasks.first { $0.taskId == session.id.uuidString }?.parentTaskId, under,
                               "\(session.title) in list_tasks", file: file, line: line)
            }
        }

        // As the agent left it: the fourth and fifth levels drawn at the third, beside the task the fourth was started
        // from, and their menus one level up from there.
        XCTAssertEqual(drawn(), ["Plan the release@0", "Tag the build@1", "Check the tag@2", "Sign the binary@2",
                                 "Notarize it@2", "Update the docs@0", "Publish the site@1"])
        try render("deep-family")
        var lists = model.sidebarLists
        XCTAssertEqual(TaskNesting.options(for: notarize.id, in: lists),
                       TaskNesting.Options(levelUp: plan.id, isNested: true,
                                           parents: [.init(id: plan.id, title: "Plan the release"),
                                                     .init(id: docs.id, title: "Update the docs"),
                                                     .init(id: site.id, title: "Publish the site")]),
                       "Not under a task at the deepest level")
        XCTAssertNil(TaskNesting.parent(of: site.id, dropped: .under, on: sign.id, in: lists), "Sign the binary is deepest")
        XCTAssertNil(TaskNesting.parent(of: notarize.id, dropped: .below, on: check.id, in: lists), "Drawn there already")
        XCTAssertEqual(TaskNesting.parent(of: site.id, dropped: .below, on: check.id, in: lists), .some(tag.id))
        await model.nest(docs.id, under: sign.id)
        XCTAssertNil(stored(docs)?.parentTaskID, "Refused: nothing goes under a task at the deepest level")

        // "Move up one level" on the fifth level: under the first, one level up from where it is drawn. The fourth keeps
        // the link the agent made.
        await model.nest(notarize.id, under: try XCTUnwrap(TaskNesting.options(for: notarize.id, in: lists).levelUp))
        XCTAssertEqual(drawn(), ["Plan the release@0", "Tag the build@1", "Check the tag@2", "Sign the binary@2",
                                 "Notarize it@1", "Update the docs@0", "Publish the site@1"])
        XCTAssertEqual(stored(sign)?.parentTaskID, check.id)
        XCTAssertEqual(stored(sign)?.isLineageDetached, false)

        // The third level, with the fourth under it, under the other family's second: both go to the third level, flat
        // under the task they are drawn under, and the fourth still knows who started it.
        lists = model.sidebarLists
        XCTAssertEqual(TaskNesting.parent(of: tag.id, dropped: .under, on: site.id, in: lists), .some(site.id))
        await model.nest(tag.id, under: site.id)
        XCTAssertEqual(drawn(), ["Plan the release@0", "Notarize it@1", "Update the docs@0", "Publish the site@1",
                                 "Tag the build@2", "Check the tag@2", "Sign the binary@2"])
        for task in [tag, check, sign] {
            XCTAssertEqual(stored(task)?.parentTaskID, site.id, task.title)
            XCTAssertEqual(stored(task)?.isLineageDetached, true, task.title)
        }
        XCTAssertNil(stored(tag)?.startedFromTaskID, "The person moved it: as any task the person placed")
        XCTAssertEqual(stored(check)?.startedFromTaskID, tag.id, "Placed flat, it still knows who started it")
        XCTAssertEqual(stored(sign)?.startedFromTaskID, check.id)
        XCTAssertEqual(TaskMessage.relation(of: tag.id.uuidString, to: try XCTUnwrap(stored(check))), .parent)
        try await agree()
        let read = await model.callSessionTool(named: "read_task", arguments: try suggestionToolJSON(["task_id": site.id.uuidString]),
                                               callerID: plan.id)
        let head = try JSONDecoder().decode(ReadHead.self, from: Data(try XCTUnwrap(read.text.components(separatedBy: "\n\n").first).utf8))
        XCTAssertEqual(Set(head.childTaskIds ?? []), Set([tag, check, sign].map(\.id.uuidString)), read.text)
        try render("deep-moved")

        // One of them a level up: under the other family's top, one level up from where it is drawn.
        lists = model.sidebarLists
        await model.nest(check.id, under: try XCTUnwrap(TaskNesting.options(for: check.id, in: lists).levelUp))
        XCTAssertEqual(drawn(), ["Plan the release@0", "Notarize it@1", "Update the docs@0", "Check the tag@1",
                                 "Publish the site@1", "Tag the build@2", "Sign the binary@2"])
        XCTAssertEqual(stored(check)?.parentTaskID, docs.id)
        XCTAssertNil(stored(check)?.startedFromTaskID, "Now the person moved it")
        try await agree()
        try render("deep-up")
        XCTAssertNil(model.bootstrapError)
        await model.shutdown()
    }

    private struct Listing: Decodable {
        struct Entry: Decodable {
            var taskId: String
            var parentTaskId: String?
        }
        var tasks: [Entry]
    }

    private struct ReadHead: Decodable {
        var childTaskIds: [String]?
    }

    /// A move is kept in the index across a restart, a task under an archived one is still under it
    /// (so nothing goes under a task it is itself above), and a task the person placed names no task
    /// that started it: a message from its new parent reads as another task's.
    func testAMoveIsKeptAcrossARestartAndNamesNoTaskThatStartedIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "nest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "session-index.sqlite3")
        let plan = task("Plan the release", minutesAgo: 30)
        let tag = task("Tag the build", parent: plan, minutesAgo: 10)
        let check = task("Check the tag", parent: tag, minutesAgo: 20)
        let notes = task("Write the notes", minutesAgo: 40)
        let repository = try SQLiteSessionRepository(databaseURL: database)
        for session in [plan, tag, check, notes] { try await repository.upsert(session) }
        try await repository.archive(id: tag.id)
        let store = SessionStore(repository: repository)
        try await store.restore()
        XCTAssertEqual(placed(store), ["Plan the release@0", "Check the tag@1", "Write the notes@0"])
        XCTAssertEqual(TaskMessage.relation(of: tag.id.uuidString, to: check), .parent)

        let refused = try await store.nest(id: plan.id, under: check.id)
        XCTAssertNil(refused, "Check the tag is under it, through the archived task")
        try await store.nest(id: notes.id, under: check.id)
        try await store.nest(id: check.id, under: nil)
        XCTAssertEqual(placed(store), ["Check the tag@0", "Write the notes@1", "Plan the release@0"])

        let reopened = SessionStore(repository: try SQLiteSessionRepository(databaseURL: database))
        try await reopened.restore()
        XCTAssertEqual(placed(reopened), ["Check the tag@0", "Write the notes@1", "Plan the release@0"])
        let saved = try XCTUnwrap(reopened.sessions.first { $0.id == notes.id })
        XCTAssertEqual(saved.parentTaskID, check.id)
        XCTAssertTrue(saved.isLineageDetached)
        XCTAssertEqual(TaskMessage.relation(of: check.id.uuidString, to: saved), .task)
        let unplaced = try XCTUnwrap(reopened.sessions.first { $0.id == plan.id })
        XCTAssertFalse(unplaced.isLineageDetached, "A task the person did not move keeps no mark")
    }

    /// A detached task is never linked again: not by a link pass over imported conversations or
    /// the Claude app's files (`TaskLineage.links`), not by the store, and not when a Codex thread
    /// read names the thread it was forked from. A task that was not detached still links.
    func testADetachedTaskIsNotLinkedAgainByAnImportOrAThreadRead() async throws {
        let parent = task("Parent", minutesAgo: 30)
        var detached = task("Detached", minutesAgo: 20)
        detached.isLineageDetached = true
        let other = task("Never linked", minutesAgo: 10)
        let parents = [detached.providerSessionID!: parent.providerSessionID!,
                       other.providerSessionID!: parent.providerSessionID!]
        XCTAssertEqual(TaskLineage.links(parents: parents, harness: .claudeCode, sessions: [parent, detached, other]),
                       [other.id: parent.id])
        let store = SessionStore(sessions: [parent, detached, other])
        let linked = try await store.linkParents([detached.id: parent.id, other.id: parent.id])
        XCTAssertEqual(linked, [other.id])
        XCTAssertNil(store.sessions.first { $0.id == detached.id }?.parentTaskID)
        XCTAssertEqual(store.sessions.first { $0.id == other.id }?.parentTaskID, parent.id)

        // A Codex thread read: the fork that was detached stays at the top level, another fork links.
        let codexParent = task("Codex parent", harness: .codex, minutesAgo: 9, providerSessionID: "thread-parent")
        var codexDetached = task("Detached fork", harness: .codex, minutesAgo: 8, providerSessionID: "thread-detached")
        codexDetached.isLineageDetached = true
        let codexFork = task("Fork", harness: .codex, minutesAgo: 7, providerSessionID: "thread-fork")
        func state(_ id: String, forkedFrom: String?) -> CodexTaskState {
            var state = CodexTaskState.empty
            var fields: [String: JSONValue] = ["id": .string(id), "turns": .array([])]
            if let forkedFrom { fields["forkedFromId"] = .string(forkedFrom) }
            XCTAssertTrue(CodexTaskReducer().applySnapshot(.object(fields), to: &state))
            return state
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TaskDetachTests")))
        let sessions = [codexParent, codexDetached, codexFork]
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in FakeHarnessAdapter(kind: .codex) },
            initialCodexPresentation: [
                codexDetached.id: state("thread-detached", forkedFrom: "thread-parent"),
                codexFork.id: state("thread-fork", forkedFrom: "thread-parent"),
                codexParent.id: state("thread-parent", forkedFrom: nil),
            ],
            restoresIndexOnLaunch: false)
        try await waitUntil {
            model.store.sessions.first(where: { $0.id == codexFork.id })?.parentTaskID != nil
        }
        // Give a link that should not come the same time to arrive.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.store.sessions.first { $0.id == codexFork.id }?.parentTaskID, codexParent.id)
        XCTAssertNil(model.store.sessions.first { $0.id == codexDetached.id }?.parentTaskID)
        await model.shutdown()
    }

    /// The app model's detach changes only the index: the task leaves its family and keeps the mark.
    func testTheModelDetachesThroughTheIndex() async throws {
        let parent = task("Parent", minutesAgo: 30)
        let child = task("Child", parent: parent, minutesAgo: 10)
        let repository = InMemorySessionRepository(sessions: [parent, child])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TaskDetachTests")))
        let model = AppModel(
            store: SessionStore(sessions: [parent, child], repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in FakeHarnessAdapter(kind: .claudeCode) },
            restoresIndexOnLaunch: false)
        await model.detachFromParent(child)
        let saved = try await repository.loadSessions().first { $0.id == child.id }
        XCTAssertNil(saved?.parentTaskID)
        XCTAssertEqual(saved?.isLineageDetached, true)
        // And back under it from the row's menu or a drop.
        await model.nest(child.id, under: parent.id)
        let nested = try await repository.loadSessions().first { $0.id == child.id }
        XCTAssertEqual(nested?.parentTaskID, parent.id)
        XCTAssertNil(model.bootstrapError)
        await model.shutdown()
    }

    /// The index keeps the mark; an index from before it gains the column with every row intact and
    /// not detached; archiving and restoring keep it; a record decoded without the key is not detached.
    /// Who started a task placed flat to keep the sidebar's levels is kept the same way.
    func testTheIndexKeepsTheMarkAndAnOlderIndexGainsItsColumn() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "detach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "session-index.sqlite3")
        let parent = task("Parent", minutesAgo: 30)
        let child = task("Linked before detaching existed", parent: parent, minutesAgo: 10)
        // An index written by the build before: links, but no `lineage_detached`.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path(percentEncoded: false), &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, """
            CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, harness TEXT NOT NULL, workspace_path TEXT NOT NULL,
                runtime_path TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL,
                updated_at REAL NOT NULL, provider_session_id TEXT, archived INTEGER NOT NULL DEFAULT 0,
                parent_task_id TEXT);
            INSERT INTO sessions (id, harness, workspace_path, runtime_path, title, status, created_at, updated_at,
                provider_session_id) VALUES ('\(parent.id.uuidString)', 'claude-code', '/tmp/detach-qa/project',
                '/tmp/agent', 'Parent', 'ready', 1, 2, '\(parent.providerSessionID!)');
            INSERT INTO sessions (id, harness, workspace_path, runtime_path, title, status, created_at, updated_at,
                provider_session_id, parent_task_id) VALUES ('\(child.id.uuidString)', 'claude-code',
                '/tmp/detach-qa/project', '/tmp/agent', 'Linked before detaching existed', 'ready', 1, 3,
                '\(child.providerSessionID!)', '\(parent.id.uuidString)');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let repository = try SQLiteSessionRepository(databaseURL: database)
        let loaded = try await repository.loadSessions()
        XCTAssertEqual(Set(loaded.map(\.id)), [parent.id, child.id])
        XCTAssertEqual(loaded.first { $0.id == child.id }?.parentTaskID, parent.id, "The old link stays")
        XCTAssertTrue(loaded.allSatisfy { !$0.isLineageDetached }, "Old rows are not detached")
        XCTAssertEqual(try columns(of: database).filter { $0 == "lineage_detached" }, ["lineage_detached"])
        XCTAssertEqual(try columns(of: database).filter { $0 == "placed_started_from_task_id" },
                       ["placed_started_from_task_id"])
        XCTAssertTrue(loaded.allSatisfy { $0.placedStartedFromTaskID == nil })

        let store = SessionStore(repository: repository)
        try await store.restore()
        try await store.detachFromParent(id: child.id)
        let reopened = try await SQLiteSessionRepository(databaseURL: database).loadSessions()
        let saved = try XCTUnwrap(reopened.first { $0.id == child.id })
        XCTAssertNil(saved.parentTaskID)
        XCTAssertTrue(saved.isLineageDetached)
        XCTAssertEqual(saved.title, "Linked before detaching existed")

        // Archiving and restoring keep the mark.
        try await repository.archive(id: child.id)
        let restored = try await repository.unarchive(id: child.id)
        XCTAssertEqual(restored?.isLineageDetached, true)

        // A task the child started, placed flat under the parent.
        var flat = task("Placed flat", parent: parent, minutesAgo: 5)
        flat.isLineageDetached = true
        flat.placedStartedFromTaskID = child.id
        try await repository.upsert(flat)
        try await repository.archive(id: flat.id)
        _ = try await repository.unarchive(id: flat.id)
        let kept = try await SQLiteSessionRepository(databaseURL: database).loadSessions().first { $0.id == flat.id }
        XCTAssertEqual(kept?.parentTaskID, parent.id)
        XCTAssertEqual(kept?.startedFromTaskID, child.id)

        // JSON: kept with the key, not detached without it.
        let encoded = try JSONEncoder().encode(saved)
        XCTAssertTrue(try JSONDecoder().decode(SessionRecord.self, from: encoded).isLineageDetached)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "isLineageDetached")
        let withoutKey = try JSONSerialization.data(withJSONObject: object)
        XCTAssertFalse(try JSONDecoder().decode(SessionRecord.self, from: withoutKey).isLineageDetached)
        let flatEncoded = try JSONEncoder().encode(try XCTUnwrap(kept))
        XCTAssertEqual(try JSONDecoder().decode(SessionRecord.self, from: flatEncoded).startedFromTaskID, child.id)
        var flatObject = try XCTUnwrap(JSONSerialization.jsonObject(with: flatEncoded) as? [String: Any])
        flatObject.removeValue(forKey: "placedStartedFromTaskID")
        XCTAssertNil(try JSONDecoder().decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: flatObject))
            .placedStartedFromTaskID)

        // An index that gained either of the two latest columns first gains the other, keeping what the first holds.
        for (column, value) in [("previous_titles", #"["Draft"]"#), ("placed_started_from_task_id", child.id.uuidString)] {
            let partial = directory.appending(path: "partial-\(column).sqlite3")
            XCTAssertEqual(sqlite3_open(partial.path(percentEncoded: false), &handle), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(handle, """
                CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, harness TEXT NOT NULL, workspace_path TEXT NOT NULL,
                    runtime_path TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL,
                    updated_at REAL NOT NULL, provider_session_id TEXT, archived INTEGER NOT NULL DEFAULT 0,
                    parent_task_id TEXT, lineage_detached INTEGER NOT NULL DEFAULT 0, \(column) TEXT);
                INSERT INTO sessions (id, harness, workspace_path, runtime_path, title, status, created_at, updated_at,
                    parent_task_id, lineage_detached, \(column)) VALUES ('\(flat.id.uuidString)', 'claude-code',
                    '/tmp/detach-qa/project', '/tmp/agent', 'Placed flat', 'ready', 1, 2, '\(parent.id.uuidString)', 1,
                    '\(value)');
                """, nil, nil, nil), SQLITE_OK)
            sqlite3_close(handle)
            let upgraded = try await SQLiteSessionRepository(databaseURL: partial).loadSessions()
            let row = try XCTUnwrap(upgraded.first)
            XCTAssertEqual(row.previousTitles, column == "previous_titles" ? ["Draft"] : [], column)
            XCTAssertEqual(row.startedFromTaskID, column == "previous_titles" ? nil : child.id, column)
            XCTAssertEqual(Set(try columns(of: partial)).intersection(["previous_titles", "placed_started_from_task_id"]),
                           ["previous_titles", "placed_started_from_task_id"], column)
        }
    }

    private func columns(of database: URL) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path(percentEncoded: false), &handle) == SQLITE_OK else { return [] }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(sessions);", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            names.append(String(cString: sqlite3_column_text(statement, 1)))
        }
        return names
    }
}
