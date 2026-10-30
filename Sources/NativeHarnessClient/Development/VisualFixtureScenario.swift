#if DEBUG
import Foundation
import SwiftUI

/// The smallest valid PNG, standing in for a plugin screenshot so the fixture never carries a
/// captured screen.
private let onePixelPNGBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

enum VisualFixtureAppearance: String, Sendable {
    case light
    case dark

    static func requested(arguments: [String] = CommandLine.arguments) -> Self? {
        arguments
            .first(where: { $0.hasPrefix("--ui-fixture-appearance=") })
            .map { String($0.dropFirst("--ui-fixture-appearance=".count)).lowercased() }
            .flatMap(Self.init(rawValue:))
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }
}

struct VisualFixtureScenario: Sendable {
    let sessions: [SessionRecord]
    let transcripts: [UUID: [TranscriptEntry]]
    let errors: [UUID: String]
    let codexPresentation: [UUID: CodexTaskState]
    let codexQueues: [UUID: [CodexQueuedSubmission]]
    let codexCapabilities: [UUID: CodexCapabilityState]
    let providerCapabilities: [UUID: ProviderCapabilityState]
    let providerUsage: [UUID: HarnessProtocolUsage]
    /// DEBUG-only launch selection used to measure native task surfaces without an interactive
    /// click or provider wake. Production launches leave this nil.
    let initialTaskSurface: String?
    /// DEBUG-only capability-sheet fixture selector. Production launches leave this nil.
    let initialCodexCapabilitySection: String?
    /// DEBUG-only: open the import sheet's Codex list searching for this. Production launches
    /// leave it nil.
    let initialCodexHistoryQuery: String?
    /// DEBUG-only Settings fixture selector. Production launches leave this nil.
    let initialSettingsSection: String?
    /// DEBUG-only notification authorization projection. Production launches leave this nil;
    /// Settings fixtures can inject a deterministic status without touching macOS permission UI.
    let initialNotificationAuthorization: SystemNotificationAuthorization?
    /// The Codex history the import sheet lists for the fixture, without a provider.
    var codexHistory: [CodexThreadSummary] = []
    /// Projects already there at launch, so tasks in a worktree sit under the project of the
    /// repository they came from rather than getting one of their own.
    var projects: ProjectSnapshot? = nil
    /// Codex cards Yardlet saved for its tasks, there before the provider streams anything.
    var codexTimelineItems: [UUID: [CodexPersistedTimelineItem]] = [:]
    /// Tasks already archived, in the index beside `sessions`.
    var archivedSessions: [SessionRecord] = []

    static func requested(arguments: [String] = CommandLine.arguments) -> VisualFixtureScenario? {
        if arguments.contains(PerfBenchFixture.argument) {
            return PerfBenchFixture.scenario()
        }
        if arguments.contains("--ui-fixture=lifecycle"),
           let runtime = arguments.first(where: { $0.hasPrefix("--ui-fixture-runtime=") }) {
            let executable = URL(filePath: String(runtime.dropFirst("--ui-fixture-runtime=".count)))
            let isAntigravity = arguments.contains("--ui-fixture-harness=antigravity-cli")
            let isClaude = arguments.contains("--ui-fixture-harness=claude-code")
            let session = SessionRecord(harness: isClaude ? .claudeCode : isAntigravity ? .antigravityCLI : .codex,
                workspaceURL: executable.deletingLastPathComponent(),
                runtimeExecutableURL: executable,
                title: isClaude ? "Claude task progress" : isAntigravity ? "Antigravity tool failure fixture" : "Codex connection recovery",
                providerSessionID: isClaude ? "00000000-0000-0000-0000-000000000001" : "lifecycle-thread",
                environmentScope: .native)
            return VisualFixtureScenario(sessions: [session], transcripts: [:], errors: [:],
                codexPresentation: [:], codexQueues: [:], codexCapabilities: [:], providerCapabilities: [:], providerUsage: [:],
                initialTaskSurface: nil, initialCodexCapabilitySection: nil, initialCodexHistoryQuery: nil,
                initialSettingsSection: nil, initialNotificationAuthorization: nil)
        }
        if arguments.contains(ShowcaseFixture.argument) {
            return ShowcaseFixture.scenario(root: ShowcaseFixture.root(arguments: arguments))
        }
        let isConversationFixture = arguments.contains("--ui-fixture=conversation")
            || arguments.contains("--ui-fixture=workspace")
            || arguments.contains("--ui-fixture=task-search")
            || arguments.contains("--ui-fixture=drafts")
            || arguments.contains("--ui-fixture=codex-reading")
            || arguments.contains("--ui-fixture=reading")
            || arguments.contains("--ui-fixture=home")
            || arguments.contains("--ui-fixture=connections")
        let isHistoryFixture = arguments.contains("--ui-fixture=history")
        let isSettingsFixture = arguments.contains("--ui-fixture=settings")
        let isHarnessTranscriptFixture = arguments.contains("--ui-fixture=harness-transcripts")
            || arguments.contains("--ui-fixture=inline-output")
        guard isConversationFixture
                || isHistoryFixture
                || isSettingsFixture
                || isHarnessTranscriptFixture else { return nil }
        let workspaceURL = arguments
            .first(where: { $0.hasPrefix("--ui-fixture-workspace=") })
            .map { String($0.dropFirst("--ui-fixture-workspace=".count)) }
            .map { URL(filePath: $0).standardizedFileURL }
        let initialTaskSurface = arguments
            .first(where: { $0.hasPrefix("--ui-fixture-surface=") })
            .map { String($0.dropFirst("--ui-fixture-surface=".count)).lowercased() }
            .flatMap { ["chat", "diff", "terminal", "browser", "full"].contains($0) ? $0 : nil }
        let initialSettingsSection = arguments
            .first(where: { $0.hasPrefix("--ui-fixture-settings-section=") })
            .map { String($0.dropFirst("--ui-fixture-settings-section=".count)).lowercased() }
            .flatMap {
                ["general", "appearance", "codex", "git", "hooks", "keyboard", "mcp", "plugins", "skills", "usage", "worktree", "notifications", "accounts", "harnesses", "connectors"].contains($0) ? $0 : nil
            } ?? (isSettingsFixture ? "general" : nil)
        let initialNotificationAuthorization: SystemNotificationAuthorization? = arguments
            .first(where: { $0.hasPrefix("--ui-fixture-notification-status=") })
            .map { String($0.dropFirst("--ui-fixture-notification-status=".count)).lowercased() }
            .flatMap { rawValue in
                switch rawValue {
                case "notdetermined", "not-determined": .notDetermined
                case "denied": .denied
                case "authorized": .authorized
                case "provisional": .provisional
                case "ephemeral": .ephemeral
                case "unknown": .unknown
                default: nil
                }
            }
        if isHarnessTranscriptFixture {
            return makeHarnessTranscripts(workspaceURL: workspaceURL ?? defaultFixtureWorkspace)
        }
        if arguments.contains("--ui-fixture=workspace") {
            return makeWorkspaceRestoration(workspaceURL: workspaceURL ?? defaultFixtureWorkspace)
        }
        if arguments.contains("--ui-fixture=task-search") {
            return makeTaskSearch(workspaceURL: workspaceURL ?? defaultFixtureWorkspace)
        }
        // Extra project folders for the populated task, so the Review repository menu can be seen
        // without creating a real multi-root task.
        let additionalRoots = arguments
            .filter { $0.hasPrefix("--ui-fixture-additional-root=") }
            .map { URL(filePath: String($0.dropFirst("--ui-fixture-additional-root=".count))).standardizedFileURL }
        return makeConversation(
            workspaceURL: workspaceURL ?? defaultFixtureWorkspace,
            initialTaskSurface: initialTaskSurface,
            initialCodexCapabilitySection: nil,
            initialCodexHistoryQuery: isHistoryFixture ? "native" : nil,
            initialSettingsSection: initialSettingsSection,
            initialNotificationAuthorization: initialNotificationAuthorization,
            additionalRoots: additionalRoots
        )
    }

    @MainActor
    func makeModel(preferences: UserDefaults = .yardlet) -> AppModel {
        let preferences = ShowcaseFixture.isRequested ? ShowcaseFixture.preferences()
            : PerfBenchFixture.isRequested ? PerfBenchFixture.preferences() : preferences
        let defaults = UserDefaults(suiteName: "NativeHarnessClient.VisualFixture") ?? .standard
        defaults.removePersistentDomain(forName: "NativeHarnessClient.VisualFixture")
        let notificationCenter: any SystemNotificationCenter = if let initialNotificationAuthorization {
            FixtureSystemNotificationCenter(authorization: initialNotificationAuthorization)
        } else {
            LocalSystemNotificationCenter()
        }
        let selections = RuntimeSelectionStore(
            defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false
        )
        let draftRepository: any ComposerDraftRepository
        let isWorkspaceFixture = CommandLine.arguments.contains("--ui-fixture=workspace")
        if CommandLine.arguments.contains("--ui-fixture=drafts") || isWorkspaceFixture {
            draftRepository = FileComposerDraftRepository(
                directoryURL: URL(filePath: NSTemporaryDirectory())
                    .appending(path: isWorkspaceFixture ? "yardlet-workspace-draft-fixture" : "yardlet-draft-persistence-fixture")
            )
            for harness in [HarnessKind.codex, .openCode] {
                selections.select(URL(filePath: "/usr/bin/true"), for: harness)
            }
        } else {
            draftRepository = InMemoryComposerDraftRepository()
        }
        if CommandLine.arguments.contains("--ui-fixture=task-search"),
           CommandLine.arguments.contains("--ui-fixture-home-harnesses") {
            for harness in [HarnessKind.codex, .openCode] {
                selections.select(URL(filePath: "/usr/bin/true"), for: harness)
            }
        }
        let sessionRepository: any SessionRepository
        if CommandLine.arguments.contains("--ui-fixture=task-search"),
           let failure = CommandLine.arguments.first(where: { $0.hasPrefix("--ui-fixture-fail-once=") }),
           let operation = TaskManagementFixtureRepository.Operation(
               rawValue: String(failure.dropFirst("--ui-fixture-fail-once=".count))
           ) {
            sessionRepository = TaskManagementFixtureRepository(sessions: sessions, failOnce: operation)
        } else {
            sessionRepository = InMemorySessionRepository(sessions: sessions + archivedSessions,
                                                          archived: archivedSessions.map(\.id))
        }
        // The bench keeps saved Codex cards in files, as the app does; other fixtures in their settings.
        if PerfBenchFixture.isRequested { PerfBenchFixture.selectRuntimes(in: selections) }
        let timelineItems: any CodexTimelineItemRepository = PerfBenchFixture.isRequested
            ? PerfBenchFixture.timelineItemRepository() : UserDefaultsCodexTimelineItemRepository(defaults: defaults)
        for (id, items) in codexTimelineItems { timelineItems.save(items, for: id) }
        let connections = ProviderConnectionStore()
        if ShowcaseFixture.isRequested { ShowcaseFixture.Accounts.add(to: connections, selections: selections) }
        if CommandLine.arguments.contains("--ui-fixture=connections") {
            connections.usesFixtureSnapshots = true
            for harness in [HarnessKind.codex, .openCode, .pi, .claudeCode] { selections.select(URL(filePath: "/usr/bin/true"), for: harness) }
            // Index 2 is the same ChatGPT account as index 1 reached through another
            // harness: one account row, one usage block, two connections underneath.
            let now = Date()
            let rows: [(harness: HarnessKind, provider: String, account: Int, shortUsed: Double, shortLeft: Double)] = [
                (.codex, "openai-codex", 1, 0.92, 8),
                (.codex, "openai-codex", 2, 0.35, 65),
                (.openCode, "openai-codex", 2, 0.35, 65),
                (.claudeCode, "anthropic", 4, 0.40, 60)
            ]
            for (index, row) in rows.enumerated() {
                let connection = ProviderConnection(id: "fixture-account-\(index)", name: "Account \(row.account)",
                    harness: row.harness, providerID: row.provider, homePath: "/tmp/yardlet-account-fixture-\(index)", credentialSelector: nil)
                try? connections.save(connection)
                connections.publish(HarnessAccountSnapshot(id: connection.id, harness: row.harness, providerID: row.provider,
                    state: .signedIn, accountLabel: "account\(row.account)@example.test",
                    accountPlan: row.provider == "openai-codex" ? L10n.format("ChatGPT %@ plan", "Pro") : nil,
                    detail: "Fixture account",
                    credentialOwner: row.harness.rawValue, checkedAt: now, usage: [
                        AccountUsageMetric(id: "short", label: L10n.format("%.0f hour limit", 5.0), usedFraction: row.shortUsed,
                            detail: L10n.format("%.0f%% remaining", row.shortLeft), resetsAt: now.addingTimeInterval(3600), evidence: .exactQuota),
                        AccountUsageMetric(id: "long", label: L10n.format("%.0f day limit", 7.0), usedFraction: 0.5,
                            detail: L10n.format("%.0f%% remaining", 50.0), resetsAt: now.addingTimeInterval(172800), evidence: .exactQuota)
                    ], canLogin: false, canLogout: false), for: connection)
            }
        }
        let model = AppModel(
            store: SessionStore(
                sessions: sessions,
                repository: sessionRepository
            ),
            runtimeSelections: selections,
            connections: connections,
            initialTranscripts: transcripts,
            initialErrors: errors,
            initialCodexPresentation: codexPresentation,
            initialCodexQueues: codexQueues,
            initialCodexCapabilities: codexCapabilities,
            initialProviderCapabilities: providerCapabilities,
            initialProviderUsage: providerUsage,
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            preferences: preferences,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: timelineItems,
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(
                defaults: defaults,
                keyPrefix: "history."
            ),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            composerDraftRepository: draftRepository,
            taskWorkspaceRepository: CommandLine.arguments.contains("--ui-fixture=workspace")
                ? UserDefaultsTaskWorkspaceRepository(defaults: UserDefaults(suiteName: "NativeHarnessClient.WorkspaceRestorationFixture")!)
                : InMemoryTaskWorkspaceRepository(),
            projectRepository: InMemoryProjectRepository(snapshot: projects),
            systemNotificationCenter: notificationCenter,
            restoresIndexOnLaunch: false,
            isVisualFixture: true,
            initialTaskSurface: initialTaskSurface,
            initialCodexCapabilitySection: initialCodexCapabilitySection,
            initialCodexHistoryQuery: initialCodexHistoryQuery,
            initialSettingsSection: initialSettingsSection,
            browserClient: AppModel.macBrowserClient
        )
        model.visualFixtureCodexHistory = codexHistory
        if ShowcaseFixture.isRequested { ShowcaseFixture.prepare(model, root: ShowcaseFixture.root()) }
        if PerfBenchFixture.isRequested { PerfBenchFixture.prepare(model) }
        openFixtureSplit(in: model)
        return model
    }

    /// `--ui-fixture-split=right|down|empty` opens a split view of the first two tasks (or the
    /// first task beside an empty pane), so split rows and panes can be seen without a drag.
    /// `--ui-fixture-tabs` then opens the next tasks and the new-task screen in tabs and returns to
    /// the first tab.
    @MainActor
    private func openFixtureSplit(in model: AppModel, arguments: [String] = CommandLine.arguments) {
        defer { openFixtureTabs(in: model, arguments: arguments) }
        let prefix = "--ui-fixture-split="
        guard let mode = arguments.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count),
              let first = sessions.first else { return }
        model.splits.activate(.session(first.id))
        let second = sessions.dropFirst().first?.id
        switch mode {
        case "down": model.splits.split(.down, placing: second)
        case "empty": model.splits.split(.right)
        default: model.splits.split(.right, placing: second)
        }
    }

    @MainActor
    private func openFixtureTabs(in model: AppModel, arguments: [String]) {
        guard arguments.contains("--ui-fixture-tabs"), let first = sessions.first else { return }
        if model.splits.selection == .home { model.splits.activate(.session(first.id)) }
        let shown = model.splits.selection
        for session in sessions.dropFirst() where model.splits.split(containing: session.id) == nil {
            model.splits.openInNewTab(.session(session.id))
            if model.splits.tabs.count >= 3 { break }
        }
        model.splits.newTab()
        model.splits.selectTab(shown)
    }

    static var conversation: VisualFixtureScenario {
        let workspace = ProcessInfo.processInfo.environment["NHC_UI_FIXTURE_WORKSPACE"]
            .map { URL(filePath: $0).standardizedFileURL }
            ?? defaultFixtureWorkspace
        return makeConversation(
            workspaceURL: workspace,
            initialTaskSurface: nil,
            initialCodexCapabilitySection: nil,
            initialCodexHistoryQuery: nil,
            initialSettingsSection: nil,
            initialNotificationAuthorization: nil
        )
    }

    private static func makeWorkspaceRestoration(workspaceURL: URL) -> VisualFixtureScenario {
        let base = makeConversation(workspaceURL: workspaceURL, initialTaskSurface: nil)
        var sessions = base.sessions
        for index in sessions.indices {
            sessions[index].status = .completed
            sessions[index].completionState = .completed
        }
        let codexID = sessions.first(where: { $0.harness == .codex })!.id
        let claudeID = sessions.first(where: { $0.harness == .claudeCode })!.id
        // One task made in a linked worktree, so the sidebar row's worktree line is renderable
        // without a repository on disk. Its origin is the fixture workspace, which is what puts
        // it beside the tasks that run in the repository itself.
        sessions.append(SessionRecord(
            id: UUID(uuidString: "00000000-0000-0000-0003-000000000001")!,
            harness: .claudeCode,
            workspaceURL: workspaceURL
                .deletingLastPathComponent()
                .appending(path: "yardlet-worktree-blue", directoryHint: .isDirectory),
            runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
            title: "Task made in a worktree, shown under its original project",
            titleOrigin: .automatic,
            status: .completed,
            updatedAt: sessions.map(\.updatedAt).min() ?? Date(),
            completionState: .completed,
            originWorkspacePath: workspaceURL.path(percentEncoded: false),
            worktreeName: "yardlet-worktree-blue",
            branch: "feature/worktree-origin"
        ))
        var thread = CodexTaskDecoder().thread(from: .object(["id": .string("workspace-reading")]))!
        thread.turns = (1...60).map(CodexReadingFixtureView.turn)
        let entries: [TranscriptEntry] = (1...50).flatMap { number in
            let request = TranscriptEntry(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", number * 2))!,
                content: .user(text: "Request \(number)")
            )
            let response = TranscriptEntry(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", number * 2 + 1))!,
                content: .assistant(text: "## Claude response \(number)\n\n" + (1...8).map {
                    "Paragraph \($0) of response \(number). Keep this reading position. 한글 👩🏽‍💻"
                }.joined(separator: "\n\n"), isStreaming: false)
            )
            return [request, response]
        }
        return VisualFixtureScenario(
            sessions: sessions, transcripts: [claudeID: entries], errors: [:],
            codexPresentation: [codexID: CodexTaskState(thread: thread)], codexQueues: [:],
            codexCapabilities: base.codexCapabilities, providerCapabilities: [:], providerUsage: [:],
            initialTaskSurface: nil, initialCodexCapabilitySection: nil, initialCodexHistoryQuery: nil,
            initialSettingsSection: nil, initialNotificationAuthorization: nil
        )
    }

    /// Dense local index with typed and common history. All tasks are inert and in memory.
    private static func makeTaskSearch(workspaceURL: URL) -> VisualFixtureScenario {
        let base = makeWorkspaceRestoration(workspaceURL: workspaceURL)
        var sessions = base.sessions
        let date = sessions.map(\.updatedAt).min()!
        for number in 3...40 {
            sessions.append(SessionRecord(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0002-%012d", number))!,
                harness: HarnessCatalog.builtIns[(number - 3) % HarnessCatalog.builtIns.count].id,
                workspaceURL: number <= 24 ? workspaceURL
                    : workspaceURL.appending(path: number <= 32 ? "Mobile Client Screen Review" : "Release Studio"),
                runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
                title: number == 40
                    ? "Final search return: task 40 checks a long task title next to the harness label"
                    : "Task \(number) · checks long titles in the conversation and project views",
                status: .completed,
                updatedAt: date.addingTimeInterval(-Double(number)),
                hasUnreadUpdate: number.isMultiple(of: 5),
                completionState: .completed,
                isPinned: number == 7 || number == 23
            ))
        }
        return VisualFixtureScenario(
            sessions: sessions, transcripts: base.transcripts, errors: [:],
            codexPresentation: base.codexPresentation, codexQueues: [:],
            codexCapabilities: base.codexCapabilities, providerCapabilities: [:], providerUsage: [:],
            initialTaskSurface: nil, initialCodexCapabilitySection: nil, initialCodexHistoryQuery: nil,
            initialSettingsSection: nil, initialNotificationAuthorization: nil
        )
    }

    /// Provider-free matrix for reviewing the common transcript with every non-Codex harness.
    /// The fixture never discovers, attaches, resumes, or sends to an installed runtime.
    static var harnessTranscripts: VisualFixtureScenario {
        let workspace = ProcessInfo.processInfo.environment["NHC_UI_FIXTURE_WORKSPACE"]
            .map { URL(filePath: $0).standardizedFileURL }
            ?? defaultFixtureWorkspace
        return makeHarnessTranscripts(workspaceURL: workspace)
    }

    /// Provider-free Account Center fixture used for deterministic installed
    /// presentation/resource review. It never selects or starts a CLI runtime.
    static var harnessCenterSnapshots: [HarnessAccountSnapshot] {
        let existing = accountSnapshots
        let snapshots = HarnessCatalog.builtIns.map { descriptor in
            if let snapshot = existing.first(where: { $0.harness == descriptor.id }) { return snapshot }
            let state: AccountAuthState = switch descriptor.id {
            case .claudeCode: .signedOut
            case .kimiCode: .actionRequired
            case .grokBuild: .unknown
            default: .unavailable
            }
            return HarnessAccountSnapshot(
                id: descriptor.id.rawValue, harness: descriptor.id, providerID: nil,
                state: state, accountLabel: nil, detail: state.displayName,
                credentialOwner: descriptor.displayName, checkedAt: Date(timeIntervalSince1970: 1_755_321_600),
                usage: [], canLogin: false, canLogout: false
            )
        }
        return ShowcaseFixture.isRequested ? ShowcaseFixture.Accounts.defaultSnapshots(replacing: snapshots) : snapshots
    }

    static var accountSnapshots: [HarnessAccountSnapshot] {
        let checkedAt = Date()
        return [
            HarnessAccountSnapshot(
                id: "codex",
                harness: .codex,
                providerID: "openai-codex",
                state: .signedIn,
                accountLabel: "fixture@example.test",
                detail: L10n.format("ChatGPT %@ plan", "Pro"),
                credentialOwner: L10n.string("Codex CLI / system credential store"),
                checkedAt: checkedAt,
                usage: [
                    AccountUsageMetric(
                        id: "codex-primary",
                        label: "Codex weekly",
                        usedFraction: 0.42,
                        detail: L10n.format("%.0f%% remaining", 58.0),
                        resetsAt: checkedAt.addingTimeInterval(86_400),
                        evidence: .exactQuota
                    ),
                    AccountUsageMetric(
                        id: "account-lifetime",
                        label: L10n.string("Lifetime tokens"),
                        usedFraction: nil,
                        detail: L10n.format("%lld tokens", Int64(12_345)),
                        resetsAt: nil,
                        evidence: .accountUsage
                    ),
                    AccountUsageMetric(
                        id: "account-daily-2026-08-15",
                        label: "2026-08-15",
                        usedFraction: nil,
                        detail: L10n.format("%lld tokens", Int64(420)),
                        resetsAt: nil,
                        evidence: .accountUsage
                    )
                ],
                canLogin: false,
                canLogout: true
            ),
            HarnessAccountSnapshot(
                id: "pi:openai-codex",
                harness: .pi,
                providerID: "openai-codex",
                state: .signedIn,
                accountLabel: nil,
                detail: L10n.string("OpenAI Codex OAuth is ready in Pi."),
                credentialOwner: L10n.string("Pi credential store (separate OAuth session)"),
                checkedAt: checkedAt,
                usage: [
                    AccountUsageMetric(
                        id: "account-streak",
                        label: L10n.string("Current streak"),
                        usedFraction: nil,
                        detail: L10n.format("%lld days", Int64(3)),
                        resetsAt: nil,
                        evidence: .accountUsage
                    )
                ],
                canLogin: false,
                canLogout: true
            ),
            HarnessAccountSnapshot(
                id: "opencode",
                harness: .openCode,
                providerID: nil,
                state: .signedIn,
                accountLabel: nil,
                detail: L10n.string("OpenCode has at least one configured model provider."),
                credentialOwner: L10n.string("OpenCode provider credentials and environment"),
                checkedAt: checkedAt,
                usage: [],
                canLogin: true,
                canLogout: true
            )
        ]
    }

    private static var defaultFixtureWorkspace: URL {
        FileManager.default.temporaryDirectory
    }

    // `makeHarnessTranscripts`, `completedHarnessTranscript`, `makeConversation` and
    // `makeCodexPresentationState` are internal (still DEBUG-only) so the rendering and
    // equivalence tests draw the same conversations through `ConversationFixtures`.

    static func makeHarnessTranscripts(
        workspaceURL workspace: URL
    ) -> VisualFixtureScenario {
        let now = Date()
        let descriptors = HarnessCatalog.builtIns.filter { $0.id != .codex }
        var sessions: [SessionRecord] = []
        var transcripts: [UUID: [TranscriptEntry]] = [:]
        var providerCapabilities: [UUID: ProviderCapabilityState] = [:]
        var providerUsage: [UUID: HarnessProtocolUsage] = [:]

        for (offset, descriptor) in descriptors.enumerated() {
            let suffix = String(format: "%012X", offset + 1)
            let sessionID = UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
            let session = SessionRecord(
                id: sessionID,
                harness: descriptor.id,
                workspaceURL: workspace,
                runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
                title: "\(descriptor.displayName) transcript",
                titleOrigin: .automatic,
                status: .ready,
                createdAt: now.addingTimeInterval(TimeInterval(-descriptors.count + offset)),
                updatedAt: now.addingTimeInterval(TimeInterval(offset)),
                providerSessionID: "visual-\(descriptor.id.rawValue)-session",
                completionState: .completed
            )
            sessions.append(session)
            transcripts[sessionID] = completedHarnessTranscript(for: descriptor)
            if descriptor.id == .grokBuild {
                providerCapabilities[sessionID] = grokCapabilityFixture
                providerUsage[sessionID] = HarnessProtocolUsage(
                    inputTokens: 20_618,
                    cachedInputTokens: 6_400,
                    outputTokens: 64,
                    reasoningTokens: 50,
                    totalCostUSD: 0.0054434,
                    contextWindowTokens: 500_000,
                    contextUsedTokens: 10_445,
                    extensionValues: [:]
                )
            }
        }

        return VisualFixtureScenario(
            sessions: sessions,
            transcripts: transcripts,
            errors: [:],
            codexPresentation: [:],
            codexQueues: [:],
            codexCapabilities: [:],
            providerCapabilities: providerCapabilities,
            providerUsage: providerUsage,
            initialTaskSurface: nil,
            initialCodexCapabilitySection: nil,
            initialCodexHistoryQuery: nil,
            initialSettingsSection: nil,
            initialNotificationAuthorization: nil
        )
    }

    private static var grokCapabilityFixture: ProviderCapabilityState {
        ProviderCapabilityState(selectors: [
            ProviderCapabilitySelector(
                id: "model",
                name: L10n.string("Model"),
                description: nil,
                category: "model",
                currentValue: "grok-4.6-build",
                choices: [
                    ProviderCapabilityChoice(
                        value: "grok-4.6-build", name: "Grok 4.6 Build", description: nil
                    ),
                    ProviderCapabilityChoice(
                        value: "grok-4.5", name: "Grok 4.5", description: nil
                    )
                ]
            ),
            ProviderCapabilitySelector(
                id: "reasoning_effort",
                name: L10n.string("Reasoning effort"),
                description: nil,
                category: "thought_level",
                currentValue: "high",
                choices: [
                    ProviderCapabilityChoice(value: "low", name: "Low", description: nil),
                    ProviderCapabilityChoice(value: "high", name: "High", description: nil)
                ]
            )
        ])
    }

    static func completedHarnessTranscript(
        for descriptor: HarnessDescriptor
    ) -> [TranscriptEntry] {
        [
            TranscriptEntry(content: .user(
                text: "Check \(descriptor.displayName) transcript presentation."
            )),
            TranscriptEntry(content: .assistant(
                text: "I’ll verify the shared transcript without waking \(descriptor.displayName).",
                isStreaming: false
            )),
            TranscriptEntry(content: .plan(
                "1. Preserve event order\n2. Group completed work\n3. Render the final answer"
            )),
            TranscriptEntry(content: .reasoning(
                text: "Reading the transcript fixture before answering. "
                    + "The thought stays collapsed and apart from the answer.",
                isStreaming: false
            )),
            TranscriptEntry(content: .activity(
                HarnessActivity(
                    id: "visual-\(descriptor.id.rawValue)-read",
                    kind: "read",
                    title: "Inspect provider output",
                    detail: "Read-only fixture event"
                ),
                state: .completed
            )),
            TranscriptEntry(content: .activity(
                HarnessActivity(
                    id: "visual-\(descriptor.id.rawValue)-edit",
                    kind: "edit",
                    title: "Apply the fixture patch",
                    detail: nil,
                    input: "apply_patch README.md\n\nREADME.md:3",
                    output: "1 file changed, 1 insertion(+), 1 deletion(-)",
                    diff: HarnessActivityDiff(
                        path: "README.md",
                        oldText: "# Yardlet",
                        newText: "# Yardlet workbench"
                    )
                ),
                state: .completed
            )),
            TranscriptEntry(content: .permission(
                PermissionRequest(
                    id: "visual-\(descriptor.id.rawValue)-permission",
                    title: "Use fixture data",
                    detail: "Resolved locally without contacting the provider.",
                    command: nil
                ),
                state: .allowed
            )),
            TranscriptEntry(content: .assistant(
                text: "**\(descriptor.displayName)**\n\n" + TranscriptReadingFixtureView.mixedMarkdown,
                isStreaming: false
            )),
            TranscriptEntry(content: .user(text: "Approve the next tool call.")),
            TranscriptEntry(content: .permission(
                PermissionRequest(
                    id: "visual-\(descriptor.id.rawValue)-options",
                    title: "Run a command",
                    detail: "execute",
                    command: "swift test --build-system native",
                    actions: [
                        PermissionRequestAction(
                            id: "allow-once", label: "Allow once",
                            decision: .allow, kind: "allow_once"
                        ),
                        PermissionRequestAction(
                            id: "allow-always", label: "Always allow",
                            decision: .allow, kind: "allow_always"
                        ),
                        PermissionRequestAction(
                            id: "reject-once", label: "Reject",
                            decision: .deny, kind: "reject_once"
                        ),
                        PermissionRequestAction(
                            id: "reject-always", label: "Always reject",
                            decision: .deny, kind: "reject_always"
                        )
                    ]
                ),
                state: .pending
            ))
        ]
    }

    static func makeConversation(
        workspaceURL workspace: URL,
        initialTaskSurface: String?,
        initialCodexCapabilitySection: String? = nil,
        initialCodexHistoryQuery: String? = nil,
        initialSettingsSection: String? = nil,
        initialNotificationAuthorization: SystemNotificationAuthorization? = nil,
        additionalRoots: [URL] = []
    ) -> VisualFixtureScenario {
        let now = Date()
        let populated = SessionRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000F401")!,
            harness: .codex,
            workspaceURL: workspace,
            runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
            title: "Restore the Codex task surface",
            status: .waitingForApproval,
            createdAt: now.addingTimeInterval(-900),
            updatedAt: now,
            providerSessionID: "visual-codex-session",
            additionalRoots: additionalRoots.map { $0.path(percentEncoded: false) }
        )
        let failed = SessionRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000F402")!,
            harness: .claudeCode,
            workspaceURL: workspace,
            runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
            title: "Permission and error states",
            status: .failed,
            createdAt: now.addingTimeInterval(-1_800),
            updatedAt: now.addingTimeInterval(-120),
            providerSessionID: "visual-claude-session"
        )

        let populatedEntries: [TranscriptEntry] = [
            TranscriptEntry(content: .user(
                text: "Restore the task conversation surface while preserving harness-specific activity and approvals."
            )),
            TranscriptEntry(content: .assistant(
                text: "I’ll keep the common shell compact and let each harness expose the capabilities it actually supports.",
                isStreaming: false
            )),
            TranscriptEntry(content: .plan(
                "1. Inspect the session storage contract\n2. Refine transcript states\n3. Verify only the changed surface"
            )),
            TranscriptEntry(content: .activity(
                HarnessActivity(
                    id: "fixture-read",
                    kind: "Read",
                    title: "Inspect the session storage contract",
                    detail: "docs/NATIVE_SESSION_STORAGE.md · sections 6, 8, 9, and 10"
                ),
                state: .completed
            )),
            TranscriptEntry(content: .activity(
                HarnessActivity(
                    id: "fixture-edit",
                    kind: "Edit",
                    title: "Update conversation components",
                    detail: "Sources/NativeHarnessClient/Views/Conversation/ConversationTimeline.swift"
                ),
                state: .running
            )),
            TranscriptEntry(content: .permission(
                PermissionRequest(
                    id: "fixture-permission",
                    title: "Run focused tests",
                    detail: "Codex wants to validate only the transcript bundle.",
                    command: "swift test --filter 'TranscriptBuilderTests|VisualFixtureScenarioTests'"
                ),
                state: .pending
            )),
            TranscriptEntry(content: .assistant(
                text: "The populated task surface now keeps progress, approvals, and streaming output in one readable column.",
                isStreaming: true
            ))
        ]

        let failedEntries: [TranscriptEntry] = [
            TranscriptEntry(content: .user(
                text: "Show an honest failure without losing the previous task context."
            )),
            TranscriptEntry(content: .activity(
                HarnessActivity(
                    id: "fixture-command",
                    kind: "Shell",
                    title: "Build native target",
                    detail: "swift build --product NativeHarnessClient"
                ),
                state: .completed
            )),
            TranscriptEntry(content: .permission(
                PermissionRequest(
                    id: "fixture-denied",
                    title: "Modify protected files",
                    detail: "The requested operation was not approved.",
                    command: "git push origin main"
                ),
                state: .denied
            )),
            TranscriptEntry(content: .error(
                message: "The harness stopped before the turn completed.\n\nFixture diagnostics: 한글 👩🏽‍💻\n  Request ID: local-review\nEND-OF-ERROR-DETAILS",
                recoverable: true
            ))
        ]

        let codexPresentation = makeCodexPresentationState(workspaceURL: workspace)
        let codexQueues: [UUID: [CodexQueuedSubmission]] = [
            populated.id: [
                CodexQueuedSubmission(
                    id: UUID(uuidString: "00000000-0000-0000-0000-00000000F411")!,
                    draft: CodexComposerDraft(inputs: [
                        .text("After the approval, verify the localized task shell.")
                    ]),
                    enqueuedAt: now.addingTimeInterval(-12),
                    state: .pending
                ),
                CodexQueuedSubmission(
                    id: UUID(uuidString: "00000000-0000-0000-0000-00000000F412")!,
                    draft: CodexComposerDraft(inputs: [
                        .skill(
                            name: "verification",
                            path: URL(filePath: "/fixture/verification/SKILL.md")
                        )
                    ]),
                    enqueuedAt: now.addingTimeInterval(-8),
                    state: .failed,
                    failureMessage: "The previous turn is still awaiting approval."
                )
            ]
        ]

        return VisualFixtureScenario(
            sessions: [populated, failed],
            transcripts: [
                populated.id: populatedEntries,
                failed.id: failedEntries
            ],
            errors: [failed.id: "The harness stopped before the turn completed."],
            codexPresentation: [populated.id: codexPresentation],
            codexQueues: codexQueues,
            codexCapabilities: [
                populated.id: CodexCapabilityState(
                    modes: [
                        CodexCollaborationPreset(
                            name: "Default",
                            mode: "default",
                            model: "gpt-5.6-codex",
                            reasoningEffort: "high"
                        ),
                        CodexCollaborationPreset(
                            name: "Plan",
                            mode: "plan",
                            model: "gpt-5.6-codex",
                            reasoningEffort: "high"
                        )
                    ],
                    selectedModeID: nil,
                    skills: [
                        CodexSkillSummary(
                            name: "openai-docs",
                            displayName: "OpenAI Docs",
                            description: "Use official OpenAI developer documentation for current product guidance.",
                            enabled: true,
                            scope: "user",
                            path: "/fixture/openai-docs/SKILL.md"
                        ),
                        CodexSkillSummary(
                            name: "verification",
                            displayName: "Verification",
                            description: "Verify the complete product flow end to end.",
                            enabled: true,
                            scope: "plugin",
                            path: "/fixture/verification/SKILL.md"
                        )
                    ],
                    plugins: [
                        CodexPluginSummary(
                            id: "github",
                            name: "github",
                            displayName: "GitHub",
                            description: "Repository, pull request, and issue workflows.",
                            installed: true,
                            enabled: true,
                            availability: "AVAILABLE",
                            marketplace: "OpenAI Curated"
                        ),
                        CodexPluginSummary(
                            id: "linear",
                            name: "linear",
                            displayName: "Linear",
                            description: "Issue and project workflows.",
                            installed: true,
                            enabled: false,
                            availability: "AVAILABLE",
                            marketplace: "OpenAI Curated"
                        ),
                        // Codex owns installation and enablement of its bundled plugins. The
                        // capability list only has to show that the same `~/.codex` home brings
                        // them to a Yardlet thread.
                        CodexPluginSummary(
                            id: "computer-use@openai-bundled",
                            name: "computer-use",
                            displayName: "Computer use",
                            description: "Screenshots and input for macOS apps.",
                            installed: true,
                            enabled: true,
                            availability: "AVAILABLE",
                            marketplace: "OpenAI Bundled"
                        )
                    ]
                )
            ],
            providerCapabilities: [
                failed.id: ProviderCapabilityState(
                    selectors: [
                        ProviderCapabilitySelector(
                            id: "model",
                            name: L10n.string("Model"),
                            description: L10n.string("Change the model for the active Claude Code session."),
                            category: "model",
                            currentValue: "sonnet",
                            choices: [
                                ProviderCapabilityChoice(value: "sonnet", name: "Sonnet", description: nil),
                                ProviderCapabilityChoice(value: "opus", name: "Opus", description: nil)
                            ]
                        ),
                        ProviderCapabilitySelector(
                            id: "permissionMode",
                            name: L10n.string("Permission mode"),
                            description: L10n.string("Controls how Claude Code asks before using tools."),
                            category: "mode",
                            currentValue: "manual",
                            choices: [
                                ProviderCapabilityChoice(value: "manual", name: L10n.string("Manual"), description: nil),
                                ProviderCapabilityChoice(value: "plan", name: L10n.string("Plan"), description: nil)
                            ]
                        )
                    ],
                    notes: [L10n.string("Skills, agents, plugins, hooks, and MCP remain owned by Claude Code settings.")]
                )
            ],
            providerUsage: [:],
            initialTaskSurface: initialTaskSurface,
            initialCodexCapabilitySection: initialCodexCapabilitySection,
            initialCodexHistoryQuery: initialCodexHistoryQuery,
            initialSettingsSection: initialSettingsSection,
            initialNotificationAuthorization: initialNotificationAuthorization,
            codexHistory: [
                CodexThreadSummary(
                    id: "visual-codex-session",
                    title: "Native harness architecture",
                    preview: "Keep the common shell small and preserve provider-specific capabilities.",
                    workspaceURL: workspace,
                    updatedAt: now.addingTimeInterval(-3_600),
                    forkedFromID: nil
                ),
                CodexThreadSummary(
                    id: "fixture-history-2",
                    title: "Terminal and browser surfaces",
                    preview: "Validate the shared work surfaces without keeping WebKit alive.",
                    workspaceURL: workspace,
                    updatedAt: now.addingTimeInterval(-8_000),
                    forkedFromID: nil
                )
            ]
        )
    }

    /// A deterministic mixed-item fixture for the typed Codex timeline. Keeping this built from
    /// the same decoder/reducer path as provider events catches presentation regressions that a
    /// flat compatibility transcript cannot show: historical turns, active streaming, plan and
    /// usage updates, approvals, subagent identity, and unknown item preservation.
    static func makeCodexPresentationState(workspaceURL: URL) -> CodexTaskState {
        let reducer = CodexTaskReducer()
        let workspacePath = workspaceURL.standardizedFileURL.path(percentEncoded: false)
        let snapshot: JSONValue = .object([
            "id": .string("visual-codex-session"),
            "name": .string("Restore the Codex task surface"),
            "preview": .string("Preserve the task surface while the native shell is restored."),
            "cwd": .string(workspacePath),
            "status": .object([
                "type": .string("active"),
                "activeFlags": .array([.string("turn")])
            ]),
            "turns": .array([
                .object([
                    "id": .string("visual-turn-001"),
                    "status": .string("completed"),
                    "durationMs": .integer(22_000),
                    "itemsView": .string("full"),
                    "items": .array([
                        .object([
                            "id": .string("visual-user-001"),
                            "type": .string("userMessage"),
                            "clientId": .string("visual-client-001"),
                            "content": .array([
                                .object([
                                    "type": .string("text"),
                                    "text": .string("Inspect the native Codex task surface.")
                                ]),
                                .object([
                                    "type": .string("localImage"),
                                    "path": .string("/fixture/visual-context.png"),
                                    "detail": .string("auto")
                                ]),
                                .object([
                                    "type": .string("skill"),
                                    "name": .string("verification"),
                                    "path": .string("/fixture/verification/SKILL.md")
                                ]),
                                .object([
                                    "type": .string("mention"),
                                    "name": .string("Sources"),
                                    "path": .string("/fixture/Sources")
                                ])
                            ])
                        ]),
                        .object([
                            "id": .string("visual-agent-001"),
                            "type": .string("agentMessage"),
                            "phase": .string("final_answer"),
                            "text": .string("""
                                ## Task surface

                                The first pass preserves provider identity for **Codex** and separates the typed timeline from the shared transcript.

                                ```swift
                                let harness = "Codex"
                                // Keep the request attached to its harness.
                                print(harness)
                                ```
                                """)
                        ]),
                        .object([
                            "id": .string("visual-command-001"),
                            "type": .string("commandExecution"),
                            "command": .string("swift test --filter VisualFixtureScenarioTests"),
                            "cwd": .string(workspacePath),
                            "status": .string("completed"),
                            "aggregatedOutput": .string((1...20).map { "Fixture output line \($0): 한글 👩🏽‍💻" }.joined(separator: "\r\n") + "\r\nEND-OF-COMMAND-OUTPUT"),
                            "exitCode": .integer(0),
                            "durationMs": .integer(1608)
                        ]),
                        .object([
                            "id": .string("visual-file-001"),
                            "type": .string("fileChange"),
                            "status": .string("completed"),
                            // App Server shapes: absolute paths, hunks for an update, the whole
                            // text for an added or deleted file; the last one passes the line cap.
                            "changes": .array([
                                .object([
                                    "path": .string(workspacePath + "/Sources/NativeHarnessClient/Views/Conversation/ConversationTimeline.swift"),
                                    "kind": .object(["type": .string("update"), "move_path": .null]),
                                    "diff": .string(
                                        "@@ -12,6 +12,7 @@\n struct ConversationTimeline: View {\n     let source: ConversationSource\n-    let workspace: URL\n+    let workspaceURL: URL\n+    var placement: ConversationPlacement = .task\n     var readingPosition: TranscriptReadingPosition? = nil\n \n     var body: some View {\n"
                                            + "@@ -140,7 +141,9 @@\n"
                                            + (1...6).map { "     // unchanged context line \($0)\n" }.joined()
                                            + "-    Text(path)\n+    CodexFileChangeContent(change: change)\n+        .padding(.vertical, 2)\n+    // 한글 주석도 그대로 보인다\n"
                                    )
                                ]),
                                .object([
                                    "path": .string(workspacePath + "/docs/file-change-notes.md"),
                                    "kind": .object(["type": .string("add")]),
                                    "diff": .string("# File changes\n\nEach file is one row.\nOpen a row to read its diff.\n")
                                ]),
                                .object([
                                    "path": .string(workspacePath + "/Sources/Legacy/OldFileRow.swift"),
                                    "kind": .object(["type": .string("delete")]),
                                    "diff": .string("struct OldFileRow {}\n// replaced by the file change card\n")
                                ]),
                                .object([
                                    "path": .string(workspacePath + "/Tests/Fixtures/GeneratedCases.swift"),
                                    "kind": .object(["type": .string("add")]),
                                    "diff": .string((1...1_012).map { "let case\($0) = \($0)\n" }.joined())
                                ])
                            ])
                        ]),
                        .object([
                            "id": .string("visual-collab-001"),
                            "type": .string("collabAgentToolCall"),
                            "tool": .string("spawn_agent"),
                            "status": .string("completed"),
                            "senderThreadId": .string("visual-codex-session"),
                            "receiverThreadIds": .array([.string("visual-child-001")]),
                            "prompt": .string("Review the task timeline contracts."),
                            "model": .string("gpt-5.6-luna"),
                            "reasoningEffort": .string("max"),
                            "agentsStates": .object([
                                "visual-child-001": .object(["status": .string("completed")])
                            ])
                        ]),
                        .object([
                            "id": .string("visual-unknown-001"),
                            "type": .string("futureCodexItem"),
                            "newField": .string("kept for diagnosis")
                        ])
                    ])
                ]),
                .object([
                    "id": .string("visual-turn-002"),
                    "status": .string("inProgress"),
                    "itemsView": .string("full"),
                    "items": .array([
                        .object([
                            "id": .string("visual-user-002"),
                            "type": .string("userMessage"),
                            "content": .array([.object([
                                "type": .string("text"),
                                "text": .string("Now keep the active turn visible while it waits for a safe approval.")
                            ])])
                        ]),
                        .object([
                            "id": .string("visual-agent-002"),
                            "type": .string("agentMessage"),
                            "phase": .string("commentary"),
                            "text": .string("I am checking the approval boundary and the child-agent handoff…")
                        ]),
                        .object([
                            "id": .string("visual-reasoning-002"),
                            "type": .string("reasoning"),
                            "summary": .array([.string("Keep the request typed and fail closed.")]),
                            "content": .array([.string(
                                "The approval card must answer with the provider's own decision shape, so a generic yes is not enough."
                            )])
                        ]),
                        .object([
                            "id": .string("visual-subagent-002"),
                            "type": .string("subAgentActivity"),
                            "agentThreadId": .string("visual-child-001"),
                            "agentPath": .string("0/0"),
                            "kind": .string("running")
                        ]),
                        .object([
                            "id": .string("visual-mcp-002"),
                            "type": .string("mcpToolCall"),
                            "server": .string("docs"),
                            "tool": .string("search"),
                            "status": .string("inProgress"),
                            "arguments": .object(["query": .string("Codex UI")]),
                            "pluginId": .string("openai-docs")
                        ]),
                        // A completed call from a bundled computer-use plugin: Codex hands the
                        // MCP content blocks through, so the card shows the tool's own text and
                        // screenshot rather than only the call's name.
                        .object([
                            "id": .string("visual-mcp-003"),
                            "type": .string("mcpToolCall"),
                            "server": .string("computer-use"),
                            "tool": .string("app_screenshot"),
                            "status": .string("completed"),
                            "arguments": .object(["app": .string("Yardlet")]),
                            "pluginId": .string("computer-use@openai-bundled"),
                            "durationMs": .integer(1_420),
                            "result": .object([
                                "content": .array([
                                    .object([
                                        "type": .string("text"),
                                        "text": .string("Captured the frontmost Yardlet window at 1512x982.")
                                    ]),
                                    .object([
                                        "type": .string("image"),
                                        "mimeType": .string("image/png"),
                                        "data": .string(onePixelPNGBase64)
                                    ])
                                ])
                            ])
                        ]),
                        .object([
                            "id": .string("visual-web-002"),
                            "type": .string("webSearch"),
                            "query": .string("current Codex desktop task surface")
                        ]),
                        .object([
                            "id": .string("visual-sleep-002"),
                            "type": .string("sleep"),
                            "durationMs": .integer(240)
                        ])
                    ])
                ])
            ])
        ])

        var state = CodexTaskState.empty
        _ = reducer.applySnapshot(snapshot, to: &state)
        _ = reducer.applyNotification(
            method: "turn/plan/updated",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002"),
                "explanation": .string("Keep the active turn safe and observable."),
                "plan": .array([
                    .object(["step": .string("Render the typed request"), "status": .string("completed")]),
                    .object(["step": .string("Wait for an explicit decision"), "status": .string("inProgress")]),
                    .object(["step": .string("Resume the child task"), "status": .string("pending")])
                ])
            ]),
            sequence: 1,
            to: &state
        )
        _ = reducer.applyNotification(
            method: "thread/tokenUsage/updated",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002"),
                "tokenUsage": .object([
                    "total": .object([
                        "inputTokens": .integer(4_920),
                        "cachedInputTokens": .integer(1_100),
                        "cacheWriteInputTokens": .integer(0),
                        "outputTokens": .integer(780),
                        "reasoningOutputTokens": .integer(320),
                        "totalTokens": .integer(5_700)
                    ]),
                    "last": .object([
                        "inputTokens": .integer(1_240),
                        "cachedInputTokens": .integer(210),
                        "cacheWriteInputTokens": .integer(0),
                        "outputTokens": .integer(180),
                        "reasoningOutputTokens": .integer(80),
                        "totalTokens": .integer(1_420)
                    ]),
                    "modelContextWindow": .integer(32_000)
                ])
            ]),
            sequence: 2,
            to: &state
        )
        _ = reducer.applyServerRequest(
            id: .string("visual-command-approval"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002"),
                "itemId": .string("visual-command-approval-item"),
                "command": .string("swift test"),
                "cwd": .string(workspacePath),
                "reason": .string("Run the local verification suite before continuing.")
            ]),
            sequence: 3,
            to: &state
        )
        _ = reducer.applyServerRequest(
            id: .string("visual-permissions-approval"),
            method: "item/permissions/requestApproval",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002"),
                "itemId": .string("visual-permissions-approval-item"),
                "reason": .string("The next step needs explicit network access."),
                "permissions": .object([
                    "network": .object(["enabled": .bool(true)])
                ])
            ]),
            sequence: 4,
            to: &state
        )
        _ = reducer.applyServerRequest(
            id: .string("visual-tool-input"),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002"),
                "itemId": .string("visual-tool-input-item"),
                "questions": .array([
                    .object([
                        "id": .string("verification-target"),
                        "text": .string("Which verification target should the child task use?")
                    ])
                ])
            ]),
            sequence: 5,
            to: &state
        )
        _ = reducer.applyServerRequest(
            id: .string("visual-mcp-elicitation"),
            method: "mcpServer/elicitation/request",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002"),
                "itemId": .string("visual-mcp-elicitation-item"),
                "message": .string("Allow the documentation search extension to continue?")
            ]),
            sequence: 6,
            to: &state
        )
        _ = reducer.applyServerRequest(
            id: .string("visual-dynamic-tool-call"),
            method: "item/tool/call",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002"),
                "itemId": .string("visual-dynamic-tool-call-item"),
                "tool": .string("docs.search")
            ]),
            sequence: 7,
            to: &state
        )
        _ = reducer.applyServerRequest(
            id: .string("visual-auth-refresh"),
            method: "account/chatgptAuthTokens/refresh",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002")
            ]),
            sequence: 8,
            to: &state
        )
        _ = reducer.applyServerRequest(
            id: .string("visual-attestation"),
            method: "attestation/generate",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002")
            ]),
            sequence: 9,
            to: &state
        )
        _ = reducer.applyServerRequest(
            id: .string("visual-current-time"),
            method: "currentTime/read",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002")
            ]),
            sequence: 10,
            to: &state
        )
        _ = reducer.applyServerRequest(
            id: .string("visual-unknown-request"),
            method: "future/unknownRequest",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002")
            ]),
            sequence: 11,
            to: &state
        )
        // A command still running on the active turn, with output streamed so far.
        _ = reducer.applyNotification(
            method: "item/started",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002"),
                "item": .object([
                    "id": .string("visual-command-002"),
                    "type": .string("commandExecution"),
                    "command": .string("swift build"),
                    "cwd": .string(workspacePath),
                    "status": .string("inProgress"),
                    "aggregatedOutput": .null
                ])
            ]),
            sequence: 12,
            to: &state
        )
        for (offset, delta) in ["Building for debugging...\n", "Compiling CodexTaskReducer.swift\n"]
            .enumerated() {
            _ = reducer.applyNotification(
                method: "item/commandExecution/outputDelta",
                params: .object([
                    "threadId": .string("visual-codex-session"),
                    "turnId": .string("visual-turn-002"),
                    "itemId": .string("visual-command-002"),
                    "delta": .string(delta)
                ]),
                sequence: UInt64(13 + offset),
                to: &state
            )
        }
        // A patch the model is still writing, and an MCP call still running.
        _ = reducer.applyNotification(
            method: "item/fileChange/patchUpdated",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002"),
                "itemId": .string("visual-patch-002"),
                "changes": .array([.object([
                    "path": .string(workspacePath + "/Sources/Timeline/CodexTaskReducer.swift"),
                    "kind": .object(["type": .string("update"), "move_path": .null]),
                    "diff": .string("@@ -1 +1 @@\n-old\n+new\n")
                ])])
            ]),
            sequence: 15,
            to: &state
        )
        _ = reducer.applyNotification(
            method: "item/started",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002"),
                "item": .object([
                    "id": .string("visual-mcp-002"),
                    "type": .string("mcpToolCall"),
                    "server": .string("docs"),
                    "tool": .string("search"),
                    "arguments": .object(["query": .string("approval card")]),
                    "status": .string("inProgress")
                ])
            ]),
            sequence: 16,
            to: &state
        )
        // The running turn's diff so far, for the review panel's Last turn.
        _ = reducer.applyNotification(
            method: "turn/diff/updated",
            params: .object([
                "threadId": .string("visual-codex-session"),
                "turnId": .string("visual-turn-002"),
                "diff": .string("""
                    diff --git a/Sources/Timeline/CodexTaskReducer.swift b/Sources/Timeline/CodexTaskReducer.swift
                    index 3b18e51..a1f9c02 100644
                    --- a/Sources/Timeline/CodexTaskReducer.swift
                    +++ b/Sources/Timeline/CodexTaskReducer.swift
                    @@ -12,7 +12,8 @@ struct CodexTaskReducer {
                         func apply(_ event: Event) {
                    -        state.items.append(event.item)
                    +        // Replace the item when the same one arrives again.
                    +        state.items.upsert(event.item)
                             publish()
                         }
                     
                    diff --git a/Tests/CodexTaskReducerTests.swift b/Tests/CodexTaskReducerTests.swift
                    new file mode 100644
                    --- /dev/null
                    +++ b/Tests/CodexTaskReducerTests.swift
                    @@ -0,0 +1,3 @@
                    +final class CodexTaskReducerTests: XCTestCase {
                    +    func testUpsertReplacesTheItem() {}
                    +}

                    """)
            ]),
            sequence: 17,
            to: &state
        )
        return state
    }
}

@MainActor
private final class FixtureSystemNotificationCenter: SystemNotificationCenter {
    private var authorizationValue: SystemNotificationAuthorization

    init(authorization: SystemNotificationAuthorization) {
        authorizationValue = authorization
    }

    func authorization() async -> SystemNotificationAuthorization {
        authorizationValue
    }

    func requestAuthorization() async -> Bool {
        authorizationValue = .authorized
        return true
    }

    func post(title: String, body: String, identifier: String) async {}
}
#endif
