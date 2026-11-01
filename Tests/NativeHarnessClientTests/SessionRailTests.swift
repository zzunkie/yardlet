import Foundation
import SwiftUI
import XCTest
@testable import NativeHarnessClient
import YardletAgentTools

/// The session rail: its cards' order, hiding and folds and how
/// they are kept, the window's switch and the raised rail, where it fits, and which cards each
/// harness fills. No provider, process, `gh` or user data.
@MainActor
final class SessionRailTests: XCTestCase {
    private typealias Fixtures = ComposerUnificationFixtures

    // MARK: - Order and hiding

    func testTheDefaultOrderIsTheClaudeAppsAndEnvironmentCannotBeHidden() {
        var preferences = SessionRailPreferences()
        XCTAssertEqual(preferences.resolvedOrder, [
            .environment, .goal, .settings, .context, .usage, .connectors, .progress, .outputs, .changes, .servers,
            .suggestions, .agents, .backgroundTasks, .preview
        ])
        XCTAssertTrue(preferences.isDefault)
        preferences.setHidden(.environment, true)
        XCTAssertFalse(preferences.isHidden(.environment))
        preferences.setHidden(.usage, true)
        XCTAssertTrue(preferences.isHidden(.usage))
        XCTAssertFalse(preferences.isDefault)
        preferences.setHidden(.usage, false)
        XCTAssertTrue(preferences.isDefault)
        XCTAssertEqual(SessionRailCardKind.foldedByDefault, [.connectors, .context, .usage, .backgroundTasks])
    }

    /// A stored order that lacks a card a later build added gets it after the nearest card before it
    /// by default, as the Claude app puts a missing `servers` before `backgroundTasks`.
    func testAStoredOrderMissingACardGetsItInItsDefaultNeighbourhood() throws {
        let json = #"{"order":["changes","environment","backgroundTasks","settings"],"hidden":["usage","nonsense"]}"#
        let preferences = try JSONDecoder().decode(SessionRailPreferences.self, from: Data(json.utf8))
        // Suggested tasks, Agents and Preview, which later builds added, go after their default neighbours.
        XCTAssertEqual(preferences.resolvedOrder, [
            .changes, .servers, .suggestions, .agents, .environment, .goal, .backgroundTasks, .preview, .settings, .context, .usage,
            .connectors, .progress, .outputs
        ])
        XCTAssertEqual(preferences.hidden, [.usage], "an unknown card is dropped")
        let round = try JSONDecoder().decode(SessionRailPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(round, preferences)
    }

    func testDraggingAndMovingReorderAmongTheCardsShown() {
        var preferences = SessionRailPreferences()
        preferences.move(.changes, before: .settings)
        XCTAssertEqual(Array(preferences.resolvedOrder.prefix(4)), [.environment, .goal, .changes, .settings])
        preferences.move(.environment, before: nil)
        XCTAssertEqual(preferences.resolvedOrder.last, .environment)
        preferences.reset()
        XCTAssertEqual(preferences.resolvedOrder, SessionRailCardKind.defaultOrder)

        // Up and down pass over the cards the rail does not show.
        let shown: [SessionRailCardKind] = [.environment, .settings, .changes, .backgroundTasks]
        preferences.move(.changes, by: -1, among: shown)
        XCTAssertLessThan(preferences.resolvedOrder.firstIndex(of: .changes)!, preferences.resolvedOrder.firstIndex(of: .settings)!)
        XCTAssertGreaterThan(preferences.resolvedOrder.firstIndex(of: .changes)!, preferences.resolvedOrder.firstIndex(of: .environment)!)
        preferences.reset()
        preferences.move(.settings, by: 1, among: shown)
        let order = preferences.resolvedOrder
        XCTAssertEqual(order.firstIndex(of: .settings)!, order.firstIndex(of: .changes)! + 1)
        // Nothing moves past the ends.
        let before = preferences
        preferences.move(.environment, by: -1, among: shown)
        preferences.move(.backgroundTasks, by: 1, among: shown)
        XCTAssertEqual(preferences, before)
    }

    func testPreferencesAreKeptInYardletsDefaultsAndTheDefaultLeavesNothing() throws {
        let suite = testDefaultsSuite("SessionRailTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = SessionRailPreferenceStore(defaults: defaults)
        store.update { $0.setHidden(.connectors, true) }
        store.update { $0.move(.progress, before: .settings) }
        XCTAssertNotNil(defaults.data(forKey: SessionRailPreferenceStore.defaultsKey))
        let reopened = SessionRailPreferenceStore(defaults: defaults)
        XCTAssertEqual(reopened.preferences, store.preferences)
        XCTAssertTrue(reopened.preferences.isHidden(.connectors))
        reopened.update { $0.reset() }
        XCTAssertNil(defaults.data(forKey: SessionRailPreferenceStore.defaultsKey))
    }

    // MARK: - Folds

    func testFoldsRecordOnlyWhatDiffersFromEachCardsDefault() throws {
        var folds = SessionRailFolds()
        XCTAssertTrue(folds.isFolded(.context))
        XCTAssertTrue(folds.isFolded(.backgroundTasks))
        XCTAssertFalse(folds.isFolded(.environment))
        XCTAssertFalse(folds.isFolded(.changes))
        folds.setFolded(.context, false)
        folds.setFolded(.changes, true)
        XCTAssertEqual(folds.opened, [.context])
        XCTAssertEqual(folds.folded, [.changes])
        folds.setFolded(.context, true)
        folds.setFolded(.changes, false)
        XCTAssertTrue(folds.isDefault)

        // Option-click: every card at once.
        folds.setAll(folded: false)
        XCTAssertTrue(SessionRailCardKind.allCases.allSatisfy { !folds.isFolded($0) })
        folds.setAll(folded: true)
        XCTAssertTrue(SessionRailCardKind.allCases.allSatisfy { folds.isFolded($0) })
        let round = try JSONDecoder().decode(SessionRailFolds.self, from: JSONEncoder().encode(folds))
        XCTAssertEqual(round, folds)
    }

    /// Each task keeps its own folds with its panels, so they go when the task is archived or
    /// deleted; a task with default folds stores none.
    func testFoldsAreKeptPerTaskWithItsPanelState() {
        let repository = InMemoryTaskWorkspaceRepository()
        let store = TaskWorkspaceStore(repository: repository)
        let first = UUID()
        let second = UUID()
        store.state(for: first).railFolds.setFolded(.usage, false)
        store.state(for: second).railFolds.setFolded(.settings, true)
        store.persistNow()
        XCTAssertEqual(repository.snapshots[first]?.railFolds?.opened, [.usage])
        XCTAssertEqual(repository.snapshots[second]?.railFolds?.folded, [.settings])
        let reopened = TaskWorkspaceStore(repository: repository)
        XCTAssertFalse(reopened.state(for: first).railFolds.isFolded(.usage))
        XCTAssertTrue(reopened.state(for: first).railFolds.isFolded(.context))
        XCTAssertTrue(reopened.state(for: second).railFolds.isFolded(.settings))

        reopened.state(for: second).railFolds = SessionRailFolds()
        reopened.persistNow()
        XCTAssertNil(repository.snapshots[second]?.railFolds)
        reopened.remove(for: first)
        XCTAssertNil(repository.snapshots[first])
    }

    // MARK: - The window's switch

    func testTheToggleHidesAnInlineRailAndRaisesOneWithoutRoom() {
        let task = UUID()
        var visibility = SessionRailVisibility()
        XCTAssertTrue(visibility.isShown, "on by default, as the Claude app's")
        visibility.setFits(true, for: task)
        XCTAssertTrue(visibility.isInline(task))
        XCTAssertTrue(visibility.isOnScreen(task))

        // On screen beside the conversation: the toggle turns the window's switch off.
        visibility.toggle(for: task)
        XCTAssertFalse(visibility.isShown)
        XCTAssertFalse(visibility.isOnScreen(task))
        // Off: the toggle brings it back beside the conversation.
        visibility.toggle(for: task)
        XCTAssertTrue(visibility.isInline(task))
        XCTAssertFalse(visibility.isRaised(task))

        // The area narrows: the rail leaves the column and the button shows it as off.
        visibility.setFits(false, for: task)
        XCTAssertTrue(visibility.isShown)
        XCTAssertFalse(visibility.isOnScreen(task))
        // The toggle raises it over the task; the switch stays on.
        visibility.toggle(for: task)
        XCTAssertTrue(visibility.isRaised(task))
        XCTAssertTrue(visibility.isShown)
        // Toggled again, or dismissed, the raised rail goes and the switch stays.
        visibility.toggle(for: task)
        XCTAssertFalse(visibility.isRaised(task))
        XCTAssertTrue(visibility.isShown)
        visibility.toggle(for: task)
        visibility.dismissRaised()
        XCTAssertFalse(visibility.isOnScreen(task))

        // A raised rail whose area grows takes its place beside the conversation.
        visibility.toggle(for: task)
        visibility.setFits(true, for: task)
        XCTAssertNil(visibility.raisedTaskID)
        XCTAssertTrue(visibility.isInline(task))

        // With the switch off and no room, the toggle turns it on and raises it.
        var narrow = SessionRailVisibility(isShown: false)
        narrow.toggle(for: task)
        XCTAssertTrue(narrow.isShown)
        XCTAssertTrue(narrow.isRaised(task))
        narrow.forget(task)
        XCTAssertFalse(narrow.isOnScreen(task))
    }

    func testTheToggleTitleFollowsWhetherTheRailIsOnScreen() {
        let state = SessionRailWindowState()
        let task = UUID()
        state.setFits(true, for: task)
        XCTAssertEqual(state.toggleTitle(for: task), L10n.string("Hide session rail"))
        state.toggle(for: task)
        XCTAssertEqual(state.toggleTitle(for: task), L10n.string("Show session rail"))
        XCTAssertEqual(L10n.string("Show session rail", languageCode: "ko"), "세션 레일 표시")
        XCTAssertEqual(L10n.string("Hide session rail", languageCode: "ko"), "세션 레일 숨기기")
        XCTAssertEqual(TaskCommandShortcut.toggleSessionRail.key, KeyEquivalent("i"))
        XCTAssertEqual(TaskCommandShortcut.toggleSessionRail.modifiers, [.command, .control])
    }

    // MARK: - Where it fits

    /// The Claude app's widths (`My`): 611 pt for the conversation's side of the area alone, 771 pt
    /// beside an open side panel; a panel expanded over the conversation leaves none.
    func testTheRailFitsFrom611AloneAnd771BesideASidePanel() {
        XCTAssertFalse(SessionRailPlacement.fits(sessionWidth: 610, panelOpen: false))
        XCTAssertTrue(SessionRailPlacement.fits(sessionWidth: 611, panelOpen: false))
        XCTAssertFalse(SessionRailPlacement.fits(sessionWidth: 770, panelOpen: true))
        XCTAssertTrue(SessionRailPlacement.fits(sessionWidth: 771, panelOpen: true))

        func metrics(width: CGFloat, trailing: Bool, expanded: Bool = false, rail: Bool = true) -> TaskWorkspaceMetrics {
            TaskWorkspaceMetrics.resolve(size: CGSize(width: width, height: 700), trailing: trailing, terminal: false,
                                         preferredWidth: 420, preferredHeight: 240, expanded: expanded, rail: rail)
        }
        // Alone.
        XCTAssertFalse(metrics(width: 610, trailing: false).showsRail)
        let alone = metrics(width: 611, trailing: false)
        XCTAssertTrue(alone.showsRail)
        XCTAssertEqual(alone.railWidth, 280)
        XCTAssertEqual(alone.chatWidth, 331)
        // Beside a 420 pt panel and its 6 pt divider: 771 + 426.
        XCTAssertFalse(metrics(width: 1196, trailing: true).showsRail)
        let beside = metrics(width: 1197, trailing: true)
        XCTAssertTrue(beside.showsRail)
        XCTAssertEqual(beside.chatWidth, 491)
        XCTAssertEqual(beside.trailingWidth, 420)
        XCTAssertEqual(beside.chatWidth + beside.railWidth + 6 + beside.trailingWidth, 1197)
        // An expanded panel covers the conversation and the rail.
        XCTAssertFalse(metrics(width: 1600, trailing: true, expanded: true).showsRail)
        XCTAssertFalse(metrics(width: 1600, trailing: true, expanded: true).railFits)
        // The switch off: the area still says it has room, and the conversation keeps all of it.
        let off = metrics(width: 1000, trailing: false, rail: false)
        XCTAssertFalse(off.showsRail)
        XCTAssertTrue(off.railFits)
        XCTAssertEqual(off.chatWidth, 1000)
    }

    // MARK: - Cards per harness

    private func content(
        _ harness: HarnessKind, options: ComposerSessionOptions, entries: [TranscriptEntry] = [],
        connectors: ComposerConnectorList? = nil, account: SessionRailAccount? = nil, codexPlan: CodexPlanState? = nil,
        git: SessionRailGitInfo? = nil, pullRequest: TaskPullRequest? = nil, session: SessionRecord? = nil
    ) -> SessionRailContent {
        SessionRailContent.make(
            session: session ?? Fixtures.session(harness), projectName: "composer-unify-project",
            instructionSources: TaskInstructionSources(origin: .detected, paths: []), git: git, options: options,
            connectors: connectors, account: account, entries: entries, codexPlan: codexPlan, pullRequest: pullRequest,
            pullRequestState: nil)
    }

    func testAClaudeCodeTaskFillsSettingsContextConnectorsProgressAndBackgroundTasks() throws {
        let entries = try Self.claudeEntries()
        let options = ComposerSessionOptionsProjection.make(
            harness: .claudeCode, session: Fixtures.session(.claudeCode), providerCapabilities: Fixtures.claudeLiveCapabilities,
            providerUsage: Fixtures.providerUsage, entries: entries, isAttached: true)
        let connectors = ComposerConnectorList(rows: [
            .init(id: "a", name: "Linear", state: .connected, toolCount: 12, source: .yardlet),
            .init(id: "b", name: "Notion", state: .needsAuthentication, toolCount: nil, source: .yardlet),
            .init(id: "c", name: "github", state: .connected, toolCount: 40, source: .session)
        ])
        let account = SessionRailAccount(name: "me@example.com", windows: [
            AccountLimitWindow(id: "5h", name: "5 hour limit", remainingPercent: 64, resetsAt: nil, evidence: .exactQuota),
            AccountLimitWindow(id: "7d", name: "7 day limit", remainingPercent: 80, resetsAt: nil, evidence: .exactQuota)
        ])
        let rail = content(.claudeCode, options: options, entries: entries, connectors: connectors, account: account,
                           git: SessionRailGitInfo(branch: "feature/rail", branchURL: nil,
                                                   changes: GitChangeSummary(changedFiles: 3, additions: 40, deletions: 2)))
        XCTAssertEqual(rail.cards(SessionRailPreferences()),
                       [.environment, .settings, .context, .usage, .connectors, .progress, .outputs, .changes,
                        .backgroundTasks])
        XCTAssertEqual(rail.rollup(.environment), L10n.string("Local"))
        XCTAssertEqual(rail.environment.branch, "feature/rail")
        XCTAssertEqual(rail.rollup(.context), "60%")
        XCTAssertEqual(rail.meter(.context) ?? 0, 0.6, accuracy: 0.001)
        // Folded, the usage card says both windows the account has (2026-10-22: with both a 5-hour
        // and a weekly limit, both show when folded), and its single meter steps aside.
        XCTAssertEqual(rail.rollup(.usage), "5 hour 64% · 7 day 80%")
        XCTAssertNil(rail.meter(.usage))
        XCTAssertEqual(SessionRailContent.shortWindowName("5시간 한도"), "5시간")
        XCTAssertEqual(SessionRailContent.shortWindowName("5h limit"), "5h")
        XCTAssertEqual(rail.rollup(.connectors), L10n.string("1 needs reconnection"))
        XCTAssertEqual(rail.rollup(.progress), L10n.format("%lld of %lld", 1, 3))
        XCTAssertEqual(rail.progress?.plan.steps.map(\.text), ["Read the parser", "Fix the bug", "Run the tests"])
        XCTAssertEqual(rail.progress?.plan.steps.first { $0.id == rail.progress?.currentStepID }?.text, "Fix the bug")
        XCTAssertEqual(rail.rollup(.changes), L10n.format("%lld files", 3))
        XCTAssertEqual(rail.rollup(.backgroundTasks), L10n.format("%lld running", 1))
        XCTAssertEqual(rail.settings?.model?.menu.title, "Opus · High")
        XCTAssertNotNil(rail.settings?.permission)

        // Hidden cards leave; the environment stays.
        var preferences = SessionRailPreferences()
        for kind in SessionRailCardKind.allCases { preferences.setHidden(kind, true) }
        XCTAssertEqual(rail.cards(preferences), [.environment])
        // A Korean rollup reads in Korean order.
        XCTAssertEqual(String(format: L10n.string("%lld of %lld", languageCode: "ko"), 1, 3), "3개 중 1개")
    }

    func testACodexTaskShowsItsPlanAndItsContextButNoBackgroundTasksCard() {
        let options = ComposerSessionOptionsProjection.make(
            harness: .codex, session: Fixtures.session(.codex),
            codexCapabilities: { var state = CodexCapabilityState(); state.modelCatalog = Fixtures.codexCatalog; return state }(),
            providerCapabilities: nil, providerUsage: nil, codexTokenUsage: Fixtures.codexTokenUsage, isAttached: true)
        let plan = CodexPlanState(explanation: "Two steps", steps: [
            CodexPlanStep(id: "1", text: "Write the test", status: .completed),
            CodexPlanStep(id: "2", text: "Make it pass", status: .pending)
        ])
        let rail = content(.codex, options: options, codexPlan: plan)
        XCTAssertEqual(rail.cards(SessionRailPreferences()), [.environment, .settings, .context, .progress])
        XCTAssertEqual(rail.rollup(.progress), L10n.format("%lld of %lld", 1, 2))
        // Nothing in progress: the first pending step once one is done (the Claude app's rule).
        XCTAssertEqual(rail.progress?.currentStepID, "2")
        XCTAssertNotNil(rail.context?.fraction)
        XCTAssertNil(rail.backgroundTasks)
    }

    /// A harness that reports no context window, no connectors and no plan gets only the cards it
    /// has: no empty Context, Connectors or Progress card.
    func testAHarnessThatReportsLessGetsFewerCardsNotEmptyOnes() {
        let options = ComposerSessionOptionsProjection.make(
            harness: .openCode, session: Fixtures.session(.openCode), providerCapabilities: nil, providerUsage: nil,
            isAttached: false)
        let rail = content(.openCode, options: options)
        XCTAssertFalse(rail.has(.context))
        XCTAssertFalse(rail.has(.progress))
        XCTAssertFalse(rail.has(.usage))
        XCTAssertFalse(rail.has(.changes))
        XCTAssertFalse(rail.has(.backgroundTasks))
        XCTAssertTrue(rail.cards(SessionRailPreferences()).first == .environment)
        XCTAssertFalse(rail.cards(SessionRailPreferences()).contains(.goal))
    }

    func testAWorktreeTaskNamesItsWorktreeAndAPullRequestBringsTheChangesCard() {
        let worktree = SessionRecord(harness: .claudeCode,
                                     workspaceURL: URL(filePath: "/tmp/.yardlet/worktrees/yardlet/fix-parser"),
                                     runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Worktree task",
                                     originWorkspacePath: "/tmp/yardlet", worktreeName: "fix-parser",
                                     branch: "yardlet/fix-parser")
        let options = ComposerSessionOptions(harnessName: "Claude Code", input: HarnessComposerInputPolicy(harness: .claudeCode),
                                             submission: .providerInput)
        let pullRequest = TaskPullRequest(number: 42, url: URL(string: "https://github.com/o/r/pull/42")!, repository: nil,
                                          state: .open, checks: .failing)
        let rail = content(.claudeCode, options: options, pullRequest: pullRequest, session: worktree)
        XCTAssertEqual(rail.environment.locationTitle, L10n.string("Worktree"))
        XCTAssertEqual(rail.rollup(.environment), "fix-parser")
        XCTAssertEqual(rail.environment.branch, "yardlet/fix-parser")
        XCTAssertEqual(rail.rollup(.changes), "#42")
        XCTAssertTrue(rail.has(.changes))
    }

    func testAnAccountsFiveHourAndWeeklyWindowsComeFirst() {
        let snapshot = HarnessAccountSnapshot(
            id: "claude", harness: .claudeCode, providerID: nil, state: .signedIn, accountLabel: "me@example.com",
            accountOrganization: nil, accountPlan: nil, detail: "", credentialOwner: "", checkedAt: Date(timeIntervalSince1970: 10),
            usage: [
                AccountUsageMetric(id: "claude:opus", label: "Opus · 7 day limit", usedFraction: 0.5, detail: "", resetsAt: nil,
                                   evidence: .exactQuota),
                AccountUsageMetric(id: "claude:week", label: "7 day limit", usedFraction: 0.2, detail: "", resetsAt: nil,
                                   evidence: .exactQuota),
                AccountUsageMetric(id: "claude:session", label: "5 hour limit", usedFraction: 0.36, detail: "", resetsAt: nil,
                                   evidence: .exactQuota)
            ], canLogin: false, canLogout: false)
        let account = SessionRailAccount(choice: AccountChoice(harness: .claudeCode, connection: nil, snapshot: snapshot))
        XCTAssertEqual(account.name, "me@example.com")
        XCTAssertEqual(account.windows.map(\.id), ["claude:session", "claude:week"])
        XCTAssertEqual(account.windows.first?.remainingPercent ?? 0, 64, accuracy: 0.01)
    }

    // MARK: - Outputs

    /// The files a task wrote, newest first and once each: documents inside its folder, anything
    /// outside it, never the source files it edits; Codex's added files too.
    func testOutputsAreTheDocumentsTheTaskWroteNewestFirst() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Write the report")
        func apply(_ json: String) throws {
            for payload in projection.payloads(from: try ClaudeWireCodec().decodeLine(Data(json.utf8))) {
                builder.apply(payload)
            }
        }
        func write(_ id: String, _ path: String) throws {
            try apply(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"Write","input":{"file_path":"\#(path)","content":"x"}}]}}"#)
            try apply(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"File created successfully"}]}}"#)
        }
        let folder = Fixtures.workspace
        try write("w1", folder.appending(path: "docs/report.md").path(percentEncoded: false))
        try write("w2", folder.appending(path: "Sources/Parser.swift").path(percentEncoded: false))
        try write("w3", "/tmp/elsewhere/summary.txt")
        try write("w4", folder.appending(path: "docs/chart.png").path(percentEncoded: false))
        try write("w5", folder.appending(path: "docs/report.md").path(percentEncoded: false))
        // An Edit is a change, not an output; a running Write is not done yet.
        try apply(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"e1","name":"Edit","input":{"file_path":"\#(folder.appending(path: "docs/notes.md").path(percentEncoded: false))","old_string":"a","new_string":"b"}}]}}"#)
        try apply(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"e1","content":"ok"}]}}"#)
        try apply(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"w6","name":"Write","input":{"file_path":"/tmp/elsewhere/draft.md","content":"x"}}]}}"#)

        let outputs = SessionRailContent.outputs(entries: builder.entries, codexChanges: [], workspaceURL: folder)
        XCTAssertEqual(outputs.map(\.name), ["report.md", "chart.png", "summary.txt"])
        let options = ComposerSessionOptions(harnessName: "Claude Code", input: HarnessComposerInputPolicy(harness: .claudeCode),
                                             submission: .providerInput)
        let rail = content(.claudeCode, options: options, entries: builder.entries)
        XCTAssertTrue(rail.cards(SessionRailPreferences()).contains(.outputs))
        XCTAssertEqual(rail.rollup(.outputs), "3")

        let added = CodexChangeHandoff(id: "t:i:0", turnID: "t", itemID: "i", relativePath: "notes/plan.md", status: "add",
                                       verifiedURL: folder.appending(path: "notes/plan.md"), line: nil, column: nil)
        let updated = CodexChangeHandoff(id: "t:i:1", turnID: "t", itemID: "i", relativePath: "README.md", status: "update",
                                         verifiedURL: folder.appending(path: "README.md"), line: nil, column: nil)
        XCTAssertEqual(SessionRailContent.outputs(entries: [], codexChanges: [added, updated], workspaceURL: folder)
            .map(\.name), ["plan.md"])
    }

    /// The rail, the composer and its line of background tasks read a transcript's few entries they read
    /// (`SessionRailContent.reads`, gathered from each turn by `TranscriptTurns.railEntries`) and make of
    /// them what they make of the whole transcript: a long conversation's publication costs them what
    /// they show, not its history.
    func testTheRailMakesTheSameOfTheEntriesItReadsAsOfTheWholeTranscript() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        func apply(_ line: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: line)
            for payload in projection.payloads(from: try ClaudeWireCodec().decodeLine(data)) { builder.apply(payload) }
        }
        func call(_ id: String, _ name: String, _ input: [String: Any], result: String?) throws {
            try apply(["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": name,
                                                                      "input": input]]]])
            guard let result else { return }
            try apply(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id,
                                                                 "content": result]]]])
        }
        // Turns of plain work around everything the rail lists.
        for index in 0..<4 {
            builder.appendUser("Request \(index)")
            builder.apply(.assistantMessageCompleted("Looking at \(index)."))
            try call("bash-\(index)", "Bash", ["command": "swift build"], result: "ok")
        }
        builder.appendUser("Plan, delegate and suggest")
        try call("todo", "TodoWrite", ["todos": [["content": "Read", "status": "completed", "activeForm": "Reading"],
                                                 ["content": "Fix", "status": "in_progress", "activeForm": "Fixing"]]],
                 result: "Todos have been modified successfully")
        try call("doc", "Write", ["file_path": "/tmp/session-rail-notes/report.md", "content": "x"],
                 result: "File created successfully")
        try call("docs", "Agent", ["description": "Read the docs", "prompt": "Read docs/"], result: "The docs say so.")
        try call("survey", "Agent", ["description": "Survey", "prompt": "Survey", "run_in_background": true], result: nil)
        try apply(["type": "system", "subtype": "task_started", "task_id": "a-survey", "tool_use_id": "survey",
                   "description": "Survey", "task_type": "local_agent", "is_backgrounded": true])
        try call("shell", "Bash", ["command": "swift test", "run_in_background": true], result: nil)
        try apply(["type": "system", "subtype": "task_started", "task_id": "t-shell", "tool_use_id": "shell",
                   "description": "swift test", "task_type": "local_bash", "is_backgrounded": true])
        try call("run", "mcp__yardlet__run_agent", ["harness": "codex", "prompt": "Check the migration"],
                 result: "agent_id: \(UUID().uuidString)\nharness: codex · state: completed\n\nDone.")
        try call("spawn", "mcp__yardlet__spawn_task", ["title": "Remove the dead flag", "tldr": "It is never read.",
                                                       "prompt": "Delete the flag."],
                 result: TaskSuggestionToolCatalog.notedResult(taskID: "task_1a2b3c4d"))
        try call("edit", "Bash", ["command": "rm -rf build"], result: nil)
        builder.apply(.permissionRequested(PermissionRequest(id: "ask", title: "Run", detail: nil, command: "rm -rf build",
                                                             toolCallID: "edit")))
        builder.apply(.assistantDelta("Waiting on you."))

        let all = builder.entries
        let read = TranscriptTurns(all).railEntries
        XCTAssertFalse(read.contains { entry in
            switch entry.content {
            case .user, .assistant: true
            case let .activity(activity, _): activity.id.hasPrefix("bash-")
            default: false
            }
        }, "The requests, answers and plain calls are not read")
        let session = Fixtures.session(.claudeCode)
        func rail(_ entries: [TranscriptEntry]) -> SessionRailContent {
            SessionRailContent.make(
                session: session, projectName: "p", instructionSources: TaskInstructionSources(origin: .detected, paths: []),
                git: nil, options: SessionRailAgentsTests.options(.claudeCode), connectors: nil, account: nil,
                entries: entries, codexPlan: nil, pullRequest: nil, pullRequestState: nil,
                suggestionResolution: { _ in nil })
        }
        let whole = rail(all)
        XCTAssertEqual(rail(read), whole)
        XCTAssertNotNil(whole.progress)
        XCTAssertEqual(whole.agents?.agents.count, 3)
        XCTAssertEqual(whole.suggestions.map(\.id), ["task_1a2b3c4d"])
        XCTAssertEqual(whole.outputs.map(\.name), ["report.md"])
        XCTAssertEqual(whole.backgroundTasks?.rows.map(\.id), ["shell"])
        for (agents, tasks) in [(true, true), (true, false), (false, true)] {
            XCTAssertEqual(BackgroundTasksProjection(entries: read, includesAgents: agents, includesTasks: tasks),
                           BackgroundTasksProjection(entries: all, includesAgents: agents, includesTasks: tasks))
        }
        XCTAssertEqual(ConversationSessionStatusProjection.pendingPermissionCount(in: read), 1)
        XCTAssertEqual(ComposerSessionOptionsProjection.make(harness: .claudeCode, session: session, providerCapabilities: nil,
                                                             providerUsage: nil, entries: read, isAttached: true),
                       ComposerSessionOptionsProjection.make(harness: .claudeCode, session: session, providerCapabilities: nil,
                                                             providerUsage: nil, entries: all, isAttached: true))
    }

    // MARK: - Git

    func testChangeSummaryCountsNumstatLinesOnceAndBinaryFilesWithoutLines() {
        let summary = GitChangeSummary(numstat: "3\t1\tSources/A.swift\n-\t-\tAssets/logo.png\n10\t0\tSources/A.swift\n")
        XCTAssertEqual(summary.changedFiles, 2)
        XCTAssertEqual(summary.additions, 13)
        XCTAssertEqual(summary.deletions, 1)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(GitChangeSummary(numstat: "").isEmpty)
    }

    func testGitHubRemotesGiveTheBranchPage() {
        XCTAssertEqual(GitHubRemote.webURL(fromRemote: "https://github.com/example/yardlet-macos.git")?.absoluteString,
                       "https://github.com/example/yardlet-macos")
        XCTAssertEqual(GitHubRemote.webURL(fromRemote: "git@github.com:example-org/web.git")?.absoluteString,
                       "https://github.com/example-org/web")
        XCTAssertEqual(GitHubRemote.webURL(fromRemote: "ssh://git@github.com/o/r")?.absoluteString, "https://github.com/o/r")
        XCTAssertNil(GitHubRemote.webURL(fromRemote: "https://gitlab.com/o/r.git"))
        let repository = URL(string: "https://github.com/o/r")!
        XCTAssertEqual(GitHubRemote.branchURL(repository: repository, branch: "feat/rail")?.absoluteString,
                       "https://github.com/o/r/tree/feat/rail")
    }

    // MARK: - Fixtures

    /// A Claude Code turn with a task list and a background shell, through the real wire projection.
    static func claudeEntries() throws -> [TranscriptEntry] {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Fix the parser bug")
        func apply(_ json: String) throws {
            for payload in projection.payloads(from: try ClaudeWireCodec().decodeLine(Data(json.utf8))) {
                builder.apply(payload)
            }
        }
        try apply(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"todo","name":"TodoWrite","input":{"todos":[{"content":"Read the parser","status":"completed","activeForm":"Reading"},{"content":"Fix the bug","status":"in_progress","activeForm":"Fixing"},{"content":"Run the tests","status":"pending","activeForm":"Running"}]}}]}}"#)
        try apply(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"todo","content":"Todos have been modified successfully"}]}}"#)
        try apply(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"doc","name":"Write","input":{"file_path":"/tmp/session-rail-notes/rail-design.md","content":"Rail notes"}}]}}"#)
        try apply(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"doc","content":"File created successfully"}]}}"#)
        try apply(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"shell","name":"Bash","input":{"command":"swift test","run_in_background":true}}]}}"#)
        try apply(#"{"type":"system","subtype":"task_started","task_id":"t-shell","tool_use_id":"shell","description":"swift test","task_type":"local_bash","is_backgrounded":true}"#)
        return builder.entries
    }
}
