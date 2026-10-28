import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let store: SessionStore
    let runtimeSelections: RuntimeSelectionStore
    let connections: ProviderConnectionStore
    /// Model lists and settings defaults, so composers name a task's model before it connects.
    let modelCatalogs: HarnessModelCatalogStore
    let composerDrafts: ComposerDrafts
    let taskWorkspaces: TaskWorkspaceStore
    /// Window-layer arrangement. The focused pane owns which task the shell shows.
    let splits: SplitStore
    /// Yardlet-owned projects: a name, several root folders, and one primary folder each.
    let projects: ProjectStore
    let codexEnvironmentManager: CodexEnvironmentManager?
    /// Makes the worktrees new tasks can start in, and tidies them when their tasks are archived.
    let worktrees: TaskWorktreeService
    /// How much CPU and memory each task's processes use. The app starts it after restoring the
    /// index; tests and visual fixtures leave it stopped.
    let resourceMonitor = TaskResourceMonitor(table: LiveProcessTable())
    /// The pull request each task on screen made. The app starts its lookups after restoring the
    /// index (`startPullRequestLookups`); tests and visual fixtures leave it without sources.
    let pullRequests = TaskPullRequestMonitor()
    /// The full status of the pull requests the session rails show, and auto-fix. Started with the
    /// lookups; tests and visual fixtures leave it without a client, so nothing asks `gh`.
    let pullRequestDetails: PullRequestDetailCenter
    /// The session rail's card preferences, the same in every window.
    let sessionRailPreferences: SessionRailPreferenceStore
    /// The person's scheduled tasks and the loop that runs them while Yardlet is open
    /// (`AppModel+ScheduledTasks`). The app starts the loop after restoring the index; tests and
    /// visual fixtures drive it themselves.
    let scheduledTasks: ScheduledTaskCenter

    /// Each task's transcript and Codex timeline state. A view reads one task's value at a time,
    /// so a task streaming in the background does not invalidate the view showing another.
    var transcriptBySessionID: TaskStateReader<[TranscriptEntry]> { transcripts.reader }
    private let transcripts = TaskStateTable<[TranscriptEntry]>()
    private(set) var errorBySessionID: [UUID: String] = [:]
    var codexPresentationBySessionID: TaskStateReader<CodexTaskState> { codexPresentations.reader }
    private let codexPresentations = TaskStateTable<CodexTaskState>()
    /// How many reads of each task's saved conversation from the provider's own history are under
    /// way (`isReadingSavedConversation`).
    private let savedConversationReads = TaskStateTable<Int>()
    /// Each detached task's saved-conversation read in flight, by harness and task, which a second
    /// asker waits for rather than reading again or skipping it (`readSavedConversationOnce`).
    @ObservationIgnored private var savedConversationReadTasks: [String: Task<Void, Never>] = [:]
    /// What each task's latest turn waits on and how it ended, for the sidebar's row states, the
    /// activity view and `⌥⌘A`. Read from the transcript and Codex timeline when either is set,
    /// and published only when it changes, so streaming does not redraw the sidebar. Tasks with
    /// nothing to say are absent.
    private(set) var taskAttentionDetails: [UUID: TaskAttentionDetail] = [:]
    /// The browser tabs each task's agent handed to the person and still waits on (`browser_handoff`),
    /// oldest first, which the phone remote shows as a wait (REMOTE_PROTOCOL §15.18).
    var browserHandoffWaits: [UUID: [BrowserHandoffWait]] = [:]
    /// Each task's latest finished message's first line (`TaskAttentionDetail.answerLine`), which the
    /// home shows under a finished task. One task at a time, so a running turn's messages redraw only
    /// what reads that task's line.
    var answerLineBySessionID: TaskStateReader<String> { answerLines.reader }
    private let answerLines = TaskStateTable<String>()
    /// How much of each Claude task's saved transcript its reads take, and whether the file holds
    /// earlier turns than they reached, which the conversation offers as it scrolls up.
    var claudeTranscriptTailBySessionID: TaskStateReader<ClaudeTranscriptTail> { claudeTranscriptTails.reader }
    private let claudeTranscriptTails = TaskStateTable<ClaudeTranscriptTail>()
    private(set) var codexHistorySelectionBySessionID: [UUID: CodexHistorySearchSelection] = [:]
    /// A place in a task's conversation something outside it asked to show: a file's related task's call
    /// (`revealCall`), which the task's conversation scrolls to once it holds the call.
    var conversationPlaceRequests: [UUID: ConversationPlaceRequest] = [:]
    /// Every task's follow-up queue (plan B1): messages sent while a turn runs or queued on
    /// purpose. A pending one waits in Yardlet; a sent one sits in Claude Code's own queue under
    /// `providerMessageID` until the CLI reports taking it, when it becomes a chat bubble. The
    /// composer acts on it through `submitFollowUp` and the queue actions below.
    let followUps: FollowUpQueueStore
    /// The Codex history a visual fixture's import list shows without a provider.
    @ObservationIgnored var visualFixtureCodexHistory: [CodexThreadSummary] = []
    /// Claude bash-mode (`!`) commands Yardlet has run this launch, by their conversation entry.
    private(set) var shellRunsByEntryID: [UUID: ClaudeShellCommandRun] = [:]
    /// The one command each Claude task is running, by task.
    private(set) var runningShellCommandBySessionID: [UUID: UUID] = [:]
    /// Finished commands whose message waits for the task to be idle, oldest first, by task. Saved
    /// with the task's queued follow-ups, so output not yet sent survives quitting.
    @ObservationIgnored private var pendingShellDeliveries: [UUID: [ClaudeShellDelivery]] = [:]
    @ObservationIgnored private var shellProcesses: [UUID: any ShellCommandRunning] = [:]
    @ObservationIgnored private var shellDeliveryTasks: [UUID: Task<Void, Never>] = [:]
    /// Each Claude task's bash-mode shell, kept between its commands.
    @ObservationIgnored let taskShells = TaskShells(launch: .userLoginShell()) {
        TaskShellProcess(workingDirectory: $0, launch: $1)
    }
    /// The shell bash mode runs commands in. Tests substitute one without the user's startup files.
    var shellCommandLaunch: ShellLaunchEnvironment {
        get { taskShells.launch }
        set { taskShells.launch = newValue }
    }
    private(set) var codexCapabilitiesBySessionID: [UUID: CodexCapabilityState] = [:]
    /// Codex tasks whose `/status` panel is open, with their account's rate limits as last read.
    /// Kept in memory only, as the Codex app keeps it in its composer.
    private(set) var codexStatusBySessionID: [UUID: CodexStatusReading] = [:]
    private(set) var providerCapabilitiesBySessionID: [UUID: ProviderCapabilityState] = [:]
    private(set) var providerUsageBySessionID: [UUID: HarnessProtocolUsage] = [:]
    /// Codex token usage for a task whose thread has reported none this run: what the index kept,
    /// then the rollout's latest `token_count`. The thread's own turns win whenever they have it.
    private(set) var restoredCodexTokenUsageBySessionID: [UUID: CodexThreadTokenUsage] = [:]
    /// What each task's context usage was last kept as in the index: a save happens only on a
    /// change, and a saved conversation read later is shown only when it went on after this.
    @ObservationIgnored private var savedContextUsage: [UUID: TaskContextUsageSnapshot] = [:]
    @ObservationIgnored private var contextUsageSaves: [UUID: Task<Void, Never>] = [:]
    /// Tasks whose harness reported their context this run. History read for them is not shown.
    @ObservationIgnored private var liveContextUsageSessionIDs = Set<UUID>()
    /// What a running task's provider is retrying, for its running status line.
    private(set) var providerRetryBySessionID: [UUID: HarnessProviderRetry] = [:]
    /// A plan limit the provider warned a task is close to, for the line above its composer.
    private(set) var rateLimitWarningBySessionID: [UUID: HarnessRateLimit] = [:]
    /// Limit cards whose task sends the continue message once the limit resets. Kept in memory
    /// only; a restart forgets them.
    private(set) var usageLimitAutoContinue: [UUID: UsageLimitAutoContinue] = [:]
    /// Why continuing a limited task under another account was refused, for its limit card.
    private(set) var usageLimitSwitchErrorBySessionID: [UUID: String] = [:]
    @ObservationIgnored private var usageLimitAutoContinueTasks: [UUID: Task<Void, Never>] = [:]
    /// How long after a limit's reset the continue message waits, so the provider's own clock
    /// has passed it too.
    @ObservationIgnored var usageLimitResumeGrace: Duration = .seconds(10)
    /// Tasks Yardlet continued after the last restart, for the line above their composer. Kept in
    /// memory only and cleared once the person sends to or stops the task.
    private(set) var restartResumeNoticeSessionIDs = Set<UUID>()
    /// Cut-off turns that continue once their task is opened, with the last moment they may.
    @ObservationIgnored private var restartResumesWhenOpened: [UUID: Date] = [:]
    /// Cut-off turns continuing from launch, a few starting at a time (`RestartResumeLine`).
    @ObservationIgnored private(set) var restartResumeLine = RestartResumeLine()
    /// Starting continuations Yardlet has asked for, until their provider shows work.
    @ObservationIgnored private var restartResumesAwaitingWork = Set<UUID>()
    /// The wait after which a starting continuation gives up its place in line.
    @ObservationIgnored private var restartResumeStartWaits: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var continuesRestartResumeLine = false
    /// The record's entry for each cut-off turn not continued yet, in line or until opened, for a
    /// quit before then to carry over.
    @ObservationIgnored private var restartResumesToContinue: [UUID: RestartResumeRecord.Entry] = [:]
    /// Idle Claude Code tasks in line whose CLI starts again, with nothing sent, for the session jobs
    /// it brings back (`ClaudeSessionJobs`).
    @ObservationIgnored private var sessionJobRelaunches = Set<UUID>()
    /// The launch's read of saved conversations for those jobs, which quitting cancels.
    @ObservationIgnored private var sessionJobScan: Task<[UUID], Never>?
    /// The session jobs each Claude Code task's CLI holds (`ClaudeSessionJobs.held`), read from its saved
    /// conversation when it starts and after a turn that made, ended or listed one (`sessionJobs(of:)`).
    private(set) var sessionJobsBySessionID: [UUID: [ClaudeSessionJob]] = [:]
    /// When each task's runtime started, for the wakeups it armed since.
    @ObservationIgnored private var runtimeStartedAt: [UUID: Date] = [:]
    /// The memory saver for harness runtimes (`HarnessMemorySaver`): when each task was last on screen, the tasks on
    /// screen at the last look, and its last sweep for memory pressure.
    @ObservationIgnored private var lastOnScreen: [UUID: Date] = [:]
    @ObservationIgnored private var memorySaverOnScreen = Set<UUID>()
    @ObservationIgnored private var lastMemoryPressureSweep: Date?
    @ObservationIgnored private var harnessMemorySaverTask: Task<Void, Never>?
    @ObservationIgnored private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    /// Runtimes the memory saver is closing; a new attach of the task waits for its close to finish.
    @ObservationIgnored private var memorySaverClosings: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var harnessMemorySaverTiming = HarnessMemorySaver.Timing()
    /// The tasks the phone shows now (`AppModelRemoteBridge`), which the memory saver counts as on screen.
    @ObservationIgnored var remoteWatchedTaskIDs = Set<UUID>()
    @ObservationIgnored private var sessionJobReads: [UUID: Task<Void, Never>] = [:]
    /// The cards of the questions a restart cut off, asked again until the person answers in their
    /// next message, sends anything else, or a turn starts (`RestartResumePolicy.Plan.questions`).
    /// A quit before then carries them over with their entry in `restartResumesToContinue`.
    private(set) var restartQuestions: [UUID: ConversationRequest] = [:]
    /// Whether this Mac's network path is up, as the system last reported it (`NetworkWatch`); up
    /// until it says otherwise.
    private(set) var isNetworkAvailable = true
    /// Tasks whose turn a lost connection cut off, until their continuation has run or the person
    /// takes over (`ConnectionResumePolicy`).
    private(set) var connectionResumes: [UUID: ConnectionResume] = [:]
    @ObservationIgnored private var connectionResumeWaits: [UUID: Task<Void, Never>] = [:]
    /// Waits out a connection resume's delay; tests hand it a clock of their own.
    @ObservationIgnored var connectionResumeSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Waits out `RestartResumePolicy.startWindow`; tests hand it a clock of their own.
    @ObservationIgnored var restartResumeSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Tasks whose running turn Yardlet continued after a restart while nobody had them open, with
    /// how many times in a row it has. A quit writes one down again until
    /// `RestartResumePolicy.unseenContinuationLimit`.
    @ObservationIgnored private var unseenRestartResumes: [UUID: Int] = [:]
    /// Tasks whose turn the person stopped, until their next turn starts.
    @ObservationIgnored var stoppedByPerson = Set<UUID>()
    /// Instruction files the provider itself reported for a task. Harnesses that report nothing
    /// stay absent here and fall back to a plain existence check.
    private(set) var instructionSourcesBySessionID: [UUID: [String]] = [:]
    private(set) var openingSideChats = Set<UUID>()
    private var forkingSessions = Set<UUID>()
    private var restartingSessions = Set<UUID>()
    /// Codex tasks whose link to the task they were started from is being saved.
    @ObservationIgnored private var linkingCodexParents = Set<UUID>()
    /// Each runtime's native branch method, once its adapter has been asked (`canBranch`).
    private var branchMethodsByRuntime: [HarnessRegistry.Key: HarnessSessionBranchMethod?] = [:]
    @ObservationIgnored private var resolvingBranchMethods = Set<HarnessRegistry.Key>()
    private(set) var sessionMutations = Set<UUID>()
    private var reviewedFileRewinds: [UUID: FileRewindPreview] = [:]
    var pendingCodexReview: CodexReviewRequest?
    private(set) var switchingAccounts = Set<UUID>()
    private(set) var sideChatErrors: [UUID: String] = [:]
    private(set) var bootstrapError: String?
    /// Archived tasks being restored, and the last restore or listing failure, for the archived list.
    private(set) var unarchivingSessionIDs = Set<UUID>()
    private(set) var archivedTaskError: String?
    /// What archiving or unarchiving did with a task's worktree when it is worth saying: a
    /// worktree kept because work in it would be lost, or one that could not be put back.
    private(set) var worktreeNotice: String?
    /// The tasks whose folder was found gone (`TaskFolderMissing`), which their composer says above it:
    /// looked at when a task is shown and when the app comes to the front, before anything is sent or
    /// started in a task, and after its worktree is made again.
    private(set) var missingTaskFolders: [UUID: TaskFolderMissing] = [:]
    /// Tasks whose worktree is being made again from their branch.
    private(set) var recreatingTaskWorktrees = Set<UUID>()
    private(set) var isRestoringIndex: Bool
    /// Optional DEBUG fixture launch surface. Live app instances keep this nil so task routing
    /// remains user-driven.
    let initialTaskSurface: String?
    /// Optional DEBUG fixture capability-sheet section. Live app instances keep these nil so
    /// opening Codex features/history remains user-driven.
    let initialCodexCapabilitySection: String?
    let initialCodexHistoryQuery: String?
    /// Optional DEBUG fixture Settings section. Live app instances keep this nil so Settings
    /// remains user-driven and no fixture route can affect production launches.
    let initialSettingsSection: String?

    @ObservationIgnored private(set) var publicationCounts = AppModelPublicationCounts()
    @ObservationIgnored private(set) var eventsBySessionID: [UUID: [HarnessEventEnvelope]] = [:]
    /// When each task's provider last did something for its conversation: a message, a call, a
    /// Codex item. A turn's status moves the task's recency only as it starts, waits and ends, so a
    /// long turn (one resumed after a restart included) would otherwise read as active at its start.
    @ObservationIgnored private(set) var providerActivityBySessionID: [UUID: Date] = [:]
    @ObservationIgnored private var transcriptBuilders: [UUID: TranscriptBuilder] = [:]
    @ObservationIgnored private var pendingTranscriptDeltas: [UUID: [PendingTranscriptDelta]] = [:]
    @ObservationIgnored private var transcriptPublicationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var codexSnapshotCheckpointTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var savedCodexRequests: [UUID: [CodexPendingServerRequest]] = [:]
    @ObservationIgnored private var codexModelRestoreErrors: [UUID: String] = [:]
    @ObservationIgnored private var savedCodexItems: [UUID: [CodexPersistedTimelineItem]] = [:]
    /// Each Codex task's saved cards and settled turns, reused while their items stay the same.
    @ObservationIgnored private var codexPersistedTimelines: [UUID: CodexPersistedTimeline] = [:]
    @ObservationIgnored private var codexSettledTurns: [UUID: CodexSettledTurns] = [:]
    /// Saves of Codex cards whose only change is streamed content, waiting to be written.
    @ObservationIgnored private var codexItemSaveTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var implementingCodexPlans = Set<UUID>()
    @ObservationIgnored private var preparingCodexCommands = Set<UUID>()
    /// When a send last marked each task running. A "ready" the provider emitted before then, such
    /// as the one from attaching a new task, is older than the send and must not end the turn.
    @ObservationIgnored var submissionStartedAt: [UUID: Date] = [:]
    @ObservationIgnored private var codexPresentationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var sessionTitleResolutionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var sessionTitleRefreshes: [UUID: UUID] = [:]
    /// Each task's send of its next queued message once its turn ends.
    @ObservationIgnored private var followUpDrainTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var codexTurnPageLoads = Set<UUID>()
    /// Claude tasks reading earlier turns of their saved transcript.
    @ObservationIgnored private var claudeEarlierHistoryReads = Set<UUID>()
    /// Detached Codex tasks whose saved thread is being read for display (`thread/read`).
    @ObservationIgnored private var codexThreadReads = Set<UUID>()
    /// The rollout file a detached Codex task's last `thread/read` named, which following the
    /// task while it is shown watches for another app's writes.
    @ObservationIgnored private var codexRolloutPathBySessionID: [UUID: String] = [:]
    /// How often a shown detached task looks for another app's writes to its conversation.
    @ObservationIgnored var detachedFollowInterval: Duration = .seconds(2)
    /// Where the Claude desktop app keeps its Code sessions, for importing the ones it has open.
    @ObservationIgnored var claudeDesktopSessionsRoot = ClaudeDesktopSessionCatalog.defaultRoot()
    /// When the next pass following the Claude app's and Codex's lists may run (`SessionListFollow`).
    @ObservationIgnored var sessionListFollowSchedule = SessionListFollow.Schedule()
    /// Set once the index is restored: a pass compares the sources with the tasks Yardlet has.
    @ObservationIgnored var sessionListFollowIsReady = false
    /// A pass over the Claude app's and Codex's lists is running (the refresh item says so).
    private(set) var isFollowingSessionLists = false
    /// Folders whose conversations a pass leaves alone; tests follow their temporary folders.
    @ObservationIgnored var sessionListFollowSkipsFolder: (URL) -> Bool = SessionListFollow.isTemporaryFolder
    /// Antigravity CLI's conversation index and logs, for importing and reading its conversations.
    @ObservationIgnored var antigravityConversationStore = AntigravityConversationStore.live
    /// Detached Antigravity tasks whose log is being read, and the log each last showed: the
    /// stamp read, and whether the conversation shown is that log (rather than Yardlet's own cache).
    @ObservationIgnored private var antigravityHistoryReads = Set<UUID>()
    @ObservationIgnored private var antigravityHistoryShown: [UUID: AntigravityHistoryShown] = [:]
    @ObservationIgnored private var codexItemPageLoads = Set<String>()
    private let isVisualFixture: Bool
    var usesVisualFixture: Bool { isVisualFixture }
    let registry: HarnessRegistry
    /// App preferences read at the moment they apply, such as the Codex follow-up mode.
    private let preferences: UserDefaults
    private let codexPendingRequestRepository: any CodexPendingServerRequestRepository
    private let codexTimelineItemRepository: any CodexTimelineItemRepository
    /// The files each task read and edited, for a file's related tasks (`AppModel+FileTasks`). Nil in
    /// tests and visual fixtures, which have no tasks of the person's to read.
    let fileTaskIndex: FileTaskIndex?
    private let codexHistorySelectionRepository: any CodexHistorySelectionRepository
    private let transcriptRepository: any TranscriptRepository
    /// Writes detached-reading snapshots of `transcriptRepository` off the main thread. Reading
    /// through it waits for the writes already queued, as reading the repository directly does not.
    let transcriptSnapshots: TranscriptSnapshotWriter
    /// Reads the title a `ProviderTitleSource.pull` harness stored for a session.
    private let sessionTitleResolver: @Sendable (SessionRecord) -> String?
    private let sessionTitleRetryCount: Int
    private let sessionTitleRetryInterval: Duration
    let systemNotificationCenter: any SystemNotificationCenter
    /// The Dock and app activation; nil in tests and fixtures, which never touch either.
    @ObservationIgnored let applicationAttention: (any ApplicationAttention)?
    /// The Dock badge and bounce for tasks that need the person (`AppModel+SystemNotifications`).
    @ObservationIgnored let dockAttention: DockAttention?
    /// Notification clicks that arrived before the task index was read at launch.
    @ObservationIgnored var pendingNotificationResponses: [SystemNotificationResponse] = []
    /// Links other apps opened with Yardlet before the task index was read at launch (`AppModel+ExternalLinks`).
    @ObservationIgnored var pendingExternalLinks: [(urls: [URL], elsewhere: @MainActor (URL) -> Void)] = []
    /// Each task's delivered approval notifications, by the request each asks about ("" for one
    /// that names no request), withdrawn once the request is answered.
    @ObservationIgnored var approvalNotificationIDs: [UUID: [String: String]] = [:]
    /// The browser whose tabs' waits on the person the tasks show (`followBrowserWaits(of:)`), and each task's wait.
    @ObservationIgnored weak var browserWaitSource: BrowserHostClient?
    @ObservationIgnored var browserWaits: [UUID: BrowserTaskWait] = [:]
#if DEBUG
    /// The browser waits announced, by their notification's identifier, for QA (notifications are not delivered there).
    @ObservationIgnored var browserWaitAnnouncements: [String] = []
#endif
    /// Asks the window to show archived tasks: a notification led to a task that was archived.
    var archivedTasksRevealRequest = 0
    /// An explicit navigation outside the main window asks it to reveal Tasks.
    /// Background index selection changes do not send this request.
    var taskSurfaceRevealRequest = 0
    /// The main windows that show Tasks rather than another sidebar section. With none, no task
    /// counts as seen, so its updates stay unread and are announced.
    private(set) var taskWindowIDs = Set<UUID>()
    private let restoresIndexOnLaunch: Bool
    @ObservationIgnored private let legacyFolderPreferences: LegacyProjectFolderPreferences
    private var notifiedBackgroundStates = Set<String>()
    private var adaptersBySessionID: [UUID: any HarnessAdapter] = [:]
    private var handlesBySessionID: [UUID: HarnessSessionHandle] = [:]
    private var eventTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    /// Issues the Yardlet MCP server (agent browser tools) for a task's next start. The platform
    /// layer sets it; nil, as in tests and fixtures, starts every session without it.
    @ObservationIgnored var agentTools: (any AgentToolLaunchProviding)?
    /// Yardlet's connectors, which composers list beside each session's MCP servers. The platform
    /// layer sets it with `agentTools`; nil in tests and fixtures.
    var connectorCenter: ConnectorCenter?
    /// What each task's harness was found to load itself when the task was last injected, so its
    /// composer can say which of Yardlet's connectors the harness's own server stands in for.
    private(set) var connectorScopeBySessionID: [UUID: ConnectorTaskScope] = [:]
    /// The phone remote (Settings › Remote, docs/REMOTE_PROTOCOL.md). The app sets it after restoring
    /// the index; nil in tests and fixtures.
    var remoteControl: RemoteControlService?
    /// The display is kept on while tasks work ("Keep the screen unlocked while tasks work"), which
    /// the menu bar menu says (`RunningWorkActivity`).
    @ObservationIgnored var keepsScreenAwake = false
    /// The setting wants the display on, but a battery under 20% lets the screen lock (`RunningWorkActivity`).
    @ObservationIgnored var screenAwakePausedForBattery = false
    /// The lid helper keeps the Mac awake with its lid closed while tasks work ("Keep tasks working
    /// with the lid closed"), which the menu bar menu says (`RunningWorkActivity`).
    @ObservationIgnored var keepsAwakeWithLidClosed = false
    /// The lid setting wants the Mac awake, but the battery or the heat lets it sleep (`RunningWorkActivity`).
    @ObservationIgnored var lidAwakePause: LidAwakePause?
    /// Yardlet's lid helper, for Settings › General. The app sets it; nil in tests and fixtures,
    /// where the setting is left out.
    var lidSleepHelper: LidSleepHelper?
    /// Harness CLI update checks (Settings › CLI Updates). The app sets it after restoring the index;
    /// nil in tests and fixtures.
    var cliUpdates: CLIUpdateCenter?
    /// Yardlet instructions (Settings › Yardlet Instructions), handed to every task's launch through its
    /// harness's own route. The app sets it before restoring the index; nil sends nothing.
    var yardletInstructions: YardletInstructionsStore?
    /// The routing evaluation's switch and ledger (Settings). The app sets it
    /// before restoring the index; nil records nothing.
    var routingEvaluation: RoutingEvaluationStore?
    @ObservationIgnored var routingEvaluationLoop: Task<Void, Never>?
    @ObservationIgnored var routingEvaluationIsRunning = false
    /// What became of each task's suggested tasks (`spawn_task` chips), kept with the task.
    let taskSuggestions: TaskSuggestionStore
    /// What the session tools wait on and run: their approvals, subagents and nesting depth
    /// (`AppModel+SessionTools`). Tests give it volatile defaults.
    var sessionTools = SessionToolCenter()
    /// Which account each task an agent started runs on, and why (`AppModel+AccountRouting`). The
    /// app keeps it in a file; tests and fixtures in memory.
    var accountAssignments = AccountAssignmentLog()

    init(
        store: SessionStore,
        runtimeSelections: RuntimeSelectionStore,
        registry: HarnessRegistry? = nil,
        connections: ProviderConnectionStore? = nil,
        modelCatalogs: HarnessModelCatalogStore? = nil,
        codexEnvironmentManager: CodexEnvironmentManager? = nil,
        bootstrapError: String? = nil,
        initialTranscripts: [UUID: [TranscriptEntry]] = [:],
        initialErrors: [UUID: String] = [:],
        initialCodexPresentation: [UUID: CodexTaskState] = [:],
        initialCodexQueues: [UUID: [QueuedFollowUp]] = [:],
        initialCodexCapabilities: [UUID: CodexCapabilityState] = [:],
        initialProviderCapabilities: [UUID: ProviderCapabilityState] = [:],
        initialProviderUsage: [UUID: HarnessProtocolUsage] = [:],
        codexQueueRepository: any CodexQueueRepository = UserDefaultsCodexQueueRepository(),
        preferences: UserDefaults = .yardlet,
        codexPendingRequestRepository: any CodexPendingServerRequestRepository = UserDefaultsCodexPendingServerRequestRepository(),
        codexTimelineItemRepository: any CodexTimelineItemRepository = UserDefaultsCodexTimelineItemRepository(),
        fileTaskIndex: FileTaskIndex? = nil,
        codexHistorySelectionRepository: any CodexHistorySelectionRepository = UserDefaultsCodexHistorySelectionRepository(),
        transcriptRepository: any TranscriptRepository = UserDefaultsTranscriptRepository(),
        composerDraftRepository: any ComposerDraftRepository = InMemoryComposerDraftRepository(),
        taskWorkspaceRepository: any TaskWorkspaceRepository = InMemoryTaskWorkspaceRepository(),
        taskSuggestionRepository: any TaskSuggestionRepository = InMemoryTaskSuggestionRepository(),
        splitRepository: any SplitRepository = InMemorySplitRepository(),
        projectRepository: any ProjectRepository = InMemoryProjectRepository(),
        scheduleRepository: any ScheduledTaskRepository = InMemoryScheduledTaskRepository(),
        chatWorkspaceHome: URL? = nil,
        worktrees: TaskWorktreeService = TaskWorktreeService(),
        legacyProjectFolderPreferences: LegacyProjectFolderPreferences? = nil,
        sessionTitleResolver: @escaping @Sendable (SessionRecord) -> String? = {
            ProviderSessionTitleResolver.title(for: $0)
        },
        // About ten seconds after the first turn: Claude writes its generated title a few seconds
        // after the first request, and Codex names a thread after a separate short turn.
        sessionTitleRetryCount: Int = 40,
        sessionTitleRetryInterval: Duration = .milliseconds(250),
        systemNotificationCenter: any SystemNotificationCenter = LocalSystemNotificationCenter(),
        applicationAttention: (any ApplicationAttention)? = nil,
        restoresIndexOnLaunch: Bool = true,
        isVisualFixture: Bool = false,
        initialTaskSurface: String? = nil,
        initialCodexCapabilitySection: String? = nil,
        initialCodexHistoryQuery: String? = nil,
        initialSettingsSection: String? = nil,
        browserClient: @escaping @MainActor () -> BrowserHostClient? = {
            MacBrowserHost.isAvailable ? MacBrowserHost.shared.client : nil
        }
    ) {
        self.store = store
        self.runtimeSelections = runtimeSelections
        self.connections = connections ?? ProviderConnectionStore()
        self.modelCatalogs = modelCatalogs ?? HarnessModelCatalogStore()
        self.composerDrafts = ComposerDrafts(repository: composerDraftRepository)
        // Each task's side-panel browser tabs open in the browser engine, when the build has one.
        self.taskWorkspaces = TaskWorkspaceStore(repository: taskWorkspaceRepository, browserClient: browserClient)
        self.taskSuggestions = TaskSuggestionStore(repository: taskSuggestionRepository)
        self.splits = SplitStore(repository: splitRepository)
        // A visual fixture's new chats get folders of their own, never in the person's Documents.
        self.projects = ProjectStore(
            repository: projectRepository,
            chatWorkspaceHome: chatWorkspaceHome ?? (isVisualFixture
                ? FileManager.default.temporaryDirectory.appending(path: "yardlet-fixture-home", directoryHint: .isDirectory)
                : FileManager.default.homeDirectoryForCurrentUser))
        self.worktrees = worktrees
        self.codexEnvironmentManager = codexEnvironmentManager
        self.registry = registry ?? HarnessRegistry(
            codexEnvironmentManager: codexEnvironmentManager
        )
        self.followUps = FollowUpQueueStore(repository: codexQueueRepository)
        self.preferences = preferences
        self.sessionRailPreferences = SessionRailPreferenceStore(defaults: preferences)
        self.pullRequestDetails = PullRequestDetailCenter(autoFix: PullRequestAutoFixStore(defaults: preferences))
        self.scheduledTasks = ScheduledTaskCenter(repository: scheduleRepository)
        // Streaming Codex tasks merge these into every timeline state; keep them in memory.
        self.codexPendingRequestRepository = CachedCodexPendingServerRequestRepository(codexPendingRequestRepository)
        self.codexTimelineItemRepository = CachedCodexTimelineItemRepository(codexTimelineItemRepository)
        self.fileTaskIndex = fileTaskIndex
        self.codexHistorySelectionRepository = codexHistorySelectionRepository
        self.transcriptRepository = transcriptRepository
        self.transcriptSnapshots = TranscriptSnapshotWriter(repository: transcriptRepository)
        self.sessionTitleResolver = sessionTitleResolver
        self.sessionTitleRetryCount = max(0, sessionTitleRetryCount)
        self.sessionTitleRetryInterval = sessionTitleRetryInterval
        self.systemNotificationCenter = systemNotificationCenter
        self.applicationAttention = applicationAttention
        self.dockAttention = applicationAttention.map(DockAttention.init(application:))
        self.restoresIndexOnLaunch = restoresIndexOnLaunch
        self.legacyFolderPreferences = legacyProjectFolderPreferences ?? LegacyProjectFolderPreferences()
        self.isRestoringIndex = restoresIndexOnLaunch
        self.isVisualFixture = isVisualFixture
        self.initialTaskSurface = initialTaskSurface
        self.initialCodexCapabilitySection = initialCodexCapabilitySection
        self.initialCodexHistoryQuery = initialCodexHistoryQuery
        self.initialSettingsSection = initialSettingsSection
        self.bootstrapError = bootstrapError
        transcripts.didSet = { [weak self] id in self?.refreshAttentionDetail(for: id) }
        codexPresentations.didSet = { [weak self] id in
            self?.refreshAttentionDetail(for: id)
            self?.linkCodexParentIfNeeded(for: id)
            self?.keepCodexTokenUsage(for: id)
        }
        for (id, entries) in initialTranscripts { transcripts[id] = entries }
        transcriptBuilders = initialTranscripts.mapValues { TranscriptBuilder(entries: $0) }
        errorBySessionID = initialErrors
        for (id, state) in initialCodexPresentation { codexPresentations[id] = state }
        followUps.seed(initialCodexQueues)
        // A finished bash command waits behind queued messages; with none left it may go.
        followUps.queueDidEmpty = { [weak self] sessionID in self?.scheduleShellDelivery(for: sessionID) }
        codexCapabilitiesBySessionID = initialCodexCapabilities
        providerCapabilitiesBySessionID = initialProviderCapabilities
        providerUsageBySessionID = initialProviderUsage
        // Codex's default login is read in the environment the app's Codex tasks run in.
        if self.connections.codexEnvironmentManager == nil {
            self.connections.codexEnvironmentManager = codexEnvironmentManager
        }
        self.connections.selection = composerDrafts.home.connectionSelection
        self.connections.onSelectionChange = { [weak composerDrafts] selection in
            composerDrafts?.home.connectionSelection = selection
        }
        if !restoresIndexOnLaunch { taskWorkspaces.restoreSelection(in: store) }
        importFolderPreferencesIfNeeded(legacyProjectFolderPreferences)
        splits.adopt(
            selection: store.selectedSessionID,
            knownSessionIDs: Set(store.sessions.map(\.id)),
            isFinal: !restoresIndexOnLaunch
        )
        splits.onFocusedSessionChange = { [weak store] id in store?.selectedSessionID = id }
        store.onSelectionChange = { [weak splits, weak self] id in
            splits?.focusSession(id)
            self?.taskOpened(id)
            self?.noteMemorySaverScreen()
        }
        resourceMonitor.request = { [weak self] in self?.taskResourceRequest() ?? TaskResourceRequest() }
        resourceMonitor.describe = { [weak self] in self?.taskResourceDescription($0) }
        systemNotificationCenter.setResponseHandler { [weak self] response in
            Task { await self?.handleNotificationResponse(response) }
        }
        trackAttentionBadge()
        wireScheduledTasks()
    }

    static func live() -> AppModel {
        HostSessionEnvironment.detachFromHostSession()
        #if DEBUG
        if let fixture = VisualFixtureScenario.requested() {
            return fixture.makeModel()
        }
        #endif
        let supportRootURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let codexEnvironmentManager = CodexEnvironmentManager(
            paths: CodexEnvironmentPaths.live()
        )
        let composerDraftRepository = FileComposerDraftRepository(
            directoryURL: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: YardletProduct.storageDirectoryName).appending(path: "drafts")
        )
        do {
            let storageRootURL = try YardletProduct.storageRootURL(
                applicationSupportBaseURL: supportRootURL
            )
            let defaults = UserDefaults.yardlet
            let repository = try SQLiteSessionRepository(
                databaseURL: storageRootURL.appending(path: "session-index.sqlite3")
            )
            let transcriptRepository = MigratingTranscriptRepository(
                primary: FileTranscriptRepository(
                    directoryURL: storageRootURL.appending(path: "transcripts")
                ),
                legacy: UserDefaultsTranscriptRepository(defaults: defaults)
            )
            let codexTimelineItems = FileCodexTimelineItemRepository(
                directoryURL: storageRootURL.appending(path: "codex-timeline-items")
            )
            codexTimelineItems.moveCards(from: UserDefaultsCodexTimelineItemRepository(defaults: defaults))
            let model = AppModel(
                store: SessionStore(repository: repository),
                runtimeSelections: RuntimeSelectionStore(defaults: defaults),
                // A harness whose new CLI failed Yardlet's check runs the version before it.
                registry: HarnessRegistry(codexEnvironmentManager: codexEnvironmentManager,
                                          runtimeOverrides: .shared),
                connections: ProviderConnectionStore(fileURL: storageRootURL.appending(path: "provider-connections.json"),
                    snapshotCacheURL: storageRootURL.appending(path: ProviderConnectionStore.snapshotCacheFileName),
                    assignmentDefaults: defaults),
                modelCatalogs: HarnessModelCatalogStore(fileURL: storageRootURL.appending(path: "model-catalogs.json")),
                codexEnvironmentManager: codexEnvironmentManager,
                codexTimelineItemRepository: codexTimelineItems,
                fileTaskIndex: FileTaskIndex(repository: FileTouchRepository(
                    directoryURL: storageRootURL.appending(path: "file-activity"))),
                transcriptRepository: transcriptRepository,
                composerDraftRepository: composerDraftRepository,
                taskWorkspaceRepository: UserDefaultsTaskWorkspaceRepository(defaults: defaults),
                taskSuggestionRepository: UserDefaultsTaskSuggestionRepository(defaults: defaults),
                splitRepository: FileSplitRepository(
                    fileURL: storageRootURL.appending(path: "splits.json"),
                    legacyDeskFileURL: storageRootURL.appending(path: "desks.json")
                ),
                projectRepository: FileProjectRepository(
                    fileURL: storageRootURL.appending(path: "projects.json")
                ),
                scheduleRepository: FileScheduledTaskRepository(
                    fileURL: storageRootURL.appending(path: "schedules.json")
                ),
                legacyProjectFolderPreferences: LegacyProjectFolderPreferences.stored(in: defaults),
                applicationAttention: MacApplicationAttention()
            )
            model.accountAssignments = AccountAssignmentLog(
                fileURL: storageRootURL.appending(path: AccountAssignmentLog.fileName))
            return model
        } catch {
            return AppModel(
                store: SessionStore(repository: InMemorySessionRepository()),
                runtimeSelections: RuntimeSelectionStore(),
                codexEnvironmentManager: codexEnvironmentManager,
                bootstrapError: L10n.format(
                    "Session index unavailable: %@",
                    error.localizedDescription
                ),
                codexTimelineItemRepository: FileCodexTimelineItemRepository.live(),
                composerDraftRepository: composerDraftRepository,
                taskWorkspaceRepository: UserDefaultsTaskWorkspaceRepository(defaults: .yardlet),
                taskSuggestionRepository: UserDefaultsTaskSuggestionRepository(defaults: .yardlet),
                splitRepository: FileSplitRepository.live(),
                projectRepository: FileProjectRepository.live(),
                scheduleRepository: FileScheduledTaskRepository.live(),
                legacyProjectFolderPreferences: LegacyProjectFolderPreferences.stored(in: .yardlet),
                applicationAttention: MacApplicationAttention(),
                restoresIndexOnLaunch: false
            )
        }
    }

    #if DEBUG
    /// A visual fixture's next frame of a Codex task (`ShowcasePlayback`), put in place as the
    /// task's provider events would leave it.
    func showVisualFixtureCodexState(_ state: CodexTaskState, for sessionID: UUID) {
        guard isVisualFixture else { return }
        codexPresentations[sessionID] = state
    }

    func updateWorkspaceReadingFixture(addTurn: Bool) {
        guard isVisualFixture, CommandLine.arguments.contains("--ui-fixture=workspace"),
              let session = store.selectedSession else { return }
        if session.harness == .codex {
            guard var state = codexPresentationBySessionID[session.id],
                  let turn = state.thread?.turns.indices.last,
                  let item = state.thread?.turns[turn].items.indices.last else { return }
            if addTurn {
                state.thread?.turns.append(CodexReadingFixtureView.turn(turn + 2))
            } else if case var .agentMessage(message) = state.thread?.turns[turn].items[item].content {
                message.text += String(repeating: "\n\nA latest-response update. Keep reading earlier content.", count: 10)
                state.thread?.turns[turn].items[item].content = .agentMessage(message)
            }
            codexPresentations[session.id] = state
        } else {
            guard var entries = transcriptBySessionID[session.id], let last = entries.indices.last else { return }
            if addTurn {
                entries.append(TranscriptEntry(content: .user(text: "A new request")))
                entries.append(TranscriptEntry(content: .assistant(text: "A new answer", isStreaming: false)))
            } else if case let .assistant(text, _) = entries[last].content {
                entries[last].content = .assistant(text: text + String(repeating: "\n\nA latest-response update.", count: 12), isStreaming: true)
            }
            transcripts[session.id] = entries
        }
    }
    #endif

    /// Converts the folder-path keyed sidebar settings and every existing task's folder into
    /// one-folder projects. The conversion is idempotent and only reads the old settings.
    private func importFolderPreferencesIfNeeded(_ preferences: LegacyProjectFolderPreferences? = nil) {
        // A task a project already shows (by its ID, its folder or its worktree's origin) needs no
        // project of its own folder, and a chat's folder never becomes one.
        projects.importFolderPreferences(
            preferences ?? legacyFolderPreferences,
            sessionWorkspaceURLs: store.sessions
                .filter { projects.project(for: $0) == nil && !ChatWorkspaces.isChat($0.workspaceURL) }
                .map(\.workspaceURL)
        )
    }

    /// The project a task belongs to, matched by stored ID or, for tasks written before projects
    /// existed, by its folder.
    func project(for session: SessionRecord) -> Project? {
        projects.project(for: session)
    }

    /// What the task information surface may say about instruction files for this task.
    func instructionSources(for session: SessionRecord) -> TaskInstructionSources {
        InstructionSourceProjection.sources(
            providerReported: instructionSourcesBySessionID[session.id],
            cwd: session.workspaceURL,
            additionalRoots: session.additionalRootURLs
        )
    }

    /// The saved tasks are loaded: what keeps a task's data (its browser profile) can be told from what
    /// was archived or deleted.
    private(set) var hasRestoredIndex = false

    func restoreIndex() async {
        guard restoresIndexOnLaunch else { return }
        isRestoringIndex = true
        defer {
            isRestoringIndex = false
            handlePendingNotificationResponses()
            handlePendingExternalLinks()
        }
        do {
            try await store.restore()
            await relocateMissingRuntimes()
            importFolderPreferencesIfNeeded(legacyFolderPreferences)
            taskWorkspaces.restoreSelection(in: store)
            splits.restore(
                knownSessionIDs: Set(store.sessions.map(\.id)),
                fallbackSessionID: store.selectedSessionID
            )
            composerDrafts.retainSessions(Set(store.sessions.map(\.id)))
            loadPersistedTranscripts()
            await loadSavedContextUsage()
            await loadPersistedGrokSessionMetadata()
            await reconcilePersistedProviderTitles()
            loadPersistedFollowUps()
            restoreQueuedSessionToolStarts()
            loadPersistedCodexHistorySelections()
            sessionListFollowIsReady = true
            hasRestoredIndex = true
        } catch {
            bootstrapError = L10n.format(
                "Could not restore tasks: %@",
                error.localizedDescription
            )
        }
    }

    /// The project a task about to start in this folder belongs to. The stored choice wins, then
    /// the project that owns the folder itself, then — for a linked worktree — the project that
    /// owns the repository it came from. Only the last resort creates a project, and never for a
    /// chat's folder (`ProjectStore.ensureProject(forTaskIn:)`): a chat has no project.
    func projectForNewTask(workspaceURL: URL, projectID: UUID?) -> Project? {
        if let chosen = projects.project(id: projectID) { return chosen }
        if projects.project(containingRoot: workspaceURL) == nil,
           let origin = store.workspaceOrigin(for: workspaceURL).originWorkspaceURL,
           let owner = projects.project(containingRoot: origin) {
            if owner.isHidden { projects.reveal(owner.id) }
            return projects.project(id: owner.id) ?? owner
        }
        return projects.ensureProject(forTaskIn: workspaceURL)
    }

    /// Starts a task from the new-task composer. A task that runs in a new worktree gets the
    /// worktree first, from the chosen folder's repository, and joins the chosen folder's
    /// project. When Git cannot make the worktree nothing is created and the error is thrown for
    /// the composer to show beside the draft. A chat gets a new folder of its own when it starts
    /// (`ChatWorkspaces.makeFolder`), as the Codex app makes one, and no project.
    func createTask(_ submission: NewTaskDraft.Submission) async throws -> SessionRecord? {
        let created = try await createSession(for: submission)
        if let created, let origin = submission.suggestion {
            await recordSuggestedTaskStart(origin, startedTask: created)
        }
        return created
    }

    private func createSession(for submission: NewTaskDraft.Submission) async throws -> SessionRecord? {
        guard let folder = submission.workspaceURL else {
            // A start that would fail anyway should not leave an empty folder behind first.
            try submission.connection?.validate(for: submission.harness)
            let chatFolder = try ChatWorkspaces.makeFolder(in: projects.chatRoot)
            let created = await createSession(
                harness: submission.harness, workspaceURL: chatFolder,
                runtimeExecutableURL: submission.runtimeURL, title: submission.title,
                titleOrigin: submission.titleOrigin,
                initialPrompt: submission.prompt, initialAttachments: submission.attachments,
                connection: submission.connection, providerOptions: submission.providerOptions,
                selectsSession: submission.selectsTask, parentTaskID: submission.parentTaskID,
                takesDraftWorkspace: submission.takesDraftWorkspace
            )
            // A chat that never came to exist takes its still empty folder with it.
            if created == nil, !store.sessions.contains(where: { Project.isSamePath($0.workspaceURL, chatFolder) }),
               (try? FileManager.default.contentsOfDirectory(atPath: chatFolder.path(percentEncoded: false)))?
                   .isEmpty == true {
                try? FileManager.default.removeItem(at: chatFolder)
            }
            return created
        }
        guard submission.startsInNewWorktree, !isVisualFixture else {
            return await createSession(
                harness: submission.harness, workspaceURL: folder,
                runtimeExecutableURL: submission.runtimeURL, title: submission.title,
                titleOrigin: submission.titleOrigin,
                initialPrompt: submission.prompt, initialAttachments: submission.attachments,
                connection: submission.connection, projectID: submission.projectID,
                providerOptions: submission.providerOptions,
                selectsSession: submission.selectsTask, parentTaskID: submission.parentTaskID,
                takesDraftWorkspace: submission.takesDraftWorkspace
            )
        }
        // A start that would fail anyway should not leave a worktree behind first.
        try submission.connection?.validate(for: submission.harness)
        let project = projectForNewTask(workspaceURL: folder, projectID: submission.projectID)
        let worktree = try await worktrees.create(from: folder, prompt: submission.prompt)
        let created = await createSession(
            harness: submission.harness, workspaceURL: worktree.workspaceURL,
            runtimeExecutableURL: submission.runtimeURL, title: submission.title,
            titleOrigin: submission.titleOrigin,
            initialPrompt: submission.prompt, initialAttachments: submission.attachments,
            connection: submission.connection, projectID: project?.id,
            sourceFolder: folder, providerOptions: submission.providerOptions,
            selectsSession: submission.selectsTask, parentTaskID: submission.parentTaskID,
            takesDraftWorkspace: submission.takesDraftWorkspace
        )
        // A task that started but then failed keeps its worktree, like any failed task keeps its
        // folder. One that never came to exist takes its worktree with it.
        if created == nil,
           !store.sessions.contains(where: { Project.isSamePath($0.workspaceURL, worktree.workspaceURL) }) {
            await worktrees.discard(worktree)
        } else if let created, worktree.largeFilesLeftAsPointers > 0 {
            addWorktreeNotice(L10n.format("In the worktree of “%@”, %lld Git LFS files stay pointers: their content isn't on this Mac.",
                                          created.title, worktree.largeFilesLeftAsPointers))
        }
        return created
    }

    /// `sourceFolder` is the folder a task in a new worktree was started from: the project's
    /// other roots still come along, and the worktree stands in for that one. `initialPromptSender`
    /// is the task that wrote `initialPrompt` (`create_task`): the prompt reaches the new task as
    /// that task's message, in Yardlet's envelope with the parent's sentence on every harness
    /// (`TaskMessage`), not as the person's. `holdsInitialPrompt` makes the task and stops there: no
    /// runtime attaches and nothing is sent until `startHeldTask` (a child that waits for room).
    @discardableResult
    func createSession(
        harness: HarnessKind,
        workspaceURL: URL,
        runtimeExecutableURL: URL,
        title: String,
        titleOrigin: SessionTitleOrigin? = nil,
        initialPrompt: String? = nil,
        initialPromptSender: (id: UUID, title: String, quotes: [TaskMessage.Quote])? = nil,
        initialAttachments: [CodexUserInput] = [],
        connection: ProviderConnection? = nil,
        projectID: UUID? = nil,
        sourceFolder: URL? = nil,
        providerOptions: [String: String] = [:],
        selectsSession: Bool = true,
        parentTaskID: UUID? = nil,
        takesDraftWorkspace: Bool = false,
        holdsInitialPrompt: Bool = false
    ) async -> SessionRecord? {
        // The task records its runtime; the harness's runtime stays the person's choice or the
        // newest install (`RuntimeSelectionStore`), not whichever runtime the last task started with.
        // A folder chosen directly still belongs to a project: find the one that owns it, or
        // make a one-folder project for it. The chosen folder stays the task's cwd. A folder
        // that is a worktree of a repository a project already owns joins that project instead
        // of becoming a second one; the task still runs in the worktree. A chat's folder gets no
        // project, and its task no other roots.
        let project = projectForNewTask(workspaceURL: workspaceURL, projectID: projectID)
        let primaryFolder = sourceFolder ?? workspaceURL
        let additionalRoots = project.map { project in
            project.contains(root: primaryFolder)
                ? project.roots
                    .filter { !Project.isSamePath($0, primaryFolder) }
                    .map { ProjectSidebarPresentation.normalizedPath(for: $0) }
                : []
        } ?? []
        var createdSessionID: UUID?
        do {
            try connection?.validate(for: harness)
            let session = try await store.createSession(
                harness: harness,
                workspaceURL: workspaceURL,
                runtimeExecutableURL: runtimeExecutableURL,
                title: title,
                titleOrigin: titleOrigin ?? (initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? .provisional
                    : .manual),
                selectsSession: selectsSession,
                providerOptions: providerOptions,
                connection: connection,
                projectID: project?.id,
                additionalRoots: additionalRoots,
                parentTaskID: parentTaskID
            )
            createdSessionID = session.id
            // Before anything waits, so the window shows the task with the new-task screen's panels.
            if takesDraftWorkspace { handOffDraftWorkspace(to: session.id) }
            if holdsInitialPrompt { return store.sessions.first(where: { $0.id == session.id }) ?? session }
            try await startCreatedSession(session, initialPrompt: initialPrompt, text: initialPrompt.map { prompt in
                initialPromptSender.map {
                    TaskMessage(senderID: $0.id.uuidString, senderName: $0.title, body: prompt,
                                relation: .parent, quotes: $0.quotes).text(in: .yardlet)
                } ?? prompt
            }, initialAttachments: initialAttachments)
            return store.sessions.first(where: { $0.id == session.id }) ?? session
        } catch {
            if let id = createdSessionID {
                guard store.sessions.contains(where: { $0.id == id }) else { return nil }
                try? await store.updateSession(id: id, status: .failed)
                errorBySessionID[id] = error.localizedDescription
            } else {
                bootstrapError = error.localizedDescription
            }
            return nil
        }
    }

    /// Starts a task `createSession(holdsInitialPrompt:)` made, as it would have started then: it
    /// attaches and `text` goes as its first message. One that cannot start is marked failed with the
    /// reason, as a new task that fails to start is; false then.
    @discardableResult
    func startHeldTask(_ session: SessionRecord, text: String) async -> Bool {
        do {
            try await startCreatedSession(session, initialPrompt: text, text: text, initialAttachments: [])
            return true
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return false }
            try? await store.updateSession(id: session.id, status: .failed)
            errorBySessionID[session.id] = error.localizedDescription
            return false
        }
    }

    /// A new task's start: its runtime attaches and its first message goes, `text` alone, or with
    /// attachments the typed way the task composer sends them.
    private func startCreatedSession(_ session: SessionRecord, initialPrompt: String?, text: String?,
                                     initialAttachments: [CodexUserInput]) async throws {
        let sends = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if sends { await markSubmissionStarted(for: session.id) }
        try await attach(session, resumesExistingSession: false)
        guard sends, let initialPrompt else { return }
        if initialAttachments.isEmpty {
            await send(text ?? initialPrompt, to: session)
        } else {
            // The first message takes the same typed path as the task composer's send.
            let draft = CodexComposerDraft(inputs: [.text(initialPrompt)] + initialAttachments)
            if session.harness == .codex {
                await submitCodex(draft, action: .automatic, to: session)
            } else {
                await send(HarnessUserInput.projecting(draft).input, to: session)
            }
        }
    }

    // MARK: - Branching: fork, side chat, new chat

    /// The one entry point for a conversation made from a task: the palette's Fork task, Codex
    /// `/fork` and New chat, Claude `/clear`, a turn's fork, the capability sheet's fork, and the
    /// side chat. `at` is how much of the source it carries; `placement` is its own selected task
    /// in the sidebar, or the parent's side chat. A fork needs the native method of the task's
    /// adapter (`HarnessSessionBranching`); only a side chat falls back to a reading snapshot,
    /// and it always carries the whole conversation. The child keeps the source's
    /// account, storage scope, runtime and project, and gets its own provider session.
    @discardableResult
    func branch(
        _ session: SessionRecord,
        at point: BranchPoint = .latest,
        placement: BranchPlacement = .sidebar
    ) async -> SessionRecord? {
        switch (placement, point) {
        case (.sidePanel, .latest):
            return await prepareSideChat(for: session)
        case (.sidePanel, _):
            return nil
        case (.sidebar, .start):
            return await startNewChat(from: session)
        case (.sidebar, .latest):
            return await forkTask(session, throughTurnID: nil)
        case let (.sidebar, .turn(turnID)):
            return await forkTask(session, throughTurnID: turnID)
        }
    }

    /// Whether the task can be forked into a task of its own, read from its adapter without
    /// attaching or probing it. A runtime's first question is answered after one hop to the
    /// registry; until then this says no, and the answer then updates observers.
    func canBranch(_ session: SessionRecord) -> Bool {
        if let adapter = adaptersBySessionID[session.id] {
            return (adapter as? any HarnessSessionBranching)?.sessionBranchMethod != nil
        }
        let key = branchRuntimeKey(for: session)
        if let known = branchMethodsByRuntime[key] { return known != nil }
        if resolvingBranchMethods.insert(key).inserted {
            Task { _ = await branchMethod(for: session) }
        }
        return false
    }

    private func branchRuntimeKey(for session: SessionRecord) -> HarnessRegistry.Key {
        HarnessRegistry.Key(harness: session.harness, executableURL: session.runtimeExecutableURL.standardizedFileURL,
            environmentScope: session.environmentScope, connection: session.connection)
    }

    /// The task's attached adapter, or the one the registry would attach it with. Asking does not
    /// start the runtime.
    private func branchMethod(for session: SessionRecord) async -> HarnessSessionBranchMethod? {
        let key = branchRuntimeKey(for: session)
        let adapter: any HarnessAdapter
        if let attached = adaptersBySessionID[session.id] {
            adapter = attached
        } else {
            adapter = await registry.adapter(for: session.harness, executableURL: session.runtimeExecutableURL,
                environmentScope: session.environmentScope, connection: session.connection)
        }
        let method = (adapter as? any HarnessSessionBranching)?.sessionBranchMethod
        branchMethodsByRuntime[key] = .some(method)
        resolvingBranchMethods.remove(key)
        return method
    }

    /// A fork into a task of its own, which is selected. Only an attached provider forks through
    /// a turn; an adapter without a native method has no fork.
    private func forkTask(_ session: SessionRecord, throughTurnID: String?) async -> SessionRecord? {
        switch await branchMethod(for: session) {
        case .savedConversation? where throughTurnID == nil:
            return await forkSavedConversation(session, selectsSession: true)
        case .attachedSession?:
            return await forkAttachedSession(session, selectsSession: true, throughTurnID: throughTurnID)
        case .savedConversation?, nil:
            return nil
        }
    }

    /// Side chats retain the source conversation, but own their input and subsequent turns.
    /// An adapter with a native method forks; any other receives a fixed context on first send.
    private func prepareSideChat(for parent: SessionRecord) async -> SessionRecord? {
        guard store.sessions.contains(where: { $0.id == parent.id }) else { return nil }
        let workspace = taskWorkspaces.state(for: parent.id)
        if let id = workspace.sideChatSessionID, id != parent.id,
           let existing = store.sessions.first(where: { $0.id == id }) { return existing }
        guard openingSideChats.insert(parent.id).inserted else { return nil }
        defer { openingSideChats.remove(parent.id) }
        sideChatErrors.removeValue(forKey: parent.id)
        let method = await branchMethod(for: parent)
        guard store.sessions.contains(where: { $0.id == parent.id }) else { return nil }
        if method == .savedConversation, !isVisualFixture {
            guard let child = await forkSavedConversation(parent, selectsSession: false) else {
                sideChatErrors[parent.id] = errorBySessionID[parent.id]
                return nil
            }
            guard matchingSession(parent) != nil else { return nil }
            workspace.sideChatSessionID = child.id
            taskWorkspaces.persistNow()
            return child
        }
        if method == .attachedSession, parent.providerSessionID != nil,
           !isVisualFixture || CommandLine.arguments.contains("--ui-fixture=lifecycle") {
            guard let child = await forkAttachedSession(parent, selectsSession: false) else { return nil }
            workspace.sideChatSessionID = child.id
            taskWorkspaces.persistNow()
            return child
        }
        flushTranscriptDeltas(for: parent.id)
        let entries = transcriptBuilders[parent.id]?.entries ?? transcriptBySessionID[parent.id] ?? []
        let context = SideChatContext(source: parent, entries: entries)
        do {
            let child = try await store.createSession(
                harness: parent.harness,
                workspaceURL: parent.workspaceURL,
                runtimeExecutableURL: parent.runtimeExecutableURL,
                title: L10n.string("Side chat"), titleOrigin: .automatic,
                environmentScope: parent.environmentScope, selectsSession: false,
                inheritedContext: context.messages.isEmpty ? nil : context,
                providerOptions: parent.providerOptions,
                connection: parent.connection
            )
            guard store.sessions.contains(where: { $0.id == parent.id }) else {
                try? await store.discardSession(id: child.id)
                return nil
            }
            workspace.sideChatSessionID = child.id
            if !context.messages.isEmpty {
                transcriptBuilders[child.id] = TranscriptBuilder(entries: context.readingEntries)
                publishTranscript(for: child.id)
            }
            taskWorkspaces.persistNow()
            return child
        } catch {
            if store.sessions.contains(where: { $0.id == parent.id }) {
                sideChatErrors[parent.id] = error.localizedDescription
            }
            return nil
        }
    }

    /// A main window reports whether it shows Tasks, and stops showing them when it closes.
    func setShowsTasks(_ shows: Bool, inWindow windowID: UUID) {
        guard taskWindowIDs.contains(windowID) != shows else { return }
        if shows { taskWindowIDs.insert(windowID) } else { taskWindowIDs.remove(windowID) }
    }

    func isSessionVisible(_ id: UUID) -> Bool {
        guard !taskWindowIDs.isEmpty, let selected = store.selectedSessionID else { return false }
        if selected == id { return true }
        let workspace = taskWorkspaces.state(for: selected)
        return workspace.panels.trailingSurfaceID == "sideChat" && workspace.sideChatSessionID == id
    }

    private func contextualDraft(_ draft: CodexComposerDraft, for sessionID: UUID) throws -> CodexComposerDraft {
        guard let context = store.sessions.first(where: { $0.id == sessionID })?.inheritedContext,
              context.nativeForkSource == nil, context.nativeConversationOrigin == nil,
              !context.isDelivered else { return draft }
        return CodexComposerDraft(inputs: [.text(try context.prefix())] + draft.inputs)
    }

    private func contextWasDelivered(to sessionID: UUID) async throws {
        guard let context = store.sessions.first(where: { $0.id == sessionID })?.inheritedContext,
              !context.isDelivered else { return }
        try await store.updateSession(id: sessionID, inheritedContextDelivered: true)
    }

    func resume(_ session: SessionRecord) async {
        guard !switchingAccounts.contains(session.id),
              let session = store.sessions.first(where: { $0.id == session.id }) else { return }
        if let refusal = sendRefusal(for: session) {
            composerDrafts.tasks.draft(for: session.id).notice = refusal.message
            return
        }
        do {
            await refreshNativeClaudeConversation(for: session)
            await refreshNativeAntigravityConversation(for: session)
            guard matchingSession(session) != nil else { return }
            try await attach(session, resumesExistingSession: session.providerSessionID != nil)
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            try? await store.updateSession(id: session.id, status: .failed)
            errorBySessionID[session.id] = error.localizedDescription
        }
    }

    func send(_ prompt: String, to session: SessionRecord) async {
        let draft = composerDrafts.tasks.draft(for: session.id)
        if draft.editState != nil {
            await submitConversationEdit(.init(inputs: [.text(prompt)] + draft.attachments), to: session)
            return
        }
        await send(HarnessUserInput(text: prompt), to: session)
    }

    /// The composer's submission, attachments included. Text-only input takes exactly the path
    /// it always took; an attachment reaches the adapter as an attachment instead of being
    /// dropped on the way to a text-only send.
    func send(_ input: HarnessUserInput, to session: SessionRecord) async {
        if composerDrafts.tasks.draft(for: session.id).editState != nil {
            await submitConversationEdit(CodexComposerDraft(inputs: [.text(input.text)]
                + input.images.map { .localImage($0.url, detail: .auto) }
                + input.mentions.compactMap(CodexUserInput.localMention(for:))), to: session)
            return
        }
        guard !sessionMutations.contains(session.id) else {
            composerDrafts.tasks.draft(for: session.id).keepDiffComments(sentIn: input.text, images: input.images.map(\.url))
            return
        }
        // Anything sent to the task takes over from a pending automatic continue.
        cancelUsageLimitAutoContinue(for: session.id)
        personActed(on: session.id)
        if usageLimitSwitchErrorBySessionID[session.id] != nil {
            usageLimitSwitchErrorBySessionID.removeValue(forKey: session.id)
        }
        var input = input
        input.text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty,
              !switchingAccounts.contains(session.id),
              let saved = store.sessions.first(where: { $0.id == session.id }) else {
            if store.sessions.contains(where: { $0.id == session.id }) {
                composerDrafts.tasks.draft(for: session.id).keepDiffComments(sentIn: input.text, images: input.images.map(\.url))
            }
            return
        }
        var session = saved
        if session.harness == .claudeCode, ClaudeComposerCommands.isResetCandidate(input.text) {
            let sourceDraft = composerDrafts.tasks.draft(for: session.id)
            let submittedDraft = sourceDraft.snapshot
            let commandName = input.text.split(whereSeparator: \.isWhitespace).first
            if commandName != "/clear", providerCapabilitiesBySessionID[session.id] == nil {
                session = await sessionWithAvailableRuntime(session)
                await loadProviderCapabilities(for: session)
                if let state = providerCapabilitiesBySessionID[session.id], !state.errors.isEmpty {
                    sourceDraft.notice = state.errors.joined(separator: "\n")
                    return
                }
            }
            guard let resetSource = matchingSession(session, allowingInitialAttachment: true) else { return }
            let commands = providerCapabilitiesBySessionID[session.id]?.composerCommands ?? []
            if ClaudeComposerCommands.isSessionReset(input.text, commands: commands) {
                guard input.images.isEmpty, input.mentions.isEmpty,
                      input.text.split(whereSeparator: \.isWhitespace).count == 1 else {
                    sourceDraft.notice = L10n.string("Start a new conversation without arguments or attachments.")
                    return
                }
                guard await restartClaudeConversation(resetSource) != nil else { return }
                if sourceDraft.snapshot == submittedDraft,
                   submittedDraft.text.trimmingCharacters(in: .whitespacesAndNewlines) == input.text,
                   submittedDraft.attachments.isEmpty { sourceDraft.clear() }
                return
            }
            // A project command may own an alias. Consume only the submitted draft after the
            // catalog resolves it; typing during the metadata read must survive.
            if sourceDraft.snapshot == submittedDraft,
               submittedDraft.text.trimmingCharacters(in: .whitespacesAndNewlines) == input.text {
                sourceDraft.clear()
            }
        }
        if session.harness == .codex {
            await submitCodex(Self.codexDraft(from: input), action: .automatic, to: session)
            return
        }
        // A conversation another app still holds is only followed here until that app lets it go, and
        // a task whose folder is gone cannot start. Nothing is sent and the message stays in the composer.
        if let refusal = sendRefusal(for: session) {
            keepUnsent(Self.codexDraft(from: input), for: session.id, reason: refusal.message)
            return
        }
        // A provider that takes messages while its turn runs queues this one instead.
        if await runningFollowUpTarget(for: session) != nil {
            await submitFollowUp(input, action: .automatic, to: session)
            return
        }
        // Messages the provider lost unread with its last runtime were sent before this one: the
        // first of them starts the turn, and the rest and this one follow it into that turn.
        if let first = followUps.queue(for: session.id).first, first.waitsToBeSteered {
            followUps.append(QueuedFollowUp(draft: CodexComposerDraft(input), steered: true), to: session.id)
            await startQueuedTurn(with: first.id, in: session, attaching: true)
            return
        }
        mutateTranscript(for: session.id, publishImmediately: true) { builder in
            builder.appendUser(input.promptText, images: input.transcriptImages)
        }
        await markSubmissionStarted(for: session.id)
        do {
            if handlesBySessionID[session.id] == nil {
                try await attach(session, resumesExistingSession: session.providerSessionID != nil)
            }
            guard let adapter = adaptersBySessionID[session.id],
                  let handle = handlesBySessionID[session.id] else {
                throw HarnessAdapterError.invalidProviderEvent(
                    L10n.string("Task did not attach to its harness")
                )
            }
            await markSubmissionStarted(for: session.id)
            errorBySessionID.removeValue(forKey: session.id)
            let submission = try contextualDraft(
                CodexComposerDraft(inputs: [.text(input.promptText)]),
                for: session.id
            )
            // Mentions are already projected into the contextual prompt; carrying them twice
            // would repeat every path in the turn the provider receives.
            var outgoing = input
            outgoing.text = submission.text
            outgoing.mentions = []
            try await adapter.send(outgoing, to: handle)
            try await contextWasDelivered(to: session.id)
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            try? await store.updateSession(id: session.id, status: .failed)
            errorBySessionID[session.id] = error.localizedDescription
            recordLocalError(error.localizedDescription, for: session.id)
            // The message stays in the conversation as sent; the diff comments it carried wait again.
            composerDrafts.tasks.draft(for: session.id).keepDiffComments(sentIn: input.text, images: input.images.map(\.url))
        }
    }

    // MARK: - Follow-up queue (plan B1)
    //
    // One queue per task in `followUps`, the same seven actions for every provider that keeps one
    // (`submitFollowUp`, `sendQueuedNow`, `removeQueued`, `editQueued`, `moveQueued`,
    // `retryQueued`, `resumeQueue`), and the provider's own way of taking a message in its
    // `FollowUpDelivery`. Codex's typed drafts enter through `submitCodex`, which queues and steers
    // the same way.

    /// A message for a task's follow-up queue: the composer's Queue and Steer, or one sent while
    /// the task's turn runs (Return follows the follow-up setting, ⌘Return does the other). Nothing
    /// here stops the running turn (2026-10-16: a message sent while Claude wrote its answer cut the
    /// answer off). Codex steers its active turn (`turn/steer`) or holds the message in Yardlet, as
    /// its typed path `submitCodex` does. Claude Code is written a steered message to read at its
    /// next step (`next`), or once the answer it is writing ends, and holds it until it does; a
    /// queued one waits in Yardlet for the turn to end. A harness that takes nothing while its turn
    /// runs holds both in Yardlet until then. Either way it shows as queued, not as a sent bubble,
    /// until the provider has it. With no turn running, a steered message is sent as any other, and
    /// a queued one waits for the queue's next send.
    /// What Return does while a turn runs (Settings), which the phone remote starts its own choice from.
    var followUpMode: FollowUpMode { FollowUpMode.current(in: preferences) }

    func submitFollowUp(_ input: HarnessUserInput, action: CodexComposerAction, to source: SessionRecord) async {
        personActed(on: source.id)
        switch FollowUpPolicy(harness: source.harness) {
        case .codex?:
            var input = input
            input.text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
            await submitCodex(Self.codexDraft(from: input), action: action, to: source)
        case let policy?:
            await submitHeldFollowUp(input, action: policy.steers ? action : .queue, to: source)
        case nil:
            return
        }
    }

    /// Codex keeps its own typed input envelopes, so attachments stay attachments instead of being
    /// flattened into the prompt on the way to its composer path.
    private static func codexDraft(from input: HarnessUserInput) -> CodexComposerDraft {
        var inputs: [CodexUserInput] = input.text.isEmpty ? [] : [.text(input.text)]
        inputs += input.mentions.compactMap(CodexUserInput.localMention(for:))
        inputs += input.images.map { .localImage($0.url, detail: .auto) }
        return CodexComposerDraft(inputs: inputs)
    }

    /// Submit a structured Codex draft. Automatic submissions start a new turn when idle; while a
    /// turn runs they steer it or enter the client-owned FIFO, as the follow-up setting says.
    /// Explicit steer never gets silently flattened into a generic harness send.
    func submitCodex(
        _ draft: CodexComposerDraft,
        action: CodexComposerAction,
        to session: SessionRecord
    ) async {
        personActed(on: session.id)
        if session.harness == .codex, CodexComposerCommands.isBuiltin(draft.text) {
            await submitCodexCommand(draft, action: action, to: session)
            return
        }
        if composerDrafts.tasks.draft(for: session.id).editState != nil {
            guard action == .automatic else {
                composerDrafts.tasks.draft(for: session.id).notice = L10n.string("Edited messages cannot be queued or steered.")
                return
            }
            await submitConversationEdit(draft, to: session)
            return
        }
        guard !sessionMutations.contains(session.id) else {
            composerDrafts.tasks.draft(for: session.id).keepDiffComments(sentIn: draft.text, images: draft.imageURLs)
            return
        }
        guard session.harness == .codex,
              !draft.isEmpty,
              store.sessions.contains(where: { $0.id == session.id }) else { return }
        // Holding a message in the queue starts nothing; sending or steering it would.
        if action != .queue, let refusal = sendRefusal(for: session) {
            keepUnsent(draft, for: session.id, reason: refusal.message)
            return
        }
        appendCodexDraftToTranscript(draft, for: session.id)

        if action == .queue {
            queueCodexDraft(draft, for: session)
            return
        }
        let followUpMode = FollowUpMode.current(in: preferences)

        // The deterministic UI fixture owns a hydrated active turn but deliberately has no
        // provider adapter. Preserve the same client-side queue/fail-closed contract that a
        // disconnected packaged task would expose instead of probing its `/usr/bin/true`
        // placeholder or inventing a provider turn/steer response.
        if isVisualFixture && !CommandLine.arguments.contains("--ui-fixture=lifecycle") {
            if action == .automatic, followUpMode == .queue,
               codexPresentationBySessionID[session.id]?.activeTurnID != nil {
                queueCodexDraft(draft, for: session)
                return
            }
            let message = L10n.string("Codex steer is unavailable for this runtime")
            queueCodexDraft(draft, for: session, failureMessage: message)
            errorBySessionID[session.id] = message
            recordLocalError(message, for: session.id)
            return
        }

        // A follow-up to a running turn leaves the running state alone, which would otherwise also
        // hide a pending approval.
        let followsRunningTurn = isRunning(session.id)
        if action == .automatic, !followsRunningTurn {
            await markSubmissionStarted(for: session.id)
        }
        var startedTurn = false
        var steersRunningTurn = false
        do {
            if handlesBySessionID[session.id] == nil {
                try await attach(session, resumesExistingSession: session.providerSessionID != nil)
            }
            guard let delivery = followUpDelivery(for: session) else {
                throw HarnessAdapterError.invalidProviderEvent(
                    L10n.string("Task did not attach to its harness")
                )
            }
            if let message = codexModelRestoreErrors[session.id] {
                throw HarnessAdapterError.capabilityUnavailable(message)
            }
            let runningTurn = await delivery.runningTurn(reportedRunning: followsRunningTurn)
            switch action {
            case .automatic:
                if let runningTurn {
                    guard followUpMode == .steer else {
                        queueCodexDraft(draft, for: session)
                        return
                    }
                    steersRunningTurn = true
                    try await delivery.steer(QueuedFollowUp(draft: draft), into: runningTurn, priority: .next)
                } else {
                    // Attaching reports the task ready; the new turn makes it running again.
                    startedTurn = true
                    await markSubmissionStarted(for: session.id)
                    try await delivery.start(draft) { try contextualDraft($0, for: session.id) }
                }
            case .steer:
                guard let runningTurn else {
                    throw HarnessAdapterError.capabilityUnavailable(
                        L10n.string("Codex steer requires an active turn")
                    )
                }
                try await delivery.steer(QueuedFollowUp(draft: draft), into: runningTurn, priority: .next)
            case .queue:
                // Queue is handled before attachment above.
                break
            }
            if startedTurn { try await contextWasDelivered(to: session.id) }
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            errorBySessionID.removeValue(forKey: session.id)
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            // A rejected steer leaves the running turn as it was; the draft is kept below.
            if action == .automatic, !steersRunningTurn {
                try? await store.updateSession(id: session.id, status: .failed)
            }
            queueCodexDraft(draft, for: session, failureMessage: error.localizedDescription)
            errorBySessionID[session.id] = error.localizedDescription
            recordLocalError(error.localizedDescription, for: session.id)
        }
    }

    /// Holds a Codex draft in the queue, already in the conversation, or keeps one that could not
    /// be sent there as failed.
    private func queueCodexDraft(_ draft: CodexComposerDraft, for session: SessionRecord, failureMessage: String? = nil) {
        guard store.sessions.contains(where: { $0.id == session.id }) else { return }
        followUps.append(QueuedFollowUp(draft: draft, state: failureMessage == nil ? .pending : .failed,
                                        failureMessage: failureMessage), to: session.id)
    }

    /// `submitFollowUp` for a provider other than Codex. Steering writes the message to Claude Code
    /// to read at its next step (`next`): the CLI queues it, hands it to the model at its next tool
    /// boundary or once the answer it is writing ends, and never stops the turn for it. Queueing,
    /// and every message to a harness that cannot steer, keeps it in Yardlet until the turn ends.
    private func submitHeldFollowUp(
        _ input: HarnessUserInput,
        action: CodexComposerAction,
        to source: SessionRecord
    ) async {
        guard let session = store.sessions.first(where: { $0.id == source.id }),
              !sessionMutations.contains(session.id), !switchingAccounts.contains(session.id) else {
            if store.sessions.contains(where: { $0.id == source.id }) {
                composerDrafts.tasks.draft(for: source.id).keepDiffComments(sentIn: input.text, images: input.images.map(\.url))
            }
            return
        }
        var input = input
        input.text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        if action != .automatic, composerDrafts.tasks.draft(for: session.id).editState != nil {
            composerDrafts.tasks.draft(for: session.id).notice = L10n.string("Edited messages cannot be queued or steered.")
            return
        }
        cancelUsageLimitAutoContinue(for: session.id)
        let target = await runningFollowUpTarget(for: session)
        let mode: FollowUpMode = switch action {
        case .automatic: FollowUpMode.current(in: preferences)
        case .queue: .queue
        case .steer: .steer
        }
        guard mode == .steer else {
            followUps.append(QueuedFollowUp(draft: CodexComposerDraft(input)), to: session.id)
            if target == nil { scheduleFollowUpDrain(for: session.id) }
            return
        }
        guard let target else {
            await send(input, to: session)
            return
        }
        followUps.append(QueuedFollowUp(draft: CodexComposerDraft(input), steered: true), to: session.id)
        await steerInOrder(into: target, in: session.id)
    }

    /// Writes into the running turn, in their order, the messages Yardlet holds on their way into it
    /// (`QueuedFollowUp.waitsToBeSteered`): one just steered, and those the provider lost unread with
    /// its last runtime, which go first. One that cannot go now (another action has it, or the
    /// provider refused it) keeps the rest waiting behind it, so no message reaches the provider
    /// before one sent earlier (2026-10-23: after an update restart, the message another task sent
    /// before the quit reached its parent after one it sent after).
    private func steerInOrder(into target: FollowUpTarget, in sessionID: UUID) async {
        guard target.delivery.policy.steers else { return }
        while let next = followUps.queue(for: sessionID).first(where: \.waitsToBeSteered) {
            guard followUps.claim(next.id) else { return }
            await steerFollowUp(next.id, priority: .next, into: target, in: sessionID)
            followUps.finish(next.id)
            guard followUps.item(next.id, in: sessionID)?.waitsToBeSteered != true,
                  followUps.item(next.id, in: sessionID)?.state != .failed else { return }
        }
    }

    /// Sends one queued message without stopping the running turn: Codex's Steer adds it to the
    /// turn, Claude Code reads it at its next step. A harness that cannot steer keeps it for the
    /// turn's end. With no turn running, the message starts the next turn. The rest of the queue
    /// keeps its order and any pause.
    func sendQueuedNow(_ itemID: UUID, for source: SessionRecord) async {
        guard let session = matchingSession(source, allowingInitialAttachment: true),
              let item = followUps.item(itemID, in: session.id),
              !sessionMutations.contains(session.id), !switchingAccounts.contains(session.id) else { return }
        guard let target = await runningFollowUpTarget(for: session) else {
            await startQueuedTurn(with: itemID, in: session, attaching: true)
            return
        }
        guard target.delivery.policy.steers, item.state == .pending, followUps.claim(itemID) else { return }
        defer { followUps.finish(itemID) }
        await steerFollowUp(itemID, priority: .next, into: target, in: session.id)
    }

    /// Stop and send: the one queue action that stops the running turn for a message, Claude Code's
    /// Send now. A Claude Code that reads Send now itself (`interrupt_send_now_v1`) is asked to read
    /// the message at once: it moves a running command to the background so the turn takes the
    /// message in, or stops the turn when it cannot; a message Yardlet holds is written to it first.
    /// An older CLI gets the previous behavior: a message Yardlet holds is steered into the running
    /// turn, and one the CLI holds is sent again with priority `now`, which ends the turn at its next
    /// step. With no turn running, the message starts the next turn.
    func stopAndSendQueued(_ itemID: UUID, for source: SessionRecord) async {
        guard let session = matchingSession(source, allowingInitialAttachment: true),
              followUps.item(itemID, in: session.id) != nil,
              !sessionMutations.contains(session.id), !switchingAccounts.contains(session.id) else { return }
        guard let target = await runningFollowUpTarget(for: session) else {
            await startQueuedTurn(with: itemID, in: session, attaching: true)
            return
        }
        guard target.delivery.policy.stopAndSendLabel != nil else { return }
        await sendFollowUpNow(itemID, into: target, in: session)
    }

    /// `stopAndSendQueued` once a turn is running: the provider reads the message now.
    private func sendFollowUpNow(_ itemID: UUID, into target: FollowUpTarget, in session: SessionRecord) async {
        guard let item = followUps.item(itemID, in: session.id), followUps.claim(itemID) else { return }
        defer { followUps.finish(itemID) }
        if let message = codexModelRestoreErrors[session.id] {
            markFollowUpFailed(itemID, message: message, in: session.id)
            return
        }
        if await target.delivery.canSendHeldNow() {
            if item.state != .sent {
                await steerFollowUp(itemID, priority: .next, into: target, in: session.id)
            }
            guard let sent = followUps.item(itemID, in: session.id), sent.state == .sent else { return }
            do {
                // The read arrives as the message's `started`, which places its bubble.
                try await target.delivery.sendHeldNow(sent)
            } catch {
                if store.sessions.contains(where: { $0.id == session.id }) {
                    composerDrafts.tasks.draft(for: session.id).notice = error.localizedDescription
                }
            }
            return
        }
        if item.state == .sent {
            // Out of the provider's queue first, so the message is not read twice.
            guard await withdrawFollowUp(item, in: session) else { return }
            await steerFollowUp(itemID, priority: .now, into: target, in: session.id)
        } else {
            await steerFollowUp(itemID, priority: .next, into: target, in: session.id)
        }
    }

    /// Remove from queue. A message the provider holds is withdrawn from it first; one it has
    /// already taken stays until it shows in the conversation.
    func removeQueued(_ itemID: UUID, for source: SessionRecord) async {
        guard let session = matchingSession(source, allowingInitialAttachment: true),
              let item = followUps.item(itemID, in: session.id), followUps.claim(itemID) else { return }
        defer { followUps.finish(itemID) }
        if item.state == .sent {
            guard await withdrawFollowUp(item, in: session) else { return }
        }
        followUps.remove(itemID, from: session.id)
    }

    /// Moves a queued message back into the composer to change it. One the provider holds is
    /// withdrawn first and arrives in the composer once the provider lets it go. A draft already
    /// in the composer is never replaced; the message then stays queued.
    @discardableResult
    func editQueued(_ itemID: UUID, for session: SessionRecord) -> CodexComposerDraft? {
        guard store.sessions.contains(where: { $0.id == session.id }),
              let item = followUps.item(itemID, in: session.id),
              !followUps.isClaimed(itemID) else { return nil }
        let composer = composerDrafts.tasks.draft(for: session.id)
        guard composer.editState == nil, composer.isMessageEmpty else {
            composer.notice = L10n.string("Send or clear the current draft before editing a queued message.")
            return nil
        }
        guard item.state != .sent else {
            Task { await editHeldFollowUp(itemID, for: session) }
            return nil
        }
        followUps.remove(itemID, from: session.id)
        composer.restoreUnsent(item.draft)
        composerDrafts.persistNow()
        return item.draft
    }

    /// Reorders the queue. Messages Claude Code holds stay ahead of the rest, in the order the
    /// CLI reads them.
    func moveQueued(_ itemID: UUID, in session: SessionRecord, to index: Int) {
        guard let policy = FollowUpPolicy(harness: session.harness) else { return }
        followUps.move(itemID, in: session.id, to: index, policy: policy)
    }

    /// A failed message waits to be sent again, and goes once no turn is running.
    func retryQueued(_ itemID: UUID, for session: SessionRecord) {
        guard followUps.retry(itemID, in: session.id) else { return }
        scheduleFollowUpDrain(for: session.id)
    }

    /// Continues a queue paused by an interrupt. Its first message goes once no turn is running.
    func resumeQueue(for session: SessionRecord) {
        guard followUps.resume(session.id) else { return }
        scheduleFollowUpDrain(for: session.id)
    }

    // MARK: Delivery

    /// The provider side of a task's follow-up queue, when its runtime is attached.
    private func followUpDelivery(for session: SessionRecord) -> (any FollowUpDelivery)? {
        guard let policy = FollowUpPolicy(harness: session.harness),
              let adapter = adaptersBySessionID[session.id],
              let handle = handlesBySessionID[session.id] else { return nil }
        return policy.delivery(adapter: adapter, handle: handle)
    }

    /// The attached runtime of a task whose turn a follow-up can join now. A Claude Code turn takes
    /// what is sent meanwhile into its own queue instead of starting a turn.
    private func runningFollowUpTarget(for session: SessionRecord) async -> FollowUpTarget? {
        guard let delivery = followUpDelivery(for: session),
              let turn = await delivery.runningTurn(reportedRunning: isRunning(session.id)) else { return nil }
        return FollowUpTarget(delivery: delivery, turn: turn)
    }

    private struct FollowUpTarget {
        let delivery: any FollowUpDelivery
        let turn: FollowUpTurn
    }

    /// Whether the task's own status says a turn is running.
    private func isRunning(_ sessionID: UUID) -> Bool {
        let status = store.sessions.first(where: { $0.id == sessionID })?.status
        return status == .running || status == .waitingForApproval
    }

    /// Whether a task is in a turn, for the Yardlet MCP server's broker, which tells a task's
    /// server about changed tools only between turns.
    func isInTurn(_ sessionID: UUID) -> Bool {
        isRunning(sessionID)
    }

    /// A queued message joins the running turn. Codex has it at once, so it leaves the queue. Claude
    /// Code holds it under a new message ID, placed where the CLI reads it (after the others it
    /// holds, or first when it stops the turn for it), until it reports reading it. A refused one
    /// stays queued as failed, with the reason.
    private func steerFollowUp(
        _ itemID: UUID,
        priority: HarnessFollowUpPriority,
        into target: FollowUpTarget,
        in sessionID: UUID
    ) async {
        let holds = target.delivery.policy.holdsSentMessages
        if holds {
            // Every write takes a new ID: the CLI drops a second message with an ID it has seen.
            followUps.markSent(itemID, messageID: UUID().uuidString.lowercased(), first: priority == .now, in: sessionID)
        }
        guard let item = followUps.item(itemID, in: sessionID) else { return }
        do {
            try await target.delivery.steer(item, into: target.turn, priority: priority)
            guard !holds, store.sessions.contains(where: { $0.id == sessionID }) else { return }
            followUps.remove(itemID, from: sessionID)
        } catch {
            guard store.sessions.contains(where: { $0.id == sessionID }) else { return }
            markFollowUpFailed(itemID, message: error.localizedDescription, in: sessionID)
        }
    }

    /// Starts the next turn with a message Yardlet holds, as a message typed into an idle task is
    /// sent. Where the provider's conversation shows a message only once it has it (Claude Code),
    /// its bubble appears now.
    private func startQueuedTurn(with itemID: UUID, in session: SessionRecord, attaching: Bool) async {
        guard let item = followUps.item(itemID, in: session.id), item.state != .sent,
              !sessionMutations.contains(session.id), !switchingAccounts.contains(session.id),
              composerDrafts.tasks.draft(for: session.id).editState == nil,
              attaching || handlesBySessionID[session.id] != nil,
              !Task.isCancelled, followUps.claim(itemID) else { return }
        defer { followUps.finish(itemID) }
        do {
            if handlesBySessionID[session.id] == nil {
                try await attach(session, resumesExistingSession: session.providerSessionID != nil)
            }
            guard let delivery = followUpDelivery(for: session) else {
                throw HarnessAdapterError.invalidProviderEvent(L10n.string("Task did not attach to its harness"))
            }
            if let message = codexModelRestoreErrors[session.id] {
                throw HarnessAdapterError.capabilityUnavailable(message)
            }
            await markSubmissionStarted(for: session.id)
            try await delivery.start(item.draft) { try contextualDraft($0, for: session.id) }
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            followUps.remove(itemID, from: session.id)
            if !delivery.policy.recordsMessagesWhenQueued {
                let input = HarnessUserInput.projecting(item.draft).input
                mutateTranscript(for: session.id, publishImmediately: true) { builder in
                    builder.appendUser(input.promptText, images: input.transcriptImages)
                }
            }
            try await contextWasDelivered(to: session.id)
            // What was on its way into a running turn joins this one, in its order.
            if let target = await runningFollowUpTarget(for: session) {
                await steerInOrder(into: target, in: session.id)
            }
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            try? await store.updateSession(id: session.id, status: .failed)
            markFollowUpFailed(itemID, message: error.localizedDescription, in: session.id)
        }
    }

    private func scheduleFollowUpDrain(for sessionID: UUID) {
        guard followUpDrainTasks[sessionID] == nil, !followUps.queue(for: sessionID).isEmpty else { return }
        followUpDrainTasks[sessionID] = Task { [weak self] in
            defer { self?.followUpDrainTasks[sessionID] = nil }
            await self?.drainFollowUps(for: sessionID)
        }
    }

    /// Sends the first message Yardlet holds once no turn runs. While the provider still holds one
    /// (Claude Code), it starts that turn itself, so the queue waits for it.
    private func drainFollowUps(for sessionID: UUID) async {
        guard let session = store.sessions.first(where: { $0.id == sessionID }), !followUps.isPaused(sessionID),
              let delivery = followUpDelivery(for: session),
              case let queue = followUps.queue(for: sessionID),
              !queue.contains(where: { $0.state == .sent || followUps.isClaimed($0.id) }),
              let first = queue.first, first.state == .pending,
              await delivery.runningTurn(reportedRunning: isRunning(sessionID)) == nil else { return }
        await startQueuedTurn(with: first.id, in: session, attaching: false)
    }

    // MARK: Messages the provider holds

    private func editHeldFollowUp(_ itemID: UUID, for session: SessionRecord) async {
        guard let item = followUps.item(itemID, in: session.id), item.state == .sent,
              followUps.claim(itemID) else { return }
        defer { followUps.finish(itemID) }
        guard await withdrawFollowUp(item, in: session) else { return }
        let composer = composerDrafts.tasks.draft(for: session.id)
        guard composer.editState == nil, composer.isMessageEmpty else {
            // Something was typed while the provider answered; the message waits in Yardlet instead.
            followUps.hold(itemID, in: session.id)
            composer.notice = L10n.string("Send or clear the current draft before editing a queued message.")
            return
        }
        followUps.remove(itemID, from: session.id)
        composer.restoreUnsent(item.draft)
        composerDrafts.persistNow()
    }

    /// Takes a sent follow-up back out of the provider's queue. False when the provider already
    /// took it or could not answer; its refusal shows on the composer.
    private func withdrawFollowUp(_ item: QueuedFollowUp, in session: SessionRecord) async -> Bool {
        guard item.providerMessageID != nil, let delivery = followUpDelivery(for: session) else { return true }
        do {
            return try await delivery.withdraw(item)
        } catch {
            if store.sessions.contains(where: { $0.id == session.id }) {
                composerDrafts.tasks.draft(for: session.id).notice = error.localizedDescription
            }
            return false
        }
    }

    /// Takes back every message the provider still holds before an interrupt, which it would
    /// otherwise run next. Each waits in Yardlet with the rest of the paused queue.
    private func withdrawSentFollowUps(in session: SessionRecord) async {
        for item in followUps.queue(for: session.id) where item.state == .sent {
            guard followUps.claim(item.id) else { continue }
            defer { followUps.finish(item.id) }
            if await withdrawFollowUp(item, in: session) {
                followUps.hold(item.id, in: session.id)
            }
        }
    }

    /// What the harness predicts the person sends next, a moment after its turn ended. It waits in
    /// the task's draft for the composer, which shows it while nothing is typed. One that arrives
    /// after the next turn began (the person sent first) is dropped; it is never sent or kept.
    private func acceptNextMessageSuggestion(_ text: String, for sessionID: UUID) {
        guard let session = store.sessions.first(where: { $0.id == sessionID }),
              session.status != .running, session.status != .waitingForApproval,
              let suggestion = NextMessageSuggestionText.normalized(text) else { return }
        composerDrafts.tasks.draft(for: sessionID).nextMessageSuggestion = suggestion
    }

    /// The provider took a follow-up into a turn, here in the stream, so its bubble goes here — inside
    /// the running turn when the provider read it there (D13); or it let one go unread, which stays
    /// in the queue as failed so it can be sent again.
    private func acceptFollowUpDelivery(_ delivery: HarnessFollowUpDelivery, for sessionID: UUID) {
        guard let policy = store.sessions.first(where: { $0.id == sessionID }).flatMap({ FollowUpPolicy(harness: $0.harness) }),
              let item = followUps.sentItem(messageID: delivery.messageID, in: sessionID) else { return }
        switch delivery.state {
        case .read:
            followUps.remove(item.id, from: sessionID)
            let input = HarnessUserInput.projecting(item.draft).input
            let images = input.transcriptImages
            mutateTranscript(for: sessionID, publishImmediately: true) { builder in
                builder.appendUser(input.promptText.isEmpty && images.isEmpty
                    ? L10n.string("Attached context") : input.promptText, images: images,
                    joinsRunningTurn: delivery.joinsRunningTurn == true)
            }
        case .dropped:
            markFollowUpFailed(item.id, message: policy.droppedMessage, in: sessionID)
        }
    }

    /// A turn Claude Code started with a command it queued itself opens here, so what Claude answered
    /// before stays that turn's answer (2026-10-22: a check-in's work had folded into the turn before
    /// as its commentary; 2026-10-24: so had a final report, under the answer to a background agent's
    /// notice). Its request is read from the CLI's saved record once the CLI has written it — 2.1.299
    /// writes its transcript every 100 ms, and the stream carries no `user` frame for it — under
    /// `messageID`, or as the newest request when the command had no uuid (a background task's notice),
    /// and reads as the saved conversation reads it: a schedule's prompt as the schedule's, a
    /// background task's notice as the notice, another session's message as sent. Until then, or when
    /// it is never found, the turn shows no request.
    private func openProviderTurn(_ messageID: String?, for sessionID: UUID) {
        guard let session = store.sessions.first(where: { $0.id == sessionID }), session.harness == .claudeCode
        else { return }
        var entryID: UUID?
        mutateTranscript(for: sessionID, publishImmediately: true) { builder in
            entryID = builder.appendUser("", origin: .provider)
        }
        guard let entryID, let providerID = session.providerSessionID else { return }
        let reader = claudeSessionReader(for: session)
        Task { [weak self] in
            for delay in Self.providerTurnRequestReadDelays {
                try? await Task.sleep(for: delay)
                let request = try? await Task.detached(priority: .utility) {
                    if let messageID { return try reader.request(savedUnder: messageID, sessionID: providerID) }
                    return try reader.newestRequestClaudeSent(sessionID: providerID)
                }.value
                guard let request else { continue }
                if let request = request.first {
                    self?.mutateTranscript(for: sessionID, publishImmediately: true) { builder in
                        builder.settleRequest(of: entryID, as: request)
                    }
                }
                return
            }
        }
    }

    /// When a provider-started turn's saved request is looked for: from just after the CLI's first
    /// write (100 ms) until about ten seconds on.
    static let providerTurnRequestReadDelays: [Duration] = [.milliseconds(150), .milliseconds(300),
        .milliseconds(600), .milliseconds(1_200), .milliseconds(2_400), .milliseconds(4_800)]

    private func markFollowUpFailed(_ itemID: UUID, message: String, in sessionID: UUID) {
        guard followUps.markFailed(itemID, message: message, in: sessionID) else { return }
        reportTaskError(message, in: sessionID)
    }

    /// Says in the task's conversation, as an error it can go on from, what Yardlet did not do for it.
    func reportTaskError(_ message: String, in sessionID: UUID) {
        errorBySessionID[sessionID] = message
        recordLocalError(message, for: sessionID)
    }

    // MARK: Claude bash mode

    func shellCommandRun(entryID: UUID) -> ClaudeShellCommandRun? {
        shellRunsByEntryID[entryID]
    }

    func isShellCommandRunning(in session: SessionRecord) -> Bool {
        runningShellCommandBySessionID[session.id] != nil
    }

    /// Tasks running a bash-mode command. They show as running in the sidebar and keep the Mac
    /// awake, while their provider status stays what the provider says.
    var shellBusySessionIDs: Set<UUID> {
        Set(runningShellCommandBySessionID.keys)
    }

    /// A Codex task whose thread says it was forked from, or is a subagent of, a thread another
    /// Yardlet task continues is linked to that task the first time its thread is read
    /// (`TaskLineage`), so tasks imported or opened before links were kept nest too.
    private func linkCodexParentIfNeeded(for id: UUID) {
        guard let thread = codexPresentations[id]?.thread,
              let parentThread = TaskLineage.codexParentThreadID(forkedFromID: thread.forkedFromID,
                                                                 parentThreadID: thread.parentThreadID),
              let session = store.sessions.first(where: { $0.id == id }), session.parentTaskID == nil,
              !session.isLineageDetached,
              let parent = TaskLineage.task(continuing: parentThread, harness: session.harness, among: store.sessions,
                                           environmentScope: session.environmentScope, connection: session.connection),
              parent != id, linkingCodexParents.insert(id).inserted else { return }
        Task {
            defer { linkingCodexParents.remove(id) }
            guard matchingSession(session) != nil else { return }
            _ = try? await store.linkParents([id: parent])
        }
    }

    /// Rereads one task's `TaskAttentionDetail` after its transcript or Codex timeline was set.
    func refreshAttentionDetail(for id: UUID) {
        let answerLine = codexPresentations[id].flatMap(TaskAttentionDetail.answerLine)
            ?? transcripts[id].flatMap(TaskAttentionDetail.answerLine)
        if answerLines[id] != answerLine { answerLines[id] = answerLine }
        let transcript = transcripts[id].map(TaskAttentionDetail.reading) ?? .none
        var detail = codexPresentations[id].map { TaskAttentionDetail.reading($0).merged(over: transcript) } ?? transcript
        // A session tool's own approval, or one its subagent waits on, is an approval the task waits on.
        if sessionToolWaitsForPerson(in: id) { detail.pendingRequest = .approval }
        if restartQuestions[id] != nil {
            if restartQuestion(in: id) != nil {
                detail.idleRequest = .input
            } else {
                // The provider's record went on past the question (another app continued the
                // conversation): it no longer waits, here or after a later quit.
                restartQuestions.removeValue(forKey: id)
                restartResumesToContinue.removeValue(forKey: id)
            }
        }
        if connectionResumes[id]?.isWaiting == true { detail.isReconnecting = true }
        if let wait = browserWaits[id] { detail.browserWait = wait.wait }
        if detail == .none {
            if taskAttentionDetails[id] != nil { taskAttentionDetails.removeValue(forKey: id) }
        } else if taskAttentionDetails[id] != detail {
            taskAttentionDetails[id] = detail
        }
    }

    /// A provider turn or a bash-mode command is running somewhere: the Mac stays awake.
    var hasRunningWork: Bool {
        !runningShellCommandBySessionID.isEmpty || store.sessions.contains { $0.status == .running }
    }

    /// Running work keeps the Mac awake. With the remote on and a phone paired, a task waiting on
    /// an approval does too, so the phone can still reach the Mac to answer it.
    var keepsMacAwake: Bool {
        let remote = remoteControl
        return Self.keepsMacAwake(
            hasRunningWork: hasRunningWork,
            phoneCanAnswer: remote?.isEnabled == true && remote?.devices.isEmpty == false,
            sessions: store.sessions)
    }

    nonisolated static func keepsMacAwake(hasRunningWork: Bool, phoneCanAnswer: Bool, sessions: [SessionRecord]) -> Bool {
        hasRunningWork || (phoneCanAnswer && sessions.contains { $0.status == .waitingForApproval })
    }

    /// Bash mode (`!`) of a Claude task, as the Claude app's Code tab has it: the command runs in
    /// the task's own login shell, which stays open in the task's folder between commands, and the
    /// conversation shows it with its output as the output arrives. When it ends, the command and
    /// its output go to Claude as one message, which Claude answers; while a turn runs, or messages
    /// wait in the queue, it goes once the task is idle, as the Claude app waits. A stopped command
    /// is not sent. One command runs at a time.
    func runShellCommand(_ command: String, in source: SessionRecord) {
        guard let session = store.sessions.first(where: { $0.id == source.id }), session.harness == .claudeCode,
              !switchingAccounts.contains(session.id), !sessionMutations.contains(session.id) else { return }
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        guard runningShellCommandBySessionID[session.id] == nil else {
            composerDrafts.tasks.draft(for: session.id).notice = L10n.string("A shell command is already running")
            return
        }
        // Anything sent to the task takes over from a pending automatic continue.
        cancelUsageLimitAutoContinue(for: session.id)
        personActed(on: session.id)
        var entryID = UUID()
        mutateTranscript(for: session.id, publishImmediately: true) { builder in
            entryID = builder.appendUser(ClaudeBashMessage.inputText(command: command))
        }
        let run = ClaudeShellCommandRun(id: entryID, sessionID: session.id, command: command)
        shellRunsByEntryID[entryID] = run
        runningShellCommandBySessionID[session.id] = entryID
        let process = taskShells.command(command, for: session.id, in: session.workspaceURL)
        process.onOutput = { [weak run] output in run?.output = output }
        process.onFinish = { [weak self] result in self?.finishShellCommand(entryID, with: result) }
        shellProcesses[entryID] = process
        process.start()
    }

    /// Stops the task's running command: Control-C first, then its process tree.
    func stopShellCommand(in source: SessionRecord) {
        guard let entryID = runningShellCommandBySessionID[source.id] else { return }
        shellProcesses[entryID]?.stop()
    }

    private func finishShellCommand(_ entryID: UUID, with result: ShellCommandResult) {
        shellProcesses.removeValue(forKey: entryID)
        guard let run = shellRunsByEntryID[entryID] else { return }
        let sessionID = run.sessionID
        if runningShellCommandBySessionID[sessionID] == entryID {
            runningShellCommandBySessionID.removeValue(forKey: sessionID)
        }
        run.output = result.output
        run.exitCode = result.exitCode
        let text: String
        if let error = result.launchError {
            // The Claude app still sends a command that could not run, with the reason as stderr.
            run.state = .failed(error)
            text = ClaudeBashMessage.text(command: run.command, stdout: "", stderr: error)
        } else {
            run.state = result.wasStopped ? .stopped : .finished
            text = ClaudeBashMessage.text(command: run.command, stdout: result.output)
        }
        guard store.sessions.contains(where: { $0.id == sessionID }) else { return }
        mutateTranscript(for: sessionID, publishImmediately: true) { $0.replaceUserText(of: entryID, with: text) }
        guard !result.wasStopped else { return }
        pendingShellDeliveries[sessionID, default: []].append(ClaudeShellDelivery(entryID: entryID, text: text))
        persistShellDeliveries(for: sessionID)
        scheduleShellDelivery(for: sessionID)
    }

    private func persistShellDeliveries(for sessionID: UUID) {
        followUps.saveShellDeliveries(pendingShellDeliveries[sessionID] ?? [], for: sessionID)
    }

    private func scheduleShellDelivery(for sessionID: UUID) {
        guard shellDeliveryTasks[sessionID] == nil, pendingShellDeliveries[sessionID]?.isEmpty == false else { return }
        shellDeliveryTasks[sessionID] = Task { [weak self] in
            defer { self?.shellDeliveryTasks[sessionID] = nil }
            await self?.deliverShellCommand(for: sessionID)
        }
    }

    /// Sends the oldest finished command once the task is idle and holds no queued message, as
    /// the Claude app waits for the turn and for messages ahead of it. Its message starts a turn,
    /// and the next one waits for that turn to end.
    private func deliverShellCommand(for sessionID: UUID) async {
        guard let session = store.sessions.first(where: { $0.id == sessionID }), session.harness == .claudeCode,
              session.status != .running, session.status != .waitingForApproval,
              !sessionMutations.contains(sessionID), !switchingAccounts.contains(sessionID),
              !followUps.queue(for: sessionID).contains(where: { $0.state != .failed }),
              let delivery = pendingShellDeliveries[sessionID]?.first else { return }
        pendingShellDeliveries[sessionID]?.removeFirst()
        if pendingShellDeliveries[sessionID]?.isEmpty == true { pendingShellDeliveries.removeValue(forKey: sessionID) }
        persistShellDeliveries(for: sessionID)
        do {
            if handlesBySessionID[sessionID] == nil {
                try await attach(session, resumesExistingSession: session.providerSessionID != nil)
            }
            guard let adapter = adaptersBySessionID[sessionID], let handle = handlesBySessionID[sessionID] else {
                throw HarnessAdapterError.invalidProviderEvent(L10n.string("Task did not attach to its harness"))
            }
            // Output saved before quitting: its row is gone if the conversation was read again.
            if !(transcriptBySessionID[sessionID] ?? []).contains(where: { $0.id == delivery.entryID }) {
                mutateTranscript(for: sessionID, publishImmediately: true) { $0.appendUser(delivery.text) }
            }
            await markSubmissionStarted(for: sessionID)
            let submission = try contextualDraft(CodexComposerDraft(inputs: [.text(delivery.text)]), for: sessionID)
            try await adapter.send(HarnessUserInput(text: submission.text), to: handle)
            try await contextWasDelivered(to: sessionID)
        } catch {
            guard store.sessions.contains(where: { $0.id == sessionID }) else { return }
            try? await store.updateSession(id: sessionID, status: .failed)
            errorBySessionID[sessionID] = error.localizedDescription
            recordLocalError(error.localizedDescription, for: sessionID)
        }
    }

    /// A task that goes away, or the app quitting, ends the task's shell and the command running
    /// in it. Unsent output stays saved: the next launch sends it, unless the task went away.
    private func discardShellCommands(for sessionID: UUID) {
        if let entryID = runningShellCommandBySessionID.removeValue(forKey: sessionID) {
            shellProcesses.removeValue(forKey: entryID)?.terminate()
        }
        taskShells.close(sessionID)
        shellDeliveryTasks.removeValue(forKey: sessionID)?.cancel()
        pendingShellDeliveries.removeValue(forKey: sessionID)
        shellRunsByEntryID = shellRunsByEntryID.filter { $0.value.sessionID != sessionID }
    }

    /// Load the next provider-owned turn page without replacing the reducer state. The provider
    /// remains authoritative for cursor semantics; the adapter merges the page by stable turn ID
    /// and republishes it through the existing presentation stream. A detached task reads the page
    /// read-only instead (`loadEarlierDetachedCodexTurns`): asking for history never attaches it.
    func loadMoreCodexTurns(for session: SessionRecord) async {
        guard session.harness == .codex,
              store.sessions.contains(where: { $0.id == session.id }),
              let cursor = codexPresentationBySessionID[session.id]?.thread?.turnsNextCursor,
              !cursor.isEmpty,
              codexTurnPageLoads.insert(session.id).inserted else { return }
        defer { codexTurnPageLoads.remove(session.id) }

        guard handlesBySessionID[session.id] != nil else {
            await loadEarlierDetachedCodexTurns(for: session, before: cursor)
            return
        }
        do {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            guard let adapter = adaptersBySessionID[session.id],
                  let provider = adapter as? any CodexPresentationProviding,
                  let handle = handlesBySessionID[session.id] else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.string("Codex history is unavailable for this task")
                )
            }
            _ = try await provider.loadTurns(for: handle, cursor: cursor, limit: CodexThreadPaging.earlierTurns)
            // The page is merged by the adapter's presentation stream. Do not treat a page that
            // completed after deletion as an action owned by the removed task.
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            updateCodexActionError(error, for: session.id)
        }
    }

    /// Load the next provider-owned item page for one hydrated turn. Item cursors are scoped to
    /// both the local task and turn so independent turns can paginate without suppressing one
    /// another, while repeated taps on the same turn remain idempotent until the request exits.
    func loadMoreCodexItems(for session: SessionRecord, turnID: String) async {
        guard session.harness == .codex,
              store.sessions.contains(where: { $0.id == session.id }),
              let cursor = codexPresentationBySessionID[session.id]?.thread?.turns
                  .first(where: { $0.id == turnID })?.itemsNextCursor,
              !cursor.isEmpty else { return }
        let loadKey = "\(session.id.uuidString):\(turnID)"
        guard codexItemPageLoads.insert(loadKey).inserted else { return }
        defer { codexItemPageLoads.remove(loadKey) }

        do {
            if handlesBySessionID[session.id] == nil {
                try await attach(session, resumesExistingSession: session.providerSessionID != nil)
            }
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            guard let adapter = adaptersBySessionID[session.id],
                  let provider = adapter as? any CodexPresentationProviding,
                  let handle = handlesBySessionID[session.id] else {
                throw HarnessAdapterError.capabilityUnavailable(
                    L10n.string("Codex history is unavailable for this task")
                )
            }
            _ = try await provider.loadItems(
                for: handle,
                turnID: turnID,
                cursor: cursor,
                limit: 100
            )
            // Item pages are merged by the adapter's presentation stream. A page that completes
            // after deletion must not be considered a live action for the removed task.
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            updateCodexActionError(error, for: session.id)
        }
    }

    /// Retries the latest turn an error that can pass ended (`ConversationTurnActions.canRetry`), the
    /// way the task's own app does: Codex continues its thread with an empty turn, Claude Code is sent
    /// the Claude app's retry message.
    func retryTurn(_ turnID: String, in session: SessionRecord) async {
        if session.harness == .codex {
            await retryCodexTurn(turnID, in: session)
        } else {
            await retryTranscriptTurn(in: session)
        }
    }

    /// Capacity recovery sends no user input and preserves both the retained native history
    /// and the current composer. It is never queued or steered into a different active turn.
    private func retryCodexTurn(_ turnID: String, in session: SessionRecord) async {
        guard canRetryCodexTurn(turnID, in: session),
              sessionMutations.insert(session.id).inserted else { return }
        defer { sessionMutations.remove(session.id) }
        do {
            let (adapter, _, handle) = try await codexProvider(for: session)
            guard canRetryCodexTurn(turnID, in: session, allowingMutation: true) else { return }
            guard let recovery = adapter as? any CodexTurnRecovering else {
                throw HarnessAdapterError.capabilityUnavailable(L10n.string("Retry is unavailable for this Codex runtime."))
            }
            if let message = codexModelRestoreErrors[session.id] {
                throw HarnessAdapterError.capabilityUnavailable(message)
            }
            await markSubmissionStarted(for: session.id)
            guard matchingSession(session) != nil else { return }
            try await recovery.retryFailedTurn(turnID, in: handle)
        } catch {
            guard matchingSession(session) != nil else { return }
            if store.sessions.first(where: { $0.id == session.id })?.status == .running,
               codexPresentationBySessionID[session.id]?.activeTurnID == nil {
                try? await store.updateSession(id: session.id, status: .failed)
            }
            updateCodexActionError(error, for: session.id)
        }
    }

    /// The Claude app's retry of a turn an error ended (`retryLastTurn`): its retry message, sent as the
    /// person's, which leaves the composer as it is. It goes only to the task as the card left it: idle,
    /// the transient error still its last entry, no message being edited, none queued.
    private func retryTranscriptTurn(in source: SessionRecord) async {
        flushTranscriptDeltas(for: source.id)
        guard let session = matchingSession(source),
              session.status == .ready || session.status == .failed,
              case .error(_, _, true?)? = transcriptBuilders[session.id]?.entries.last?.content,
              composerDrafts.tasks.draft(for: session.id).editState == nil,
              followUps.queue(for: session.id).isEmpty,
              !switchingAccounts.contains(session.id), !sessionMutations.contains(session.id) else { return }
        await send(HarnessUserInput(text: RestartContinuation.claudeRetry), to: session)
    }

    private func canRetryCodexTurn(_ turnID: String, in source: SessionRecord, allowingMutation: Bool = false) -> Bool {
        guard let session = matchingSession(source), session.harness == .codex,
              session.status == .ready || session.status == .failed,
              !switchingAccounts.contains(session.id),
              allowingMutation || !sessionMutations.contains(session.id),
              composerDrafts.tasks.draft(for: session.id).editState == nil,
              followUps.queue(for: session.id).isEmpty,
              let state = codexPresentationBySessionID[session.id] else { return false }
        return state.thread?.id == session.providerSessionID
            && CodexTurnRecoveryProjection.canRetry(turnID, in: state)
    }

    private func submitCodexCommand(_ input: CodexComposerDraft, action: CodexComposerAction, to source: SessionRecord) async {
        let draft = composerDrafts.tasks.draft(for: source.id)
        guard let session = matchingSession(source) else { return }
        let command = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard command == "/compact" || command == "/review", input.inputs.count == 1,
              action == .automatic, draft.editState == nil, followUps.queue(for: session.id).isEmpty,
              session.status != .running, session.status != .waitingForApproval,
              !switchingAccounts.contains(session.id), sessionMutations.insert(session.id).inserted else {
            draft.notice = L10n.string("Use this command with an empty composer while the chat is idle.")
            return
        }
        defer { sessionMutations.remove(session.id) }
        let snapshot = draft.snapshot
        if command == "/review" {
            pendingCodexReview = CodexReviewRequest(session: session, draft: snapshot)
            return
        }
        do {
            let (_, provider, handle) = try await codexProvider(for: session)
            guard matchingSession(session, allowingInitialAttachment: true) != nil else { return }
            try await provider.compactConversation(in: handle)
            if matchingSession(session, allowingInitialAttachment: true) != nil, draft.snapshot == snapshot { draft.clear() }
        } catch {
            if matchingSession(session, allowingInitialAttachment: true) != nil { draft.notice = error.localizedDescription }
        }
    }

    /// Runs one of the Codex app's slash commands chosen from the composer list. The list has
    /// already removed the typed `/name`; nothing here sends or clears the rest of the draft.
    /// Window surfaces (rename, side chat) and composer surfaces (model picker, skills) are
    /// handled by the views that own them.
    func runCodexComposerCommand(_ command: CodexComposerCommand, in source: SessionRecord) async {
        guard source.harness == .codex, let session = matchingSession(source) else { return }
        let draft = composerDrafts.tasks.draft(for: session.id)
        let isRunning = session.status == .running || session.status == .waitingForApproval
        switch command {
        case .compact:
            // The Codex app keeps Compact in the list and explains why it does nothing mid-turn.
            guard !isRunning else {
                draft.notice = L10n.string("Compact is disabled while a chat is in progress")
                return
            }
            guard draft.editState == nil, followUps.queue(for: session.id).isEmpty, !switchingAccounts.contains(session.id),
                  sessionMutations.insert(session.id).inserted else {
                draft.notice = L10n.string("Use this command with an empty composer while the chat is idle.")
                return
            }
            defer { sessionMutations.remove(session.id) }
            do {
                let (_, provider, handle) = try await codexProvider(for: session)
                guard matchingSession(session, allowingInitialAttachment: true) != nil else { return }
                try await provider.compactConversation(in: handle)
            } catch {
                if matchingSession(session, allowingInitialAttachment: true) != nil { draft.notice = error.localizedDescription }
            }
        case .codeReview:
            guard !isRunning, draft.editState == nil, followUps.queue(for: session.id).isEmpty,
                  !switchingAccounts.contains(session.id), !sessionMutations.contains(session.id) else {
                draft.notice = L10n.string("Use this command with an empty composer while the chat is idle.")
                return
            }
            pendingCodexReview = CodexReviewRequest(session: session, draft: nil)
        case .fork:
            _ = await branch(session)
        case .newChat:
            _ = await branch(session, at: .start)
        case .pin:
            await togglePinned(session)
        case .archive:
            await archive(session)
        case let .serviceTier(tier):
            let catalog = composerCodexCapabilities(for: matchingSession(session) ?? session).modelCatalog
            guard let selection = catalog.selectingServiceTier(catalog.serviceTier == tier ? "default" : tier) else { return }
            guard isAttached(session.id) else { return await chooseCodexModelBeforeAttach(selection, for: session) }
            do { try await applyCodexModel(selection, for: session) }
            catch { if matchingSession(session, allowingInitialAttachment: true) != nil { draft.notice = error.localizedDescription } }
        case .planMode:
            var state = codexCapabilitiesBySessionID[session.id] ?? .empty
            if state.modes.isEmpty {
                // A restored task shows its saved mode before the runtime lists its presets; the
                // toggle reads them now so it leaves or enters the mode the composer shows.
                do {
                    let (_, provider, _) = try await codexProvider(for: session)
                    let modes = try await provider.collaborationModes()
                    guard let current = matchingSession(session, allowingInitialAttachment: true) else { return }
                    if codexCapabilitiesBySessionID[session.id]?.modes.isEmpty != false {
                        codexCapabilitiesBySessionID[session.id, default: .empty].modes = modes
                        restoreCodexMode(in: &codexCapabilitiesBySessionID[session.id, default: .empty], from: current)
                    }
                    state = codexCapabilitiesBySessionID[session.id] ?? .empty
                } catch {
                    if matchingSession(session, allowingInitialAttachment: true) != nil { draft.notice = error.localizedDescription }
                    return
                }
            }
            let isPlan = state.modes.first { $0.id == state.selectedModeID }?.mode == "plan"
            // Leaving Plan returns to the provider's Default preset, or to no preset without one.
            let preset = isPlan ? state.modes.first { $0.mode == "default" } : state.modes.first { $0.mode == "plan" }
            guard isPlan || preset != nil else { return }
            do { try await applyCodexMode(preset, for: session) }
            catch { if matchingSession(session, allowingInitialAttachment: true) != nil { draft.notice = error.localizedDescription } }
        case .initialize:
            guard !isRunning, draft.editState == nil else { return }
            let instructions = session.workspaceURL.appending(path: CodexInitPrompt.fileName)
            guard !FileManager.default.fileExists(atPath: instructions.path(percentEncoded: false)) else {
                draft.notice = L10n.string("AGENTS.md already exists here. Skipping /init to avoid overwriting it")
                return
            }
            await submitCodex(CodexComposerDraft(inputs: [.text(CodexInitPrompt.text)]), action: .automatic, to: session)
        case .status:
            await openCodexStatus(for: session)
        case .rename, .sideChat, .model, .reasoning, .skill:
            break
        }
    }

    /// Opens the task's status panel and reads the rate limits of the account it runs under. The
    /// read goes to the App Server the task already uses, or to the one its account would use, so
    /// a task that has not started its thread does not start one. No turn starts either way.
    func openCodexStatus(for source: SessionRecord) async {
        guard source.harness == .codex, let session = matchingSession(source) else { return }
        let previous = codexStatusBySessionID[session.id]?.rateLimits
        codexStatusBySessionID[session.id] = CodexStatusReading(rateLimits: previous, isReading: true)
        let limits = await readCodexRateLimits(for: session)
        // Closed while reading: the panel stays closed. A reading of an account the task has
        // since left is not shown; the thread starting meanwhile changes nothing.
        guard codexStatusBySessionID[session.id] != nil else { return }
        let sameAccount = store.sessions.contains {
            $0.id == session.id && $0.connection == session.connection && $0.environmentScope == session.environmentScope
        }
        codexStatusBySessionID[session.id] = CodexStatusReading(
            rateLimits: sameAccount ? limits ?? previous : previous, isReading: false)
    }

    func closeCodexStatus(for session: SessionRecord) {
        codexStatusBySessionID.removeValue(forKey: session.id)
    }

    private func readCodexRateLimits(for session: SessionRecord) async -> CodexAccountRateLimits? {
        guard !isVisualFixture, !switchingAccounts.contains(session.id) else { return nil }
        if let connection = session.connection {
            guard (try? connection.validate(for: session.harness)) != nil else { return nil }
            if let home = connection.homePath, !FileManager.default.fileExists(atPath: home) { return nil }
        }
        let adapter: any HarnessAdapter
        if let attached = adaptersBySessionID[session.id] {
            adapter = attached
        } else {
            adapter = await registry.adapter(for: session.harness, executableURL: session.runtimeExecutableURL,
                                             environmentScope: session.environmentScope, connection: session.connection)
        }
        guard let provider = adapter as? any CodexCapabilityProviding else { return nil }
        return try? await provider.accountRateLimits()
    }

    /// Reads what the Codex command list shows beyond its fixed commands: the model catalog (Fast,
    /// reasoning), collaboration modes (Plan mode) and skills. No turn starts. A task without a
    /// Codex thread is not attached for this, so opening the list never creates a thread.
    func prepareCodexComposerCommands(for source: SessionRecord) async {
        guard source.harness == .codex, !isVisualFixture, let session = matchingSession(source),
              handlesBySessionID[session.id] != nil || session.providerSessionID != nil,
              !switchingAccounts.contains(session.id) else { return }
        let state = codexCapabilitiesBySessionID[session.id] ?? .empty
        guard state.modelCatalog.models.isEmpty || state.modes.isEmpty || state.skills.isEmpty,
              preparingCodexCommands.insert(session.id).inserted else { return }
        defer { preparingCodexCommands.remove(session.id) }
        guard let attached = try? await codexProvider(for: session),
              matchingSession(session, allowingInitialAttachment: true) != nil else { return }
        let provider = attached.1, handle = attached.2
        if state.modelCatalog.models.isEmpty, let catalog = try? await provider.modelCatalog(for: handle),
           matchingSession(session, allowingInitialAttachment: true) != nil,
           codexCapabilitiesBySessionID[session.id]?.modelCatalog.models.isEmpty != false {
            codexCapabilitiesBySessionID[session.id, default: .empty].modelCatalog = catalog
            modelCatalogs.recordCodex(catalog, for: session)
        }
        if state.modes.isEmpty, let modes = try? await provider.collaborationModes(),
           let current = matchingSession(session, allowingInitialAttachment: true),
           codexCapabilitiesBySessionID[session.id]?.modes.isEmpty != false {
            codexCapabilitiesBySessionID[session.id, default: .empty].modes = modes
            restoreCodexMode(in: &codexCapabilitiesBySessionID[session.id, default: .empty], from: current)
        }
        if state.skills.isEmpty, let skills = try? await provider.skills(in: session.workspaceURL),
           matchingSession(session, allowingInitialAttachment: true) != nil,
           codexCapabilitiesBySessionID[session.id]?.skills.isEmpty != false {
            codexCapabilitiesBySessionID[session.id, default: .empty].skills = skills
        }
    }

    private func appendCodexDraftToTranscript(_ draft: CodexComposerDraft, for sessionID: UUID) {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = draft.inputs.compactMap(\.sentImage)
        let fallback = images.isEmpty && draft.inputs.contains { input in
            if case .text = input { return false }
            return true
        } ? L10n.string("Attached context") : ""
        guard !text.isEmpty || !fallback.isEmpty || !images.isEmpty else { return }
        mutateTranscript(for: sessionID, publishImmediately: true) { builder in
            builder.appendUser(text.isEmpty ? fallback : text, images: images)
        }
    }

    private func markSubmissionStarted(for sessionID: UUID) async {
        guard store.sessions.contains(where: { $0.id == sessionID }) else { return }
        stoppedByPerson.remove(sessionID)
        unseenRestartResumes.removeValue(forKey: sessionID)
        submissionStartedAt[sessionID] = Date()
        errorBySessionID.removeValue(forKey: sessionID)
        composerDrafts.tasks.existingDraft(for: sessionID)?.nextMessageSuggestion = nil
        try? await store.updateSession(
            id: sessionID,
            status: .running,
            completionState: SessionCompletionState.none
        )
    }

    func interrupt(_ session: SessionRecord) async {
        // Stopping a turn stops its subagents and refuses what its session tools wait on.
        await stopSessionToolWork(for: session.id)
        guard let current = store.sessions.first(where: { $0.id == session.id }),
              let adapter = adaptersBySessionID[session.id],
              let handle = handlesBySessionID[session.id] else { return }
        personActed(on: session.id)
        // As in the Codex app, stopping a turn also holds what is queued behind it until Resume.
        // The pause is in place before the interrupt so the turn's end cannot send the next one.
        let isRunning = current.status == .running || current.status == .waitingForApproval
        if isRunning { stoppedByPerson.insert(session.id) }
        let pausesQueue = isRunning && followUps.pause(session.id)
        // Claude Code keeps what it holds through an interrupt and runs it next, so those messages
        // come back first and wait with the rest.
        if isRunning { await withdrawSentFollowUps(in: current) }
        do {
            try await adapter.interrupt(handle)
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            if pausesQueue { resumeQueue(for: current) }
            errorBySessionID[session.id] = error.localizedDescription
        }
    }

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: SessionRecord
    ) async {
        await respond(to: permissionRequestID, action: nil, decision: decision, in: session)
    }

    /// Answers with the provider's own approval option. The adapter receives the option the
    /// provider defined instead of a plain allow or deny it would have to map itself.
    func respond(
        to permissionRequestID: String,
        action: PermissionRequestAction,
        in session: SessionRecord
    ) async {
        await respond(
            to: permissionRequestID,
            action: action,
            decision: action.decision,
            in: session
        )
    }

    /// Answers a request whose provider asked a question or submitted a plan. The answer is the
    /// provider's own content coming back, so it reaches the adapter as an answer rather than as
    /// an allow that would discard what the user chose.
    func respond(
        to permissionRequestID: String,
        answer: PermissionStructuredAnswer,
        in session: SessionRecord
    ) async {
        await respond(
            to: permissionRequestID,
            action: nil,
            answer: answer,
            decision: answer.decision,
            in: session
        )
    }

    private func respond(
        to permissionRequestID: String,
        action: PermissionRequestAction?,
        answer: PermissionStructuredAnswer? = nil,
        decision: PermissionDecision,
        in session: SessionRecord
    ) async {
        // A session tool's own approval, or a request its subagent waits on, is answered there.
        if await answerSessionToolRequest(permissionRequestID, action: action, answer: answer, decision: decision,
                                          in: session.id) { return }
        if await answerRestartQuestion(permissionRequestID, answer: answer, in: session) { return }
        guard store.sessions.contains(where: { $0.id == session.id }),
              let adapter = adaptersBySessionID[session.id],
              let handle = handlesBySessionID[session.id] else { return }
        do {
            if let answer, let responder = adapter as? any HarnessStructuredPermissionResponding {
                try await responder.respond(
                    to: permissionRequestID,
                    answer: answer,
                    in: handle
                )
            } else if let action,
                      let responder = adapter as? any HarnessPermissionActionResponding {
                try await responder.respond(
                    to: permissionRequestID,
                    selectedActionID: action.id,
                    in: handle
                )
            } else {
                try await adapter.respond(
                    to: permissionRequestID,
                    decision: decision,
                    in: handle
                )
            }
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            var pending = codexPendingRequestRepository.load(for: session.id)
            pending.removeAll { $0.id == permissionRequestID }
            if pending.isEmpty {
                codexPendingRequestRepository.remove(for: session.id)
            } else {
                codexPendingRequestRepository.save(pending, for: session.id)
            }
            mutateTranscript(for: session.id, publishImmediately: true) { builder in
                builder.resolvePermission(id: permissionRequestID, decision: decision)
            }
            withdrawAnsweredApprovalNotifications(for: session.id)
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            errorBySessionID[session.id] = error.localizedDescription
            recordLocalError(error.localizedDescription, for: session.id)
        }
    }

    func respondCodex(
        to serverRequestID: String,
        response: CodexServerRequestResponse,
        in session: SessionRecord
    ) async {
        // A Codex subagent's request is answered in its own thread.
        if await answerSessionToolCodexRequest(serverRequestID, response: response, in: session.id) { return }
        if await answerRestartQuestion(serverRequestID, codexResponse: response, in: session) { return }
        guard session.harness == .codex,
              store.sessions.contains(where: { $0.id == session.id }) else { return }
        guard let adapter = adaptersBySessionID[session.id],
              let provider = adapter as? any CodexPresentationProviding,
              let handle = handlesBySessionID[session.id] else {
            if isVisualFixture {
                await resolveVisualFixtureCodexRequest(
                    serverRequestID,
                    response: response,
                    for: session.id
                )
            }
            return
        }
        do {
            try await provider.respond(to: serverRequestID, response: response, in: handle)
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            if var state = codexPresentationBySessionID[session.id],
               let request = state.serverRequestsByID[serverRequestID],
               let result = response.result(for: request.method),
               CodexTaskReducer().resolveServerRequest(
                   id: serverRequestID,
                   response: result,
                   in: &state
               ) {
                codexPresentations[session.id] = state
                persistCodexServerRequests(state, for: session.id)
                persistCodexTimelineItems(state, for: session.id)
            }
            withdrawAnsweredApprovalNotifications(for: session.id)
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            errorBySessionID[session.id] = error.localizedDescription
            recordLocalError(error.localizedDescription, for: session.id)
        }
    }

    private func resolveVisualFixtureCodexRequest(
        _ serverRequestID: String,
        response: CodexServerRequestResponse,
        for sessionID: UUID
    ) async {
        guard var state = codexPresentationBySessionID[sessionID],
              let request = state.serverRequestsByID[serverRequestID],
              let result = response.result(for: request.method),
              CodexTaskReducer().resolveServerRequest(
                  id: serverRequestID,
                  response: result,
                  in: &state
              ) else { return }
        codexPresentations[sessionID] = state
        persistCodexServerRequests(state, for: sessionID)
        persistCodexTimelineItems(state, for: sessionID)
        if store.sessions.first(where: { $0.id == sessionID })?.status == .waitingForApproval {
            try? await store.updateSession(id: sessionID, status: .running)
        }
    }

    func archive(_ session: SessionRecord) async {
        worktreeNotice = nil
        guard let archived = await archiveTask(session) else { return }
        await cleanUpWorktree(afterArchiving: archived)
    }

    /// The task as it was archived, or nil when it was not.
    @discardableResult
    private func archiveTask(_ session: SessionRecord) async -> SessionRecord? {
        guard let session = store.sessions.first(where: { $0.id == session.id }) else { return nil }
        bootstrapError = nil
        var archivedInProvider = false
        do {
            // An attached task whose provider keeps its own sessions is archived there before its
            // local record is removed. Detached tasks keep the existing lazy local-archive behavior.
            if let (provider, handle) = attachedSessionLifecycle(for: session.id) {
                try await provider.archiveProviderSession(handle)
                archivedInProvider = true
                guard store.sessions.contains(where: { $0.id == session.id }) else { return nil }
            }
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return nil }
            bootstrapError = error.localizedDescription
            return nil
        }
        guard store.sessions.contains(where: { $0.id == session.id }) else { return nil }
        await removeSessionState(for: session, removal: .archive(providerArchived: archivedInProvider))
        return store.sessions.contains(where: { $0.id == session.id }) ? nil : session
    }

    /// Archiving the last task in one of Yardlet's worktrees removes the worktree when nothing in
    /// it would be lost, and otherwise keeps it and says why. While another task still works in
    /// it, it is left for that task's own archive. Its branch always stays. Returns what the
    /// notice says about this task's worktree, if anything.
    @discardableResult
    private func cleanUpWorktree(afterArchiving session: SessionRecord) async -> String? {
        let layout = worktrees.layout
        guard !isVisualFixture,
              !store.sessions.contains(where: { $0.id == session.id }),
              let worktree = layout.worktreeURL(containing: session.workspaceURL),
              !store.sessions.contains(where: { layout.worktreeURL(containing: $0.workspaceURL) == worktree })
        else { return nil }
        let message: String? = switch await worktrees.cleanUp(
            workspaceURL: session.workspaceURL, recordedBranch: session.branch
        ) {
        case .removed, .untouched:
            nil
        case .keptUncommittedChanges:
            L10n.format("Kept the worktree of “%@” because it has uncommitted changes.", session.title)
        case let .keptUnmergedCommits(branch?):
            L10n.format("Kept the worktree of “%@” because %@ has commits that aren't on another branch.",
                        session.title, branch)
        case .keptUnmergedCommits(nil):
            L10n.format("Kept the worktree of “%@” because it has commits that aren't on any branch.", session.title)
        case let .failed(reason):
            L10n.format("Couldn't remove the worktree of “%@”: %@", session.title, reason)
        }
        if let message { addWorktreeNotice(message) }
        return message
    }

    /// An unarchived task whose worktree was removed gets it back from its branch, in the same
    /// place, so its provider session finds the folder it ran in: its Yardlet worktree on its own, and
    /// any worktree it recorded (`worktreeName`) when the person asks (`recreateTaskWorktree`).
    private func restoreWorktree(for session: SessionRecord, worktreeName: String? = nil) async {
        guard !isVisualFixture else { return }
        let message: String? = switch await worktrees.restore(
            workspaceURL: session.workspaceURL, repositoryURL: session.originWorkspaceURL, branch: session.branch,
            worktreeName: worktreeName
        ) {
        case .notNeeded:
            nil
        case .recreated:
            L10n.format("Recreated the worktree of “%@” from %@.", session.title, session.branch ?? "")
        case let .repositoryMissing(path):
            L10n.format("Couldn't recreate the worktree of “%@” because the repository at %@ no longer exists.",
                        session.title, path)
        case let .branchMissing(branch?):
            L10n.format("Couldn't recreate the worktree of “%@” because %@ no longer exists.", session.title, branch)
        case .branchMissing(nil):
            L10n.format("Couldn't recreate the worktree of “%@” because it has no branch to check out.", session.title)
        case let .failed(reason):
            L10n.format("Couldn't recreate the worktree of “%@”: %@", session.title, reason)
        }
        if let message { addWorktreeNotice(message) }
    }

    private func addWorktreeNotice(_ message: String) {
        worktreeNotice = [worktreeNotice, message].compactMap { $0 }.joined(separator: "\n")
    }

    func dismissWorktreeNotice() {
        worktreeNotice = nil
    }

    // MARK: - A task whose folder is gone

    /// Whether this window's harnesses need each task's folder: they start in it.
    private var checksTaskFolders: Bool { !isVisualFixture && registry.startsHarnessesInTaskFolders }

    /// The task's folder, when it is gone, which the composer then says; a folder that is back is
    /// forgotten. What was learned of its worktree stays until it is looked at again.
    @discardableResult
    func taskFolderMissing(_ session: SessionRecord) -> TaskFolderMissing? {
        guard checksTaskFolders, var missing = TaskFolderMissing(workspaceURL: session.workspaceURL) else {
            if missingTaskFolders[session.id] != nil { missingTaskFolders.removeValue(forKey: session.id) }
            return nil
        }
        missing.worktreeBranch = missingTaskFolders[session.id]?.worktreeBranch
        if missingTaskFolders[session.id] != missing { missingTaskFolders[session.id] = missing }
        return missing
    }

    /// Looks at a task's folder and, when it is gone, at whether its worktree can be made again from
    /// its branch in the same place.
    func refreshTaskFolder(_ id: UUID) async {
        guard let session = store.sessions.first(where: { $0.id == id }), taskFolderMissing(session) != nil
        else { return }
        let branch = await worktrees.restorableBranch(
            workspaceURL: session.workspaceURL, repositoryURL: session.originWorkspaceURL, branch: session.branch,
            worktreeName: session.worktreeName
        )
        guard let session = store.sessions.first(where: { $0.id == id }), var missing = taskFolderMissing(session)
        else { return }
        missing.worktreeBranch = branch
        if missingTaskFolders[id] != missing { missingTaskFolders[id] = missing }
    }

    /// Makes the task's worktree again in its folder from its branch, as the Codex app restores a
    /// worktree it cleaned up. The window's worktree notice says how that went; the provider session
    /// and storage scope are untouched.
    func recreateTaskWorktree(_ id: UUID) async {
        guard !recreatingTaskWorktrees.contains(id), let session = store.sessions.first(where: { $0.id == id })
        else { return }
        recreatingTaskWorktrees.insert(id)
        await restoreWorktree(for: session, worktreeName: session.worktreeName)
        recreatingTaskWorktrees.remove(id)
        await refreshTaskFolder(id)
    }

    /// Why a message for the task waits instead of going to it: another app's process holds its Claude
    /// conversation, or the task's folder is gone. Every way a message reaches a task asks this first —
    /// the composer, Codex's composer, another task's message, the phone — and starting the task's
    /// harness refuses the same (`attach`).
    func sendRefusal(for session: SessionRecord) -> TaskSendRefusal? {
        if isHeldElsewhere(session) { return .heldElsewhere }
        return taskFolderMissing(session).map(TaskSendRefusal.folderMissing)
    }

    /// Keeps a message the task did not take in its composer, with the reason as the composer's notice.
    private func keepUnsent(_ unsent: CodexComposerDraft, for sessionID: UUID, reason: String) {
        let draft = composerDrafts.tasks.draft(for: sessionID)
        if draft.text.isEmpty, draft.attachments.isEmpty, draft.editState == nil {
            draft.restoreUnsent(unsent)
        } else {
            draft.keepDiffComments(sentIn: unsent.text, images: unsent.imageURLs)
        }
        draft.notice = reason
    }

    func loadArchivedTasks() async {
        do {
            try await store.loadArchivedSessions()
            archivedTaskError = nil
        } catch {
            archivedTaskError = error.localizedDescription
        }
    }

    /// Brings an archived task back to the sidebar with its provider session ID, account binding,
    /// storage scope, and project unchanged. A session Yardlet archived in the provider (a Codex
    /// thread) is unarchived there first; one Yardlet never archived there is left alone. A Yardlet
    /// worktree that archiving removed is checked out again from its branch, or the notice says
    /// why it could not be; the task comes back either way. Nothing is resumed and no turn
    /// starts: the task attaches the next time it is opened.
    func unarchive(_ archived: ArchivedSessionRecord) async {
        let session = archived.session
        guard !store.sessions.contains(where: { $0.id == session.id }),
              unarchivingSessionIDs.insert(session.id).inserted else { return }
        defer { unarchivingSessionIDs.remove(session.id) }
        archivedTaskError = nil
        worktreeNotice = nil
        do {
            if archived.isProviderArchived, !isVisualFixture,
               let providerSessionID = session.providerSessionID {
                try session.connection?.validate(for: session.harness)
                let runtime = FileManager.default.isExecutableFile(atPath: session.runtimeExecutableURL.path(percentEncoded: false))
                    ? session.runtimeExecutableURL
                    : RuntimeRelocation.successor(of: session.runtimeExecutableURL, for: session.harness)
                        ?? runtimeSelections.selectedURL(for: session.harness) ?? session.runtimeExecutableURL
                let adapter = await registry.adapter(for: session.harness, executableURL: runtime,
                    environmentScope: session.environmentScope, connection: session.connection)
                _ = try await adapter.probeRuntime()
                guard let provider = adapter as? any HarnessSessionLifecycleProviding else {
                    throw HarnessAdapterError.capabilityUnavailable(
                        "\(session.harness.displayName) session unarchive is unavailable"
                    )
                }
                try await provider.unarchiveProviderSession(providerSessionID: providerSessionID)
            }
            // The folder comes back first, while the row still shows it is being restored, so the
            // task is never listed without the worktree it runs in.
            await restoreWorktree(for: session)
            guard let restored = try await store.unarchiveSession(id: session.id) else { return }
            // The person's choice: following the other app's list does not archive it again while
            // that app still has it archived.
            if [.claudeCode, .codex].contains(restored.harness), restored.providerSessionID != nil {
                keepListedWhileSourceArchives(restored.id)
            }
            // A task from a project that was later hidden would otherwise come back out of sight.
            if let project = projects.project(for: restored), project.isHidden {
                projects.reveal(project.id)
            }
        } catch {
            archivedTaskError = error.localizedDescription
        }
    }

    /// What archiving one task in a batch came to: archived, or not and why, and what the worktree
    /// notice says about its worktree. `archive_task` reports it task by task.
    struct TaskArchiveOutcome: Equatable {
        let sessionID: UUID
        var failure: String?
        var worktreeNotice: String?
    }

    @discardableResult
    func archive(_ sessions: [SessionRecord]) async -> [TaskArchiveOutcome] {
        worktreeNotice = nil
        var firstFailure: String?
        var archived: [SessionRecord] = []
        var outcomes: [TaskArchiveOutcome] = []
        for session in sessions {
            guard store.sessions.contains(where: { $0.id == session.id }) else {
                outcomes.append(TaskArchiveOutcome(sessionID: session.id, failure: "that task is no longer listed."))
                continue
            }
            if let record = await archiveTask(session) {
                archived.append(record)
                outcomes.append(TaskArchiveOutcome(sessionID: session.id))
            } else {
                outcomes.append(TaskArchiveOutcome(
                    sessionID: session.id, failure: bootstrapError ?? "that task left the list while it was archived."))
            }
            if firstFailure == nil { firstFailure = bootstrapError }
        }
        // A later successful removal must not hide an earlier failure in the same project.
        if let firstFailure { bootstrapError = firstFailure }
        // Every task leaves the list before any worktree is looked at, so a large batch is not
        // held up by Git, and a worktree several of them shared is judged once they all left.
        for session in archived {
            let notice = await cleanUpWorktree(afterArchiving: session)
            if let index = outcomes.firstIndex(where: { $0.sessionID == session.id }) {
                outcomes[index].worktreeNotice = notice
            }
        }
        return outcomes
    }

    func togglePinned(_ session: SessionRecord) async {
        do {
            try await store.togglePinned(id: session.id)
        } catch {
            bootstrapError = error.localizedDescription
        }
    }

    /// "Detach to top level" on a task listed under the task it was started from: only Yardlet's
    /// index changes (`SessionStore.detachFromParent`); the provider's history and the other app's
    /// files stay as they are.
    func detachFromParent(_ session: SessionRecord) async {
        do {
            try await store.detachFromParent(id: session.id)
        } catch {
            bootstrapError = error.localizedDescription
        }
    }

    /// The moves a task's menus offer (`TaskProjectMove`): the projects in `visibleProjects`, the
    /// sidebar's in its order, and Chats when the task's folder is a chat's.
    func projectMoveOptions(for session: SessionRecord, visibleProjects: [Project]) -> TaskProjectMove.Options {
        TaskProjectMove.options(for: session, visibleProjects: visibleProjects, projects: projects.projects,
                                home: projects.chatWorkspaceHome)
    }

    /// Moves a task to `project`, or out of its project to Chats (nil), as the Codex app's sidebar
    /// does. Only the task's project and the roots that come along change; its folder, provider
    /// session, storage scope, account, history, draft and pin stay as they are, and nothing is
    /// written to the provider. A running task moves too, as in the Codex app: the move is where
    /// the task is listed, its turn and attached session go on untouched, and the new roots reach
    /// the harness the next time it starts or resumes the session.
    @discardableResult
    func moveTask(_ session: SessionRecord, to project: Project?) async -> SessionRecord? {
        guard let current = store.sessions.first(where: { $0.id == session.id }) else { return nil }
        // The project as it is now, so the roots that come along are its current ones.
        let target = project.flatMap { projects.project(id: $0.id) }
        guard project == nil || target != nil else { return nil }
        let options = projectMoveOptions(for: current, visibleProjects: projects.projects)
        guard options.allows(target) else { return nil }
        let moved = TaskProjectMove.moved(current, to: target)
        do {
            return try await store.moveSession(id: current.id, toProject: moved.projectID,
                                               additionalRoots: moved.additionalRoots)
        } catch {
            bootstrapError = error.localizedDescription
            return nil
        }
    }

    /// Delete a task with an explicit provider boundary. An attached task whose provider keeps its
    /// own sessions (Codex) is deleted by the provider first; a detached task is only removed from
    /// the local index so this action never wakes a runtime or invents a provider session handle.
    /// Adapters without `HarnessSessionLifecycleProviding` keep the local-only lifecycle.
    func delete(_ session: SessionRecord) async {
        guard store.sessions.contains(where: { $0.id == session.id }) else { return }
        bootstrapError = nil
        do {
            if let (provider, handle) = attachedSessionLifecycle(for: session.id) {
                try await provider.deleteProviderSession(handle)
                guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            }
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            bootstrapError = error.localizedDescription
            return
        }
        guard store.sessions.contains(where: { $0.id == session.id }) else { return }
        await removeSessionState(for: session, removal: .discard)
    }

    /// An archived task stays listed under archived tasks and can be restored; a deleted or
    /// discarded one does not.
    private enum SessionRemoval {
        case archive(providerArchived: Bool)
        case discard
    }

    private func removeSessionState(for session: SessionRecord, removal: SessionRemoval) async {
        eventTasksBySessionID.removeValue(forKey: session.id)?.cancel()
        followUpDrainTasks.removeValue(forKey: session.id)?.cancel()
        discardShellCommands(for: session.id)
        sessionTitleResolutionTasks.removeValue(forKey: session.id)?.cancel()
        sessionTitleRefreshes.removeValue(forKey: session.id)
        clearBackgroundNotificationDeduplication(for: session.id)
        agentTools?.releaseAgentTools(for: session.id)
        if let adapter = adaptersBySessionID.removeValue(forKey: session.id),
           let handle = handlesBySessionID.removeValue(forKey: session.id) {
            await adapter.close(handle)
            let closedIdentity = ObjectIdentifier(adapter as AnyObject)
            let remainsInUse = adaptersBySessionID.values.contains {
                ObjectIdentifier($0 as AnyObject) == closedIdentity
            }
            if !remainsInUse {
                await registry.invalidate(
                    harness: session.harness,
                    executableURL: session.runtimeExecutableURL
                )
            }
        }
        // The split view lets go of the task first, so the window moves to the split's remaining
        // pane instead of to whichever task the index would select next.
        splits.removeSession(session.id)
        do {
            switch removal {
            case let .archive(providerArchived):
                try await store.archiveSession(id: session.id, providerArchived: providerArchived)
            case .discard:
                try await store.discardSession(id: session.id)
            }
            composerDrafts.remove(for: session.id)
            taskWorkspaces.remove(for: session.id)
            pullRequestDetails.forget(session.id)
            withdrawApprovalNotifications(for: session.id)
            eventsBySessionID.removeValue(forKey: session.id)
            providerActivityBySessionID.removeValue(forKey: session.id)
            transcriptBuilders.removeValue(forKey: session.id)
            pendingTranscriptDeltas.removeValue(forKey: session.id)
            transcriptPublicationTasks.removeValue(forKey: session.id)?.cancel()
            transcripts.removeValue(forKey: session.id)
            answerLines.removeValue(forKey: session.id)
            claudeTranscriptTails.removeValue(forKey: session.id)
            antigravityHistoryShown.removeValue(forKey: session.id)
            errorBySessionID.removeValue(forKey: session.id)
            codexCapabilitiesBySessionID.removeValue(forKey: session.id)
            codexStatusBySessionID.removeValue(forKey: session.id)
            codexPresentationTasks.removeValue(forKey: session.id)?.cancel()
            codexTurnPageLoads.remove(session.id)
            codexItemPageLoads = codexItemPageLoads.filter {
                !$0.hasPrefix("\(session.id.uuidString):")
            }
            codexSnapshotCheckpointTasks.removeValue(forKey: session.id)?.cancel()
            codexModelRestoreErrors.removeValue(forKey: session.id)
            savedCodexRequests.removeValue(forKey: session.id)
            savedCodexItems.removeValue(forKey: session.id)
            codexPersistedTimelines.removeValue(forKey: session.id)
            codexSettledTurns.removeValue(forKey: session.id)
            codexItemSaveTasks.removeValue(forKey: session.id)?.cancel()
            codexPresentations.removeValue(forKey: session.id)
            followUps.discard(session.id)
            codexPendingRequestRepository.remove(for: session.id)
            codexTimelineItemRepository.remove(for: session.id)
            codexHistorySelectionRepository.remove(for: session.id)
            // An archived task keeps what became of its suggestions; a deleted one takes them along.
            if case .discard = removal {
                taskSuggestions.remove(for: session.id)
                accountAssignments.remove(for: session.id)
            }
            // A deleted task's files read and edited go with it; an archived task's are kept.
            if case .discard = removal, let fileTaskIndex { await fileTaskIndex.remove(session.id) }
            // Its subagents stop; a deleted task takes their kept conversations and its depth along.
            await stopSessionToolWork(for: session.id)
            if case .discard = removal { sessionTools.forget(session.id) }
            transcriptSnapshots.remove(for: session.id)
            providerCapabilitiesBySessionID.removeValue(forKey: session.id)
            providerUsageBySessionID.removeValue(forKey: session.id)
            restoredCodexTokenUsageBySessionID.removeValue(forKey: session.id)
            savedContextUsage.removeValue(forKey: session.id)
            contextUsageSaves.removeValue(forKey: session.id)
            liveContextUsageSessionIDs.remove(session.id)
        } catch {
            bootstrapError = error.localizedDescription
        }
    }

    func rename(_ session: SessionRecord, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              store.sessions.contains(where: { $0.id == session.id }) else { return }
        bootstrapError = nil
        sessionTitleResolutionTasks.removeValue(forKey: session.id)?.cancel()
        do {
            // Keep an already-attached provider session's title (a Codex thread's name) in sync
            // without waking a runtime just for a local rename.
            if let (provider, handle) = attachedSessionLifecycle(for: session.id) {
                try await provider.renameProviderSession(handle, to: trimmed)
                guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            }
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            try await store.renameSession(id: session.id, title: trimmed, titleOrigin: .manual)
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            bootstrapError = error.localizedDescription
        }
    }

    /// The provider side of an attached task's archive, delete, and rename, when its adapter keeps
    /// its own sessions. A detached task has none, so these actions never wake a runtime, and the
    /// visual fixture stays provider-free.
    private func attachedSessionLifecycle(
        for sessionID: UUID
    ) -> (any HarnessSessionLifecycleProviding, HarnessSessionHandle)? {
        guard !isVisualFixture,
              let provider = adaptersBySessionID[sessionID] as? any HarnessSessionLifecycleProviding,
              let handle = handlesBySessionID[sessionID] else { return nil }
        return (provider, handle)
    }

    func isAttached(_ sessionID: UUID) -> Bool {
        handlesBySessionID[sessionID] != nil
    }

    /// Sessions with provider work, or a running bash-mode command, that would be interrupted by
    /// application termination. Ready/attached sessions are intentionally excluded: merely
    /// opening or resuming a task does not make it an active local turn.
    /// A harness's CLI changed under Yardlet (updated, or back to an earlier version): tasks that
    /// attach from now on start it again, and attached ones keep the process they have.
    func harnessRuntimeChanged(_ harness: HarnessKind) async {
        await registry.invalidate(harness: harness)
    }

    var activeLocalSessions: [SessionRecord] {
        store.sessions
            .filter {
                $0.status == .running || $0.status == .waitingForApproval
                    || runningShellCommandBySessionID[$0.id] != nil
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadCodexCapabilities(for session: SessionRecord) async {
        guard session.harness == .codex,
              store.sessions.contains(where: { $0.id == session.id }) else { return }
        var state = codexCapabilitiesBySessionID[session.id] ?? .empty
        state.isLoading = true
        state.errors = []
        state.actionMessage = nil
        codexCapabilitiesBySessionID[session.id] = state

        do {
            let (_, provider, _) = try await codexProvider(for: session)
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            do {
                state.modes = try await provider.collaborationModes()
                guard let current = store.sessions.first(where: { $0.id == session.id }) else { return }
                restoreCodexMode(in: &state, from: current)
            } catch {
                guard store.sessions.contains(where: { $0.id == session.id }) else { return }
                state.errors.append(L10n.format("Modes unavailable: %@", error.localizedDescription))
            }
            do {
                state.skills = try await provider.skills(in: session.workspaceURL)
                guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            } catch {
                guard store.sessions.contains(where: { $0.id == session.id }) else { return }
                state.errors.append(L10n.format("Skills unavailable: %@", error.localizedDescription))
            }
            do {
                state.plugins = try await provider.plugins(in: session.workspaceURL)
                guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            } catch {
                guard store.sessions.contains(where: { $0.id == session.id }) else { return }
                state.errors.append(L10n.format("Plugins unavailable: %@", error.localizedDescription))
            }
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            state.errors = [error.localizedDescription]
        }
        guard store.sessions.contains(where: { $0.id == session.id }) else { return }
        state.isLoading = false
        state.hasListedCapabilities = true
        codexCapabilitiesBySessionID[session.id] = state
    }

    func loadCodexModels(for session: SessionRecord) async {
        do {
            let (_, provider, handle) = try await codexProvider(for: session)
            let catalog = try await provider.modelCatalog(for: handle)
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            codexCapabilitiesBySessionID[session.id, default: .empty].modelCatalog = catalog
            modelCatalogs.recordCodex(catalog, for: session)
        } catch { updateCodexActionError(error, for: session.id) }
    }

    func selectCodexModel(_ selection: CodexModelSelection, for session: SessionRecord) async {
        guard isAttached(session.id) else {
            await chooseCodexModelBeforeAttach(selection, for: session)
            return
        }
        do { try await applyCodexModel(selection, for: session) }
        catch { updateCodexActionError(error, for: session.id) }
    }

    private func applyCodexModel(_ selection: CodexModelSelection, for session: SessionRecord) async throws {
        let (_, provider, handle) = try await codexProvider(for: session)
        let catalog = try await provider.selectModel(selection, for: handle)
        guard store.sessions.contains(where: { $0.id == session.id }) else { return }
        if let value = selection.storedValue {
            try await store.updateProviderOption(id: session.id, optionID: CodexModelSelection.storageKey, value: value)
        }
        // The mode stays: the adapter sends it with this model and effort on the next turn.
        codexCapabilitiesBySessionID[session.id, default: .empty].modelCatalog = catalog
        modelCatalogs.recordCodex(catalog, for: session)
        if codexModelRestoreErrors.removeValue(forKey: session.id) != nil {
            errorBySessionID.removeValue(forKey: session.id)
        }
    }

    func selectCodexMode(
        _ presetID: CodexCollaborationPreset.ID?,
        for session: SessionRecord
    ) async {
        let preset = codexCapabilitiesBySessionID[session.id]?.modes.first { $0.id == presetID }
        do { try await applyCodexMode(preset, for: session) }
        catch { updateCodexActionError(error, for: session.id) }
    }

    private func applyCodexMode(_ preset: CodexCollaborationPreset?, for session: SessionRecord) async throws {
        let (_, provider, handle) = try await codexProvider(for: session)
        guard store.sessions.contains(where: { $0.id == session.id }) else { return }
        try await selectAndKeepCodexMode(preset, provider: provider, handle: handle, for: session)
        guard store.sessions.contains(where: { $0.id == session.id }) else { return }
        var state = codexCapabilitiesBySessionID[session.id] ?? .empty
        state.selectedModeID = preset?.id
        state.actionMessage = preset.map {
            L10n.format("Mode selected: %@", $0.name)
        } ?? L10n.string("Using harness default mode")
        codexCapabilitiesBySessionID[session.id] = state
    }

    /// The provider takes the mode first, then the task keeps it (`CodexCollaborationPreset.storageKey`)
    /// for a restart, a resume and a fork. If the task cannot be saved, the provider goes back to
    /// the mode the task still records, so the composer and the next turn keep agreeing.
    private func selectAndKeepCodexMode(_ preset: CodexCollaborationPreset?, provider: any CodexCapabilityProviding,
                                        handle: HarnessSessionHandle, for session: SessionRecord) async throws {
        let state = codexCapabilitiesBySessionID[session.id] ?? .empty
        let previous = state.modes.first { $0.id == state.selectedModeID }
            ?? store.sessions.first { $0.id == session.id }.flatMap { CodexCollaborationPreset.restored(from: $0.providerOptions) }
        try await provider.selectCollaborationMode(preset, for: handle)
        do {
            if let value = preset?.storedValue {
                try await store.updateProviderOption(id: session.id, optionID: CodexCollaborationPreset.storageKey, value: value)
            } else {
                try await store.removeProviderOption(id: session.id, optionID: CodexCollaborationPreset.storageKey)
            }
        } catch {
            await restoreCodexProviderMode(previous, provider: provider, handle: handle, for: session)
            throw error
        }
    }

    /// Puts the provider back in the mode the task records. A runtime that renamed its presets since
    /// they were listed (YHP resolves a mode by its listed ID) is asked for its list again and given
    /// its own preset with the same mode, and the composer follows that list.
    private func restoreCodexProviderMode(_ previous: CodexCollaborationPreset?, provider: any CodexCapabilityProviding,
                                          handle: HarnessSessionHandle, for session: SessionRecord) async {
        do { return try await provider.selectCollaborationMode(previous, for: handle) } catch {}
        guard let previous, let listed = try? await provider.collaborationModes(),
              let current = previous.matching(listed),
              (try? await provider.selectCollaborationMode(current, for: handle)) != nil,
              store.sessions.contains(where: { $0.id == session.id }) else { return }
        codexCapabilitiesBySessionID[session.id, default: .empty].modes = listed
        codexCapabilitiesBySessionID[session.id]?.selectedModeID = current.id
    }

    /// The task's saved mode as the runtime's own listed preset, for a state that has none chosen
    /// or whose choice the runtime no longer lists (a preset renamed between App Server versions).
    private func restoreCodexMode(in state: inout CodexCapabilityState, from session: SessionRecord) {
        guard !state.modes.contains(where: { $0.id == state.selectedModeID }),
              let saved = CodexCollaborationPreset.restored(from: session.providerOptions) else { return }
        state.selectedModeID = saved.matching(state.modes)?.id
    }

    /// "Yes, implement this plan": as the Codex app does, leave Plan mode for the provider's
    /// Default mode, then send the implement request through the ordinary submission path.
    func implementCodexPlan(_ plan: String, in session: SessionRecord) async {
        guard session.harness == .codex,
              store.sessions.contains(where: { $0.id == session.id }),
              implementingCodexPlans.insert(session.id).inserted else { return }
        // A second click before the turn starts must not queue the request twice.
        defer { implementingCodexPlans.remove(session.id) }
        do {
            let (_, provider, handle) = try await codexProvider(for: session)
            var modes = codexCapabilitiesBySessionID[session.id]?.modes ?? []
            if !modes.contains(where: { $0.mode == "default" }) {
                modes = try await provider.collaborationModes()
            }
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            // A runtime that lists no Default preset is left to its own default mode.
            let preset = modes.first { $0.mode == "default" }
            try await selectAndKeepCodexMode(preset, provider: provider, handle: handle, for: session)
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            var state = codexCapabilitiesBySessionID[session.id] ?? .empty
            if state.modes.isEmpty { state.modes = modes }
            state.selectedModeID = preset?.id
            codexCapabilitiesBySessionID[session.id] = state
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            composerDrafts.tasks.draft(for: session.id).notice = error.localizedDescription
            return
        }
        await submitCodex(
            CodexComposerDraft(inputs: [.text(CodexPlanImplementation.request(for: plan))]),
            action: .automatic,
            to: session
        )
    }

    /// The choice is kept with the task (`CodexRunLocation.storageKey`) before the runtime hears
    /// it, so the composer, a restart's resume, and a child task on Codex all read the same one.
    func selectCodexRunLocation(
        _ location: CodexRunLocation,
        for session: SessionRecord
    ) async {
        do {
            try await store.updateProviderOption(id: session.id, optionID: CodexRunLocation.storageKey,
                                                 value: location.rawValue)
            let (_, provider, handle) = try await codexProvider(for: session)
            try await provider.selectRunLocation(location, for: handle)
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            var state = codexCapabilitiesBySessionID[session.id] ?? .empty
            state.selectedRunLocation = location
            state.actionMessage = L10n.format(
                "Run location selected: %@",
                location.displayName
            )
            codexCapabilitiesBySessionID[session.id] = state
        } catch {
            updateCodexActionError(error, for: session.id)
        }
    }

    /// `HarnessSessionBranchMethod.savedConversation`. The boundary is read in Claude's own
    /// conversation format, the one saved conversation Yardlet reads.
    private func forkSavedConversation(_ source: SessionRecord, selectsSession: Bool) async -> SessionRecord? {
        guard let source = matchingSession(source), source.harness == .claudeCode,
              !switchingAccounts.contains(source.id), forkingSessions.insert(source.id).inserted else { return nil }
        defer { forkingSessions.remove(source.id) }
        let selectedAtStart = store.selectedSessionID
        do {
            guard let providerID = source.providerSessionID,
                  source.status != .running, source.status != .waitingForApproval else {
                throw HarnessAdapterError.capabilityUnavailable(L10n.string("The saved conversation cannot be forked."))
            }
            let reader = claudeSessionReader(for: source)
            let pending = source.inheritedContext?.nativeForkSource
            let snapshot = try await Task.detached(priority: .utility) {
                if let saved = try reader.readSession(sessionID: providerID) { return saved }
                if let pending, let saved = try reader.readSession(sessionID: pending.providerSessionID,
                    throughMessageID: pending.throughMessageID) { return saved }
                throw HarnessAdapterError.capabilityUnavailable(L10n.string("The saved conversation cannot be forked."))
            }.value
            guard let current = matchingSession(source), current.status != .running,
                  current.status != .waitingForApproval else { return nil }
            let context = SideChatContext(source: current, entries: snapshot.transcript.entries,
                nativeForkSource: snapshot.forkSource, isTruncated: snapshot.transcript.isTruncated)
            let child = try await store.createSession(
                harness: .claudeCode, workspaceURL: current.workspaceURL,
                runtimeExecutableURL: current.runtimeExecutableURL,
                title: selectsSession ? L10n.format("Fork of %@", current.title) : L10n.string("Side chat"),
                titleOrigin: .automatic, providerSessionID: UUID().uuidString.lowercased(),
                environmentScope: current.environmentScope, selectsSession: false,
                inheritedContext: context, providerOptions: current.providerOptions, connection: current.connection,
                projectID: current.projectID, additionalRoots: current.additionalRoots,
                // A fork nests under its task in the sidebar; a side chat lives in its side panel.
                parentTaskID: selectsSession ? current.id : nil
            )
            guard matchingSession(current) != nil else {
                try? await store.discardSession(id: child.id)
                return nil
            }
            transcriptBuilders[child.id] = TranscriptBuilder(entries: snapshot.transcript.entries)
            publishTranscript(for: child.id)
            if selectsSession, store.selectedSessionID == selectedAtStart { store.selectedSessionID = child.id }
            return child
        } catch {
            if matchingSession(source) != nil { errorBySessionID[source.id] = error.localizedDescription }
            return nil
        }
    }

    /// Claude's `/clear`. As in the CLI it waits for the current turn, then opens a new chat.
    @discardableResult
    func restartClaudeConversation(_ source: SessionRecord) async -> SessionRecord? {
        guard let source = matchingSession(source), !switchingAccounts.contains(source.id),
              !restartingSessions.contains(source.id) else { return nil }
        guard source.status != .running, source.status != .waitingForApproval else {
            composerDrafts.tasks.draft(for: source.id).notice =
                L10n.string("Stop the current turn before starting a new conversation.")
            return nil
        }
        return await branch(source, at: .start)
    }

    /// A blank task in the source's project, account, storage scope and runtime; the source keeps
    /// its history and draft. It does not wait for the current turn, as in the Codex app: the
    /// source keeps running on its own. Claude's `/clear` waits before it gets here.
    private func startNewChat(from source: SessionRecord) async -> SessionRecord? {
        guard let source = matchingSession(source),
              !switchingAccounts.contains(source.id), restartingSessions.insert(source.id).inserted else { return nil }
        defer { restartingSessions.remove(source.id) }
        let selectedAtStart = store.selectedSessionID
        do {
            let next = try await store.createSession(harness: source.harness, workspaceURL: source.workspaceURL,
                runtimeExecutableURL: source.runtimeExecutableURL, title: L10n.string("New task"), titleOrigin: .automatic,
                environmentScope: source.environmentScope, selectsSession: false, providerOptions: source.providerOptions,
                connection: source.connection, projectID: source.projectID, additionalRoots: source.additionalRoots)
            guard matchingSession(source) != nil else {
                try? await store.discardSession(id: next.id)
                return nil
            }
            if store.selectedSessionID == selectedAtStart { store.selectedSessionID = next.id }
            return next
        } catch {
            if matchingSession(source) != nil {
                composerDrafts.tasks.draft(for: source.id).notice = error.localizedDescription
            }
            return nil
        }
    }

    /// Compare the saved provider/account/storage identity after every asynchronous boundary.
    private func matchingSession(_ source: SessionRecord, allowingInitialAttachment: Bool = false) -> SessionRecord? {
        store.sessions.first { $0.id == source.id && $0.harness == source.harness
            && ($0.providerSessionID == source.providerSessionID || (allowingInitialAttachment
                && source.providerSessionID == nil && $0.providerSessionID == handlesBySessionID[source.id]?.providerSessionID))
            && $0.environmentScope == source.environmentScope
            && $0.connection == source.connection && $0.workspaceURL == source.workspaceURL
            && $0.runtimeExecutableURL == source.runtimeExecutableURL }
    }

    func claudeSessionReader(for session: SessionRecord) -> ClaudeSubagentTranscriptReader {
        ClaudeSubagentTranscriptReader(configDirectory: ClaudeSubagentTranscriptReader.configDirectory(
            connection: session.connection, workspaceURL: session.workspaceURL))
    }

    /// A detached Claude task's conversation read again from its saved transcript: the newest part
    /// of the file (`ClaudeTranscriptTail.initialBytes`), not its whole history, so opening it and
    /// following another app's writes stay quick however long it is. The newest part goes in place
    /// of the turns shown from its first one on, so the earlier turns the person brought in stay
    /// (`ClaudeSubagentTranscriptReader.refreshConversation`). A place the person was reading that
    /// the newest part leaves out is kept: the read goes further back until it holds that place.
    /// Whether `id`'s saved conversation is being read from the provider's own history: a detached
    /// task's Claude Code file, Codex thread or Antigravity log. Until a first read arrives, a task
    /// with nothing in Yardlet's reading cache shows its conversation loading rather than empty.
    func isReadingSavedConversation(_ id: UUID) -> Bool {
        (savedConversationReads[id] ?? 0) > 0
    }

    private func beginSavedConversationRead(_ id: UUID) {
        savedConversationReads[id] = (savedConversationReads[id] ?? 0) + 1
    }

    private func endSavedConversationRead(_ id: UUID) {
        let remaining = (savedConversationReads[id] ?? 1) - 1
        savedConversationReads[id] = remaining > 0 ? remaining : nil
    }

    /// Starts reading a detached task's saved conversation as the task is chosen, rather than once its
    /// surface has been built and its composer asks (`refreshConversationStatus`, which then waits for
    /// this read or finds it done), so the conversation arrives that much sooner. Reading resumes
    /// nothing and starts no turn.
    private func readSavedConversation(of id: UUID) {
        guard !isVisualFixture, let session = store.sessions.first(where: { $0.id == id }),
              [.claudeCode, .codex, .antigravityCLI].contains(session.harness),
              handlesBySessionID[id] == nil, session.providerSessionID != nil else { return }
        // Loading from the frame the task opens in, not from when the read gets going.
        beginSavedConversationRead(id)
        Task { [weak self] in
            switch session.harness {
            case .claudeCode: await self?.refreshNativeClaudeConversation(for: session)
            case .codex: await self?.readDetachedCodexThread(for: session)
            default: await self?.refreshNativeAntigravityConversation(for: session)
            }
            self?.endSavedConversationRead(id)
        }
    }

    /// The pointer rests on a task in the sidebar: a detached task whose conversation Yardlet has
    /// nothing of yet this launch starts reading it, so it is there when the task opens, as a page
    /// behind a link is fetched on hover. A task already showing something reads again when opened.
    func prefetchSavedConversation(of id: UUID) {
        guard !isReadingSavedConversation(id), (transcriptBySessionID[id] ?? []).isEmpty,
              codexPresentationBySessionID[id]?.thread?.turns.isEmpty != false else { return }
        readSavedConversation(of: id)
    }

    /// One read of a task's saved conversation at a time. Opening a task starts one as it is chosen,
    /// and its composer, a resume or following asks again once the surface is built: a second asker
    /// waits for the read in flight, which reads what it would have, and is done when it is; one that
    /// knows the provider's record changed since (`afterChange`) reads again once it is over.
    private func readSavedConversationOnce(_ key: String, afterChange: Bool,
                                           _ read: @escaping @MainActor () async -> Void) async {
        if let inFlight = savedConversationReadTasks[key] {
            await inFlight.value
            guard afterChange else { return }
            if let next = savedConversationReadTasks[key] {
                await next.value
                return
            }
        }
        let task = Task { @MainActor in await read() }
        savedConversationReadTasks[key] = task
        await task.value
        if savedConversationReadTasks[key] == task { savedConversationReadTasks.removeValue(forKey: key) }
    }

    /// Reads a detached Claude task's conversation from Claude Code's own file, one read at a time.
    func refreshNativeClaudeConversation(for source: SessionRecord, afterChange: Bool = false) async {
        await readSavedConversationOnce("claude|\(source.id)", afterChange: afterChange) {
            await self.readNativeClaudeConversation(for: source)
        }
    }

    private func readNativeClaudeConversation(for source: SessionRecord) async {
        guard let session = matchingSession(source), session.harness == .claudeCode,
              handlesBySessionID[session.id] == nil, session.status != .running,
              session.status != .waitingForApproval, !sessionMutations.contains(session.id),
              // A shell command Claude has not been sent yet is only in Yardlet's conversation.
              runningShellCommandBySessionID[session.id] == nil, pendingShellDeliveries[session.id] == nil,
              let providerID = session.providerSessionID else { return }
        let stored = claudeTranscriptTails[session.id]
        let window = stored.flatMap { $0.providerSessionID == providerID ? $0.window : nil }
        let before = transcriptBySessionID[session.id] ?? []
        let reading = taskWorkspaces.state(for: session.id).transcript
        let savedPlace = reading.bookmark.followsLatest ? nil : reading.bookmark.anchorID.flatMap { anchor in
            before.contains { $0.id.uuidString == anchor } ? anchor : nil
        }
        let reader = claudeSessionReader(for: session)
        beginSavedConversationRead(session.id)
        defer { endSavedConversationRead(session.id) }
        do {
            let read = try await Task.detached(priority: .utility) {
                try reader.refreshConversation(sessionID: providerID, window: window, shown: before, keeping: savedPlace)
            }.value
            if let usage = read?.contextUsage { adoptClaudeHistoryContextUsage(usage, for: session) }
            guard let read, matchingSession(session) != nil, handlesBySessionID[session.id] == nil,
                  (transcriptBySessionID[session.id] ?? []) == before,
                  claudeTranscriptTails[session.id] == stored else { return }
            if let anchor = reading.bookmark.anchorID,
               let old = before.first(where: { $0.id.uuidString == anchor }) {
                let matches = read.entries.filter { $0.content == old.content }
                if matches.count == 1 { reading.bookmark.anchorID = matches[0].id.uuidString }
            }
            transcriptBuilders[session.id] = TranscriptBuilder(entries: read.entries,
                                                               limit: Self.claudeEntryLimit(holding: read.entries.count))
            publishTranscript(for: session.id)
            setClaudeTranscriptTail(ClaudeTranscriptTail(providerSessionID: providerID, window: read.window),
                                    for: session.id)
        } catch {
            // Preserve cache and binding on failure. The provider still owns resume; never
            // clear original history or manufacture a new identity merely to read a transcript.
        }
    }

    /// Reads a detached Antigravity task's conversation from Antigravity CLI's own log
    /// (`AntigravityConversationStore`), on open and while following it. The log has the requests,
    /// answers, thinking and tool calls but not tool output, so Yardlet's own reading cache, which
    /// has the output, stays while it holds as many requests: the log replaces it when the cache
    /// is empty (an imported or archived task), when the log has more requests (the conversation
    /// went on in `agy` or another client), and, once it has, on every later change. Nothing is
    /// sent, resumed, attached or written.
    func refreshNativeAntigravityConversation(for source: SessionRecord, afterChange: Bool = false) async {
        await readSavedConversationOnce("antigravity|\(source.id)", afterChange: afterChange) {
            await self.readNativeAntigravityConversation(for: source)
        }
    }

    private func readNativeAntigravityConversation(for source: SessionRecord) async {
        guard !isVisualFixture, let session = matchingSession(source), session.harness == .antigravityCLI,
              handlesBySessionID[session.id] == nil, session.status != .running,
              session.status != .waitingForApproval, !sessionMutations.contains(session.id),
              let providerID = session.providerSessionID,
              // A task still on its local stand-in identity has no conversation of its own yet.
              UUID(uuidString: providerID) != session.id,
              !antigravityHistoryReads.contains(session.id) else { return }
        let store = antigravityConversationStore
        let stamp = store.transcriptURL(conversationID: providerID).flatMap { DetachedConversationStamp(file: $0) }
        guard let stamp else { return }
        let shown = antigravityHistoryShown[session.id]
        guard shown?.providerSessionID != providerID || shown?.stamp != stamp else { return }
        antigravityHistoryReads.insert(session.id)
        beginSavedConversationRead(session.id)
        defer {
            antigravityHistoryReads.remove(session.id)
            endSavedConversationRead(session.id)
        }
        let before = transcriptBySessionID[session.id] ?? []
        do {
            let read = try await Task.detached(priority: .utility) {
                try store.readTranscript(conversationID: providerID)
            }.value
            guard matchingSession(session) != nil, handlesBySessionID[session.id] == nil,
                  (transcriptBySessionID[session.id] ?? []) == before else { return }
            let showsLog = shown?.providerSessionID == providerID && shown?.showsLog == true
            let cachedRequests = before.reduce(0) { count, entry in
                if case .user = entry.content { return count + 1 }
                return count
            }
            let replaces = !read.entries.isEmpty
                && (before.isEmpty || read.requestCount > cachedRequests || (showsLog && read.requestCount >= cachedRequests))
            antigravityHistoryShown[session.id] = AntigravityHistoryShown(
                providerSessionID: providerID, stamp: read.stamp ?? stamp, showsLog: replaces || showsLog)
            guard replaces, read.entries != before else { return }
            transcriptBuilders[session.id] = TranscriptBuilder(entries: read.entries,
                                                               limit: Self.claudeEntryLimit(holding: read.entries.count))
            publishTranscript(for: session.id)
        } catch {
            // The cache and the binding stay. The CLI still owns its conversation.
        }
    }

    /// Reads earlier turns of a Claude task's saved transcript as the person scrolls up to them, until
    /// the file's start: the read reaches further back (`ClaudeTranscriptTail.budget(after:)`), parses
    /// only the lines before the part already read, and puts the turns it finds before the first one
    /// shown, which keeps its place and ID. A turn longer than a step brings none by itself, so the
    /// read goes on until a turn arrives. A detached task and an attached one read the same way; an
    /// attached one keeps what its runtime streams. Nothing is sent, resumed, attached or saved.
    func readEarlierClaudeHistory(for source: SessionRecord) async {
        guard !isVisualFixture, let session = matchingSession(source), session.harness == .claudeCode,
              let providerID = session.providerSessionID,
              let tail = claudeTranscriptTails[session.id], tail.providerSessionID == providerID,
              let window = tail.window, window.hasEarlierRecords,
              claudeEarlierHistoryReads.insert(session.id).inserted else { return }
        defer { claudeEarlierHistoryReads.remove(session.id) }
        let reader = claudeSessionReader(for: session)
        let read = try? await Task.detached(priority: .utility) { try reader.readEarlierTurns(window) }.value
        guard let read = read ?? nil, matchingSession(session) != nil,
              claudeTranscriptTails[session.id] == tail else { return }
        var builder = transcriptBuilders[session.id] ?? TranscriptBuilder()
        if !read.entries.isEmpty {
            builder.raiseLimit(to: Self.claudeEntryLimit(holding: builder.entries.count + read.entries.count))
            // The part of the last turn the first read held goes, for the whole turn and what precedes it;
            // otherwise the turns found go before the first one shown.
            if let seam = read.replacesThrough ?? window.seamEntry {
                // A conversation that no longer holds the turn the reads began at has nothing to put before it.
                guard builder.entries.contains(where: { $0.id == seam }) else {
                    setClaudeTranscriptTail(ClaudeTranscriptTail(providerSessionID: providerID), for: session.id)
                    return
                }
                if read.replacesThrough != nil {
                    builder.replaceEntries(through: seam, with: read.entries)
                } else {
                    builder.replaceEntries(before: seam, with: read.entries)
                }
            } else {
                builder = TranscriptBuilder(entries: read.entries + builder.entries,
                                            limit: Self.claudeEntryLimit(holding: read.entries.count + builder.entries.count))
            }
            transcriptBuilders[session.id] = builder
            publishTranscript(for: session.id)
        }
        setClaudeTranscriptTail(ClaudeTranscriptTail(providerSessionID: providerID, window: read.window), for: session.id)
    }

    /// Whether a Claude task's saved transcript holds turns before the ones its reads reached, which
    /// its conversation offers as the person scrolls up (`readEarlierClaudeHistory`), until the
    /// reads reach the file's start.
    func hasEarlierClaudeHistory(_ session: SessionRecord) -> Bool {
        guard session.harness == .claudeCode, let providerID = session.providerSessionID,
              let tail = claudeTranscriptTailBySessionID[session.id] else { return false }
        return tail.providerSessionID == providerID && tail.hasEarlierHistory
    }

    /// The entries a Claude task's conversation keeps: what its reads covered, and room for as many
    /// again as before the window could grow, so streaming does not push out the earlier turns read.
    private static func claudeEntryLimit(holding count: Int) -> Int {
        count + 2_000
    }

    private func setClaudeTranscriptTail(_ tail: ClaudeTranscriptTail, for sessionID: UUID) {
        guard claudeTranscriptTails[sessionID] != tail else { return }
        claudeTranscriptTails[sessionID] = tail
    }

    /// A detached Codex task shows its newest turns when it is opened, commands and file changes
    /// included, as the Codex app does: the task's runtime reads the saved thread without its turns
    /// (`thread/read`) and then its newest page (`thread/turns/list`), which neither loads nor
    /// resumes it, starts no turn and changes no account. Earlier turns stay with the provider
    /// behind the page's cursor until the person scrolls up to them (`loadMoreCodexTurns`), so the
    /// first paint does not grow with the thread. A thread already shown, opened again or followed
    /// as another app writes it, reads only its newest page again and merges it into the turns it
    /// loaded. The reading snapshot stays the first paint until the thread arrives, and stays if it
    /// cannot be read. The read itself saves nothing.
    func readDetachedCodexThread(for source: SessionRecord, afterChange: Bool = false) async {
        await readSavedConversationOnce("codex|\(source.id)", afterChange: afterChange) {
            await self.readDetachedCodexThreadNow(for: source)
        }
    }

    private func readDetachedCodexThreadNow(for source: SessionRecord) async {
        guard !isVisualFixture, let session = matchingSession(source), session.harness == .codex,
              handlesBySessionID[session.id] == nil, session.status != .running,
              session.status != .waitingForApproval, !sessionMutations.contains(session.id),
              !switchingAccounts.contains(session.id), let threadID = session.providerSessionID,
              codexThreadReads.insert(session.id).inserted else { return }
        beginSavedConversationRead(session.id)
        defer {
            codexThreadReads.remove(session.id)
            endSavedConversationRead(session.id)
        }
        guard let reader = await detachedCodexThreadReader(for: session) else { return }
        let shown = codexPresentationBySessionID[session.id]?.thread
        var state: CodexTaskState
        if shown?.id == threadID, shown?.turns.isEmpty == false {
            guard let page = try? await reader.readThreadTurns(threadID: threadID, cursor: nil,
                                                                limit: CodexThreadPaging.newestTurns),
                  !page.turns.isEmpty, let current = codexPresentationBySessionID[session.id],
                  current.thread?.id == threadID else { return }
            state = current
            CodexTaskReducer().mergeNewestTurnPage(page, into: &state)
        } else {
            guard let read = try? await reader.readThreadPresentation(
                threadID: threadID, newestTurns: CodexThreadPaging.newestTurns) else { return }
            state = read
        }
        // A task that connected, started a turn or changed while the thread was read shows its own.
        // A read without turns says nothing the snapshot does not, and must not clear it.
        guard state.thread?.id == threadID, state.thread?.turns.isEmpty == false,
              let current = matchingSession(session),
              current.providerSessionID == threadID, handlesBySessionID[session.id] == nil,
              current.status != .running, current.status != .waitingForApproval,
              !sessionMutations.contains(session.id) else { return }
        // The rollout the thread is written to, which following the shown task watches.
        if let path = state.thread?.raw["path"]?.stringValue, path.hasPrefix("/") {
            codexRolloutPathBySessionID[session.id] = path
        }
        settleDetachedCodexState(&state, for: session.id)
        guard codexPresentationBySessionID[session.id] != state else { return }
        codexPresentations[session.id] = state
    }

    /// An earlier page of a detached Codex task's thread, read through the task's own App Server
    /// (same account and storage scope) the way opening it reads, and put before the turns loaded.
    /// Nothing attaches or resumes the task. A page that arrives after the turns changed under it
    /// (the task attached, or another read replaced the cursor) is dropped.
    private func loadEarlierDetachedCodexTurns(for source: SessionRecord, before cursor: String) async {
        guard !isVisualFixture, let session = matchingSession(source), let threadID = session.providerSessionID,
              let reader = await detachedCodexThreadReader(for: session) else { return }
        do {
            let page = try await reader.readThreadTurns(threadID: threadID, cursor: cursor,
                                                         limit: CodexThreadPaging.earlierTurns)
            guard matchingSession(session) != nil, handlesBySessionID[session.id] == nil,
                  var state = codexPresentationBySessionID[session.id], state.thread?.id == threadID,
                  state.thread?.turnsNextCursor == cursor else { return }
            CodexTaskReducer().mergeTurnPage(page, prepending: true, into: &state)
            settleDetachedCodexState(&state, for: session.id)
            codexPresentations[session.id] = state
        } catch {
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            updateCodexActionError(error, for: session.id)
        }
    }

    /// The App Server a detached Codex task reads its thread through: the registry's for the
    /// task's runtime, storage scope and account, which no session of this task holds.
    /// The runtime a task is attached to now, and its session there; nil while it is not attached.
    func attachedRuntime(for sessionID: UUID) -> (adapter: any HarnessAdapter, handle: HarnessSessionHandle)? {
        guard let adapter = adaptersBySessionID[sessionID], let handle = handlesBySessionID[sessionID] else { return nil }
        return (adapter, handle)
    }

    func detachedCodexThreadReader(for session: SessionRecord) async -> (any CodexThreadReading)? {
        guard FileManager.default.isExecutableFile(atPath: session.runtimeExecutableURL.path(percentEncoded: false)),
              session.connection.map({ (try? $0.validate(for: .codex)) != nil }) ?? true,
              session.connection?.homePath.map({ FileManager.default.fileExists(atPath: $0) }) ?? true
        else { return nil }
        let adapter = await registry.adapter(for: .codex, executableURL: session.runtimeExecutableURL,
                                             environmentScope: session.environmentScope, connection: session.connection)
        return adapter as? any CodexThreadReading
    }

    /// What a detached thread read shows beside the provider's turns: the task's saved requests and
    /// cards, and no turn still running, since no runtime holds the thread (a turn it left open
    /// stopped with the runtime, as one does when a task's runtime ends while it is shown).
    private func settleDetachedCodexState(_ state: inout CodexTaskState, for sessionID: UUID) {
        mergePersistedCodexServerRequests(into: &state, for: sessionID)
        mergePersistedCodexTimelineItems(into: &state, for: sessionID)
        CodexTaskReducer().endRuntime(in: &state)
    }

    func canOpenOriginalConversation(in session: SessionRecord) -> Bool {
        session.harness == .claudeCode && session.inheritedContext?.nativeConversationOrigin?.harness == .claudeCode
            && session.inheritedContext?.nativeConversationOrigin?.providerSessionID != session.providerSessionID
            && session.status != .running && session.status != .waitingForApproval
            && !sessionMutations.contains(session.id) && !switchingAccounts.contains(session.id)
    }

    /// Open the preserved original as an ordinary separate chat. Neither branch is rebound,
    /// resumed or sent a model input merely to read the saved conversation.
    @discardableResult
    func openOriginalClaudeConversation(from source: SessionRecord) async -> SessionRecord? {
        guard let current = matchingSession(source), canOpenOriginalConversation(in: current),
              let origin = current.inheritedContext?.nativeConversationOrigin,
              origin.providerSessionID != current.providerSessionID,
              sessionMutations.insert(current.id).inserted else { return nil }
        defer { sessionMutations.remove(current.id) }
        let selectedAtStart = store.selectedSessionID
        if let existing = store.sessions.first(where: { $0.id != current.id && origin.matches($0) }) {
            if store.selectedSessionID == selectedAtStart { store.selectedSessionID = existing.id }
            return existing
        }
        do {
            let reader = claudeSessionReader(for: origin.record)
            let snapshot = try await Task.detached(priority: .utility) {
                try reader.readConversation(sessionID: origin.providerSessionID)
            }.value
            guard let snapshot else {
                throw HarnessAdapterError.capabilityUnavailable(L10n.string("The original conversation is unavailable."))
            }
            guard let saved = matchingSession(current), saved.inheritedContext?.nativeConversationOrigin == origin else { return nil }
            // Another read may have opened this identity while the scoped file read was pending.
            if let existing = store.sessions.first(where: { $0.id != current.id && origin.matches($0) }) {
                if store.selectedSessionID == selectedAtStart { store.selectedSessionID = existing.id }
                return existing
            }
            let original = try await store.createSession(harness: .claudeCode, workspaceURL: origin.workspaceURL,
                runtimeExecutableURL: origin.runtimeExecutableURL, title: L10n.format("Original of %@", origin.title),
                titleOrigin: .automatic, providerSessionID: origin.providerSessionID,
                environmentScope: origin.environmentScope, selectsSession: false,
                providerOptions: origin.providerOptions, connection: origin.connection,
                projectID: origin.projectID, additionalRoots: origin.additionalRoots, parentTaskID: current.id)
            guard matchingSession(current)?.inheritedContext?.nativeConversationOrigin == origin else {
                try? await store.discardSession(id: original.id)
                return nil
            }
            transcriptBuilders[original.id] = TranscriptBuilder(entries: snapshot.entries)
            publishTranscript(for: original.id)
            if store.selectedSessionID == selectedAtStart { store.selectedSessionID = original.id }
            return original
        } catch {
            if matchingSession(current) != nil { errorBySessionID[current.id] = error.localizedDescription }
            return nil
        }
    }

    /// `HarnessSessionBranchMethod.attachedSession`: the attached provider forks the thread.
    private func forkAttachedSession(
        _ session: SessionRecord,
        selectsSession: Bool,
        throughTurnID: String? = nil
    ) async -> SessionRecord? {
        guard let saved = matchingSession(session), !switchingAccounts.contains(saved.id),
              forkingSessions.insert(saved.id).inserted else { return nil }
        var session = saved
        defer { forkingSessions.remove(session.id) }
        let selectedAtStart = store.selectedSessionID
        do {
            if let throughTurnID {
                guard let turn = codexPresentationBySessionID[session.id]?.thread?.turns
                    .first(where: { $0.id == throughTurnID }), turn.status.isTerminal else {
                    throw HarnessAdapterError.capabilityUnavailable(L10n.string("This turn cannot be forked."))
                }
            }
            session = await sessionWithAvailableRuntime(session)
            guard matchingSession(session) != nil else { return nil }
            let (adapter, provider, handle) = try await codexProvider(for: session)
            guard let attached = matchingSession(session, allowingInitialAttachment: true) else { return nil }
            session = attached
            let forkedSession = try await store.createSession(
                harness: .codex,
                workspaceURL: session.workspaceURL,
                runtimeExecutableURL: session.runtimeExecutableURL,
                title: selectsSession ? L10n.format("Fork of %@", session.title) : L10n.string("Side chat"),
                titleOrigin: .automatic,
                environmentScope: session.environmentScope, selectsSession: false,
                providerOptions: store.sessions.first(where: { $0.id == session.id })?.providerOptions ?? session.providerOptions,
                connection: session.connection,
                projectID: session.projectID,
                additionalRoots: session.additionalRoots,
                parentTaskID: selectsSession ? session.id : nil
            )
            do {
                guard matchingSession(session) != nil else {
                    try? await store.discardSession(id: forkedSession.id)
                    return nil
                }
                // The fork is a task of its own, so its thread gets its own tool token and tab.
                await configureAgentTools(on: adapter, for: forkedSession)
                await configureYardletInstructions(on: adapter, harness: forkedSession.harness,
                                                   projectID: projects.project(for: forkedSession)?.id, for: forkedSession.id)
                if let roots = adapter as? any HarnessWorkspaceRootsConfiguring {
                    await roots.setAdditionalWorkspaceRoots(forkedSession.additionalRootURLs, for: forkedSession.id)
                }
                let forkedHandle = try await provider.fork(
                    handle,
                    newLocalSessionID: forkedSession.id,
                    throughTurnID: throughTurnID
                )
                guard matchingSession(session) != nil,
                      store.sessions.contains(where: { $0.id == forkedSession.id }) else {
                    await adapter.close(forkedHandle)
                    try? await store.discardSession(id: forkedSession.id)
                    return nil
                }
                adaptersBySessionID[forkedSession.id] = adapter
                handlesBySessionID[forkedSession.id] = forkedHandle
                try await store.updateSession(
                    id: forkedSession.id,
                    status: .ready,
                    providerSessionID: forkedHandle.providerSessionID,
                    setProviderSessionID: true
                )
                startEventCollection(adapter: adapter, handle: forkedHandle)
                if let presentation = adapter as? any CodexPresentationProviding {
                    startCodexPresentationCollection(
                        provider: presentation,
                        handle: forkedHandle
                    )
                }
                // Keep app-local capability selections visible and effective on the forked
                // task, while intentionally dropping source-task history/search/error state.
                // The adapter carries the same selections into the next provider turn.
                let sourceCapabilities = codexCapabilitiesBySessionID[session.id]
                var forkedCapabilities = CodexCapabilityState.empty
                forkedCapabilities.modelCatalog = sourceCapabilities?.modelCatalog ?? CodexModelCatalog()
                forkedCapabilities.modes = sourceCapabilities?.modes ?? []
                forkedCapabilities.selectedModeID = sourceCapabilities?.selectedModeID
                forkedCapabilities.selectedRunLocation =
                    sourceCapabilities?.selectedRunLocation ?? .automatic
                forkedCapabilities.skills = sourceCapabilities?.skills ?? []
                forkedCapabilities.plugins = sourceCapabilities?.plugins ?? []
                codexCapabilitiesBySessionID[forkedSession.id] = forkedCapabilities
                if throughTurnID != nil, let presentation = adapter as? any CodexPresentationProviding {
                    do {
                        _ = try await presentation.loadTurns(for: forkedHandle, cursor: nil, limit: 50)
                    } catch {
                        // The provider already accepted the fork. Preserve that identity even
                        // when history hydration fails, and keep the source conversation intact.
                        if store.sessions.contains(where: { $0.id == forkedSession.id }) {
                            errorBySessionID[forkedSession.id] = L10n.format(
                                "The fork was created, but its history could not be loaded: %@", error.localizedDescription)
                        }
                    }
                }
                guard matchingSession(session) != nil,
                      store.sessions.contains(where: { $0.id == forkedSession.id }) else { return nil }
                if selectsSession, store.selectedSessionID == selectedAtStart {
                    store.selectedSessionID = forkedSession.id
                }
                return store.sessions.first { $0.id == forkedSession.id }
            } catch {
                try? await store.discardSession(id: forkedSession.id)
                throw error
            }
        } catch {
            if selectsSession { updateCodexActionError(error, for: session.id) }
            else { sideChatErrors[session.id] = error.localizedDescription }
            return nil
        }
    }

    /// Conversations a harness keeps for one folder that another app started, a page at a time.
    /// Claude's are read from its own history under the chosen account, all at once. Codex's come
    /// from its App Server: the most recent first, or with a search term the ones whose text
    /// matches, each with the matching snippet.
    func importableConversations(
        harness: HarnessKind,
        workspaceURL: URL,
        connection: ProviderConnection?,
        searchTerm: String = "",
        cursor: String? = nil
    ) async throws -> ImportableConversationPage {
        let query = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        switch harness {
        case .claudeCode:
            let config = ClaudeSubagentTranscriptReader.configDirectory(connection: connection)
            let conversations = await Task.detached(priority: .userInitiated) {
                ClaudeConversationCatalog.conversations(in: workspaceURL, configDirectory: config)
            }.value
            return ImportableConversationPage(conversations: conversations)
        case .codex:
            // The visual fixture has no provider. Its seeded history goes through the same list,
            // search and selection without waking a runtime.
            if isVisualFixture {
                let threads = visualFixtureCodexHistory.filter {
                    query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                        || $0.preview.localizedCaseInsensitiveContains(query)
                }
                return ImportableConversationPage(conversations: threads.map {
                    ImportableConversation(codex: $0, snippet: query.isEmpty ? nil : $0.preview)
                })
            }
            let provider = try await codexHistoryProvider(connection: connection)
            if query.isEmpty {
                let page = try await provider.recentThreadsPage(in: workspaceURL, cursor: cursor, limit: 50)
                return ImportableConversationPage(conversations: page.threads.map { ImportableConversation(codex: $0) },
                    nextCursor: page.nextCursor)
            }
            let page = try await provider.searchThreads(in: workspaceURL, searchTerm: query, cursor: cursor, limit: 50)
            return ImportableConversationPage(conversations: page.matches.map {
                ImportableConversation(codex: $0.thread, snippet: $0.snippet)
            }, nextCursor: page.nextCursor)
        case .antigravityCLI:
            // Antigravity CLI's own index and logs, read and never written; nothing starts.
            let store = antigravityConversationStore
            let conversations = try await Task.detached(priority: .userInitiated) {
                try store.conversations(in: workspaceURL)
            }.value
            return ImportableConversationPage(conversations: query.isEmpty ? conversations : conversations.filter {
                $0.title.localizedCaseInsensitiveContains(query)
            })
        default:
            return ImportableConversationPage(conversations: [])
        }
    }

    /// The Yardlet task that already continues this conversation under the same history.
    func existingTask(for conversation: ImportableConversation, connection: ProviderConnection?) -> SessionRecord? {
        store.sessions.first {
            $0.harness == conversation.harness && $0.environmentScope == .native
                && $0.providerSessionID?.lowercased() == conversation.providerSessionID.lowercased()
                && ($0.connection == connection
                    || (conversation.harness == .claudeCode && ClaudeConversationStorage.isShared($0.connection, connection)))
        }
    }

    /// Adds a conversation another app started as a Yardlet task with the same provider session ID,
    /// under the chosen account, and opens it. Nothing is copied or moved; an already imported
    /// conversation opens its task instead. A Codex conversation found by a search opens at the
    /// match (`historySelection`); opened without a search, it forgets an earlier match.
    @discardableResult
    func importConversation(
        _ conversation: ImportableConversation,
        connection: ProviderConnection?,
        historySelection: CodexHistorySearchSelection? = nil
    ) async -> SessionRecord? {
        do {
            let task = try await importTask(conversation, connection: connection, selects: true)
            await linkImportedConversations([conversation])
            if conversation.harness == .codex {
                await rememberCodexHistorySelection(historySelection, threadID: conversation.providerSessionID,
                                                    for: task.id)
            }
            return store.sessions.first { $0.id == task.id }
        } catch {
            bootstrapError = error.localizedDescription
            return nil
        }
    }

    /// Imports each conversation in turn, as the list showed them, without opening any: the
    /// sidebar gains the tasks and the selection stays. Claude's go under `claudeConnection`, Codex's
    /// under `codexConnection` (nil is the default login). Each task keeps the other app's last
    /// activity as its place in the sidebar. Returns why each conversation that could not be
    /// imported failed, by its ID.
    func importConversations(
        _ conversations: [ImportableConversation],
        claudeConnection: ProviderConnection?,
        codexConnection: ProviderConnection? = nil,
        onEach: (ImportableConversation) -> Void = { _ in }
    ) async -> [String: String] {
        var failures: [String: String] = [:]
        let roots = importProjectRoots(among: conversations)
        for conversation in conversations {
            let connection: ProviderConnection? = switch conversation.harness {
            case .claudeCode: claudeConnection
            case .codex: codexConnection
            default: nil
            }
            do {
                _ = try await importTask(conversation, connection: connection,
                                         selects: false, lastActivityAt: conversation.updatedAt, projectRoots: roots)
            } catch {
                failures[conversation.id] = error.localizedDescription
            }
            onEach(conversation)
        }
        await linkImportedConversations(conversations)
        return failures
    }

    /// The task that continues `conversation`: the one already imported, else a new one made
    /// detached, like a task restored after relaunch. No runtime starts; it attaches when the
    /// person first sends, and opening the task reads the provider's own history. A conversation
    /// another app still holds is imported too, and is followed read-only until that app lets it go.
    private func importTask(
        _ conversation: ImportableConversation,
        connection: ProviderConnection?,
        selects: Bool,
        lastActivityAt: Date? = nil,
        projectRoots: [URL]? = nil
    ) async throws -> SessionRecord {
        if let existing = existingTask(for: conversation, connection: connection) {
            if selects { store.selectedSessionID = existing.id }
            return existing
        }
        // The visual fixture has no provider to read a conversation it does not already show.
        guard !isVisualFixture else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("The conversation could not be imported."))
        }
        guard let runtime = runtimeSelections.selectedURL(for: conversation.harness) else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.format("%@ is not installed.", conversation.harness.displayName))
        }
        try connection?.validate(for: conversation.harness)
        // A folder found with a login becomes a saved account once a conversation comes in under it.
        try connections.saveIfFound(connection)
        let project = importProject(for: conversation, projectRoots: projectRoots ?? importProjectRoots(among: []))
        // A worktree stands in for its repository's folder; the project's other roots come along.
        let primaryFolder = conversation.workspaceOrigin?.originWorkspaceURL ?? conversation.workspaceURL
        let additionalRoots = project.map { project in
            project.contains(root: primaryFolder)
                ? project.roots.filter { !Project.isSamePath($0, primaryFolder) }
                    .map { ProjectSidebarPresentation.normalizedPath(for: $0) }
                : []
        } ?? []
        return try await store.createSession(
            harness: conversation.harness, workspaceURL: conversation.workspaceURL, runtimeExecutableURL: runtime,
            title: conversation.title, titleOrigin: .provider, providerSessionID: conversation.providerSessionID,
            environmentScope: .native, selectsSession: selects, providerOptions: conversation.providerOptions,
            connection: connection, projectID: project?.id, additionalRoots: additionalRoots,
            workspaceOrigin: conversation.workspaceOrigin, lastActivityAt: lastActivityAt,
            parentTaskID: TaskLineage.task(continuing: conversation.parentProviderSessionID,
                                           harness: conversation.harness, among: store.sessions,
                                           archived: store.archivedSessions?.map(\.session) ?? [],
                                           environmentScope: conversation.harness == .codex ? .native : nil,
                                           connection: connection))
    }

    /// Links imported tasks to the tasks their conversations were started from, both being in
    /// Yardlet, whichever came in first: the conversations just imported, and for Claude every
    /// session the Claude app records (`linkTasksStartedInTheClaudeApp`). A link already recorded
    /// stays.
    private func linkImportedConversations(_ conversations: [ImportableConversation]) async {
        for harness in Set(conversations.map(\.harness)) {
            let parents = Dictionary(
                conversations.compactMap { conversation -> (String, String)? in
                    guard conversation.harness == harness, let parent = conversation.parentProviderSessionID else { return nil }
                    return (conversation.providerSessionID, parent)
                },
                uniquingKeysWith: { first, _ in first })
            let links = TaskLineage.links(parents: parents, harness: harness, sessions: store.sessions,
                                          archived: store.archivedSessions?.map(\.session) ?? [])
            _ = try? await store.linkParents(links)
        }
        if conversations.contains(where: { $0.harness == .claudeCode }) {
            await linkTasksStartedInTheClaudeApp()
        }
    }

    /// Reads the Claude app's session files (`ClaudeDesktopSessionCatalog`, read only) for which
    /// session started which, and links the Claude tasks that have no link yet to the task of the
    /// session that started them. Nothing is written but the links in Yardlet's index; the provider
    /// history and the app's files stay as they are. Nothing is read when no Claude task could be
    /// linked.
    func linkTasksStartedInTheClaudeApp() async {
        guard !isVisualFixture, store.sessions.contains(where: {
            $0.harness == .claudeCode && $0.parentTaskID == nil && !$0.isLineageDetached && $0.providerSessionID != nil
        }) else { return }
        let root = claudeDesktopSessionsRoot
        let parents = await Task.detached(priority: .utility) {
            ClaudeDesktopSessionCatalog.parentSessionIDs(of: ClaudeDesktopSessionCatalog.sessions(in: root))
        }.value
        let links = TaskLineage.links(parents: parents, harness: .claudeCode, sessions: store.sessions,
                                      archived: store.archivedSessions?.map(\.session) ?? [])
        _ = try? await store.linkParents(links)
    }

    /// The once-only read for tasks imported before links were kept: on the first launch with this
    /// build, `linkTasksStartedInTheClaudeApp` runs once. Later imports link as they go.
    func linkTasksStartedInTheClaudeAppOnce(defaults: UserDefaults = .yardlet) async {
        let key = "Yardlet.taskLineage.claudeAppLinksRead"
        guard !isVisualFixture, !defaults.bool(forKey: key) else { return }
        await linkTasksStartedInTheClaudeApp()
        defaults.set(true, forKey: key)
    }

    /// The project an imported conversation joins, or none for a chat (`ConversationImportPlacement`).
    private func importProject(for conversation: ImportableConversation, projectRoots: [URL]) -> Project? {
        switch ConversationImportPlacement.of(conversation, projectRoots: projectRoots) {
        case .chat: nil
        case let .project(root): projectForNewTask(workspaceURL: root, projectID: nil)
        }
    }

    /// The folders a conversation in a folder inside them joins: the person's projects', and the
    /// folders of the conversations imported with it.
    private func importProjectRoots(among conversations: [ImportableConversation]) -> [URL] {
        projects.projects.flatMap(\.roots) + conversations
            .filter { !ChatWorkspaces.isChat($0.workspaceURL) }
            .map(ConversationImportPlacement.folder(of:))
    }

    /// Where the import list says a conversation goes, without making a project: Chats, the project
    /// that already owns its folder (or its worktree's repository, or a folder it is inside), else
    /// the folder that would become one. `conversations` is the whole list, whose folders a
    /// conversation in a folder inside them joins.
    func importDestination(for conversation: ImportableConversation,
                           among conversations: [ImportableConversation] = []) -> ConversationImportDestination {
        switch ConversationImportPlacement.of(conversation, projectRoots: importProjectRoots(among: conversations)) {
        case .chat:
            return .chats
        case let .project(root):
            let owner = projects.project(containingRoot: root)
                ?? store.workspaceOrigin(for: root).originWorkspaceURL.flatMap { projects.project(containingRoot: $0) }
            if let owner { return ConversationImportDestination(id: owner.id.uuidString, name: owner.name) }
            return ConversationImportDestination(id: ProjectSidebarPresentation.normalizedPath(for: root),
                                                 name: root.lastPathComponent)
        }
    }

    /// The conversations open in the Claude and Codex apps, to import them all at once. Claude's are
    /// the desktop app's open Code sessions whose transcript is in `claudeConnection`'s history,
    /// then that history's most recent other conversations (Claude Code run in a terminal or by
    /// another tool); Codex's are the threads a person started under `codexConnection` (nil is the default Codex
    /// login), every folder's. Reading starts no thread and no turn. A source that cannot be read
    /// says why, and the other is still listed.
    func otherAppConversations(claudeConnection: ProviderConnection?,
                               codexConnection: ProviderConnection? = nil) async -> OtherAppConversations {
        var result = OtherAppConversations()
        guard !isVisualFixture else {
            result.codex = visualFixtureCodexHistory.map { ImportableConversation(codex: $0) }
            return result
        }
        let root = claudeDesktopSessionsRoot
        let config = ClaudeSubagentTranscriptReader.configDirectory(connection: claudeConnection)
        let history = modelCatalogs.locations.folder(for: .claudeCode, connection: claudeConnection) ?? config
        // The Claude app's open sessions, then what Claude Code ran elsewhere under this account
        // (a terminal, another tool's account folder).
        result.claude = await Task.detached(priority: .userInitiated) {
            let app = ClaudeDesktopSessionCatalog.conversations(root: root, configDirectory: config)
            let listed = Set(app.map(\.providerSessionID))
            return app + ClaudeConversationCatalog.recentConversations(configDirectory: history)
                .filter { !listed.contains($0.providerSessionID) }
        }.value
        do {
            let provider = try await codexHistoryProvider(connection: codexConnection)
            result.codex = try await codexInteractiveThreads(provider, archived: false).map { ImportableConversation(codex: $0) }
        } catch {
            result.codexError = error.localizedDescription
        }
        if runtimeSelections.selectedURL(for: .antigravityCLI) != nil {
            let store = antigravityConversationStore
            do {
                result.antigravity = try await Task.detached(priority: .userInitiated) {
                    try store.conversations()
                }.value
            } catch {
                result.antigravityError = error.localizedDescription
            }
        }
        // A conversation in a worktree another app made (the Codex app's `~/.codex/worktrees`) goes
        // with its repository, as a Claude worktree session does. Git's own files say which.
        let listed = result
        return await Task.detached(priority: .userInitiated) { listed.resolvingWorktreeOrigins() }.value
    }

    /// The threads a person started under the default Codex login, every folder's, open or (with
    /// `archived`) archived, the most recently updated first: at most 20 pages of 100, each once.
    /// `thread/list` reads; no thread is loaded, resumed or changed.
    private func codexInteractiveThreads(
        _ provider: any CodexCapabilityProviding, archived: Bool
    ) async throws -> [CodexThreadSummary] {
        var threads: [CodexThreadSummary] = []
        var cursor: String?
        for _ in 0..<20 {
            let page = archived
                ? try await provider.archivedInteractiveThreadsPage(cursor: cursor, limit: 100)
                : try await provider.interactiveThreadsPage(cursor: cursor, limit: 100)
            threads += page.threads
            cursor = page.nextCursor
            guard cursor != nil else { break }
        }
        var seen = Set<String>()
        return threads.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Following the Claude app's and Codex's lists

    /// A pass of `followSessionLists` when one is due: once the index is restored, one at a time,
    /// at most once per `SessionListFollow.interval`. Launch asks once the index is loaded
    /// (2026-10-22 user decision: on launch, and otherwise when asked, not each time the app
    /// becomes active).
    func followSessionListsIfDue(now: Date = Date()) async {
        guard !isVisualFixture, sessionListFollowIsReady, sessionListFollowSchedule.begin(at: now) else { return }
        isFollowingSessionLists = true
        defer {
            sessionListFollowSchedule.end()
            isFollowingSessionLists = false
        }
        await followSessionLists(now: now)
    }

    /// The person's "Refresh from the Claude App and Codex": a pass now, whenever the last one was.
    func followSessionListsNow(now: Date = Date()) async {
        guard !isVisualFixture, sessionListFollowIsReady,
              sessionListFollowSchedule.begin(at: now, asked: true) else { return }
        isFollowingSessionLists = true
        defer {
            sessionListFollowSchedule.end()
            isFollowingSessionLists = false
        }
        await followSessionLists(now: now)
    }

    /// Brings the task list in step with the Claude app's Code sessions and the Codex threads a
    /// person started, the way the Codex app lists every thread in `~/.codex` (`SessionListFollow`).
    /// The sources are only read: the Claude app's session files (`ClaudeDesktopSessionCatalog`,
    /// with its size and count limits) under the account the import sheet starts on, and Codex's
    /// `thread/list` of open and archived threads under the default Codex login, the import
    /// sheet's App Server. Nothing is written to either app, no thread is archived or resumed
    /// there, no turn starts and no runtime attaches.
    ///
    /// In Yardlet: a conversation open there and never in Yardlet comes in through the import
    /// path (`importConversations`); a task's last activity moves forward to the source's; a
    /// provider title follows the source's; a task the source archived is archived in Yardlet
    /// only when nothing of the person's would be cut off or lost. A task the person archived,
    /// deleted or brought back in Yardlet stays as they left it.
    func followSessionLists(now: Date = Date()) async {
        guard !isVisualFixture else { return }
        let claudeConnection = connections.defaultImportChoice(for: .claudeCode)?.connection
        let root = claudeDesktopSessionsRoot
        let config = ClaudeSubagentTranscriptReader.configDirectory(connection: claudeConnection)
        var entries = await Task.detached(priority: .utility) {
            ClaudeDesktopSessionCatalog.followedConversations(root: root, configDirectory: config)
        }.value
        if runtimeSelections.selectedURL(for: .codex) != nil {
            do {
                entries += try await codexFollowedThreads()
            } catch {
                // Codex unread this time: its tasks stay as they are until a later pass.
            }
        }
        guard !Task.isCancelled, let indexed = try? await store.indexedProviderSessions() else { return }
        let keptListed = sessionListFollowKeptListed()
        let attached = handlesBySessionID.values.map {
            SessionListFollow.IndexedSession(harness: $0.harness, providerSessionID: $0.providerSessionID)
        }
        let plan = SessionListFollow.plan(entries, state: SessionListFollow.State(
            tasks: store.sessions, indexed: indexed.union(attached),
            task: { [unowned self] conversation in
                self.existingTask(for: conversation,
                                  connection: conversation.harness == .claudeCode ? claudeConnection : nil)
            },
            isBusy: { [unowned self] in self.sessionListFollowKeepsListed($0) },
            keptListed: keptListed, skipsFolder: sessionListFollowSkipsFolder, now: now))
        guard !plan.isEmpty else {
            sessionListFollowForget(keptListed.subtracting(store.sessions.map(\.id)))
            return
        }
        for (id, date) in plan.activity.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            _ = try? await store.moveLastActivity(id: id, forwardTo: date)
        }
        for (id, title) in plan.titles.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            // Only while the title is still the provider's: a rename meanwhile is the person's.
            guard store.sessions.first(where: { $0.id == id })?.titleOrigin == .provider else { continue }
            try? await store.renameSession(id: id, title: title, titleOrigin: .provider, updatesRecency: false)
        }
        for (id, sourceActivity) in plan.archives.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            await archiveFollowingSource(id, sourceActivity: sourceActivity)
        }
        sessionListFollowForget(plan.keptListedReleased.union(keptListed.subtracting(store.sessions.map(\.id))))
        let imports = plan.imports.filter { runtimeSelections.selectedURL(for: $0.harness) != nil }
        guard !imports.isEmpty else { return }
        // A conversation in a worktree another app made goes with its repository, as in the sheet.
        let listed = OtherAppConversations(claude: imports.filter { $0.harness == .claudeCode },
                                           codex: imports.filter { $0.harness == .codex })
        let resolved = await Task.detached(priority: .utility) { listed.resolvingWorktreeOrigins() }.value
        _ = await importConversations(resolved.all, claudeConnection: claudeConnection)
    }

    /// The Codex threads a person started, open and archived, as `SessionListFollow` reads them.
    /// A thread listed as both (archived while the two lists were read) counts as open. The title
    /// followed is the thread's name, not the first request a nameless thread is listed under.
    private func codexFollowedThreads() async throws -> [SessionListFollow.Entry] {
        let provider = try await codexHistoryProvider(connection: nil)
        let open = try await codexInteractiveThreads(provider, archived: false)
        // An App Server that cannot list archived threads leaves the archive alone.
        let archived = (try? await codexInteractiveThreads(provider, archived: true)) ?? []
        let openIDs = Set(open.map(\.id))
        func entry(_ thread: CodexThreadSummary, archived: Bool) -> SessionListFollow.Entry {
            SessionListFollow.Entry(conversation: ImportableConversation(codex: thread), isArchived: archived,
                                    sourceTitle: thread.title != thread.preview ? thread.title : nil)
        }
        return open.map { entry($0, archived: false) }
            + archived.filter { !openIDs.contains($0.id) }.map { entry($0, archived: true) }
    }

    /// Whether a task has work or input of the person's that archiving it would cut off or lose,
    /// or is in front of them: a turn running or waiting for an answer, an attached runtime, a
    /// shell command, a non-empty draft, queued messages, being shown or arranged in a split,
    /// or a move, account switch or restore in progress.
    func sessionListFollowKeepsListed(_ task: SessionRecord) -> Bool {
        let id = task.id
        return task.status == .running || task.status == .waitingForApproval
            || handlesBySessionID[id] != nil || adaptersBySessionID[id] != nil
            || runningShellCommandBySessionID[id] != nil
            || composerDrafts.tasks.existingDraft(for: id).map { !$0.snapshot.isEmpty } == true
            || !followUps.queue(for: id).isEmpty
            || store.selectedSessionID == id || splits.focusedSessionID == id || splits.groupedSessionIDs.contains(id)
            || sessionMutations.contains(id) || switchingAccounts.contains(id) || unarchivingSessionIDs.contains(id)
    }

    /// Archives a listed task its source archived, in Yardlet's index only: no `thread/archive`,
    /// no write to the other app, no worktree removed. It is checked again right before, since
    /// the person may have started on it while the sources were read; an attached task is never
    /// archived here, so no provider is asked. Archiving drops the task's local caches as an
    /// archive always does; there is no draft or queued message to lose, by that check.
    private func archiveFollowingSource(_ id: UUID, sourceActivity: Date) async {
        guard let task = store.sessions.first(where: { $0.id == id }), !task.isPinned,
              task.updatedAt <= sourceActivity, !sessionListFollowKept(id),
              !sessionListFollowKeepsListed(task) else { return }
        await removeSessionState(for: task, removal: .archive(providerArchived: false))
    }

    private static let sessionListFollowKeptListedKey = "Yardlet.sessionListFollow.keptListed"

    /// Tasks the person brought back from Yardlet's archive: following the source does not
    /// archive them again until the source lists them open once more.
    func sessionListFollowKeptListed() -> Set<UUID> {
        Set((preferences.stringArray(forKey: Self.sessionListFollowKeptListedKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    private func sessionListFollowKept(_ id: UUID) -> Bool { sessionListFollowKeptListed().contains(id) }

    private func keepListedWhileSourceArchives(_ id: UUID) {
        var kept = sessionListFollowKeptListed()
        guard kept.insert(id).inserted else { return }
        preferences.set(kept.map(\.uuidString).sorted(), forKey: Self.sessionListFollowKeptListedKey)
    }

    private func sessionListFollowForget(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let kept = sessionListFollowKeptListed().subtracting(ids)
        if kept.isEmpty {
            preferences.removeObject(forKey: Self.sessionListFollowKeptListedKey)
        } else {
            preferences.set(kept.map(\.uuidString).sorted(), forKey: Self.sessionListFollowKeptListedKey)
        }
    }

    /// Whether another app's Claude process holds this detached task's conversation, so Yardlet
    /// must not continue it as well. Yardlet's own processes do not count.
    func isHeldElsewhere(_ session: SessionRecord) -> Bool {
        guard !isVisualFixture, session.harness == .claudeCode, handlesBySessionID[session.id] == nil,
              let id = session.providerSessionID else { return false }
        let config = ClaudeSubagentTranscriptReader.configDirectory(connection: session.connection,
                                                                   workspaceURL: session.workspaceURL)
        return ClaudeConversationCatalog.runningSessionIDs(configDirectory: config).contains(id.lowercased())
    }

    /// While a detached Claude or Codex task is shown, follows its conversation read-only as another
    /// app writes it. Every `detachedFollowInterval` it looks at the provider's own file (Claude's
    /// transcript; the Codex rollout the last `thread/read` named) and, when that changed, reads only
    /// the newest part again, with the guards opening the task has: Claude's transcript tail with
    /// the budget in use, Codex's newest page of turns, merged into the turns loaded. The earlier
    /// history the person brought in stays; nothing reads the whole history on a change. Nothing is
    /// sent, resumed or saved. It returns once the task attaches or is gone; the view ends it when
    /// the task is no longer shown.
    func followDetachedConversation(for source: SessionRecord) async {
        guard !isVisualFixture,
              [.claudeCode, .codex, .antigravityCLI].contains(source.harness) else { return }
        var seen: DetachedConversationStamp?
        while !Task.isCancelled {
            guard let session = matchingSession(source), handlesBySessionID[session.id] == nil else { return }
            let stamp = detachedConversationStamp(for: session)
            if let stamp, let previous = seen, stamp != previous {
                // The record changed since any read in flight began: read it again after that one.
                switch session.harness {
                case .claudeCode: await refreshNativeClaudeConversation(for: session, afterChange: true)
                case .antigravityCLI: await refreshNativeAntigravityConversation(for: session, afterChange: true)
                default:
                    await readDetachedCodexThread(for: session, afterChange: true)
                    await readCodexRolloutTokenUsage(for: session)
                }
            }
            if stamp != nil { seen = stamp }
            do { try await Task.sleep(for: detachedFollowInterval) } catch { return }
        }
    }

    private func detachedConversationStamp(for session: SessionRecord) -> DetachedConversationStamp? {
        let file: URL?
        switch session.harness {
        case .claudeCode:
            file = session.providerSessionID.flatMap {
                ClaudeConversationCatalog.transcriptURL(sessionID: $0, workspace: session.workspaceURL,
                    configDirectory: ClaudeSubagentTranscriptReader.configDirectory(connection: session.connection,
                                                                                     workspaceURL: session.workspaceURL))
            }
        case .codex:
            file = codexRolloutPathBySessionID[session.id].map { URL(filePath: $0) }
        case .antigravityCLI:
            file = session.providerSessionID.flatMap { antigravityConversationStore.transcriptURL(conversationID: $0) }
        default:
            file = nil
        }
        return file.flatMap(DetachedConversationStamp.init(file:))
    }

    /// Where a Codex task opened from the import list shows its search match: the provider's
    /// own occurrence when it can name one, else the query and snippet the list showed. Nothing
    /// is kept for a task deleted meanwhile.
    private func rememberCodexHistorySelection(
        _ selection: CodexHistorySearchSelection?,
        threadID: String,
        for sessionID: UUID
    ) async {
        guard let selection else {
            codexHistorySelectionBySessionID.removeValue(forKey: sessionID)
            codexHistorySelectionRepository.remove(for: sessionID)
            return
        }
        let resolved = await resolveCodexHistorySelection(selection, threadID: threadID, sessionID: sessionID)
        guard store.sessions.contains(where: { $0.id == sessionID }) else { return }
        codexHistorySelectionBySessionID[sessionID] = resolved
        codexHistorySelectionRepository.save(resolved, for: sessionID)
    }

    /// Resolve a visible History result to the provider's stable turn/item identity when the
    /// installed runtime exposes `thread/searchOccurrences`. Older runtimes and deterministic
    /// fixtures keep the original query/snippet and continue using the local hydrated-text
    /// projection; no result is dropped merely because the optional endpoint is unavailable.
    private func resolveCodexHistorySelection(
        _ selection: CodexHistorySearchSelection,
        threadID: String,
        sessionID: UUID
    ) async -> CodexHistorySearchSelection {
        guard !selection.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let session = store.sessions.first(where: { $0.id == sessionID }) else { return selection }
        // An imported task is not attached yet; the account's App Server that listed the match
        // answers without loading the thread.
        let adapter: any HarnessAdapter
        if let attached = adaptersBySessionID[sessionID] {
            adapter = attached
        } else {
            adapter = await registry.adapter(for: .codex, executableURL: session.runtimeExecutableURL,
                environmentScope: session.environmentScope, connection: session.connection)
        }
        guard let provider = adapter as? any CodexCapabilityProviding else {
            return selection
        }

        do {
            let page = try await provider.searchOccurrences(
                threadID: threadID,
                searchTerm: selection.query,
                cursor: nil,
                limit: 30
            )
            guard let occurrence = page.occurrences.first else { return selection }
            return CodexHistorySearchSelection(
                query: selection.query,
                snippet: occurrence.snippet,
                threadID: threadID,
                turnID: occurrence.turnID,
                itemID: occurrence.itemID,
                turnCursor: occurrence.turnCursor,
                snippetMatchRange: occurrence.snippetMatchRange
            )
        } catch {
            return selection
        }
    }

    /// Read a child log from the saved parent's account, without acquiring an agent loop.
    func readClaudeSubtask(activityID: String, from sourceSession: SessionRecord) async throws -> HarnessSubtaskTranscript {
        let (session, activity) = try claudeSubtask(activityID: activityID, sourceSession: sourceSession)
        guard let parentID = session.providerSessionID, let reference = activity.subtask else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("The child conversation could not be read."))
        }
        let reader = ClaudeSubagentTranscriptReader(configDirectory:
            ClaudeSubagentTranscriptReader.configDirectory(connection: session.connection, workspaceURL: session.workspaceURL))
        let snapshot = try await Task.detached(priority: .utility) {
            try reader.read(parentSessionID: parentID, reference: reference)
        }.value
        // Account/session changes while a file is being read must not publish another scope's
        // content. No attach, model turn, index write or selection change is needed for reading.
        _ = try claudeSubtask(activityID: activityID, sourceSession: session)
        return snapshot
    }

    func stopClaudeSubtask(activityID: String, from sourceSession: SessionRecord) async throws {
        let (session, _) = try claudeSubtask(activityID: activityID, sourceSession: sourceSession)
        guard let handle = handlesBySessionID[session.id],
              let controller = adaptersBySessionID[session.id] as? any HarnessSubtaskControlling else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Task control is unavailable."))
        }
        try await controller.stopSubtask(activityID: activityID, in: handle)
    }

    private func claudeSubtask(activityID: String, sourceSession: SessionRecord) throws -> (SessionRecord, HarnessActivity) {
        guard sourceSession.harness == .claudeCode,
              sourceSession.connection == nil || sourceSession.connection?.harness == .claudeCode,
              let session = store.sessions.first(where: { $0.id == sourceSession.id }),
              session.harness == sourceSession.harness,
              session.providerSessionID == sourceSession.providerSessionID,
              session.environmentScope == sourceSession.environmentScope,
              session.connection == sourceSession.connection,
              session.workspaceURL == sourceSession.workspaceURL,
              let activity = transcriptBySessionID[session.id]?.compactMap({ entry -> HarnessActivity? in
                  if case let .activity(activity, _) = entry.content, activity.id == activityID { return activity }
                  return nil
              }).last, activity.subtask != nil else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("This task is no longer available."))
        }
        return (session, activity)
    }

    /// Resume a provider-owned child thread in the same task shell. This only changes local task
    /// selection and provider session attachment; it never invents child state or starts a new
    /// agent turn.
    func openCodexSubagent(threadID: String, from sourceSession: SessionRecord) async {
        guard sourceSession.harness == .codex,
              !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let sourceSession = matchingSession(sourceSession) else { return }
        if let existingID = TaskLineage.task(continuing: threadID, harness: .codex, among: store.sessions,
                                             environmentScope: sourceSession.environmentScope,
                                             connection: sourceSession.connection),
           let existing = store.sessions.first(where: { $0.id == existingID }) {
            store.selectedSessionID = existing.id
            if existing.parentTaskID == nil, existing.id != sourceSession.id {
                _ = try? await store.linkParents([existing.id: sourceSession.id])
            }
            return
        }

        // The DEBUG visual fixture has no provider process to resume. Keep the child-thread
        // navigation path honest by creating a local, not-loaded task record from the provider
        // child identity already present in the parent item, without inventing turns or waking
        // the `/usr/bin/true` fixture executable. Packaged sessions continue through the real
        // provider-backed resume path below.
        if isVisualFixture {
            do {
                let child = try await store.createSession(
                    harness: .codex,
                    workspaceURL: sourceSession.workspaceURL,
                    runtimeExecutableURL: sourceSession.runtimeExecutableURL,
                    title: L10n.format("Subagent %@", String(threadID.prefix(12))),
                    titleOrigin: .automatic,
                    providerSessionID: threadID,
                    environmentScope: sourceSession.environmentScope, connection: sourceSession.connection,
                    projectID: sourceSession.projectID, additionalRoots: sourceSession.additionalRoots,
                    parentTaskID: sourceSession.id
                )
                guard matchingSession(sourceSession) != nil else {
                    try? await store.discardSession(id: child.id)
                    return
                }
                let parentThreadID = codexPresentationBySessionID[sourceSession.id]?.thread?.id
                    ?? sourceSession.providerSessionID
                let childThread = CodexThreadState(
                    id: threadID,
                    sessionID: nil,
                    name: child.title,
                    preview: "",
                    workspacePath: sourceSession.workspaceURL.path(percentEncoded: false),
                    cliVersion: nil,
                    modelProvider: nil,
                    parentThreadID: parentThreadID,
                    forkedFromID: nil,
                    status: .notLoaded,
                    canAcceptDirectInput: nil,
                    createdAt: child.createdAt,
                    updatedAt: child.updatedAt,
                    turns: [],
                    turnsNextCursor: nil,
                    turnsBackwardsCursor: nil,
                    itemsBackwardsCursor: nil,
                    raw: .object([
                        "id": .string(threadID),
                        "parentThreadId": parentThreadID.map(JSONValue.string) ?? .null,
                        "source": .string("visual-fixture-child-navigation")
                    ])
                )
                codexPresentations[child.id] = CodexTaskState(
                    thread: childThread,
                    approvalsByID: [:],
                    serverRequestsByID: [:],
                    lastAppliedSequence: nil
                )
                store.selectedSessionID = child.id
            } catch {
                updateCodexActionError(error, for: sourceSession.id)
            }
            return
        }
        do {
            let child = try await store.createSession(
                harness: .codex,
                workspaceURL: sourceSession.workspaceURL,
                runtimeExecutableURL: sourceSession.runtimeExecutableURL,
                title: L10n.format("Subagent %@", String(threadID.prefix(12))),
                titleOrigin: .automatic,
                providerSessionID: threadID,
                environmentScope: sourceSession.environmentScope, connection: sourceSession.connection,
                projectID: sourceSession.projectID, additionalRoots: sourceSession.additionalRoots,
                parentTaskID: sourceSession.id
            )
            do {
                guard matchingSession(sourceSession) != nil else {
                    try? await store.discardSession(id: child.id)
                    return
                }
                try await attach(child, resumesExistingSession: true)
                guard matchingSession(sourceSession) != nil else {
                    await removeSessionState(for: child, removal: .discard)
                    return
                }
                store.selectedSessionID = child.id
            } catch {
                try? await store.discardSession(id: child.id)
                throw error
            }
        } catch {
            updateCodexActionError(error, for: sourceSession.id)
        }
    }

    func reviewCodexWorkingTree(_ session: SessionRecord) async {
        await startCodexReview(.uncommittedChanges, in: session)
    }

    func startCodexReview(_ target: CodexReviewTarget, in source: SessionRecord, submittedDraft: TaskDraftSnapshot? = nil) async {
        guard let session = matchingSession(source), session.status != .running, session.status != .waitingForApproval,
              !switchingAccounts.contains(session.id), followUps.queue(for: session.id).isEmpty,
              composerDrafts.tasks.draft(for: session.id).editState == nil,
              sessionMutations.insert(session.id).inserted else { return }
        defer { sessionMutations.remove(session.id) }
        do {
            let (_, provider, handle) = try await codexProvider(for: session)
            guard matchingSession(session, allowingInitialAttachment: true) != nil else { return }
            try await provider.startReview(target, in: handle)
            guard matchingSession(session, allowingInitialAttachment: true) != nil else { return }
            if let submittedDraft, composerDrafts.tasks.draft(for: session.id).snapshot == submittedDraft {
                composerDrafts.tasks.draft(for: session.id).clear()
            }
            var state = codexCapabilitiesBySessionID[session.id] ?? .empty
            state.actionMessage = L10n.string("Working tree review started")
            codexCapabilitiesBySessionID[session.id] = state
        } catch {
            updateCodexActionError(error, for: session.id)
        }
    }

    func loadProviderCapabilities(for session: SessionRecord) async {
        guard session.harness != .codex,
              store.sessions.contains(where: { $0.id == session.id }) else { return }
        guard supportsLiveProviderControls(session.harness) else {
            providerCapabilitiesBySessionID[session.id] = keepingNegotiatedImageInput(
                unsupportedProviderState(for: session.harness),
                for: session.id
            )
            return
        }
        var state = providerCapabilitiesBySessionID[session.id] ?? .empty
        state.isLoading = true
        state.errors = []
        providerCapabilitiesBySessionID[session.id] = state
        do {
            let (adapter, provider, handle) = try await providerCapabilityProvider(for: session)
            state = try await provider.providerCapabilities(for: handle)
            // Antigravity lists its models only here; the new-task screen offers what it listed.
            if session.harness == .antigravityCLI { await rememberAdvertisedModels(from: adapter, for: session) }
        } catch HarnessAdapterError.capabilityUnavailable {
            state = unsupportedProviderState(for: session.harness)
        } catch {
            state.errors = [error.localizedDescription]
        }
        guard store.sessions.contains(where: { $0.id == session.id }) else { return }
        state.isLoading = false
        providerCapabilitiesBySessionID[session.id] = keepingNegotiatedImageInput(
            state,
            for: session.id
        )
    }

    /// User-requested metadata for a new Claude task's home composer. Its account and workspace
    /// are the user's selections; existing task handles, index, drafts and histories stay owned
    /// by their existing sessions. The temporary handle is closed by the reader.
    func readHomeComposerCommands(
        workspaceURL: URL, runtimeURL: URL, connection: ProviderConnection?
    ) async throws -> [ProviderComposerCommand] {
        try connection?.validate(for: .claudeCode)
        if let home = connection?.homePath {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: home, isDirectory: &directory), directory.boolValue else {
                throw ProviderConnectionError.invalidBinding
            }
        }
        let adapter = await registry.adapter(
            for: .claudeCode, executableURL: runtimeURL, environmentScope: .native, connection: connection
        )
        _ = try await adapter.probeRuntime()
        return try await ComposerCommandReader.read(using: adapter, workspaceURL: workspaceURL)
    }

    /// Refreshes conversation chrome without waking a detached provider's session. Live controls
    /// are read only from an already-attached runtime; a detached Codex task's saved thread is read
    /// for display, which resumes nothing; Grok's persisted metadata remains read-only.
    func refreshConversationStatus(for session: SessionRecord) async {
        guard store.sessions.contains(where: { $0.id == session.id }) else { return }
        prepareComposerModel(for: session)
        await refreshNativeClaudeConversation(for: session)
        await refreshNativeAntigravityConversation(for: session)
        await refreshProviderTitle(for: session)
        guard !Task.isCancelled, store.sessions.contains(where: { $0.id == session.id }) else { return }
        if session.harness == .codex {
            guard let handle = handlesBySessionID[session.id] else {
                await readDetachedCodexThread(for: session)
                await readCodexRolloutTokenUsage(for: session)
                return
            }
            // Composer choices must not depend on opening the former capability browser.
            // Read only the attached runtime, without starting a session or enumerating history/plugins.
            guard let provider = adaptersBySessionID[session.id] as? any CodexCapabilityProviding else { return }
            let catalog = try? await provider.modelCatalog(for: handle)
            guard !Task.isCancelled, handlesBySessionID[session.id] == handle,
                  store.sessions.contains(where: { $0.id == session.id }) else { return }
            let skills = try? await provider.skills(in: session.workspaceURL)
            guard !Task.isCancelled, handlesBySessionID[session.id] == handle,
                  store.sessions.contains(where: { $0.id == session.id }),
                  catalog != nil || skills != nil else { return }
            var state = codexCapabilitiesBySessionID[session.id] ?? .empty
            if let catalog {
                state.modelCatalog = catalog
                modelCatalogs.recordCodex(catalog, for: session)
            }
            if let skills { state.skills = skills }
            codexCapabilitiesBySessionID[session.id] = state
            await refreshMCPServers(for: session)
            return
        }
        await refreshPersistedGrokSessionMetadata(for: session)
        guard isAttached(session.id),
              supportsLiveProviderControls(session.harness) else { return }
        await loadProviderCapabilities(for: session)
    }

    /// Rereads the MCP servers an attached task's session loaded, for the composer's connector
    /// list, from a harness that reports them on request (Claude Code `mcp_status`, Codex
    /// `mcpServerStatus/list`). Nothing starts: a detached task keeps what it last showed.
    func refreshMCPServers(for session: SessionRecord) async {
        guard let handle = handlesBySessionID[session.id],
              let reader = adaptersBySessionID[session.id] as? any HarnessMCPServerStatusReading,
              let servers = try? await reader.mcpServers(for: handle),
              handlesBySessionID[session.id] == handle,
              store.sessions.contains(where: { $0.id == session.id }) else { return }
        if session.harness == .codex {
            codexCapabilitiesBySessionID[session.id, default: .empty].mcpServers = servers
        } else if providerCapabilitiesBySessionID[session.id] != nil {
            providerCapabilitiesBySessionID[session.id]?.mcpServers = servers
        }
    }

    /// App activation rereads only visible provider-owned titles, without attaching a runtime.
    func refreshVisibleProviderTitles() async {
        guard !isRestoringIndex else { return }
        for session in store.sessions where isSessionVisible(session.id) {
            guard !Task.isCancelled else { return }
            await refreshProviderTitle(for: session)
        }
    }

    func setProviderOption(_ id: String, value: String, for session: SessionRecord) async {
        if session.harness == .claudeCode, !isAttached(session.id),
           id == ClaudeLaunchOption.model || id == ClaudeLaunchOption.effort {
            await chooseClaudeModelBeforeAttach(id, value: value, for: session)
            return
        }
        do {
            let (_, provider, handle) = try await providerCapabilityProvider(for: session)
            let nextState = try await provider.setProviderOption(
                id: id, value: value, in: handle
            )
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            let applied = nextState.selectors.first(where: { $0.id == id })?.currentValue ?? value
            try await store.updateProviderOption(id: session.id, optionID: id, value: applied)
            // An effort kept from before that the new model does not take would fail when the task
            // next starts, so the task goes back to the model's default effort.
            let effortID: String? = switch session.harness {
            case .claudeCode: ClaudeLaunchOption.effort
            // The CLI refuses `--effort` for a model without levels, so the same holds there.
            case .antigravityCLI: StructuredHeadlessOptionID.reasoningEffort
            default: nil
            }
            if let effortID, id == ClaudeLaunchOption.model,
               let kept = store.sessions.first(where: { $0.id == session.id })?.providerOptions[effortID],
               kept != "default",
               nextState.selectors.first(where: { $0.id == effortID })?.choices
                   .contains(where: { $0.value == kept }) != true {
                try await store.updateProviderOption(id: session.id, optionID: effortID, value: "default")
            }
            // A variant chosen before the list was folded carries its effort; keep it with the task.
            if session.harness == .antigravityCLI, id == StructuredHeadlessOptionID.model,
               let effort = nextState.selectors.first(where: { $0.id == StructuredHeadlessOptionID.reasoningEffort })?.currentValue,
               effort != "default",
               store.sessions.first(where: { $0.id == session.id })?.providerOptions[StructuredHeadlessOptionID.reasoningEffort] != effort {
                try await store.updateProviderOption(id: session.id, optionID: StructuredHeadlessOptionID.reasoningEffort, value: effort)
            }
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            providerCapabilitiesBySessionID[session.id] = keepingNegotiatedImageInput(
                nextState,
                for: session.id
            )
        } catch { updateProviderActionError(error, for: session.id) }
    }

    // MARK: Model and effort before a task connects

    /// The provider controls a task's composer shows. A Claude task whose runtime has not reported
    /// its model shows the one it will use — its own choice, else its account's settings, else
    /// Claude Code's default — named from the list Claude Code last advertised, and can choose
    /// from that list without connecting.
    func composerProviderCapabilities(for session: SessionRecord) -> ProviderCapabilityState? {
        let live = providerCapabilitiesBySessionID[session.id]
        if session.harness == .antigravityCLI {
            // An attached task reads its own list as it attaches (`refreshConversationStatus`).
            guard !isAttached(session.id),
                  live?.selectors.contains(where: { $0.id == StructuredHeadlessOptionID.model }) != true else { return live }
            // Before Antigravity lists its models (the task has not attached in this run), the menu
            // names the task's own choice; opening it attaches, which starts nothing, and reads the list.
            var state = live ?? .empty
            state.selectors = AntigravityDetachedSelectors.model(options: session.providerOptions) + state.selectors
            return state
        }
        guard session.harness == .claudeCode,
              live?.selectors.contains(where: { $0.id == ClaudeLaunchOption.model }) != true else { return live }
        let catalog = modelCatalogs.claudeModels(for: session.connection)
        var state = live ?? .empty
        state.selectors = ClaudeComposerModelProjection.selectors(
            model: session.providerOptions[ClaudeLaunchOption.model],
            effort: session.providerOptions[ClaudeLaunchOption.effort],
            defaults: modelCatalogs.defaults(for: .claudeCode, connection: session.connection,
                                             workspaceURL: session.workspaceURL),
            catalog: catalog
        ) + state.selectors
        state.offersModelsBeforeAttach = !isAttached(session.id) && !catalog.isEmpty
        return state
    }

    /// The Codex controls a task's composer shows. Before the App Server reports its own, the
    /// model list is the one it last gave for this account, and the model is the task's own
    /// choice, else the one its thread last reported, else `config.toml`'s, else the list's default.
    func composerCodexCapabilities(for session: SessionRecord) -> CodexCapabilityState {
        var state = codexCapabilitiesBySessionID[session.id] ?? .empty
        guard session.harness == .codex else { return state }
        state.selectedRunLocation = CodexRunLocation.restored(from: session.providerOptions)
        // The task's saved mode shows before the runtime lists its presets; the adapter already
        // sends it from the task's launch options.
        if !state.modes.contains(where: { $0.id == state.selectedModeID }),
           let saved = CodexCollaborationPreset.restored(from: session.providerOptions) {
            if state.modes.isEmpty { state.modes = [saved] }
            state.selectedModeID = saved.matching(state.modes)?.id
        }
        state.modelCatalog = CodexComposerModelProjection.catalog(
            live: state.modelCatalog,
            stored: CodexModelSelection.restored(from: session.providerOptions) ?? modelCatalogs.codexThreads[session.id],
            defaults: modelCatalogs.defaults(for: .codex, connection: session.connection,
                                             scope: session.environmentScope, workspaceURL: nil),
            cached: modelCatalogs.codexModels(for: session.connection)
        )
        return state
    }

    /// Rereads the settings files that name a task's default model. Files only: no runtime starts.
    func prepareComposerModel(for session: SessionRecord) {
        guard session.harness == .claudeCode || session.harness == .codex else { return }
        modelCatalogs.refreshDefaults(for: session.harness, connection: session.connection,
            scope: session.environmentScope, workspaceURL: session.workspaceURL)
    }

    /// A model or effort chosen for a Claude task that has not connected is kept with the task and
    /// applied when it starts: the model as its launch flag, the effort as soon as it connects,
    /// before the turn it connects for. Nothing starts now.
    private func chooseClaudeModelBeforeAttach(_ id: String, value: String, for session: SessionRecord) async {
        guard let current = store.sessions.first(where: { $0.id == session.id }) else { return }
        let catalog = modelCatalogs.claudeModels(for: current.connection)
        let model = id == ClaudeLaunchOption.model ? value
            : current.providerOptions[ClaudeLaunchOption.model]
                ?? modelCatalogs.defaults(for: .claudeCode, connection: current.connection,
                                          workspaceURL: current.workspaceURL)?.model
                ?? ClaudeComposerModelProjection.defaultModel
        let kept = current.providerOptions[ClaudeLaunchOption.effort]
        guard let chosen = ClaudeComposerModelProjection.choosing(id, value: value, model: model, effort: kept,
                                                                  catalog: catalog) else { return }
        do {
            // Choosing only an effort leaves the model to the account's settings, as before.
            if id == ClaudeLaunchOption.model {
                try await store.updateProviderOption(id: current.id, optionID: ClaudeLaunchOption.model, value: chosen.model)
            }
            if let effort = chosen.effort, effort != kept {
                try await store.updateProviderOption(id: current.id, optionID: ClaudeLaunchOption.effort, value: effort)
            }
        } catch { updateProviderActionError(error, for: current.id) }
    }

    /// A model chosen for a Codex task that has not connected is kept with the task; connecting
    /// restores it before the turn it connects for, which then carries it in `turn/start`.
    private func chooseCodexModelBeforeAttach(_ selection: CodexModelSelection, for session: SessionRecord) async {
        guard let current = store.sessions.first(where: { $0.id == session.id }),
              let model = modelCatalogs.codexModels(for: current.connection).first(where: { $0.model == selection.model }),
              selection.reasoningEffort.map({ model.supportedReasoningEfforts.contains($0) }) ?? true,
              let value = selection.storedValue else { return }
        do { try await store.updateProviderOption(id: current.id, optionID: CodexModelSelection.storageKey, value: value) }
        catch { updateCodexActionError(error, for: current.id) }
    }

    /// Reads a harness's model list for the new-task screen when Yardlet has none for the account
    /// yet. Claude Code answers its handshake in a session that is sent nothing and then closed, as
    /// the home command list is read; Codex answers `model/list` from an App Server of its own.
    /// No turn, thread or task starts.
    func loadNewTaskModels(harness: HarnessKind, runtimeURL: URL, connection: ProviderConnection?,
                           workspaceURL: URL?) async {
        guard !isVisualFixture else { return }
        do { try connection?.validate(for: harness) } catch { return }
        switch harness {
        case .claudeCode:
            guard let workspaceURL else { return }
            let adapter = await registry.adapter(for: .claudeCode, executableURL: runtimeURL,
                                                 environmentScope: .native, connection: connection)
            guard (try? await adapter.probeRuntime()) != nil,
                  let handle = try? await adapter.createSession(CreateHarnessSessionRequest(
                      localSessionID: UUID(), workspaceURL: workspaceURL, initialPrompt: nil)) else { return }
            let models = await (adapter as? any HarnessModelCatalogReporting)?.advertisedModels(for: handle.localSessionID)
            await adapter.close(handle)
            if let models { modelCatalogs.recordClaude(models, for: connection) }
        case .codex:
            let transport = CodexProcessTransport(executableURL: runtimeURL,
                environmentManager: connection?.codexEnvironmentManager() ?? codexEnvironmentManager)
            if let models = try? await CodexModelList.read(using: transport) {
                modelCatalogs.recordCodex(models, for: connection)
            }
        case .antigravityCLI:
            // A session that runs nothing: its lists are `agy models` and its kin, which send no prompt.
            let adapter = await registry.adapter(for: .antigravityCLI, executableURL: runtimeURL,
                                                 environmentScope: .native, connection: nil)
            let folder = workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser
            guard let provider = adapter as? any ProviderCapabilityProviding,
                  let reporting = adapter as? any HarnessModelCatalogReporting,
                  (try? await adapter.probeRuntime()) != nil,
                  let handle = try? await adapter.createSession(CreateHarnessSessionRequest(
                      localSessionID: UUID(), workspaceURL: folder, initialPrompt: nil)) else { return }
            _ = try? await provider.providerCapabilities(for: handle)
            let models = await reporting.advertisedModels(for: handle.localSessionID)
            await adapter.close(handle)
            if let models { modelCatalogs.recordAntigravity(models) }
        default:
            return
        }
    }

    private func rememberAdvertisedModels(from adapter: any HarnessAdapter, for session: SessionRecord) async {
        guard session.harness == .claudeCode || session.harness == .antigravityCLI,
              let reporting = adapter as? any HarnessModelCatalogReporting,
              let models = await reporting.advertisedModels(for: session.id) else { return }
        if session.harness == .antigravityCLI {
            modelCatalogs.recordAntigravity(models)
        } else {
            modelCatalogs.recordClaude(models, for: session.connection)
        }
    }

    func performProviderAction(_ id: String, for session: SessionRecord) async {
        do {
            let (_, provider, handle) = try await providerCapabilityProvider(for: session)
            let nextState = try await provider.performProviderAction(
                id: id, in: handle
            )
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            providerCapabilitiesBySessionID[session.id] = keepingNegotiatedImageInput(
                nextState,
                for: session.id
            )
        } catch { updateProviderActionError(error, for: session.id) }
    }

    func shutdown() async {
        scheduledTasks.stop()
        // The quit has written down what was still in line; nothing more begins.
        restartResumeLine = RestartResumeLine()
        sessionJobScan?.cancel()
        sessionJobRelaunches.removeAll()
        restartResumeStartWaits.values.forEach { $0.cancel() }
        restartResumeStartWaits.removeAll()
        routingEvaluationLoop?.cancel()
        // What waits for room stays written down and waits again at the next launch.
        sessionTools.admissionLoop?.cancel()
        resourceMonitor.stop()
        pullRequests.stop()
        pullRequestDetails.stop()
        composerDrafts.persistNow()
        taskWorkspaces.persistNow()
        splits.persistNow()
        let attachments = handlesBySessionID.compactMap { localSessionID, handle in
            adaptersBySessionID[localSessionID].map { ($0, handle) }
        }
        let codexStates = codexPresentations.dictionary
        for (id, state) in codexStates {
            if let waiting = codexItemSaveTasks.removeValue(forKey: id) {
                waiting.cancel()
                persistCodexTimelineItems(state, for: id)
            }
        }
        codexItemSaveTasks.values.forEach { $0.cancel() }
        codexItemSaveTasks.removeAll()
        codexSnapshotCheckpointTasks.values.forEach { $0.cancel() }
        codexSnapshotCheckpointTasks.removeAll()
        codexModelRestoreErrors.removeAll()
        eventTasksBySessionID.values.forEach { $0.cancel() }
        transcriptPublicationTasks.values.forEach { $0.cancel() }
        codexPresentationTasks.values.forEach { $0.cancel() }
        followUpDrainTasks.values.forEach { $0.cancel() }
        for sessionID in Set(runningShellCommandBySessionID.keys).union(pendingShellDeliveries.keys) {
            discardShellCommands(for: sessionID)
        }
        taskShells.closeAll()
        sessionTitleResolutionTasks.values.forEach { $0.cancel() }
        eventTasksBySessionID.removeAll()
        pendingTranscriptDeltas.removeAll()
        transcriptPublicationTasks.removeAll()
        codexPresentationTasks.removeAll()
        followUpDrainTasks.removeAll()
        sessionTitleResolutionTasks.removeAll()
        sessionTitleRefreshes.removeAll()
        codexTurnPageLoads.removeAll()
        codexItemPageLoads.removeAll()
        handlesBySessionID.removeAll()
        adaptersBySessionID.removeAll()
        codexPresentations.removeAll()
        codexHistorySelectionBySessionID.removeAll()
        // Each Codex thread's reading snapshot is worked out off the main thread, as it is written:
        // a long thread takes a while to flatten, and quitting held the main thread for every one.
        let codexSnapshots = await Task.detached(priority: .userInitiated) {
            codexStates.filter { $0.value.thread != nil }
                .mapValues { CodexTranscriptSnapshotProjection.entries(from: $0) }
        }.value
        for (id, entries) in codexSnapshots {
            if entries.isEmpty { transcriptSnapshots.removeSoon(for: id) } else { transcriptSnapshots.saveSoon(entries, for: id) }
        }
        // Every reading snapshot is saved before quitting goes on. Nothing above is left to
        // publish another one: the streams and publications that would were cancelled first.
        await transcriptSnapshots.flushed()

        for (adapter, handle) in attachments {
            await adapter.close(handle)
        }
        await registry.invalidateAll()
    }

    func switchAccount(to connection: ProviderConnection, for session: SessionRecord) async {
        guard let current = store.sessions.first(where: { $0.id == session.id }),
              !switchingAccounts.contains(session.id),
              current.connection == session.connection, current.providerSessionID == session.providerSessionID,
              current.status != .running, current.status != .waitingForApproval,
              connection != current.connection, TaskAccountSwitch.allows(connection, for: current) else { return }
        switchingAccounts.insert(current.id)
        defer { switchingAccounts.remove(current.id) }
        cancelUsageLimitAutoContinue(for: current.id)
        func stillIdle() -> Bool {
            guard let value = store.sessions.first(where: { $0.id == current.id }) else { return false }
            return value.connection == current.connection && value.providerSessionID == current.providerSessionID
                && value.environmentScope == current.environmentScope && value.runtimeExecutableURL == current.runtimeExecutableURL
                && value.workspaceURL == current.workspaceURL && value.status != .running && value.status != .waitingForApproval
        }
        do {
            try connection.validate(for: current.harness)
            // The task resumes under the target's own login, so that CLI must report one first.
            let status = try await AccountCommandRunner.run(executableURL: current.runtimeExecutableURL,
                arguments: ["auth", "status"], environment: connection.environment)
            guard HarnessAccountBroker.commandAccountState(for: .claudeCode, result: status) == .signedIn
            else { throw ProviderConnectionError.signedOut }
            guard stillIdle(), TaskAccountSwitch.allows(connection, for: current) else {
                throw ProviderConnectionError.invalidBinding
            }
            eventTasksBySessionID.removeValue(forKey: current.id)?.cancel()
            flushTranscriptDeltas(for: current.id)
            if let adapter = adaptersBySessionID.removeValue(forKey: current.id),
               let handle = handlesBySessionID.removeValue(forKey: current.id) { await adapter.close(handle) }
            await registry.invalidate(harness: current.harness, executableURL: current.runtimeExecutableURL,
                environmentScope: current.environmentScope, connection: current.connection)
            guard stillIdle() else {
                throw ProviderConnectionError.invalidBinding
            }
            try await store.updateConnection(id: current.id, connection: connection)
            // The previous account's warning and limits say nothing about the next one.
            rateLimitWarningBySessionID.removeValue(forKey: current.id)
            codexStatusBySessionID.removeValue(forKey: current.id)
            guard let updated = store.sessions.first(where: { $0.id == current.id }) else { return }
            try await attach(updated, resumesExistingSession: updated.providerSessionID != nil)
        } catch { errorBySessionID[current.id] = error.localizedDescription }
    }

    /// Saved accounts a task stopped by a plan limit can continue under (the ones that share its
    /// conversation history), with the most limit left first and unchecked ones last.
    func usageLimitAccounts(for session: SessionRecord) -> [ProviderConnection] {
        guard let current = store.sessions.first(where: { $0.id == session.id }) else { return [] }
        return AccountListProjection.choices(.continueAfterLimit(current), store: connections)
            .compactMap { $0.connection == current.connection ? nil : $0.connection }
    }

    /// What a limit card's "Continue with another account" opens: the task's account list.
    func usageLimitAccountOptions(for session: SessionRecord) -> UsageLimitAccounts {
        let current = store.sessions.first { $0.id == session.id } ?? session
        return UsageLimitAccounts(session: current, store: connections, runtimeSelections: runtimeSelections,
            others: usageLimitAccounts(for: current))
    }

    /// Rereads the offered accounts' limits unless a check confirmed them within the last minute,
    /// as the account list does when it opens. Only the CLI's own status and usage requests run.
    func refreshUsageLimitAccounts(for session: SessionRecord) async {
        let offered = usageLimitAccounts(for: session)
        guard !offered.isEmpty else { return }
        await connections.check(defaultsOf: [], savedOf: [session.harness], connectionIDs: Set(offered.map(\.id)),
            runtimeSelections: runtimeSelections)
    }

    /// Moves a task a plan limit stopped to another account that shares its history, then asks
    /// Claude to pick up where it stopped. Nothing is sent unless the switch completed.
    func continueAfterUsageLimit(using connection: ProviderConnection, for session: SessionRecord) async {
        // An earlier failure is superseded by this attempt, so one left afterwards is its own.
        usageLimitSwitchErrorBySessionID.removeValue(forKey: session.id)
        errorBySessionID.removeValue(forKey: session.id)
        await switchAccount(to: connection, for: session)
        guard let updated = store.sessions.first(where: { $0.id == session.id }),
              updated.connection == connection, handlesBySessionID[updated.id] != nil,
              errorBySessionID[updated.id] == nil else {
            // A refusal such as a signed-out account shows on the limit card that asked for it.
            if let message = errorBySessionID[session.id] { usageLimitSwitchErrorBySessionID[session.id] = message }
            return
        }
        await send(HarnessUserInput(text: UsageLimitContinuation.afterAccountSwitch), to: updated)
    }

    /// Arms or disarms the automatic continue for one limit card. Armed, the task sends the
    /// continue message once the limit has reset, unless it changed in the meantime.
    func setUsageLimitAutoContinue(_ enabled: Bool, entryID: UUID, resetsAt: Date, for session: SessionRecord) {
        cancelUsageLimitAutoContinue(for: session.id)
        guard enabled, let current = store.sessions.first(where: { $0.id == session.id }),
              current.harness == .claudeCode else { return }
        let armed = UsageLimitAutoContinue(entryID: entryID, resetsAt: resetsAt,
            providerSessionID: current.providerSessionID, connection: current.connection)
        usageLimitAutoContinue[current.id] = armed
        let wait = Duration.seconds(max(0, resetsAt.timeIntervalSinceNow)) + usageLimitResumeGrace
        usageLimitAutoContinueTasks[current.id] = Task { [weak self] in
            // The continuous clock keeps counting while the Mac sleeps, so a reset that passed
            // during sleep is acted on at wake.
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.continueAfterUsageLimitReset(current.id, armed: armed)
        }
    }

    private func cancelUsageLimitAutoContinue(for sessionID: UUID) {
        usageLimitAutoContinueTasks.removeValue(forKey: sessionID)?.cancel()
        if usageLimitAutoContinue[sessionID] != nil { usageLimitAutoContinue.removeValue(forKey: sessionID) }
    }

    /// The continue message goes only to the task exactly as it was left: the same conversation
    /// and account, idle, nothing after the limit card, and no message being edited.
    private func continueAfterUsageLimitReset(_ sessionID: UUID, armed: UsageLimitAutoContinue) async {
        guard usageLimitAutoContinue[sessionID] == armed else { return }
        usageLimitAutoContinue.removeValue(forKey: sessionID)
        usageLimitAutoContinueTasks.removeValue(forKey: sessionID)
        flushTranscriptDeltas(for: sessionID)
        guard let session = store.sessions.first(where: { $0.id == sessionID }),
              session.providerSessionID == armed.providerSessionID, session.connection == armed.connection,
              session.status != .running, session.status != .waitingForApproval,
              transcriptBuilders[sessionID]?.entries.last?.id == armed.entryID,
              composerDrafts.tasks.draft(for: sessionID).editState == nil,
              !switchingAccounts.contains(sessionID), !sessionMutations.contains(sessionID) else { return }
        await send(HarnessUserInput(text: UsageLimitContinuation.afterReset), to: session)
    }

    // MARK: - Continuing after a restart

    /// Writes down, while Yardlet quits, the tasks whose turn the quit cuts off and that their own
    /// app would continue (`RestartResumePolicy`), and those the last launch had not continued yet.
    /// With the setting off, or nothing to continue, any earlier record goes.
    func recordWorkForRestart(trigger: RestartTrigger, now: Date = Date()) {
        guard !isVisualFixture else { return }
        RestartResumeRecord(trigger: trigger, recordedAt: now, entries: restartResumeEntries(now: now)).save(to: preferences)
    }

    /// The tasks that continue when Yardlet opens again if it quit now, for the quit confirmation
    /// to say which of the running ones do. Empty with the setting off.
    func tasksContinuingAfterRestart() -> Set<UUID> {
        guard !isVisualFixture else { return [] }
        return Set(restartResumeEntries(now: Date()).map(\.sessionID))
    }

    private func restartResumeEntries(now: Date) -> [RestartResumeRecord.Entry] {
        let candidates = store.sessions.map { session in
            RestartResumePolicy.Candidate(
                session: session,
                hasQueuedMessages: !followUps.queue(for: session.id).isEmpty,
                stoppedByPerson: stoppedByPerson.contains(session.id),
                unseenContinuations: isSessionVisible(session.id) ? 0 : unseenRestartResumes[session.id] ?? 0,
                isSubagentThread: codexPresentationBySessionID[session.id]?.thread?.parentThreadID != nil,
                waitingQuestion: Self.waitingQuestion(in: transcriptBySessionID[session.id] ?? [],
                                                      codex: codexPresentationBySessionID[session.id])
            )
        }
        let stillToContinue = restartResumesToContinue.values.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
        return RestartResumePolicy.entries(for: candidates, stillToContinue: stillToContinue, now: now,
            isOn: RestartResumePreference.isOn(in: preferences))
    }

    /// The question a task's latest turn waits on the person to answer, when it waits on nothing
    /// else: its one open request asks questions, in the shared transcript (Claude Code's
    /// `AskUserQuestion`) or among the Codex thread's requests (`item/tool/requestUserInput`). A Codex
    /// question with a secret answer is left out: its answer would go as a message anyone reads.
    nonisolated static func waitingQuestion(in transcript: [TranscriptEntry], codex: CodexTaskState?) -> RestartQuestion? {
        // Every open request by its ID (a Codex approval shows in both records), with its question.
        var open: [String: RestartQuestion] = [:]
        var others = Set<String>()
        for entry in transcript.reversed() {
            if case .user = entry.content, entry.joinsRunningTurn != true { break }
            guard case let .permission(request, .pending) = entry.content else { continue }
            if case .questions = request.structured { open[request.id] = .request(request) } else { others.insert(request.id) }
        }
        if let codex {
            // As the Codex row reads them (`TaskAttentionDetail.reading`): those of the running turn.
            func isOpen(_ turnID: String?) -> Bool { turnID == nil || turnID == codex.activeTurnID }
            for approval in codex.approvalsByID.values where approval.resolution == .pending && isOpen(approval.turnID) {
                others.insert(approval.id)
            }
            for request in codex.serverRequestsByID.values where request.resolution == .pending && isOpen(request.turnID) {
                if request.kind == .toolUserInput,
                   !CodexRequestResponseProjection.questions(request.params).contains(where: \.isSecret) {
                    open[request.id] = .codex(CodexPendingServerRequest(request))
                } else {
                    others.insert(request.id)
                }
            }
        }
        guard open.count == 1, others.subtracting(open.keys).isEmpty else { return nil }
        return open.values.first
    }

    /// Reads the record the last quit wrote, once, after the task index is back, and continues
    /// what it allows: the most recent first, a few starting at a time, and those that waited on
    /// the person once they are opened.
    /// Then the idle Claude Code tasks whose CLI brings session jobs back start again, after them.
    func continueWorkInterruptedByRestart(now: Date = Date()) async {
        guard !isVisualFixture else { return }
        await continueTurnsCutOffByRestart(now: now)
        await relaunchForSessionJobs()
    }

    private func continueTurnsCutOffByRestart(now: Date) async {
        guard let record = RestartResumeRecord.load(from: preferences) else { return }
        RestartResumeRecord.remove(from: preferences)
        let plan = RestartResumePolicy.plan(for: record, sessions: store.sessions, now: now,
            isOn: RestartResumePreference.isOn(in: preferences))
        restartResumesToContinue.merge(plan.entries) { _, new in new }
        restartResumesWhenOpened.merge(plan.whenOpened) { _, new in new }
        // A question the quit cut off waits for the person on the card it was asked on.
        for (id, question) in plan.questions {
            restartQuestions[id] = switch question {
            case let .request(request):
                TranscriptConversationProjection.conversationRequest(
                    request, state: .pending, entry: TranscriptEntry(content: .permission(request, state: .pending)))
            case let .codex(request):
                CodexRequestResponseProjection.request(request.state)
            }
            refreshAttentionDetail(for: id)
        }
        restartResumeLine.append(plan.atLaunch)
        await continueRestartResumeLine()
        // A task already open counts as opened.
        taskOpened(store.selectedSessionID, now: now)
    }

    /// Whether a cut-off turn waits for its task to be opened before it continues.
    func continuesWhenOpened(_ id: UUID) -> Bool {
        restartResumesWhenOpened[id] != nil
    }

    /// Starts again, with nothing sent, the CLI of each idle Claude Code task whose saved conversation
    /// holds a session job the CLI brings back on resuming it (`ClaudeSessionJobs`):
    /// the jobs ran only in the CLI the quit ended. They take their turn in the restart line behind
    /// the cut-off turns, and only under the restart setting.
    private func relaunchForSessionJobs() async {
        guard RestartResumePreference.isOn(in: preferences) else { return }
        let now = Date()
        // Whether another app holds a conversation is asked only of those found to have jobs.
        let candidates = store.sessions.filter { relaunchesForSessionJobs($0, now: now, askingRefusal: false) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { session in session.providerSessionID.map { (session.id, claudeSessionReader(for: session), $0) } }
        guard !candidates.isEmpty else { return }
        let scan = Task.detached(priority: .utility) { () -> [UUID] in
            candidates.filter { _, reader, conversation in
                guard !Task.isCancelled else { return false }
                let records = (try? reader.recordsNamingSessionJobs(sessionID: conversation)) ?? []
                return !ClaudeSessionJobs.broughtBack(from: records, now: Date()).isEmpty
            }.map(\.0)
        }
        sessionJobScan = scan
        let found = await scan.value
        guard !scan.isCancelled else { return }
        sessionJobScan = nil
        let relaunching = found.filter { id in
            store.sessions.first { $0.id == id }.map { relaunchesForSessionJobs($0, now: Date()) } ?? false
        }
        sessionJobRelaunches.formUnion(relaunching)
        restartResumeLine.append(relaunching)
        await continueRestartResumeLine()
    }

    // MARK: Session jobs a running CLI holds

    /// The session jobs the task's CLI holds while it runs, for its rail; none once it stopped, since
    /// they lived in it. What exists comes from the CLI's own records read by its own rule, not from
    /// the stream: the CLI announces no job, and its records also hold what a compaction carried over
    /// and what it brought back on resuming, which the stream never repeats.
    func sessionJobs(of id: UUID) -> [ClaudeSessionJob] {
        handlesBySessionID[id] == nil ? [] : sessionJobsBySessionID[id] ?? []
    }

    /// Every task's session jobs, for the scheduled tasks list: the tasks Yardlet runs a CLI for, in
    /// the sidebar's order of tasks.
    var scheduledSessionJobs: [ScheduledSessionJob] {
        store.sessions.flatMap { session in
            sessionJobs(of: session.id).map { ScheduledSessionJob(session: session, job: $0) }
        }
    }

    /// Reads again what the task's running CLI holds, off the main thread; one read at a time per task.
    private func readSessionJobs(of id: UUID) {
        guard let session = store.sessions.first(where: { $0.id == id }), session.harness == .claudeCode,
              let conversation = session.providerSessionID, handlesBySessionID[id] != nil else {
            if sessionJobsBySessionID[id] != nil { sessionJobsBySessionID.removeValue(forKey: id) }
            return
        }
        let reader = claudeSessionReader(for: session)
        let since = runtimeStartedAt[id]
        sessionJobReads.removeValue(forKey: id)?.cancel()
        sessionJobReads[id] = Task { [weak self] in
            let jobs = await Task.detached(priority: .utility) {
                let records = (try? reader.recordsNamingSessionJobs(sessionID: conversation)) ?? []
                return ClaudeSessionJobs.held(in: records, now: Date(), runningSince: since)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.sessionJobReads[id] = nil
            let held = self.handlesBySessionID[id] == nil || jobs.isEmpty ? nil : jobs
            if self.sessionJobsBySessionID[id] != held { self.sessionJobsBySessionID[id] = held }
        }
    }

    /// Whether the task's latest turn called a tool that makes, ends or lists a session job.
    private func latestTurnTouchedSessionJobs(_ id: UUID) -> Bool {
        for entry in (transcriptBySessionID[id] ?? []).reversed() {
            if case let .activity(activity, _) = entry.content, ClaudeSessionJobs.toolNames.contains(activity.kind) {
                return true
            }
            if entry.opensTurn { return false }
        }
        return false
    }

    /// Whether a task's CLI may start again for its session jobs: an idle Claude Code task touched
    /// within a recurring job's lifetime, with no runtime, nothing the restart already continues or
    /// keeps waiting for the person (its turn, an approval, a question), no message waiting to go, and
    /// nothing being edited, moved or refused. The rest start when the person comes to them.
    private func relaunchesForSessionJobs(_ session: SessionRecord, now: Date, askingRefusal: Bool = true) -> Bool {
        session.harness == .claudeCode && session.providerSessionID != nil
            && now.timeIntervalSince(session.updatedAt) < ClaudeSessionJobs.recurringMaxAge
            && handlesBySessionID[session.id] == nil
            && session.status != .running && session.status != .waitingForApproval
            && restartResumesToContinue[session.id] == nil && connectionResumes[session.id] == nil
            && followUps.queue(for: session.id).isEmpty && pendingShellDeliveries[session.id]?.isEmpty != false
            && !switchingAccounts.contains(session.id) && !sessionMutations.contains(session.id)
            && composerDrafts.tasks.existingDraft(for: session.id)?.editState == nil
            && (!askingRefusal || sendRefusal(for: session) == nil)
    }

    // MARK: Memory saver (HarnessMemorySaver)

    /// Starts the memory saver's looks at the tasks' runtimes (`checkHarnessMemory`): every minute, and at once when
    /// macOS reports memory pressure.
    func startHarnessMemorySaver() {
        guard harnessMemorySaverTask == nil else { return }
        harnessMemorySaverTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.harnessMemorySaverTiming.checkInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                await self?.checkHarnessMemory()
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { _ = Task { await self?.checkHarnessMemory() } }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Ends the runtimes `HarnessMemorySaver` picks, while the setting is on. A Codex thread with a background terminal
    /// stays: only its attached thread says so.
    func checkHarnessMemory(now: Date = Date(), pressure: MacLoad.MemoryPressure = MacConditionReader.memoryPressure(),
                            physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) async {
        noteMemorySaverScreen(now: now)
        guard MemorySaverPreference.isOn(in: preferences) else { return }
        let runtimes = store.sessions.compactMap { session -> HarnessMemorySaver.Runtime? in
            guard handlesBySessionID[session.id] != nil else { return nil }
            let kind: HarnessMemorySaver.Kind
            switch session.harness {
            case .claudeCode: kind = .claudeProcess
            case .codex: kind = .codexThread
            default: return nil
            }
            let idleSince = [session.updatedAt, providerActivityBySessionID[session.id], lastOnScreen[session.id],
                             runtimeStartedAt[session.id]].compactMap { $0 }.max() ?? session.updatedAt
            return HarnessMemorySaver.Runtime(task: session.id, kind: kind, idleSince: idleSince,
                                              keptBy: memorySaverKeeps(session))
        }
        let pressureSweep = pressure >= .warning
            && lastMemoryPressureSweep.map { now.timeIntervalSince($0) >= harnessMemorySaverTiming.pressureSpacing } ?? true
        if pressureSweep { lastMemoryPressureSweep = now }
        for id in HarnessMemorySaver.releases(runtimes, now: now, pressureSweep: pressureSweep,
                                              physicalMemory: physicalMemory, timing: harnessMemorySaverTiming) {
            await endRuntimeToSaveMemory(id)
        }
    }

    /// The tasks on screen: the window's task or split panes, the side chat each shows, and the tasks the phone shows.
    private func memorySaverOnScreenIDs() -> Set<UUID> {
        var onScreen = sessionToolOnScreenIDs().union(remoteWatchedTaskIDs)
        for id in onScreen {
            guard let workspace = taskWorkspaces.loadedState(for: id), workspace.panels.trailingSurfaceID == "sideChat",
                  let side = workspace.sideChatSessionID else { continue }
            onScreen.insert(side)
        }
        return onScreen
    }

    /// Records which tasks are on screen: the window's task or split panes, the side chat it shows, and the tasks the
    /// phone shows. A task that leaves the screen starts its idle time then.
    func noteMemorySaverScreen(now: Date = Date()) {
        let onScreen = memorySaverOnScreenIDs()
        for id in onScreen.union(memorySaverOnScreen) { lastOnScreen[id] = now }
        memorySaverOnScreen = onScreen
    }

    /// What keeps an attached task's runtime whatever the memory saver's rules say, in a word for the log and tests;
    /// nil when the saver may end it. When in doubt it keeps the runtime: the task on screen, a turn or its question,
    /// messages waiting to go, the harness's background shells and schedules, a server of the task or its processes
    /// keeping a core busy (its terminal's among them), child tasks and subagents still working, and an edit, move or
    /// continuation under way. An idle terminal does not keep it: the shell goes on without the runtime.
    func memorySaverKeeps(_ session: SessionRecord) -> String? {
        let id = session.id
        if memorySaverOnScreenIDs().contains(id) { return "on screen" }
        if session.status == .running || session.status == .waitingForApproval
            || codexPresentationBySessionID[id]?.activeTurnID != nil || runningShellCommandBySessionID[id] != nil {
            return "turn"
        }
        if TaskAttentionProjection.waitingRequest(of: session, detail: taskAttentionDetails[id]) != nil
            || !heldRequests(in: id).isEmpty {
            return "question"
        }
        if !followUps.queue(for: id).isEmpty || pendingShellDeliveries[id]?.isEmpty == false { return "queued" }
        if !BackgroundTasksProjection(entries: transcriptBySessionID[id] ?? []).rows.isEmpty { return "background" }
        if !sessionJobs(of: id).isEmpty { return "schedule" }
        if !resourceMonitor.servers(of: id).isEmpty || !resourceMonitor.busyCPU(of: [id]).isEmpty { return "processes" }
        if sessionTools.runs(hostedBy: id).contains(where: { !$0.state.isFinished })
            || sessionTools.queue.contains(where: { $0.callerID == id })
            || store.sessions.contains(where: { $0.parentTaskID == id && ($0.status == .running || $0.status == .waitingForApproval) }) {
            return "children"
        }
        if composerDrafts.tasks.existingDraft(for: id)?.editState != nil || sessionMutations.contains(id)
            || switchingAccounts.contains(id) || forkingSessions.contains(id) || restartingSessions.contains(id)
            || openingSideChats.contains(id) || unarchivingSessionIDs.contains(id) || recreatingTaskWorktrees.contains(id) {
            return "changing"
        }
        if restartResumesToContinue[id] != nil || restartResumesWhenOpened[id] != nil || sessionJobRelaunches.contains(id)
            || restartResumeLine.waiting.contains(id) || restartResumeLine.starting.contains(id)
            || connectionResumes[id] != nil || usageLimitAutoContinue[id] != nil {
            return "continuing"
        }
        return nil
    }

    /// Ends an idle task's runtime to free its memory, as an idle runtime that ends on its own does
    /// (`eventStreamEnded`), but the task stays ready and its next message resumes the same provider session. Nothing
    /// is sent to the conversation. A Codex thread with a background terminal stays, and so does one whose terminals the
    /// App Server could not list.
    func endRuntimeToSaveMemory(_ id: UUID) async {
        guard let adapter = adaptersBySessionID[id], let handle = handlesBySessionID[id],
              let session = store.sessions.first(where: { $0.id == id }), memorySaverKeeps(session) == nil else { return }
        if session.harness == .codex {
            guard let terminals = await codexBackgroundTerminals(of: session), terminals.isEmpty else { return }
        }
        let finalState: CodexTaskState?
        if let provider = adapter as? any CodexPresentationProviding {
            finalState = try? await provider.presentationState(for: handle)
        } else {
            finalState = nil
        }
        // The person may have come back to it meanwhile.
        guard handlesBySessionID[id] == handle, let current = store.sessions.first(where: { $0.id == id }),
              memorySaverKeeps(current) == nil else { return }
        eventTasksBySessionID.removeValue(forKey: id)?.cancel()
        codexPresentationTasks.removeValue(forKey: id)?.cancel()
        followUpDrainTasks.removeValue(forKey: id)?.cancel()
        flushTranscriptDeltas(for: id)
        followUps.holdAllSent(in: id)
        if var state = finalState ?? codexPresentationBySessionID[id] {
            mergePersistedCodexServerRequests(into: &state, for: id)
            mergePersistedCodexTimelineItems(into: &state, for: id)
            CodexTaskReducer().endRuntime(in: &state)
            codexPresentations[id] = state
            persistCodexServerRequests(state, for: id)
            persistCodexTimelineItems(state, for: id)
            persistCodexTranscriptSnapshot(state, for: id)
        }
        mutateTranscript(for: id, publishImmediately: true) { $0.endRuntime() }
        handlesBySessionID.removeValue(forKey: id)
        adaptersBySessionID.removeValue(forKey: id)
        // An adapter no task uses any more may have ended its process for good (a Codex App Server stops with its
        // last task): the next attach, which waits for this, makes a new one, as after archiving.
        let closing = Task { @MainActor [registry] in
            await adapter.close(handle)
            let identity = ObjectIdentifier(adapter as AnyObject)
            if !self.adaptersBySessionID.values.contains(where: { ObjectIdentifier($0 as AnyObject) == identity }) {
                await registry.invalidate(harness: session.harness, executableURL: session.runtimeExecutableURL,
                                          environmentScope: session.environmentScope, connection: session.connection)
            }
        }
        memorySaverClosings[id] = closing
        await closing.value
        memorySaverClosings[id] = nil
    }

    /// Begins the continuations in line while fewer than `RestartResumePolicy.launchLimit` are
    /// starting. One Yardlet asked for keeps its place until its provider shows work or
    /// `RestartResumePolicy.startWindow` passes; one with nothing to continue gives it up at once.
    private func continueRestartResumeLine() async {
        guard !continuesRestartResumeLine else { return }
        continuesRestartResumeLine = true
        defer { continuesRestartResumeLine = false }
        while let id = restartResumeLine.next() {
            let asked = await continueAfterRestart(id)
            // Its provider may have shown work already.
            guard restartResumeLine.starting.contains(id) else { continue }
            guard asked else {
                restartResumeStarted(id)
                continue
            }
            let sleep = restartResumeSleep
            restartResumeStartWaits[id] = Task { [weak self] in
                do { try await sleep(RestartResumePolicy.startWindow) } catch { return }
                guard !Task.isCancelled else { return }
                self?.restartResumeStarted(id)
            }
        }
    }

    /// A starting continuation showed work, waited out its window, or had nothing to start: the
    /// next one in line may begin.
    private func restartResumeStarted(_ id: UUID) {
        restartResumesAwaitingWork.remove(id)
        restartResumeStartWaits.removeValue(forKey: id)?.cancel()
        // A line already running picks up the free place itself.
        guard restartResumeLine.finishStarting(id), !continuesRestartResumeLine else { return }
        Task { await continueRestartResumeLine() }
    }

    /// The person opened a task: a turn that waits for that, in line or until opened, continues now.
    private func taskOpened(_ id: UUID?, now: Date = Date()) {
        guard let id else { return }
        readSavedConversation(of: id)
        unseenRestartResumes.removeValue(forKey: id)
        if restartResumeLine.removeWaiting(id) {
            Task { await continueAfterRestart(id) }
            return
        }
        guard let deadline = restartResumesWhenOpened.removeValue(forKey: id) else { return }
        guard now < deadline else {
            restartResumesToContinue.removeValue(forKey: id)
            return
        }
        Task { await continueAfterRestart(id) }
    }

    /// Whatever the person does in a task takes over from continuing it, and from the line saying
    /// it was continued.
    private func personActed(on id: UUID) {
        restartResumesWhenOpened.removeValue(forKey: id)
        restartResumeLine.removeWaiting(id)
        sessionJobRelaunches.remove(id)
        restartResumesToContinue.removeValue(forKey: id)
        if restartResumeNoticeSessionIDs.contains(id) { restartResumeNoticeSessionIDs.remove(id) }
        stopAskingRestartQuestion(id)
        forgetConnectionResume(id)
    }

    // MARK: Continuing after a lost connection

    /// The system reported the network path: once it is up again, every task whose cut-off turn is due
    /// continues.
    func networkPathChanged(isSatisfied: Bool) {
        guard isNetworkAvailable != isSatisfied else { return }
        isNetworkAvailable = isSatisfied
        if isSatisfied { continueDueConnectionResumes() }
    }

    /// The provider ended a turn on its own connection error: the task waits for the network and the
    /// Claude app's time after the cut, then continues, as many times in a row as the policy allows.
    /// A turn the person stopped, or a task the setting leaves alone, does not.
    private func acceptTurnCut(_ cut: TurnCut, for id: UUID, at date: Date) {
        guard cut != .quit, RestartResumePreference.isOn(in: preferences), !stoppedByPerson.contains(id),
              store.sessions.contains(where: { $0.id == id }) else { return }
        let continued = connectionResumes[id]?.continuations ?? 0
        guard continued < ConnectionResumePolicy.limit else {
            forgetConnectionResume(id)
            return
        }
        connectionResumes[id] = ConnectionResume(cut: cut, cutAt: date, continuations: continued, isWaiting: true)
        refreshAttentionDetail(for: id)
        connectionResumeWaits.removeValue(forKey: id)?.cancel()
        let delay = max(0, connectionResumes[id]?.dueAt.timeIntervalSinceNow ?? 0)
        let sleep = connectionResumeSleep
        connectionResumeWaits[id] = Task { [weak self] in
            do { try await sleep(.milliseconds(Int64(delay * 1_000))) } catch { return }
            guard !Task.isCancelled else { return }
            self?.connectionResumeIsDue(id)
        }
    }

    private func connectionResumeIsDue(_ id: UUID) {
        connectionResumeWaits.removeValue(forKey: id)
        guard connectionResumes[id]?.isWaiting == true else { return }
        connectionResumes[id]?.isDue = true
        if isNetworkAvailable { continueDueConnectionResumes() }
    }

    /// Continues every waiting task whose time has come, in the order their turns were cut off, a few
    /// starting at once (`RestartResumeLine`), while the network is up.
    private func continueDueConnectionResumes() {
        let due = connectionResumes.filter { $0.value.isWaiting && $0.value.isDue }
            .sorted { $0.value.cutAt < $1.value.cutAt }.map(\.key)
        guard isNetworkAvailable, !due.isEmpty else { return }
        restartResumeLine.append(due)
        Task { await continueRestartResumeLine() }
    }

    /// The task no longer waits to continue after a lost connection: it continued and ended, someone
    /// else started a turn, or the person took over.
    private func forgetConnectionResume(_ id: UUID) {
        connectionResumeWaits.removeValue(forKey: id)?.cancel()
        guard connectionResumes.removeValue(forKey: id) != nil else { return }
        restartResumeLine.removeWaiting(id)
        refreshAttentionDetail(for: id)
    }

    /// Continues a turn a lost connection cut off, the way its provider's app does: Claude Code is sent
    /// the Claude app's "Try again" (or its sleep message), Codex the Codex app's Resume. A message
    /// waiting in the queue goes instead, as the next turn. True once the provider was asked.
    private func continueAfterConnectionCut(_ id: UUID) async -> Bool {
        guard var record = connectionResumes[id], record.isWaiting, isNetworkAvailable,
              RestartResumePreference.isOn(in: preferences),
              let session = store.sessions.first(where: { $0.id == id }),
              session.status != .running, session.status != .waitingForApproval,
              !switchingAccounts.contains(id), !sessionMutations.contains(id),
              composerDrafts.tasks.draft(for: id).editState == nil else { return false }
        let inLine = restartResumeLine.starting.contains(id)
        if !followUps.queue(for: id).isEmpty {
            forgetConnectionResume(id)
            if inLine { restartResumesAwaitingWork.insert(id) }
            scheduleFollowUpDrain(for: id)
            return true
        }
        if handlesBySessionID[id] == nil { await resume(session) }
        guard connectionResumes[id]?.isWaiting == true, let current = matchingSession(session),
              current.status != .running, current.status != .waitingForApproval,
              let adapter = adaptersBySessionID[id] as? any HarnessInterruptedTurnContinuing,
              let handle = handlesBySessionID[id] else {
            forgetConnectionResume(id)
            return false
        }
        record.isWaiting = false
        record.isDue = false
        record.continuations += 1
        connectionResumes[id] = record
        refreshAttentionDetail(for: id)
        // The continuation is a turn of its own after the error that ended the last one, with no
        // request of the person's to show (the provider's message is the app speaking).
        if !HarnessPresentationPolicy(harness: current.harness).usesCodexTimeline {
            mutateTranscript(for: id, publishImmediately: true) { builder in
                builder.appendUser("", origin: .provider)
            }
        }
        await markSubmissionStarted(for: id)
        if inLine { restartResumesAwaitingWork.insert(id) }
        do {
            let started = try await adapter.continueInterruptedTurn(in: handle, after: record.cut)
            guard store.sessions.contains(where: { $0.id == id }) else { return false }
            if !started {
                forgetConnectionResume(id)
                if store.sessions.first(where: { $0.id == id })?.status == .running {
                    try? await store.updateSession(id: id, status: .ready)
                }
            }
            return started
        } catch {
            guard store.sessions.contains(where: { $0.id == id }) else { return false }
            forgetConnectionResume(id)
            try? await store.updateSession(id: id, status: .failed)
            errorBySessionID[id] = error.localizedDescription
            return false
        }
    }

    /// The question a restart cut off in this task, while the provider's record shows nothing asked
    /// after its call: the card drawn at the end of the latest turn.
    func restartQuestion(in id: UUID) -> ConversationRequest? {
        guard let card = restartQuestions[id] else { return nil }
        // A Codex thread with a turn after the one that asked.
        if case let .codexServerRequest(request) = card.source, let turns = codexPresentationBySessionID[id]?.thread?.turns,
           let asked = turns.firstIndex(where: { $0.id == request.turnID }), asked < turns.count - 1 {
            return nil
        }
        // A transcript with a request after the call that asked.
        guard let callID = card.toolCallID, let transcript = transcriptBySessionID[id],
              let call = transcript.lastIndex(where: { entry in
                  if case let .activity(activity, _) = entry.content { activity.id == callID } else { false }
              }) else { return card }
        return transcript[(call + 1)...].contains(where: \.opensTurn) ? nil : card
    }

    /// The question stops waiting: the person answered it or sent something else, or a turn began.
    /// A later quit no longer carries it over.
    private func stopAskingRestartQuestion(_ id: UUID) {
        guard restartQuestions.removeValue(forKey: id) != nil else { return }
        restartResumesToContinue.removeValue(forKey: id)
        refreshAttentionDetail(for: id)
    }

    /// The person's answers to a question a restart cut off go as their next message, which names
    /// the questions it answers (`RestartQuestionAnswer`): the call that asked them is gone. False
    /// when the request is not that question.
    /// Its card's route brings the answers in the provider's own shape: Claude Code's per-question
    /// picks, or Codex's answers under each question's ID.
    private func answerRestartQuestion(_ requestID: String, answer: PermissionStructuredAnswer? = nil,
                                       codexResponse: CodexServerRequestResponse? = nil,
                                       in session: SessionRecord) async -> Bool {
        guard let card = restartQuestions[session.id], card.id == requestID else { return false }
        stopAskingRestartQuestion(session.id)
        let text: String
        switch (card.form, answer, codexResponse) {
        case let (.choices(questions)?, .questions(answers)?, _):
            text = RestartQuestionAnswer.message(questions: questions, answers: answers)
        case let (.freeText(questions)?, _, .toolUserInput(answers)?):
            // The words Codex sent for each question, not the card's stand-in for a question without any.
            var params: JSONValue?
            if case let .codexServerRequest(request) = card.source { params = request.params }
            let asked = params?["questions"]?.arrayValue ?? []
            text = RestartQuestionAnswer.message(questions.map { question in
                let sent = asked.first { $0["id"]?.stringValue == question.id }
                return (sent?["text"]?.stringValue ?? sent?["question"]?.stringValue, answers[question.id] ?? [])
            })
        default:
            return true
        }
        guard !text.isEmpty, let current = store.sessions.first(where: { $0.id == session.id }) else { return true }
        await send(HarnessUserInput(text: text), to: current)
        return true
    }

    /// Resumes the task's conversation and asks its provider to continue, only while the task is
    /// as the record left it: idle, nothing being edited or moved. A task whose queue holds messages
    /// sends the first of them instead, as the next turn. True once the provider was asked. A task in
    /// line because a lost connection cut its turn off continues that way instead.
    /// A task in line for its session jobs only starts its CLI again, as long as it still may; nothing
    /// is asked, so its place frees at once.
    @discardableResult
    private func continueAfterRestart(_ id: UUID) async -> Bool {
        if connectionResumes[id]?.isWaiting == true { return await continueAfterConnectionCut(id) }
        if sessionJobRelaunches.remove(id) != nil {
            if let session = store.sessions.first(where: { $0.id == id }), relaunchesForSessionJobs(session, now: Date()) {
                await resume(session)
            }
            return false
        }
        let unseenBefore = restartResumesToContinue[id]?.unseenContinuations ?? 0
        // Until it is asked, a quit still carries it over.
        defer { restartResumesToContinue.removeValue(forKey: id) }
        guard let session = store.sessions.first(where: { $0.id == id }),
              session.status != .running, session.status != .waitingForApproval,
              !switchingAccounts.contains(id), !sessionMutations.contains(id),
              composerDrafts.tasks.draft(for: id).editState == nil else { return false }
        if handlesBySessionID[id] == nil { await resume(session) }
        let inLine = restartResumeLine.starting.contains(id)
        if !followUps.queue(for: id).isEmpty {
            if inLine { restartResumesAwaitingWork.insert(id) }
            scheduleFollowUpDrain(for: id)
            return true
        }
        guard let current = matchingSession(session), current.status != .running,
              current.status != .waitingForApproval, current.status != .failed,
              let adapter = adaptersBySessionID[id] as? any HarnessInterruptedTurnContinuing,
              let handle = handlesBySessionID[id] else { return false }
        await markSubmissionStarted(for: id)
        // Work the provider shows from here on is this continuation's.
        if inLine { restartResumesAwaitingWork.insert(id) }
        do {
            let started = try await adapter.continueInterruptedTurn(in: handle, after: .quit)
            guard store.sessions.contains(where: { $0.id == id }) else { return false }
            if started {
                restartResumeNoticeSessionIDs.insert(id)
                if !isSessionVisible(id) { unseenRestartResumes[id] = unseenBefore + 1 }
                return true
            } else if store.sessions.first(where: { $0.id == id })?.status == .running {
                // The provider's record says the turn had ended; it stays as it ended.
                try? await store.updateSession(id: id, status: .ready)
            }
        } catch {
            guard store.sessions.contains(where: { $0.id == id }) else { return false }
            try? await store.updateSession(id: id, status: .failed)
            errorBySessionID[id] = error.localizedDescription
        }
        return false
    }

    /// Hands the adapter Yardlet instructions for this launch or session request — the global text, then
    /// the project's — or clears it when the setting or the project turned it off, there is no
    /// text, or the harness has no route of its own. A chat has no project and gets the global text.
    func configureYardletInstructions(on adapter: any HarnessAdapter, harness: HarnessKind,
                                      projectID: UUID?, for id: UUID) async {
        guard let configurable = adapter as? any HarnessYardletInstructionsConfiguring else { return }
        guard YardletInstructionsRoute.route(for: harness) != nil, let instructions = yardletInstructions else {
            await configurable.setYardletInstructions(nil, for: id)
            return
        }
        await configurable.setYardletInstructions(
            instructions.delivery(forProject: projectID, routing: routingEvaluation?.routingBlock), for: id)
    }

    /// Hands the adapter the Yardlet MCP server for this task's next session request, or clears it
    /// when the setting is off, this build cannot run it, or the harness has no per-session route.
    private func configureAgentTools(on adapter: any HarnessAdapter, for session: SessionRecord) async {
        guard let configurable = adapter as? any HarnessAgentToolConfiguring else { return }
        let routed = AgentToolInjectionRoute.route(for: session.harness) != nil
        let scope = routed && agentTools != nil ? connectorScope(for: session) : nil
        let server = routed
            ? agentTools?.agentToolServer(
                for: session.id,
                workspaceRoots: [session.workspaceURL] + session.additionalRootURLs,
                connectorScope: scope
            )
            : nil
        if connectorScopeBySessionID[session.id] != scope { connectorScopeBySessionID[session.id] = scope }
        await configurable.setAgentToolServer(server, for: session.id)
    }

    /// The connectors a task gets: its harness's own servers, with Yardlet's connected connectors
    /// standing in for those the harness can leave out of this launch.
    func connectorScope(for session: SessionRecord) -> ConnectorTaskScope {
        let scope = ConnectorCenter.scope(for: session)
        return connectorCenter?.withYardletStandIns(scope) ?? scope
    }

    /// A task keeps the runtime it was created with. When a desktop app that bundles that runtime
    /// moved it or removed its old version, the task continues with where the runtime now lives,
    /// or else with the harness's current runtime. The provider session and its home stay as they
    /// were, and a recorded runtime that still exists is never replaced.
    private func sessionWithAvailableRuntime(_ session: SessionRecord) async -> SessionRecord {
        guard !FileManager.default.isExecutableFile(atPath: session.runtimeExecutableURL.path(percentEncoded: false)),
              let replacement = RuntimeRelocation.successor(of: session.runtimeExecutableURL, for: session.harness)
                ?? runtimeSelections.selectedURL(for: session.harness),
              let updated = try? await store.updateRuntimeExecutable(id: session.id, to: replacement)
        else { return session }
        return updated
    }

    /// Restoration points tasks at moved runtimes up front, so task details and the next attach
    /// read the runtime the task will actually use.
    private func relocateMissingRuntimes() async {
        for session in store.sessions {
            _ = await sessionWithAvailableRuntime(session)
        }
    }

    private func attach(
        _ session: SessionRecord,
        resumesExistingSession: Bool
    ) async throws {
        guard store.sessions.contains(where: { $0.id == session.id && $0.connection == session.connection }) else {
            throw HarnessAdapterError.invalidProviderEvent(
                L10n.string("Task was deleted during harness attach")
            )
        }
        // The memory saver's close of the task's last runtime ends before another starts: it clears the task's state in
        // the adapter.
        if let closing = memorySaverClosings[session.id] { await closing.value }
        if handlesBySessionID[session.id] != nil { return }
        // Two processes must not continue one Claude conversation: one another app still holds
        // is followed read-only until it lets the conversation go.
        if resumesExistingSession, isHeldElsewhere(session) { throw ConversationHeldElsewhere() }
        // A task of a harness Yardlet no longer lists says so, not that its saved account is wrong.
        if HarnessCatalog.retired.contains(session.harness) { throw UnsupportedHarnessAdapter.unavailable(session.harness) }
        // A harness starts in the task's folder; one that is gone is the reason, not the launch's words.
        if let missing = taskFolderMissing(session) { throw missing }
        let session = await sessionWithAvailableRuntime(session)
        // Opening a task is the one moment a row written before worktree origins existed may
        // gain one, and only when its folder really is a worktree. Launch never rescans.
        try? await store.recordWorkspaceOriginIfMissing(id: session.id)
        try session.connection?.validate(for: session.harness)
        if let home = session.connection?.homePath {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ProviderConnectionError.invalidBinding
            }
        }
        let adapter = await registry.adapter(
            for: session.harness,
            executableURL: session.runtimeExecutableURL,
            environmentScope: session.environmentScope,
            connection: session.connection
        )
        do {
            _ = try await adapter.probeRuntime()
            guard store.sessions.contains(where: { $0.id == session.id && $0.connection == session.connection }) else {
                throw HarnessAdapterError.invalidProviderEvent(
                    L10n.string("Task was deleted during harness attach")
                )
            }
            // A task's extra project roots reach the provider through its own mechanism before
            // the thread starts or resumes. The cwd stays the task's one primary folder.
            if let rootsConfigurable = adapter as? any HarnessWorkspaceRootsConfiguring {
                await rootsConfigurable.setAdditionalWorkspaceRoots(
                    session.additionalRootURLs,
                    for: session.id
                )
            }
            if let source = session.inheritedContext?.nativeForkSource {
                guard session.harness == .claudeCode, let childID = session.providerSessionID,
                      let configurable = adapter as? any HarnessSessionForkConfiguring else {
                    throw HarnessAdapterError.capabilityUnavailable("Native session fork is unavailable")
                }
                let reader = claudeSessionReader(for: session)
                let pendingSource = try await Task.detached(priority: .utility) {
                    if try reader.readSession(sessionID: childID) != nil { return Optional<HarnessSessionForkSource>.none }
                    guard try reader.readSession(sessionID: source.providerSessionID,
                        throughMessageID: source.throughMessageID) != nil else {
                        throw HarnessAdapterError.capabilityUnavailable(L10n.string("The saved conversation cannot be forked."))
                    }
                    return Optional(source)
                }.value
                guard matchingSession(session) != nil else {
                    throw HarnessAdapterError.invalidProviderEvent("Task changed during native fork preparation")
                }
                try await configurable.setSessionForkSource(pendingSource, for: session.id)
            }
            if session.harness == .claudeCode, session.inheritedContext?.nativeForkSource == nil,
               let origin = session.inheritedContext?.nativeConversationOrigin,
               origin.connection == session.connection, origin.environmentScope == session.environmentScope,
               origin.workspaceURL == session.workspaceURL, let plannedID = session.providerSessionID,
               plannedID != origin.providerSessionID {
                guard let configurable = adapter as? any HarnessNewSessionConfiguring else {
                    throw HarnessAdapterError.capabilityUnavailable("New native session preparation is unavailable")
                }
                let reader = claudeSessionReader(for: session)
                let exists = try await Task.detached(priority: .utility) {
                    try reader.readSession(sessionID: plannedID) != nil
                }.value
                guard matchingSession(session) != nil else {
                    throw HarnessAdapterError.invalidProviderEvent("Task changed during native session preparation")
                }
                try await configurable.setNewSessionID(exists ? nil : plannedID, for: session.id)
            }
            // Options the provider reads as launch flags have to be in place before the process
            // starts; the in-session ones are restored after the handle exists.
            if let launchConfigurable = adapter as? any HarnessLaunchOptionConfiguring {
                await launchConfigurable.setLaunchOptions(session.providerOptions, for: session.id)
            }
            // The Yardlet MCP server goes in with the session request itself and nowhere else.
            await configureAgentTools(on: adapter, for: session)
            await configureYardletInstructions(on: adapter, harness: session.harness,
                                               projectID: projects.project(for: session)?.id, for: session.id)
            let handle: HarnessSessionHandle
            if resumesExistingSession, let providerSessionID = session.providerSessionID {
                handle = try await adapter.resumeSession(
                    providerSessionID: providerSessionID,
                    localSessionID: session.id,
                    workspaceURL: session.workspaceURL
                )
            } else {
                handle = try await adapter.createSession(
                    CreateHarnessSessionRequest(
                        localSessionID: session.id,
                        workspaceURL: session.workspaceURL,
                        initialPrompt: nil
                    )
                )
            }
            if let reporting = adapter as? any HarnessInstructionSourceReporting,
               let sources = await reporting.instructionSources(for: session.id) {
                instructionSourcesBySessionID[session.id] = sources
            }
            await rememberAdvertisedModels(from: adapter, for: session)
            // A family that negotiates image input has settled the answer by the time the
            // session exists. The composer reads it from the session's capability state, so it
            // is recorded here rather than waiting for the next status refresh.
            let negotiatedImageInput = await (adapter as? any HarnessImageInputReporting)?
                .acceptsImageInput(for: session.id) ?? nil
            var providerOptionRestoreErrors: [String] = []
            if let selection = CodexModelSelection.restored(from: session.providerOptions),
               let provider = adapter as? any CodexCapabilityProviding {
                // Restore one atomic model/effort pair before the next queued or manual turn.
                do {
                    _ = try await provider.selectModel(selection, for: handle)
                    codexModelRestoreErrors.removeValue(forKey: session.id)
                } catch {
                    codexModelRestoreErrors[session.id] = error.localizedDescription
                    providerOptionRestoreErrors.append(error.localizedDescription)
                }
            }
            if !session.providerOptions.isEmpty,
               let provider = adapter as? any ProviderCapabilityProviding {
                // The model goes first: the effort levels a model takes are read once it is chosen.
                let ordered = session.providerOptions.sorted {
                    ($0.key == ClaudeLaunchOption.model ? 0 : 1, $0.key) < ($1.key == ClaudeLaunchOption.model ? 0 : 1, $1.key)
                }
                for option in ordered {
                    do {
                        _ = try await provider.setProviderOption(
                            id: option.key,
                            value: option.value,
                            in: handle
                        )
                    } catch {
                        providerOptionRestoreErrors.append(error.localizedDescription)
                    }
                }
            }
            guard store.sessions.contains(where: { $0.id == session.id && $0.connection == session.connection }) else {
                await adapter.close(handle)
                throw HarnessAdapterError.invalidProviderEvent(
                    L10n.string("Task was deleted during harness attach")
                )
            }
            adaptersBySessionID[session.id] = adapter
            handlesBySessionID[session.id] = handle
            // What it streams from here is Yardlet's own, richer than Antigravity's log, so a later
            // detached read starts over and keeps it unless the log has more requests.
            antigravityHistoryShown.removeValue(forKey: session.id)
            // A new runtime holds none of the follow-ups an earlier one was sent.
            followUps.holdAllSent(in: session.id)
            if !providerOptionRestoreErrors.isEmpty {
                providerCapabilitiesBySessionID[session.id] = ProviderCapabilityState(
                    errors: providerOptionRestoreErrors
                )
            }
            if let negotiatedImageInput {
                var state = providerCapabilitiesBySessionID[session.id] ?? .empty
                state.acceptsImageInput = negotiatedImageInput
                providerCapabilitiesBySessionID[session.id] = state
            }
            errorBySessionID.removeValue(forKey: session.id)
            codexCapabilitiesBySessionID.removeValue(forKey: session.id)
            if session.harness == .codex, !providerOptionRestoreErrors.isEmpty {
                errorBySessionID[session.id] = providerOptionRestoreErrors.joined(separator: "\n")
            }
            // Connecting is not activity: the task keeps its place in the sidebar.
            try await store.updateSession(
                id: session.id,
                status: .ready,
                providerSessionID: handle.providerSessionID,
                setProviderSessionID: true,
                updatesRecency: false
            )
            guard store.sessions.contains(where: { $0.id == session.id && $0.connection == session.connection }) else {
                if handlesBySessionID[session.id] == handle {
                    handlesBySessionID.removeValue(forKey: session.id)
                    adaptersBySessionID.removeValue(forKey: session.id)
                    await adapter.close(handle)
                }
                throw HarnessAdapterError.invalidProviderEvent(
                    L10n.string("Task was deleted during harness attach")
                )
            }
            startEventCollection(adapter: adapter, handle: handle)
            let persistedCodexRequests = codexPendingRequestRepository.load(for: session.id)
            var answerableCodexRequestIDs = Set<String>()
            if let validator = adapter as? any CodexPendingServerRequestValidating {
                answerableCodexRequestIDs = await validator.answerablePendingServerRequestIDs(
                    persistedCodexRequests.filter(\.isPending),
                    for: handle
                )
                guard store.sessions.contains(where: { $0.id == session.id && $0.connection == session.connection }) else { return }
            }
            reconcileCodexRequestsAfterAttach(
                persistedCodexRequests,
                answerableRequestIDs: answerableCodexRequestIDs,
                for: session.id
            )
            if let provider = adapter as? any CodexPresentationProviding {
                startCodexPresentationCollection(provider: provider, handle: handle)
            }
        } catch {
            await registry.invalidate(
                harness: session.harness,
                executableURL: session.runtimeExecutableURL
            )
            throw error
        }
    }

    private func reconcileCodexRequestsAfterAttach(
        _ requests: [CodexPendingServerRequest],
        answerableRequestIDs: Set<String>,
        for sessionID: UUID
    ) {
        guard !requests.isEmpty else { return }
        let reconciled = requests.map { request -> CodexPendingServerRequest in
            guard request.isPending, !answerableRequestIDs.contains(request.id) else {
                return request
            }
            var state = request.state
            state.resolution = .rejected(
                code: CodexPendingServerRequest.expiredRuntimeCode,
                message: L10n.string("Approval expired because the provider runtime stopped.")
            )
            return CodexPendingServerRequest(state)
        }
        codexPendingRequestRepository.save(reconciled, for: sessionID)
    }

    /// The import sheet reads original Codex sessions on demand from the account's native home;
    /// imported rows keep that source scope.
    private func codexHistoryProvider(
        connection: ProviderConnection?
    ) async throws -> any CodexCapabilityProviding {
        guard let runtime = runtimeSelections.selectedURL(for: .codex) else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Codex history is unavailable for this runtime"))
        }
        let adapter = await registry.adapter(for: .codex, executableURL: runtime, environmentScope: .native,
            connection: connection)
        _ = try await adapter.probeRuntime()
        guard let provider = adapter as? any CodexCapabilityProviding else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("Codex history is unavailable for this runtime")
            )
        }
        return provider
    }

    private func startEventCollection(
        adapter: any HarnessAdapter,
        handle: HarnessSessionHandle
    ) {
        eventTasksBySessionID[handle.localSessionID]?.cancel()
        eventTasksBySessionID[handle.localSessionID] = Task { [weak self] in
            let stream = await adapter.events(for: handle)
            for await event in stream {
                guard !Task.isCancelled else { break }
                guard self?.handlesBySessionID[handle.localSessionID] == handle else { break }
                await self?.accept(event)
            }
            guard !Task.isCancelled else { return }
            await self?.eventStreamEnded(adapter: adapter, handle: handle)
        }
    }

    private func eventStreamEnded(adapter: any HarnessAdapter, handle: HarnessSessionHandle) async {
        let id = handle.localSessionID
        guard !Task.isCancelled, handlesBySessionID[id] == handle,
              let session = store.sessions.first(where: { $0.id == id }) else { return }
        // The presentation and lifecycle relays run independently. Read the final snapshot
        // before canceling the presentation relay so EOF cannot discard its last text deltas.
        let finalState: CodexTaskState?
        if let provider = adapter as? any CodexPresentationProviding {
            finalState = try? await provider.presentationState(for: handle)
        } else {
            finalState = nil
        }
        // Drop the dead adapter from the registry before a new attachment can reuse it.
        await registry.invalidate(harness: session.harness, executableURL: session.runtimeExecutableURL)
        guard !Task.isCancelled, handlesBySessionID[id] == handle,
              store.sessions.contains(where: { $0.id == id }) else { return }
        eventTasksBySessionID.removeValue(forKey: id)
        codexPresentationTasks.removeValue(forKey: id)?.cancel()
        followUpDrainTasks.removeValue(forKey: id)?.cancel()
        followUps.holdAllSent(in: id)
        let interrupted = session.status == .running || session.status == .waitingForApproval
        if var state = finalState ?? codexPresentationBySessionID[id] {
            mergePersistedCodexServerRequests(into: &state, for: id)
            mergePersistedCodexTimelineItems(into: &state, for: id)
            CodexTaskReducer().endRuntime(in: &state)
            codexPresentations[id] = state
            persistCodexServerRequests(state, for: id)
            persistCodexTimelineItems(state, for: id)
            persistCodexTranscriptSnapshot(state, for: id)
        }
        mutateTranscript(for: id, publishImmediately: true) { $0.endRuntime() }
        handlesBySessionID.removeValue(forKey: id)
        adaptersBySessionID.removeValue(forKey: id)
        if interrupted {
            let message = errorBySessionID[id] ?? L10n.format("Connection to %@ ended.", session.harness.displayName)
            if errorBySessionID[id] == nil { recordLocalError(message, for: id) }
            errorBySessionID[id] = message
            try? await store.updateSession(id: id, status: .failed,
                hasUnreadUpdate: !isSessionVisible(id) ? true : nil)
        }
        await adapter.close(handle)
    }

    private func startCodexPresentationCollection(
        provider: any CodexPresentationProviding,
        handle: HarnessSessionHandle
    ) {
        codexPresentationTasks[handle.localSessionID]?.cancel()
        codexPresentationTasks[handle.localSessionID] = Task { [weak self] in
            guard let stream = try? await provider.presentationStates(for: handle) else { return }
            for await state in stream {
                guard !Task.isCancelled else { break }
                let providerTitle = state.thread?.name
                await MainActor.run {
                    guard let self else { return }
                    guard self.store.sessions.contains(where: { $0.id == handle.localSessionID }) else {
                        return
                    }
                    var merged = state
                    if !self.sessionMutations.contains(handle.localSessionID) {
                        self.mergePersistedCodexServerRequests(into: &merged, for: handle.localSessionID)
                        self.mergePersistedCodexTimelineItems(into: &merged, for: handle.localSessionID)
                    }
                    let reducer = CodexTaskReducer()
                    reducer.reconcileResolvedServerRequestItems(in: &merged)
                    reducer.reconcileTerminalActivityItems(
                        in: &merged,
                        settledTurns: &self.codexSettledTurns[handle.localSessionID, default: CodexSettledTurns()]
                    )
                    let prior = self.codexPresentationBySessionID[handle.localSessionID]
                    // A state the runtime sends while a turn runs (or as it ends) is the turn's work;
                    // the states it sends on connecting are not.
                    if merged.activeTurnID != nil || prior?.activeTurnID != nil {
                        self.noteProviderActivity(handle.localSessionID, at: Date())
                    }
                    self.codexPresentations[handle.localSessionID] = merged
                    self.publicationCounts.codexStates += 1
                    if self.store.selectedSessionID != handle.localSessionID {
                        self.publicationCounts.backgroundCodexStates += 1
                    }
                    self.persistCodexServerRequests(merged, for: handle.localSessionID)
                    self.persistCodexTimelineItems(merged, for: handle.localSessionID, deferringStreamedContent: true)
                    let lifecycleChanged = prior?.activeTurnID != merged.activeTurnID
                        || prior?.thread?.turns.map(\.status) != merged.thread?.turns.map(\.status)
                    self.checkpointCodexTranscript(merged, for: handle.localSessionID, immediately: lifecycleChanged)
                }
                await self?.adoptProviderTitle(
                    providerTitle,
                    for: handle.localSessionID
                )
            }
        }
    }

    func accept(_ event: HarnessEventEnvelope) async {
        guard store.sessions.contains(where: { $0.id == event.localSessionID }) else { return }
        eventsBySessionID[event.localSessionID, default: []].appendKeepingLast(event, limit: 1_000)
        if Self.changesTranscript(event.payload) { noteProviderActivity(event.localSessionID, at: event.timestamp) }
        switch event.payload {
        case let .assistantDelta(delta):
            enqueueTranscriptDelta(.answer(delta), for: event.localSessionID)
            scheduleTranscriptPublication(for: event.localSessionID)
        case let .reasoningDelta(delta):
            enqueueTranscriptDelta(.reasoning(delta), for: event.localSessionID)
            scheduleTranscriptPublication(for: event.localSessionID)
        case _ where !Self.changesTranscript(event.payload):
            // Status, usage and capability reports leave the transcript as it is; republishing
            // it would only re-render and rewrite an unchanged conversation.
            break
        default:
            flushTranscriptDeltas(for: event.localSessionID)
            mutateTranscript(
                for: event.localSessionID,
                publishImmediately: true
            ) { builder in
                builder.apply(event.payload)
            }
        }

        if providerRetryBySessionID[event.localSessionID] != nil, Self.endsProviderRetry(event.payload) {
            providerRetryBySessionID.removeValue(forKey: event.localSessionID)
        }

        switch event.payload {
        case let .sessionStarted(handle):
            handlesBySessionID[event.localSessionID] = handle
            // The jobs a resume brought back, and those this CLI makes from now on.
            runtimeStartedAt[event.localSessionID] = event.timestamp
            readSessionJobs(of: event.localSessionID)
            clearBackgroundNotificationDeduplication(for: event.localSessionID)
            let startedBeforeSend = submissionStartedAt[event.localSessionID].map { event.timestamp < $0 } ?? false
            try? await store.updateSession(
                id: event.localSessionID,
                status: startedBeforeSend ? nil : .ready,
                providerSessionID: handle.providerSessionID,
                setProviderSessionID: true,
                updatesRecency: false
            )
        case let .sessionStatusChanged(status)
            where status == .ready && (submissionStartedAt[event.localSessionID].map { event.timestamp < $0 } ?? false):
            break
        case let .sessionStatusChanged(status):
            if status == .running || status == .waitingForApproval {
                // The next turn has begun; what was suggested after the last one no longer fits, and a
                // question a restart cut off is no longer what the task waits on.
                composerDrafts.tasks.existingDraft(for: event.localSessionID)?.nextMessageSuggestion = nil
                stopAskingRestartQuestion(event.localSessionID)
                // A turn someone else started takes over from one a lost connection cut off.
                if connectionResumes[event.localSessionID]?.isWaiting == true {
                    forgetConnectionResume(event.localSessionID)
                }
            } else {
                // The rail's browser preview goes with the turn, as the Codex app's at `turn/completed`.
                BrowserAgentUse.shared.endTurn(session: event.localSessionID)
                // A turn that made, ended or listed a session job, or ran one, changed what the CLI holds.
                if sessionJobsBySessionID[event.localSessionID] != nil || latestTurnTouchedSessionJobs(event.localSessionID) {
                    readSessionJobs(of: event.localSessionID)
                }
                // A continuation that ended without its connection being cut again is done.
                if let resume = connectionResumes[event.localSessionID], !resume.isWaiting {
                    forgetConnectionResume(event.localSessionID)
                }
            }
            let shouldMarkUnread = !isSessionVisible(event.localSessionID)
                && [.waitingForApproval, .completed, .failed].contains(status)
            // A runtime that reports ready when no turn was running (as it does on connecting)
            // has done nothing new; a turn's own states move the task.
            let previous = store.sessions.first(where: { $0.id == event.localSessionID })?.status
            try? await store.updateSession(
                id: event.localSessionID,
                status: status,
                hasUnreadUpdate: shouldMarkUnread ? true : nil,
                completionState: status == .running ? SessionCompletionState.none : nil,
                updatesRecency: status != .ready || previous == .running || previous == .waitingForApproval
            )
            if previous == .running || previous == .waitingForApproval, status != .running, status != .waitingForApproval {
                recordTurnForRoutingEvaluation(event.localSessionID, status: status, at: event.timestamp)
                // A dialog the agent's own input opened and left unanswered is now the person's to answer.
                refreshBrowserWaits()
            }
            if status == .waitingForApproval {
                announceApproval(in: event.localSessionID)
            } else {
                withdrawAnsweredApprovalNotifications(for: event.localSessionID)
            }
            if status == .running {
                clearBackgroundNotificationDeduplication(for: event.localSessionID)
                // A harness that stores its title writes it early in the first turn (Claude's
                // `ai-title`); a task still on its first words reads it then, not only when that
                // turn, which may run long, ends — on screen or not.
                if store.sessions.first(where: { $0.id == event.localSessionID })?.titleOrigin == .provisional {
                    scheduleSessionTitleResolution(for: event.localSessionID)
                }
            } else if shouldMarkUnread {
                await postBackgroundNotification(
                    for: event.localSessionID,
                    status: status
                )
            }
            if status == .ready {
                scheduleFollowUpDrain(for: event.localSessionID)
            }
            // A failure auto-fix held while the task worked may go now, and so may a change to
            // its tools that waited for the turn's end.
            if status != .running, status != .waitingForApproval {
                pullRequestDetails.taskBecameIdle(event.localSessionID)
                agentTools?.taskTurnEnded(event.localSessionID)
            }
            // A shell command's output waits for the turn to end, however it ended.
            if status != .running, status != .waitingForApproval {
                scheduleShellDelivery(for: event.localSessionID)
            }
        case let .followUpDelivery(delivery):
            acceptFollowUpDelivery(delivery, for: event.localSessionID)
        case let .providerStartedTurn(messageID):
            openProviderTurn(messageID, for: event.localSessionID)
        case let .turnCutOff(cut):
            acceptTurnCut(cut, for: event.localSessionID, at: event.timestamp)
        case let .nextMessageSuggestion(text):
            acceptNextMessageSuggestion(text, for: event.localSessionID)
        case .turnCompleted:
            // A turn that ended on its final error already failed and notified; it did not complete.
            let failed = store.sessions.first(where: { $0.id == event.localSessionID })?.status == .failed
            let shouldMarkUnread = !isSessionVisible(event.localSessionID)
            try? await store.updateSession(
                id: event.localSessionID,
                hasUnreadUpdate: shouldMarkUnread ? true : nil,
                completionState: failed ? nil : .completed
            )
            if shouldMarkUnread, !failed {
                await postBackgroundNotification(
                    for: event.localSessionID,
                    status: .completed
                )
            }
            scheduleSessionTitleResolution(for: event.localSessionID)
            if let session = store.sessions.first(where: { $0.id == event.localSessionID }),
               session.harness == .grokBuild {
                await refreshPersistedGrokSessionMetadata(for: session)
            }
            await reloadAttachedProviderCapabilities(for: event.localSessionID)
        case .providerCapabilitiesChanged:
            // The provider changed a session setting itself, such as the mode an approval
            // switched to, so the composer's selectors follow it now rather than at turn end.
            await reloadAttachedProviderCapabilities(for: event.localSessionID)
            await keepAnnouncedPermissionMode(for: event.localSessionID)
        case let .rateLimitUpdated(limit), let .usageLimitReached(limit):
            recordRateLimit(limit, for: event.localSessionID)
        case let .providerRetrying(retry):
            providerRetryBySessionID[event.localSessionID] = retry
        case let .usageUpdated(usage):
            providerUsageBySessionID[event.localSessionID] = mergedUsage(
                newest: usage,
                fallback: providerUsageBySessionID[event.localSessionID]
            )
            keepLiveContextUsage(usage, for: event.localSessionID)
        case let .error(message, _, _):
            errorBySessionID[event.localSessionID] = message
            let shouldMarkUnread = !isSessionVisible(event.localSessionID)
            try? await store.updateSession(
                id: event.localSessionID,
                status: .failed,
                hasUnreadUpdate: shouldMarkUnread ? true : nil
            )
            agentTools?.taskTurnEnded(event.localSessionID)
            if shouldMarkUnread {
                await postBackgroundNotification(
                    for: event.localSessionID,
                    status: .failed,
                    detail: message
                )
            }
        default:
            break
        }
    }

    /// A retry stays on the status line until the provider moves on: output, a tool call, the
    /// turn's end, or a failure. Reports about limits and usage say nothing about the retry.
    private static func endsProviderRetry(_ payload: HarnessEventPayload) -> Bool {
        switch payload {
        case .providerRetrying, .rateLimitUpdated, .usageUpdated, .providerCapabilitiesChanged,
             .sessionStatusChanged(.running), .nextMessageSuggestion:
            false
        default:
            true
        }
    }

    /// A Claude session's plan-limit report: a warning shows above the task's composer until the
    /// provider reports otherwise, and every report updates the account the task runs under.
    private func recordRateLimit(_ limit: HarnessRateLimit, for sessionID: UUID) {
        guard let session = store.sessions.first(where: { $0.id == sessionID }),
              session.harness == .claudeCode else { return }
        if limit.status == .warning, !limit.isUsingOverage {
            rateLimitWarningBySessionID[sessionID] = limit
        } else if rateLimitWarningBySessionID[sessionID] != nil {
            rateLimitWarningBySessionID.removeValue(forKey: sessionID)
        }
        connections.recordRateLimit(limit, for: session.connection)
    }

    /// A mode the CLI announced on its own (one an approval switched to, or the one a plan's
    /// approval left) is the task's mode now, so it is kept as a mode chosen in the selector is,
    /// and the task resumes in it after a restart. Only the selector's own modes are kept.
    private func keepAnnouncedPermissionMode(for sessionID: UUID) async {
        guard let session = store.sessions.first(where: { $0.id == sessionID }),
              session.harness == .claudeCode,
              let mode = providerCapabilitiesBySessionID[sessionID]?.selectors
                .first(where: { $0.id == ClaudeLaunchOption.permissionMode })?.currentValue,
              ClaudePermissionMode.selectable.contains(mode),
              mode != session.providerOptions[ClaudeLaunchOption.permissionMode] ?? ClaudePermissionMode.manual
        else { return }
        try? await store.updateProviderOption(id: sessionID, optionID: ClaudeLaunchOption.permissionMode, value: mode)
    }

    /// Rereads live provider controls from a runtime that is already attached. A detached task
    /// is never woken for this.
    private func reloadAttachedProviderCapabilities(for sessionID: UUID) async {
        guard let session = store.sessions.first(where: { $0.id == sessionID }),
              session.harness != .codex,
              isAttached(session.id),
              supportsLiveProviderControls(session.harness) else { return }
        await loadProviderCapabilities(for: session)
    }

    private func clearBackgroundNotificationDeduplication(for sessionID: UUID) {
        let prefix = "\(sessionID.uuidString):"
        notifiedBackgroundStates = notifiedBackgroundStates.filter { !$0.hasPrefix(prefix) }
        dockAttention?.forgetApprovals(in: sessionID)
    }

    private func postBackgroundNotification(
        for sessionID: UUID,
        status: SessionStatus,
        detail: String? = nil
    ) async {
        guard let session = store.sessions.first(where: { $0.id == sessionID }),
              !isSessionVisible(sessionID),
              status != .completed || announcesCompletion(of: session) else { return }
        // An approval names the request it asks about, so each new request in a wait is announced.
        let requestID = status == .waitingForApproval ? newestPendingApproval(in: session)?.id : nil
        let key = "\(sessionID.uuidString):\(status.rawValue)" + (requestID.map { ":\($0)" } ?? "")
        guard notifiedBackgroundStates.insert(key).inserted else { return }

        let title: String
        let body: String
        switch status {
        case .waitingForApproval:
            title = L10n.string("Task needs your attention")
            body = L10n.format("%@ is waiting for approval.", session.title)
        case .completed:
            title = L10n.string("Task completed")
            body = L10n.format("%@ finished.", session.title)
        case .failed:
            title = L10n.string("Task failed")
            body = detail.map { L10n.format("%@ failed: %@", session.title, $0) }
                ?? L10n.format("%@ failed.", session.title)
        case .ready, .running:
            return
        }
        guard (await systemNotificationCenter.authorization()).isDeliverable else { return }
        // Authorization is an async boundary. The task may be deleted (or selected) while the
        // system prompt/state is being read; never deliver a notification for a task that no
        // longer owns this lifecycle continuation.
        guard let current = store.sessions.first(where: { $0.id == sessionID }),
              !isSessionVisible(sessionID) else { return }
        let identifier = "yardlet-session-\(sessionID.uuidString)-\(status.rawValue)"
            + (requestID.map { "-\($0)" } ?? "")
        var offersAllowOnce = false
        if status == .waitingForApproval {
            // An approval answered while authorization was read is not announced. Whether it
            // offers "Allow once" is read now, when a Codex request's own state has arrived.
            guard current.status == .waitingForApproval else { return }
            offersAllowOnce = requestID.flatMap { pendingApproval($0, in: current)?.allowOnce } != nil
            approvalNotificationIDs[sessionID, default: [:]][requestID ?? ""] = identifier
        }
        await systemNotificationCenter.post(SystemNotification(
            title: title,
            body: body,
            identifier: identifier,
            target: SystemNotificationTarget(sessionID: sessionID, requestID: requestID),
            offersAllowOnce: offersAllowOnce
        ))
    }

    private func mutateTranscript(
        for sessionID: UUID,
        publishImmediately: Bool,
        _ mutation: (inout TranscriptBuilder) -> Void
    ) {
        // A local/user mutation can arrive inside the provider-delta publication window. Apply
        // the queued assistant text first so transcript ordering remains causal.
        flushTranscriptDeltas(for: sessionID)
        var builder = transcriptBuilders.removeValue(forKey: sessionID) ?? TranscriptBuilder()
        mutation(&builder)
        transcriptBuilders[sessionID] = builder
        if publishImmediately {
            publishTranscript(for: sessionID)
        } else {
            scheduleTranscriptPublication(for: sessionID)
        }
    }

    /// A streamed answer or thinking fragment waiting for the next publication.
    private enum PendingTranscriptDelta {
        case answer(String)
        case reasoning(String)
    }

    /// Whether `TranscriptBuilder.apply` can change the transcript for this payload.
    private func noteProviderActivity(_ sessionID: UUID, at date: Date) {
        // A continuation after a restart has started: the next in line may begin.
        if restartResumesAwaitingWork.contains(sessionID) { restartResumeStarted(sessionID) }
        if let known = providerActivityBySessionID[sessionID], known >= date { return }
        providerActivityBySessionID[sessionID] = date
    }

    private static func changesTranscript(_ payload: HarnessEventPayload) -> Bool {
        switch payload {
        case .sessionStarted, .sessionStatusChanged, .usageUpdated, .providerCapabilitiesChanged,
             .rateLimitUpdated, .providerRetrying, .followUpDelivery, .nextMessageSuggestion, .providerStartedTurn,
             .turnCutOff:
            false
        default:
            true
        }
    }

    /// Provider streams commonly emit many tiny answer and thinking fragments. Keep those
    /// fragments separate until the publication boundary (`transcriptPublicationInterval`), then
    /// join each run of one kind once, in order. This avoids repeatedly rebuilding the complete
    /// message for every fragment while preserving the same observable transcript cadence.
    private func enqueueTranscriptDelta(_ delta: PendingTranscriptDelta, for sessionID: UUID) {
        switch delta {
        case let .answer(text), let .reasoning(text):
            guard !text.isEmpty else { return }
        }
        pendingTranscriptDeltas[sessionID, default: []].append(delta)
    }

    private func flushTranscriptDeltas(for sessionID: UUID) {
        guard let chunks = pendingTranscriptDeltas.removeValue(forKey: sessionID),
              !chunks.isEmpty else { return }
        var builder = transcriptBuilders.removeValue(forKey: sessionID) ?? TranscriptBuilder()
        var run: [String] = []
        var runIsReasoning = false
        func applyRun() {
            guard !run.isEmpty else { return }
            let text = run.joined()
            builder.apply(runIsReasoning ? .reasoningDelta(text) : .assistantDelta(text))
            run.removeAll(keepingCapacity: true)
        }
        for chunk in chunks {
            switch chunk {
            case let .answer(text):
                if runIsReasoning { applyRun() }
                runIsReasoning = false
                run.append(text)
            case let .reasoning(text):
                if !runIsReasoning { applyRun() }
                runIsReasoning = true
                run.append(text)
            }
        }
        applyRun()
        transcriptBuilders[sessionID] = builder
    }

    /// How often a streaming task's transcript is published while fragments keep arriving. Each
    /// publication lays the shown conversation's window out again in its display cycle, which the
    /// installed app measured at about 17 ms a time (2026-10-22, two windows, several tasks
    /// streaming): at 40 ms the window spent half its time on that alone. Ten times a second reads
    /// as live text and leaves the main thread to the person's typing, clicks and scrolling.
    static let transcriptPublicationInterval: Duration = .milliseconds(100)

    private func scheduleTranscriptPublication(for sessionID: UUID) {
        guard transcriptPublicationTasks[sessionID] == nil else { return }
        transcriptPublicationTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: Self.transcriptPublicationInterval)
            guard !Task.isCancelled else { return }
            self?.publishTranscript(for: sessionID)
        }
    }

    private func publishTranscript(for sessionID: UUID) {
        transcriptPublicationTasks.removeValue(forKey: sessionID)?.cancel()
        flushTranscriptDeltas(for: sessionID)
        let entries = transcriptBuilders[sessionID]?.entries ?? []
        let hasLiveCodex = codexPresentationBySessionID[sessionID]?.activeTurnID != nil
        if !hasLiveCodex {
            transcripts[sessionID] = entries
            publicationCounts.transcripts += 1
            if store.selectedSessionID != sessionID { publicationCounts.backgroundTranscripts += 1 }
        }
        guard !entries.isEmpty else { return }
        // Once typed Codex history exists, its projection is the complete bounded window. The
        // common event stream may contain only the newest live turn and must not replace it.
        if store.sessions.first(where: { $0.id == sessionID })?.harness == .codex,
           codexPresentationBySessionID[sessionID]?.thread != nil {
            return
        }
        // Streaming publishes many times a second; the reading snapshot keeps the newest one.
        transcriptSnapshots.scheduleSave(entries, for: sessionID)
    }

    private func loadPersistedTranscripts() {
        for session in store.sessions {
            var entries = transcriptSnapshots.load(for: session.id)
            if session.harness == .grokBuild,
               let providerSessionID = session.providerSessionID,
               let repaired = GrokTranscriptSnapshotProjection.repairedEntries(
                   providerSessionID: providerSessionID,
                   existing: entries
               ) {
                transcriptSnapshots.saveNow(repaired, for: session.id)
                entries = repaired
            }
            guard !entries.isEmpty else { continue }
            let builder = TranscriptBuilder(entries: entries)
            transcriptBuilders[session.id] = builder
            transcripts[session.id] = builder.entries
        }
    }

    private func loadPersistedGrokSessionMetadata() async {
        for session in store.sessions where session.harness == .grokBuild {
            await refreshPersistedGrokSessionMetadata(for: session)
        }
    }

    private func refreshPersistedGrokSessionMetadata(for session: SessionRecord) async {
        guard session.harness == .grokBuild,
              let providerSessionID = session.providerSessionID else { return }
        let snapshot = await Task.detached(priority: .utility) {
            GrokSessionMetadataProjection.snapshot(providerSessionID: providerSessionID)
        }.value
        guard store.sessions.contains(where: { $0.id == session.id }),
              let snapshot else { return }
        if let usage = snapshot.usage {
            providerUsageBySessionID[session.id] = mergedUsage(
                newest: usage,
                fallback: providerUsageBySessionID[session.id]
            )
        }
        if !isAttached(session.id),
           let state = snapshot.detachedCapabilityState {
            providerCapabilitiesBySessionID[session.id] = state
        }
    }

    private func mergedUsage(
        newest: HarnessProtocolUsage,
        fallback: HarnessProtocolUsage?
    ) -> HarnessProtocolUsage {
        HarnessProtocolUsage(
            inputTokens: newest.inputTokens ?? fallback?.inputTokens,
            cachedInputTokens: newest.cachedInputTokens ?? fallback?.cachedInputTokens,
            outputTokens: newest.outputTokens ?? fallback?.outputTokens,
            reasoningTokens: newest.reasoningTokens ?? fallback?.reasoningTokens,
            totalCostUSD: newest.totalCostUSD ?? fallback?.totalCostUSD,
            contextWindowTokens: newest.contextWindowTokens ?? fallback?.contextWindowTokens,
            contextUsedTokens: newest.contextUsedTokens ?? fallback?.contextUsedTokens,
            extensionValues: newest.extensionValues.isEmpty
                ? fallback?.extensionValues ?? [:]
                : newest.extensionValues,
            contextBreakdown: newest.contextBreakdown ?? fallback?.contextBreakdown,
            contextWindowModel: newest.contextWindowModel ?? fallback?.contextWindowModel
        )
    }

    // MARK: Context usage after a restart
    //
    // The composer's ring and the session rail's Context card show what a task's harness reports
    // while it is attached. After a restart they show what the index kept for the task
    // (`TaskContextUsageSnapshot`), then, when the task is opened, what the provider's own history
    // says: Claude Code's transcript (its last response's usage) and Codex's rollout (its latest
    // `token_count`). A live report replaces both, through the merge above. No read starts a
    // process or a turn; the history is read off the main thread by the reads opening already does.

    /// The index's last values for the restored tasks that are still on the same conversation.
    private func loadSavedContextUsage() async {
        guard let saved = try? await store.loadContextUsage(), !saved.isEmpty else { return }
        for session in store.sessions {
            guard let snapshot = saved[session.id], snapshot.providerSessionID == session.providerSessionID else {
                continue
            }
            savedContextUsage[session.id] = snapshot
            guard !liveContextUsageSessionIDs.contains(session.id) else { continue }
            if session.harness == .codex {
                if let codex = snapshot.codex { restoredCodexTokenUsageBySessionID[session.id] = codex }
            } else if let usage = snapshot.provider, providerUsageBySessionID[session.id] == nil {
                providerUsageBySessionID[session.id] = usage
            }
        }
    }

    /// A harness's report: kept for after a restart, and, from Claude Code, the window its model has.
    private func keepLiveContextUsage(_ usage: HarnessProtocolUsage, for id: UUID) {
        liveContextUsageSessionIDs.insert(id)
        if let model = usage.contextWindowModel, let window = usage.contextWindowTokens,
           store.sessions.first(where: { $0.id == id })?.harness == .claudeCode {
            modelCatalogs.recordClaudeContextWindow(window, model: model)
        }
        saveContextUsage(for: id)
    }

    /// A Codex thread's newest turn usage, kept when it changed. The table calls this on every change
    /// to the task's state, streaming included, so it compares before it saves.
    private func keepCodexTokenUsage(for id: UUID) {
        guard let usage = codexPresentations[id]?.thread?.turns.last(where: { $0.tokenUsage != nil })?.tokenUsage,
              savedContextUsage[id]?.codex != usage else { return }
        liveContextUsageSessionIDs.insert(id)
        saveContextUsage(for: id)
    }

    /// What the Codex task shows: its thread's newest turn usage, else what was read back.
    private func shownCodexTokenUsage(for id: UUID) -> CodexThreadTokenUsage? {
        codexPresentations[id]?.thread?.turns.last(where: { $0.tokenUsage != nil })?.tokenUsage
            ?? restoredCodexTokenUsageBySessionID[id]
    }

    /// Keeps what the task's context usage shows now in the index, when it changed. Saves for one
    /// task run in order.
    private func saveContextUsage(for id: UUID) {
        guard let session = store.sessions.first(where: { $0.id == id }) else { return }
        let isCodex = session.harness == .codex
        let snapshot = TaskContextUsageSnapshot(
            providerSessionID: session.providerSessionID, recordedAt: Date(),
            provider: isCodex ? nil : providerUsageBySessionID[id],
            codex: isCodex ? shownCodexTokenUsage(for: id) : nil)
        guard !snapshot.isEmpty else { return }
        if let saved = savedContextUsage[id], saved.providerSessionID == snapshot.providerSessionID,
           saved.provider == snapshot.provider, saved.codex == snapshot.codex { return }
        savedContextUsage[id] = snapshot
        let previous = contextUsageSaves[id]
        contextUsageSaves[id] = Task { [store] in
            await previous?.value
            try? await store.saveContextUsage(snapshot, for: id)
        }
    }

    /// A detached Claude task's saved conversation, read as it opened: its last response's usage
    /// shows unless the task reported this run, or what the index kept was taken after that response
    /// (Claude Code's own `/context` count, which also has the breakdown). The window is the one
    /// Claude Code last gave the response's model here, else the one the task last showed; without
    /// either the ring stays as it was.
    private func adoptClaudeHistoryContextUsage(_ read: ClaudeTranscriptContextUsage, for source: SessionRecord) {
        guard let session = matchingSession(source), handlesBySessionID[session.id] == nil,
              !liveContextUsageSessionIDs.contains(session.id) else { return }
        if let saved = savedContextUsage[session.id], saved.providerSessionID == session.providerSessionID,
           saved.provider?.contextUsedTokens != nil,
           read.timestamp.map({ $0 <= saved.recordedAt }) ?? true { return }
        let chosen = ClaudeLaunchOption.launchModel(session.providerOptions[ClaudeLaunchOption.model])
            ?? modelCatalogs.defaults(for: .claudeCode, connection: session.connection,
                                      workspaceURL: session.workspaceURL)?.model
        let current = providerUsageBySessionID[session.id]
        guard let window = read.model.flatMap({
                  modelCatalogs.claudeContextWindow(forResponseModel: $0, chosenModel: chosen)
              }) ?? current?.contextWindowTokens, window > 0,
              current?.contextUsedTokens != read.usedTokens || current?.contextWindowTokens != window else { return }
        providerUsageBySessionID[session.id] = HarnessProtocolUsage(
            inputTokens: nil, cachedInputTokens: nil, outputTokens: nil, reasoningTokens: nil, totalCostUSD: nil,
            contextWindowTokens: window, contextUsedTokens: read.usedTokens, extensionValues: [:],
            contextWindowModel: read.model)
        saveContextUsage(for: session.id)
    }

    /// A detached Codex task's rollout (the file its `thread/read` named), read for its latest
    /// `token_count`: what Codex's App Server sends again when the thread is resumed, here without
    /// resuming it. A task that attached or reported this run keeps its own.
    private func readCodexRolloutTokenUsage(for source: SessionRecord) async {
        guard let session = matchingSession(source), session.harness == .codex,
              handlesBySessionID[session.id] == nil, !liveContextUsageSessionIDs.contains(session.id),
              let path = codexRolloutPathBySessionID[session.id] else { return }
        let file = URL(filePath: path)
        let usage = await Task.detached(priority: .utility) { CodexRolloutTokenUsage.latest(in: file) }.value
        guard let usage, let current = matchingSession(session),
              current.providerSessionID == session.providerSessionID, handlesBySessionID[session.id] == nil,
              !liveContextUsageSessionIDs.contains(session.id),
              restoredCodexTokenUsageBySessionID[session.id] != usage else { return }
        restoredCodexTokenUsageBySessionID[session.id] = usage
        saveContextUsage(for: session.id)
    }

    // MARK: Provider titles
    //
    // A task's provider title arrives from its `ProviderTitleSource`: pushed by the attached
    // session (Codex `thread.name`, adopted from each presentation state) or pulled from what the
    // harness stored (`sessionTitleResolver`). Both take one schedule — index restore, task
    // selection, app activation, and each turn's end, where the first request waits for it before
    // the local fallback — and one path into the task, `adoptProviderTitle`.

    /// Refreshes titles already owned by a provider as well as eligible old first-prompt labels.
    /// Manual and arbitrary legacy names remain local because their provenance is not known.
    private func reconcilePersistedProviderTitles() async {
        for session in store.sessions {
            guard !Task.isCancelled else { return }
            await refreshProviderTitle(for: session)
        }
    }

    /// Brings a task's provider title up to date at one of the scheduled moments. A pulled title
    /// is read now; a pushed one needs nothing here, because the attached session announces it
    /// by itself and a detached one is not woken to ask.
    private func refreshProviderTitle(for session: SessionRecord) async {
        switch ProviderTitleSource(harness: session.harness) {
        case .push:
            return
        case .pull:
            await pullProviderTitle(for: session)
        }
    }

    /// Reads, off the main actor, the title the harness stored, and adopts it only while the task
    /// still has the provider session, scope, and title the read started from and no newer read
    /// has begun.
    private func pullProviderTitle(for session: SessionRecord) async {
        guard !isVisualFixture,
              let snapshot = store.sessions.first(where: { $0.id == session.id }),
              snapshot.providerSessionID != nil, snapshot.titleOrigin != .manual else { return }
        if snapshot.titleOrigin == .legacy {
            guard let firstUserMessage = firstUserMessage(for: snapshot.id),
                  snapshot.title == SessionTitleProjection.provisionalTitle(from: firstUserMessage) else { return }
        }
        let refreshID = UUID()
        sessionTitleRefreshes[snapshot.id] = refreshID
        defer {
            if sessionTitleRefreshes[snapshot.id] == refreshID {
                sessionTitleRefreshes.removeValue(forKey: snapshot.id)
            }
        }
        let resolver = sessionTitleResolver
        let providerTitle = await Task.detached(priority: .utility) { resolver(snapshot) }.value
        guard !Task.isCancelled, sessionTitleRefreshes[snapshot.id] == refreshID,
              let current = store.sessions.first(where: { $0.id == snapshot.id }),
              current.providerSessionID == snapshot.providerSessionID,
              current.environmentScope == snapshot.environmentScope,
              current.titleOrigin == snapshot.titleOrigin,
              current.title == snapshot.title else { return }
        await adoptProviderTitle(providerTitle, for: snapshot.id)
    }

    private func scheduleSessionTitleResolution(for sessionID: UUID) {
        guard sessionTitleResolutionTasks[sessionID] == nil,
              let origin = store.sessions.first(where: { $0.id == sessionID })?.titleOrigin,
              origin == .provisional || origin == .automatic else {
            return
        }
        sessionTitleResolutionTasks[sessionID] = Task { [weak self] in
            await self?.resolveSessionTitle(for: sessionID)
        }
    }

    /// The first request waits for the provider's title, about ten seconds
    /// (`sessionTitleRetryCount` × `sessionTitleRetryInterval`), and settles on the local fallback
    /// only when none arrives in time. A pulled title is read at each attempt; a pushed one ends
    /// the wait when the session announces it. The fallback stands in until then: every later
    /// turn reads the provider title again, so one that arrives late still replaces it.
    private func resolveSessionTitle(for sessionID: UUID) async {
        defer { sessionTitleResolutionTasks.removeValue(forKey: sessionID) }
        if let snapshot = store.sessions.first(where: { $0.id == sessionID }),
           snapshot.titleOrigin == .automatic {
            await refreshProviderTitle(for: snapshot)
            return
        }
        for attempt in 0...sessionTitleRetryCount {
            guard !Task.isCancelled,
                  let snapshot = store.sessions.first(where: { $0.id == sessionID }),
                  snapshot.titleOrigin == .provisional else { return }
            await refreshProviderTitle(for: snapshot)
            guard store.sessions.first(where: { $0.id == sessionID })?.titleOrigin == .provisional else { return }
            if attempt < sessionTitleRetryCount {
                do {
                    try await Task.sleep(for: sessionTitleRetryInterval)
                } catch {
                    return
                }
            }
        }

        guard !Task.isCancelled,
              let current = store.sessions.first(where: { $0.id == sessionID }),
              current.titleOrigin == .provisional,
              let firstUserMessage = firstUserMessage(for: sessionID) else { return }
        let fallback = SessionTitleProjection.fallbackTitle(
            firstUserMessage: firstUserMessage,
            workspaceURL: current.workspaceURL
        )
        try? await store.renameSession(
            id: sessionID,
            title: fallback,
            titleOrigin: .automatic
        )
    }

    /// The one way a provider title, pushed or pulled, becomes the task's title. A manual name
    /// always wins; a legacy name gives way only while it is exactly the first request; a
    /// provisional, automatic, or earlier provider title is replaced. Recency is unchanged.
    private func adoptProviderTitle(_ candidate: String?, for sessionID: UUID) async {
        guard let title = SessionTitleProjection.normalizedProviderTitle(candidate),
              let current = store.sessions.first(where: { $0.id == sessionID }) else { return }
        switch current.titleOrigin {
        case .manual:
            return
        case .legacy:
            guard let firstUserMessage = firstUserMessage(for: sessionID),
                  current.title == SessionTitleProjection.provisionalTitle(from: firstUserMessage) else {
                return
            }
        case .provisional, .automatic, .provider:
            break
        }
        try? await store.renameSession(
            id: sessionID,
            title: title,
            titleOrigin: .provider,
            updatesRecency: false
        )
    }

    private func firstUserMessage(for sessionID: UUID) -> String? {
        let entries = transcriptBuilders[sessionID]?.entries ?? transcriptBySessionID[sessionID] ?? []
        for entry in entries {
            // A schedule's prompt is not what the person asked the task for. What another task sent
            // (`create_task`'s first message) asks its body.
            if case let .user(text, _) = entry.content, entry.origin == nil,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return TaskMessage.parse(text)?.body ?? ClaudeBashMessage.summary(of: text) ?? text
            }
        }
        return nil
    }

    /// How often a streaming Codex turn's reading snapshot is written while the turn runs. The turn's
    /// start and end are written at once.
    static let codexTranscriptCheckpointInterval: Duration = .seconds(1)

    private func checkpointCodexTranscript(_ state: CodexTaskState, for id: UUID, immediately: Bool) {
        if immediately || state.activeTurnID == nil {
            // Written in the background too: the snapshot queue keeps the order, and the main
            // thread does not wait while a long conversation is encoded and written.
            codexSnapshotCheckpointTasks.removeValue(forKey: id)?.cancel()
            persistCodexTranscriptSnapshot(state, for: id, inBackground: true)
        } else if codexSnapshotCheckpointTasks[id] == nil {
            codexSnapshotCheckpointTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: Self.codexTranscriptCheckpointInterval)
                guard !Task.isCancelled, let self else { return }
                self.codexSnapshotCheckpointTasks.removeValue(forKey: id)
                if let latest = self.codexPresentationBySessionID[id] {
                    self.persistCodexTranscriptSnapshot(latest, for: id, inBackground: true)
                }
            }
        }
    }

    /// `inBackground` is for the streaming checkpoint: it returns before the snapshot is written.
    private func persistCodexTranscriptSnapshot(_ state: CodexTaskState, for sessionID: UUID, inBackground: Bool = false) {
        // An absent thread is a transient presentation bootstrap and must not erase a previously
        // hydrated detached snapshot. A present empty thread is authoritative and clears it.
        guard state.thread != nil else { return }
        let entries = CodexTranscriptSnapshotProjection.entries(from: state)
        if entries.isEmpty {
            if inBackground { transcriptSnapshots.removeSoon(for: sessionID) } else { transcriptSnapshots.remove(for: sessionID) }
        } else if inBackground {
            transcriptSnapshots.saveSoon(entries, for: sessionID)
        } else {
            transcriptSnapshots.saveNow(entries, for: sessionID)
        }
    }

    private func loadPersistedFollowUps() {
        // A sent message went unread with the CLI that held it when the last launch ended; the
        // store holds it in Yardlet again.
        followUps.load(for: store.sessions.filter { FollowUpPolicy(harness: $0.harness) != nil }.map(\.id))
        // Bash-mode output the last launch did not send goes once the task has attached and is
        // idle, after its queued messages, as it would have.
        pendingShellDeliveries = Dictionary(uniqueKeysWithValues: store.sessions.compactMap { session in
            guard session.harness == .claudeCode else { return nil }
            let deliveries = followUps.savedShellDeliveries(for: session.id)
            return deliveries.isEmpty ? nil : (session.id, deliveries)
        })
    }

    private func mergePersistedCodexServerRequests(
        into state: inout CodexTaskState,
        for sessionID: UUID
    ) {
        let existing = Set(state.serverRequestsByID.keys)
        for request in codexPendingRequestRepository.load(for: sessionID) where !existing.contains(request.id) {
            state.serverRequestsByID[request.id] = request.state
        }
    }

    private func persistCodexServerRequests(
        _ state: CodexTaskState,
        for sessionID: UUID
    ) {
        let requests = state.serverRequestsByID.values
            .map(CodexPendingServerRequest.init).sorted { $0.id < $1.id }
        guard savedCodexRequests[sessionID] != requests else { return }
        savedCodexRequests[sessionID] = requests
        if requests.isEmpty {
            codexPendingRequestRepository.remove(for: sessionID)
        } else {
            codexPendingRequestRepository.save(requests, for: sessionID)
        }
    }

    private func mergePersistedCodexTimelineItems(
        into state: inout CodexTaskState,
        for sessionID: UUID
    ) {
        let entries = codexPersistedTimelines[sessionID, default: CodexPersistedTimeline()].supplementEntries(
            for: state,
            saved: codexTimelineItemRepository.load(for: sessionID)
        )
        guard !entries.isEmpty else { return }
        // App-local cards supplement provider-loaded turns; they must never manufacture a
        // placeholder turn outside the bounded authoritative resume window.
        CodexTaskReducer().mergeItemPage(
            CodexItemPage(entries: entries, nextCursor: nil, backwardsCursor: nil),
            into: &state
        )
    }

    /// `deferringStreamedContent` is for streamed states: when only the content of cards already
    /// saved changed, as a running command's output does, the newest content is saved a second
    /// later instead of on every state. New, removed or settled cards are saved at once.
    private func persistCodexTimelineItems(
        _ state: CodexTaskState,
        for sessionID: UUID,
        deferringStreamedContent: Bool = false
    ) {
        let bounded = codexPersistedTimelines[sessionID, default: CodexPersistedTimeline()].items(from: state)
        guard savedCodexItems[sessionID] != bounded else {
            codexItemSaveTasks.removeValue(forKey: sessionID)?.cancel()
            return
        }
        if deferringStreamedContent, let saved = savedCodexItems[sessionID],
           saved.count == bounded.count,
           zip(saved, bounded).allSatisfy({ $0.turnID == $1.turnID && $0.id == $1.id
               && $0.lifecycleRawValue == $1.lifecycleRawValue }) {
            guard codexItemSaveTasks[sessionID] == nil else { return }
            codexItemSaveTasks[sessionID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.codexItemSaveTasks.removeValue(forKey: sessionID)
                if let latest = self.codexPresentationBySessionID[sessionID] {
                    self.persistCodexTimelineItems(latest, for: sessionID)
                }
            }
            return
        }
        codexItemSaveTasks.removeValue(forKey: sessionID)?.cancel()
        savedCodexItems[sessionID] = bounded
        if bounded.isEmpty {
            codexTimelineItemRepository.remove(for: sessionID)
        } else {
            codexTimelineItemRepository.save(bounded, for: sessionID)
        }
    }

    private func loadPersistedCodexHistorySelections() {
        codexHistorySelectionBySessionID = Dictionary(
            uniqueKeysWithValues: store.sessions.compactMap { session in
                guard session.harness == .codex,
                      let selection = codexHistorySelectionRepository.load(for: session.id) else {
                    return nil
                }
                return (session.id, selection)
            }
        )
    }

    private func recordLocalError(_ message: String, for sessionID: UUID) {
        #if DEBUG
        if CommandLine.arguments.contains("--ui-fixture=lifecycle") {
            NSLog("Lifecycle fixture error: %@", message)
        }
        #endif
        mutateTranscript(for: sessionID, publishImmediately: true) { builder in
            builder.apply(.error(message: message, recoverable: true))
        }
    }

    private func codexProvider(
        for session: SessionRecord
    ) async throws -> (any HarnessAdapter, any CodexCapabilityProviding, HarnessSessionHandle) {
        guard session.harness == .codex else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("This capability is available only for Codex tasks")
            )
        }
        if handlesBySessionID[session.id] == nil {
            try await attach(session, resumesExistingSession: session.providerSessionID != nil)
        }
        guard let adapter = adaptersBySessionID[session.id],
              let provider = adapter as? any CodexCapabilityProviding,
              let handle = handlesBySessionID[session.id]
        else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("Codex capabilities are unavailable for this task")
            )
        }
        return (adapter, provider, handle)
    }

    private func updateCodexActionError(_ error: Error, for sessionID: UUID) {
        guard store.sessions.contains(where: { $0.id == sessionID }) else { return }
        var state = codexCapabilitiesBySessionID[sessionID] ?? .empty
        state.actionMessage = error.localizedDescription
        codexCapabilitiesBySessionID[sessionID] = state
    }

    private func providerCapabilityProvider(
        for session: SessionRecord
    ) async throws -> (any HarnessAdapter, any ProviderCapabilityProviding, HarnessSessionHandle) {
        if handlesBySessionID[session.id] == nil {
            try await attach(session, resumesExistingSession: session.providerSessionID != nil)
        }
        guard let adapter = adaptersBySessionID[session.id],
              let provider = adapter as? any ProviderCapabilityProviding,
              let handle = handlesBySessionID[session.id] else {
            throw HarnessAdapterError.capabilityUnavailable(
                L10n.string("This harness does not expose live session controls")
            )
        }
        return (adapter, provider, handle)
    }

    private func unsupportedProviderState(for harness: HarnessKind) -> ProviderCapabilityState {
        ProviderCapabilityState(notes: [L10n.format(
            "%@ preserves its model and mode inside the harness; its current headless protocol does not expose live selectors.",
            harness.displayName
        )])
    }

    private func supportsLiveProviderControls(_ harness: HarnessKind) -> Bool {
        HarnessPresentationPolicy(harness: harness).loadsLiveProviderControls
    }

    /// A replacement capability state carries the selectors the provider just reported, not the
    /// answer its agent gave during the handshake. Carrying the recorded answer forward keeps a
    /// model change from putting back a composer control the agent already declined.
    private func keepingNegotiatedImageInput(
        _ next: ProviderCapabilityState,
        for sessionID: UUID
    ) -> ProviderCapabilityState {
        guard next.acceptsImageInput == nil else { return next }
        var next = next
        next.acceptsImageInput = providerCapabilitiesBySessionID[sessionID]?.acceptsImageInput
        return next
    }

    private func updateProviderActionError(_ error: Error, for sessionID: UUID) {
        guard store.sessions.contains(where: { $0.id == sessionID }) else { return }
        var state = providerCapabilitiesBySessionID[sessionID] ?? .empty
        state.actionMessage = error.localizedDescription
        providerCapabilitiesBySessionID[sessionID] = state
    }
}

extension AppModel {
    func beginCodexEdit(_ turn: CodexTurnState, in source: SessionRecord) {
        guard let session = matchingSession(source), session.harness == .codex,
              let thread = codexPresentationBySessionID[session.id]?.thread,
              thread.turns.last(where: \.hasNativeUserMessage)?.id == turn.id,
              thread.turns.allSatisfy({ $0.status.isTerminal }), followUps.queue(for: session.id).isEmpty,
              let input = turn.userInputDraft, let providerID = session.providerSessionID, !providerID.isEmpty,
              !sessionMutations.contains(session.id) else { return }
        let draft = composerDrafts.tasks.draft(for: session.id)
        guard draft.editState == nil else { return }
        let userTurns = thread.turns.filter(\.hasNativeUserMessage)
        var edit = ConversationEditState(session: session, targetID: turn.id,
            previousID: userTurns.dropLast().last?.id, originalText: input.text,
            draft: draft.snapshot, entries: transcriptBySessionID[session.id] ?? [])
        // As in the Codex app, the composer edits the request; its context goes again with the edit.
        // A message another task sent edits as its body, and the edit goes as the person's.
        let request = input.codexRequestForEditing
        edit.codexRequestPrefix = request?.requestPrefix
        draft.restore(request?.draft
            ?? TaskMessage.parse(input.text).map { CodexComposerDraft(inputs: [.text($0.body)]) } ?? input)
        draft.editState = edit
        composerDrafts.persistNow()
    }

    func beginClaudeEdit(_ text: String, in source: SessionRecord) async {
        guard let session = matchingSession(source), session.harness == .claudeCode,
              session.status != .running, session.status != .waitingForApproval,
              !sessionMutations.contains(session.id), let providerID = session.providerSessionID else { return }
        let draft = composerDrafts.tasks.draft(for: session.id)
        guard draft.editState == nil else { return }
        let initial = draft.snapshot
        do {
            let reader = claudeSessionReader(for: session)
            let points = try await Task.detached(priority: .utility) { try reader.conversationPoints(sessionID: providerID) }.value
            guard matchingSession(session) != nil, draft.snapshot == initial,
                  let point = points.last, let images = point.imageInputs,
                  point.text == text || (!point.text.isEmpty && text.hasPrefix(point.text + "\n")
                    && point.hasAttachments && (transcriptBySessionID[session.id] ?? []).last(where: {
                        if case .user = $0.content { true } else { false }
                    })?.content == .user(text: text)) else {
                throw HarnessAdapterError.capabilityUnavailable(L10n.string("This message can no longer be edited."))
            }
            var edit = ConversationEditState(session: session, targetID: point.id,
                previousID: point.previousAssistantID, originalText: point.text,
                draft: initial, entries: transcriptBySessionID[session.id] ?? [])
            edit.originalInputFingerprint = point.inputFingerprint
            // A message another task sent edits as its body, and the edit goes as the person's.
            draft.restore(.init(inputs: [.text(TaskMessage.parse(point.text)?.body ?? point.text)] + images))
            draft.editState = edit
            composerDrafts.persistNow()
        } catch { draft.notice = error.localizedDescription }
    }

    func cancelConversationEdit(in session: SessionRecord) {
        let draft = composerDrafts.tasks.draft(for: session.id)
        guard let edit = draft.editState, edit.preparedProviderSessionID == nil,
              !sessionMutations.contains(session.id) else { return }
        // Diff and browser comments wait outside the edit, so canceling it leaves them as they are.
        draft.apply(.init(text: edit.previousDraftText, attachments: edit.previousDraftAttachments,
                          diffComments: draft.diffComments.isEmpty ? nil : draft.diffComments,
                          browserComments: draft.browserComments.isEmpty ? nil : draft.browserComments))
        composerDrafts.persistNow()
    }

    private func submitConversationEdit(_ input: CodexComposerDraft, to source: SessionRecord) async {
        let draft = composerDrafts.tasks.draft(for: source.id)
        guard !input.isEmpty, var edit = draft.editState, var session = matchingSession(source), edit.matches(session),
              !switchingAccounts.contains(session.id), session.status != .running, session.status != .waitingForApproval,
              sessionMutations.insert(session.id).inserted else { return }
        defer { sessionMutations.remove(session.id) }
        do {
            guard followUps.queue(for: session.id).isEmpty else {
                throw HarnessAdapterError.capabilityUnavailable("Remove queued messages before editing")
            }
            composerDrafts.persistNow()
            guard composerDrafts.storageFailure == nil else { throw HarnessAdapterError.capabilityUnavailable("The edit draft could not be saved") }
            if session.harness == .claudeCode {
                guard case let .send(outgoing) = HarnessComposerInputPolicy(harness: .claudeCode).submission(for: input) else {
                    throw HarnessAdapterError.capabilityUnavailable(L10n.string("This edited attachment cannot be sent."))
                }
                _ = try outgoing.encodedImages()
            }
            session = await sessionWithAvailableRuntime(session)
            if edit.preparedProviderSessionID == nil, let planned = edit.plannedProviderSessionID,
               session.providerSessionID == planned {
                guard session.harness == .claudeCode,
                      session.inheritedContext?.nativeForkSource?.providerSessionID == edit.originalProviderSessionID
                        || (edit.previousID == nil && (session.inheritedContext == nil
                            || session.inheritedContext?.nativeConversationOrigin?.providerSessionID == edit.originalProviderSessionID)) else {
                    throw HarnessAdapterError.invalidProviderEvent("The edit destination has changed")
                }
                edit.preparedProviderSessionID = planned
                draft.editState = edit
                composerDrafts.persistNow()
            }
            if edit.preparedProviderSessionID == nil {
                if session.harness == .codex {
                    let (adapter, _, handle) = try await codexProvider(for: session)
                    guard let editing = adapter as? any CodexConversationEditing else {
                        throw HarnessAdapterError.capabilityUnavailable("Conversation editing is unavailable")
                    }
                    try await editing.prepareConversationEdit(edit, in: handle)
                    guard let current = matchingSession(session), edit.matches(current) else { return }
                    // Cached removed items must not reappear when retained history is hydrated.
                    codexTimelineItemRepository.remove(for: session.id)
                    codexPendingRequestRepository.remove(for: session.id)
                    codexHistorySelectionRepository.remove(for: session.id)
                    codexHistorySelectionBySessionID.removeValue(forKey: session.id)
                    edit.preparedProviderSessionID = handle.providerSessionID
                } else if session.harness == .claudeCode {
                    try ClaudeComposerCommands.validateSubmission(input.text,
                        commands: providerCapabilitiesBySessionID[session.id]?.composerCommands ?? [])
                    guard let oldID = session.providerSessionID else { return }
                    let reader = claudeSessionReader(for: session)
                    let points = try await Task.detached(priority: .utility) { try reader.conversationPoints(sessionID: oldID) }.value
                    guard let point = points.last, point.id == edit.targetID, point.text == edit.originalText,
                          point.previousAssistantID == edit.previousID, point.imageInputs != nil,
                          (edit.originalInputFingerprint.map { $0 == point.inputFingerprint } ?? !point.hasAttachments) else {
                        throw HarnessAdapterError.capabilityUnavailable(L10n.string("This message can no longer be edited."))
                    }
                    if handlesBySessionID[session.id] == nil { try await attach(session, resumesExistingSession: true) }
                    guard let adapter = adaptersBySessionID[session.id], let handle = handlesBySessionID[session.id],
                          let quiescing = adapter as? any HarnessConversationQuiescing else {
                        throw HarnessAdapterError.capabilityUnavailable("Conversation rewind is unavailable")
                    }
                    try await quiescing.requireReadyForRewind(in: handle)
                    guard let current = matchingSession(session), edit.matches(current) else { return }
                    let newID = edit.plannedProviderSessionID ?? UUID().uuidString.lowercased()
                    edit.plannedProviderSessionID = newID
                    draft.editState = edit
                    composerDrafts.persistNow()
                    guard composerDrafts.storageFailure == nil else {
                        throw HarnessAdapterError.capabilityUnavailable("The edit destination could not be saved")
                    }
                    var context = SideChatContext(source: current, entries: point.precedingEntries,
                        nativeForkSource: point.previousAssistantID.map { .init(providerSessionID: oldID, throughMessageID: $0) })
                    context.nativeConversationOrigin = NativeConversationOrigin(session: current)
                    context.isDelivered = true
                    // Persist the new native identity before launching it. The draft retains the
                    // original identity/cache and survives a failed launch or first submission.
                    try await store.updateSession(id: session.id, status: .ready, providerSessionID: newID,
                        setProviderSessionID: true, inheritedContext: context, setInheritedContext: true)
                    eventTasksBySessionID.removeValue(forKey: session.id)?.cancel()
                    handlesBySessionID.removeValue(forKey: session.id)
                    adaptersBySessionID.removeValue(forKey: session.id)
                    await adapter.close(handle)
                    transcriptBuilders[session.id] = TranscriptBuilder(entries: point.precedingEntries)
                    publishTranscript(for: session.id)
                    edit.preparedProviderSessionID = newID
                    guard let fresh = store.sessions.first(where: { $0.id == session.id }) else { return }
                    session = fresh
                } else { throw HarnessAdapterError.capabilityUnavailable("Conversation editing is unavailable") }
                guard draft.editState?.id == edit.id else { return }
                draft.editState = edit
                composerDrafts.persistNow()
                guard composerDrafts.storageFailure == nil else { throw HarnessAdapterError.capabilityUnavailable("The prepared edit could not be saved") }
            }
            guard let current = store.sessions.first(where: { $0.id == session.id }), edit.matches(current) else { return }
            session = current
            if handlesBySessionID[session.id] == nil { try await attach(session, resumesExistingSession: true) }
            guard let adapter = adaptersBySessionID[session.id], let handle = handlesBySessionID[session.id] else { return }
            if session.harness == .codex, let editing = adapter as? any CodexConversationEditing {
                // A lost send acknowledgement may have committed a newer user turn. Recheck the
                // retained native head before retrying, never append a duplicate edited message.
                try await editing.prepareConversationEdit(edit, in: handle)
            }
            let retained = edit.originalEntries
            let boundary = retained.lastIndex { if case .user = $0.content { true } else { false } }
            let preceding = boundary.map { Array(retained[..<$0]) } ?? []
            transcriptBuilders[session.id] = TranscriptBuilder(entries: preceding)
            let projected = HarnessUserInput.projecting(input).input
            let isClaude = session.harness == .claudeCode
            // A Codex request edited alone goes with the context it was first sent with.
            let sent = edit.codexRequestPrefix.map { input.sendingCodexRequest(after: $0) } ?? input
            mutateTranscript(for: session.id, publishImmediately: true) {
                $0.appendUser(isClaude ? projected.promptText : sent.text, images: isClaude ? projected.transcriptImages : [])
            }
            await markSubmissionStarted(for: session.id)
            if let composer = adapter as? any CodexComposerProviding {
                guard await composer.activeTurnID(for: handle) == nil else {
                    throw HarnessAdapterError.capabilityUnavailable(L10n.string("Stop the current turn before editing a message."))
                }
                try await composer.submit(sent, submission: .start, to: handle)
            } else {
                guard case let .send(outgoing) = HarnessComposerInputPolicy(harness: session.harness).submission(for: sent) else {
                    throw HarnessAdapterError.capabilityUnavailable("This edited attachment cannot be sent")
                }
                try await adapter.send(outgoing, to: handle)
            }
            guard store.sessions.contains(where: { $0.id == session.id }), draft.editState?.id == edit.id else { return }
            if draft.submission == input { draft.clear() }
            else { draft.editState = nil }
            composerDrafts.persistNow()
            errorBySessionID.removeValue(forKey: session.id)
        } catch {
            if store.sessions.contains(where: { $0.id == source.id }), draft.editState?.id == edit.id {
                draft.notice = error.localizedDescription
                if store.sessions.first(where: { $0.id == source.id })?.status == .running {
                    try? await store.updateSession(id: source.id, status: .failed)
                }
            }
        }
    }

    func loadClaudeFilePoints(in source: SessionRecord) async throws -> [ClaudeConversationPoint] {
        guard let session = matchingSession(source), session.harness == .claudeCode,
              let providerID = session.providerSessionID else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("File restore is unavailable."))
        }
        let reader = claudeSessionReader(for: session)
        let points = try await Task.detached(priority: .utility) { try reader.conversationPoints(sessionID: providerID) }.value
        guard matchingSession(session) != nil else { throw HarnessAdapterError.invalidProviderEvent("Task changed during checkpoint read") }
        return points
    }

    func previewClaudeFiles(pointID: String, in source: SessionRecord) async throws -> FileRewindPreview {
        guard var session = matchingSession(source), session.status != .running,
              session.status != .waitingForApproval, !sessionMutations.contains(session.id) else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Stop active work before rewinding this conversation."))
        }
        let points = try await loadClaudeFilePoints(in: session)
        guard let point = points.first(where: { $0.id == pointID }) else { throw HarnessAdapterError.invalidProviderEvent("Unknown file checkpoint") }
        session = await sessionWithAvailableRuntime(session)
        if handlesBySessionID[session.id] == nil { try await attach(session, resumesExistingSession: true) }
        guard let adapter = adaptersBySessionID[session.id] as? any HarnessFileRewinding,
              let handle = handlesBySessionID[session.id] else { throw HarnessAdapterError.capabilityUnavailable("File restore is unavailable") }
        let result = try await adapter.previewFileRewind(userMessageID: point.id, in: handle)
        guard matchingSession(session) != nil else { throw HarnessAdapterError.invalidProviderEvent("Task changed during file preview") }
        let hashes = try ClaudeSubagentTranscriptReader.fileFingerprints(result.canRewind ? result.filesChanged ?? [] : [], in: session)
        let preview = FileRewindPreview(id: UUID(), session: session, point: point, result: result, fileFingerprints: hashes)
        reviewedFileRewinds[preview.id] = preview
        return preview
    }

    func restoreClaudeFiles(_ preview: FileRewindPreview) async throws -> HarnessFileRewindResult {
        guard reviewedFileRewinds[preview.id] == preview, let session = matchingSession(preview.session),
              preview.result.canRewind, let files = preview.result.filesChanged,
              session.status != .running, session.status != .waitingForApproval,
              sessionMutations.insert(session.id).inserted else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Review the file changes before restoring them."))
        }
        defer { sessionMutations.remove(session.id); reviewedFileRewinds.removeValue(forKey: preview.id) }
        guard try ClaudeSubagentTranscriptReader.fileFingerprints(files, in: session) == preview.fileFingerprints else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("The file changes have changed. Review them again."))
        }
        let points = try await loadClaudeFilePoints(in: session)
        guard points.contains(where: { $0.id == preview.point.id }),
              let controller = adaptersBySessionID[session.id] as? any HarnessFileRewinding,
              let handle = handlesBySessionID[session.id] else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("File restore is unavailable."))
        }
        return try await controller.restoreFiles(userMessageID: preview.point.id, expecting: preview.result, in: handle)
    }
}
