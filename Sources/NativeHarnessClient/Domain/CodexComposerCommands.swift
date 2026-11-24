import Foundation

/// The official Codex app's composer slash commands that a Yardlet Codex task can run.
///
/// Source: the Codex desktop app (`com.openai.codex` 26.930.51102) registers each command with
/// `{id, title, description, requiresEmptyComposer, enabled, onSelect | submenu}`. The menu
/// drops commands whose `enabled` is false, hides `requiresEmptyComposer` commands while the
/// composer holds other text, lists the rest by group and then title, and searches the title,
/// ID and aliases. Yardlet keeps the IDs, wording and availability, and runs each command with
/// the App Server request or Yardlet surface it already has. Commands that need a surface
/// Yardlet does not have (MCP status list, feedback, usage & billing, goals, …) are not offered.
enum CodexComposerCommand: Equatable, Hashable, Sendable {
    /// `thread/compact/start`.
    case compact
    /// The review target sheet, then `review/start`.
    case codeReview
    /// `thread/fork` into a new task in the same workspace.
    case fork
    /// A blank task in the same project, account and storage scope.
    case newChat
    case rename
    case pin
    case archive
    /// The composer's model picker, opened at its model list.
    case model
    /// The composer's model picker, opened at its effort list.
    case reasoning
    /// Turns a model's advertised service tier (Fast) on or off for the next turn.
    case serviceTier(String)
    /// Turns the provider's Plan collaboration mode on or off for the next turn.
    case planMode
    /// Sends the Codex `/init` prompt as an ordinary turn unless AGENTS.md exists.
    case initialize
    case sideChat
    /// The status panel above the composer: chat ID, context usage and the account's rate limits.
    case status
    /// Adds the skill to the draft, as the Skills menu does. `name` is the command-safe name.
    case skill(name: String, path: String)

    /// The Codex app's command ID, which Yardlet also uses as the typed `/name`.
    var name: String {
        switch self {
        case .compact: "compact"
        case .codeReview: "review-mode"
        case .fork: "fork"
        case .newChat: "new"
        case .rename: "rename"
        case .pin: "pin"
        case .archive: "archive"
        case .model: "model"
        case .reasoning: "reasoning"
        case let .serviceTier(tier): "service-tier:\(tier)"
        case .planMode: "plan-mode"
        case .initialize: "init"
        case .sideChat: "side"
        case .status: "status"
        case let .skill(name, _): "skill:\(name)"
        }
    }

    /// Commands the Codex app hides while the composer holds other text.
    var requiresEmptyComposer: Bool {
        switch self {
        case .compact, .codeReview, .fork, .newChat, .rename, .pin, .archive, .initialize: true
        case .model, .reasoning, .serviceTier, .planMode, .sideChat, .status, .skill: false
        }
    }
}

/// What decides which Codex commands a task's composer offers and how they read.
struct CodexComposerCommandContext: Equatable {
    /// The task is bound to a Codex thread (it has sent its first message or was resumed).
    var hasThread = false
    var isRunning = false
    /// The composer holds text other than the slash being typed, or edits a sent message.
    var hasDraftContent = false
    var canOpenSideChat = false
    var isGitRepository = false
    var workspaceURL: URL?
    var modelCatalog = CodexModelCatalog()
    var modes: [CodexCollaborationPreset] = []
    var selectedModeID: CodexCollaborationPreset.ID?
    var tokenUsage: CodexThreadTokenUsage?
    var skills: [CodexSkillSummary] = []

    var isPlanModeActive: Bool {
        modes.first { $0.id == selectedModeID }?.mode == "plan"
    }

    /// The Codex app's context fullness: the last turn's tokens against the model window.
    var contextPercent: Int? {
        guard let usage = tokenUsage, let window = usage.modelContextWindow, window > 0,
              usage.last.totalTokens >= 0 else { return nil }
        return Int((Double(min(usage.last.totalTokens, window)) / Double(window) * 100).rounded())
    }

    /// `/init` needs a real project folder, as in the Codex app (not `/` or the home folder).
    var hasProjectFolder: Bool {
        guard let path = workspaceURL?.standardizedFileURL.path(percentEncoded: false) else { return false }
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path(percentEncoded: false)
        let homeTrimmed = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        return !trimmed.isEmpty && trimmed != "/" && trimmed != homeTrimmed
    }
}

enum CodexComposerCommands {
    /// The commands this context offers, in the Codex app's order: ungrouped commands by title,
    /// then the Skills group.
    static func catalog(_ context: CodexComposerCommandContext) -> [ProviderComposerCommand] {
        var entries: [(command: CodexComposerCommand, row: ProviderComposerCommand)] = []
        func add(_ command: CodexComposerCommand, title: String, description: String, group: String? = nil) {
            guard !(context.hasDraftContent && command.requiresEmptyComposer) else { return }
            entries.append((command, ProviderComposerCommand(
                name: command.name, description: description, argumentHint: "", builtin: true,
                title: title, group: group)))
        }

        if context.hasThread {
            add(.compact, title: L10n.string("Compact slash command"), description: context.contextPercent.map {
                L10n.format("Compact this chat's context (%lld%% full)", Int64($0))
            } ?? L10n.string("Compact this chat's context"))
        }
        if context.isGitRepository {
            add(.codeReview, title: L10n.string("Code review"),
                description: L10n.string("Review uncommitted changes or compare against a branch"))
        }
        if context.hasThread {
            // Yardlet forks into the task's own workspace and never makes a worktree, which is
            // the Codex app's wording for a fork without the worktree option.
            add(.fork, title: L10n.string("Fork chat"), description: L10n.string("Fork this chat"))
        }
        add(.newChat, title: L10n.string("New chat"), description: L10n.string("Start a blank chat in the same workspace"))
        add(.rename, title: L10n.string("Rename"), description: L10n.string("Rename the current chat"))
        add(.pin, title: L10n.string("Pin chat"), description: L10n.string("Keep this chat in the sidebar"))
        add(.archive, title: L10n.string("Archive"), description: L10n.string("Archive the current chat"))
        add(.model, title: L10n.string("Model"), description: "")
        add(.reasoning, title: L10n.string("Reasoning slash command"),
            description: context.modelCatalog.effort.map(CodexReasoningLabel.name) ?? "")
        for tier in context.modelCatalog.availableServiceTiers {
            let isActive = context.modelCatalog.serviceTier == tier.id
            add(.serviceTier(tier.id), title: tier.name, description: isActive
                ? L10n.format("Turn off %@ and return to standard speed", tier.name) : tier.description)
        }
        if context.modes.contains(where: { $0.mode == "plan" }) {
            add(.planMode, title: L10n.string("Plan mode"), description: context.isPlanModeActive
                ? L10n.string("Turn plan mode off") : L10n.string("Turn plan mode on"))
        }
        if !context.isRunning, context.hasProjectFolder {
            add(.initialize, title: L10n.string("Init"),
                description: L10n.string("Create an AGENTS.md file with instructions for Codex"))
        }
        if context.canOpenSideChat, context.hasThread {
            add(.sideChat, title: L10n.string("Side"), description: L10n.string("Start a temporary side chat"))
        }
        // The Codex app registers Status in every local composer, running or not.
        add(.status, title: L10n.string("Status slash command"),
            description: L10n.string("Show chat ID, context usage, and rate limits"))
        var commands = entries.map(\.row).sorted { $0.displayTitle < $1.displayTitle }

        var seenSkills = Set<String>()
        let skills = context.skills.filter(\.enabled).sorted { $0.displayName < $1.displayName }
        for skill in skills {
            let command = CodexComposerCommand.skill(name: skillName(skill), path: skill.path)
            guard seenSkills.insert(command.name).inserted else { continue }
            commands.append(ProviderComposerCommand(
                name: command.name, description: skill.description, argumentHint: "", builtin: true,
                title: skill.displayName, group: L10n.string("Skills")))
        }
        return commands
    }

    /// The command a catalog row runs.
    static func command(for row: ProviderComposerCommand, in context: CodexComposerCommandContext) -> CodexComposerCommand? {
        let name = row.name
        if name.hasPrefix("service-tier:") { return .serviceTier(String(name.dropFirst("service-tier:".count))) }
        if name.hasPrefix("skill:") {
            let skillName = String(name.dropFirst("skill:".count))
            return context.skills.first { $0.enabled && Self.skillName($0) == skillName }
                .map { .skill(name: skillName, path: $0.path) }
        }
        let fixed: [CodexComposerCommand] = [.compact, .codeReview, .fork, .newChat, .rename, .pin, .archive,
                                             .model, .reasoning, .planMode, .initialize, .sideChat, .status]
        return fixed.first { $0.name == name }
    }

    /// A skill's command name. A name is one token, so whitespace and slashes become dashes.
    static func skillName(_ skill: CodexSkillSummary) -> String {
        String(skill.name.map { $0.isWhitespace || $0 == "/" ? "-" : $0 })
    }

    /// Typed text that the send path still runs as a command: `/compact` and `/review` keep
    /// working when the list was dismissed before Return.
    static func isBuiltin(_ text: String) -> Bool {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).first
        return name == "/compact" || name == "/review"
    }

    /// Whether `url` is inside a Git working tree, as the Code review command requires.
    static func isInsideGitRepository(_ url: URL) -> Bool {
        var current = url.standardizedFileURL
        for _ in 0..<64 {
            if FileManager.default.fileExists(atPath: current.appending(path: ".git").path(percentEncoded: false)) {
                return true
            }
            let parent = current.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == current.path(percentEncoded: false) { return false }
            current = parent
        }
        return false
    }
}

/// The prompt the Codex `/init` command submits. It is the open-source Codex CLI's
/// `codex-rs/tui/prompt_for_init_command.md` (Apache-2.0), which the Codex desktop app also
/// sends; see THIRD_PARTY_NOTICES.md.
enum CodexInitPrompt {
    static let fileName = "AGENTS.md"

    static let text = """
    Generate a file named AGENTS.md that serves as a contributor guide for this repository.
    Your goal is to produce a clear, concise, and well-structured document with descriptive headings and actionable explanations for each section.
    Follow the outline below, but adapt as needed — add sections if relevant, and omit those that do not apply to this project.

    Document Requirements

    - Title the document "Repository Guidelines".
    - Use Markdown headings (#, ##, etc.) for structure.
    - Keep the document concise. 200-400 words is optimal.
    - Keep explanations short, direct, and specific to this repository.
    - Provide examples where helpful (commands, directory paths, naming patterns).
    - Maintain a professional, instructional tone.

    Recommended Sections

    Project Structure & Module Organization

    - Outline the project structure, including where the source code, tests, and assets are located.

    Build, Test, and Development Commands

    - List key commands for building, testing, and running locally (e.g., npm test, make build).
    - Briefly explain what each command does.

    Coding Style & Naming Conventions

    - Specify indentation rules, language-specific style preferences, and naming patterns.
    - Include any formatting or linting tools used.

    Testing Guidelines

    - Identify testing frameworks and coverage requirements.
    - State test naming conventions and how to run tests.

    Commit & Pull Request Guidelines

    - Summarize commit message conventions found in the project’s Git history.
    - Outline pull request requirements (descriptions, linked issues, screenshots, etc.).

    (Optional) Add other sections if relevant, such as Security & Configuration Tips, Architecture Overview, or Agent-Specific Instructions.

    """
}
