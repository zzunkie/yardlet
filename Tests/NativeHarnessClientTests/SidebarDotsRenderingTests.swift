import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The sidebar's Claude-style status dots and nested sessions drawn offscreen into
/// `.build/sidebar-dots-qa`, light and dark, in the 240 pt sidebar. No provider, process, window
/// server interaction, or app launch.
///
/// - `states-*.png`: one row per state across harnesses (Claude Code, Codex, OpenCode over ACP,
///   Cursor and Antigravity headless, Pi RPC, Kimi): approval and question dots (one for a question a
///   restart cut off, with no turn running), a failed turn, a plan limit, a running task with its CPU,
///   an unread result, a pull request and an idle task; a split view; two collapsed projects
///   summarizing by the most urgent.
/// - `families-*.png`: a pinned family, an expanded family with a grandchild, a collapsed family
///   keeping a waiting task and counting the rest, a collapsed family counting all, a task whose
///   parent is archived at top level, and a family under Chats.
@MainActor
final class SidebarDotsRenderingTests: XCTestCase {
    private let now = Date()
    private var minutes = 0.0
    private let monitor = TaskResourceMonitor(table: FakeProcessTable())
    private let pullRequests = TaskPullRequestMonitor()

    private func task(_ title: String, _ harness: HarnessKind, in folder: URL, status: SessionStatus = .ready,
                      completion: SessionCompletionState = .none, unread: Bool = false, pinned: Bool = false,
                      parent: SessionRecord? = nil) -> SessionRecord {
        minutes += 1
        return SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/agent"),
                             title: title, titleOrigin: .provider, status: status,
                             updatedAt: now.addingTimeInterval(-minutes * 60), hasUnreadUpdate: unread,
                             completionState: completion, isPinned: pinned, parentTaskID: parent?.id)
    }

    private func sidebar(projects: ProjectStore, sessions: [SessionRecord], chats: [SessionRecord] = [],
                         details: [UUID: TaskAttentionDetail], splits: [SplitGroup] = [], collapsed: Set<String> = [],
                         selected: SessionRecord?, waiting: Set<UUID> = [],
                         archivedParents: [UUID: UUID] = [:]) -> some View {
        let groups = projects.visibleGroups(sessions: sessions)
        let selection = selected.map { WindowItem.session($0.id) } ?? .home
        let disclosure = SidebarDisclosureStore(defaults: UserDefaults(suiteName: testDefaultsSuite("SidebarDots"))!)
        for key in collapsed { disclosure.collapse(key) }
        let layout = SidebarProjection.layout(
            visibleGroups: groups, allGroups: groups, chats: chats, splits: splits, isFiltering: false,
            disclosure: SidebarDisclosure(collapsedKeys: collapsed), selection: selection, waiting: waiting,
            archivedParents: archivedParents)
        return TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: selection,
            searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
            projects: projects, onEditProject: { _ in },
            onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
            onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
            disclosure: disclosure)
            .environment(monitor)
            .environment(pullRequests)
            .environment(\.taskAttentionDetails, details)
    }

    private func render(_ name: String, height: CGFloat, _ view: some View) throws -> [WindowlessRender.AccessibilityElement] {
        let directory = try WindowlessRender.directory("sidebar-dots-qa")
        let size = NSSize(width: ParityTheme.sidebarWidth, height: height)
        let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size) { appearance in
            view
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.sidebar)
        }
        for capture in captures {
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
        }
        let host = WindowlessRender.Host(view.frame(width: size.width, height: size.height, alignment: .top), size: size)
        defer { host.close() }
        host.settle()
        return host.accessibilityElements()
    }

    func testEveryStateIsADotOrAMarkAcrossHarnesses() throws {
        let yardlet = URL(filePath: "/tmp/sidebar-dots-qa/yardlet", directoryHint: .isDirectory)
        let website = URL(filePath: "/tmp/sidebar-dots-qa/website", directoryHint: .isDirectory)
        let docs = URL(filePath: "/tmp/sidebar-dots-qa/docs", directoryHint: .isDirectory)
        let projects = ProjectStore()
        _ = projects.ensureProject(forRoot: yardlet)
        let websiteProject = projects.ensureProject(forRoot: website, name: "Website")
        let docsProject = projects.ensureProject(forRoot: docs, name: "Docs")
        let approval = task("Approve the index migration", .claudeCode, in: yardlet, status: .waitingForApproval)
        let question = task("Pick the icon set for the toolbar", .codex, in: yardlet, status: .running)
        // A question a restart cut off: no turn runs, and the task waits for the answer all the same.
        let askedAgain = task("Choose the first settings fix", .claudeCode, in: yardlet, unread: true)
        let failed = task("Fix the flaky sampler test", .openCode, in: yardlet, status: .failed, completion: .failed)
        // A turn a lost connection cut off, continuing once the network is back.
        let offline = task("Push the release notes", .claudeCode, in: yardlet, status: .failed, completion: .failed)
        let limited = task("Run the full test suite", .claudeCode, in: yardlet, status: .completed, completion: .completed)
        let running = task("Build the release bundle", .cursorAgent, in: yardlet, status: .running)
        let unread = task("Summarize the crash reports", .pi, in: yardlet, status: .completed, completion: .completed,
                          unread: true)
        let withPR = task("Polish the onboarding copy", .codex, in: yardlet, status: .completed, completion: .completed)
        let idle = task("Tidy the README", .kimiCode, in: yardlet)
        let headless = task("Translate the release notes", .antigravityCLI, in: yardlet, status: .running)
        let splitLeft = task("Compare the parsers", .claudeCode, in: yardlet, status: .failed, completion: .failed)
        let splitRight = task("Benchmark the parsers", .codex, in: yardlet, status: .running)
        let websiteWaiting = task("Regenerate the screenshots", .claudeCode, in: website, status: .waitingForApproval)
        let websiteRunning = task("Fix the footer links", .codex, in: website, status: .running)
        let docsLimited = task("Translate the guide", .claudeCode, in: docs, status: .completed, completion: .completed)
        let sessions = [approval, question, askedAgain, failed, offline, limited, running, unread, withPR, idle, headless, splitLeft,
                        splitRight, websiteWaiting, websiteRunning, docsLimited]
        let limit = HarnessRateLimit(status: .rejected, window: .session,
                                     resetsAt: Calendar.current.date(byAdding: .hour, value: 3, to: now))
        let details: [UUID: TaskAttentionDetail] = [
            question.id: TaskAttentionDetail(pendingRequest: .input),
            askedAgain.id: TaskAttentionDetail(idleRequest: .input),
            approval.id: TaskAttentionDetail(pendingRequest: .approval),
            failed.id: TaskAttentionDetail(errorMessage: "Stream closed before the response finished"),
            offline.id: TaskAttentionDetail(errorMessage: "API Error: Connection dropped (ECONNRESET)", isReconnecting: true),
            limited.id: TaskAttentionDetail(usageLimit: limit),
            docsLimited.id: TaskAttentionDetail(usageLimit: limit),
        ]
        let rightPane = SplitPane(sessionID: splitRight.id)
        let split = SplitGroup(isPinned: false, anchorSessionID: splitLeft.id,
            root: .branch(axis: .horizontal, children: [.pane(SplitPane(sessionID: splitLeft.id)), .pane(rightPane)],
                          fractions: [1, 1]),
            focusedPaneID: rightPane.id)
        monitor.describe = { owner in sessions.first { $0.id == owner.taskID }.map { ($0.harness, $0.title) } }
        monitor.apply([(running, 142.0), (websiteRunning, 64.0)].map { session, cpu in
            TaskResourceUsage(owner: .task(session.id), locations: [.yardlet], processCount: 4,
                              memoryBytes: 300 << 20, cpuPercent: cpu, isBusy: true)
        })
        pullRequests.setPullRequest(.init(number: 131, url: URL(string: "https://github.com/example/yardlet/pull/131")!,
                                          repository: nil, state: .open, checks: .failing), for: withPR.id)
        let collapsed: Set<String> = [
            SidebarProjection.disclosureKey(for: WorkspaceGroup(workspaceURL: website, sessions: [], project: websiteProject)),
            SidebarProjection.disclosureKey(for: WorkspaceGroup(workspaceURL: docs, sessions: [], project: docsProject)),
        ]
        let elements = try render("states", height: 720, sidebar(
            projects: projects, sessions: sessions, details: details, splits: [split], collapsed: collapsed, selected: idle))
        let spoken = elements.map { "\($0.label) = \($0.value)" }
        func says(_ title: String, _ state: String) -> Bool { spoken.contains { $0.contains(title) && $0.contains(state) } }
        XCTAssertTrue(says("Approve the index migration", L10n.string("Awaiting input")), spoken.description)
        XCTAssertTrue(says("Pick the icon set", L10n.string("Awaiting answer")), spoken.description)
        XCTAssertTrue(says("Push the release notes", L10n.string("Reconnecting")), spoken.description)
        XCTAssertTrue(says("Choose the first settings fix", L10n.string("Awaiting answer")), spoken.description)
        XCTAssertTrue(says("Fix the flaky sampler test", L10n.string("Task encountered a system error")), spoken.description)
        XCTAssertTrue(says("Run the full test suite", L10n.string("Session limit reached")), spoken.description)
        XCTAssertTrue(says("Build the release bundle", L10n.string("Running")), spoken.description)
        XCTAssertTrue(says("Build the release bundle", L10n.format("CPU %lld%%", 142)), spoken.description)
        XCTAssertTrue(says("Summarize the crash reports", L10n.string("Unread response")), spoken.description)
        XCTAssertTrue(says("Polish the onboarding copy", "131"), spoken.description)
        XCTAssertTrue(says("Translate the release notes", L10n.string("Running")), spoken.description)
        XCTAssertTrue(says("Website", L10n.string("Awaiting input")), spoken.description)
        XCTAssertTrue(says("Docs", L10n.string("Session limit reached")), spoken.description)
        XCTAssertFalse(spoken.contains { $0.contains("Approve the index migration") && $0.contains(L10n.string("Running")) })
    }

    func testNestedSessionsDrawUnderTheTaskTheyWereStartedFrom() throws {
        let yardlet = URL(filePath: "/tmp/sidebar-dots-qa/yardlet", directoryHint: .isDirectory)
        let projects = ProjectStore()
        _ = projects.ensureProject(forRoot: yardlet)
        let pinnedParent = task("Release checklist", .claudeCode, in: yardlet, pinned: true)
        let pinnedChild = task("Draft the notes", .claudeCode, in: yardlet, status: .running, pinned: true,
                               parent: pinnedParent)
        let parent = task("Coordinate the migration", .claudeCode, in: yardlet, status: .running)
        let childA = task("Approve the schema", .claudeCode, in: yardlet, status: .waitingForApproval, parent: parent)
        let childB = task("Rebuild the index", .claudeCode, in: yardlet, status: .running, parent: parent)
        let grandchild = task("Check the index sizes", .claudeCode, in: yardlet, status: .completed,
                              completion: .completed, unread: true, parent: childB)
        // Past `deepestNesting`, beside the task it was started from; and under an archived task, a
        // level in from the task that one was started from.
        let greatGrandchild = task("Compare the index sizes", .codex, in: yardlet, parent: grandchild)
        let archivedStep = task("Archived step", .claudeCode, in: yardlet, parent: childA)
        let afterArchivedStep = task("Verify the backfill", .codex, in: yardlet, status: .running, parent: archivedStep)
        let collapsedParent = task("Review the parser", .codex, in: yardlet, status: .completed, completion: .completed)
        let keptChild = task("Answer the API question", .codex, in: yardlet, status: .running, parent: collapsedParent)
        let hiddenFailed = task("Fuzz the lexer", .codex, in: yardlet, status: .failed, completion: .failed,
                                unread: true, parent: collapsedParent)
        let hiddenWorking = task("Profile the parser", .codex, in: yardlet, status: .running, parent: collapsedParent)
        let hiddenDone = task("Port the tests", .codex, in: yardlet, status: .completed, completion: .completed,
                              parent: collapsedParent)
        let quietParent = task("Plan the sprint", .openCode, in: yardlet)
        let quietChildren = (1...3).map { task("Sprint item \($0)", .openCode, in: yardlet, parent: quietParent) }
        let archivedParent = task("Archived parent", .claudeCode, in: yardlet)
        let orphan = task("Child of an archived task", .claudeCode, in: yardlet, status: .completed,
                          completion: .completed, parent: archivedParent)
        let chatRoot = ChatWorkspaces.yardletRoot(home: projects.chatWorkspaceHome).appending(path: "2026-10-15/new-chat")
        let chat = task("Ask about the release", .claudeCode, in: chatRoot)
        let chatChild = task("Look up the changelog", .claudeCode, in: chatRoot, status: .running, parent: chat)
        let sessions = [pinnedParent, pinnedChild, parent, childA, childB, grandchild, greatGrandchild,
                        afterArchivedStep, collapsedParent, keptChild, hiddenFailed, hiddenWorking, hiddenDone,
                        quietParent] + quietChildren + [orphan]
        let details: [UUID: TaskAttentionDetail] = [
            childA.id: TaskAttentionDetail(pendingRequest: .approval),
            keptChild.id: TaskAttentionDetail(pendingRequest: .input),
        ]
        let collapsed: Set<String> = [SidebarProjection.familyKey(for: collapsedParent.id),
                                      SidebarProjection.familyKey(for: quietParent.id)]
        let waiting: Set<UUID> = [childA.id, keptChild.id]

        let archivedParents = [archivedStep.id: childA.id]

        let groups = projects.visibleGroups(sessions: sessions)
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, chats: [chat, chatChild],
            splits: [], isFiltering: false, disclosure: SidebarDisclosure(collapsedKeys: collapsed),
            selection: .session(parent.id), waiting: waiting, archivedParents: archivedParents)
        XCTAssertEqual(layout.pinned.first?.children.map(\.title), ["Draft the notes"])
        let rows = layout.sections.flatMap(\.rows)
        let migration = try XCTUnwrap(rows.first { $0.title == "Coordinate the migration" })
        XCTAssertEqual(migration.children.map(\.title), ["Approve the schema", "Verify the backfill", "Rebuild the index",
                                                          "Check the index sizes", "Compare the index sizes"])
        XCTAssertEqual(migration.children.map { $0.familyPlace?.depth }, [1, 2, 1, 2, 2])
        XCTAssertEqual(rows.first { $0.title == "Review the parser" }?.children.map(\.title), ["Answer the API question"])
        XCTAssertEqual(rows.first { $0.title == "Review the parser" }?.hiddenChildren.count, 3)
        XCTAssertEqual(rows.first { $0.title == "Plan the sprint" }?.hiddenChildren.count, 3)
        XCTAssertTrue(rows.contains { $0.title == "Child of an archived task" && !$0.isNestedChild })
        XCTAssertEqual(layout.chats?.rows.first?.children.map(\.title), ["Look up the changelog"])

        let elements = try render("families", height: 780, sidebar(
            projects: projects, sessions: sessions, chats: [chat, chatChild], details: details, collapsed: collapsed,
            selected: parent, waiting: waiting, archivedParents: archivedParents))
        let spoken = elements.map { "\($0.label) = \($0.value)" }
        XCTAssertTrue(spoken.contains { $0.contains("Rebuild the index") && $0.contains(L10n.string("Nested session")) },
                      spoken.description)
        XCTAssertFalse(spoken.contains { $0.contains("Coordinate the migration") && $0.contains(L10n.string("Nested session")) })
        let more = SidebarFamilySummaryLine.accessibilityLabel(
            .init(sessions: 3, failed: 1, new: 1, working: 1), more: true)
        XCTAssertTrue(spoken.contains { $0.contains(more) }, spoken.description)
        XCTAssertTrue(spoken.contains { $0.contains(L10n.format("Show %@", L10n.format("%lld nested sessions", 3))) },
                      spoken.description)
    }

    // MARK: - Hover card

    /// 2026-10-23 user decision (the Codex app's hover card): a row's card opens after the pointer
    /// rests on it, moves to the next row at once, opens at once over the row's end, closes when the
    /// pointer leaves for neither the card nor a row and when the list scrolls, and opens the pull
    /// request on a click. SwiftUI reads hover from the real pointer, so the rows' reports
    /// (`rowHovered`, `rowLeft`) are made here with the rows' frames in the window; the scroll is the
    /// sidebar's own and the pull request line is pressed as a button. The card draws into
    /// `.build/sidebar-dots-qa/hover-card-*.png`, light and dark.
    func testAHoverCardShowsTheTaskBesideItsRow() async throws {
        let yardlet = URL(filePath: "/tmp/sidebar-dots-qa/yardlet", directoryHint: .isDirectory)
        let projects = ProjectStore()
        _ = projects.ensureProject(forRoot: yardlet, name: "Yardlet")
        let withPR = task("Polish the onboarding copy", .codex, in: yardlet, status: .completed, completion: .completed)
        let failed = task("Fix the flaky sampler test", .claudeCode, in: yardlet, status: .failed, completion: .failed)
        let plain = task("Tidy the README", .claudeCode, in: yardlet)
        let sessions = [withPR, failed, plain] + (1...30).map { task("Older task \($0)", .codex, in: yardlet) }
        let error = TaskAttentionDetail(errorMessage: "Stream closed before the response finished")
        let pullRequest = URL(string: "https://github.com/example/yardlet/pull/131")!
        pullRequests.setPullRequest(.init(number: 131, url: pullRequest, repository: nil, state: .open, checks: .failing),
                                    for: withPR.id)
        // A child an agent started, on the account automatic assignment picked.
        let limit = AccountUsageMetric(id: "claude:session:", label: L10n.format("%.0f hour limit", 5.0), usedFraction: 0.12,
                                       detail: "", resetsAt: Date().addingTimeInterval(3 * 3600), evidence: .exactQuota,
                                       windowMinutes: 300)
        let assignment = AccountAssignment(
            choice: AccountChoice(harness: .claudeCode, connection: nil, snapshot: HarnessAccountSnapshot(
                id: "claude-code", harness: .claudeCode, providerID: nil, state: .signedIn,
                accountLabel: "developer@example.test", detail: "", credentialOwner: "", checkedAt: Date(), usage: [limit],
                canLogin: false, canLogout: false)),
            origin: .automatic, headroom: AccountRouting.headroom(of: [limit], model: nil, now: Date()))
        let cards = [
            SidebarHoverCardContent(session: withPR, projectName: "Yardlet", status: nil, isScheduledRun: false,
                                    cpuPercent: nil, pullRequest: pullRequests.pullRequest(for: withPR.id)
                                        .flatMap(TaskPullRequestRowMark.init)),
            SidebarHoverCardContent(session: failed, projectName: "Yardlet",
                                    status: SidebarTaskIndicatorProjection.status(of: failed, detail: error),
                                    isScheduledRun: false, cpuPercent: nil, pullRequest: nil),
            SidebarHoverCardContent(session: plain, projectName: "Yardlet", status: nil, isScheduledRun: false,
                                    cpuPercent: nil, pullRequest: nil, accountAssignment: assignment)
        ]
        var opened: [URL] = []
        // Where the pointer is, which the card reads to tell a resting pointer from a moving one.
        var pointer = NSPoint.zero
        let state = SidebarHoverCardState(pointerLocation: { pointer })
        let size = NSSize(width: ParityTheme.sidebarWidth + 420, height: 420)
        func window(_ scheme: ColorScheme) -> some View {
            HStack(spacing: 0) {
                sidebar(projects: projects, sessions: sessions, details: [failed.id: error], selected: plain)
                    .frame(width: ParityTheme.sidebarWidth)
                    .background(ParityTheme.sidebar)
                ParityTheme.canvas
            }
            .coordinateSpace(.named(SidebarHoverCardMetrics.space))
            .overlay(alignment: .topLeading) {
                SidebarHoverCardLayer(state: state, onOpenPullRequest: { opened.append($0) })
            }
            .environment(\.sidebarHoverCard, state)
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height)
        }
        let directory = try WindowlessRender.directory("sidebar-dots-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(window(appearance.colorScheme), size: size, appearance: appearance)
            defer { host.close() }
            host.window.setFrameOrigin(NSPoint(x: 20_000, y: 20_000))
            host.window.orderFrontRegardless()
            host.settle(passes: 10)
            let rows = try rowFrames(cards.map(\.title), in: host)
            func hover(_ index: Int, atEnd: Bool = false) {
                pointer = NSPoint(x: rows[index].midX, y: rows[index].midY + (atEnd ? 1 : 0))
                state.rowHovered(cards[index], frame: rows[index], atEnd: atEnd)
            }
            func wait(_ duration: Duration) async {
                try? await Task.sleep(for: duration)
                host.settle(passes: 2, interval: 0.01)
            }
            let shown = { state.card?.content.title }
            // The window going in and out of use closes a card: let the ordering in settle first.
            await wait(.milliseconds(300))
            for card in cards { state.rowLeft(card.taskID) }

            // A rest opens the card beside its row; it does not open before.
            hover(0)
            XCTAssertNil(shown(), "Opened before the pointer rested")
            await wait(SidebarHoverCardTiming.openDelay + .milliseconds(150))
            XCTAssertEqual(shown(), "Polish the onboarding copy")
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "hover-card-pr-\(appearance.suffix).png"))
            // The next row's opens at once.
            state.rowLeft(withPR.id)
            hover(1)
            XCTAssertEqual(shown(), "Fix the flaky sampler test")
            await wait(.milliseconds(50))
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "hover-card-error-\(appearance.suffix).png"))
            // Onto the card it stays; off it, to neither the card nor a row, it closes.
            state.rowLeft(failed.id)
            state.cardHovered(true)
            await wait(SidebarHoverCardTiming.closeGrace + .milliseconds(100))
            XCTAssertEqual(shown(), "Fix the flaky sampler test")
            state.cardHovered(false)
            await wait(SidebarHoverCardTiming.closeGrace + .milliseconds(100))
            XCTAssertNil(shown())
            // Cold again, the row's end, where its buttons are, opens it at once.
            await wait(SidebarHoverCardTiming.warmInterval)
            hover(2, atEnd: true)
            XCTAssertEqual(shown(), "Tidy the README")
            await wait(.milliseconds(50))
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "hover-card-plain-\(appearance.suffix).png"))
            // The list's scroll closes it, and a row under the resting pointer opens none until it moves.
            let scroll = try XCTUnwrap(scrollView(in: host.hosting))
            await scrollList(scroll, to: 120, in: host)
            XCTAssertNil(shown(), "A scroll left the card open")
            state.rowHovered(cards[0], frame: rows[0], atEnd: true)
            XCTAssertNil(shown(), "A row under the resting pointer opened a card")
            await scrollList(scroll, to: 0, in: host)
            await wait(SidebarHoverCardTiming.warmInterval)
            // The pull request line opens the pull request and puts the card away.
            hover(0, atEnd: true)
            XCTAssertEqual(shown(), "Polish the onboarding copy")
            await wait(.milliseconds(50))
            try Self.withAccessibility {
                let line = try XCTUnwrap(pullRequestLine(in: host.hosting), "No pull request line in the card")
                XCTAssertEqual(line.accessibilityPerformPress?(), true)
            }
            host.settle(passes: 2)
            XCTAssertEqual(opened.last, pullRequest)
            XCTAssertNil(shown())
            state.rowLeft(withPR.id)
        }
        XCTAssertEqual(opened.count, 2)
    }

    /// Runs `body` with the application's accessibility tree built, as VoiceOver has it built.
    private static func withAccessibility<T>(_ body: () throws -> T) rethrows -> T {
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        let previous = (app.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?
            .takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                        with: attribute)
        defer {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                            with: NSNumber(value: previous), with: attribute)
        }
        return try body()
    }

    /// Each row titled as given, in the window's top-left space the card is placed in.
    private func rowFrames(_ titles: [String], in host: WindowlessRender.Host<some View>) throws -> [CGRect] {
        host.hosting.layoutSubtreeIfNeeded()
        let root = host.hosting, window = host.window, height = host.hosting.bounds.height
        return try Self.withAccessibility {
            var found: [String: CGRect] = [:]
            func visit(_ node: AnyObject) {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    let label = (child.accessibilityLabel?() ?? nil) ?? ""
                    if let title = titles.first(where: { label.hasPrefix($0) }), found[title] == nil,
                       let screen = child.accessibilityFrame?(), screen.height > 0 {
                        let frame = window.convertFromScreen(screen)
                        found[title] = CGRect(x: frame.minX, y: height - frame.maxY,
                                              width: frame.width, height: frame.height)
                    }
                    visit(child)
                }
            }
            visit(root)
            return try titles.map { try XCTUnwrap(found[$0], "No row \($0)") }
        }
    }

    /// The list scrolled to `y`, as its scroll view moves it.
    private func scrollList(_ scroll: NSScrollView, to y: CGFloat, in host: WindowlessRender.Host<some View>) async {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        try? await Task.sleep(for: .milliseconds(50))
        host.settle(passes: 2, interval: 0.01)
    }

    private func scrollView(in root: NSView) -> NSScrollView? {
        (root as? NSScrollView) ?? root.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    /// The card's pull request line, by what it says it opens.
    private func pullRequestLine(in root: NSView) -> AnyObject? {
        var found: AnyObject?
        func visit(_ node: AnyObject) {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] where found == nil {
                if ((child.accessibilityLabel?() ?? nil) ?? "") == L10n.format("Open pull request #%@", "131") {
                    found = child
                }
                visit(child)
            }
        }
        visit(root)
        return found
    }
}
