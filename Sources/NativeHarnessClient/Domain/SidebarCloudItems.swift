import Foundation

/// A Codex task one of the person's dots started (`PersonalAgentThread`, kind `task`), as the app's
/// watch on the dots read it, with the dot it belongs to and the account choice the watch follows,
/// so a window can show that dot and open the task in its reader. Its agent loop ran on the
/// provider's side, so there is no local session and no row in Yardlet's index.
struct PersonalAgentCloudTask: Identifiable, Equatable, Sendable {
    let agent: PersonalAgent
    let accountChoiceID: String
    let thread: PersonalAgentThread

    var id: String { thread.id }
}

/// One row of the sidebar's Cloud section: a Codex Cloud task, or a Codex task a dot started. Both
/// run on the provider's machines; the section lists them together, newest first.
enum SidebarCloudItem: Identifiable, Equatable, Sendable {
    case codexCloud(CodexCloudTask)
    case personalAgent(PersonalAgentCloudTask)

    var id: String {
        switch self {
        case let .codexCloud(task): "cloud:" + task.id
        case let .personalAgent(task): "dot:" + task.id
        }
    }

    var title: String {
        switch self {
        case let .codexCloud(task): task.title
        case let .personalAgent(task): task.thread.displayTitle
        }
    }

    var updatedAt: Date? {
        switch self {
        case let .codexCloud(task): task.updatedAt
        case let .personalAgent(task): task.thread.updatedAt ?? task.thread.createdAt ?? task.thread.attachedAt
        }
    }

    /// The marks task rows use: a running task is "Running", a failed one the error mark.
    var status: SidebarTaskStatus? {
        switch self {
        case let .codexCloud(task):
            switch task.status {
            case .pending: .running
            case .error: .failed(message: nil)
            case .ready, .applied, nil: nil
            }
        case let .personalAgent(task):
            switch task.thread.status {
            case .active: .running
            case .systemError: .failed(message: nil)
            case .idle, .notLoaded, .unknown, nil: nil
            }
        }
    }

    /// Where the task comes from, as its help and accessibility value name it: Codex Cloud, or the dot.
    var source: String {
        switch self {
        case .codexCloud: L10n.string("Codex Cloud")
        case let .personalAgent(task): task.agent.name
        }
    }

    /// A state the marks do not show (a Codex Cloud task ready to apply, or applied).
    var stateName: String? {
        switch self {
        case let .codexCloud(task):
            switch task.status {
            case .ready: L10n.string("Ready")
            case .applied: L10n.string("Applied")
            case .pending, .error, nil: status?.accessibilityName
            }
        case .personalAgent:
            status?.accessibilityName
        }
    }

    /// The environment a Codex Cloud task ran in; a dot's task names no place here.
    var detail: String? {
        if case let .codexCloud(task) = self { return task.environment }
        return nil
    }

    /// The page a Codex Cloud task opens on; a dot's task opens in Yardlet.
    var url: URL? {
        if case let .codexCloud(task) = self { return task.url }
        return nil
    }

    /// Both lists as one, newest first; a task with no time comes last, and the lists' own orders
    /// hold between equals.
    static func merged(codexCloud: [CodexCloudTask], personalAgents: [PersonalAgentCloudTask]) -> [SidebarCloudItem] {
        let items = codexCloud.map(SidebarCloudItem.codexCloud) + personalAgents.map(SidebarCloudItem.personalAgent)
        return items.enumerated().sorted { a, b in
            switch (a.element.updatedAt, b.element.updatedAt) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The items a sidebar search keeps: those whose title, source or detail holds the search text.
    static func matching(_ items: [SidebarCloudItem], search: String) -> [SidebarCloudItem] {
        let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return items }
        return items.filter {
            $0.title.localizedStandardContains(search) || $0.source.localizedStandardContains(search)
                || $0.detail?.localizedStandardContains(search) == true
        }
    }
}
