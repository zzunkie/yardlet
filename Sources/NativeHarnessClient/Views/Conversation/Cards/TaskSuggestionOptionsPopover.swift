import SwiftUI

/// What a chip's Options reads and does, bound to one suggestion in its task.
struct TaskSuggestionOptionsContext {
    /// What Start starts with now, read each time Options draws: the last choice made here, else
    /// the defaults.
    var choice: () -> TaskSuggestionStartChoice
    /// "As a subtask of ‘…’" when the agent named the task it nests under.
    var parentLabel: String?
    var projects: [Project]
    var harnesses: [HarnessDescriptor]
    var models: NewTaskModelSource?
    /// The accounts the new-task screen offers for a harness, and their check.
    var accounts: (HarnessKind) -> [AccountChoice] = { _ in [] }
    var checkAccounts: (HarnessKind) async -> Void = { _ in }
    var runtimeURL: (HarnessKind) -> URL?
    /// The options a task starts with on another harness: the parent's permission level in its words.
    var defaults: (HarnessKind) -> [String: String]
    /// The account a task starts on with another harness.
    var connection: (HarnessKind) -> ProviderConnection?
    var isRepository: (URL) -> Bool
    /// The agent asked for a worktree (`useWorktree`): a folder outside Git says it starts locally.
    var asksForWorktree = false
    /// A folder chosen from disk becomes a project, as the new-task screen's does.
    var chooseWorkspace: (URL) -> Project?
    /// Keeps a choice for the chip's Start and its quiet summary.
    var save: (TaskSuggestionStartChoice) -> Void
    var start: (TaskSuggestionStartChoice) -> Void
}

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

/// This Mac's suggestion: its choice, read from and saved to the chip, on this Mac's harnesses,
/// accounts, projects and model lists.
extension TaskSuggestionOptionsContext: TaskSuggestionOptionsSource {
    /// What the model lists are read for: the harness, the account and the folder.
    private struct ModelListKey: Hashable {
        var harness: HarnessKind
        var connectionID: String?
        var folder: URL?
    }

    func menus() -> TaskSuggestionOptionsMenus {
        let context = self
        let choice = choice()
        let options = TaskSuggestionStartOptions.sessionOptions(for: choice, catalogs: models?.catalogs)
        let accounts = accounts(choice.harness)
        let currentAccount = accounts.first { $0.connection?.id == choice.connection?.id }
        let folder = choice.place.folder
        let project = choice.place.project ?? folder.flatMap { ProjectProjection.project(containingRoot: $0, in: projects) }
        var run: TaskSuggestionOptionsMenus.Run?
        if let folder {
            if isRepository(folder) {
                run = .choosable(inWorktree: choice.place.startsInNewWorktree)
            } else if asksForWorktree {
                run = .localOnly
            }
        }
        return TaskSuggestionOptionsMenus(
            parentLabel: parentLabel,
            harness: choice.harness,
            harnesses: harnesses.map(\.id),
            chooseHarness: { harness in
                guard let next = TaskSuggestionStartOptions.choosing(
                    harness: harness, in: choice, options: context.defaults(harness),
                    connection: context.connection(harness)) else { return }
                context.save(next)
            },
            account: accounts.isEmpty ? nil : .init(
                title: currentAccount?.composerTitle ?? choice.connection?.name ?? L10n.string("Account unavailable"),
                items: accounts.map { .init(id: $0.id, title: $0.composerTitle, isChosen: $0.id == currentAccount?.id,
                                            isEnabled: $0.canSelect) }),
            chooseAccount: { id in
                guard let account = accounts.first(where: { $0.id == id }) else { return }
                var next = choice
                next.connection = account.connection
                context.save(next)
            },
            place: .init(title: project?.name ?? folder?.lastPathComponent ?? L10n.string("Chat (no project)"),
                         startsAsChat: folder == nil,
                         projects: projects.map { .init(id: $0.id.uuidString, title: $0.name,
                                                        isChosen: folder != nil && $0.id == project?.id) }),
            choosePlace: { id in
                guard let id else {
                    context.save(choice.moving(to: nil, project: nil, isRepository: context.isRepository))
                    return
                }
                guard let chosen = context.projects.first(where: { $0.id.uuidString == id }) else { return }
                context.save(choice.moving(to: chosen.primaryRoot, project: chosen, isRepository: context.isRepository))
            },
            chooseFolder: {
                guard let chosen = NewTaskDestination.askForFolder() else { return }
                let project = context.chooseWorkspace(chosen)
                context.save(context.choice().moving(to: chosen, project: project, isRepository: context.isRepository))
            },
            run: run,
            chooseWorktree: { context.save(choice.startingInNewWorktree($0, isRepository: context.isRepository)) },
            options: options,
            pick: { picked in
                guard let next = TaskSuggestionStartOptions.choosing(picked, in: choice, catalogs: context.models?.catalogs) else { return }
                context.save(next)
            },
            canStart: runtimeURL(choice.harness) != nil,
            start: { _ in context.start(context.choice()) },
            // Opening Options is opening the model menu: a list not read yet is read now, as the
            // new-task screen's menu reads it when it opens.
            loadModels: .init(id: ModelListKey(harness: choice.harness, connectionID: choice.connection?.id, folder: folder)) {
                guard let model = options.model, !model.menu.canChoose || model.menu.isEmpty,
                      let models = context.models, let runtime = context.runtimeURL(choice.harness) else { return }
                await models.load(choice.harness, runtime, choice.connection, choice.place.folder)
            },
            checkAccounts: .init(id: choice.harness) { await context.checkAccounts(choice.harness) })
    }
}

/// The chip's Options, as the Claude app's (3.1623.3: a popover from the row with Environment,
/// Worktree, Model and Effort, and Permissions): the harness, the account, where it starts, Local
/// or New worktree, the model, effort and permissions, each a one-level menu of the new-task
/// screen's own choices, then Start. A pick is saved as it is made, for the row's Start and its
/// summary, so nothing waits on the popover staying open, and no control here opens a popover of
/// its own. A harness chosen here starts from the parent's permission level in its words. Another
/// Mac's suggestion draws the same menus from that Mac's choices.
struct TaskSuggestionOptionsPopover: View {
    let context: any TaskSuggestionOptionsSource
    let dismiss: () -> Void

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    /// A choice the provider asks about first, or Start on one, waiting for that answer.
    @State private var confirming: Confirming?

    private struct Confirming {
        let confirmation: ComposerPermissionSlot.Confirmation
        /// Nil confirms Start.
        let pick: ComposerSessionChoice?
    }

    var body: some View {
        let menus = context.menus()
        let options = menus.options
        VStack(alignment: .leading, spacing: 10) {
            if let parentLabel = menus.parentLabel {
                Text(parentLabel)
                    .font(.system(size: 12 * interfaceScale))
                    .foregroundStyle(.secondary)
            }
            row(L10n.string("Harness")) { harnessMenu(menus) }
            if let account = menus.account {
                row(L10n.string("Account")) { accountMenu(account, menus: menus) }
            }
            row(L10n.string("taskSuggestion.where")) { placeMenu(menus) }
            runRow(menus)
            if let model = options.model {
                ForEach([model.menu.model, model.menu.effort, model.menu.speed].compactMap { $0 }) { selector in
                    row(selector.name) {
                        selectorMenu(selector, isEnabled: model.menu.canChoose) { value in
                            guard let picked = model.apply.choice(id: selector.id, value: value) else { return }
                            menus.pick(picked)
                        }
                    }
                }
            }
            if let permission = options.permission {
                row(L10n.string("Permissions")) { permissionMenu(permission, menus: menus) }
            }
            HStack {
                Spacer(minLength: 0)
                Button(L10n.string("Start")) {
                    let menus = context.menus()
                    if let confirmation = menus.startConfirmation {
                        confirming = Confirming(confirmation: confirmation, pick: nil)
                    } else {
                        menus.start(false)
                        dismiss()
                    }
                }
                .parityProminentButton()
                .controlSize(.small)
                .parityPointer()
                .disabled(!menus.canStart)
                .keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13 * interfaceScale))
        .padding(14)
        .frame(width: 400)
        .task(id: menus.loadModels?.id) { await menus.loadModels?.run() }
        .task(id: menus.checkAccounts?.id) { await menus.checkAccounts?.run() }
        .alert(confirming?.confirmation.title ?? "", isPresented: Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        ), presenting: confirming) { request in
            Button(L10n.string("Cancel"), role: .cancel) {}
            Button(request.confirmation.confirm, role: .destructive) {
                let menus = context.menus()
                if let pick = request.pick {
                    menus.pick(pick)
                } else {
                    menus.start(true)
                    dismiss()
                }
            }
        } message: { request in
            Text(request.confirmation.message)
        }
    }

    private func row<Control: View>(_ name: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(name)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            HStack(spacing: 6) { control() }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28 * interfaceScale)
    }

    @ViewBuilder
    private func item(_ title: String, isChosen: Bool) -> some View {
        if isChosen {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func harnessMenu(_ menus: TaskSuggestionOptionsMenus) -> some View {
        Menu {
            ForEach(menus.harnesses, id: \.self) { harness in
                Button {
                    menus.chooseHarness(harness)
                } label: {
                    HarnessIdentityLabel(harness: harness)
                }
            }
        } label: {
            HarnessIdentityLabel(harness: menus.harness)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .parityPointer()
        .accessibilityLabel(L10n.string("Harness"))
        .accessibilityValue(menus.harness.displayName)
    }

    private func accountMenu(_ account: TaskSuggestionOptionsMenus.Account, menus: TaskSuggestionOptionsMenus) -> some View {
        Menu {
            ForEach(account.items) { choice in
                Button {
                    menus.chooseAccount(choice.id)
                } label: {
                    item(choice.title, isChosen: choice.isChosen)
                }
                .disabled(!choice.isEnabled)
            }
        } label: {
            ParityComposerControl(title: account.title, systemName: "person.crop.circle", showsChevron: true)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .parityPointer()
        .accessibilityLabel(L10n.string("Account"))
        .accessibilityValue(account.title)
    }

    private func placeMenu(_ menus: TaskSuggestionOptionsMenus) -> some View {
        let place = menus.place
        return Menu {
            if let chooseFolder = menus.chooseFolder {
                Button(L10n.string("Choose project…")) { chooseFolder() }
            }
            Button {
                menus.choosePlace(nil)
            } label: {
                item(L10n.string("Chat (no project)"), isChosen: place.startsAsChat)
            }
            if !place.projects.isEmpty {
                Divider()
                ForEach(place.projects) { project in
                    Button {
                        menus.choosePlace(project.id)
                    } label: {
                        item(project.title, isChosen: project.isChosen)
                    }
                }
            }
        } label: {
            ParityComposerControl(title: place.title, systemName: place.startsAsChat ? "bubble.left" : "folder", showsChevron: true)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .parityPointer()
        .accessibilityLabel(L10n.string("taskSuggestion.where"))
        .accessibilityValue(place.title)
    }

    /// Local or New worktree, as the new-task screen's control, for a folder in Git. A folder
    /// outside Git has no control there; here it says Local only when the agent asked for a worktree.
    @ViewBuilder
    private func runRow(_ menus: TaskSuggestionOptionsMenus) -> some View {
        switch menus.run {
        case let .choosable(inWorktree)?:
            let title = L10n.string(inWorktree ? "New worktree" : "Local")
            row(L10n.string("Where to run")) {
                Menu {
                    Button {
                        menus.chooseWorktree(false)
                    } label: {
                        item(L10n.string("Work locally"), isChosen: !inWorktree)
                    }
                    Button {
                        menus.chooseWorktree(true)
                    } label: {
                        item(L10n.string("New worktree"), isChosen: inWorktree)
                    }
                } label: {
                    ParityComposerControl(title: title, systemName: inWorktree ? "arrow.triangle.branch" : "laptopcomputer",
                                          showsChevron: true)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .parityPointer()
                .accessibilityLabel(L10n.string("Where to run"))
                .accessibilityValue(title)
            }
        case .localOnly?:
            let reason = L10n.string("The folder isn't in a Git repository, so it can't have a worktree.")
            row(L10n.string("Where to run")) {
                ParityComposerControl(title: L10n.string("Local"), systemName: "laptopcomputer", isInteractive: false)
                    .fixedSize()
                    .help(reason)
                    .accessibilityHint(reason)
            }
        case nil:
            EmptyView()
        }
    }

    /// One of the model menu's lists (model, effort, speed) as a menu of its own.
    private func selectorMenu(_ selector: ProviderCapabilitySelector, isEnabled: Bool,
                              onPick: @escaping (String) -> Void) -> some View {
        let title = ProviderCapabilityAccessibility.selectedChoiceName(for: selector)
        return Menu {
            ForEach(selector.choices) { choice in
                Button { onPick(choice.value) } label: {
                    item(choice.name, isChosen: choice.value == selector.currentValue)
                }
            }
        } label: {
            // The menu draws its own chevron; one in the label would be taken for its symbol.
            ParityComposerControl(title: title)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .parityPointer()
        .disabled(!isEnabled)
        .accessibilityLabel(selector.name)
        .accessibilityValue(title)
    }

    private func permissionMenu(_ slot: ComposerPermissionSlot, menus: TaskSuggestionOptionsMenus) -> some View {
        Menu {
            if let selector = slot.selector {
                ForEach(selector.choices) { option in
                    Button {
                        guard option.value != selector.currentValue,
                              let picked = slot.apply.choice(id: selector.id, value: option.value) else { return }
                        if let confirmation = slot.confirmations[option.value] {
                            confirming = Confirming(confirmation: confirmation, pick: picked)
                        } else {
                            menus.pick(picked)
                        }
                    } label: {
                        item(option.name, isChosen: option.value == selector.currentValue)
                    }
                }
            }
        } label: {
            ParityComposerControl(title: slot.title, systemName: "checkmark.shield", showsChevron: true,
                                  tint: slot.isElevated ? .orange : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .parityPointer()
        .disabled(!slot.canChoose || !slot.showsChoices)
        .accessibilityLabel(L10n.string("Permissions"))
        .accessibilityValue(slot.title)
    }
}
