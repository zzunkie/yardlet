import Foundation

/// The Windows app's model: its stores on disk in %LOCALAPPDATA%\Yardlet, where a Windows app keeps
/// what stays on the machine. Platform/Portable stands in for the services the Windows layer does not
/// provide yet, and there is no browser host (docs/PLATFORM_PORTABILITY.md, "The Windows app").
extension AppModel {
    static func live() -> AppModel {
        let codexEnvironmentManager = CodexEnvironmentManager(
            paths: CodexEnvironmentPaths.live()
        )
        do {
            let storageRootURL = try windowsStorageRootURL()
            let defaults = UserDefaults.yardlet
            let repository = try SQLiteSessionRepository(
                databaseURL: storageRootURL.appending(path: "session-index.sqlite3")
            )
            // One record of the versions runtimes reported, for choosing among installs and for
            // the way a runtime runs (Antigravity CLI over ACP or in print mode).
            let runtimeVersions = RuntimeVersionCache(defaults: defaults)
            let model = AppModel(
                store: SessionStore(repository: repository),
                runtimeSelections: RuntimeSelectionStore(defaults: defaults, versions: runtimeVersions),
                registry: HarnessRegistry(codexEnvironmentManager: codexEnvironmentManager,
                                          runtimeOverrides: .shared, versions: runtimeVersions),
                connections: ProviderConnectionStore(fileURL: storageRootURL.appending(path: "provider-connections.json"),
                    snapshotCacheURL: storageRootURL.appending(path: ProviderConnectionStore.snapshotCacheFileName),
                    defaults: defaults),
                modelCatalogs: HarnessModelCatalogStore(fileURL: storageRootURL.appending(path: "model-catalogs.json")),
                codexEnvironmentManager: codexEnvironmentManager,
                codexTimelineItemRepository: FileCodexTimelineItemRepository(
                    directoryURL: storageRootURL.appending(path: "codex-timeline-items")
                ),
                fileTaskIndex: FileTaskIndex(repository: FileTouchRepository(
                    directoryURL: storageRootURL.appending(path: "file-activity"))),
                transcriptRepository: FileTranscriptRepository(
                    directoryURL: storageRootURL.appending(path: "transcripts")
                ),
                composerDraftRepository: FileComposerDraftRepository(
                    directoryURL: storageRootURL.appending(path: "drafts")
                ),
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
                legacyProjectFolderPreferences: LegacyProjectFolderPreferences.stored(in: defaults)
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
                composerDraftRepository: FileComposerDraftRepository(
                    directoryURL: FileManager.default.temporaryDirectory.appending(path: "yardlet-drafts")
                ),
                taskWorkspaceRepository: UserDefaultsTaskWorkspaceRepository(defaults: .yardlet),
                taskSuggestionRepository: UserDefaultsTaskSuggestionRepository(defaults: .yardlet),
                splitRepository: FileSplitRepository.live(),
                projectRepository: FileProjectRepository.live(),
                scheduleRepository: FileScheduledTaskRepository.live(),
                legacyProjectFolderPreferences: LegacyProjectFolderPreferences.stored(in: .yardlet),
                restoresIndexOnLaunch: false
            )
        }
    }

    /// %LOCALAPPDATA%\Yardlet, made on first use.
    private static func windowsStorageRootURL() throws -> URL {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appending(path: YardletProduct.applicationSupportDirectoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
