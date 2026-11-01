import Foundation
import Observation

/// The app owns the home draft, including an in-flight start, across navigation.
/// Preparing or restoring a draft never starts a harness or sends a request.
@MainActor
@Observable
final class NewTaskDraft {
    var text = "" {
        didSet {
            if !text.utf16.elementsEqual(oldValue.utf16) { savedSelection = nil }
            // Emptying the draft lets go of the suggestion it was opened from.
            if suggestion != nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { suggestion = nil }
            if text != oldValue { wasRestored = false; onChange?() }
        }
    }
    /// The suggested task this draft was opened from (a chip's Options opened one until 2026-10-22;
    /// a draft saved then still holds it). The task the draft starts is that suggestion's.
    var suggestion: NewTaskSuggestionOrigin? { didSet { if suggestion != oldValue { onChange?() } } }
    /// Pasted, dropped or mentioned inputs that travel with the first message.
    var attachments: [CodexUserInput] = [] { didSet { if attachments != oldValue { onChange?() } } }
    var notice: String?
    var workspaceURL: URL? {
        didSet {
            // Choosing a folder or a project is choosing not to start a chat.
            if workspaceURL != nil { startsChat = false }
            if workspaceURL != oldValue { onChange?() }
        }
    }
    /// The project whose primary folder seeds `workspaceURL`. A folder chosen directly leaves
    /// this nil, and the task still joins the project that owns that folder.
    var projectID: UUID? { didSet { if projectID != oldValue { onChange?() } } }
    /// The task starts as a chat with no project, in a new folder made for it when it starts
    /// (`ChatWorkspaces`), as the Codex app starts a chat. There is then no folder to choose.
    private(set) var startsChat = false { didSet { if startsChat != oldValue { onChange?() } } }

    /// Starts the next task as a chat instead of in a project's folder.
    func chooseChat() {
        workspaceURL = nil
        projectID = nil
        startsChat = true
    }
    var harness: HarnessKind? { didSet { if harness != oldValue { onChange?() } } }
    var connectionSelection: [HarnessKind: String] = [:] {
        didSet { if connectionSelection != oldValue { onChange?() } }
    }
    /// The Local / New worktree choice, remembered per project the way the Codex app remembers
    /// it. A project that is not listed starts tasks locally.
    private(set) var worktreeProjectIDs: Set<UUID> = [] {
        didSet { if worktreeProjectIDs != oldValue { onChange?() } }
    }
    /// The model and effort chosen for new tasks, remembered per harness as the other new-task
    /// choices are. A harness without one starts on what its own settings name.
    var modelChoices: [HarnessKind: NewTaskModelChoice] = [:] {
        didSet { if modelChoices != oldValue { onChange?() } }
    }
    private(set) var wasRestored = false
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onPreparation: (() -> Void)?
    // Like task input, home selection is transient and belongs to the exact draft text.
    @ObservationIgnored private var savedSelection: NSRange?

    var selection: Range<String.Index>? {
        savedSelection.flatMap { Range($0, in: text) }
    }

    func rememberSelection(_ range: NSRange, in value: String) {
        guard value.utf16.elementsEqual(text.utf16), Range(range, in: text) != nil else { return }
        savedSelection = range
    }

    /// A suggested task's prompt in the draft, in the project and harness of the task that suggested
    /// it (Codex "Use suggestion"). Words already in the draft stay, before the prompt, and a prompt
    /// already there is not added twice.
    func takeSuggestedPrompt(_ prompt: String, project: Project?, harness: HarnessKind) {
        insertPrompt(prompt)
        if let project {
            projectID = project.id
            workspaceURL = project.primaryRoot
        }
        self.harness = harness
    }

    /// A prompt a suggestion or a new-task row offers, in the draft: words already there stay,
    /// before it, and a prompt already there is not added twice. Nothing is sent.
    func insertPrompt(_ prompt: String) {
        guard !prompt.isEmpty, !text.contains(prompt) else { return }
        let kept = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = kept.isEmpty ? prompt : kept + "\n\n" + prompt
    }

    func startsInNewWorktree(projectID: UUID?) -> Bool {
        projectID.map(worktreeProjectIDs.contains) ?? false
    }

    func setStartsInNewWorktree(_ startsInNewWorktree: Bool, projectID: UUID) {
        if startsInNewWorktree {
            worktreeProjectIDs.insert(projectID)
        } else {
            worktreeProjectIDs.remove(projectID)
        }
    }

    private(set) var creationFailed = false
    /// Why the last start failed, when the failure came with a reason worth showing beside the
    /// draft, such as Git refusing to make the worktree.
    private(set) var creationError: String?
    private var pendingSubmission: Submission?
    private var hasPreparedWorkspace = false { didSet { if hasPreparedWorkspace != oldValue { onChange?() } } }

    var snapshot: HomeDraftSnapshot {
        HomeDraftSnapshot(text: text, workspaceURL: workspaceURL, projectID: projectID,
                          startsChat: startsChat ? true : nil,
                          harness: harness,
                          hasPreparedWorkspace: hasPreparedWorkspace,
                          connectionSelection: connectionSelection.isEmpty ? nil : connectionSelection,
                          attachments: attachments.isEmpty ? nil : attachments,
                          worktreeProjectIDs: worktreeProjectIDs.isEmpty ? nil : worktreeProjectIDs,
                          modelChoices: modelChoices.isEmpty ? nil : modelChoices,
                          suggestion: suggestion)
    }

    func apply(_ snapshot: HomeDraftSnapshot) {
        savedSelection = nil
        let callback = onChange
        onChange = nil
        text = snapshot.text
        attachments = snapshot.attachments ?? []
        notice = nil
        workspaceURL = snapshot.workspaceURL
        projectID = snapshot.projectID
        startsChat = snapshot.workspaceURL == nil && snapshot.startsChat == true
        harness = snapshot.harness
        connectionSelection = snapshot.connectionSelection ?? [:]
        worktreeProjectIDs = snapshot.worktreeProjectIDs ?? []
        modelChoices = snapshot.modelChoices ?? [:]
        suggestion = snapshot.suggestion
        hasPreparedWorkspace = snapshot.hasPreparedWorkspace
        wasRestored = !text.isEmpty
        onChange = callback
    }

    var isCreating: Bool { pendingSubmission != nil }

    struct Submission {
        let id = UUID()
        let originalText: String
        let attachments: [CodexUserInput]
        let harness: HarnessKind
        /// Nil starts a chat, in a folder made for it when it starts.
        let workspaceURL: URL?
        let projectID: UUID?
        let runtimeURL: URL
        var connection: ProviderConnection?
        /// Start in a new linked worktree of `workspaceURL`'s repository instead of the folder itself.
        var startsInNewWorktree = false
        /// The model and effort the new task keeps as its own, so its first turn runs on them.
        var providerOptions: [String: String] = [:]
        /// The suggested task the draft was opened from.
        var suggestion: NewTaskSuggestionOrigin? = nil
        /// A name the task keeps as the person's own, such as a schedule's run ("{name} · {time}").
        var titleOverride: String? = nil
        /// Whether the window goes to the new task. A scheduled run starts beside the person's work.
        var selectsTask = true
        /// The task the new one nests under in the sidebar.
        var parentTaskID: UUID? = nil
        /// Sent from the new-task screen that shows the draft's terminal, browser and side panel: the
        /// task takes them over as soon as it exists (`AppModel.handOffDraftWorkspace`).
        var takesDraftWorkspace = false

        var startsChat: Bool { workspaceURL == nil }
        var prompt: String { originalText.trimmingCharacters(in: .whitespacesAndNewlines) }
        /// The suggestion's title while the draft still holds the agent's prompt, as the Claude app
        /// names a task started from a chip; otherwise the first words of the request.
        var title: String {
            titleOverride ?? suggestion?.title(for: prompt) ?? SessionTitleProjection.provisionalTitle(from: prompt)
        }
        /// A suggestion's title stays the task's own, as a name the person gave it would; nil leaves
        /// the title provisional until the harness names the task.
        var titleOrigin: SessionTitleOrigin? {
            titleOverride != nil || suggestion?.title(for: prompt) != nil ? .manual : nil
        }
    }

    /// A draft left in a project that has since been hidden or removed starts over in the first
    /// visible project instead of offering a destination the sidebar no longer shows.
    func dropUnavailableProject(visible projects: [Project]) {
        guard let workspaceURL else { return }
        if let projectID, projects.contains(where: { $0.id == projectID }) { return }
        if projectID == nil, projects.contains(where: { $0.contains(root: workspaceURL) }) { return }
        self.workspaceURL = projects.first?.primaryRoot
        self.projectID = projects.first?.id
    }

    /// A project seeds both the destination project and its primary folder, so an untouched
    /// draft starts in the folder that project's tasks run in.
    func prepare(defaultProject: Project?, availableHarnesses: [HarnessKind]) {
        prepare(
            defaultWorkspaceURL: defaultProject?.primaryRoot,
            defaultProjectID: defaultProject?.id,
            availableHarnesses: availableHarnesses
        )
    }

    func prepare(
        defaultWorkspaceURL: URL?,
        defaultProjectID: UUID? = nil,
        availableHarnesses: [HarnessKind]
    ) {
        let previous = snapshot
        let callback = onChange
        onChange = nil
        defer {
            onChange = callback
            if snapshot != previous { onPreparation?() }
        }
        if !hasPreparedWorkspace {
            if workspaceURL == nil, !startsChat {
                workspaceURL = defaultWorkspaceURL
                projectID = defaultProjectID
            }
            hasPreparedWorkspace = true
        }
        // A selected harness keeps its identity even when its runtime disappears.
        if harness == nil { harness = availableHarnesses.first }
    }

    func canCreate(runtimeURL: URL?) -> Bool {
        (workspaceURL != nil || startsChat) && harness != nil && runtimeURL != nil
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    func beginSubmission(
        runtimeURL: URL?,
        connection: ProviderConnection? = nil,
        startsInNewWorktree: Bool = false
    ) -> Submission? {
        guard canCreate(runtimeURL: runtimeURL), let harness, let runtimeURL else { return nil }
        let submission = Submission(
            originalText: text, attachments: attachments, harness: harness, workspaceURL: workspaceURL,
            projectID: workspaceURL == nil ? nil : projectID, runtimeURL: runtimeURL, connection: connection,
            // A chat's folder is made for it; it has no repository to make a worktree of.
            startsInNewWorktree: workspaceURL != nil && startsInNewWorktree,
            providerOptions: modelChoices[harness]?.providerOptions(for: harness) ?? [:],
            suggestion: suggestion
        )
        pendingSubmission = submission
        creationFailed = false
        creationError = nil
        return submission
    }

    func complete(_ submission: Submission, succeeded: Bool, error: String? = nil) {
        guard pendingSubmission?.id == submission.id else { return }
        pendingSubmission = nil
        creationFailed = !succeeded
        creationError = succeeded ? nil : error
        // The suggestion has its task now, even when edits made during the start stay in the draft.
        if succeeded, suggestion != nil, suggestion == submission.suggestion { suggestion = nil }
        // A late result must not erase input edited while the start was pending.
        if succeeded, text == submission.originalText, attachments == submission.attachments,
           harness == submission.harness,
           workspaceURL?.standardizedFileURL == submission.workspaceURL?.standardizedFileURL {
            text = ""
            attachments = []
            notice = nil
        }
    }
}
