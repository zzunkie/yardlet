import Foundation

/// The Mac app's model: its stores on disk and the macOS services the engine is handed.
extension AppModel {
    /// The in-window browser's engine, when this build bundles the browser host.
    static let macBrowserClient: @MainActor () -> BrowserHostClient? = {
        MacBrowserHost.isAvailable ? MacBrowserHost.shared.client : nil
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
                restoresIndexOnLaunch: false,
                browserClient: macBrowserClient
            )
        }
    }
}
