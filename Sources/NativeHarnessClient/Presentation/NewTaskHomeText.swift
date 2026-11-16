import Foundation

// The new-task screen's words, the same on the Mac, on Windows and for a host's new task.

/// The new-task composer's placeholder, in the chosen harness's name, as the Codex app writes it
/// (`composer.placeholder.newTask.doAnything`).
enum NewTaskComposerText {
    static func placeholder(harnessName: String?) -> String {
        harnessName.map { L10n.format("Ask %@ to do anything", $0) } ?? L10n.string("Describe a task…")
    }
}

/// Which of the Codex app's titles the new-task screen shows (`NewTaskHeroTitle`).
enum NewTaskHeroTitleKind: Equatable {
    case build(project: String)
    case workOn(project: String)
    case noProject

    init(startsChat: Bool, workspaceURL: URL?, isInRepository: Bool, projectName: (URL) -> String) {
        guard !startsChat, let workspaceURL else { self = .noProject; return }
        let name = Self.shortened(projectName(workspaceURL))
        self = isInRepository ? .build(project: name) : .workOn(project: name)
    }

    /// A project's name as the title shows it: up to 40 characters, a long one shortened in the middle.
    static func shortened(_ name: String, limit: Int = 40) -> String {
        guard name.count > limit else { return name }
        let half = (limit - 1) / 2
        return String(name.prefix(half)) + "…" + String(name.suffix(limit - 1 - half))
    }

    /// The sentence around the project's name, in the reader's language: what comes before it,
    /// the name, and what follows.
    var parts: (before: String, project: String?, after: String) {
        let sentence: String
        let project: String
        switch self {
        case .noProject: return (L10n.string("What should we build?"), nil, "")
        case let .build(name): (sentence, project) = (L10n.string("What should we build in %@?"), name)
        case let .workOn(name): (sentence, project) = (L10n.string("What should we work on in %@?"), name)
        }
        return Self.split(sentence, around: project)
    }

    /// A localized sentence split where its `%@` names the project.
    static func split(_ sentence: String, around project: String) -> (before: String, project: String?, after: String) {
        guard let range = sentence.range(of: "%@") else { return (sentence, project, "") }
        return (String(sentence[..<range.lowerBound]), project, String(sentence[range.upperBound...]))
    }

    /// The whole sentence, as assistive technologies read it.
    var sentence: String {
        let parts = parts
        return parts.before + (parts.project ?? "") + parts.after
    }
}
