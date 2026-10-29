import CSQLite
import XCTest
@testable import NativeHarnessClient

/// Tasks started from another task (`SessionRecord.parentTaskID`): one link for every harness, kept
/// in the index, and the sidebar nesting each family under its first task, each task a level in from
/// the task it was started from.
@MainActor
final class TaskLineageTests: XCTestCase {
    private let folder = URL(filePath: "/tmp/lineage-qa/project", directoryHint: .isDirectory)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(
        _ title: String, harness: HarnessKind = .claudeCode, parent: SessionRecord? = nil, minutesAgo: Double,
        status: SessionStatus = .ready, unread: Bool = false, pinned: Bool = false, in workspace: URL? = nil
    ) -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: workspace ?? folder, runtimeExecutableURL: URL(filePath: "/tmp/agent"),
                      title: title, titleOrigin: .provider, status: status,
                      updatedAt: clock.addingTimeInterval(-minutesAgo * 60), providerSessionID: UUID().uuidString.lowercased(),
                      hasUnreadUpdate: unread, isPinned: pinned, parentTaskID: parent?.id)
    }

    private func rows(_ sessions: [SessionRecord]) -> [SidebarRow] {
        sessions.map { SidebarRow(content: .session($0)) }
    }

    /// Each title indented two spaces per level it is nested.
    private func titles(_ rows: [SidebarRow]) -> [String] {
        rows.flatMap(\.rowsWithChildren).map { String(repeating: "  ", count: $0.familyPlace?.depth ?? 0) + $0.title }
    }

    // MARK: - Nesting

    /// Every descendant sits under the family's first task, depth first along who started whom,
    /// newest first, each a level in from the task it was started from down to `deepestNesting`,
    /// where deeper tasks stay; the family sits where its newest member would. The guide's lines run
    /// on past a row at each level a later row continues.
    func testAFamilyNestsEachTaskALevelInFromTheTaskItWasStartedFrom() {
        let root = task("Plan the release", minutesAgo: 50)
        let older = task("Write the notes", parent: root, minutesAgo: 40)
        let newer = task("Tag the build", parent: root, minutesAgo: 5)
        let grandchild = task("Check the tag", parent: newer, minutesAgo: 30)
        let greatGrandchild = task("Read the signature", parent: grandchild, minutesAgo: 35)
        let alone = task("Tidy the README", minutesAgo: 10)
        let nested = SidebarProjection.nest(rows([root, older, newer, grandchild, greatGrandchild, alone]))
        XCTAssertEqual(SidebarProjection.deepestNesting, 2)
        XCTAssertEqual(titles(nested), ["Plan the release", "  Tag the build", "    Check the tag",
                                        "    Read the signature", "  Write the notes", "Tidy the README"])
        XCTAssertEqual(nested[0].children.map(\.familyPlace?.continuingLevels), [[1], [1, 2], [1], []])
        XCTAssertEqual(nested.first?.sortDate, newer.updatedAt, "The family sorts by its newest member")
        XCTAssertEqual(nested.first?.familySessions.map(\.id), [root.id, newer.id, grandchild.id, greatGrandchild.id,
                                                                older.id])
        XCTAssertTrue(nested[0].children.allSatisfy(\.isNestedChild))

        // An archived task between nests its child under the nearest task listed, a level in from it.
        let archived = task("Archived step", parent: newer, minutesAgo: 60)
        let afterArchived = task("Verify the mirror", parent: archived, minutesAgo: 45)
        let archivedRoot = task("Archived root", minutesAgo: 70)
        let underArchivedRoot = task("Left on its own", parent: archivedRoot, minutesAgo: 55)
        let throughArchive = SidebarProjection.nest(
            rows([root, newer, older, afterArchived, underArchivedRoot]),
            archivedParents: [archived.id: newer.id])
        XCTAssertEqual(titles(throughArchive), ["Plan the release", "  Tag the build", "    Verify the mirror",
                                                "  Write the notes", "Left on its own"])

        // A collapsed family keeps a waiting grandchild a level in from the nearest task shown above it.
        let collapsed = SidebarProjection.nest(rows([root, older, newer, grandchild]),
                                               collapsedKeys: [SidebarProjection.familyKey(for: root.id)],
                                               keepingShown: [grandchild.id])
        XCTAssertEqual(titles(collapsed), ["Plan the release", "  Check the tag"])
        XCTAssertEqual(collapsed[0].children.first?.familyPlace?.continuingLevels, [1],
                       "The line runs on to the count of hidden tasks")

        // The layout puts the family where its newest member is: above an older top-level task.
        let groups = [WorkspaceGroup(workspaceURL: folder, sessions: [root, older, newer, grandchild, alone])]
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false)
        XCTAssertEqual(layout.sections[0].rows.map(\.title), ["Plan the release", "Tidy the README"])
        XCTAssertEqual(layout.rows.map(\.id), [root, newer, grandchild, older, alone].map { .session($0.id) },
                       "Arrow keys and Previous/Next go through the nested tasks in order")
    }

    /// A task whose parent is not a task row of the same list stays at top level: an archived or
    /// deleted parent, one pinned apart, one in a split view, one moved to another project. A split
    /// view is never nested. A task the person moved to top level in the Claude app has no link.
    func testATaskWhoseParentIsNotListedBesideItStaysAtTopLevel() {
        let archivedParent = task("Archived parent", minutesAgo: 90)
        let orphan = task("Child of an archived task", parent: archivedParent, minutesAgo: 10)
        let pinnedParent = task("Pinned parent", minutesAgo: 20, pinned: true)
        let unpinnedChild = task("Child of a pinned task", parent: pinnedParent, minutesAgo: 15)
        let splitParent = task("Split parent", minutesAgo: 30)
        let childOfSplit = task("Child of a split member", parent: splitParent, minutesAgo: 25)
        let elsewhere = URL(filePath: "/tmp/lineage-qa/other", directoryHint: .isDirectory)
        let movedParent = task("Parent in another project", minutesAgo: 40, in: elsewhere)
        let movedChild = task("Child moved away", parent: movedParent, minutesAgo: 35)
        let detached = task("Moved to top level", minutesAgo: 5)
        let sessions = [orphan, pinnedParent, unpinnedChild, splitParent, childOfSplit, movedParent, movedChild, detached]
        let groups = [WorkspaceGroup(workspaceURL: folder, sessions: sessions.filter { $0.workspaceURL == folder }),
                      WorkspaceGroup(workspaceURL: elsewhere, sessions: [movedParent])]
        let split = SplitGroup(isPinned: false, anchorSessionID: splitParent.id,
            root: .branch(axis: .horizontal, children: [.pane(SplitPane(sessionID: splitParent.id)),
                                                        .pane(SplitPane(sessionID: task("Other pane", minutesAgo: 1).id))],
                          fractions: [1, 1]),
            focusedPaneID: UUID())
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [split], isFiltering: false)
        XCTAssertTrue(layout.rows.allSatisfy { !$0.isNestedChild }, titles(layout.pinned + layout.sections.flatMap(\.rows)).description)
        XCTAssertEqual(Set(layout.sections[0].rows.compactMap { row -> UUID? in
            if case let .session(session) = row.content { return session.id } else { return nil }
        }), [orphan.id, unpinnedChild.id, childOfSplit.id, movedChild.id, detached.id])
        XCTAssertEqual(layout.pinned.map(\.title), ["Pinned parent"])

        // A pinned child of a pinned task nests in Pinned.
        let pinnedChild = task("Pinned child", parent: pinnedParent, minutesAgo: 2, pinned: true)
        let withPinnedChild = SidebarProjection.layout(
            visibleGroups: [WorkspaceGroup(workspaceURL: folder, sessions: [pinnedParent, pinnedChild])],
            allGroups: [WorkspaceGroup(workspaceURL: folder, sessions: [pinnedParent, pinnedChild])],
            splits: [], isFiltering: false)
        XCTAssertEqual(titles(withPinnedChild.pinned), ["Pinned parent", "  Pinned child"])

        // Chats nest the same way.
        let chat = task("Chat", minutesAgo: 3), chatChild = task("Chat child", parent: chat, minutesAgo: 4)
        let chats = SidebarProjection.layout(visibleGroups: [], allGroups: [], chats: [chat, chatChild], splits: [],
                                             isFiltering: false)
        XCTAssertEqual(titles(chats.chats?.rows ?? []), ["Chat", "  Chat child"])

        // A loop, which the index refuses to record, still lists both tasks.
        var first = task("Loop A", minutesAgo: 1)
        let second = task("Loop B", parent: first, minutesAgo: 2)
        first.parentTaskID = second.id
        XCTAssertEqual(Set(SidebarProjection.nest(rows([first, second])).flatMap(\.rowsWithChildren).map(\.title)),
                       ["Loop A", "Loop B"])
    }

    /// Collapsing a family hides its nested tasks but those waiting on the person and the one the
    /// window shows; the family row keeps the rest to count. A search shows every match expanded.
    func testACollapsedFamilyKeepsWaitingAndShownTasksAndCountsTheRest() {
        let root = task("Coordinate the migration", minutesAgo: 60)
        let waiting = task("Approve the schema", parent: root, minutesAgo: 10, status: .waitingForApproval)
        let shown = task("Read the logs", parent: root, minutesAgo: 20)
        let failed = task("Run the backfill", parent: root, minutesAgo: 30, status: .failed, unread: true)
        let working = task("Rebuild the index", parent: root, minutesAgo: 40, status: .running)
        let groups = [WorkspaceGroup(workspaceURL: folder, sessions: [root, waiting, shown, failed, working])]
        let collapsed = SidebarDisclosure(collapsedKeys: [SidebarProjection.familyKey(for: root.id)])
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false,
                                              disclosure: collapsed, selection: .session(shown.id), waiting: [waiting.id])
        let family = layout.sections[0].rows[0]
        XCTAssertEqual(family.children.map(\.title), ["Approve the schema", "Read the logs"])
        XCTAssertEqual(family.hiddenChildren.map(\.title), ["Run the backfill", "Rebuild the index"])
        XCTAssertEqual(layout.rows.map(\.id), [root, waiting, shown].map { .session($0.id) })
        XCTAssertEqual(SidebarProjection.section(holding: .session(failed.id), in: layout)?.id, folder,
                       "A hidden nested task still belongs to its project")
        XCTAssertEqual(layout.sections[0].allRows.flatMap(\.familySessions).count, 5,
                       "A collapsed project summarizes every nested task")

        let counts = SidebarFamilySummaryLine.counts(of: family.hiddenChildren)
        XCTAssertEqual(counts, .init(sessions: 2, failed: 1, new: 1, working: 1))
        XCTAssertEqual(SidebarFamilySummaryLine.sessionsText(2, more: true), L10n.format("%lld more nested sessions", 2))
        XCTAssertEqual(SidebarFamilySummaryLine.sessionsText(1, more: false), L10n.string("1 nested session"))
        XCTAssertEqual(SidebarFamilySummaryLine.accessibilityLabel(counts, more: true),
                       L10n.format("Show %@, %@", L10n.format("%lld more nested sessions", 2), L10n.format("%lld new", 1)))

        // Expanded again, or searched: everything nested shows.
        let expanded = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false)
        XCTAssertEqual(expanded.sections[0].rows[0].children.count, 4)
        XCTAssertTrue(expanded.sections[0].rows[0].hiddenChildren.isEmpty)
        let searched = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: true,
                                                disclosure: collapsed)
        XCTAssertEqual(searched.sections[0].rows[0].children.count, 4)
        // A search that matches only a nested task lists it on its own.
        let onlyChild = [WorkspaceGroup(workspaceURL: folder, sessions: [working])]
        let matched = SidebarProjection.layout(visibleGroups: onlyChild, allGroups: groups, splits: [], isFiltering: true)
        XCTAssertEqual(titles(matched.sections[0].rows), ["Rebuild the index"])

        // The menu item names the action in the Claude app's words.
        XCTAssertEqual(SidebarFamilyToggle(isCollapsed: false, action: {}).title, L10n.string("Hide nested sessions"))
        XCTAssertEqual(SidebarFamilyToggle(isCollapsed: true, action: {}).title, L10n.string("Show nested sessions"))
    }

    /// "Show more" counts a family as one row, and keeps the shown task's family listed.
    func testTheRowLimitCountsAFamilyAsOneRow() {
        let parent = task("Parent", minutesAgo: 1)
        var sessions = [parent] + (0..<4).map { task("Child \($0)", parent: parent, minutesAgo: 2 + Double($0)) }
        sessions += (0..<6).map { task("Task \($0)", minutesAgo: 10 + Double($0)) }
        let late = task("Late parent", minutesAgo: 100)
        let lateChild = task("Late child", parent: late, minutesAgo: 101)
        sessions += [late, lateChild]
        let groups = [WorkspaceGroup(workspaceURL: folder, sessions: sessions)]
        let disclosure = SidebarDisclosure(rowLimit: SidebarDisclosure.codexRowLimit)
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false,
                                              disclosure: disclosure)
        XCTAssertEqual(layout.sections[0].rows.count, 5)
        XCTAssertEqual(layout.sections[0].rows[0].children.count, 4)
        XCTAssertEqual(layout.sections[0].hiddenRowCount, 3)
        let selected = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false,
                                                disclosure: disclosure, selection: .session(lateChild.id))
        XCTAssertEqual(selected.sections[0].rows.last?.title, "Late parent")
        XCTAssertTrue(selected.rows.contains { $0.id == .session(lateChild.id) })
    }

    // MARK: - The link in the index

    func testTheIndexKeepsTheLinkAndAnOlderIndexGainsItsColumn() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "lineage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "session-index.sqlite3")
        // An index written before the column existed, with one task in it.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path(percentEncoded: false), &handle), SQLITE_OK)
        let old = task("Written before links", minutesAgo: 5)
        XCTAssertEqual(sqlite3_exec(handle, """
            CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, harness TEXT NOT NULL, workspace_path TEXT NOT NULL,
                runtime_path TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL,
                updated_at REAL NOT NULL, provider_session_id TEXT, archived INTEGER NOT NULL DEFAULT 0);
            INSERT INTO sessions (id, harness, workspace_path, runtime_path, title, status, created_at, updated_at,
                provider_session_id) VALUES ('\(old.id.uuidString)', 'claude-code', '/tmp/lineage-qa/project', '/tmp/agent',
                'Written before links', 'ready', 1, 2, '\(old.providerSessionID ?? "")');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let repository = try SQLiteSessionRepository(databaseURL: database)
        let loaded = try await repository.loadSessions()
        XCTAssertEqual(loaded.map(\.id), [old.id])
        XCTAssertNil(loaded.first?.parentTaskID, "A task from before links is at top level")

        let child = task("Started from it", parent: old, minutesAgo: 1)
        try await repository.upsert(child)
        let store = SessionStore(repository: repository)
        try await store.restore()
        XCTAssertEqual(store.sessions.first { $0.id == child.id }?.parentTaskID, old.id)

        // Archiving and restoring keep the link, and a store read again knows an archived task's parent.
        try await repository.archive(id: child.id)
        try await store.restore()
        XCTAssertEqual(store.archivedParentIDs, [child.id: old.id])
        let restored = try await repository.unarchive(id: child.id)
        XCTAssertEqual(restored?.parentTaskID, old.id)

        // A record decoded from JSON without the key reads as top level; with it, keeps it.
        let encoded = try JSONEncoder().encode(child)
        XCTAssertEqual(try JSONDecoder().decode(SessionRecord.self, from: encoded).parentTaskID, old.id)
        XCTAssertNil(SessionRecord(id: child.id, harness: .codex, workspaceURL: folder, runtimeExecutableURL: folder,
                                   title: "Self", parentTaskID: child.id).parentTaskID, "A task is not its own parent")
    }

    /// Linking fills only a missing link, never replaces one, never makes a loop and is not
    /// activity: the task keeps its place.
    func testLinkingFillsOnlyMissingLinksWithoutLoopsOrRecency() async throws {
        let parent = task("Parent", minutesAgo: 30)
        let child = task("Child", minutesAgo: 20)
        let other = task("Other", minutesAgo: 10)
        let store = SessionStore(sessions: [parent, child, other])
        let first = try await store.linkParents([child.id: parent.id])
        XCTAssertEqual(first, [child.id])
        let again = try await store.linkParents([child.id: other.id, parent.id: child.id, other.id: other.id])
        XCTAssertEqual(again, [], "An existing link stays; a loop and a self-link are refused")
        XCTAssertEqual(store.sessions.first { $0.id == child.id }?.parentTaskID, parent.id)
        XCTAssertNil(store.sessions.first { $0.id == parent.id }?.parentTaskID)
        XCTAssertEqual(store.sessions.map(\.updatedAt), [parent, child, other].map(\.updatedAt))
    }

    // MARK: - Every harness

    /// The link resolves by harness and provider session ID, so every harness links the same way.
    func testLinksResolveByHarnessAndProviderSessionForEveryHarness() {
        for harness in HarnessCatalog.builtIns.map(\.id) {
            let parent = task("Parent", harness: harness, minutesAgo: 2)
            let child = task("Child", harness: harness, minutesAgo: 1)
            let foreign = task("Same ID, other harness", harness: harness == .codex ? .claudeCode : .codex, minutesAgo: 3)
            let links = TaskLineage.links(parents: [child.providerSessionID!.uppercased(): parent.providerSessionID!],
                                          harness: harness, sessions: [parent, child, foreign])
            XCTAssertEqual(links, [child.id: parent.id], harness.rawValue)
            XCTAssertNil(TaskLineage.task(continuing: parent.providerSessionID, harness: harness == .codex ? .claudeCode : .codex,
                                          among: [parent]), harness.rawValue)
        }
        XCTAssertEqual(TaskLineage.codexParentThreadID(forkedFromID: " ", parentThreadID: "parent"), "parent")
        XCTAssertEqual(TaskLineage.codexParentThreadID(forkedFromID: "fork", parentThreadID: "parent"), "fork")
        XCTAssertNil(TaskLineage.codexParentThreadID(forkedFromID: nil, parentThreadID: nil))
        let summary = CodexThreadSummary(id: "t-child", title: "Child", preview: "", workspaceURL: folder,
                                         updatedAt: clock, forkedFromID: "t-parent")
        XCTAssertEqual(ImportableConversation(codex: summary).parentProviderSessionID, "t-parent")
    }

    /// A Codex task whose thread names the thread it was forked from, or the one whose subagent it is,
    /// is linked to the task continuing that thread when its thread is read.
    func testACodexThreadReadLinksItsTaskToTheTaskOfItsParentThread() async throws {
        let parent = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                   title: "Parent", providerSessionID: "thread-parent")
        let fork = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                 title: "Fork", providerSessionID: "thread-fork")
        let subagent = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                     title: "Subagent", providerSessionID: "thread-subagent")
        func state(_ id: String, _ fields: [String: JSONValue]) -> CodexTaskState {
            var state = CodexTaskState.empty
            XCTAssertTrue(CodexTaskReducer().applySnapshot(.object(["id": .string(id), "turns": .array([])]
                .merging(fields) { _, new in new }), to: &state))
            return state
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests")))
        let model = AppModel(
            store: SessionStore(sessions: [parent, fork, subagent],
                                repository: InMemorySessionRepository(sessions: [parent, fork, subagent])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in FakeHarnessAdapter(kind: .codex) },
            initialCodexPresentation: [
                fork.id: state("thread-fork", ["forkedFromId": .string("thread-parent")]),
                subagent.id: state("thread-subagent", ["parentThreadId": .string("thread-parent")]),
                parent.id: state("thread-parent", [:]),
            ],
            restoresIndexOnLaunch: false)
        try await waitUntil {
            !model.store.sessions.contains(where: { $0.id != parent.id && $0.parentTaskID == nil })
        }
        XCTAssertEqual(model.store.sessions.first { $0.id == fork.id }?.parentTaskID, parent.id)
        XCTAssertEqual(model.store.sessions.first { $0.id == subagent.id }?.parentTaskID, parent.id)
        XCTAssertNil(model.store.sessions.first { $0.id == parent.id }?.parentTaskID)
        await model.shutdown()
    }

    /// The marks read the same task state for every harness: approvals and questions, a running turn,
    /// a failure, a plan limit and an unread result come from the shared record and transcript.
    func testEveryHarnessMapsToTheSameMarks() {
        let limit = HarnessRateLimit(status: .rejected, window: .session)
        for harness in HarnessCatalog.builtIns.map(\.id) {
            func mark(_ status: SessionStatus, unread: Bool = false, completion: SessionCompletionState = .none,
                      _ entries: [TranscriptEntry] = []) -> SidebarTaskStatus? {
                let session = SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: folder,
                                            title: "Task", status: status, hasUnreadUpdate: unread,
                                            completionState: completion)
                return SidebarTaskIndicatorProjection.status(of: session, detail: TaskAttentionDetail.reading(entries))
            }
            let approval = PermissionRequest(id: "p", title: "Run tests", detail: nil, command: "swift test")
            XCTAssertEqual(mark(.waitingForApproval, [TranscriptEntry(content: .permission(approval, state: .pending))]),
                           .awaitingApproval, harness.rawValue)
            let question = PermissionRequest(id: "q", title: "Pick one", detail: nil, command: nil, structured: .questions([
                PermissionQuestion(question: "Which icon set?", options: [PermissionQuestionOption(label: "Line")])]))
            XCTAssertEqual(mark(.waitingForApproval, [TranscriptEntry(content: .permission(question, state: .pending))]),
                           .needsInput, harness.rawValue)
            XCTAssertEqual(mark(.running), .running, harness.rawValue)
            XCTAssertEqual(mark(.failed, completion: .failed, [TranscriptEntry(content: .error(message: "Stream closed", recoverable: false))]),
                           .failed(message: "Stream closed"), harness.rawValue)
            XCTAssertEqual(mark(.completed, completion: .completed, [TranscriptEntry(content: .usageLimit(limit))]),
                           .usageLimit(limit), harness.rawValue)
            XCTAssertEqual(mark(.completed, unread: true, completion: .completed), .unread, harness.rawValue)
            XCTAssertNil(mark(.ready), harness.rawValue)
        }
    }
}
