import Foundation

/// How a task's pull request reads wherever a task is shown — the title bar's badge, and a sidebar
/// row's when one shows it: "PR #123", the Claude app's glyph and tint for its state, a dot for its
/// checks, and the words for help and accessibility. Colours are Yardlet's own status colours (`Tone`).
///
/// As the Claude app's session glyph: an open pull request shows its review decision (changes
/// requested, then approved) in place of the pull request glyph; a draft is grey, a merged one
/// purple, a closed one red; checks show as a dot beside an open or draft one only.
struct TaskPullRequestBadge: Equatable, Sendable {
    enum Glyph: Equatable, Sendable {
        case pullRequest
        case merged
        case approved
        case changesRequested
        /// A sidebar row's mark for an open or draft pull request whose checks fail; the title bar
        /// shows checks as a dot beside the state's glyph instead.
        case checksFailing

        /// The SF Symbol drawn for it.
        var systemName: String {
            switch self {
            case .pullRequest: "arrow.triangle.pull"
            case .merged: "arrow.triangle.merge"
            case .approved: "checkmark.circle"
            case .changesRequested: "xmark.circle"
            case .checksFailing: "exclamationmark.circle"
            }
        }
    }

    /// Yardlet's status colours: secondary, green, orange, red, and purple for merged.
    enum Tone: Equatable, Sendable {
        case neutral
        case success
        case pending
        case failure
        case merged
    }

    let number: Int
    let url: URL
    let glyph: Glyph
    let tone: Tone
    /// The checks' dot, nil when none is drawn.
    let checksTone: Tone?
    /// "PR #123".
    let title: String
    /// The state, checks and review in words, those GitHub said.
    let facts: [String]

    init(_ pullRequest: TaskPullRequest) {
        number = pullRequest.number
        url = pullRequest.url
        // A pull request number is an identifier: no grouping separator, whatever the locale.
        title = L10n.format("PR #%@", String(pullRequest.number))
        switch pullRequest.state {
        case nil:
            (glyph, tone) = (.pullRequest, .neutral)
        case .draft:
            (glyph, tone) = (.pullRequest, .neutral)
        case .merged:
            (glyph, tone) = (.merged, .merged)
        case .closed:
            (glyph, tone) = (.pullRequest, .failure)
        case .open:
            switch pullRequest.review {
            case .changesRequested: (glyph, tone) = (.changesRequested, .failure)
            case .approved: (glyph, tone) = (.approved, .success)
            case nil: (glyph, tone) = (.pullRequest, .success)
            }
        }
        let showsChecks = pullRequest.state == .open || pullRequest.state == .draft
        checksTone = showsChecks ? pullRequest.checks.map {
            switch $0 {
            case .passing: .success
            case .pending: .pending
            case .failing: .failure
            }
        } : nil
        var facts: [String] = []
        if let state = pullRequest.state { facts.append(Self.label(state)) }
        if showsChecks, let checks = pullRequest.checks { facts.append(Self.label(checks)) }
        if pullRequest.state == .open || pullRequest.state == .draft, let review = pullRequest.review {
            facts.append(Self.label(review))
        }
        self.facts = facts
        repository = pullRequest.repository
    }

    private let repository: String?

    /// The pointer's help: where it is, then the Claude app's "Pull request · {state}" with the
    /// checks and review after it.
    var help: String {
        let place = repository.map { "\($0) #\(number)" } ?? title
        return place + "\n" + ([L10n.string("Pull request")] + facts).joined(separator: " · ")
    }

    var accessibilityLabel: String { L10n.format("Pull request #%@", String(number)) }
    var accessibilityValue: String { facts.joined(separator: ", ") }

    static func label(_ state: TaskPullRequest.State) -> String {
        switch state {
        case .open: L10n.string("Pull request state open")
        case .draft: L10n.string("Pull request state draft")
        case .merged: L10n.string("Pull request state merged")
        case .closed: L10n.string("Pull request state closed")
        }
    }

    static func label(_ checks: TaskPullRequest.Checks) -> String {
        switch checks {
        case .passing: L10n.string("Checks passing")
        case .failing: L10n.string("Checks failing")
        case .pending: L10n.string("Checks running")
        }
    }

    static func label(_ review: TaskPullRequest.Review) -> String {
        switch review {
        case .changesRequested: L10n.string("Changes requested")
        case .approved: L10n.string("Pull request review approved")
        }
    }
}

/// The quiet mark a sidebar row shows for its task's pull request, as the Claude app's Code list
/// marks a session's pull request (`data-pr-glyph`): the state's small glyph in its tint and no
/// number — open green, approved green check, changes requested red cross, draft grey, merged
/// purple, closed red (the title bar badge's glyph and tone). Failing checks, which the Claude app's
/// row glyph leaves out and the title bar shows as a red dot, turn an open or draft one's mark into
/// a red exclamation mark (2026-10-16, asked for with the other states); changes requested, a
/// person's word, stays ahead of it. The number, the state and the checks are in the row's help and
/// accessibility value and in the row's menu, and the title bar still shows "PR #123". A pull
/// request whose state GitHub did not give shows nothing in the row.
struct TaskPullRequestRowMark: Equatable, Sendable {
    let number: Int
    let url: URL
    let glyph: TaskPullRequestBadge.Glyph
    let tone: TaskPullRequestBadge.Tone
    /// "PR #123 · Open · Checks failing", for the row's help.
    let help: String
    /// "Pull request #123, Open, Checks failing", for the row's accessibility value.
    let accessibilityName: String
    /// "Open Pull Request #123", the row menu's item.
    var openTitle: String { L10n.format("Open pull request #%@", String(number)) }

    init?(_ pullRequest: TaskPullRequest) {
        guard pullRequest.state != nil else { return nil }
        let badge = TaskPullRequestBadge(pullRequest)
        number = pullRequest.number
        url = pullRequest.url
        if pullRequest.checks == .failing, badge.glyph != .changesRequested,
           pullRequest.state == .open || pullRequest.state == .draft {
            (glyph, tone) = (.checksFailing, .failure)
        } else {
            (glyph, tone) = (badge.glyph, badge.tone)
        }
        help = ([badge.title] + badge.facts).joined(separator: " · ")
        accessibilityName = ([badge.accessibilityLabel] + badge.facts).joined(separator: ", ")
    }
}

/// The new-task screen's warning, from the Claude app: the folder chosen for a new task already has
/// a task running in it, and a worktree would keep their changes apart. A warning only: the task
/// still starts locally if the person wants.
enum NewTaskFolderConflict {
    /// The running task in `folder`, when the new task would start there beside it: a folder in Git
    /// (so a worktree is possible), the new task starting locally rather than in a new worktree, and
    /// a task (not archived, which the list never holds) whose own folder is exactly this one and
    /// whose turn is running or waiting on the person. A task in its own worktree has that
    /// worktree's folder, so it never counts.
    static func runningTask(
        in folder: URL?, isInRepository: Bool, startsInNewWorktree: Bool, startsChat: Bool,
        sessions: [SessionRecord]
    ) -> SessionRecord? {
        guard let folder, isInRepository, !startsInNewWorktree, !startsChat else { return nil }
        let key = ProjectSidebarPresentation.folderKey(for: folder)
        return sessions.first { session in
            (session.status == .running || session.status == .waitingForApproval)
                && ProjectSidebarPresentation.folderKey(for: session.workspaceURL) == key
        }
    }
}
