import Foundation
import Observation
import YardletAgentTools

// Suggested tasks: an agent's `spawn_task` call is a chip in its task's conversation. Start starts
// the task under the one that suggested it, Do it here sends the suggestion to that task, and
// Options opens a new task draft holding it (docs/AGENT_BROWSER_TOOLS.md, "Task suggestion tools").
// The conversation's own record says what was suggested; Yardlet keeps only what became of each
// suggestion, per task, as the Claude app keeps `resolvedBackgroundTaskSuggestions` with a session.

/// What became of one suggestion.
struct TaskSuggestionResolution: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        /// A task was started from the suggestion, by Start or from its draft.
        case started
        /// The person dismissed the chip, or the agent withdrew it with `dismiss_task`.
        case dismissed
        /// Do it here: the suggestion went to the task that suggested it, as the person's message
        /// (the Claude app's `sent_here`).
        case sentHere
    }

    var outcome: Outcome
    var at: Date
    /// The task the suggestion started.
    var startedTaskID: UUID? = nil
}

/// Each task's resolutions, keyed by the suggestion's task ID (`task_1a2b3c4d`). Kept apart from
/// the task index (no schema change) and from the task's window state, which archiving clears:
/// an archived task keeps its resolutions, and only deleting the task removes them.
protocol TaskSuggestionRepository {
    func load(for taskID: UUID) -> [String: TaskSuggestionResolution]
    func save(_ resolutions: [String: TaskSuggestionResolution], for taskID: UUID)
    func remove(for taskID: UUID)
}

struct UserDefaultsTaskSuggestionRepository: TaskSuggestionRepository {
    let defaults: UserDefaults
    let keyPrefix: String

    init(defaults: UserDefaults = .yardlet, keyPrefix: String = "Yardlet.taskSuggestions.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    private struct Snapshot: Codable {
        var version = 1
        var resolutions: [String: TaskSuggestionResolution]
    }

    func load(for taskID: UUID) -> [String: TaskSuggestionResolution] {
        guard let data = defaults.data(forKey: keyPrefix + taskID.uuidString),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return [:] }
        return snapshot.resolutions
    }

    func save(_ resolutions: [String: TaskSuggestionResolution], for taskID: UUID) {
        guard !resolutions.isEmpty else { return remove(for: taskID) }
        guard let data = try? JSONEncoder().encode(Snapshot(resolutions: resolutions)) else { return }
        defaults.set(data, forKey: keyPrefix + taskID.uuidString)
    }

    func remove(for taskID: UUID) {
        defaults.removeObject(forKey: keyPrefix + taskID.uuidString)
    }
}

final class InMemoryTaskSuggestionRepository: TaskSuggestionRepository {
    private(set) var resolutionsByTask: [UUID: [String: TaskSuggestionResolution]] = [:]

    init(_ resolutionsByTask: [UUID: [String: TaskSuggestionResolution]] = [:]) {
        self.resolutionsByTask = resolutionsByTask
    }

    func load(for taskID: UUID) -> [String: TaskSuggestionResolution] { resolutionsByTask[taskID] ?? [:] }
    func save(_ resolutions: [String: TaskSuggestionResolution], for taskID: UUID) {
        resolutionsByTask[taskID] = resolutions.isEmpty ? nil : resolutions
    }
    func remove(for taskID: UUID) { resolutionsByTask[taskID] = nil }
}

/// The resolutions the conversation's chips read. A task's are read from the repository the first
/// time a chip asks, and written back on every change.
@MainActor @Observable
final class TaskSuggestionStore {
    /// The Claude app keeps a session's latest 100 resolutions.
    static let keptPerTask = 100

    /// Changes whenever a resolution does, so a chip that read one draws again.
    private(set) var revision = 0
    @ObservationIgnored private var loaded: [UUID: [String: TaskSuggestionResolution]] = [:]
    @ObservationIgnored private let repository: any TaskSuggestionRepository
    @ObservationIgnored var now: () -> Date = Date.init

    init(repository: any TaskSuggestionRepository) {
        self.repository = repository
    }

    func resolution(of suggestionID: String, in taskID: UUID) -> TaskSuggestionResolution? {
        _ = revision
        return resolutions(for: taskID)[suggestionID]
    }

    /// Hides the chip. A suggestion already started stays started; the earlier resolution is
    /// returned so `dismiss_task` can say what happened.
    @discardableResult
    func dismiss(_ suggestionID: String, in taskID: UUID) -> TaskSuggestionResolution? {
        let previous = resolutions(for: taskID)[suggestionID]
        guard previous == nil else { return previous }
        update(taskID) { $0[suggestionID] = TaskSuggestionResolution(outcome: .dismissed, at: now()) }
        return nil
    }

    /// The suggestion started `startedTaskID`.
    func markStarted(_ suggestionID: String, in taskID: UUID, startedTaskID: UUID) {
        progressByKey[ProgressKey(taskID: taskID, suggestionID: suggestionID)] = nil
        update(taskID) {
            $0[suggestionID] = TaskSuggestionResolution(outcome: .started, at: now(), startedTaskID: startedTaskID)
        }
    }

    /// Do it here: the suggestion went to the task that suggested it.
    func markSentHere(_ suggestionID: String, in taskID: UUID) {
        progressByKey[ProgressKey(taskID: taskID, suggestionID: suggestionID)] = nil
        update(taskID) { $0[suggestionID] = TaskSuggestionResolution(outcome: .sentHere, at: now()) }
    }

    /// What a chip's Start or Do it here is doing, or why it did not happen. Only while the app runs.
    enum Progress: Equatable, Sendable {
        case starting
        case sending
        case failed(String)

        var isUnderWay: Bool { self == .starting || self == .sending }
    }

    private struct ProgressKey: Hashable {
        var taskID: UUID
        var suggestionID: String
    }

    private var progressByKey: [ProgressKey: Progress] = [:]
    private var choiceByKey: [ProgressKey: TaskSuggestionStartChoice] = [:]

    /// What the person chose in the chip's Options, which its Start starts with. Only while the
    /// app runs, as the Claude app keeps a card's options.
    func choice(of suggestionID: String, in taskID: UUID) -> TaskSuggestionStartChoice? {
        choiceByKey[ProgressKey(taskID: taskID, suggestionID: suggestionID)]
    }

    func setChoice(_ value: TaskSuggestionStartChoice?, of suggestionID: String, in taskID: UUID) {
        let key = ProgressKey(taskID: taskID, suggestionID: suggestionID)
        guard choiceByKey[key] != value else { return }
        choiceByKey[key] = value
    }

    func progress(of suggestionID: String, in taskID: UUID) -> Progress? {
        progressByKey[ProgressKey(taskID: taskID, suggestionID: suggestionID)]
    }

    func setProgress(_ value: Progress?, of suggestionID: String, in taskID: UUID) {
        progressByKey[ProgressKey(taskID: taskID, suggestionID: suggestionID)] = value
    }

    /// The task was deleted: its suggestions go with it. Archiving keeps them.
    func remove(for taskID: UUID) {
        loaded[taskID] = nil
        repository.remove(for: taskID)
        revision += 1
    }

    private func resolutions(for taskID: UUID) -> [String: TaskSuggestionResolution] {
        if let resolutions = loaded[taskID] { return resolutions }
        let resolutions = repository.load(for: taskID)
        loaded[taskID] = resolutions
        return resolutions
    }

    private func update(_ taskID: UUID, _ change: (inout [String: TaskSuggestionResolution]) -> Void) {
        var resolutions = resolutions(for: taskID)
        change(&resolutions)
        if resolutions.count > Self.keptPerTask {
            let oldest = resolutions.sorted { $0.value.at < $1.value.at }.prefix(resolutions.count - Self.keptPerTask)
            for (id, _) in oldest { resolutions[id] = nil }
        }
        loaded[taskID] = resolutions
        repository.save(resolutions, for: taskID)
        revision += 1
    }
}

/// A new task draft opened from a suggestion's Options: where the suggestion came from, so the task
/// the draft starts is that suggestion's (the chip reads "Started", the new task nests under the
/// one that suggested it, and keeps the suggestion's title while the prompt is still the agent's).
struct NewTaskSuggestionOrigin: Codable, Equatable, Sendable {
    var sourceTaskID: UUID
    var suggestionID: String
    var title: String?
    var prompt: String
    /// The task the started one nests under when the agent named one (`parent_task_id`); nil nests
    /// it under the task that suggested it.
    var parentTaskID: UUID? = nil

    /// The suggestion's title, while the draft still holds the agent's whole prompt.
    func title(for submittedPrompt: String) -> String? {
        guard let title, !title.isEmpty, !prompt.isEmpty, submittedPrompt.contains(prompt) else { return nil }
        return title
    }
}

/// Where a suggestion's task starts, as the Claude app starts one from its chip (`spawnedFrom`): in
/// the suggesting task's repository folder — the one its worktree came from when it works in one —
/// and that folder's project, in a new worktree when the agent asked for one, the suggesting task
/// itself works in a worktree, or the person starts that project's tasks in one. Only a folder in
/// Git can have a worktree, so one outside Git starts locally whatever was asked, as the new-task
/// screen starts it. A chat's suggestion starts another chat.
struct SuggestedTaskPlace: Equatable {
    /// Nil starts a chat, in a folder made for it.
    var folder: URL?
    var project: Project?
    var startsInNewWorktree: Bool

    static func of(
        _ suggestion: ConversationTaskSuggestion,
        from source: SessionRecord,
        in projects: [Project],
        worktreeByDefault: (UUID) -> Bool = { _ in false },
        isRepository: (URL) -> Bool = SuggestedTaskPlace.isInRepository,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SuggestedTaskPlace {
        // A chat the agent asked for (`chat`), as New Task's "No project".
        if suggestion.startsAsChat {
            return SuggestedTaskPlace(folder: nil, project: nil, startsInNewWorktree: false)
        }
        // Another project's root the agent named (`cwd`): a fresh worktree under it, as the Claude
        // app starts one, when it is a repository; else the folder itself.
        if let cwd = suggestion.cwd {
            let folder = URL(filePath: cwd, directoryHint: .isDirectory).standardizedFileURL
            return SuggestedTaskPlace(folder: folder, project: ProjectProjection.project(containingRoot: folder, in: projects),
                                      startsInNewWorktree: isRepository(folder))
        }
        if ProjectProjection.isChat(source, in: projects, home: home) {
            return SuggestedTaskPlace(folder: nil, project: nil, startsInNewWorktree: false)
        }
        let origin = source.originWorkspaceURL
        // A worktree's own project (the Claude app's `.claude/worktrees/…` sessions are kept hidden)
        // is not where its children go; the repository's project is.
        let project = origin.flatMap { ProjectProjection.project(containingRoot: $0, in: projects) }
            ?? ProjectProjection.project(for: source, in: projects)
        var folder = origin ?? source.workspaceURL
        if let project, !project.contains(root: folder) { folder = project.primaryRoot }
        let worktree = suggestion.startsInNewWorktree || origin != nil || project.map { worktreeByDefault($0.id) } == true
        return SuggestedTaskPlace(folder: folder, project: project, startsInNewWorktree: worktree && isRepository(folder))
    }

    /// Whether `folder` can have a worktree: it is in a Git checkout, read as the new-task screen
    /// reads it (`GitWorktreeOriginResolver.isInRepository`), without starting Git.
    static func isInRepository(_ folder: URL) -> Bool {
        GitWorktreeOriginResolver.isInRepository(folder)
    }
}

/// Where a suggestion's Start starts the task: the task it nests under, whose harness, account,
/// model, effort and permission mode it takes — the task that suggested it, or the one the agent
/// named (`parent_task_id`) — and the place.
struct SuggestedTaskStart: Equatable {
    var parent: SessionRecord
    var place: SuggestedTaskPlace
}

/// What a suggestion's Start starts the task with: the harness, the options the task keeps (model,
/// effort, permission mode), where, and the account. Without a choice in the chip's Options, the
/// task it nests under gives the harness, options and account and `SuggestedTaskStart` the place.
struct TaskSuggestionStartChoice: Equatable {
    var harness: HarnessKind
    var providerOptions: [String: String]
    var place: SuggestedTaskPlace
    /// The account the task starts on; nil is the harness's own login.
    var connection: ProviderConnection? = nil

    /// Starting in `folder` (nil starts a chat) and its project. A new worktree stays chosen where
    /// the folder can have one.
    func moving(to folder: URL?, project: Project?, isRepository: (URL) -> Bool) -> TaskSuggestionStartChoice {
        var choice = self
        choice.place = SuggestedTaskPlace(folder: folder, project: project,
                                          startsInNewWorktree: place.startsInNewWorktree && folder.map(isRepository) == true)
        return choice
    }

    /// Local or a new worktree, as the new-task screen's control chooses; only a folder in Git has one.
    func startingInNewWorktree(_ startsInNewWorktree: Bool, isRepository: (URL) -> Bool) -> TaskSuggestionStartChoice {
        var choice = self
        choice.place.startsInNewWorktree = startsInNewWorktree && place.folder.map(isRepository) == true
        return choice
    }
}

/// Do it here's message: the Claude app's "Do this task here: “{title}”", naming the suggestion
/// by its title, else its summary, else its prompt's first line, in quotes of its own.
enum TaskSuggestionHereMessage {
    static func text(for suggestion: ConversationTaskSuggestion) -> String {
        func cleaned(_ value: String?) -> String {
            let line = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"[\p{Quotation_Mark}]"#, with: "'", options: .regularExpression)
            return line.count <= 200 ? line : String(line.prefix(199)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }
        let name = [cleaned(suggestion.title), cleaned(suggestion.tldr)].first { !$0.isEmpty }
            ?? suggestion.prompt.split(separator: "\n", maxSplits: 20, omittingEmptySubsequences: false)
                .prefix(20).map { cleaned(String($0)) }.first { !$0.isEmpty } ?? ""
        return L10n.format("Do this task here: “%@”", name)
    }
}

/// `spawn_task` and `dismiss_task` as the app answers them. Neither starts a turn or touches a
/// file: a suggestion only becomes a chip in the conversation that called it.
enum TaskSuggestionToolCall {
    struct Suggestion: Equatable {
        var title: String?
        var prompt: String
        var tldr: String?
        var startsInNewWorktree: Bool
        /// Another project's root (`cwd`): an absolute path without `.` or `..` segments.
        var cwd: String? = nil
        /// A task id from list_tasks, or "self" (`parent_task_id`).
        var parentTaskReference: String? = nil
        /// The task starts as a chat, with no project (`chat`).
        var startsAsChat = false
    }

    /// The suggestion a call's arguments describe, cleaned as the Claude app cleans them, or why
    /// they describe none.
    static func suggestion(from arguments: JSONValue) -> Result<Suggestion, SuggestionError> {
        let prompt = (arguments["prompt"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .failure(.emptyPrompt) }
        guard prompt.count <= TaskSuggestionToolCatalog.maximumPromptLength else {
            return .failure(.promptTooLong(prompt.count))
        }
        func cleaned(_ key: String, limit: Int) -> String? {
            let text = String((arguments[key]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
            return text.isEmpty ? nil : text
        }
        let cwd = cleaned(TaskSuggestionToolCatalog.cwd, limit: 4_096)
        let parent = cleaned(TaskSuggestionToolCatalog.parentTaskID, limit: 64)
        if cwd != nil, parent != nil { return .failure(.cwdAndParent) }
        let chat = arguments[TaskSuggestionToolCatalog.chat]?.boolValue == true
        if chat, cwd != nil || parent != nil { return .failure(.chatAndPlace) }
        if let cwd {
            // The Claude app's checks, before Yardlet looks for the folder.
            guard PathRules.current.isAbsolute(cwd) else { return .failure(.cwdNotAbsolute(cwd)) }
            guard !PathRules.current.names(cwd).contains(where: { $0 == "." || $0 == ".." }) else {
                return .failure(.cwdDotSegment)
            }
        }
        if let parent, parent != TaskSuggestionToolCatalog.selfReference, UUID(uuidString: parent) == nil {
            return .failure(.parentNotATaskID(parent))
        }
        return .success(Suggestion(
            title: cleaned("title", limit: TaskSuggestionToolCatalog.maximumTitleLength),
            prompt: prompt,
            tldr: cleaned("tldr", limit: TaskSuggestionToolCatalog.maximumSummaryLength),
            startsInNewWorktree: !chat && arguments["useWorktree"]?.boolValue == true,
            cwd: cwd,
            parentTaskReference: parent,
            startsAsChat: chat
        ))
    }

    enum SuggestionError: Error, Equatable {
        case emptyPrompt
        case promptTooLong(Int)
        case cwdAndParent
        case chatAndPlace
        case cwdNotAbsolute(String)
        case cwdDotSegment
        case parentNotATaskID(String)

        var message: String {
            switch self {
            case .emptyPrompt: "prompt is required and cannot be empty."
            case let .promptTooLong(count):
                "prompt is too long (\(count) characters; the limit is \(TaskSuggestionToolCatalog.maximumPromptLength))."
            case .cwdAndParent:
                "Give cwd or parent_task_id, not both: a task nested under another starts in that task's project."
            case .chatAndPlace:
                "chat starts the task with no project, so it takes neither cwd nor parent_task_id."
            case let .cwdNotAbsolute(cwd):
                "cwd must be an absolute path (got \"\(cwd)\"). Omit cwd to use the current project."
            case .cwdDotSegment:
                "cwd must not contain \".\" or \"..\" segments. Pass the plain absolute path, or omit cwd to use the "
                    + "current project."
            case let .parentNotATaskID(value):
                "parent_task_id must be a task id from list_tasks or \"self\" (got \"\(value)\")."
            }
        }
    }

    /// The answer to one call from `taskID`'s harness. `place` says where Start starts the task when
    /// the agent named a place, as the answer words it (`TaskSuggestionToolCatalog.notedResult`); the
    /// app has checked that the place exists.
    @MainActor
    static func respond(
        to tool: String, arguments: JSONValue, taskID: UUID, store: TaskSuggestionStore, place: String? = nil,
        newTaskID: () -> String = TaskSuggestionToolCatalog.newTaskID
    ) -> AgentToolResult {
        switch tool {
        case TaskSuggestionToolCatalog.spawnTask:
            switch suggestion(from: arguments) {
            case let .failure(error):
                return .error(error.message)
            case .success:
                // The chip is drawn from this call in the conversation; nothing is kept until the
                // person starts or dismisses it.
                return .text(TaskSuggestionToolCatalog.notedResult(taskID: newTaskID(), place: place))
            }
        case TaskSuggestionToolCatalog.dismissTask:
            let id = (arguments["task_id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard TaskSuggestionToolCatalog.isTaskID(id) else {
                return .error("task_id must be the id returned by spawn_task (format: task_xxxxxxxx).")
            }
            switch store.dismiss(id, in: taskID)?.outcome {
            case nil:
                return .text("Task \(id) withdrawn \u{2014} the chip is no longer shown to the user. Continue your current work.")
            case .started:
                return .text("Task \(id) was already started by the user \u{2014} it's no longer pending, so there is "
                    + "nothing to withdraw. Continue your current work.")
            case .dismissed:
                return .text("Task \(id) was already dismissed \u{2014} the chip is no longer shown. Do not re-flag it.")
            case .sentHere:
                return .text("The user asked for task \(id) to be done here, in this conversation \u{2014} it's no longer "
                    + "pending, so there is nothing to withdraw.")
            }
        default:
            return .error("Unknown tool: \(tool)")
        }
    }
}
