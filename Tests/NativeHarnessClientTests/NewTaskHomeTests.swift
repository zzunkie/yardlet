import Foundation
import XCTest
@testable import NativeHarnessClient

/// The new-task screen's rules: which projects it shows, in what order and with which lines, the
/// folder's rows, how many show for a window's height, that what needs the person is
/// `TaskAttentionProjection`'s, the pickers' defaults, the title, and how the keyboard moves. The
/// views are drawn in `NewTaskHomeRenderingTests`.
@MainActor
final class NewTaskHomeTests: XCTestCase {
    private static let folder = URL(filePath: "/tmp/new-task-home/yardlet")
    private static let otherFolder = URL(filePath: "/tmp/new-task-home/other")

    private func task(
        _ title: String, at time: TimeInterval, status: SessionStatus = .completed, unread: Bool = false,
        in folder: URL = folder, harness: HarnessKind = .claudeCode
    ) -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/runtime"),
                      title: title, status: status, updatedAt: Date(timeIntervalSince1970: time),
                      hasUnreadUpdate: unread)
    }

    private func pullRequest(
        _ number: Int, state: TaskPullRequest.State? = .open, checks: TaskPullRequest.Checks? = nil,
        review: TaskPullRequest.Review? = nil, source: TaskPullRequest.Source = .transcriptLink
    ) -> TaskPullRequest {
        TaskPullRequest(number: number, url: URL(string: "https://github.com/example/yardlet/pull/\(number)")!,
                        repository: nil, source: source, state: state, checks: checks, review: review)
    }

    private static let featureBranch = NewTaskFolderGitState(
        isRepository: true, branch: "feature/home", isDefaultBranch: false, uncommittedFiles: 4)

    // MARK: - In this folder

    func testFolderRowsFollowTheClaudeFirstTurnOrder() {
        let waiting = task("Approve the migration", at: 90, status: .waitingForApproval)
        let running = task("Refactor the sidebar", at: 95, status: .running)
        let failing = task("Ship the PR badge", at: 80)
        let elsewhere = task("Other project", at: 99, status: .waitingForApproval, in: Self.otherFolder)
        let prs = [failing.id: pullRequest(12, checks: .failing, source: .branch("feature/home"))]

        let rows = NewTaskHomeListsProjection.folderRows(
            folder: Self.folder, startsChat: false, isInRepository: true, startsInNewWorktree: false,
            git: Self.featureBranch, sessions: [failing, elsewhere, waiting, running], pullRequest: { prs[$0] })

        XCTAssertEqual(rows, [
            .waiting(waiting, .approval),
            .runningHere(running),
            .failingChecks(failing, branch: "feature/home"),
            .continueBranch(branch: "feature/home", uncommittedFiles: 4),
            .resume(running),
        ], "Waiting, running here, CI failed, the branch, then the most recent task no row above opens")

        XCTAssertEqual(rows[0].title, L10n.format("%@ is waiting on you", "Approve the migration"))
        XCTAssertEqual(rows[0].detail, L10n.string("needs a permission"))
        XCTAssertEqual(rows[0].action, .openTask(waiting.id))
        XCTAssertEqual(rows[1].action, .useNewWorktree)
        XCTAssertEqual(rows[2].action, .draft(
            L10n.format("Fix the failing CI checks on %@: find out why they fail and fix them.", "feature/home")))
        XCTAssertEqual(rows[3].detail, L10n.format("%lld uncommitted files", 4))
        XCTAssertEqual(rows[3].action, .draft(L10n.format("Continue the work in progress on %@: look at the uncommitted changes, tell me what state they’re in, and finish what’s started.", "feature/home")))
        XCTAssertEqual(rows[4].action, .openTask(running.id))
        XCTAssertEqual(rows[4].title, L10n.format("Resume “%@”", "Refactor the sidebar"))
        XCTAssertNil(rows[4].detail)

        // The Claude app's English words for the drafts (`y/YKKTcuel`, `WWOBi0J82E`).
        XCTAssertEqual(String(format: L10n.string("Fix the failing CI checks on %@: find out why they fail and fix them.",
                                                  languageCode: "en"), "main"),
                       "Fix the failing CI checks on main: find out why they fail and fix them.")
        XCTAssertEqual(String(format: L10n.string("%lld uncommitted files", languageCode: "en"), 4), "4 uncommitted files")

        // The Claude app's Korean words.
        XCTAssertEqual(String(format: L10n.string("%@ is waiting on you", languageCode: "ko"), "마이그레이션"), "마이그레이션 작업이 대기 중입니다")
        XCTAssertEqual(L10n.string("Another session is running here", languageCode: "ko"), "여기에서 다른 세션이 실행 중입니다")
        XCTAssertEqual(String(format: L10n.string("Fix the failing checks on %@", languageCode: "ko"), "main"), "main 브랜치에서 실패한 검사 수정")
        XCTAssertEqual(String(format: L10n.string("Continue on %@", languageCode: "ko"), "main"), "main 브랜치에서 계속하기")
        XCTAssertEqual(String(format: L10n.string("Resume “%@”", languageCode: "ko"), "작업"), "“작업” 이어서 하기")
        XCTAssertEqual(L10n.string("CI failed", languageCode: "ko"), "CI 실패")
    }

    func testFolderRowsKeepToTheirConditions() {
        let question = task("Pick a name", at: 50, status: .running)
        let details = [question.id: TaskAttentionDetail(pendingRequest: .input)]
        func rows(git: NewTaskFolderGitState = Self.featureBranch, chat: Bool = false, repository: Bool = true,
                  worktree: Bool = false, sessions: [SessionRecord], prs: [UUID: TaskPullRequest] = [:])
            -> [NewTaskFolderRow] {
            NewTaskHomeListsProjection.folderRows(
                folder: Self.folder, startsChat: chat, isInRepository: repository, startsInNewWorktree: worktree,
                git: git, sessions: sessions, details: details, pullRequest: { prs[$0] })
        }

        // A question a running Codex turn asks waits as an approval does; the turn also runs here.
        let asked = rows(sessions: [question])
        XCTAssertEqual(asked.first, .waiting(question, .input))
        XCTAssertEqual(asked.first?.detail, L10n.string("asked a question"))
        XCTAssertTrue(asked.contains(.runningHere(question)))

        XCTAssertEqual(rows(chat: true, sessions: [question]), [], "A chat has no folder")
        XCTAssertFalse(rows(worktree: true, sessions: [question]).contains(.runningHere(question)),
                       "A new worktree keeps the changes apart already")
        XCTAssertFalse(rows(repository: false, sessions: [question]).contains(.runningHere(question)),
                       "Outside Git (or a project) there is no worktree to turn on")

        let done = task("Done", at: 40)
        let main = NewTaskFolderGitState(isRepository: true, branch: "main", isDefaultBranch: true, uncommittedFiles: nil)
        XCTAssertEqual(rows(git: main, sessions: [done], prs: [done.id: pullRequest(3, checks: .failing)]),
                       [.resume(done)], "On the default branch: no work in progress, and a linked PR is not this branch's")
        XCTAssertEqual(rows(sessions: [done], prs: [done.id: pullRequest(3, checks: .failing)]).first,
                       .failingChecks(done, branch: "feature/home"), "A PR the task's conversation links, on the folder's branch")
        XCTAssertEqual(rows(sessions: [done], prs: [done.id: pullRequest(3, state: .draft, checks: .failing)]).first,
                       .failingChecks(done, branch: "feature/home"), "A draft's failing checks count too")
        for other in [pullRequest(3, checks: .failing, source: .branch("feature/other")),
                      pullRequest(3, state: .merged, checks: .failing), pullRequest(3, checks: .passing),
                      pullRequest(3, state: nil)] {
            XCTAssertFalse(rows(sessions: [done], prs: [done.id: other]).contains { if case .failingChecks = $0 { true } else { false } },
                           "\(other)")
        }
        var clean = Self.featureBranch
        clean.uncommittedFiles = 0
        XCTAssertEqual(rows(git: clean, sessions: [done]), [.resume(done)], "Nothing uncommitted: nothing to continue")
        clean.uncommittedFiles = 1
        XCTAssertEqual(rows(git: clean, sessions: []).first?.detail, L10n.string("1 uncommitted file"))
        XCTAssertEqual(rows(sessions: []), [.continueBranch(branch: "feature/home", uncommittedFiles: 4)],
                       "A folder without tasks still has its branch")
    }

    // MARK: - Tasks

    func testTheTasksListIsExactlyWhatTheAttentionProjectionCounts() {
        let approval = task("Approval", at: 10, status: .waitingForApproval, in: Self.otherFolder)
        let question = task("Question", at: 30, status: .running)
        let working = task("Working", at: 99, status: .running)
        let unread = task("Unread", at: 50, unread: true)
        let failed = task("Failed", at: 70, status: .failed, unread: true, in: Self.otherFolder)
        let read = task("Read", at: 80)
        let shell = task("Shell", at: 90)
        let sessions = [read, unread, working, approval, failed, question, shell]
        let details = [question.id: TaskAttentionDetail(pendingRequest: .input),
                       failed.id: TaskAttentionDetail(errorMessage: "Overloaded")]
        let busy: Set<UUID> = [shell.id]

        let rows = NewTaskHomeListsProjection.attentionRows(sessions: sessions, details: details, shellBusy: busy)
        XCTAssertEqual(rows.map(\.session.title), ["Question", "Approval", "Failed", "Unread"],
                       "Waiting first, then unread results, each most recent first; nothing running")
        XCTAssertEqual(rows.count, TaskAttentionProjection.count(in: sessions, details: details, shellBusy: busy),
                       "The Dock badge's number")
        XCTAssertEqual(rows.first?.id, TaskAttentionProjection.nextSession(in: sessions, excluding: nil, details: details,
                                                                           shellBusy: busy), "Where ⌥⌘A goes")
        XCTAssertEqual(rows.map(\.id), TaskAttentionProjection.activityList(in: sessions, details: details, shellBusy: busy)
            .filter { TaskAttentionProjection.needsAttention($0, detail: details[$0.id], isShellBusy: busy.contains($0.id)) }
            .map(\.id), "The activity view's order, without the tasks still working")
        for row in rows {
            XCTAssertEqual(row.status, SidebarTaskIndicatorProjection.status(of: row.session, detail: details[row.id],
                                                                            isShellBusy: busy.contains(row.id)),
                           "The sidebar row's mark for \(row.session.title)")
        }
        XCTAssertEqual(rows.map(\.status.accessibilityName), [
            L10n.string("Awaiting answer"), L10n.string("Awaiting input"),
            L10n.string("Task encountered a system error"), L10n.string("Unread response"),
        ])
        XCTAssertEqual(rows.map(\.canMarkRead), [false, false, true, true], "A waiting task stays until it is answered")
        XCTAssertEqual(TaskAttentionProjection.attentionList(in: sessions, details: details, shellBusy: busy).map(\.id),
                       rows.map(\.id))
    }

    // MARK: - Pull requests

    func testPullRequestRowsListOpenOnesOnceMostRecentFirst() {
        let tasks = (0..<8).map { task("Task \($0)", at: TimeInterval($0) * 10) }
        let prs: [UUID: TaskPullRequest] = [
            tasks[0].id: pullRequest(1, checks: .passing),
            tasks[1].id: pullRequest(2, state: .draft),
            tasks[2].id: pullRequest(3, state: .merged),
            tasks[3].id: pullRequest(4, state: .closed),
            tasks[4].id: pullRequest(5, state: nil),
            tasks[5].id: pullRequest(6, checks: .failing, review: .approved),
            tasks[6].id: pullRequest(6, checks: .failing, review: .approved),
            tasks[7].id: pullRequest(8, review: .changesRequested),
        ]
        let rows = NewTaskHomeListsProjection.pullRequestRows(sessions: tasks, pullRequest: { prs[$0] })
        XCTAssertEqual(rows.map(\.pullRequest.number), [8, 6, 1],
                       "Open only (no draft, merged, closed or unknown), once per link, the most recent task's")
        XCTAssertEqual(rows.map(\.session.id), [tasks[7].id, tasks[6].id, tasks[0].id])

        func pill(_ pr: TaskPullRequest) -> String { NewTaskPullRequestRow(session: tasks[0], pullRequest: pr).pill.title }
        XCTAssertEqual(pill(pullRequest(1, checks: .failing, review: .changesRequested)), L10n.string("Changes requested"))
        XCTAssertEqual(pill(pullRequest(1, checks: .failing, review: .approved)), L10n.string("Checks failing"))
        XCTAssertEqual(pill(pullRequest(1, checks: .pending)), L10n.string("Checks running"))
        XCTAssertEqual(pill(pullRequest(1, checks: .passing, review: .approved)), L10n.string("Pull request review approved"))
        XCTAssertEqual(pill(pullRequest(1, checks: .passing)), L10n.string("Checks passing"))
        XCTAssertEqual(pill(pullRequest(1)), L10n.string("Pull request state open"))
    }

    func testTheScreenAsksAboutTheRecentTasksAndTheFoldersOwn() {
        let recent = (0..<20).map { task("Recent \($0)", at: 1000 + TimeInterval($0), in: Self.otherFolder) }
        let here = (0..<5).map { task("Here \($0)", at: TimeInterval($0)) }
        let picked = NewTaskHomeListsProjection.pullRequestCandidates(folder: Self.folder, sessions: here + recent)
        XCTAssertEqual(picked.count, NewTaskHomeListsProjection.pullRequestCandidateLimit
                       + NewTaskHomeListsProjection.folderPullRequestCandidateLimit)
        XCTAssertEqual(Array(picked.prefix(12)).map(\.title), (8..<20).reversed().map { "Recent \($0)" })
        XCTAssertEqual(Array(picked.suffix(3)).map(\.title), ["Here 4", "Here 3", "Here 2"])
        XCTAssertEqual(NewTaskHomeListsProjection.pullRequestCandidates(folder: nil, sessions: here).count, 5)
    }

    // MARK: - How many rows

    func testListsShowThreeToSevenRowsByWindowHeight() {
        let limits = [600, 800, 801, 900, 901, 1000, 1001, 1100, 1101, 1600].map {
            NewTaskHomeListsProjection.rowLimit(windowHeight: CGFloat($0))
        }
        XCTAssertEqual(limits, [3, 3, 4, 4, 5, 5, 6, 6, 7, 7], "The Claude app's `dU`: 3, and one more past each of 800–1100")
        XCTAssertEqual(String(format: L10n.string("Show %lld more", languageCode: "ko"), 4), "4개 더 보기")
    }

    // MARK: - Pickers and title

    func testPickerDefaultsForANewTask() {
        let first = Project(name: "yardlet", primaryRoot: Self.folder)
        let second = Project(name: "other", primaryRoot: Self.otherFolder)
        let draft = NewTaskDraft()
        draft.prepare(defaultProject: first, availableHarnesses: [.claudeCode, .codex])
        XCTAssertEqual(draft.workspaceURL, first.primaryRoot, "The first project the sidebar lists")
        XCTAssertEqual(draft.projectID, first.id)
        XCTAssertEqual(draft.harness, .claudeCode, "The first connected harness")
        XCTAssertFalse(draft.startsInNewWorktree(projectID: first.id), "Local until a worktree is chosen")
        XCTAssertNil(draft.modelChoices[.claudeCode], "The harness's own settings name the model")
        XCTAssertFalse(draft.startsChat)

        // Choices made stay; preparing again does not undo them.
        NewTaskDestination.select(second, draft: draft, onChooseWorkspace: { _ in })
        draft.setStartsInNewWorktree(true, projectID: second.id)
        draft.harness = .codex
        draft.prepare(defaultProject: first, availableHarnesses: [.claudeCode, .codex])
        XCTAssertEqual(draft.workspaceURL, second.primaryRoot)
        XCTAssertEqual(draft.harness, .codex)
        XCTAssertTrue(draft.startsInNewWorktree(projectID: second.id))
        XCTAssertFalse(draft.startsInNewWorktree(projectID: first.id), "Remembered per project")
        XCTAssertEqual(NewTaskDestination.project(for: draft, in: [first, second])?.id, second.id)

        draft.chooseChat()
        XCTAssertNil(draft.workspaceURL)
        XCTAssertNil(NewTaskDestination.project(for: draft, in: [first, second]))
        XCTAssertTrue(NewTaskHomeListsProjection.folderRows(
            folder: draft.workspaceURL, startsChat: draft.startsChat, isInRepository: true, startsInNewWorktree: false,
            git: Self.featureBranch, sessions: [task("Here", at: 0)]).isEmpty)
    }

    func testTheTitleNamesTheProjectAsTheCodexAppDoes() {
        typealias Kind = NewTaskHeroTitleKind
        let name: (URL) -> String = { _ in "yardlet" }
        XCTAssertEqual(Kind(startsChat: false, workspaceURL: Self.folder, isInRepository: true, projectName: name),
                       .build(project: "yardlet"))
        XCTAssertEqual(Kind(startsChat: false, workspaceURL: Self.folder, isInRepository: false, projectName: name),
                       .workOn(project: "yardlet"))
        XCTAssertEqual(Kind(startsChat: true, workspaceURL: nil, isInRepository: false, projectName: name), .noProject)
        XCTAssertEqual(Kind(startsChat: false, workspaceURL: nil, isInRepository: false, projectName: name), .noProject)

        // The project's name goes where the sentence names it, in either language.
        let english = Kind.split(L10n.string("What should we build in %@?", languageCode: "en"), around: "yardlet")
        XCTAssertEqual(english.before, "What should we build in ")
        XCTAssertEqual(english.project, "yardlet")
        XCTAssertEqual(english.after, "?")
        let korean = Kind.split(L10n.string("What should we build in %@?", languageCode: "ko"), around: "yardlet")
        XCTAssertEqual(korean.before, "")
        XCTAssertEqual(korean.after, "에서 무엇을 만들어볼까요?")
        XCTAssertEqual(Kind.build(project: "yardlet").sentence, L10n.format("What should we build in %@?", "yardlet"))
        XCTAssertEqual(Kind.workOn(project: "notes").sentence, L10n.format("What should we work on in %@?", "notes"))
        XCTAssertEqual(Kind.noProject.sentence, L10n.string("What should we build?"))
        XCTAssertNil(Kind.noProject.parts.project)
        XCTAssertEqual(Kind.shortened(String(repeating: "a", count: 30)), String(repeating: "a", count: 30))
        XCTAssertEqual(Kind.shortened(String(repeating: "a", count: 30) + String(repeating: "b", count: 30)).count, 40)

        XCTAssertEqual(L10n.string("What should we build in %@?", languageCode: "ko"), "%@에서 무엇을 만들어볼까요?")
        XCTAssertEqual(L10n.string("What should we work on in %@?", languageCode: "ko"), "%@에서 무엇을 작업할까요?")
        XCTAssertEqual(String(format: L10n.string("Ask %@ to do anything", languageCode: "ko"), "Codex"), "Codex에게 뭐든 부탁해 보세요")
    }

    // MARK: - Projects

    func testProjectsListWhatNeedsThePersonFirstAndKeepTheirPlaces() throws {
        let now = Date(timeIntervalSince1970: 10 * 86_400)
        func at(_ hoursAgo: Double) -> TimeInterval { now.timeIntervalSince1970 - hoursAgo * 3600 }
        let quietFolder = URL(filePath: "/tmp/new-task-home/quiet")
        let staleFolder = URL(filePath: "/tmp/new-task-home/stale")
        let yardlet = Project(name: "yardlet", primaryRoot: Self.folder)
        let other = Project(name: "other", primaryRoot: Self.otherFolder)
        let quiet = Project(name: "quiet", primaryRoot: quietFolder)
        let stale = Project(name: "stale", primaryRoot: staleFolder)

        let parent = task("Parent", at: at(0.5), status: .running)
        var child = task("Child", at: at(0.4), status: .running)
        child.parentTaskID = parent.id
        var idleChild = task("Idle child", at: at(0.3))
        idleChild.parentTaskID = parent.id
        let unread = task("Unread", at: at(1), unread: true)
        let finished = task("Finished", at: at(2))
        let question = task("Question", at: at(3), status: .running, in: Self.otherFolder)
        let lastWeek = task("Last week", at: at(24 * 6), in: quietFolder)
        let old = task("Old", at: at(24 * 8), in: staleFolder)
        let details = [question.id: TaskAttentionDetail(pendingRequest: .input)]
        let turns = [parent.id: TaskLatestTurn(startedAt: Date(timeIntervalSince1970: at(1.5)))]
        let audit = ScheduledTask(name: "Audit", prompt: "", trigger: .daily(ScheduleTime(hour: 9, minute: 0)),
                                  destination: ScheduleDestination(harness: .codex, projectID: yardlet.id))
        let groups = [
            WorkspaceGroup(workspaceURL: Self.folder, sessions: [parent, child, idleChild, unread, finished], project: yardlet),
            WorkspaceGroup(workspaceURL: Self.otherFolder, sessions: [question], project: other),
            WorkspaceGroup(workspaceURL: quietFolder, sessions: [lastWeek], project: quiet),
            WorkspaceGroup(workspaceURL: staleFolder, sessions: [old], project: stale),
        ]
        let summaries = NewTaskHomeListsProjection.projectSummaries(
            groups: groups, details: details, schedules: [(audit, now.addingTimeInterval(3600))],
            answerLine: { $0 == unread.id ? "Done." : nil }, latestTurn: { turns[$0] }, now: now,
            calendar: Calendar(identifier: .gregorian))

        XCTAssertEqual(summaries.map(\.name), ["other", "yardlet", "quiet"],
                       "Waiting on the person first, then running; a project quiet for over seven days is not shown")
        let home = try XCTUnwrap(summaries.first { $0.name == "yardlet" })
        XCTAssertEqual(home.tasks.map(\.session.title), ["Unread", "Parent", "Finished"],
                       "Unread, then running, then the others; a task under another is that task's")
        XCTAssertEqual(home.tasks[0], .attention(NewTaskAttentionRow(session: unread, status: .unread, answerLine: "Done.")))
        XCTAssertEqual(home.tasks[1], .running(NewTaskRunningRow(session: parent, subtasks: 1,
                                                                 since: Date(timeIntervalSince1970: at(1.5)))),
                       "The running child is counted on its parent's line, which runs since its turn started")
        XCTAssertEqual([home.unread, home.running, home.waiting], [1, 2, 0])
        XCTAssertEqual(home.upcoming, [.schedule(audit, nextRun: now.addingTimeInterval(3600))])
        XCTAssertEqual(summaries.last?.tasks, [.recent(lastWeek, answerLine: nil)], "A quiet project shows its latest")

        // Places stay while the screen shows: a project that comes to need the person does not jump.
        let places = NewTaskHomeListsProjection.places([], listing: summaries.map(\.id))
        var later = summaries
        later.swapAt(0, 2)
        XCTAssertEqual(NewTaskHomeListsProjection.keepingPlaces(places, of: later).map(\.name), ["other", "yardlet", "quiet"])
        XCTAssertEqual(NewTaskHomeListsProjection.places(places, listing: [summaries[2].id, "new", summaries[0].id]),
                       [summaries[0].id, summaries[2].id, "new"], "One gone leaves; a new one comes last")

        // Columns of at least 400 pt, up to three: 640 pt is one, 1240 pt two, 1480 pt three.
        XCTAssertEqual([640, 1240, 1480].map { NewTaskHomeLayout.columns(width: $0) }, [1, 2, 3])

        // Left alone three days or more, with nothing waiting or running: named with what it left, and
        // no longer one of the projects. Being old alone lists nothing; a project whose tasks were all
        // archived has none listed, so it is closed out.
        let leftFolder = URL(filePath: "/tmp/new-task-home/left")
        let left = Project(name: "left", primaryRoot: leftFolder)
        let leftTask = task("Left", at: at(24 * 4), in: leftFolder)
        let sleepingFolder = URL(filePath: "/tmp/new-task-home/sleeping")
        let sleeping = Project(name: "sleeping", primaryRoot: sleepingFolder)
        let sleepingTask = task("Sleeping", at: at(24 * 20), in: sleepingFolder)
        var stopped = ScheduledTask(name: "Nightly", prompt: "", trigger: .daily(ScheduleTime(hour: 2, minute: 0)),
                                    destination: ScheduleDestination(harness: .codex, projectID: sleeping.id))
        stopped.isEnabled = false
        stopped.state.stopReason = .repeatedFailures
        let withLeft = groups + [
            WorkspaceGroup(workspaceURL: leftFolder, sessions: [leftTask], project: left),
            WorkspaceGroup(workspaceURL: sleepingFolder, sessions: [sleepingTask], project: sleeping),
            WorkspaceGroup(workspaceURL: URL(filePath: "/tmp/new-task-home/closed"), sessions: [],
                           project: Project(name: "closed", primaryRoot: URL(filePath: "/tmp/new-task-home/closed"))),
        ]
        XCTAssertEqual(NewTaskHomeListsProjection.idleCandidates(groups: withLeft, details: details, now: now)
            .map(\.project.name), ["left", "quiet", "stale", "sleeping"], "The most recently left first")
        let monitor = [sleepingTask.id: pullRequest(31)]
        let idle = NewTaskHomeListsProjection.idleProjects(
            groups: withLeft, details: details,
            work: { $0 == left.id ? GitLeftWork(uncommittedFiles: 21, openWorktrees: 3) : nil },
            pullRequest: { monitor[$0] }, stoppedSchedules: [stopped], now: now)
        XCTAssertEqual(idle.map(\.project.name), ["left", "sleeping"], "Quiet and stale left nothing")
        XCTAssertEqual(idle[0].latestTask, leftTask)
        XCTAssertEqual(idle[0].workLeft, [L10n.format("%lld uncommitted files", 21),
                                          L10n.format("%lld worktrees with work left", 3)])
        XCTAssertEqual(idle[1].workLeft, [L10n.string("1 open pull request"), L10n.string("1 stopped schedule")])
        let rest = NewTaskHomeListsProjection.projectSummaries(groups: withLeft, details: details,
                                                               leaving: Set(idle.map(\.id)), now: now)
        XCTAssertEqual(rest.map(\.name), ["other", "yardlet", "quiet"], "What was left is named apart")
        XCTAssertEqual(NewTaskHomeListsProjection.pullRequestCandidates(folder: nil, sessions: [], idle: [sleepingTask]),
                       [sleepingTask], "A left project's latest task is asked about its pull requests")

        // Dismissed there, a project is set aside until it is active again, and stays so across launches.
        var setAside = left
        setAside.setAsideThrough = leftTask.updatedAt
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(setAside))
        XCTAssertEqual(restored.setAsideThrough, leftTask.updatedAt)
        func names(_ project: Project, _ sessions: [SessionRecord]) -> [String] {
            NewTaskHomeListsProjection.idleCandidates(
                groups: [WorkspaceGroup(workspaceURL: leftFolder, sessions: sessions, project: project)], now: now)
                .map(\.project.name)
        }
        XCTAssertEqual(names(restored, [leftTask]), [])
        let againLater = task("Again", at: at(24 * 3.5), in: leftFolder)
        XCTAssertEqual(names(restored, [leftTask, againLater]), ["left"], "Active after it was set aside")

        // A task that needs the person, or one running, means the project was not left.
        let waiting = task("Waiting", at: at(24 * 5), status: .waitingForApproval, in: leftFolder)
        let busy = [WorkspaceGroup(workspaceURL: leftFolder, sessions: [leftTask, waiting], project: left)]
        XCTAssertTrue(NewTaskHomeListsProjection.idleCandidates(groups: busy, now: now).isEmpty)
    }

    func testARowsPromptKeepsTheDraftAndIsNotAddedTwice() {
        let draft = NewTaskDraft()
        draft.insertPrompt("Fix the failing CI checks on main.")
        XCTAssertEqual(draft.text, "Fix the failing CI checks on main.")
        draft.insertPrompt("Fix the failing CI checks on main.")
        XCTAssertEqual(draft.text, "Fix the failing CI checks on main.")
        draft.text = "Also tidy the README. "
        draft.insertPrompt("Continue on main.")
        XCTAssertEqual(draft.text, "Also tidy the README.\n\nContinue on main.")
    }

    // MARK: - Keyboard

    func testTheKeyboardMovesFromTheComposerThroughTheRowsAndBack() {
        var keyboard = NewTaskHomeListKeyboard()
        XCTAssertFalse(keyboard.enter(), "Nothing listed: Tab stays with the composer")
        XCTAssertEqual(keyboard.press(.down), .ignored)

        let rows: [NewTaskHomeListKeyboard.Entry] = [.row(.folder, "a"), .row(.folder, "b"), .toggle(.folder),
                                                     .row(.project("p"), "t")]
        keyboard.list(rows)
        XCTAssertNil(keyboard.highlighted, "Listing rows does not take the keyboard")
        XCTAssertTrue(keyboard.enter())
        XCTAssertEqual(keyboard.highlightedEntry, .row(.folder, "a"), "Tab goes to the first row")
        XCTAssertEqual(keyboard.press(.up), .handled)
        XCTAssertEqual(keyboard.highlightedEntry, .row(.folder, "a"), "↑ stops at the first row")
        XCTAssertEqual(keyboard.press(.down), .handled)
        XCTAssertEqual(keyboard.press(.down), .handled)
        XCTAssertEqual(keyboard.press(.return), .perform(.toggle(.folder)), "Show more is a row too")
        XCTAssertEqual(keyboard.press(.down), .handled)
        XCTAssertEqual(keyboard.press(.down), .handled)
        XCTAssertEqual(keyboard.highlightedEntry, .row(.project("p"), "t"), "↓ stops at the last row")
        XCTAssertEqual(keyboard.press(.return), .perform(.row(.project("p"), "t")))
        XCTAssertEqual(keyboard.press(.escape), .ignored, "Escape does not leave the new-task screen")
        XCTAssertEqual(keyboard.press(.tab), .returnToComposer)

        // Rows change under the highlight: it stays on its row, or on the same place.
        keyboard.list([.row(.folder, "b"), .row(.project("p"), "t"), .row(.moreProjects, "p")])
        XCTAssertEqual(keyboard.highlightedEntry, .row(.project("p"), "t"))
        keyboard.list([.row(.folder, "b")])
        XCTAssertEqual(keyboard.highlightedEntry, .row(.folder, "b"))
        keyboard.list([])
        XCTAssertNil(keyboard.highlighted)
        keyboard.list(rows)
        _ = keyboard.enter()
        keyboard.leave()
        XCTAssertNil(keyboard.highlighted, "Leaving the lists drops the highlight")
    }

    func testFileNewTaskIsCommandNAndClashesWithNoTaskShortcut() {
        XCTAssertEqual(TaskCommandShortcut.newTask.key, "n")
        XCTAssertEqual(TaskCommandShortcut.newTask.modifiers, .command)
        XCTAssertFalse(TaskCommandShortcut.all.contains { $0.key == "n" && $0.modifiers == .command })
        XCTAssertNil(YardletTaskCommandSet().newTask, "Off until the window offers it")
        XCTAssertEqual(L10n.string("New Window", languageCode: "ko"), "새로운 윈도우")
    }

    // MARK: - Git

    func testTheFolderStateCountsUncommittedFilesWithoutWriting() async throws {
        let git = GitExecutableLocator.preferredURL()
        let root = FileManager.default.temporaryDirectory.appending(path: "new-task-home-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = git
            process.currentDirectoryURL = root
            process.arguments = arguments
            process.environment = ["GIT_CONFIG_NOSYSTEM": "1", "HOME": root.path, "GIT_AUTHOR_NAME": "t",
                                   "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
                                   "GIT_COMMITTER_EMAIL": "t@example.com"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(arguments)")
        }
        try run(["init", "-q", "-b", "main"])
        try Data("a".utf8).write(to: root.appending(path: "a.txt"))
        try run(["add", "a.txt"])
        try run(["commit", "-q", "-m", "First"])

        let onMain = await NewTaskFolderGitState.read(root)
        XCTAssertEqual(onMain, NewTaskFolderGitState(isRepository: true, branch: "main", isDefaultBranch: true),
                       "On the default branch nothing is counted")

        try run(["checkout", "-q", "-b", "feature/home"])
        try Data("b".utf8).write(to: root.appending(path: "a.txt"))
        try Data("c".utf8).write(to: root.appending(path: "new.txt"))
        let index = root.appending(path: ".git/index")
        let before = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        let onBranch = await NewTaskFolderGitState.read(root)
        XCTAssertEqual(onBranch, NewTaskFolderGitState(isRepository: true, branch: "feature/home", isDefaultBranch: false,
                                                       uncommittedFiles: 2))
        let after = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "Counting does not refresh Git's index")

        let outside = await NewTaskFolderGitState.read(FileManager.default.temporaryDirectory
            .appending(path: "new-task-home-none-\(UUID().uuidString)"))
        XCTAssertEqual(outside, .none)

        // What a project left: its files not committed, commits not pushed, and worktrees whose commits
        // main does not hold or with files not committed; a merged, clean worktree left nothing.
        let remote = root.appending(path: "../\(root.lastPathComponent)-remote.git").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: remote) }
        try run(["init", "-q", "--bare", remote.path])
        try run(["commit", "-q", "-am", "Work on the home"])
        try run(["checkout", "-q", "main"])
        try run(["remote", "add", "origin", remote.path])
        try run(["push", "-q", "-u", "origin", "main"])
        try Data("d".utf8).write(to: root.appending(path: "d.txt"))
        try run(["add", "d.txt"])
        try run(["commit", "-q", "-m", "Not pushed"])
        let unmerged = root.appending(path: "../\(root.lastPathComponent)-unmerged").standardizedFileURL
        let merged = root.appending(path: "../\(root.lastPathComponent)-merged").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: unmerged); try? FileManager.default.removeItem(at: merged) }
        try run(["worktree", "add", "-q", unmerged.path, "feature/home"])
        try run(["worktree", "add", "-q", "-b", "done", merged.path, "main"])
        let beforeLeft = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        let left = try await GitDiffService().leftWork(workspaceURL: root)
        XCTAssertEqual(left, GitLeftWork(uncommittedFiles: 1, unpushedCommits: 1, openWorktrees: 1),
                       "new.txt; the commit not pushed; feature/home's worktree, whose commit main lacks")
        let afterLeft = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        XCTAssertEqual(beforeLeft, afterLeft, "Reading what was left does not refresh Git's index")
    }
}
