import Foundation

/// The Mac app's model: its stores on disk and the macOS services the engine is handed.
extension AppModel {
    /// The in-window browser's engine, when this build bundles the browser host.
    static let macBrowserClient: @MainActor () -> BrowserHostClient? = {
        MacBrowserHost.isAvailable ? MacBrowserHost.shared.client : nil
    }

    static func live() -> AppModel {
        HostSessionEnvironment.detachFromHostSession()
        // Its one look at the disk, before the first view asks.
        Task.detached(priority: .userInitiated) { _ = MacBrowserHost.isAvailable }
        #if DEBUG
        // A fixture keeps to its own data: nothing below runs for it.
        if let fixture = VisualFixtureScenario.requested() {
            return fixture.makeModel()
        }
        #endif
        // Preferences saved under their earlier keys are copied to their keys first
        // (`PreferenceKeyCarryOver`), and what Yardlet kept of addresses that carried a vault password
        // goes before the task workspaces and the browser host read it (`BrowserFilledValueCleanup`).
        PreferenceKeyCarryOver.run()
        MacAgentToolService.startPreparing()
        BrowserFilledValueCleanup.runAtLaunch()
        LoginShellPath.startReading(shell: ShellLaunchEnvironment.loginShellPath())
        AccountCheckLog.fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: YardletProduct.storageDirectoryName).appending(path: "logs/account-checks.log")
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
            // One record of the versions runtimes reported, for choosing among installs and for
            // the way a runtime runs (Antigravity CLI over ACP or in print mode).
            let runtimeVersions = RuntimeVersionCache(defaults: defaults)
            let runtimeSelections = RuntimeSelectionStore(defaults: defaults, versions: runtimeVersions)
            // Only the app itself cleans Antigravity's folder, here and not in anything a view or a test
            // reaches: a QA run shares the folder with the person's Yardlet, and a fixture runs no `agy`.
            // The sweep counts a running process of any install found, and of the earlier version run in
            // its place, as `agy`, whatever its file is named.
            let antigravitySchemaCopies: AntigravitySchemaCopies? = QABackground.isOn ? nil : .live.counting(
                runtimeSelections.discoveredInstalls(for: .antigravityCLI).flatMap {
                    [$0, CLIRuntimeOverrides.shared.executable(for: .antigravityCLI, requested: $0)]
                })
            antigravitySchemaCopies?.sweep()
            let model = AppModel(
                store: SessionStore(repository: repository),
                runtimeSelections: runtimeSelections,
                // A harness whose new CLI failed Yardlet's check runs the version before it.
                registry: HarnessRegistry(codexEnvironmentManager: codexEnvironmentManager,
                                          runtimeOverrides: .shared, versions: runtimeVersions,
                                          antigravitySchemaCopies: antigravitySchemaCopies),
                connections: ProviderConnectionStore(fileURL: storageRootURL.appending(path: "provider-connections.json"),
                    snapshotCacheURL: storageRootURL.appending(path: ProviderConnectionStore.snapshotCacheFileName),
                    defaults: defaults),
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
                applicationAttention: MacApplicationAttention(),
                browserClient: macBrowserClient
            )
            model.accountAssignments = AccountAssignmentLog(
                fileURL: storageRootURL.appending(path: AccountAssignmentLog.fileName))
            model.personalAgentReadings = PersonalAgentReadings(cache: PersonalAgentCacheFiles.live)
            model.coordinationLog.fileURL = storageRootURL.appending(path: "logs/task-coordination.log")
            return model
        } catch {
            return storageUnavailable(error, codexEnvironmentManager: codexEnvironmentManager,
                                      applicationAttention: MacApplicationAttention(), browserClient: macBrowserClient)
        }
    }
}
