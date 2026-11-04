import AppKit
import SwiftUI

/// What the window gives a task's rail beyond what the task's surface already has: the window's
/// rail switch, the person's card preferences, the task's project, instruction files, account and
/// pull request, and how to read Git. A task shown without it (a side chat, a render without a
/// window) draws no rail.
@MainActor
struct SessionRailServices {
    var window: SessionRailWindowState
    var preferences: SessionRailPreferenceStore
    var projectName: String
    /// The instruction files in the task's folders, read when the rail reads Git rather than as the
    /// conversation streams.
    var instructionSources: @MainActor () -> TaskInstructionSources = { TaskInstructionSources(origin: .detected, paths: []) }
    /// The account the task runs on, read with Git (as a turn ends, and when Yardlet comes forward).
    var account: @MainActor () -> SessionRailAccount? = { nil }
    var chooseAccount: (() -> Void)?
    /// The pull request the title bar shows for the task (`TaskPullRequestMonitor`).
    var pullRequest: TaskPullRequest?
    /// The pull request's full status and auto-fix; nil where nothing may ask `gh`.
    var details: PullRequestDetailCenter?
    /// Reads the folder's branch and uncommitted work. Nil keeps `git` as given (renders).
    var readGit: (@Sendable (URL, String?) async -> SessionRailGitInfo)? = { folder, branch in
        await SessionRailGitInfo.read(folder: folder, knownBranch: branch)
    }
    var git: SessionRailGitInfo? = nil
    /// What the Agents, Background tasks and Preview cards read beyond the conversation.
    var agents = SessionRailAgentServices()
}

/// The browser tab the agent drives in a task's running turn.
struct SessionRailBrowserTab: Equatable {
    var tab: BrowserTabID
    var title: String?
    /// The side-panel tab it is (`BrowserTab.key`).
    var key: UUID? = nil
}

/// What the rail's Agents, Background tasks and Preview cards read from the app: a task's
/// `run_agent` subagents and child tasks, the conversations and outputs they open beside the task,
/// Codex's background terminals and how to stop them, and the browser tab the agent drives.
@MainActor
struct SessionRailAgentServices {
    /// The task's `run_agent` subagents and the child tasks `create_task` made (Agents card).
    var agentRuns: @MainActor () -> [SessionRailAgents.Run] = { [] }
    var childTasks: @MainActor () -> [SessionRailAgents.Child] = { [] }
    /// A child task's own conversation's answers, for what its row shows it waits on the person for.
    var childRequests: @MainActor (UUID) -> ConversationActions = { _ in ConversationActions() }
    /// Reads the Codex thread's background terminals; nil where there is nothing to ask (the task
    /// is not on Codex). The answer is nil while the task is not attached.
    var readBackgroundTerminals: (@MainActor () async -> [CodexBackgroundTerminal]?)? = nil
    /// The browser tab the agent drives in the task's running turn, and its page title.
    var browserPreviewTab: @MainActor () -> SessionRailBrowserTab? = { nil }
    /// Goes to a child task.
    var openTask: @MainActor (UUID) -> Void = { _ in }
    /// A `run_agent` subagent the app holds, or one kept from an earlier launch.
    var agentRun: @MainActor (UUID) -> AgentRun? = { _ in nil }
    var keptAgentRun: @MainActor (UUID) -> KeptAgentRun? = { _ in nil }
    var stopAgentRun: @MainActor (AgentRun) -> Void = { _ in }
    /// Reads a Codex child thread for the side panel.
    var readCodexThread: @MainActor (String) async throws -> CodexTaskState = { _ in
        throw HarnessAdapterError.capabilityUnavailable(L10n.string("The child conversation could not be read."))
    }
    /// Reads a Claude Code background task's output.
    var readTaskOutput: @MainActor (HarnessActivity) async -> ClaudeTaskOutputReader.Output? = { _ in nil }
    /// The session jobs a Claude Code task's running CLI holds (`AppModel.sessionJobs(of:)`).
    var sessionJobs: @MainActor () -> [ClaudeSessionJob] = { [] }
    /// Stops Codex's background terminals.
    var stopTerminal: (@MainActor (CodexBackgroundTerminal) async throws -> Void)? = nil
    var stopAllTerminals: (@MainActor () async throws -> Void)? = nil
}

private struct SessionRailServicesKey: EnvironmentKey {
    static let defaultValue: SessionRailServices? = nil
}

extension EnvironmentValues {
    var sessionRail: SessionRailServices? {
        get { self[SessionRailServicesKey.self] }
        set { self[SessionRailServicesKey.self] = newValue }
    }
}

/// A task's rail with its data: builds the cards from the task (`SessionRailContent`), reads Git
/// when the task's turn ends, and keeps the pull request card asked while it is on screen.
struct SessionRailHost: View {
    let services: SessionRailServices
    let session: SessionRecord
    let entries: [TranscriptEntry]
    let codexPlan: CodexPlanState?
    /// A Codex task's thread: its child threads, `run_agent` calls and computer-use screenshots.
    var codexState: CodexTaskState? = nil
    /// A Codex task's file changes, whose added files are its outputs.
    var codexChanges: [CodexChangeHandoff] = []
    let options: ComposerSessionOptions
    let connectors: ComposerConnectorList?
    @Binding var folds: SessionRailFolds
    let actions: SessionRailActions
    var isRaised = false
    /// The browser tab the side panel shows, if it shows one: the preview leaves out the tab already on
    /// screen there, and previews any other the agent drives.
    var panelBrowserKey: UUID? = nil

    @State private var readGit: SessionRailGitInfo?
    @State private var backgroundTerminals: [CodexBackgroundTerminal] = []
    @State private var instructionSources: TaskInstructionSources?
    @State private var account: SessionRailAccount?
    /// The `run_agent` calls the rail read, so a draw reads only the calls that changed.
    @State private var agentCalls = SessionRailAgents.Calls()
    /// The task's chips' actions: the rail lists the suggestions they have not resolved, and acts as they do.
    @Environment(\.taskSuggestionActions) private var suggestionActions
    @AppStorage(PullRequestAutoFixPrompt.preferenceKey) private var autoFixPrompt = PullRequestAutoFixPrompt.ask.rawValue

    private var git: SessionRailGitInfo? { readGit ?? services.git }

    private var content: SessionRailContent {
        SessionRailContent.make(
            session: session, projectName: services.projectName,
            instructionSources: instructionSources ?? TaskInstructionSources(origin: .detected, paths: []),
            git: git, options: options, connectors: connectors, account: account, entries: entries,
            codexPlan: codexPlan, pullRequest: services.pullRequest,
            pullRequestState: services.details?.state(for: session.id),
            autoFix: services.details?.autoFix.record(for: session.id),
            autoFixPrompt: PullRequestAutoFixPrompt(rawValue: autoFixPrompt) ?? .ask,
            codexChanges: codexChanges,
            codexState: codexState,
            agentRuns: services.agents.agentRuns(),
            agentCalls: agentCalls,
            childTasks: services.agents.childTasks(),
            backgroundTerminals: backgroundTerminals,
            sessionJobs: services.agents.sessionJobs(),
            preview: preview,
            suggestionResolution: suggestionActions.map { actions in
                { id in MainActor.assumeIsolated { actions.resolution(id) } }
            })
    }

    private var isTurnRunning: Bool { session.status == .running || session.status == .waitingForApproval }

    /// The browser tab the agent drives while the side panel does not show the browser, else the
    /// screen a Codex computer-use call last returned in the running turn.
    private var preview: SessionRailPreview? {
        let tab = services.agents.browserPreviewTab()
        if let browser = SessionRailPreview.browser(tab: tab?.tab, title: tab?.title, isTurnRunning: isTurnRunning,
                                                    panelShowsBrowser: tab?.key != nil && tab?.key == panelBrowserKey) {
            return browser
        }
        guard session.harness == .codex, let frame = SessionRailComputerFrame.latest(in: codexState) else { return nil }
        return SessionRailPreview(source: .computer(frame), caption: L10n.string("Computer use"))
    }

    /// Asked again when the task's turn starts or ends and, while any run or a turn is running,
    /// every few seconds: the App Server sends no notice when a background terminal starts or ends.
    private var terminalsKey: String { "\(session.id)|\(session.status)|\(isAttached)" }
    private var isAttached: Bool { services.agents.readBackgroundTerminals != nil && session.providerSessionID != nil }

    /// Git is read again when the task's turn ends or its folder changes, and when Yardlet comes back
    /// to the front.
    private var gitKey: String {
        "\(session.workspaceURL.path(percentEncoded: false))|\(session.status)|\(session.completionState)"
    }

    var body: some View {
        SessionRailView(content: content, folds: $folds, preferences: services.preferences,
                        actions: actions, isRaised: isRaised)
            .task(id: gitKey) { await refreshGit() }
            .task(id: terminalsKey) { await followBackgroundTerminals() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await refreshGit() }
            }
            .onChange(of: services.pullRequest?.url, initial: true) { _, _ in followPullRequest() }
            .onDisappear { services.details?.hide(taskID: session.id) }
    }

    private func refreshGit() async {
        let sources = services.instructionSources()
        if sources != instructionSources { instructionSources = sources }
        let reading = services.account()
        if reading != account { account = reading }
        guard let read = services.readGit else { return }
        let value = await read(session.workspaceURL, session.branch)
        if value != readGit { readGit = value }
    }

    /// Reads the thread's background terminals while the rail shows the task: every 5 seconds while
    /// a turn runs or one is listed, else every 30 seconds.
    private func followBackgroundTerminals() async {
        guard let read = services.agents.readBackgroundTerminals else {
            if !backgroundTerminals.isEmpty { backgroundTerminals = [] }
            return
        }
        while !Task.isCancelled {
            let listed = await read() ?? []
            guard !Task.isCancelled else { return }
            if listed != backgroundTerminals { backgroundTerminals = listed }
            let pause: Duration = isTurnRunning || !listed.isEmpty ? .seconds(5) : .seconds(30)
            try? await Task.sleep(for: pause)
        }
    }

    private func followPullRequest() {
        guard let details = services.details else { return }
        if let pullRequest = services.pullRequest {
            details.show(taskID: session.id, pullRequest: pullRequest, folder: session.workspaceURL)
        } else {
            details.hide(taskID: session.id)
        }
    }
}

/// Keeps the window's rail switch with the window (scene storage), so each window remembers its own
/// across launches, as the Claude app remembers its one switch (`sessionRailShown`, on by default).
struct SessionRailStorage: View {
    let state: SessionRailWindowState
    @SceneStorage("Yardlet.sessionRailShown") private var isShown = true

    var body: some View {
        Color.clear
            .onAppear { if state.visibility.isShown != isShown { state.visibility.isShown = isShown } }
            .onChange(of: state.visibility.isShown) { _, shown in if shown != isShown { isShown = shown } }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// The rail raised over the task's trailing edge where the area has no room for it, as the Claude
/// app raises its rail in a narrow window: a click outside it or Escape puts it away.
struct SessionRailRaisedLayer<Rail: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let rail: () -> Rail

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)
            rail()
                .frame(maxHeight: .infinity, alignment: .top)
                .background(ParityTheme.canvas)
                .overlay(alignment: .leading) {
                    Rectangle().fill(ParityTheme.separator).frame(width: 1)
                }
                .shadow(color: .black.opacity(0.14), radius: 16, x: -4)
                .onExitCommand(perform: onDismiss)
        }
    }
}
