import XCTest
@testable import NativeHarnessClient

@MainActor
final class SplitLayoutTests: XCTestCase {
    // MARK: - Split tree

    func testSplittingAlongTheSameAxisAddsASiblingAndAcrossTheAxisNests() throws {
        let a = SplitPane(), b = SplitPane(), c = SplitPane(), d = SplitPane()
        var root = SplitNode.pane(a)
        root = root.splitting(a.id, direction: .right, with: b)
        root = root.splitting(b.id, direction: .right, with: c)
        guard case let .branch(axis, children, fractions) = root else { return XCTFail("expected a branch") }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children.count, 3)
        XCTAssertEqual(fractions, [0.5, 0.25, 0.25])

        root = root.splitting(c.id, direction: .down, with: d)
        guard case let .branch(_, nested, _) = root, case let .branch(innerAxis, inner, innerFractions) = nested[2] else {
            return XCTFail("expected the third column to stack")
        }
        XCTAssertEqual(innerAxis, .vertical)
        XCTAssertEqual(inner.flatMap(\.panes).map(\.id), [c.id, d.id])
        XCTAssertEqual(innerFractions, [0.5, 0.5])
        XCTAssertEqual(root.panes.map(\.id), [a.id, b.id, c.id, d.id])

        let left = SplitPane()
        let prepended = SplitNode.pane(a).splitting(a.id, direction: .left, with: left)
        XCTAssertEqual(prepended.panes.map(\.id), [left.id, a.id])
    }

    func testClosingAPaneCollapsesLoneChildrenAndMergesSameAxisBranches() throws {
        let a = SplitPane(), b = SplitPane(), c = SplitPane(), d = SplitPane()
        let root = SplitNode.branch(axis: .horizontal, children: [
            .pane(a),
            .branch(axis: .vertical, children: [
                .pane(b),
                .branch(axis: .horizontal, children: [.pane(c), .pane(d)], fractions: [0.5, 0.5])
            ], fractions: [0.5, 0.5])
        ], fractions: [0.5, 0.5])

        let removed = try XCTUnwrap(root.removing(b.id))
        guard case let .branch(axis, children, fractions) = removed else { return XCTFail("expected a branch") }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children.flatMap(\.panes).map(\.id), [a.id, c.id, d.id])
        XCTAssertEqual(fractions, [0.5, 0.25, 0.25])

        let single = try XCTUnwrap(SplitNode.branch(axis: .vertical, children: [.pane(a), .pane(b)], fractions: [0.5, 0.5]).removing(b.id))
        XCTAssertEqual(single, .pane(a))
        XCTAssertNil(SplitNode.pane(a).removing(a.id))
    }

    func testFocusMovesToTheNearestPaneInTheRequestedDirection() {
        var split = SplitGroup(root: .pane(SplitPane(sessionID: UUID())))
        let left = split.focusedPaneID
        let topRight = split.split(.right)
        let bottomRight = split.split(.down)

        XCTAssertTrue(split.focus(paneID: left))
        XCTAssertTrue(split.moveFocus(.right))
        XCTAssertEqual(split.focusedPaneID, topRight)
        XCTAssertTrue(split.moveFocus(.down))
        XCTAssertEqual(split.focusedPaneID, bottomRight)
        XCTAssertFalse(split.moveFocus(.right))
        XCTAssertTrue(split.moveFocus(.left))
        XCTAssertEqual(split.focusedPaneID, left)
        XCTAssertFalse(split.moveFocus(.up))
    }

    func testOneSessionLivesInOnePaneAndDecodingRepairsTheTree() throws {
        let session = UUID()
        var split = SplitGroup(root: .pane(SplitPane(sessionID: session)))
        let second = split.split(.right)
        split.place(session, in: second)
        XCTAssertEqual(split.sessionIDs, [session])
        XCTAssertEqual(split.pane(hosting: session)?.id, second)

        let paneID = UUID()
        let json = """
        {"id":"\(UUID().uuidString)","root":{"kind":"branch","axis":"horizontal","fractions":[3],
        "children":[{"kind":"pane","id":"\(paneID.uuidString)","sessionID":"\(session.uuidString)"},
        {"kind":"pane","id":"\(paneID.uuidString)","sessionID":"\(session.uuidString)"},
        {"kind":"branch","axis":"vertical","children":[],"fractions":[]}]}}
        """
        let decoded = try JSONDecoder().decode(SplitGroup.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.panes.count, 2)
        XCTAssertEqual(Set(decoded.panes.map(\.id)).count, 2)
        XCTAssertEqual(decoded.sessionIDs, [session])
        XCTAssertEqual(decoded.anchorSessionID, session)
        guard case let .branch(_, _, fractions) = decoded.root else { return XCTFail("expected a branch") }
        XCTAssertEqual(fractions, [0.5, 0.5])

        let roundTrip = try JSONDecoder().decode(SplitGroup.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(roundTrip, decoded)
    }

    func testResizingReplacesOnlyTheAddressedBranch() {
        var split = SplitGroup(root: .pane(SplitPane(sessionID: UUID())))
        split.split(.right)
        split.split(.down)
        split.resize(at: [], fractions: [0.7, 0.3])
        split.resize(at: [1], fractions: [0.25, 0.75])
        guard case let .branch(_, children, fractions) = split.root,
              case let .branch(_, _, inner) = children[1] else { return XCTFail("expected nested branches") }
        XCTAssertEqual(fractions, [0.7, 0.3])
        XCTAssertEqual(inner, [0.25, 0.75])
    }

    // MARK: - Store

    func testSplittingOneTaskMakesASplitViewWithTheTaskAndAnEmptyPane() throws {
        let store = SplitStore()
        store.adopt(selection: nil, knownSessionIDs: [], isFinal: true)
        var published: [UUID?] = []
        store.onFocusedSessionChange = { published.append($0) }
        let a = UUID()

        store.activate(.session(a))
        store.split(.right, pinned: true)

        let split = try XCTUnwrap(store.activeSplit)
        XCTAssertEqual(store.selection, .split(split.id))
        XCTAssertEqual(split.panes.map(\.sessionID), [a, nil])
        XCTAssertTrue(split.isPinned)
        XCTAssertNil(store.focusedSessionID)
        XCTAssertEqual(published, [a, nil])
    }

    func testChoosingATaskFillsTheEmptyPaneAndATaskInASplitOpensTheSplit() throws {
        let store = SplitStore()
        store.adopt(selection: nil, knownSessionIDs: [], isFinal: true)
        let a = UUID(), b = UUID(), c = UUID()
        store.activate(.session(a))
        store.split(.right)
        store.activate(.session(b))

        let split = try XCTUnwrap(store.activeSplit)
        XCTAssertEqual(split.sessionIDs, [a, b])
        XCTAssertEqual(store.focusedSessionID, b)

        store.activate(.session(c))
        XCTAssertEqual(store.selection, .session(c))
        XCTAssertEqual(store.groupedSessionIDs, [a, b])

        store.activate(.session(a))
        XCTAssertEqual(store.selection, .split(split.id))
        XCTAssertEqual(store.focusedSessionID, a)

        // The mirror from the task index does the same, without duplicating the task.
        store.focusSession(b)
        XCTAssertEqual(store.focusedSessionID, b)
        XCTAssertEqual(store.activeSplit?.panes.count, 2)
    }

    func testClosingAPaneReturnsItsTaskAndASplitLeftWithOnePaneEnds() {
        let store = SplitStore()
        store.adopt(selection: nil, knownSessionIDs: [], isFinal: true)
        let a = UUID(), b = UUID(), c = UUID()
        store.activate(.session(a))
        store.split(.right, placing: b)
        store.split(.down, placing: c)
        XCTAssertEqual(store.activeSplit?.panes.count, 3)

        store.closePane()
        XCTAssertEqual(store.activeSplit?.sessionIDs, [a, b])
        XCTAssertFalse(store.groupedSessionIDs.contains(c))

        store.closePane()
        XCTAssertTrue(store.splits.isEmpty)
        XCTAssertEqual(store.selection, .session(a))
    }

    func testDroppingTasksCombinesAddsAndKeepsEachTaskInOnePlace() throws {
        let store = SplitStore()
        store.adopt(selection: nil, knownSessionIDs: [], isFinal: true)
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()

        store.combine(b, with: a)
        let first = try XCTUnwrap(store.activeSplit)
        XCTAssertEqual(first.sessionIDs, [a, b])
        XCTAssertEqual(first.anchorSessionID, a)

        store.combine(c, with: d)
        let second = try XCTUnwrap(store.activeSplit)
        XCTAssertEqual(second.sessionIDs, [d, c])

        // Moving `a` into the second split ends the first, which is left with `b` alone.
        store.add(a, to: second.id)
        XCTAssertEqual(store.splits.map(\.id), [second.id])
        XCTAssertEqual(store.activeSplit?.sessionIDs.sorted { $0.uuidString < $1.uuidString },
                       [d, c, a].sorted { $0.uuidString < $1.uuidString })

        // Dropping on a task that is already in a split joins that split.
        store.combine(b, with: a)
        XCTAssertEqual(store.activeSplit?.sessionIDs.count, 4)

        // A drop beside a pane of the shown split lands on that side.
        let paneID = try XCTUnwrap(store.activeSplit?.pane(hosting: d)?.id)
        store.place(b, beside: paneID, direction: .left)
        let panes = try XCTUnwrap(store.activeSplit?.panes.map(\.sessionID))
        XCTAssertEqual(panes.firstIndex(of: b).map { $0 + 1 }, panes.firstIndex(of: d))
        XCTAssertEqual(store.activeSplit?.sessionIDs.count, 4)

        // A pane dragged within a split of two moves without ending it, and onto the other's middle swaps.
        let e = UUID(), f = UUID()
        store.combine(f, with: e)
        let two = try XCTUnwrap(store.activeSplit)
        XCTAssertEqual(two.panes.map(\.sessionID), [e, f])
        store.place(e, beside: try XCTUnwrap(two.pane(hosting: f)?.id), direction: .down)
        XCTAssertEqual(store.activeSplit?.id, two.id)
        guard case let .branch(axis, _, _)? = store.activeSplit?.root else { return XCTFail("The split ended") }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(store.activeSplit?.panes.map(\.sessionID), [f, e])
        store.swap(e, withPane: try XCTUnwrap(store.activeSplit?.pane(hosting: f)?.id))
        XCTAssertEqual(store.activeSplit?.panes.map(\.sessionID), [e, f])
        XCTAssertEqual(store.focusedSessionID, e)
    }

    func testRemovingATaskLeavesTheWindowOnTheSplitsRemainingPane() {
        let store = SplitStore()
        store.adopt(selection: nil, knownSessionIDs: [], isFinal: true)
        var published: [UUID?] = []
        store.onFocusedSessionChange = { published.append($0) }
        let a = UUID(), b = UUID(), single = UUID()
        store.combine(b, with: a)
        XCTAssertEqual(store.focusedSessionID, b)

        store.removeSession(b)
        XCTAssertTrue(store.splits.isEmpty)
        XCTAssertEqual(store.selection, .session(a))
        XCTAssertEqual(published.last, a)

        // A task shown on its own stays selected; the task index picks the next task itself.
        store.activate(.session(single))
        store.removeSession(single)
        XCTAssertEqual(store.selection, .session(single))
    }

    func testEndingASplitKeepsTheFocusedTaskOnScreenAndRowsCanBeRenamedAndPinned() throws {
        let store = SplitStore()
        store.adopt(selection: nil, knownSessionIDs: [], isFinal: true)
        let a = UUID(), b = UUID()
        store.combine(b, with: a)
        let split = try XCTUnwrap(store.activeSplit)

        store.rename(split.id, to: "  Review  ")
        store.togglePinned(split.id)
        XCTAssertEqual(store.splits.first?.customName, "Review")
        XCTAssertEqual(store.splits.first?.isPinned, true)
        store.rename(split.id, to: " ")
        XCTAssertNil(store.splits.first?.customName)

        store.dissolve(split.id)
        XCTAssertTrue(store.splits.isEmpty)
        XCTAssertEqual(store.selection, .session(b))
    }

    func testRestoreKeepsTheSavedSplitAndIgnoresSelectionChangesUntilReady() throws {
        let a = UUID(), b = UUID(), remembered = UUID()
        var split = SplitGroup(root: .pane(SplitPane(sessionID: a)))
        split.split(.right)
        let repository = InMemorySplitRepository(snapshot: SplitSnapshot(splits: [split], selection: .split(split.id)))
        let store = SplitStore(repository: repository)
        store.adopt(selection: nil, knownSessionIDs: [], isFinal: false)
        var published: [UUID?] = []
        store.onFocusedSessionChange = { published.append($0) }

        // Restoring the remembered task must not fill the saved split's empty pane.
        store.focusSession(remembered)
        XCTAssertEqual(store.activeSplit?.sessionIDs, [a])

        store.restore(knownSessionIDs: [a, b, remembered], fallbackSessionID: remembered)
        XCTAssertEqual(store.selection, .split(split.id))
        XCTAssertEqual(store.activeSplit?.sessionIDs, [a])
        XCTAssertEqual(published, [nil])
    }

    func testRestoreWithoutASavedItemOpensTheRememberedTaskInsideItsSplit() throws {
        let a = UUID(), b = UUID()
        var split = SplitGroup(root: .pane(SplitPane(sessionID: a)))
        split.split(.right, placing: b)
        let store = SplitStore(repository: InMemorySplitRepository(snapshot: SplitSnapshot(splits: [split])))
        store.restore(knownSessionIDs: [a, b], fallbackSessionID: a)
        XCTAssertEqual(store.selection, .split(split.id))

        let plain = SplitStore()
        plain.restore(knownSessionIDs: [a], fallbackSessionID: a)
        XCTAssertEqual(plain.selection, .session(a))
    }

    func testRestoreDropsMissingTasksAndEndsSplitsLeftWithOnePane() {
        let a = UUID(), gone = UUID()
        var split = SplitGroup(root: .pane(SplitPane(sessionID: a)))
        split.split(.right, placing: gone)
        let store = SplitStore(repository: InMemorySplitRepository(
            snapshot: SplitSnapshot(splits: [split], selection: .split(split.id))
        ))
        store.restore(knownSessionIDs: [a], fallbackSessionID: nil)
        XCTAssertTrue(store.splits.isEmpty)
        XCTAssertEqual(store.selection, .session(a))
    }

    func testSplitsSurviveAFileRoundTripAndCorruptOrFutureFilesFallBack() throws {
        let directory = temporaryDirectory()
        let repository = FileSplitRepository(fileURL: directory.appending(path: "splits.json"))
        let store = SplitStore(repository: repository)
        store.adopt(selection: nil, knownSessionIDs: [], isFinal: true)
        let a = UUID(), b = UUID()
        store.combine(b, with: a)
        store.rename(try XCTUnwrap(store.activeSplit).id, to: "Review")
        store.persistNow()

        let restored = SplitStore(repository: repository)
        XCTAssertEqual(restored.splits.first?.customName, "Review")
        XCTAssertEqual(restored.splits.first?.sessionIDs, [a, b])
        XCTAssertEqual(restored.selection, store.selection)

        try Data("not json".utf8).write(to: repository.fileURL)
        XCTAssertNil(repository.load())
        repository.save(SplitSnapshot(version: 2))
        XCTAssertNil(repository.load())
        XCTAssertTrue(SplitStore(repository: repository).splits.isEmpty)
    }

    func testTheEarlierWorkspaceGridBecomesSplitViewsAndItsFileIsKept() throws {
        let directory = temporaryDirectory()
        let desksURL = directory.appending(path: "desks.json")
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let review = UUID(), release = UUID(), focused = UUID()
        let desks = """
        {"version":1,"activeDeskID":"\(review.uuidString)","desks":[
          {"id":"\(review.uuidString)","name":"Review","focusedPaneID":"\(focused.uuidString)","panes":[
            {"id":"\(UUID().uuidString)","column":0,"row":0,"sessionID":"\(a.uuidString)"},
            {"id":"\(focused.uuidString)","column":1,"row":0,"sessionID":"\(b.uuidString)"},
            {"id":"\(UUID().uuidString)","column":1,"row":1,"sessionID":"\(c.uuidString)"}]},
          {"id":"\(release.uuidString)","name":"워크스페이스 2","focusedPaneID":"\(UUID().uuidString)","panes":[
            {"id":"\(UUID().uuidString)","column":0,"row":0,"sessionID":"\(d.uuidString)"}]}]}
        """
        try Data(desks.utf8).write(to: desksURL)
        let repository = FileSplitRepository(fileURL: directory.appending(path: "splits.json"), legacyDeskFileURL: desksURL)

        let snapshot = try XCTUnwrap(repository.load())
        XCTAssertEqual(snapshot.splits.count, 1)
        let split = try XCTUnwrap(snapshot.splits.first)
        XCTAssertEqual(split.customName, "Review")
        XCTAssertEqual(split.sessionIDs, [a, b, c])
        XCTAssertEqual(split.focusedSessionID, b)
        XCTAssertEqual(snapshot.selection, .split(split.id))
        guard case let .branch(axis, children, _) = split.root, case let .branch(inner, _, _) = children[1] else {
            return XCTFail("expected two columns with the second stacked")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(inner, .vertical)

        let store = SplitStore(repository: repository)
        store.persistNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: desksURL.path(percentEncoded: false)))
        XCTAssertEqual(try Data(contentsOf: desksURL), Data(desks.utf8))

        // A single-pane workspace only carries its task as the window's selection.
        let single = """
        {"version":1,"activeDeskID":"\(release.uuidString)","desks":[
          {"id":"\(release.uuidString)","name":"Workspace 1","panes":[{"column":0,"row":0,"sessionID":"\(d.uuidString)"}]}]}
        """
        let migrated = try XCTUnwrap(LegacyDeskMigration.snapshot(fromDesksJSON: Data(single.utf8)))
        XCTAssertTrue(migrated.splits.isEmpty)
        XCTAssertEqual(migrated.selection, .session(d))
    }

    // MARK: - Sidebar rows

    func testASplitRowSitsInItsFirstTasksProjectAndHidesItsTasks() throws {
        let projectA = URL(filePath: "/tmp/split-sidebar-a"), projectB = URL(filePath: "/tmp/split-sidebar-b")
        let now = Date()
        let a = session("A", in: projectA, updated: now.addingTimeInterval(-30))
        let b = session("B", in: projectB, updated: now)
        let c = session("C", in: projectA, updated: now.addingTimeInterval(-60))
        let pinned = session("P", in: projectB, updated: now.addingTimeInterval(-90), pinned: true)
        var split = SplitGroup(root: .pane(SplitPane(sessionID: a.id)))
        split.split(.right, placing: b.id)
        let groups = [
            WorkspaceGroup(workspaceURL: projectB, sessions: [b, pinned]),
            WorkspaceGroup(workspaceURL: projectA, sessions: [a, c])
        ]

        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [split], isFiltering: false)
        XCTAssertEqual(layout.pinned.map(\.id), [.session(pinned.id)])
        XCTAssertEqual(layout.sections.map(\.group.workspaceURL), [projectB, projectA])
        XCTAssertTrue(layout.sections[0].rows.isEmpty)
        XCTAssertEqual(layout.sections[1].rows.map(\.id), [.split(split.id), .session(c.id)])
        XCTAssertEqual(layout.sections[1].rows.first?.title, "A + B")
        XCTAssertEqual(SidebarProjection.row(for: .session(b.id), in: layout), .split(split.id))
        XCTAssertEqual(
            SidebarProjection.targetRow(in: layout, selected: .session(pinned.id), offset: 1),
            .split(split.id)
        )
        XCTAssertEqual(
            SidebarProjection.targetRow(in: layout, selected: .session(pinned.id), offset: -1),
            .session(c.id)
        )

        // A search that matches only B still shows the split, in A's project; B's project, whose
        // only match sits in that split, is not listed as an empty heading.
        let filtered = [WorkspaceGroup(workspaceURL: projectB, sessions: [b])]
        let searched = SidebarProjection.layout(visibleGroups: filtered, allGroups: groups, splits: [split], isFiltering: true)
        XCTAssertTrue(searched.pinned.isEmpty)
        XCTAssertEqual(searched.sections.map(\.group.workspaceURL), [projectA])
        XCTAssertEqual(searched.rows.map(\.id), [.split(split.id)])

        // A group can list tasks from other folders (a project's roots, a worktree's origin); the
        // split row follows the group that lists its first task.
        let worktree = session("W", in: URL(filePath: "/tmp/split-sidebar-a-worktree"), updated: now)
        var worktreeSplit = SplitGroup(root: .pane(SplitPane(sessionID: worktree.id)))
        worktreeSplit.split(.right, placing: c.id)
        let originGroups = [WorkspaceGroup(workspaceURL: projectA, sessions: [worktree, a, c])]
        let origin = SidebarProjection.layout(
            visibleGroups: originGroups, allGroups: originGroups, splits: [worktreeSplit], isFiltering: false
        )
        XCTAssertEqual(origin.sections.first?.rows.map(\.id), [.split(worktreeSplit.id), .session(a.id)])

        split.isPinned = true
        let pinnedSplit = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [split], isFiltering: false)
        XCTAssertEqual(pinnedSplit.pinned.map(\.id), [.split(split.id), .session(pinned.id)])
    }

    // MARK: - App model

    func testTwoPanesHoldDistinctSessionsWithIndependentStateWithoutProviderWake() async throws {
        let fixture = VisualFixtureScenario.conversation
        let model = fixture.makeModel()
        let approval = try XCTUnwrap(fixture.sessions.first { $0.status == .waitingForApproval })
        let other = try XCTUnwrap(fixture.sessions.first { $0.id != approval.id })

        model.splits.activate(.session(approval.id))
        model.splits.split(.right)
        model.splits.activate(.session(other.id))

        let split = try XCTUnwrap(model.splits.activeSplit)
        XCTAssertEqual(split.panes.count, 2)
        XCTAssertEqual(model.store.selectedSessionID, other.id)
        let approvalPane = try XCTUnwrap(split.pane(hosting: approval.id))
        let otherPane = try XCTUnwrap(split.pane(hosting: other.id))
        XCTAssertNotEqual(approvalPane.id, otherPane.id)
        XCTAssertEqual(split.focusedPaneID, otherPane.id)

        let approvalState = model.taskWorkspaces.state(for: approval.id)
        let otherState = model.taskWorkspaces.state(for: other.id)
        approvalState.setPanels(.init(trailingSurfaceID: "diff"))
        otherState.setPanels(.init(isTerminalPresented: true))
        XCTAssertNil(otherState.panels.trailingSurfaceID)
        XCTAssertFalse(approvalState.panels.isTerminalPresented)
        XCTAssertTrue(approvalState.keyboardFocus !== otherState.keyboardFocus)

        // Selecting the task elsewhere moves focus to its pane instead of duplicating it.
        model.store.selectedSessionID = approval.id
        XCTAssertEqual(model.splits.activeSplit?.focusedPaneID, approvalPane.id)
        XCTAssertEqual(model.splits.activeSplit?.panes.count, 2)
        XCTAssertFalse(model.isAttached(approval.id))
        await model.shutdown()
    }

    func testDeletingATaskInASplitKeepsTheWindowOnTheOtherTask() async throws {
        let fixture = VisualFixtureScenario.conversation
        let model = fixture.makeModel()
        let first = try XCTUnwrap(fixture.sessions.first)
        let second = try XCTUnwrap(fixture.sessions.dropFirst().first)
        model.splits.activate(.session(first.id))
        model.splits.split(.down, placing: second.id)
        XCTAssertEqual(model.store.selectedSessionID, second.id)

        await model.delete(second)

        XCTAssertTrue(model.splits.splits.isEmpty)
        XCTAssertEqual(model.splits.selection, .session(first.id))
        XCTAssertEqual(model.store.selectedSessionID, first.id)
        await model.shutdown()
    }

    func testDeletingTheShownTaskLeavesTheWindowOnTheHome() async throws {
        let fixture = VisualFixtureScenario.conversation
        let model = fixture.makeModel()
        let first = try XCTUnwrap(fixture.sessions.first)
        model.splits.activate(.session(first.id))

        await model.delete(first)

        XCTAssertNil(model.store.selectedSessionID, "No other task opens, nor reads as read, unchosen")
        XCTAssertEqual(model.splits.selection, .home)
        await model.shutdown()
    }

    func testASavedSplitSurvivesARelaunchThatLoadsTheTaskIndexLater() async throws {
        let workspace = URL(filePath: "/tmp/split-relaunch")
        let a = session("A", in: workspace, updated: Date())
        let b = session("B", in: workspace, updated: Date())
        var split = SplitGroup(root: .pane(SplitPane(sessionID: a.id)))
        split.split(.right, placing: b.id)
        let splits = InMemorySplitRepository(snapshot: SplitSnapshot(splits: [split], selection: .split(split.id)))
        let suite = testDefaultsSuite("Yardlet.SplitLayoutTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository(sessions: [a, b])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            transcriptRepository: FileTranscriptRepository(directoryURL: URL(filePath: "/nonexistent/transcripts")),
            splitRepository: splits,
            restoresIndexOnLaunch: true
        )
        XCTAssertTrue(model.store.sessions.isEmpty)

        await model.restoreIndex()

        XCTAssertEqual(model.splits.selection, .split(split.id))
        XCTAssertEqual(model.splits.activeSplit?.sessionIDs, [a.id, b.id])
        XCTAssertEqual(model.store.selectedSessionID, b.id)
        await model.shutdown()
        XCTAssertEqual(splits.snapshot?.splits.first?.sessionIDs, [a.id, b.id])

        // A launch whose task index could not be opened knows no tasks, so it keeps everything beside
        // the index in memory, never counts as restored (the launch work that compares saved state
        // with the tasks waits for that), and says why for the whole run.
        let failed = AppModel.storageUnavailable(CocoaError(.fileReadCorruptFile), codexEnvironmentManager: nil)
        await failed.restoreIndex()
        XCTAssertFalse(failed.hasRestoredIndex)
        XCTAssertFalse(failed.sessionListFollowIsReady)
        XCTAssertNotNil(failed.storageFailure)
        await failed.shutdown()
    }

    // MARK: - Helpers

    private func session(_ title: String, in workspace: URL, updated: Date, pinned: Bool = false) -> SessionRecord {
        SessionRecord(
            harness: .codex,
            workspaceURL: workspace,
            runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
            title: title,
            updatedAt: updated,
            isPinned: pinned
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "yardlet-split-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
