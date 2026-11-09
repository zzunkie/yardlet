import Foundation
import Observation
import XCTest
@testable import NativeHarnessClient

final class TaskNavigationProjectionTests: XCTestCase {
    func testGroupingSortsSessionsAndSearchPreservesProjectIdentity() {
        let firstWorkspace = URL(filePath: "/tmp/project-a")
        let secondWorkspace = URL(filePath: "/tmp/project-b")
        let sessions = [
            SessionRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                harness: .claudeCode,
                workspaceURL: firstWorkspace,
                runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                title: "Review permissions",
                status: .waitingForApproval,
                updatedAt: Date(timeIntervalSince1970: 20)
            ),
            SessionRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!,
                harness: .codex,
                workspaceURL: firstWorkspace,
                runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                title: "Build the shell",
                status: .running,
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            SessionRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!,
                harness: .pi,
                workspaceURL: secondWorkspace,
                runtimeExecutableURL: URL(filePath: "/tmp/pi"),
                title: "Release notes",
                status: .failed,
                updatedAt: Date(timeIntervalSince1970: 30)
            )
        ]

        let groups = TaskNavigationProjection.workspaceGroups(from: sessions)
        XCTAssertEqual(groups.map(\.displayName), ["project-b", "project-a"])
        XCTAssertEqual(groups.last?.sessions.map(\.title), ["Review permissions", "Build the shell"])
        XCTAssertEqual(groups.last?.sessions.map(\.status), [.waitingForApproval, .running])

        let filtered = TaskNavigationProjection.filteredGroups(from: sessions, query: "shell")
        XCTAssertEqual(filtered.map(\.displayName), ["project-a"])
        XCTAssertEqual(filtered.first?.sessions.map(\.title), ["Build the shell"])
    }

    func testPinnedSessionsMoveToGlobalSectionWithoutProjectDuplication() {
        let firstWorkspace = URL(filePath: "/tmp/pinned-project-a")
        let secondWorkspace = URL(filePath: "/tmp/pinned-project-b")
        let olderPinned = SessionRecord(
            harness: .codex,
            workspaceURL: firstWorkspace,
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Older pinned",
            updatedAt: Date(timeIntervalSince1970: 10),
            isPinned: true
        )
        let unpinned = SessionRecord(
            harness: .claudeCode,
            workspaceURL: firstWorkspace,
            runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Unpinned",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let newerPinned = SessionRecord(
            harness: .pi,
            workspaceURL: secondWorkspace,
            runtimeExecutableURL: URL(filePath: "/tmp/pi"),
            title: "Newer pinned",
            updatedAt: Date(timeIntervalSince1970: 30),
            isPinned: true
        )

        let groups = TaskNavigationProjection.workspaceGroups(
            from: [olderPinned, unpinned, newerPinned]
        )
        let pinned = TaskNavigationProjection.pinnedSessions(in: groups)
        let projects = TaskNavigationProjection.unpinnedWorkspaceGroups(in: groups)

        XCTAssertEqual(pinned.map(\.title), ["Newer pinned", "Older pinned"])
        XCTAssertEqual(projects.map(\.displayName), ["pinned-project-b", "pinned-project-a"])
        XCTAssertTrue(projects[0].sessions.isEmpty)
        XCTAssertEqual(projects[1].sessions.map(\.title), ["Unpinned"])
        XCTAssertEqual(
            TaskNavigationProjection.flattenedSessionIDs(in: groups),
            [newerPinned.id, olderPinned.id, unpinned.id]
        )
    }

    func testEmptyAndWhitespaceSearchReturnAllGroupsWithoutProviderWork() {
        let session = SessionRecord(
            harness: .openCode,
            workspaceURL: URL(filePath: "/tmp/project"),
            runtimeExecutableURL: URL(filePath: "/tmp/opencode"),
            title: "ACP task"
        )
        let empty = TaskNavigationProjection.filteredGroups(from: [session], query: " ")
        XCTAssertEqual(empty.count, 1)
        XCTAssertEqual(empty.first?.sessions.first?.id, session.id)
    }

    func testKeyboardNavigationFollowsVisibleOrderAndWraps() {
        let first = SessionRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/keyboard-a"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "First"
        )
        let second = SessionRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
            harness: .claudeCode,
            workspaceURL: URL(filePath: "/tmp/keyboard-a"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Second"
        )
        let group = WorkspaceGroup(workspaceURL: first.workspaceURL, sessions: [first, second])

        XCTAssertEqual(
            TaskNavigationProjection.targetSessionID(
                in: [group], selectedID: first.id, offset: 1
            ),
            second.id
        )
        XCTAssertEqual(
            TaskNavigationProjection.targetSessionID(
                in: [group], selectedID: second.id, offset: 1
            ),
            first.id
        )
        XCTAssertEqual(
            TaskNavigationProjection.targetSessionID(
                in: [group], selectedID: nil, offset: -1
            ),
            second.id
        )
    }

    func testKeyboardNavigationTraversesPinnedSectionBeforeProjects() {
        let workspace = URL(filePath: "/tmp/keyboard-pinned")
        let projectTask = SessionRecord(
            harness: .codex,
            workspaceURL: workspace,
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Project task",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let pinnedTask = SessionRecord(
            harness: .codex,
            workspaceURL: workspace,
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Pinned task",
            updatedAt: Date(timeIntervalSince1970: 10),
            isPinned: true
        )
        let groups = TaskNavigationProjection.workspaceGroups(from: [projectTask, pinnedTask])

        XCTAssertEqual(
            TaskNavigationProjection.targetSessionID(
                in: groups,
                selectedID: nil,
                offset: 1
            ),
            pinnedTask.id
        )
        XCTAssertEqual(
            TaskNavigationProjection.targetSessionID(
                in: groups,
                selectedID: pinnedTask.id,
                offset: 1
            ),
            projectTask.id
        )
    }

    func testKeyboardNavigationFailsClosedForEmptyGroupsOrZeroOffset() {
        XCTAssertNil(
            TaskNavigationProjection.targetSessionID(
                in: [], selectedID: nil, offset: 1
            )
        )
        XCTAssertNil(
            TaskNavigationProjection.targetSessionID(
                in: [], selectedID: nil, offset: 0
            )
        )
    }

    func testSearchMatchesHydratedTranscriptOccurrencesWithoutProviderWork() {
        let session = SessionRecord(
            harness: .codex,
            workspaceURL: URL(filePath: "/tmp/transcript-search"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Untitled task"
        )
        let transcripts: [UUID: [TranscriptEntry]] = [
            session.id: [
                TranscriptEntry(content: .user(text: "Please inspect the approval boundary.")),
                TranscriptEntry(content: .activity(
                    HarnessActivity(
                        id: "activity-1",
                        kind: "command",
                        title: "swift test",
                        detail: "command finished"
                    ),
                    state: .completed
                ))
            ]
        ]

        let filtered = TaskNavigationProjection.filteredGroups(
            from: [session],
            query: "approval",
            transcripts: transcripts
        )

        XCTAssertEqual(filtered.flatMap(\.sessions).map(\.id), [session.id])
    }

    func testSearchIncludesTypedCodexAndCommonHistoryInTheSameResults() throws {
        let fixture = try XCTUnwrap(VisualFixtureScenario.requested(arguments: ["--ui-fixture=workspace"]))
        for query in ["  REQUEST 49\n", "response 49", "한글 👩🏽‍💻"] {
            let groups = TaskNavigationProjection.filteredGroups(
                from: fixture.sessions, query: query,
                transcripts: fixture.transcripts, codexPresentation: fixture.codexPresentation
            )
            XCTAssertEqual(Set(groups.flatMap(\.sessions).map(\.harness)), [.codex, .claudeCode], query)
        }
    }

    func testTypedSearchUsesOnlyTheMatchingTasksLoadedItems() throws {
        let fixture = try XCTUnwrap(VisualFixtureScenario.requested(arguments: ["--ui-fixture=workspace"]))
        for query in ["without losing your place", "Sources/File49.swift", "Request 60"] {
            let groups = TaskNavigationProjection.filteredGroups(
                from: fixture.sessions, query: query,
                transcripts: fixture.transcripts, codexPresentation: fixture.codexPresentation
            )
            XCTAssertEqual(groups.flatMap(\.sessions).map(\.harness), [.codex], query)
        }
        XCTAssertTrue(TaskNavigationProjection.filteredGroups(
            from: fixture.sessions, query: "Request 61",
            transcripts: fixture.transcripts, codexPresentation: fixture.codexPresentation
        ).isEmpty)
        XCTAssertTrue(TaskNavigationProjection.filteredGroups(
            from: fixture.sessions, query: "Request 60"
        ).isEmpty)
    }

    /// The sidebar search's memo searches a task again from what its change did not keep, and tells its
    /// reader only when the task comes to match or stops matching, as a task streams.
    @MainActor
    func testConversationSearchFollowsChangesAndTellsOnlyWhenAMatchComesOrGoes() {
        final class Told: @unchecked Sendable { var count = 0 }
        let id = UUID(), told = Told()
        var conversation = ConversationSearchMemo.Conversation(transcript: LongConversationFixture.claude(turns: 40))
        let memo = ConversationSearchMemo { _ in conversation }
        func matches() -> Bool { memo.matches(id, query: "ledger") }
        /// Reads the answers as the window does, until one changes.
        func observe() { withObservationTracking { _ = matches() } onChange: { told.count += 1 } }
        func stream(_ text: String, kept: Int? = nil) {
            var entries = conversation.transcript ?? []
            entries[entries.count - 1] = TranscriptEntry(content: .assistant(text: text, isStreaming: true))
            conversation.transcript = entries
            memo.transcriptChanged(id, change: TranscriptChange(dropped: 0, kept: kept ?? entries.count - 1))
        }
        XCTAssertFalse(matches())
        observe()
        stream("Still reading")
        XCTAssertEqual(told.count, 0, "A change that matches nothing tells nothing")
        stream("The ledger is balanced")
        XCTAssertEqual(told.count, 1)
        XCTAssertTrue(matches())
        observe()
        stream("The ledger is balanced", kept: 5)
        XCTAssertTrue(matches(), "Searched again from the first entry the change did not keep")
        XCTAssertEqual(told.count, 1)
        conversation.transcript = Array(conversation.transcript!.prefix(10))
        memo.transcriptChanged(id, change: .unknown)
        XCTAssertEqual(told.count, 2)
        XCTAssertFalse(matches())
        observe()

        let turns = (0..<20).map { LongConversationFixture.codexTurn($0) }
        conversation.codex = LongConversationFixture.codex(threadID: "thread-search", turns: turns)
        memo.codexStateChanged(id)
        XCTAssertEqual(told.count, 2)
        conversation.codex = LongConversationFixture.codex(
            threadID: "thread-search", turns: turns.dropLast() + [LongConversationFixture.codexTurn(19, tag: "ledger ")])
        memo.codexStateChanged(id)
        XCTAssertEqual(told.count, 3, "The newest turn came to hold the search")
        XCTAssertTrue(matches())
        observe()
        conversation.codex = LongConversationFixture.codex(
            threadID: "thread-search", turns: [LongConversationFixture.codexTurn(0, tag: "edited ")] + turns.dropFirst())
        memo.codexStateChanged(id)
        XCTAssertEqual(told.count, 4, "The turn that held it went")
        XCTAssertFalse(matches())
    }

    func testRenamedProjectSearchRetainsItsTasksAndWorkspaceIdentity() throws {
        let fixture = try XCTUnwrap(VisualFixtureScenario.requested(arguments: ["--ui-fixture=task-search"]))
        let workspace = try XCTUnwrap(fixture.sessions.first?.workspaceURL)
        let names = [workspace: "Client 검수 프로젝트"]
        let groups = TaskNavigationProjection.filteredGroups(
            from: fixture.sessions, query: "  CLIENT 검수\n", projectNames: names
        )
        XCTAssertEqual(groups.map(\.workspaceURL), [workspace])
        XCTAssertEqual(Set(groups.flatMap(\.sessions).map(\.id)),
                       Set(fixture.sessions.filter { $0.workspaceURL == workspace }.map(\.id)))
        XCTAssertEqual(TaskNavigationProjection.pinnedSessions(in: groups).count, 2)
        XCTAssertTrue(TaskNavigationProjection.filteredGroups(
            from: fixture.sessions, query: "Client 검수", projectNames: [workspace: "Renamed again"]
        ).isEmpty)
    }
}
