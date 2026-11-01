import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The session rail drawn without a window on screen, a provider, an account, `gh` or user data,
/// into `.build/session-rail-qa/`, light and dark: every card open and folded for Claude Code, Codex
/// and OpenCode; the Changes card's pull request states; and a task with the rail beside its
/// conversation at wide and narrow widths, beside a side panel, and raised where it has no room.
@MainActor
final class SessionRailRenderingTests: XCTestCase {
    private typealias Fixtures = ComposerUnificationFixtures
    private static let folder = "session-rail-qa"

    // MARK: Fixtures

    private static func session(_ harness: HarnessKind, title: String = "Build the session rail") -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: URL(filePath: "/tmp/session-rail-qa/yardlet", directoryHint: .isDirectory),
                      runtimeExecutableURL: URL(filePath: "/tmp/\(harness.rawValue)"), title: title, status: .ready,
                      providerSessionID: "saved", providerOptions: ["permissionMode": "acceptEdits"])
    }

    private static let account = SessionRailAccount(name: "me@example.com", windows: [
        AccountLimitWindow(id: "5h", name: L10n.string("5 hour limit"), remainingPercent: 64,
                           resetsAt: Date().addingTimeInterval(2 * 3_600), evidence: .exactQuota),
        AccountLimitWindow(id: "7d", name: L10n.string("7 day limit"), remainingPercent: 81,
                           resetsAt: Date().addingTimeInterval(4 * 86_400), evidence: .exactQuota)
    ], checkedAt: Date().addingTimeInterval(-300))

    private static let connectors = ComposerConnectorList(rows: [
        .init(id: "n", name: "Notion", state: .needsAuthentication, toolCount: nil, source: .yardlet),
        .init(id: "l", name: "Linear", state: .connected, toolCount: 12, source: .yardlet),
        .init(id: "g", name: "github", state: .connected, toolCount: 40, source: .session),
        .init(id: "s", name: "Sentry", state: .connected, toolCount: 9, source: .session)
    ])

    private static let git = SessionRailGitInfo(branch: "feat/session-rail",
                                                branchURL: URL(string: "https://github.com/example/yardlet-macos/tree/feat/session-rail"),
                                                changes: GitChangeSummary(changedFiles: 7, additions: 412, deletions: 38,
                                                                          untrackedFiles: 2))

    private static func pullRequestState(_ json: String, logs: [String: PullRequestDetailCenter.TaskState.Log] = [:],
                                         problem: PullRequestCLIProblem? = nil) -> PullRequestDetailCenter.TaskState {
        var state = PullRequestDetailCenter.TaskState(url: PullRequestDetailTests.url, folder: URL(filePath: "/tmp"))
        state.detail = problem == nil ? GitHubPullRequestDetailParser.parse(Data(json.utf8)) : nil
        state.problem = problem
        state.mergeMethods = .all
        state.logs = logs
        return state
    }

    private static var failingState: PullRequestDetailCenter.TaskState {
        let json = PullRequestDetailTests.viewJSON(lintStatus: "COMPLETED", lintConclusion: "SUCCESS")
        let detail = GitHubPullRequestDetailParser.parse(Data(json.utf8))!
        return pullRequestState(json, logs: [detail.failedChecks[0].id: .loaded("""
            Run swift test --filter SessionRailTests
            Test Case 'SessionRailTests.testTheRailFits' started.
            SessionRailTests.swift:221: error: XCTAssertEqual failed: ("610") is not equal to ("611")
            Executed 16 tests, with 1 failure (0 unexpected) in 0.635 seconds
            Error: Process completed with exit code 1.
            """)])
    }

    private static let pullRequest = TaskPullRequest(number: 341, url: PullRequestDetailTests.url, repository: nil,
                                                     state: .open, checks: .failing, review: .changesRequested)

    private static func claudeContent(pullRequestState: PullRequestDetailCenter.TaskState? = nil,
                                      autoFix: PullRequestAutoFixRecord? = nil) throws -> SessionRailContent {
        let entries = try SessionRailTests.claudeEntries()
        let options = ComposerSessionOptionsProjection.make(
            harness: .claudeCode, session: session(.claudeCode), providerCapabilities: Fixtures.claudeLiveCapabilities,
            providerUsage: Fixtures.providerUsage, entries: entries, isAttached: true)
        return SessionRailContent.make(
            session: session(.claudeCode), projectName: "yardlet",
            instructionSources: TaskInstructionSources(origin: .detected, paths: ["/tmp/session-rail-qa/yardlet/CLAUDE.md",
                                                                                  "/tmp/session-rail-qa/yardlet/AGENTS.md"]),
            git: git, options: options, connectors: connectors, account: account, entries: entries, codexPlan: nil,
            pullRequest: pullRequest, pullRequestState: pullRequestState ?? failingState, autoFix: autoFix)
    }

    private static func codexContent() -> SessionRailContent {
        let codex = session(.codex, title: "Migrate the session index")
        var capabilities = CodexCapabilityState()
        capabilities.modelCatalog = Fixtures.codexCatalog
        let options = ComposerSessionOptionsProjection.make(
            harness: .codex, session: codex, codexCapabilities: capabilities, providerCapabilities: nil,
            providerUsage: nil, codexTokenUsage: Fixtures.codexTokenUsage, isAttached: true)
        let plan = CodexPlanState(explanation: nil, steps: [
            CodexPlanStep(id: "1", text: "Read the current index schema", status: .completed),
            CodexPlanStep(id: "2", text: "Write the migration and its test", status: .inProgress),
            CodexPlanStep(id: "3", text: "Run the full suite", status: .pending)
        ])
        return SessionRailContent.make(
            session: codex, projectName: "yardlet", instructionSources: TaskInstructionSources(origin: .provider,
                                                                                               paths: ["/tmp/AGENTS.md"]),
            git: SessionRailGitInfo(branch: "main", branchURL: nil, changes: GitChangeSummary(changedFiles: 2, additions: 30, deletions: 4)),
            options: options, connectors: connectors, account: account, entries: [], codexPlan: plan, pullRequest: nil,
            pullRequestState: nil)
    }

    private static func openCodeContent() -> SessionRailContent {
        let openCode = session(.openCode, title: "Tidy the README")
        let options = ComposerSessionOptionsProjection.make(
            harness: .openCode, session: openCode, providerCapabilities: Fixtures.acpCapabilities, providerUsage: nil,
            isAttached: true)
        return SessionRailContent.make(
            session: openCode, projectName: "yardlet", instructionSources: TaskInstructionSources(origin: .detected, paths: []),
            git: SessionRailGitInfo(branch: "main", branchURL: nil, changes: nil), options: options, connectors: nil,
            account: nil, entries: [], codexPlan: nil, pullRequest: nil, pullRequestState: nil)
    }

    private static func preferences() -> SessionRailPreferenceStore {
        SessionRailPreferenceStore(defaults: UserDefaults(suiteName: testDefaultsSuite("SessionRailRenderingTests"))!)
    }

    private func rail(_ content: SessionRailContent, folds: SessionRailFolds,
                      actions: SessionRailActions = SessionRailActions(pullRequest: SessionRailPullRequestActions()),
                      appearance: WindowlessRender.Appearance) -> some View {
        SessionRailView(content: content, folds: .constant(folds), preferences: Self.preferences(), actions: actions)
            .frame(height: 1500, alignment: .top)
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance.colorScheme)
    }

    private var everyCardOpen: SessionRailFolds {
        var folds = SessionRailFolds()
        folds.setAll(folded: false)
        return folds
    }

    // MARK: Cards

    func testEveryCardOpenAndFoldedForEachHarness() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let claude = try Self.claudeContent()
        let width = SessionRailPlacement.width
        try WindowlessRender.hostedInBothAppearances("cards-claude-open", in: directory,
                                                     size: NSSize(width: width, height: 1500), passes: 12) { appearance in
            rail(claude, folds: everyCardOpen, appearance: appearance)
        }
        try WindowlessRender.hostedInBothAppearances("cards-claude-default", in: directory,
                                                     size: NSSize(width: width, height: 900), passes: 12) { appearance in
            rail(claude, folds: SessionRailFolds(), appearance: appearance)
        }
        var allFolded = SessionRailFolds()
        allFolded.setAll(folded: true)
        try WindowlessRender.hostedInBothAppearances("cards-claude-folded", in: directory,
                                                     size: NSSize(width: width, height: 420), passes: 8) { appearance in
            rail(claude, folds: allFolded, appearance: appearance)
        }
        try WindowlessRender.hostedInBothAppearances("cards-codex-open", in: directory,
                                                     size: NSSize(width: width, height: 1100), passes: 12) { appearance in
            rail(Self.codexContent(), folds: everyCardOpen, appearance: appearance)
        }
        try WindowlessRender.hostedInBothAppearances("cards-opencode-open", in: directory,
                                                     size: NSSize(width: width, height: 620), passes: 12) { appearance in
            rail(Self.openCodeContent(), folds: everyCardOpen, appearance: appearance)
        }

        // The rail is named for assistive apps, and each header says its card and whether it is folded.
        let host = WindowlessRender.Host(rail(claude, folds: SessionRailFolds(), appearance: .light),
                                         size: NSSize(width: width, height: 900), appearance: .light)
        defer { host.close() }
        host.settle(passes: 8)
        let elements = host.accessibilityElements()
        XCTAssertTrue(elements.contains { $0.label == L10n.string("Session details") }, "\(elements)")
        let context = try XCTUnwrap(elements.first { $0.role == "AXButton" && $0.label == L10n.string("Context") })
        XCTAssertTrue(context.value.hasPrefix(L10n.string("Collapsed")), context.value)
        XCTAssertTrue(elements.contains { $0.role == "AXButton" && $0.label == L10n.string("Changes")
            && $0.value == L10n.string("Expanded") })
    }

    // MARK: Pull request

    func testTheChangesCardInEachPullRequestState() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        var on = PullRequestAutoFixRecord()
        on.choice = .on
        on.lastSentAt = Date().addingTimeInterval(-600)
        let states: [(String, PullRequestDetailCenter.TaskState, PullRequestAutoFixRecord?)] = [
            ("failing-log-question", Self.failingState, nil),
            ("running", Self.pullRequestState(PullRequestDetailTests.viewJSON()), PullRequestAutoFixRecord(choice: .off)),
            ("conflicts-auto-fix-on", Self.pullRequestState(PullRequestDetailTests.viewJSON(
                mergeState: "DIRTY", mergeable: "CONFLICTING", lintStatus: "COMPLETED", lintConclusion: "SUCCESS")), on),
            ("auto-merge-passing", Self.pullRequestState(PullRequestDetailTests.viewJSON(
                mergeState: "CLEAN", lintStatus: "COMPLETED", lintConclusion: "SUCCESS",
                autoMerge: #"{"mergeMethod":"SQUASH"}"#, testConclusion: "SUCCESS")), PullRequestAutoFixRecord(choice: .off)),
            ("no-gh", Self.pullRequestState("", problem: .notInstalled), nil)
        ]
        for (name, state, autoFix) in states {
            let content = try Self.claudeContent(pullRequestState: state, autoFix: autoFix)
            var folds = SessionRailFolds()
            folds.setAll(folded: true)
            folds.setFolded(.changes, false)
            try WindowlessRender.hostedInBothAppearances("changes-\(name)", in: directory,
                                                         size: NSSize(width: SessionRailPlacement.width, height: 900),
                                                         passes: 12) { appearance in
                rail(content, folds: folds, appearance: appearance)
            }
        }
        XCTAssertTrue(try Self.claudeContent(pullRequestState: Self.failingState).changes?.asksAboutAutoFix == true)
        XCTAssertFalse(try Self.claudeContent(pullRequestState: Self.failingState, autoFix: on).changes?.asksAboutAutoFix == true)
    }

    // MARK: Beside the conversation

    func testTheRailBesideTheConversationWideNarrowWithAPanelAndRaised() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let cases: [(name: String, size: NSSize, panel: Bool, raised: Bool, shows: Bool)] = [
            ("task-wide", NSSize(width: 1240, height: 760), false, false, true),
            ("task-narrow-fits", NSSize(width: 700, height: 700), false, false, true),
            ("task-with-panel", NSSize(width: 1400, height: 760), true, false, true),
            // The panel's default leaves the rail its room where there is any (1100 − 777 ≥ 320) ...
            ("task-panel-default-keeps-rail", NSSize(width: 1100, height: 700), true, false, true),
            // ... and where there is none, the panel opens at the Codex app's default and the rail goes.
            ("task-panel-no-room", NSSize(width: 1000, height: 700), true, false, false),
            ("task-narrow-raised", NSSize(width: 600, height: 700), false, true, false)
        ]
        for item in cases {
            var captured: [Bool] = []
            for appearance in WindowlessRender.Appearance.allCases {
                let fixture = try TaskRailFixture(panel: item.panel, raised: item.raised)
                let host = WindowlessRender.Host(fixture.view
                    .frame(width: item.size.width, height: item.size.height)
                    .background(ParityTheme.canvas)
                    .environment(\.colorScheme, appearance.colorScheme),
                    size: item.size, appearance: appearance)
                host.settle(passes: 30, interval: 0.04)
                try WindowlessRender.writePNG(host.capture().bitmap,
                                              to: directory.appending(path: "\(item.name)-\(appearance.suffix).png"))
                captured.append(fixture.window.visibility.isInline(fixture.session.id))
                if item.raised { XCTAssertTrue(fixture.window.visibility.isRaised(fixture.session.id)) }
                host.close()
            }
            XCTAssertEqual(captured, [item.shows, item.shows], item.name)
        }
    }
}

/// A Claude Code task with a short conversation, its rail's services, and optionally its side panel
/// open or its rail raised.
@MainActor
private struct TaskRailFixture {
    let session: SessionRecord
    let workspace = TaskWorkspaceState()
    let window = SessionRailWindowState()
    let entries: [TranscriptEntry]
    let details = PullRequestDetailCenter()
    let preferences = SessionRailPreferenceStore(defaults: UserDefaults(suiteName: testDefaultsSuite("TaskRailFixture"))!)

    init(panel: Bool, raised: Bool) throws {
        session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/session-rail-qa/yardlet", directoryHint: .isDirectory),
                                runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Build the session rail",
                                status: .ready, providerSessionID: "saved", providerOptions: ["permissionMode": "acceptEdits"])
        var builder = TranscriptBuilder()
        builder.appendUser("Show the details in a sidebar on the right, not a popover")
        entries = builder.entries + (try SessionRailTests.claudeEntries())
        if panel { workspace.setPanels(TaskSurfaceNavigationProjection.showing("files", in: workspace.panels)) }
        if raised { window.toggle(for: session.id) }
        details.setState({
            var state = PullRequestDetailCenter.TaskState(url: PullRequestDetailTests.url, folder: URL(filePath: "/tmp/session-rail-qa/yardlet", directoryHint: .isDirectory))
            state.detail = GitHubPullRequestDetailParser.parse(Data(PullRequestDetailTests.viewJSON(
                lintStatus: "COMPLETED", lintConclusion: "SUCCESS").utf8))
            return state
        }(), for: session.id)
    }

    var view: some View {
        FixtureHost(fixture: self)
    }

    struct FixtureHost: View {
        let fixture: TaskRailFixture
        @FocusState private var focused: TaskSurface?

        var body: some View {
            let workspace = fixture.workspace
            TaskDetail(
                session: fixture.session, composerDraft: TaskComposerDraft(), workspaceState: workspace,
                panelState: Binding(get: { workspace.panels }, set: { workspace.setPanels($0) }),
                focusedSurface: $focused, transcript: TaskTranscriptReader(fixture.entries), errorMessage: nil, codexTaskState: nil,
                codexHistorySelection: nil, codexQueue: [], codexCapabilities: .empty,
                providerCapabilities: ComposerUnificationFixtures.claudeLiveCapabilities,
                providerUsage: ComposerUnificationFixtures.providerUsage, isProviderAttached: true,
                onShowCodexCapabilities: {}, conversationActions: ConversationActions(showHarnessSettings: {}),
                composerActions: ComposerUnificationFixtures.claudeActions)
            .environment(\.taskKeyboardFocus, workspace.keyboardFocus)
            .environment(\.sessionRail, SessionRailServices(
                window: fixture.window,
                preferences: fixture.preferences,
                projectName: "yardlet",
                account: { SessionRailAccount(name: "me@example.com", windows: [
                    AccountLimitWindow(id: "5h", name: L10n.string("5 hour limit"), remainingPercent: 64, resetsAt: nil,
                                       evidence: .exactQuota)]) },
                pullRequest: TaskPullRequest(number: 341, url: PullRequestDetailTests.url, repository: nil, state: .open,
                                             checks: .failing),
                details: fixture.details,
                readGit: nil,
                git: SessionRailGitInfo(branch: "feat/session-rail", branchURL: nil,
                                        changes: GitChangeSummary(changedFiles: 7, additions: 412, deletions: 38))))
        }
    }
}
