import Foundation

/// What a chip's Options draws now and what each pick does, whichever Mac starts the task: the
/// harness, the account, where the task starts and runs, and the new-task screen's model and
/// permission controls for them. This Mac's own (`TaskSuggestionOptionsContext`) or a host's over
/// Yardlet Remote (`RemoteSuggestionOptions`) fills it.
struct TaskSuggestionOptionsMenus {
    /// One choice in a menu.
    struct Item: Identifiable {
        var id: String
        var title: String
        var isChosen: Bool
        var isEnabled = true
    }

    struct Account {
        var title: String
        var items: [Item]
    }

    struct Place {
        var title: String
        var startsAsChat: Bool
        var projects: [Item]
    }

    /// Where to run: Local or a new worktree for a folder in Git; Local only, quietly, where the
    /// agent asked for a worktree and the folder has none.
    enum Run: Equatable {
        case choosable(inWorktree: Bool)
        case localOnly
    }

    /// A read the popover makes while open, again whenever `id` changes.
    struct Preparation {
        var id: AnyHashable
        var run: @MainActor () async -> Void
    }

    var parentLabel: String?
    var harness: HarnessKind
    var harnesses: [HarnessKind]
    var chooseHarness: (HarnessKind) -> Void
    /// Nil where the harness offers no account to choose.
    var account: Account?
    var chooseAccount: (String) -> Void = { _ in }
    var place: Place
    /// A project's `Item.id`, or nil for a chat.
    var choosePlace: (String?) -> Void
    /// Choose project…: a folder from this Mac's disk. Nil where the folders are another Mac's.
    var chooseFolder: (() -> Void)? = nil
    var run: Run?
    var chooseWorktree: (Bool) -> Void = { _ in }
    var options: ComposerSessionOptions
    /// A pick in the model or permission controls, after the person confirmed one that asks.
    var pick: (ComposerSessionChoice) -> Void
    var canStart: Bool
    /// What Start asks first: a choice the Mac asks to confirm that the person has not confirmed here.
    var startConfirmation: ComposerPermissionSlot.Confirmation? = nil
    /// Start; true when the person just confirmed `startConfirmation`.
    var start: (Bool) -> Void
    var loadModels: Preparation? = nil
    var checkAccounts: Preparation? = nil
}

/// What a chip's Options reads each time it draws.
@MainActor
protocol TaskSuggestionOptionsSource {
    func menus() -> TaskSuggestionOptionsMenus
}
