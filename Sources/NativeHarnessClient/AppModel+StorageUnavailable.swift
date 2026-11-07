import Foundation

/// The model when Yardlet's task index cannot be opened at launch.
///
/// Without the index Yardlet does not know which tasks exist, so nothing kept beside it may be read
/// against an empty list and written back: the window layout would lose every tab, schedules would
/// run for tasks it cannot see, and the Claude app's and Codex's conversations would come in again as
/// new tasks. Everything Yardlet keeps per task stays in memory for this run, the launch work that
/// follows the restored index does not run (`hasRestoredIndex` stays false), and the window says why
/// until Yardlet is restarted. Settings and sign-ins are left as they are.
extension AppModel {
    static func storageUnavailable(
        _ error: any Error,
        codexEnvironmentManager: CodexEnvironmentManager?,
        applicationAttention: (any ApplicationAttention)? = nil,
        browserClient: @escaping @MainActor () -> BrowserHostClient? = { nil }
    ) -> AppModel {
        // The per-task records Yardlet otherwise keeps in its settings go to a domain of this run's own
        // in the temporary folder: an absolute suite name keeps it in that file (as `UserDefaults.yardlet`
        // does in a test process), and only the global domain or the app's own name is refused.
        let scratch = UserDefaults(suiteName: FileManager.default.temporaryDirectory
            .appending(path: "yardlet-storage-unavailable-\(UUID().uuidString)").path(percentEncoded: false))!
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(),
            codexEnvironmentManager: codexEnvironmentManager,
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: scratch),
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: scratch),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: scratch),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: scratch),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: scratch),
            composerDraftRepository: InMemoryComposerDraftRepository(),
            taskWorkspaceRepository: InMemoryTaskWorkspaceRepository(),
            taskSuggestionRepository: InMemoryTaskSuggestionRepository(),
            splitRepository: InMemorySplitRepository(),
            projectRepository: InMemoryProjectRepository(),
            scheduleRepository: InMemoryScheduledTaskRepository(),
            applicationAttention: applicationAttention,
            restoresIndexOnLaunch: false,
            browserClient: browserClient
        )
        model.storageFailure = L10n.format(
            "Yardlet could not open its task list, so it shows and saves no tasks until it is restarted: %@",
            error.localizedDescription
        )
        return model
    }
}
