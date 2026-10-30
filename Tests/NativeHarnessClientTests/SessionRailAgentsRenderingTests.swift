import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// The rail's Agents, Background tasks and Preview cards and what they open beside the task, drawn
/// without a provider, a process or user data into `.build/session-rail-agents-qa/`, light and dark;
/// and the window's own clicks on them: an agent's row opens its conversation in the side panel, its
/// request is answered from the rail, a shell's row opens its output, a child task's row goes to it.
@MainActor
final class SessionRailAgentsRenderingTests: XCTestCase {
    private static let folder = "session-rail-agents-qa"

    func testTheCardsOpenAndFolded() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let fixture = try AgentsRailFixture()
        let width = SessionRailPlacement.width
        var open = SessionRailFolds()
        open.setAll(folded: true)
        for kind: SessionRailCardKind in [.suggestions, .agents, .backgroundTasks, .preview] { open.setFolded(kind, false) }
        try WindowlessRender.hostedInBothAppearances("cards-agents-open", in: directory,
                                                     size: NSSize(width: width, height: 980), passes: 12) { appearance in
            fixture.rail(folds: open, appearance: appearance)
        }
        var folded = SessionRailFolds()
        folded.setAll(folded: true)
        try WindowlessRender.hostedInBothAppearances("cards-agents-folded", in: directory,
                                                     size: NSSize(width: width, height: 560), passes: 8) { appearance in
            fixture.rail(folds: folded, appearance: appearance)
        }
        try WindowlessRender.hostedInBothAppearances("cards-codex-agents-preview", in: directory,
                                                     size: NSSize(width: width, height: 760), passes: 12) { appearance in
            fixture.codexRail(folds: open, appearance: appearance)
        }
        XCTAssertEqual(fixture.content.rollup(.agents), L10n.string("Needs approval"))
        XCTAssertTrue(fixture.content.rollup(.backgroundTasks)?.hasSuffix(L10n.format("%lld scheduled", Int64(3))) == true)
        XCTAssertEqual(SessionJobText.title(AgentsRailFixture.sessionJobs[2]), "/loop babysit the PR")
        XCTAssertTrue(SessionJobText.detail(AgentsRailFixture.sessionJobs[0], now: Date())
            .hasPrefix(L10n.format("Every %lld minutes", Int64(15)) + " · " + L10n.format("Next run %@", "")),
                      "schedule, then the next run")
        XCTAssertEqual(SessionJobText.summary(cron: "7,22,37,52 * * * *"),
                       L10n.format("Every hour at minute %@", "7, 22, 37, 52"))
        XCTAssertNil(SessionJobText.summary(cron: "0 9 1 * *"), "a form the CLI does not name stays its own")
        XCTAssertEqual(fixture.content.cards(SessionRailPreferences()).suffix(3), [.suggestions, .agents, .backgroundTasks])
    }

    /// The request answered from the conversation leaves the rail too, so a person with the rail
    /// folded or hidden answers where it waits in the conversation.
    func testARequestAnsweredInTheConversationLeavesTheRail() throws {
        let fixture = try AgentsRailFixture()
        let size = NSSize(width: 1480, height: 820)
        let host = WindowlessRender.Host(fixture.taskView.frame(width: size.width, height: size.height), size: size,
                                         appearance: .light)
        defer { host.close() }
        host.settle(passes: 30, interval: 0.04)
        let response = try XCTUnwrap(fixture.request.responses.last)
        XCTAssertEqual(host.hosting.buttons(titled: response.title).count, 2)
        XCTAssertTrue(host.hosting.pressElement(outsideRail: true) { $0 == response.title }, "the conversation's button")
        host.settle(passes: 12, interval: 0.04)
        XCTAssertEqual(fixture.decisions.value.map(\.0), [fixture.request.id])
        XCTAssertEqual(host.hosting.buttons(titled: response.title).count, 0)
        XCTAssertEqual(fixture.content.agents?.agents.first { $0.title == "Check the migration" }?.status, .running)

        // With the rail hidden the request still waits in the conversation.
        let hidden = try AgentsRailFixture()
        hidden.window.visibility.isShown = false
        let second = WindowlessRender.Host(hidden.taskView.frame(width: size.width, height: size.height), size: size,
                                           appearance: .light)
        defer { second.close() }
        second.settle(passes: 30, interval: 0.04)
        XCTAssertFalse(hidden.window.visibility.isOnScreen(hidden.session.id))
        XCTAssertEqual(second.hosting.buttons(titled: response.title).count, 1, "the conversation's alone")
    }

    /// The window's own presses: an agent's row, its request's answer, a shell's row, a child task's row.
    func testTheRowsOpenTheirConversationsAnswerRequestsAndGoToChildTasks() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        for appearance in WindowlessRender.Appearance.allCases {
            let fixture = try AgentsRailFixture()
            // Background tasks starts folded, as in the Claude app; this task's person opened it.
            fixture.workspace.railFolds.setFolded(.backgroundTasks, false)
            let size = NSSize(width: 1480, height: 820)
            let host = WindowlessRender.Host(fixture.taskView
                .frame(width: size.width, height: size.height)
                .background(ParityTheme.canvas)
                .environment(\.colorScheme, appearance.colorScheme),
                size: size, appearance: appearance)
            defer { host.close() }
            host.settle(passes: 30, interval: 0.04)
            XCTAssertTrue(fixture.window.visibility.isInline(fixture.session.id), "The rail stands beside the conversation")
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "task-rail-\(appearance.suffix).png"))

            // The subagent's request waits both at the end of the conversation's turn and under its row;
            // answered from the rail, by the conversation's own route, it leaves both.
            let response = try XCTUnwrap(fixture.request.responses.last)
            XCTAssertEqual(host.hosting.buttons(titled: response.title).count, 2, "the conversation's and the rail's")
            XCTAssertTrue(host.hosting.pressElement { $0 == response.title }, "the rail's answer button")
            host.settle(passes: 12, interval: 0.04)
            XCTAssertEqual(fixture.decisions.value.first?.0, fixture.request.id)
            XCTAssertEqual(host.hosting.buttons(titled: response.title).count, 0, "answered in one place, gone in both")

            // The subagent's row opens its conversation over the side panel.
            XCTAssertTrue(host.hosting.pressElement { $0.hasPrefix("Check the migration") })
            // The conversation's card names the agent as its row does.
            XCTAssertTrue(host.hosting.labels().contains { $0.hasPrefix("Check the migration") && !$0.isEmpty })
            host.settle(passes: 20, interval: 0.04)
            XCTAssertEqual(fixture.workspace.panelDetail, .agentRun(fixture.run.id, title: "Check the migration"))
            XCTAssertEqual(fixture.workspace.panels.trailingSurfaceID, TaskPanelDetail.surfaceID)
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "task-agent-panel-\(appearance.suffix).png"))

            // A shell's row opens its output there instead.
            XCTAssertTrue(host.hosting.pressElement { $0.hasPrefix("swift test") })
            host.settle(passes: 20, interval: 0.04)
            XCTAssertEqual(fixture.workspace.panelDetail?.title, "swift test")
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "task-output-panel-\(appearance.suffix).png"))
            fixture.workspace.closePanelDetail()
            host.settle(passes: 6)
            XCTAssertNil(fixture.workspace.panels.trailingSurfaceID, "Closing returns to no side panel")

            // A child task's row goes to that task.
            XCTAssertTrue(host.hosting.pressElement { $0.hasPrefix("Port the parser") })
            XCTAssertEqual(fixture.opened.value, [fixture.child.id])
        }
    }

    /// The suggestions nobody has started or dismissed wait on the rail as well as in the conversation,
    /// and the two are one: Start on the rail starts it and the chip reads "Started", ✕ on the chip
    /// takes the rail's row too, and with none left the card is gone.
    func testASuggestionWaitsOnTheRailAndActsWithItsChip() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        for appearance in WindowlessRender.Appearance.allCases {
            let fixture = try AgentsRailFixture()
            XCTAssertEqual(fixture.content.suggestions.map(\.id), ["task_0000feed", "task_0000beef"])
            XCTAssertEqual(fixture.content.rollup(.suggestions), "2")
            XCTAssertEqual(fixture.content.cards(SessionRailPreferences()).suffix(3), [.suggestions, .agents, .backgroundTasks])
            let size = NSSize(width: 1480, height: 820)
            let host = WindowlessRender.Host(fixture.taskView
                .frame(width: size.width, height: size.height)
                .background(ParityTheme.canvas)
                .environment(\.colorScheme, appearance.colorScheme),
                size: size, appearance: appearance)
            defer { host.close() }
            host.settle(passes: 30, interval: 0.04)
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "task-rail-suggestions-\(appearance.suffix).png"))
            let start = L10n.string("Start")
            XCTAssertEqual(host.hosting.buttons(titled: start).count, 4, "two chips and two rail rows")

            // Start on the rail: the suggestion starts, its chip reads Started, and the rail keeps the other.
            XCTAssertTrue(host.hosting.pressElement { $0 == start })
            host.settle(passes: 12, interval: 0.04)
            XCTAssertEqual(fixture.startedSuggestions.value, ["task_0000feed"])
            XCTAssertEqual(host.hosting.buttons(titled: start).count, 2, "the other's chip and rail row")
            XCTAssertTrue(host.hosting.labels().contains(
                L10n.format("%@: %@", "Remove the dead retry flag", L10n.string("Started"))), "the chip says it started")
            XCTAssertEqual(fixture.content.suggestions.map(\.id), ["task_0000beef"])

            // ✕ on the chip in the conversation: the rail's row goes with it, and the card with its last row.
            let dismiss = L10n.format("Dismiss suggestion %@", "Split UploadQueue.swift")
            XCTAssertTrue(host.hosting.pressElement(outsideRail: true) { $0 == dismiss })
            host.settle(passes: 12, interval: 0.04)
            XCTAssertEqual(fixture.suggestions.resolution(of: "task_0000beef", in: fixture.session.id)?.outcome, .dismissed)
            XCTAssertEqual(host.hosting.buttons(titled: start).count, 0)
            XCTAssertFalse(host.hosting.labels().contains(dismiss))
            XCTAssertFalse(fixture.content.has(.suggestions))
        }
    }

    /// What a child task waits on the person for waits under its row on the rail of the task that
    /// started it, and is answered there by the child's own route: an approval its harness asks for,
    /// and the questions a Codex child's turn ended on, which its status alone does not show. A child
    /// task and a subagent that wait for room to start read "Pending", after the ones that wait on the
    /// person, and the subagent can be stopped there.
    func testAChildTasksWaitIsAnsweredFromTheRailOfTheTaskThatStartedIt() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let folder = URL(filePath: "/tmp/session-rail-agents-qa/notes-app", directoryHint: .isDirectory)
        let parent = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                   title: "Check the launch progress", status: .running, providerSessionID: "saved")
        let claudeChild = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                        title: "Save the Steam categories", status: .waitingForApproval, parentTaskID: parent.id)
        let codexChild = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                       title: "Set up Apple certificates and notarization", status: .ready, completionState: .completed,
                                       parentTaskID: parent.id)
        var builder = TranscriptBuilder()
        builder.appendUser("Save the screenshot categories")
        builder.apply(.permissionRequested(PermissionRequest(id: "perm-push", title: "Run git push origin release",
                                                             detail: nil, command: "git push origin release")))
        let request = try XCTUnwrap(TranscriptConversationProjection.presentation(
            from: builder.entries, harness: .claudeCode, status: .waitingForApproval, latestTurnIsComplete: false
        ).turns.last?.requests.first)
        let questions = [CodexAsyncQuestion(title: "Accept the new App Store Connect terms?",
                                            options: ["Accept and continue", "Skip the API key step"],
                                            itemID: CodexAsyncQuestionReply.itemID(messageID: "q1", index: 0))]
        let queuedChild = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                        title: "Translate the screenshot captions", createdAt: Date(), parentTaskID: parent.id)
        let queuedRun = SessionRailAgents.Run(id: UUID(), harness: .codex, model: "gpt-5.5", prompt: "Check the release notes",
                                              state: .queued, startedAt: Date())
        let children = [
            SessionRailAgents.Child(codexChild, wait: SessionRailAgents.Wait(questions: questions)),
            SessionRailAgents.Child(claudeChild, wait: SessionRailAgents.Wait(requests: [request], attention: .approval))
        ]
        func content(_ children: [SessionRailAgents.Child], runs: [SessionRailAgents.Run] = []) -> SessionRailContent {
            SessionRailContent.make(
                session: parent, projectName: "notes-app",
                instructionSources: TaskInstructionSources(origin: .detected, paths: []), git: nil,
                options: SessionRailAgentsTests.options(.claudeCode), connectors: nil, account: nil, entries: [],
                codexPlan: nil, pullRequest: nil, pullRequestState: nil, agentRuns: runs, childTasks: children)
        }
        let rail = content(children + [SessionRailAgents.Child(queuedChild, wait: nil, isQueued: true)], runs: [queuedRun])
        XCTAssertEqual(rail.rollup(.agents), L10n.string("Needs approval"))
        XCTAssertEqual(content([children[0]]).rollup(.agents), L10n.string("Needs input"), "Only a question waits")
        XCTAssertEqual(rail.agents?.agents.first { $0.kind == .childTask(codexChild.id) }?.waitingFor, .input)
        XCTAssertEqual(rail.agents?.agents.first { $0.kind == .childTask(claudeChild.id) }?.waitingFor, .approval)
        XCTAssertEqual(rail.agents?.agents.map(\.status), [.waiting, .waiting, .pending, .pending],
                       "A Codex turn that ended on a question waits; the queued ones follow")
        XCTAssertEqual(rail.agents?.agents.last?.canStop, true, "A queued subagent can be stopped")

        let preferences = SessionRailPreferenceStore(defaults: UserDefaults(suiteName: testDefaultsSuite("ChildWaits"))!)
        var folds = SessionRailFolds()
        folds.setAll(folded: true)
        folds.setFolded(.agents, false)
        for appearance in WindowlessRender.Appearance.allCases {
            let decisions = AgentsRailFixture.Box<[(UUID, String, PermissionDecision)]>([])
            let replies = AgentsRailFixture.Box<[(UUID, String)]>([])
            let actions = SessionRailActions(agents: SessionRailAgentActions(open: { _ in }, childRequests: { id in
                ConversationActions(decide: { requestID, decision in decisions.value.append((id, requestID, decision)) },
                                    answerQuestion: { replies.value.append((id, $0)) })
            }))
            let size = NSSize(width: SessionRailPlacement.width, height: 760)
            let host = WindowlessRender.Host(
                SessionRailView(content: rail, folds: .constant(folds), preferences: preferences, actions: actions)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .background(ParityTheme.canvas)
                    .environment(\.colorScheme, appearance.colorScheme)
                    .environment(\.harnessModelNames, HarnessModelNames(harness: .claudeCode)),
                size: size, appearance: appearance)
            defer { host.close() }
            host.settle(passes: 24, interval: 0.04)
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "child-waits-\(appearance.suffix).png"))

            let allow = try XCTUnwrap(request.responses.last)
            XCTAssertTrue(host.hosting.pressElement { $0 == allow.title }, "the approval under the Claude child's row")
            host.settle(passes: 8, interval: 0.04)
            XCTAssertEqual(decisions.value.map(\.0), [claudeChild.id], "It goes to the child, not the task")
            XCTAssertEqual(decisions.value.map(\.1), ["perm-push"])

            XCTAssertTrue(host.hosting.pressElement { $0 == "Skip the API key step" })
            host.settle(passes: 8, interval: 0.04)
            XCTAssertTrue(host.hosting.pressElement { $0 == L10n.string("Send") })
            host.settle(passes: 8, interval: 0.04)
            XCTAssertEqual(replies.value.map(\.0), [codexChild.id])
            let answered = CodexAsyncQuestionReply.answers(in: replies.value.first?.1 ?? "")
            XCTAssertEqual(answered?.map(\.answer), ["Skip the API key step"])
            XCTAssertEqual(answered?.map(\.questionItemID), [questions[0].itemID])
        }
    }
}

/// A Claude Code task with a background agent, a finished agent, a `run_agent` subagent waiting on
/// the person, a child task and a background shell, its rail beside its conversation.
@MainActor
private final class AgentsRailFixture {
    final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    let session: SessionRecord
    let child: SessionRecord
    let workspace = TaskWorkspaceState()
    let window = SessionRailWindowState()
    let preferences = SessionRailPreferenceStore(defaults: UserDefaults(suiteName: testDefaultsSuite("AgentsRailFixture"))!)
    let entries: [TranscriptEntry]
    let run: AgentRun
    let request: ConversationRequest
    let decisions = Box<[(String, PermissionDecision)]>([])
    /// What became of the task's two suggestions, as the window's chips and rail rows share it.
    let suggestions = TaskSuggestionStore(repository: InMemoryTaskSuggestionRepository())
    let startedSuggestions = Box<[String]>([])
    private var runBuilder: TranscriptBuilder

    /// What the app does with an answer to the subagent's request (`respondToAgentRun`): the
    /// subagent's conversation records it and it goes back to work.
    func answer(_ id: String, _ decision: PermissionDecision) {
        decisions.value.append((id, decision))
        runBuilder.resolvePermission(id: id, decision: decision)
        run.entries = runBuilder.entries
        run.state = .running
    }
    let opened = Box<[UUID]>([])

    init() throws {
        let folder = URL(filePath: "/tmp/session-rail-agents-qa/yardlet", directoryHint: .isDirectory)
        session = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                title: "Split the parser work", status: .running, providerSessionID: "saved",
                                providerOptions: ["permissionMode": "acceptEdits"])
        child = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                              title: "Port the parser to the new index", status: .ready, completionState: .completed,
                              parentTaskID: session.id)
        let prompt = "Check the migration\nThen report what breaks"
        run = AgentRun(callerID: session.id, hostTaskID: session.id, harness: .codex, model: "gpt-5.5", prompt: prompt,
                       workspaceURL: folder, depth: 1, startedAt: Date().addingTimeInterval(-95))
        var runBuilder = TranscriptBuilder()
        runBuilder.appendUser(prompt)
        runBuilder.apply(.assistantMessageCompleted("I'll run the migration tests first."))
        runBuilder.apply(.permissionRequested(PermissionRequest(id: "perm-1", title: "Run swift test --filter Migration",
                                                                detail: nil, command: "swift test --filter Migration")))
        run.entries = runBuilder.entries
        run.state = .waitingForApproval
        request = try XCTUnwrap(run.pendingRequests.first)
        self.runBuilder = runBuilder

        var builder = TranscriptBuilder()
        builder.appendUser("Split up the parser work")
        let base = try SessionRailAgentsTests.claudeEntries()
        builder.apply(.activityStarted(HarnessActivity(
            id: "ra1", kind: "mcp__yardlet__run_agent", title: "run_agent",
            input: #"{"harness":"codex","model":"gpt-5.5","prompt":"Check the migration\nThen report what breaks"}"#)))
        let chips = [("task_0000feed", "Remove the dead retry flag", "Delete `retryOnFailure` and its two call sites."),
                     ("task_0000beef", "Split UploadQueue.swift", "Split the queue into a scheduler and a store.")]
        let calls = chips.map { id, title, prompt in
            TranscriptEntry(content: .activity(HarnessActivity(
                id: "toolu_\(id)", kind: "mcp__yardlet__spawn_task", title: "mcp__yardlet__spawn_task",
                input: #"{"title":"\#(title)","tldr":"Flagged while splitting the parser.","prompt":"\#(prompt)","useWorktree":true}"#,
                output: TaskSuggestionToolCatalog.notedResult(taskID: id)), state: .completed))
        }
        entries = base + builder.entries.filter { if case .user = $0.content { false } else { true } } + calls
    }

    /// The chips' actions as the window gives them: Start starts at once (the app's start, which marks
    /// the suggestion started), ✕ dismisses; both in the one store.
    var suggestionActions: TaskSuggestionActions {
        let store = suggestions, task = session.id, started = startedSuggestions
        return TaskSuggestionActions(
            resolution: { store.resolution(of: $0, in: task) },
            progress: { store.progress(of: $0, in: task) },
            start: { suggestion in
                started.value.append(suggestion.id)
                store.markStarted(suggestion.id, in: task, startedTaskID: UUID())
            },
            dismiss: { store.dismiss($0, in: task) },
            openTask: { _ in })
    }

    /// The session jobs the task's CLI holds: a recurring check, a reminder, the next `/loop` wakeup.
    static var sessionJobs: [ClaudeSessionJob] {
        let now = Date()
        return [
            ClaudeSessionJob(id: "a1b2c3d4", kind: .recurring, cron: "*/15 * * * *", schedule: "Every 15 minutes",
                             prompt: "[Inbox check] Answer new customer messages and close finished rooms.",
                             createdAt: now.addingTimeInterval(-2 * 86_400), reportedRun: now.addingTimeInterval(372)),
            ClaudeSessionJob(id: "9f8e7d6c", kind: .once, cron: "30 17 * * *", schedule: "30 17 * * *",
                             prompt: "Remind me to check the deploy", createdAt: now.addingTimeInterval(-600),
                             reportedRun: now.addingTimeInterval(5_400)),
            ClaudeSessionJob(id: "toolu_wake", kind: .wakeup, cron: nil, schedule: nil, prompt: "/loop babysit the PR",
                             createdAt: now.addingTimeInterval(-60), reportedRun: now.addingTimeInterval(1_200))
        ]
    }

    var content: SessionRailContent {
        SessionRailContent.make(
            session: session, projectName: "yardlet", instructionSources: TaskInstructionSources(origin: .detected, paths: []),
            git: SessionRailGitInfo(branch: "feat/rail-agents", branchURL: nil, changes: nil),
            options: SessionRailAgentsTests.options(.claudeCode), connectors: nil, account: nil, entries: entries,
            codexPlan: nil, pullRequest: nil, pullRequestState: nil,
            agentRuns: [SessionRailAgents.Run(run)], childTasks: [SessionRailAgents.Child(child)],
            sessionJobs: Self.sessionJobs,
            suggestionResolution: { [suggestions, session] id in
                MainActor.assumeIsolated { suggestions.resolution(of: id, in: session.id) }
            })
    }

    func rail(folds: SessionRailFolds, appearance: WindowlessRender.Appearance) -> some View {
        SessionRailView(content: content, folds: .constant(folds), preferences: preferences, actions: railActions)
            .frame(height: 1200, alignment: .top)
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance.colorScheme)
            .environment(\.harnessModelNames, HarnessModelNames(harness: .claudeCode))
            .environment(\.taskSuggestionActions, suggestionActions)
    }

    /// A Codex task: its child threads, a background terminal and a computer-use screenshot.
    func codexRail(folds: SessionRailFolds, appearance: WindowlessRender.Appearance) -> some View {
        let state = (try? SessionRailAgentsTests.codexState(turnStatus: "inProgress")) ?? CodexTaskState()
        let shot = (try? SessionRailAgentsTests.codexComputerUse(turnStatus: "inProgress", image: Self.screenshot,
                                                                 thread: "computer-use-render")) ?? state
        let codex = SessionRecord(harness: .codex, workspaceURL: session.workspaceURL, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                  title: "Audit the build", status: .running)
        let content = SessionRailContent.make(
            session: codex, projectName: "yardlet", instructionSources: TaskInstructionSources(origin: .provider, paths: []),
            git: nil, options: SessionRailAgentsTests.options(.codex), connectors: nil, account: nil, entries: [],
            codexPlan: nil, pullRequest: nil, pullRequestState: nil, codexState: state,
            backgroundTerminals: [CodexBackgroundTerminal(processID: "42", itemID: "c9", command: "npm run dev -- --port 5173",
                                                          workspacePath: "")],
            preview: SessionRailComputerFrame.latest(in: shot).map {
                SessionRailPreview(source: .computer($0), caption: L10n.string("Computer use"))
            })
        return SessionRailView(content: content, folds: .constant(folds), preferences: preferences,
                               actions: SessionRailActions(terminals: SessionRailTerminalActions()))
            .frame(height: 1200, alignment: .top)
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance.colorScheme)
            .environment(\.harnessModelNames, HarnessModelNames(harness: .codex))
    }

    private var railActions: SessionRailActions {
        SessionRailActions(
            backgroundTasks: HarnessActivityActions(open: { _ in }, stop: { _ in }, isStopping: { _ in false },
                                                    error: { _ in nil }),
            openTaskOutput: { _ in },
            agents: SessionRailAgentActions(open: { _ in }, stop: { _ in },
                                            requests: ConversationActions(decide: { _, _ in })))
    }

    var taskView: some View {
        TaskHost(fixture: self)
    }

    struct TaskHost: View {
        let fixture: AgentsRailFixture
        @FocusState private var focused: TaskSurface?

        var body: some View {
            let workspace = fixture.workspace
            var services = SessionRailAgentServices()
            services.agentRuns = { [SessionRailAgents.Run(fixture.run)] }
            services.childTasks = { [SessionRailAgents.Child(fixture.child)] }
            services.openTask = { fixture.opened.value.append($0) }
            services.agentRun = { $0 == fixture.run.id ? fixture.run : nil }
            services.readTaskOutput = { _ in
                ClaudeTaskOutputReader.Output(text: "Building for debugging...\n[412/412] Compiling NativeHarnessClient\n"
                    + "Test Suite 'All tests' started.\nTest Case 'ParserTests.testRoundTrip' passed (0.012 seconds).\n",
                    isTruncated: false, url: URL(filePath: "/tmp/b1.output"))
            }
            return TaskDetail(
                session: fixture.session, composerDraft: TaskComposerDraft(), workspaceState: workspace,
                panelState: Binding(get: { workspace.panels }, set: { workspace.setPanels($0) }),
                focusedSurface: $focused, entries: fixture.entries, errorMessage: nil, codexTaskState: nil,
                codexHistorySelection: nil, codexQueue: [], codexCapabilities: .empty,
                providerCapabilities: ComposerUnificationFixtures.claudeLiveCapabilities,
                providerUsage: ComposerUnificationFixtures.providerUsage, isProviderAttached: true,
                onShowCodexCapabilities: {},
                conversationActions: ConversationActions(decide: { id, decision in fixture.answer(id, decision) },
                                                         heldRequests: fixture.run.pendingRequests,
                                                         showHarnessSettings: {}, readSubtask: { _ in
                    HarnessSubtaskTranscript(entries: [], isTruncated: false)
                }),
                composerActions: ComposerUnificationFixtures.claudeActions)
            .environment(\.taskKeyboardFocus, workspace.keyboardFocus)
            .environment(\.harnessModelNames, HarnessModelNames(harness: .claudeCode))
            .environment(\.taskSuggestionActions, fixture.suggestionActions)
            .environment(\.sessionRail, SessionRailServices(
                window: fixture.window, preferences: fixture.preferences, projectName: "yardlet", readGit: nil,
                git: SessionRailGitInfo(branch: "feat/rail-agents", branchURL: nil, changes: nil), agents: services))
        }
    }

    /// A small desktop-like screenshot for the computer-use preview.
    static let screenshot: String = {
        let size = NSSize(width: 320, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.16, green: 0.32, blue: 0.55, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.white.setFill()
        NSRect(x: 40, y: 30, width: 240, height: 140).fill()
        NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
        NSRect(x: 40, y: 150, width: 240, height: 20).fill()
        NSColor.systemBlue.setFill()
        NSRect(x: 60, y: 60, width: 90, height: 24).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
    }()
}

private extension NSView {
    /// The buttons titled so, anywhere in the window.
    func buttons(titled title: String) -> [WindowlessRender.AccessibilityElement] {
        WindowlessRender.accessibilityElements(in: self).filter { $0.role == "AXButton" && $0.label == title }
    }

    func labels() -> [String] {
        WindowlessRender.accessibilityElements(in: self).map(\.label)
    }

    /// Presses the first button in the session rail (or, `outsideRail`, outside it) whose label
    /// matches, as VoiceOver or a click would.
    func pressElement(outsideRail: Bool = false, _ matches: (String) -> Bool) -> Bool {
        WindowlessRender.withAccessibilityTree {
            func visit(_ node: AnyObject, _ found: (AnyObject) -> Bool) -> AnyObject? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if found(child) { return child }
                    if let match = visit(child, found) { return match }
                }
                return nil
            }
            func isRail(_ node: AnyObject) -> Bool {
                ((node.accessibilityLabel?() ?? nil) ?? "") == L10n.string("Session details")
            }
            func isMatch(_ node: AnyObject) -> Bool {
                (node.accessibilityRole?() ?? nil) == .button && matches((node.accessibilityLabel?() ?? nil) ?? "")
            }
            if outsideRail {
                func search(_ node: AnyObject) -> AnyObject? {
                    for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] where !isRail(child) {
                        if isMatch(child) { return child }
                        if let match = search(child) { return match }
                    }
                    return nil
                }
                return search(self)?.accessibilityPerformPress?() ?? false
            }
            let rail = visit(self, isRail) ?? self
            return visit(rail, isMatch)?.accessibilityPerformPress?() ?? false
        }
    }
}
