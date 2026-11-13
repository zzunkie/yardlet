import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The new-task screen, Yardlet's home, drawn for review into `.build/new-task-qa/`: four projects and
/// the chats with what their tasks need, wide (two and three columns) and narrow, in both appearances,
/// quiet and empty, and with a chat chosen. Then what a person does in a real (unshown) window: a click
/// on a project chooses where the task starts and a click on a line opens its task, Tab, ↓ and Return
/// move from the composer through the projects to the folder's rows over the composer, and a narrower
/// window puts the projects in one column. No provider, `gh` or Git command runs: pull requests are
/// set on the monitor and the folders' Git state is given.
@MainActor
final class NewTaskHomeRenderingTests: XCTestCase {
    private var root: URL!
    private var repository: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "new-task-qa-\(UUID().uuidString)")
        repository = root.appending(path: "yardlet", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository.appending(path: ".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/feature/home\n".utf8).write(to: repository.appending(path: ".git/HEAD"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    private func task(_ title: String, minutesAgo: Double, status: SessionStatus = .completed, unread: Bool = false,
                      in folder: URL, harness: HarnessKind = .claudeCode) -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/runtime"),
                      title: title, titleOrigin: .provider, status: status,
                      updatedAt: Date().addingTimeInterval(-minutesAgo * 60), hasUnreadUpdate: unread)
    }

    private func pullRequest(_ number: Int, state: TaskPullRequest.State = .open, checks: TaskPullRequest.Checks? = nil,
                             review: TaskPullRequest.Review? = nil, branch: String? = nil) -> TaskPullRequest {
        TaskPullRequest(number: number, url: URL(string: "https://github.com/example/yardlet/pull/\(number)")!,
                        repository: "example/yardlet", source: branch.map { .branch($0) } ?? .transcriptLink,
                        state: state, checks: checks, review: review)
    }

    /// The home of someone with four projects and a chat: tasks waiting, unread with their answers'
    /// first lines, running with subtasks, quiet projects with their latest results, open pull
    /// requests, schedules and a suggestion, and two notices.
    private func homeFixture() -> Fixture {
        let shop = root.appending(path: "example-web", directoryHint: .isDirectory)
        let designKit = root.appending(path: "design-kit", directoryHint: .isDirectory)
        let rental = root.appending(path: "web-app", directoryHint: .isDirectory)
        let chatFolder = root.appending(path: "chats/contract", directoryHint: .isDirectory)
        let yardlet = Project(name: "yardlet", primaryRoot: repository)
        let exampleProject = Project(name: "example-web", primaryRoot: shop)
        let designProject = Project(name: "design-kit", primaryRoot: designKit)
        let rentalProject = Project(name: "web-app", primaryRoot: rental)
        let now = Date()
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        var details: [UUID: TaskAttentionDetail] = [:]
        var turns: [UUID: TaskLatestTurn] = [:]
        var answers: [UUID: String] = [:]

        // yardlet: one waiting, one unread, one running with two subtasks, two finished with pull requests.
        let approve = task("Approve schema migration", minutesAgo: 2, status: .waitingForApproval, in: repository)
        var notes = task("Summarize release notes", minutesAgo: 6, unread: true, in: repository)
        notes.completionState = .completed
        answers[notes.id] = "Sorted the 12 changes in 0.9 into features, fixes and internals."
        let sidebar = task("Refactor sidebar rows", minutesAgo: 0.5, status: .running, in: repository)
        turns[sidebar.id] = TaskLatestTurn(startedAt: at(14), suggestions: [
            TaskAttentionSuggestion(id: "task_1a2b3c4d", title: "Fix the README badge")])
        var child = task("Tidy selection state tests", minutesAgo: 1, status: .running, in: repository)
        child.parentTaskID = sidebar.id
        var hover = task("Check the hover card render", minutesAgo: 2, status: .running, in: repository, harness: .codex)
        hover.parentTaskID = sidebar.id
        let shipped = task("Ship PR badges", minutesAgo: 90, in: repository)
        answers[shipped.id] = "Badges now follow one rule in the sidebar and the rail."
        let merged = task("Tidy the connector list", minutesAgo: 150, in: repository)

        // example-web: a question, a failure, an unread result, a running task, an approved pull request.
        let question = task("Pick a CLI flag name", minutesAgo: 4, status: .running, in: shop, harness: .codex)
        details[question.id] = TaskAttentionDetail(pendingRequest: .input)
        let flaky = task("Upload test fails now and then", minutesAgo: 12, status: .failed, unread: true, in: shop,
                         harness: .codex)
        details[flaky.id] = TaskAttentionDetail(errorMessage: "Overloaded")
        let blog = task("Blog list first-load speed", minutesAgo: 25, unread: true, in: shop, harness: .codex)
        answers[blog.id] = "The list's first screen now loads in 0.6 s, down from 1.8 s. Added lazy images and a query cache; 14 tests pass."
        let webhook = task("Retry payment webhooks", minutesAgo: 1, status: .running, in: shop, harness: .codex)
        turns[webhook.id] = TaskLatestTurn(startedAt: at(3))
        let checkout = task("Checkout page accessibility", minutesAgo: 200, in: shop)

        // design-kit: a plan limit and an unread result.
        let weekly = task("Tidy the weekly report", minutesAgo: 41, status: .completed, unread: true, in: designKit)
        details[weekly.id] = TaskAttentionDetail(usageLimit: HarnessRateLimit(
            status: .rejected, window: .session, resetsAt: Calendar.current.date(byAdding: .hour, value: 2, to: now)))
        let copy = task("Polish the onboarding copy", minutesAgo: 70, unread: true, in: designKit)
        answers[copy.id] = "Fixed three places: the first screen's title, the account hint, the empty list."

        // web-app: quiet, its latest conversations from yesterday.
        let pricing = task("Tidy the vehicle rates API", minutesAgo: 60 * 20, in: rental)
        answers[pricing.id] = "Moved the rate math to one place on the server; screens only get results."
        let seo = task("Blog post meta tags", minutesAgo: 60 * 26, in: rental, harness: .codex)
        answers[seo.id] = "Added canonical and og tags per language and checked three previews."

        // A chat with no project.
        let contract = task("Compare contract clauses", minutesAgo: 180, in: chatFolder)
        answers[contract.id] = "The two termination clauses differ only in notice period (30 and 60 days)."

        // Left alone for a while, with work left: files and worktrees (ledger-app, four days), an open
        // pull request and a commit not pushed (field-notes, twelve days). Old-notes left nothing.
        let ledger = root.appending(path: "ledger-app", directoryHint: .isDirectory)
        let fieldNotes = root.appending(path: "field-notes", directoryHint: .isDirectory)
        let oldNotes = root.appending(path: "old-notes", directoryHint: .isDirectory)
        let ledgerProject = Project(name: "ledger-app", primaryRoot: ledger)
        let fieldProject = Project(name: "field-notes", primaryRoot: fieldNotes)
        let oldProject = Project(name: "old-notes", primaryRoot: oldNotes)
        let reconcile = task("Month-end reconciliation screen", minutesAgo: 60 * 24 * 4, in: ledger)
        let sync = task("Handle offline sync conflicts", minutesAgo: 60 * 24 * 12, in: fieldNotes, harness: .codex)
        let archive = task("Clean up the archive", minutesAgo: 60 * 24 * 30, in: oldNotes)

        let sessions = [approve, notes, sidebar, child, hover, shipped, merged, question, flaky, blog, webhook, checkout,
                        weekly, copy, pricing, seo, reconcile, sync, archive]

        // What the waiting tasks and an unread result said, for the composer's place.
        var conversations: [UUID: [TranscriptEntry]] = [:]
        conversations[approve.id] = [
            TranscriptEntry(content: .user(text: "Add a provider_scope column to the session index")),
            TranscriptEntry(content: .assistant(text: "I wrote the migration. Existing rows are filled from the account folders.",
                                                isStreaming: false)),
            TranscriptEntry(content: .permission(PermissionRequest(
                id: "migrate", title: "Bash", detail: "Adds provider_scope to the session index and fills the existing rows.",
                command: "swift run yardlet-index migrate --apply", toolCallID: "toolu_migrate"), state: .pending))
        ]
        conversations[question.id] = [
            TranscriptEntry(content: .user(text: "Settle on one retry flag")),
            TranscriptEntry(content: .assistant(text: "The code mixes --retry and --retries today.", isStreaming: false)),
            TranscriptEntry(content: .permission(PermissionRequest(
                id: "flag", title: "Codex asks", detail: nil, command: nil,
                structured: .questions([PermissionQuestion(
                    question: "What should the flag that sets the retry count be called?", header: "Flag",
                    options: [
                        PermissionQuestionOption(label: "--max-retries", description: "Clearly reads as a ceiling"),
                        PermissionQuestionOption(label: "--retries", description: "Short, and fits the existing --timeout"),
                        PermissionQuestionOption(label: "--retry-count", description: "Matches retryCount in the config file")
                    ],
                    allowsMultipleSelections: false)]),
                toolCallID: "flag-tool"), state: .pending))
        ]
        conversations[notes.id] = [
            TranscriptEntry(content: .user(text: "Write up the 0.9 release notes")),
            TranscriptEntry(content: .assistant(text: """
                Sorted the 12 changes in 0.9 into features, fixes and internals.

                - **Features:** project cells on Home, built-in authenticator, phone remote v2
                - **Fixes:** the card-saving bubble at checkout, Google cookie copy
                - **Internal:** session index cleanup, faster tests

                It is in `docs/RELEASE_NOTES.md`. Shall I commit it and open a PR?
                """, isStreaming: false))
        ]

        let monitor = TaskPullRequestMonitor()
        monitor.setPullRequest(pullRequest(212, checks: .failing, branch: "feature/home"), for: shipped.id)
        monitor.setPullRequest(pullRequest(209, checks: .pending), for: merged.id)
        monitor.setPullRequest(pullRequest(48, checks: .passing, review: .approved), for: checkout.id)
        monitor.setPullRequest(pullRequest(17, checks: .passing), for: sync.id)

        func group(_ project: Project) -> WorkspaceGroup {
            WorkspaceGroup(workspaceURL: project.primaryRoot,
                           sessions: sessions.filter { $0.workspaceURL.standardizedFileURL.path
                               == project.primaryRoot.standardizedFileURL.path },
                           project: project)
        }
        let calendar = Calendar.current
        func destination(_ harness: HarnessKind, _ folder: URL?) -> ScheduleDestination {
            ScheduleDestination(harness: harness, workspacePath: folder?.path(percentEncoded: false))
        }
        let briefing = ScheduledTask(name: "Morning briefing", prompt: "", trigger: .daily(ScheduleTime(hour: 9, minute: 0)),
                                     destination: destination(.claudeCode, nil))
        let audit = ScheduledTask(name: "Dependency audit", prompt: "", trigger: .daily(ScheduleTime(hour: 15, minute: 0)),
                                  destination: destination(.codex, repository))
        let names = [ProjectSidebarPresentation.normalizedPath(for: repository): "yardlet",
                     ProjectSidebarPresentation.normalizedPath(for: shop): "example-web",
                     ProjectSidebarPresentation.normalizedPath(for: designKit): "design-kit",
                     ProjectSidebarPresentation.normalizedPath(for: rental): "web-app",
                     ProjectSidebarPresentation.normalizedPath(for: ledger): "ledger-app",
                     ProjectSidebarPresentation.normalizedPath(for: fieldNotes): "field-notes",
                     ProjectSidebarPresentation.normalizedPath(for: oldNotes): "old-notes"]
        let activity = NewTaskHomeActivity(
            sessions: sessions + [contract], details: details,
            placeName: { names[ProjectSidebarPresentation.normalizedPath(for: $0.workspaceURL)] ?? "" },
            groups: [group(yardlet), group(exampleProject), group(designProject), group(rentalProject),
                     group(ledgerProject), group(fieldProject), group(oldProject)],
            chats: [contract],
            schedules: [(audit, calendar.date(byAdding: .minute, value: 95, to: now)!),
                        (briefing, calendar.date(byAdding: .hour, value: 10, to: now)!)],
            notices: { [.usage(account: "jordan", window: L10n.string("Weekly"), remaining: "8%"),
                        .lowDisk(availableBytes: 8_200_000_000)] },
            now: now,
            answerLine: { answers[$0] }, latestTurn: { turns[$0] })
        return (activity, monitor, [yardlet, exampleProject, designProject, rentalProject, ledgerProject, fieldProject,
                                    oldProject], names, conversations)
    }

    /// What the projects left alone for a while left in their folders.
    nonisolated private static func leftWork(_ folder: URL) -> GitLeftWork? {
        switch folder.lastPathComponent {
        case "ledger-app": GitLeftWork(uncommittedFiles: 21, openWorktrees: 3)
        case "field-notes": GitLeftWork(unpushedCommits: 1)
        default: GitLeftWork()
        }
    }

    private enum Scene { case full, quiet, empty }

    private typealias Fixture = (activity: NewTaskHomeActivity, monitor: TaskPullRequestMonitor, projects: [Project],
                                 names: [String: String], conversations: [UUID: [TranscriptEntry]])

    /// - Parameter resizable: the screen follows its window's size, rather than `size`.
    private func home(_ scene: Scene = .full, fixture: Fixture? = nil, size: NSSize, resizable: Bool = false,
                      scheme: ColorScheme, runtimes: RuntimeSelectionStore, draft: NewTaskDraft = NewTaskDraft(),
                      chat: Bool = false, reply: ReplyFixture? = nil, onMarkRead: @escaping ([UUID]) -> Void = { _ in },
                      onOpen: @escaping (SessionRecord) -> Void = { _ in }) -> some View {
        let fixture = fixture ?? homeFixture()
        var activity = fixture.activity
        activity.onMarkRead = onMarkRead
        switch scene {
        case .full:
            break
        case .quiet:
            // A quiet morning: nothing waits or runs; yesterday's conversations and one schedule.
            let quietTitles: Set<String> = ["Tidy the vehicle rates API", "Blog post meta tags", "Ship PR badges"]
            activity.groups = activity.groups.map {
                WorkspaceGroup(workspaceURL: $0.workspaceURL,
                               sessions: $0.sessions.filter { quietTitles.contains($0.title) }, project: $0.project)
            }
            activity.sessions = activity.groups.flatMap(\.sessions)
            activity.chats = []
            activity.schedules = Array(activity.schedules.prefix(1))
            activity.notices = { [] }
        case .empty:
            activity = NewTaskHomeActivity()
        }
        activity.windowHeight = size.height
        draft.harness = .claudeCode
        if chat {
            draft.chooseChat()
        } else if draft.workspaceURL == nil {
            draft.workspaceURL = repository
            draft.projectID = fixture.projects[0].id
        }
        let names = fixture.names
        let shop = fixture.projects[1].primaryRoot
        return NewTaskHome(
            recentSessions: [], projects: scene == .empty ? [] : fixture.projects, draft: draft, runtimeSelections: runtimes,
            onSelectSession: onOpen, onChooseWorkspace: { _ in }, onShowHarnesses: {}, onCreate: { _ in nil },
            onImportConversation: {}, onImportFromOtherApps: {},
            projectName: { names[ProjectSidebarPresentation.normalizedPath(for: $0)] ?? $0.lastPathComponent },
            activity: activity,
            reply: reply?.services(conversations: fixture.conversations),
            readFolderGit: { [repository] folder in
                if Project.isSamePath(folder, repository!) {
                    return NewTaskFolderGitState(isRepository: true, branch: "feature/home", isDefaultBranch: false,
                                                 uncommittedFiles: 4)
                }
                if Project.isSamePath(folder, shop) {
                    return NewTaskFolderGitState(isRepository: true, branch: "fix/upload-retry", isDefaultBranch: false,
                                                 uncommittedFiles: 2)
                }
                return NewTaskFolderGitState(isRepository: true, branch: "main", isDefaultBranch: true)
            },
            readLeftWork: { Self.leftWork($0) },
            readMacConditions: { [] })
        .environment(fixture.monitor)
        .frame(width: resizable ? nil : size.width, height: resizable ? nil : size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ParityTheme.canvas)
        .environment(\.colorScheme, scheme)
    }

    private func runtimes() throws -> RuntimeSelectionStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NewTaskHomeRendering")))
        let store = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        for harness in [HarnessKind.claudeCode, .codex] { store.select(URL(filePath: "/usr/bin/true"), for: harness) }
        return store
    }

    // MARK: - Renders

    /// Token usage over the projects (`TokenUsageHomeBand`), at two widths of the Home surface, in
    /// both appearances, into `.build/token-usage-qa/`.
    func testTheHomeShowsTokenUsageOverTheProjects() throws {
        let directory = try WindowlessRender.directory("token-usage-qa")
        let runtimes = try runtimes()
        for (name, size) in [("home-usage-1280", NSSize(width: 1280, height: 860)),
                             ("home-usage-920", NSSize(width: 920, height: 860))] {
            for appearance in WindowlessRender.Appearance.allCases {
                var fixture = homeFixture()
                let overview = TokenUsageFixture.overview(now: fixture.activity.now)
                fixture.activity.usage = { overview }
                let host = WindowlessRender.Host(
                    home(fixture: fixture, size: size, scheme: appearance.colorScheme, runtimes: runtimes),
                    size: size, appearance: appearance)
                defer { host.close() }
                host.settle(passes: 10)
                try WindowlessRender.writePNG(try host.capture().bitmap,
                                              to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
            }
        }
    }

    func testTheHomeShowsEachProjectWithWhatItNeeds() throws {
        let directory = try WindowlessRender.directory("new-task-qa")
        let runtimes = try runtimes()
        let scenes: [(name: String, scene: Scene, size: NSSize, chat: Bool, dark: Bool)] = [
            ("home-wide", .full, NSSize(width: 1240, height: 860), false, true),
            ("home-narrow", .full, NSSize(width: 640, height: 860), false, true),
            ("home-widest", .full, NSSize(width: 1520, height: 900), false, false),
            ("home-narrow-short", .full, NSSize(width: 640, height: 700), false, false),
            ("home-quiet", .quiet, NSSize(width: 1240, height: 860), false, false),
            ("home-chat", .full, NSSize(width: 1240, height: 860), true, false),
            ("home-empty", .empty, NSSize(width: 980, height: 760), false, true),
        ]
        var elements: [String: [WindowlessRender.AccessibilityElement]] = [:]
        for scene in scenes {
            for appearance in WindowlessRender.Appearance.allCases where appearance == .light || scene.dark {
                let host = WindowlessRender.Host(
                    home(scene.scene, size: scene.size, scheme: appearance.colorScheme, runtimes: runtimes, chat: scene.chat),
                    size: scene.size, appearance: appearance)
                defer { host.close() }
                host.settle(passes: 10)
                try WindowlessRender.writePNG(try host.capture().bitmap, to: directory.appending(
                    path: "\(scene.name)-\(appearance.suffix).png"))
                if appearance == .light { elements[scene.name] = host.accessibilityElements() }
            }
        }
        let report = elements.mapValues { $0.map(\.description).joined(separator: "\n") }
        for (name, text) in report {
            try text.write(to: directory.appending(path: "\(name)-ax.txt"), atomically: true, encoding: .utf8)
        }
        func shows(_ scene: String, _ text: String) -> Bool {
            (elements[scene] ?? []).contains { $0.label.contains(text) || $0.value.contains(text) }
        }
        func headers(_ scene: String) -> [String] {
            let names = ["yardlet", "example-web", "design-kit", "web-app", L10n.string("Chats")]
            return (elements[scene] ?? []).compactMap { element in
                names.first { element.role == "AXButton" && element.label.hasPrefix($0 + ",") || element.label == $0 }
            }
        }

        // Waiting projects first, then unread, then the quiet ones by their latest conversation.
        XCTAssertEqual(headers("home-wide"), ["yardlet", "example-web", "design-kit", L10n.string("Chats"), "web-app"],
                       report["home-wide"]!)
        XCTAssertTrue((elements["home-wide"] ?? []).contains {
            $0.label.hasPrefix("yardlet,") && $0.value == L10n.string("New tasks start here")
        }, "The chosen project says so")
        XCTAssertTrue(shows("home-wide", "Sorted the 12 changes in 0.9 into features, fixes and internals."), "An unread result's first line")
        XCTAssertTrue(shows("home-wide", L10n.format("%lld subtasks", 2)), "Running children counted on their parent")
        XCTAssertTrue(shows("home-wide", "fix/upload-retry"), "Each project's branch, read for its own folder")
        XCTAssertTrue(shows("home-wide", L10n.format("%@ %@ %@ left", "jordan", L10n.string("Weekly"), "8%")))
        XCTAssertTrue(shows("home-wide", L10n.string("Another session is running here")), "The folder's rows over the composer")
        XCTAssertTrue(shows("home-wide", L10n.format("Fix the failing checks on %@", "feature/home")))
        XCTAssertFalse(shows("home-wide", L10n.format("Continue on %@", "feature/home")), "Two of the folder's rows")
        XCTAssertFalse(shows("home-wide", L10n.format("%@ is waiting on you", "Approve schema migration")),
                       "A waiting task is its project's line, not a folder row too")
        XCTAssertTrue(shows("home-wide", L10n.format("What should we build in %@?", "yardlet")))

        // Projects left alone for a while, with what they left; one that left nothing is not named.
        XCTAssertTrue(shows("home-wide", L10n.string("Left for a while")), report["home-wide"]!)
        XCTAssertTrue(shows("home-wide", L10n.format("%lld uncommitted files", 21)))
        XCTAssertTrue(shows("home-wide", L10n.format("%lld worktrees with work left", 3)))
        XCTAssertTrue(shows("home-wide", L10n.string("1 open pull request")))
        XCTAssertTrue(shows("home-wide", L10n.string("1 unpushed commit")))
        XCTAssertFalse(shows("home-wide", "old-notes"))
        XCTAssertTrue(shows("home-narrow-short", L10n.string("Left for a while")), "In sight in a short window too")

        // A short narrow window shows three projects and the rest behind Show more.
        XCTAssertEqual(headers("home-narrow-short").count, 3, report["home-narrow-short"]!)
        XCTAssertTrue(shows("home-narrow-short", L10n.format("Show %lld more", 2)))

        // Quiet: the latest conversations with their answers, and a schedule.
        XCTAssertTrue(shows("home-quiet", "Moved the rate math to one place on the server; screens only get results."), report["home-quiet"]!)
        XCTAssertTrue(shows("home-quiet", "Dependency audit"))

        // A chat chosen: the chats say new tasks start there.
        XCTAssertTrue((elements["home-chat"] ?? []).contains {
            $0.label.hasPrefix(L10n.string("Chats")) && $0.value == L10n.string("New tasks start here")
        }, report["home-chat"]!)
        XCTAssertTrue(shows("home-chat", L10n.string("What should we build?")))

        // Nothing to show: the recent tasks and the import links.
        XCTAssertTrue(shows("home-empty", L10n.string("Recent tasks")), report["home-empty"]!)
    }

    /// Compare active controls without making the test window key or visible. An unshown window's
    /// inactive borderless buttons are not evidence of the foreground app's text contrast.
    func testDesignAuditHomeWithActiveControls() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YARDLET_DESIGN_AUDIT"] == "1")
        let directory = try WindowlessRender.directory("design-audit/home-active")
        let runtimes = try runtimes()
        for width in [CGFloat(640), 1240] {
            let size = NSSize(width: width, height: 860)
            for appearance in WindowlessRender.Appearance.allCases {
                let view = home(.full, size: size, scheme: appearance.colorScheme, runtimes: runtimes, chat: false)
                    .environment(\.controlActiveState, .active)
                let host = WindowlessRender.Host(view, size: size, appearance: appearance)
                defer { host.close() }
                host.settle(passes: 10)
                XCTAssertFalse(host.window.isVisible)
                XCTAssertFalse(host.window.isKeyWindow)
                try WindowlessRender.writePNG(host.capture().bitmap,
                    to: directory.appending(path: "home-\(Int(width))-\(appearance.suffix).png"))
            }
        }
    }

    // MARK: - The desk

    private enum DeskDay { case busy, cleared, quiet }

    /// Words in the language the test process runs in, so a Korean run reads as a Korean person's day.
    private static func words(_ ko: String, _ en: String) -> String {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("ko") ? ko : en
    }

    /// The same 9 November as the desk's mock: two coordinators (one with four subtasks, one with one),
    /// a task running alone, an approval with a long command, a question, a coordinator's report, a
    /// pull request whose checks fail, a plan limit, two results just finished, three schedules and three
    /// unread threads. A subtask its coordinator already read is not on the desk. `cleared` is the same
    /// day after the last waiting line was handled; `quiet` has nothing waiting, running or unread.
    private func deskFixture(_ day: DeskDay) -> (fixture: Fixture, requestLines: [UUID: String]) {
        let w = Self.words
        let web = root.appending(path: "example-web", directoryHint: .isDirectory)
        let designKit = root.appending(path: "design-kit", directoryHint: .isDirectory)
        let chatFolder = root.appending(path: "chats/contract", directoryHint: .isDirectory)
        let yardlet = Project(name: "yardlet", primaryRoot: repository)
        let webProject = Project(name: "example-web", primaryRoot: web)
        let designProject = Project(name: "design-kit", primaryRoot: designKit)
        let calendar = Calendar.current
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 15, minute: 25))!
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func make(_ title: String, _ harness: HarnessKind = .claudeCode, in folder: URL, minutes: Double,
                  status: SessionStatus = .completed, unread: Bool = false, parent: SessionRecord? = nil,
                  parentRead: Bool = false) -> SessionRecord {
            SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/runtime"),
                          title: title, titleOrigin: .provider, status: status, updatedAt: ago(minutes),
                          hasUnreadUpdate: unread, isParentRead: parentRead,
                          completionState: status == .failed ? .failed : .completed, parentTaskID: parent?.id)
        }
        let busy = day == .busy, quiet = day == .quiet
        var details: [UUID: TaskAttentionDetail] = [:]
        var turns: [UUID: TaskLatestTurn] = [:]
        var answers: [UUID: String] = [:]
        var lines: [UUID: String] = [:]
        var sessions: [SessionRecord] = []

        let coordinator = make(w("Codex/Claude 코드 경험 개선", "Improve the Codex/Claude coding experience"),
                               in: repository, minutes: 12, unread: busy)
        answers[coordinator.id] = w("0.11.11 서명 빌드를 Pending에 올렸습니다. 설치하고 세 가지를 봐 주시면 됩니다.",
                                    "Staged the signed 0.11.11 build in Pending. Install it and check three things.")
        let reattach = make(w("원격 패널 터미널 다시 붙기", "Reattach the remote panel's terminal"), in: repository,
                            minutes: busy ? 2 : 1, status: busy ? .waitingForApproval : (quiet ? .completed : .running),
                            parent: coordinator)
        lines[reattach.id] = "git push -u origin remote-terminal-reattach && gh pr create --base main --head remote-terminal-reattach --title \"Reattach the remote panel's terminal after the host restarts\" --body-file /private/tmp/remote-terminal-reattach/pr-body.md --label bug --draft"
        let report = make(w("문제 신고 메뉴", "Report a Problem menu"), in: repository, minutes: 3,
                          status: quiet ? .completed : .running, parent: coordinator)
        turns[report.id] = TaskLatestTurn(startedAt: ago(32))
        let readTask = make(w("하위 작업 읽음 처리 (read_task·wait_tasks)", "Mark subtasks read after read_task"),
                            .codex, in: repository, minutes: 4, status: quiet ? .completed : .running, parent: coordinator)
        turns[readTask.id] = TaskLatestTurn(startedAt: ago(8))
        let android = make(w("Android 0.3.9 내부 트랙 출시 노트", "Android 0.3.9 internal track notes"), in: repository,
                           minutes: 30, unread: true, parent: coordinator, parentRead: true)
        sessions += [coordinator, reattach, report, readTask, android]

        let interest = make(w("오픈소스 공개 인기 가능성 조사", "Gauge interest in the open-source release"), in: repository,
                            minutes: 50)
        let feed = make(w("X 피드 정리", "Sort the X feed"), in: repository, minutes: 1,
                        status: quiet ? .completed : .running, parent: interest)
        turns[feed.id] = TaskLatestTurn(startedAt: ago(5))
        sessions += [interest, feed]

        let rates = make(w("요금 계산 API 정리 (vehicle rates)", "Tidy the vehicle rates API"), .codex, in: web, minutes: 1,
                         status: quiet ? .completed : .running)
        turns[rates.id] = TaskLatestTurn(startedAt: ago(21))
        let naming = make(w("탐색 메뉴 이름 정하기", "Name the archive menu"), .codex, in: repository, minutes: busy ? 6 : 1,
                          status: quiet ? .completed : .running)
        if busy { details[naming.id] = TaskAttentionDetail(pendingRequest: .input) }
        lines[naming.id] = w("보관한 작업을 모아 두는 메뉴 이름을 \u{201C}보관함\u{201D}과 \u{201C}보관된 작업\u{201D} 중 무엇으로 할까요?",
                             "Should the menu that collects archived tasks be called \u{201C}Archive\u{201D} or \u{201C}Archived tasks\u{201D}?")
        let blog = make(w("블로그 목록 첫 화면 속도", "Blog list first-load speed"), .codex, in: web, minutes: busy ? 25 : 1,
                        status: busy || quiet ? .completed : .running)
        let weekly = make(w("주간 리포트 정리", "Tidy the weekly report"), in: designKit, minutes: busy ? 41 : 1,
                          status: busy || quiet ? .completed : .running, unread: busy)
        if busy {
            details[weekly.id] = TaskAttentionDetail(usageLimit: HarnessRateLimit(
                status: .rejected, window: .session, resetsAt: calendar.date(byAdding: .hour, value: 2, to: now)))
        }
        let topic = make(w("블로그 소재 고르기", "Pick the next blog topic"), in: repository, minutes: 60, unread: !quiet)
        answers[topic.id] = w("준비된 소재 셋 가운데 \u{201C}중계가 LA에서 답한 이야기\u{201D}를 권합니다.",
                              "Of the three topics ready, I'd go with \u{201C}the relay that answered from LA\u{201D}.")
        let contract = make(w("계약 조항 비교", "Compare contract clauses"), in: chatFolder, minutes: 180, unread: !quiet)
        answers[contract.id] = w("두 해지 조항은 통지 기간(30일, 60일)만 다릅니다.",
                                 "The two termination clauses differ only in notice period (30 and 60 days).")
        sessions += [rates, naming, blog, weekly, topic]

        let monitor = TaskPullRequestMonitor()
        monitor.setPullRequest(pullRequest(48, checks: busy ? .failing : .pending), for: blog.id)

        func schedule(_ name: String, _ hour: Int, _ minute: Int, ran: Bool) -> (ScheduledTask, Date) {
            var task = ScheduledTask(name: name, prompt: "", trigger: .daily(ScheduleTime(hour: hour, minute: minute)),
                                     destination: ScheduleDestination(harness: .claudeCode))
            let slot = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today)!
            if ran {
                task.state.runs = [ScheduledTaskRun(slot: slot, at: slot, trigger: .scheduled, outcome: .started)]
                return (task, calendar.date(byAdding: .day, value: 1, to: slot)!)
            }
            return (task, slot)
        }
        let schedules = [schedule(w("홍보 확인 · 오전", "Promotion check · morning"), 10, 0, ran: true),
                         schedule(w("설계 검토 매일 평가", "Design review daily check"), 17, 40, ran: false),
                         schedule(w("홍보 확인 · 밤", "Promotion check · night"), 22, 0, ran: false)]

        let conversations: [UUID: [TranscriptEntry]] = [reattach.id: [
            TranscriptEntry(content: .user(text: w("PR을 열어 주세요", "Open the pull request"))),
            TranscriptEntry(content: .permission(PermissionRequest(
                id: "push", title: "Bash", detail: w("갈래를 올리고 초안 PR을 엽니다.", "Pushes the branch and opens a draft pull request."),
                command: lines[reattach.id], toolCallID: "toolu_push"), state: .pending)),
        ]]
        let names = [ProjectSidebarPresentation.normalizedPath(for: repository): "yardlet",
                     ProjectSidebarPresentation.normalizedPath(for: web): "example-web",
                     ProjectSidebarPresentation.normalizedPath(for: designKit): "design-kit"]
        func group(_ project: Project) -> WorkspaceGroup {
            WorkspaceGroup(workspaceURL: project.primaryRoot,
                           sessions: sessions.filter { Project.isSamePath($0.workspaceURL, project.primaryRoot) },
                           project: project)
        }
        let activity = NewTaskHomeActivity(
            sessions: sessions + [contract], details: details,
            placeName: { names[ProjectSidebarPresentation.normalizedPath(for: $0.workspaceURL)] ?? L10n.string("Chats") },
            groups: [group(yardlet), group(webProject), group(designProject)], chats: [contract],
            agents: { $0 == rates.id ? 1 : 0 }, schedules: schedules, now: today,
            answerLine: { answers[$0] }, latestTurn: { turns[$0] }, requestLine: { lines[$0.id] })
        return ((activity, monitor, [yardlet, webProject, designProject], names, conversations), lines)
    }

    /// Three unread threads in one inbox, read through the mailbox as the window's would be.
    private func deskMailbox() async throws -> MailboxCenter {
        let mail = MailFixture()
        let account = MailFixture.work.id
        let threads = [
            mail.single(account, "play", from: MailAddress(name: "Google Play Console", address: "play@example.com"),
                        date: mail.at(daysAgo: 0, hour: 9, minute: 10), subject: Self.words("Yardlet 0.3.8 내부 테스트 출시 완료",
                        "Yardlet 0.3.8 internal testing is live"), text: "", isUnread: true),
            mail.single(account, "issue", from: MailAddress(name: "GitHub", address: "notifications@github.example"),
                        date: mail.at(daysAgo: 0, hour: 11, minute: 2), subject: Self.words("[yardlet] 새 이슈 #631: 한글 입력 뒤 커서 위치",
                        "[yardlet] New issue #631: cursor after Korean input"), text: "", isUnread: true),
            mail.single(account, "maker", from: MailAddress(name: "Product Hunt", address: "hello@producthunt.example"),
                        date: mail.at(daysAgo: 0, hour: 8, minute: 0), subject: "Your weekly maker update", text: "",
                        isUnread: true),
            mail.single(account, "read", from: MailAddress(name: "Weekly Swift", address: "hello@weekly.example"),
                        date: mail.at(daysAgo: 0, hour: 7, minute: 0), subject: "Issue 412", text: ""),
        ]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("DeskMailbox")))
        let mailbox = MailboxCenter(defaults: defaults)
        mailbox.setEnabled(true)
        let transport = FixtureMailTransport(account: MailFixture.work, threads: threads)
        mailbox.setAccounts([(MailFixture.work, transport)])
        await mailbox.refresh()
        return mailbox
    }

    /// The desk at the widths a person's window gives the home (1,280 × 820 less a 240 pt sidebar,
    /// 1,800 × 1,125 less 351 pt, 980 × 760 less 240 pt), on a busy day, after the last waiting line was
    /// handled, on a quiet day and on the first day, in both appearances, into `.build/desk-qa/<language>/`.
    /// With the development switch off the home is as it was.
    func testTheDeskShowsWhatWaitsWhatRunsAndToday() async throws {
        let language = (Locale.preferredLanguages.first ?? "en").hasPrefix("ko") ? "ko" : "en"
        let directory = try WindowlessRender.directory("desk-qa/\(language)")
        let runtimes = try runtimes()
        let mailbox = try await deskMailbox()
        DeskPreview.show()
        defer { DeskPreview.hide() }
        let regular = NSSize(width: 1_040, height: 820), wide = NSSize(width: 1_449, height: 1_125)
        let narrow = NSSize(width: 740, height: 760)
        let scenes: [(name: String, day: DeskDay?, size: NSSize)] = [
            ("busy-1040", .busy, regular), ("busy-1449", .busy, wide), ("busy-740", .busy, narrow),
            ("cleared-1040", .cleared, regular), ("quiet-1040", .quiet, regular), ("first-run-1040", nil, regular),
        ]
        var elements: [String: [WindowlessRender.AccessibilityElement]] = [:]
        for scene in scenes {
            for appearance in WindowlessRender.Appearance.allCases {
                let fixture = scene.day.map { deskFixture($0).fixture }
                let view = home(scene.day == nil ? .empty : .full, fixture: fixture, size: scene.size,
                                scheme: appearance.colorScheme, runtimes: runtimes)
                    .environment(\.mailbox, mailbox)
                let host = WindowlessRender.Host(view, size: scene.size, appearance: appearance)
                defer { host.close() }
                host.settle(passes: 10)
                try WindowlessRender.writePNG(try host.capture().bitmap,
                                              to: directory.appending(path: "\(scene.name)-\(appearance.suffix).png"))
                if appearance == .light { elements[scene.name] = host.accessibilityElements() }
            }
        }
        let report = elements.mapValues { $0.map(\.description).joined(separator: "\n") }
        for (name, text) in report {
            try text.write(to: directory.appending(path: "\(name)-ax.txt"), atomically: true, encoding: .utf8)
        }
        func shows(_ scene: String, _ text: String) -> Bool {
            (elements[scene] ?? []).contains { $0.label.contains(text) || $0.value.contains(text) }
        }
        let w = Self.words
        // A busy day: five lines wait, four tasks run, two results just finished; the header says so.
        let busy = "busy-1040"
        XCTAssertTrue(shows(busy, L10n.format("%lld waiting", 5) + " · " + L10n.format("%lld running now", 4) + " · "
                                  + L10n.format("%lld left today", 2)), report[busy]!)
        XCTAssertTrue(shows(busy, "git push -u origin remote-terminal-reattach"), "The command to approve")
        XCTAssertTrue(shows(busy, w("보관한 작업을 모아 두는 메뉴 이름을", "Should the menu that collects archived tasks")),
                      "The question")
        XCTAssertTrue(shows(busy, L10n.string("Coordinator report")))
        XCTAssertTrue(shows(busy, w("0.11.11 서명 빌드를 Pending에 올렸습니다.", "Staged the signed 0.11.11 build")),
                      "The report's first line")
        XCTAssertTrue(shows(busy, L10n.format("Pull request #%lld: checks failed", 48)))
        XCTAssertTrue(shows(busy, L10n.format("%lld running in the family", 2)), "The coordinator's family by state")
        XCTAssertTrue(shows(busy, w("문제 신고 메뉴", "Report a Problem menu")), "Its members, with room")
        XCTAssertFalse(shows(busy, w("Android 0.3.9", "Android 0.3.9")), "A result its coordinator read is not on the desk")
        XCTAssertTrue(shows(busy, L10n.string("Just finished")))
        XCTAssertTrue(shows(busy, w("두 해지 조항은", "The two termination clauses")))
        XCTAssertTrue(shows(busy, w("설계 검토 매일 평가", "Design review daily check")), "Today's runs")
        XCTAssertTrue(shows(busy, "Google Play Console"), "Unread mail")
        XCTAssertFalse(shows(busy, "Issue 412"), "Read mail is not on the desk")
        XCTAssertTrue(shows(busy, L10n.string("Now")), "The view switch")
        // Narrow: one column, the families without their members.
        XCTAssertFalse(shows("busy-740", w("문제 신고 메뉴", "Report a Problem menu")), report["busy-740"]!)
        XCTAssertTrue(shows("busy-740", w("원격 패널 터미널 다시 붙기", "Reattach the remote panel's terminal")))
        // The last waiting line handled: the zone says nothing waits.
        XCTAssertTrue(shows("cleared-1040", L10n.string("Nothing is waiting on you")), report["cleared-1040"]!)
        // A quiet day: today and the composer.
        XCTAssertFalse(shows("quiet-1040", L10n.string("Waiting on you (home)")), report["quiet-1040"]!)
        XCTAssertTrue(shows("quiet-1040", L10n.string("Unread mail")))
        // The first day: the title and the composer, no view to switch to.
        XCTAssertFalse(shows("first-run-1040", L10n.string("Now")), report["first-run-1040"]!)
    }

    /// Choosing the approval's line answers it in the composer's place: its card shows the whole command
    /// the line cut short. Then the Projects view, with the header over today's project columns.
    func testTheDeskAnswersALineInTheComposersPlaceAndSwitchesToTheProjects() async throws {
        let language = (Locale.preferredLanguages.first ?? "en").hasPrefix("ko") ? "ko" : "en"
        let directory = try WindowlessRender.directory("desk-qa/\(language)")
        let runtimes = try runtimes()
        let mailbox = try await deskMailbox()
        DeskPreview.show()
        defer { DeskPreview.hide() }
        for (name, size) in [("reply-1040", NSSize(width: 1_040, height: 820)), ("reply-1449", NSSize(width: 1_449, height: 1_125))] {
            for appearance in WindowlessRender.Appearance.allCases {
                let fixture = deskFixture(.busy).fixture
                let host = WindowlessRender.Host(
                    home(fixture: fixture, size: size, scheme: appearance.colorScheme, runtimes: runtimes, reply: ReplyFixture())
                        .environment(\.mailbox, mailbox),
                    size: size, appearance: appearance)
                defer { host.close() }
                placeOffscreen(host)
                // The waiting line, which starts with its state; the family's member line carries the title too.
                let waiting = try XCTUnwrap(controls(in: host).first {
                    $0.label.hasPrefix(SidebarTaskStatus.awaitingApproval.homeName)
                        && $0.label.contains(Self.words("원격 패널 터미널 다시 붙기", "Reattach the remote panel's terminal"))
                })
                try clickThroughApp(waiting, in: host)
                host.settle(passes: 10)
                try WindowlessRender.writePNG(try host.capture().bitmap,
                                              to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
                let elements = host.accessibilityElements()
                let report = elements.map(\.description).joined(separator: "\n")
                XCTAssertTrue(elements.contains { $0.value == L10n.string("Approval required") }, report)
                XCTAssertTrue(elements.contains { $0.role == "AXStaticText" && $0.value.hasSuffix("--label bug --draft") },
                              "The card shows the whole command: \(report)")

                // The Projects view: today's project columns under the same header.
                let projects = try XCTUnwrap(controls(in: host, role: .radioButton).first { $0.label == L10n.string("Projects") },
                                             report)
                try click(projects, in: host)
                host.settle(passes: 10)
                if name == "reply-1040" {
                    try WindowlessRender.writePNG(try host.capture().bitmap,
                                                  to: directory.appending(path: "projects-1040-\(appearance.suffix).png"))
                }
                XCTAssertTrue(host.accessibilityElements().contains { $0.label.hasPrefix("example-web") },
                              "The project columns")
            }
        }
    }

    /// The Projects view is the home as it was under the header the desk shares, which counts its projects;
    /// the home opens on the view chosen last. Drawn beside the home without the development switch at the
    /// widths a person's window gives it, into `.build/desk-qa/<language>/`.
    func testTheProjectsViewIsTheHomeUnderTheHeader() throws {
        let language = (Locale.preferredLanguages.first ?? "en").hasPrefix("ko") ? "ko" : "en"
        let directory = try WindowlessRender.directory("desk-qa/\(language)")
        let runtimes = try runtimes()
        defer { DeskPreview.hide() }
        for size in [NSSize(width: 1_040, height: 820), NSSize(width: 1_449, height: 1_125)] {
            var names: [Bool: [String]] = [:]
            for switchOn in [false, true] {
                UserDefaults.yardlet.set(switchOn, forKey: DeskPreview.key)
                UserDefaults.yardlet.set(NewTaskHomeView.projects.rawValue, forKey: NewTaskHomeView.key)
                for appearance in WindowlessRender.Appearance.allCases {
                    let host = WindowlessRender.Host(home(size: size, scheme: appearance.colorScheme, runtimes: runtimes),
                                                     size: size, appearance: appearance)
                    defer { host.close() }
                    host.settle(passes: 10)
                    let name = "\(switchOn ? "projects" : "home")-\(Int(size.width))-\(appearance.suffix).png"
                    try WindowlessRender.writePNG(try host.capture().bitmap, to: directory.appending(path: name))
                    guard appearance == .light else { continue }
                    names[switchOn] = headerNames(in: host)
                    let elements = host.accessibilityElements()
                    let report = elements.map(\.description).joined(separator: "\n")
                    XCTAssertEqual(!controls(in: host, role: .radioButton).filter { $0.label == L10n.string("Projects") }.isEmpty,
                                   switchOn, report)
                    if switchOn {
                        XCTAssertTrue(elements.contains {
                            $0.label.contains(L10n.format("%lld projects", 6) + " · " + L10n.format("%lld open pull requests", 4)
                                              + " · " + L10n.format("%lld left for a while", 2))
                        }, "The header counts the projects, their pull requests and the ones left: \(report)")
                    }
                }
            }
            XCTAssertEqual(names[true], names[false], "The same projects in the same order")
        }
    }

    /// The keyboard goes through the desk as through the projects: Tab from the composer to the first line
    /// waiting on the person, Return answers it in the composer's place; ↓ past what waits reaches what
    /// runs, and Return opens it.
    func testTheKeyboardGoesThroughTheDesksZones() async throws {
        let runtimes = try runtimes()
        let mailbox = try await deskMailbox()
        DeskPreview.show()
        defer { DeskPreview.hide() }
        let size = NSSize(width: 1_040, height: 820)
        var opened: [String] = []
        let host = WindowlessRender.Host(
            home(fixture: deskFixture(.busy).fixture, size: size, scheme: .light, runtimes: runtimes, reply: ReplyFixture(),
                 onOpen: { opened.append($0.title) })
                .environment(\.mailbox, mailbox),
            size: size, appearance: .light)
        defer { host.close() }
        placeOffscreen(host)
        let field = try XCTUnwrap(views(NSTextField.self, in: host.hosting).first { $0.isEditable })

        XCTAssertTrue(host.window.makeFirstResponder(field))
        host.settle(passes: 4)
        try press("\t", keyCode: 48, in: host)
        for _ in 0..<5 { try press(down, keyCode: 125, in: host) }
        try press("\r", keyCode: 36, in: host)
        XCTAssertEqual(opened, [Self.words("요금 계산 API 정리 (vehicle rates)", "Tidy the vehicle rates API")],
                       "Past the five waiting lines, the first family; Return opens its task")

        XCTAssertTrue(host.window.makeFirstResponder(field))
        host.settle(passes: 4)
        try press("\t", keyCode: 48, in: host)
        try press("\r", keyCode: 36, in: host)
        host.settle(passes: 10)
        let elements = host.accessibilityElements()
        XCTAssertTrue(elements.contains { $0.value == L10n.string("Approval required") },
                      "The first waiting line is answered in the composer's place: "
                      + elements.map(\.description).joined(separator: "\n"))
    }

    // MARK: - In a window

    func testClicksAndTheKeyboardChooseAProjectOpenTasksAndReachTheFolderRows() throws {
        let runtimes = try runtimes()
        let draft = NewTaskDraft()
        var opened: [String] = []
        let size = NSSize(width: 1240, height: 860)
        let fixture = homeFixture()
        let projects = fixture.projects
        let host = WindowlessRender.Host(
            home(fixture: fixture, size: size, resizable: true, scheme: .light, runtimes: runtimes, draft: draft,
                 onOpen: { opened.append($0.title) }),
            size: size, appearance: .light)
        defer { host.close() }
        // Clicks reach a window the window server has: this one is transparent, far off every screen,
        // and the test app is never activated, so nothing comes to the front or takes the keyboard.
        host.window.alphaValue = 0
        host.window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        host.window.orderFrontRegardless()
        XCTAssertFalse(NSApplication.shared.isActive)
        host.settle(passes: 10)

        // A click on a project's name starts the new task there.
        try click(header("example-web", in: host), in: host)
        XCTAssertEqual(draft.projectID, projects[1].id)
        XCTAssertTrue(Project.isSamePath(try XCTUnwrap(draft.workspaceURL), projects[1].primaryRoot))
        XCTAssertTrue(controls(in: host).contains { $0.label.hasPrefix("example-web,") && $0.value == L10n.string("New tasks start here") })
        XCTAssertEqual(headerNames(in: host).first, "yardlet", "The projects keep their places")

        // A click on a line opens its task.
        try click(XCTUnwrap(controls(in: host).first { $0.label.contains("Summarize release notes") }), in: host)
        XCTAssertEqual(opened, ["Summarize release notes"])

        // A project left alone for a while: a click starts the new task there, a double-click opens the
        // task it was left at.
        try clickThroughApp(line("ledger-app", in: host), in: host)
        XCTAssertEqual(draft.projectID, projects[4].id)
        XCTAssertTrue(host.accessibilityElements().contains {
            $0.label.contains(L10n.format("What should we work on in %@?", "ledger-app"))
        }, "The title names it")
        try doubleClick(line("field-notes", in: host), in: host)
        XCTAssertEqual(opened.last, "Handle offline sync conflicts")

        // Tab from the composer to the first project's name; Return chooses it and gives the composer back.
        let field = try XCTUnwrap(views(NSTextField.self, in: host.hosting).first { $0.isEditable })
        XCTAssertTrue(host.window.makeFirstResponder(field))
        host.settle(passes: 4)
        try press("\t", keyCode: 48, in: host)
        XCTAssertFalse(host.window.firstResponder is NSTextView, "Tab moves to the projects")
        try press("\r", keyCode: 36, in: host)
        XCTAssertEqual(draft.projectID, projects[0].id)
        XCTAssertTrue(host.window.firstResponder is NSTextView, "Back in the composer")

        // Tab, ↓, Return: the first project's first line, the task waiting on the person.
        try press("\t", keyCode: 48, in: host)
        try press(down, keyCode: 125, in: host)
        try press("\r", keyCode: 36, in: host)
        XCTAssertEqual(opened.last, "Approve schema migration")

        // ↓ past every project reaches the folder's rows over the composer; the last fills the draft.
        XCTAssertTrue(host.window.makeFirstResponder(field))
        host.settle(passes: 4)
        try press("\t", keyCode: 48, in: host)
        for _ in 0..<40 { try press(down, keyCode: 125, in: host, passes: 1) }
        host.settle(passes: 4)
        try WindowlessRender.writePNG(try host.capture().bitmap, to: try WindowlessRender.directory("new-task-qa")
            .appending(path: "home-keyboard-folder-row-light.png"))
        try press("\r", keyCode: 36, in: host)
        XCTAssertEqual(draft.text, L10n.format("Fix the failing CI checks on %@: find out why they fail and fix them.",
                                               "feature/home"))
        XCTAssertTrue(host.window.firstResponder is NSTextView, "Back in the composer to send it")

        // Two columns at 1240 pt; one when the window narrows to 640 pt.
        XCTAssertEqual(Set(headerFrames(in: host).map { Int($0.minX) }).count, 2)
        host.window.setContentSize(NSSize(width: 640, height: 860))
        host.hosting.frame = NSRect(origin: .zero, size: NSSize(width: 640, height: 860))
        host.settle(passes: 10)
        XCTAssertEqual(Set(headerFrames(in: host).map { Int($0.minX) }).count, 1, "One column")
        try WindowlessRender.writePNG(try host.capture().bitmap, to: try WindowlessRender.directory("new-task-qa")
            .appending(path: "home-resized-narrow-light.png"))
    }

    // MARK: - Answering in the composer's place

    func testATaskIsAnsweredInTheComposersPlace() throws {
        let directory = try WindowlessRender.directory("new-task-qa")
        let runtimes = try runtimes()
        let wide = NSSize(width: 1240, height: 860), narrow = NSSize(width: 640, height: 860)
        let scenes: [(name: String, line: String, size: NSSize, dark: Bool)] = [
            ("home-reply-question-wide", "Pick a CLI flag name", wide, true),
            ("home-reply-approval-wide", "Approve schema migration", wide, true),
            ("home-reply-result-wide", "Summarize release notes", wide, false),
            ("home-reply-question-narrow", "Pick a CLI flag name", narrow, true),
            ("home-reply-approval-narrow", "Approve schema migration", narrow, true),
        ]
        var elements: [String: [WindowlessRender.AccessibilityElement]] = [:]
        for scene in scenes {
            for appearance in WindowlessRender.Appearance.allCases where appearance == .light || scene.dark {
                let host = WindowlessRender.Host(
                    home(size: scene.size, scheme: appearance.colorScheme, runtimes: runtimes, reply: ReplyFixture()),
                    size: scene.size, appearance: appearance)
                defer { host.close() }
                placeOffscreen(host)
                try click(line(scene.line, in: host), in: host)
                host.settle(passes: 10)
                try WindowlessRender.writePNG(try host.capture().bitmap, to: directory.appending(
                    path: "\(scene.name)-\(appearance.suffix).png"))
                if appearance == .light { elements[scene.name] = host.accessibilityElements() }
            }
        }
        let report = elements.mapValues { $0.map(\.description).joined(separator: "\n") }
        for (name, text) in report {
            try text.write(to: directory.appending(path: "\(name)-ax.txt"), atomically: true, encoding: .utf8)
        }
        func shows(_ scene: String, _ text: String) -> Bool {
            (elements[scene] ?? []).contains { $0.label.contains(text) || $0.value.contains(text) }
        }
        for scene in scenes.map(\.name) {
            // The task's own conversation and composer take the title's and the composer's place.
            XCTAssertTrue(shows(scene, L10n.string("Conversation preview")), report[scene]!)
            XCTAssertTrue(shows(scene, L10n.string("Open task")), scene)
            XCTAssertTrue(shows(scene, L10n.string("Close preview")), scene)
            XCTAssertFalse(shows(scene, L10n.format("What should we build in %@?", "yardlet")), scene)
            XCTAssertFalse(shows(scene, L10n.string("Another session is running here")), "\(scene): no folder rows")
        }
        // The task's own request cards, as its conversation draws them.
        XCTAssertTrue(shows("home-reply-question-wide", "What should the flag that sets the retry count be called?"),
                      report["home-reply-question-wide"]!)
        XCTAssertTrue(shows("home-reply-question-wide", "--max-retries"))
        XCTAssertTrue(shows("home-reply-approval-wide", L10n.string("Approval required")), report["home-reply-approval-wide"]!)
        XCTAssertTrue(shows("home-reply-approval-narrow", "swift run yardlet-index migrate --apply"),
                      report["home-reply-approval-narrow"]!)
    }

    func testAWaitingOrUnreadLineIsAnsweredWhereTheComposerIs() throws {
        let runtimes = try runtimes()
        let draft = NewTaskDraft()
        draft.text = "New task draft"
        let replies = ReplyFixture()
        var opened: [String] = []
        var read: [UUID] = []
        let size = NSSize(width: 1240, height: 860)
        let fixture = homeFixture()
        func task(_ title: String) throws -> SessionRecord {
            try XCTUnwrap(fixture.activity.sessions.first { $0.title == title })
        }
        let host = WindowlessRender.Host(
            home(fixture: fixture, size: size, resizable: true, scheme: .light, runtimes: runtimes, draft: draft,
                 reply: replies, onMarkRead: { read += $0 }, onOpen: { opened.append($0.title) }),
            size: size, appearance: .light)
        defer { host.close() }
        placeOffscreen(host)
        func shows(_ text: String) -> Bool {
            host.accessibilityElements().contains { $0.label.contains(text) || $0.value.contains(text) }
        }

        // A click on an unread result answers it here: its conversation and composer, which takes the
        // keyboard, under the line naming it. Nothing opens.
        try click(line("Summarize release notes", in: host), in: host)
        XCTAssertEqual(opened, [])
        XCTAssertTrue(shows(L10n.string("Conversation preview")))
        XCTAssertFalse(shows(L10n.format("What should we build in %@?", "yardlet")))
        XCTAssertTrue(host.window.firstResponder is NSTextView, "Its composer has the keyboard")

        // Sent from there, with the task's own draft: the next task needing attention, as ⌥⌘A picks it
        // (the approval), takes its place, and the result it left reads as read.
        let notes = try task("Summarize release notes"), approve = try task("Approve schema migration")
        replies.draft(notes.id).text = "Go ahead"
        host.settle(passes: 2)
        try press("\r", keyCode: 36, in: host, passes: 10)
        XCTAssertEqual(replies.sent.map(\.task), [notes.id])
        XCTAssertEqual(replies.sent.map(\.text), ["Go ahead"])
        XCTAssertEqual(read, [notes.id])
        XCTAssertTrue(shows("swift run yardlet-index migrate --apply"), "The approval's card in its place")
        XCTAssertTrue(host.window.firstResponder is NSTextView, "Its composer has the keyboard")
        XCTAssertEqual(draft.text, "New task draft", "The new task's draft stays as it was")

        // Answering its card goes on to the next as well: the question.
        try click(XCTUnwrap(controls(in: host).first { $0.label == L10n.string("Allow") }), in: host)
        XCTAssertEqual(replies.answered, ["migrate"])
        XCTAssertTrue(shows("What should the flag that sets the retry count be called?"), "The question's card in its place")

        // Tab goes to the lines at the answered task's own; Return there opens it.
        try press("\t", keyCode: 48, in: host)
        XCTAssertFalse(host.window.firstResponder is NSTextView, "Tab moves to the lines")
        try press("\r", keyCode: 36, in: host)
        XCTAssertEqual(opened, ["Pick a CLI flag name"])
        XCTAssertTrue(shows(L10n.format("What should we build in %@?", "yardlet")), "The new task's composer is back")

        // Tab, ↓, Return answers the first project's waiting task; Escape in its composer gives the new
        // task its composer and draft back, the task's draft kept apart.
        let field = try XCTUnwrap(views(NSTextField.self, in: host.hosting).first { $0.isEditable })
        XCTAssertTrue(host.window.makeFirstResponder(field))
        host.settle(passes: 4)
        try press("\t", keyCode: 48, in: host)
        try press(down, keyCode: 125, in: host)
        try press("\r", keyCode: 36, in: host)
        XCTAssertEqual(opened.count, 1, "Return answers it rather than opening it")
        XCTAssertTrue(shows(L10n.string("Approval required")))
        replies.draft(approve.id).text = "A reply to finish later"
        try press("\u{1b}", keyCode: 53, in: host)
        XCTAssertTrue(shows(L10n.format("What should we build in %@?", "yardlet")))
        XCTAssertEqual((host.window.firstResponder as? NSTextView)?.string, "New task draft")
        XCTAssertEqual(replies.draft(approve.id).text, "A reply to finish later")
        XCTAssertEqual(replies.sent.count, 1, "Escape sends nothing")

        // Choosing a project while answering is about the new task: its composer comes back there.
        try click(line("Pick a CLI flag name", in: host), in: host)
        try click(header("design-kit", in: host), in: host)
        XCTAssertTrue(shows(L10n.format("What should we work on in %@?", "design-kit")))
        XCTAssertFalse(shows(L10n.string("Conversation preview")))

        // A double-click opens; a running task's line opens it.
        try doubleClick(line("Blog list first-load speed", in: host), in: host)
        XCTAssertEqual(opened.last, "Blog list first-load speed")
        try click(line("Refactor sidebar rows", in: host), in: host)
        XCTAssertEqual(opened.last, "Refactor sidebar rows")
        XCTAssertFalse(NSApplication.shared.isActive, "Nothing took the person's screen")
    }

    // MARK: - Helpers

    /// A window the window server has, so clicks and keys reach it: transparent, far off every screen,
    /// and the test app is never activated, so nothing comes to the front or takes the keyboard.
    private func placeOffscreen(_ host: WindowlessRender.Host<some View>) {
        host.window.alphaValue = 0
        host.window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        host.window.orderFrontRegardless()
        XCTAssertFalse(NSApplication.shared.isActive)
        host.settle(passes: 10)
    }

    /// A project's line for the task with `title`.
    private func line(_ title: String, in host: WindowlessRender.Host<some View>) throws -> Control {
        try XCTUnwrap(controls(in: host).first { $0.label.contains(title) }, title)
    }

    private let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    private func press(_ characters: String, keyCode: UInt16, in host: WindowlessRender.Host<some View>,
                       passes: Int = 4) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: host.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        host.window.sendEvent(event)
        host.settle(passes: passes)
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ([root] + root.subviews.flatMap { views(NSView.self, in: $0) }).compactMap { $0 as? T }
    }

    private struct Control {
        let label: String
        let value: String
        /// In the window, top-left origin.
        let frame: NSRect
    }

    /// The buttons in the window with their frames, as assistive technologies find them (with the
    /// app's enhanced interface on, as a screen reader turns it on).
    private func controls(in host: WindowlessRender.Host<some View>,
                          role: NSAccessibility.Role = .button) -> [Control] {
        host.hosting.layoutSubtreeIfNeeded()
        return WindowlessRender.withAccessibilityTree {
            let windowFrame = host.window.frame
            var found: [Control] = []
            var visited = Set<ObjectIdentifier>()
            func visit(_ node: AnyObject) {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    guard visited.insert(ObjectIdentifier(child)).inserted else { continue }
                    if (child.accessibilityRole?() ?? nil) == role {
                        let screen = child.accessibilityFrame?() ?? .zero
                        found.append(Control(
                            label: (child.accessibilityLabel?() ?? nil) ?? "",
                            value: (((child.accessibilityValue?() as Any??) ?? nil) as? String) ?? "",
                            frame: NSRect(x: screen.minX - windowFrame.minX, y: windowFrame.maxY - screen.maxY,
                                          width: screen.width, height: screen.height)))
                    }
                    visit(child)
                }
            }
            visit(host.hosting)
            return found
        }
    }

    private static let projectNames = ["yardlet", "example-web", "design-kit", "web-app"]

    private func header(_ name: String, in host: WindowlessRender.Host<some View>) throws -> Control {
        try XCTUnwrap(controls(in: host).first { $0.label.hasPrefix(name + ",") || $0.label == name })
    }

    private func headerNames(in host: WindowlessRender.Host<some View>) -> [String] {
        controls(in: host).compactMap { control in
            Self.projectNames.first { control.label.hasPrefix($0 + ",") || control.label == $0 }
        }
    }

    private func headerFrames(in host: WindowlessRender.Host<some View>) -> [NSRect] {
        controls(in: host).filter { control in
            Self.projectNames.contains { control.label.hasPrefix($0 + ",") || control.label == $0 }
        }.map(\.frame)
    }

    private func click(_ control: Control, in host: WindowlessRender.Host<some View>, clickCount: Int = 1) throws {
        let point = NSPoint(x: control.frame.midX, y: host.window.frame.height - control.frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                pressure: type == .leftMouseUp ? 0 : 1))
            host.window.sendEvent(event)
            host.settle(passes: 3, interval: 0.02)
        }
        host.settle(passes: 6)
    }

    /// Two clicks through the app's event queue, as the window server delivers them, so the line reads
    /// the second one's click count from the app's current event. The app is not activated.
    private func doubleClick(_ control: Control, in host: WindowlessRender.Host<some View>) throws {
        try clickThroughApp(control, in: host, counts: [1, 2])
    }

    /// Clicks through the app's event queue, so the app's current event is the last of them (a click sent
    /// to the window leaves an earlier double-click there).
    private func clickThroughApp(_ control: Control, in host: WindowlessRender.Host<some View>,
                                 counts: [Int] = [1]) throws {
        let point = NSPoint(x: control.frame.midX, y: host.window.frame.height - control.frame.midY)
        for clickCount in counts {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: host.window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                    pressure: type == .leftMouseUp ? 0 : 1))
                NSApp.postEvent(event, atStart: false)
                if let next = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: Date(),
                                              inMode: .default, dequeue: true) {
                    NSApp.sendEvent(next)
                }
                host.settle(passes: 3, interval: 0.02)
            }
        }
        host.settle(passes: 6)
    }
}

/// The tasks' own conversations and composers as the window gives them to the home's reply
/// (`MainWindow.homeReplyContent`): each task's transcript in its conversation, its own draft and
/// keyboard focus, and what the person sent or answered there.
@MainActor
private final class ReplyFixture {
    private var drafts: [UUID: TaskComposerDraft] = [:]
    private var workspaces: [UUID: TaskWorkspaceState] = [:]
    private(set) var sent: [(task: UUID, text: String)] = []
    private(set) var answered: [String] = []

    func draft(_ id: UUID) -> TaskComposerDraft {
        if let draft = drafts[id] { return draft }
        let draft = TaskComposerDraft()
        drafts[id] = draft
        return draft
    }

    func workspace(_ id: UUID) -> TaskWorkspaceState {
        if let workspace = workspaces[id] { return workspace }
        let workspace = TaskWorkspaceState()
        workspaces[id] = workspace
        return workspace
    }

    func services(conversations: [UUID: [TranscriptEntry]]) -> NewTaskHomeReplyServices {
        NewTaskHomeReplyServices(
            content: { session, hooks in
                AnyView(ReplyTaskHost(
                    session: session, entries: conversations[session.id] ?? [], draft: self.draft(session.id),
                    workspace: self.workspace(session.id),
                    conversation: ConversationActions(
                        decide: { id, _ in self.answered.append(id) },
                        answer: { id, _ in self.answered.append(id) }
                    ).replying(hooks, waitsBeyond: { _ in false }),
                    composer: ComposerActions(send: { self.sent.append((session.id, $0.text)) }).replying(hooks)))
            },
            focus: { self.workspace($0).keyboardFocus.move(to: .chat) })
    }
}

/// A task's conversation and composer as a side-panel tab draws them (conversation only).
private struct ReplyTaskHost: View {
    let session: SessionRecord
    let entries: [TranscriptEntry]
    let draft: TaskComposerDraft
    let workspace: TaskWorkspaceState
    let conversation: ConversationActions
    let composer: ComposerActions
    @FocusState private var focused: TaskSurface?

    var body: some View {
        TaskDetail(
            conversationOnly: true, session: session, composerDraft: draft, workspaceState: workspace,
            panelState: Binding(get: { workspace.panels }, set: { workspace.setPanels($0) }),
            focusedSurface: $focused, transcript: TaskTranscriptReader(entries), errorMessage: nil, codexTaskState: nil,
            codexHistorySelection: nil, codexQueue: [], codexCapabilities: .empty, providerCapabilities: nil,
            providerUsage: nil, isProviderAttached: true, onShowCodexCapabilities: {},
            conversationActions: conversation, composerActions: composer)
            .environment(\.taskKeyboardFocus, workspace.keyboardFocus)
    }
}

extension DeskPreview {
    /// The desk on the home: its switch on and "Now" the view. The home remembers the view the person
    /// chose, so a test that chose Projects would otherwise leave it to the next.
    static func show() {
        UserDefaults.yardlet.set(true, forKey: key)
        UserDefaults.yardlet.removeObject(forKey: NewTaskHomeView.key)
    }

    static func hide() {
        UserDefaults.yardlet.removeObject(forKey: key)
        UserDefaults.yardlet.removeObject(forKey: NewTaskHomeView.key)
    }
}
