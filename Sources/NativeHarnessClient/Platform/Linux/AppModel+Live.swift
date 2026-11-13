import Foundation

/// The Linux host's model: its stores in the data folder (`LinuxHostPaths`), Platform/Portable for the services the
/// Linux layer does not provide, and no browser host or screens (docs/LINUX_HOST.md).
extension AppModel {
    static func live() -> AppModel {
        // The person's login shell sets the PATH the harnesses are found on; a systemd service has none of it
        // (docs/LINUX_HOST.md, "Finding the harnesses").
        LoginShellPath.startReading(shell: ShellLaunchEnvironment.loginShellPath())
        let codexEnvironmentManager = CodexEnvironmentManager(
            paths: CodexEnvironmentPaths.live()
        )
        do {
            let storageRootURL = try LinuxHostPaths.dataRoot()
            AccountCheckLog.fileURL = storageRootURL.appending(path: "logs/account-checks.log")
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
                legacyProjectFolderPreferences: LegacyProjectFolderPreferences.stored(in: defaults),
                applicationAttention: nil
            )
            model.accountAssignments = AccountAssignmentLog(
                fileURL: storageRootURL.appending(path: AccountAssignmentLog.fileName))
            model.followRuntimeChoices()
            return model
        } catch {
            return storageUnavailable(error, codexEnvironmentManager: codexEnvironmentManager)
        }
    }
}
