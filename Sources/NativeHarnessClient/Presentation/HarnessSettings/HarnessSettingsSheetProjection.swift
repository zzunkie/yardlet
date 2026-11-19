import Foundation

/// One section of a task's harness settings sheet (plan B6). Every harness's sheet has the same
/// layout; which sections it shows comes from what its provider reports.
enum HarnessSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case controls
    case skills
    case plugins

    var id: Self { self }

    var title: String {
        switch self {
        case .controls: L10n.string("Controls")
        case .skills: L10n.string("Skills")
        case .plugins: L10n.string("Plugins")
        }
    }
}

/// Where a task's harness settings come from: Codex's App Server capabilities, or the live
/// controls every other provider reports. The sheet reads and refreshes through this.
enum HarnessSettingsSource: Equatable, Sendable {
    case codex
    case provider

    init(harness: HarnessKind) {
        self = harness == .codex ? .codex : .provider
    }
}

/// What choosing a row's control does. The window routes each one to the app model call the
/// former Codex and provider sheets made (`HarnessSettingsActions`).
enum HarnessSettingsCommand: Equatable, Sendable {
    /// A Codex collaboration preset, or nil for the harness default.
    case selectCodexMode(CodexCollaborationPreset.ID?)
    case setProviderOption(id: String, value: String)
    case performProviderAction(id: String)
    /// The task's fork (`AppModel.branch`), offered when its adapter can branch.
    case fork
    case reviewCodexWorkingTree
    /// A skill or plugin row's switch, through the harness's own command.
    case setSwitch(HarnessSettingsSwitch, enabled: Bool)

    /// Fork and review continue in the task list and the conversation, so the sheet closes before
    /// they start, as the Codex sheet did. Selectors, provider actions and switches keep it open.
    var dismissesSheet: Bool {
        switch self {
        case .fork, .reviewCodexWorkingTree: true
        case .selectCodexMode, .setProviderOption, .performProviderAction, .setSwitch: false
        }
    }
}

/// What a skill or plugin row's switch turns on and off. The harness keeps the value: a Codex
/// skill in the account's `config.toml` (`skills/config/write`), a Claude Code plugin in the
/// account's user settings (`claude plugin enable|disable --scope user`).
enum HarnessSettingsSwitch: Equatable, Sendable {
    case codexSkill(path: String)
    case accountPlugin(id: String)
}

struct HarnessSettingsChoice: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let command: HarnessSettingsCommand
    /// A divider goes before this choice: Codex's presets follow the harness default.
    var startsGroup = false
    /// Asked before the command runs, in the words the composer's permissions menu uses.
    var confirmation: ComposerPermissionSlot.Confirmation? = nil
}

/// A row of the Controls section: a selector (a menu of the provider's own choices) or an action
/// (a button). Both put their control at the row's trailing edge.
struct HarnessSettingsControl: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case selector(currentTitle: String, choices: [HarnessSettingsChoice])
        case action(buttonTitle: String, command: HarnessSettingsCommand)
    }

    let id: String
    let title: String
    let description: String?
    let systemImage: String
    let kind: Kind
}

/// A row of the Skills or Plugins section: what the provider reports, with a switch where the
/// harness's own command turns the item on and off (Codex skills, Claude Code plugins). Installing
/// and removing stay with the harness.
struct HarnessSettingsListItem: Equatable, Identifiable, Sendable {
    struct SwitchState: Equatable, Sendable {
        let target: HarnessSettingsSwitch
        let isOn: Bool
    }

    struct Badge: Equatable, Sendable {
        enum Tone: Equatable, Sendable {
            case positive
            case neutral
            case warning
        }

        let text: String
        let tone: Tone
    }

    let id: String
    let title: String
    let description: String?
    /// The skill's scope or the plugin's marketplace.
    let detail: String
    let systemImage: String
    let badges: [Badge]
    /// Nil for a row the harness gives no switch.
    var switchState: SwitchState? = nil
}

/// What a task's harness settings sheet shows.
struct HarnessSettingsSheetContent: Equatable, Sendable {
    var controls: [HarnessSettingsControl] = []
    /// The provider's notes about its controls, shown under them.
    var notes: [String] = []
    /// Nil when the provider does not report skills; the section is then absent.
    var skills: [HarnessSettingsListItem]?
    /// Nil when the provider does not report plugins; the section is then absent.
    var plugins: [HarnessSettingsListItem]?
    var errors: [String] = []
    var actionMessage: String?
    var isLoading = false
    /// Where the switches reach and when a change takes effect, shown above a list with switches.
    var switchNote: String?

    var sections: [HarnessSettingsSection] {
        [.controls] + (skills == nil ? [] : [.skills]) + (plugins == nil ? [] : [.plugins])
    }

    /// The section a fixture or a caller asked for, when this sheet has it; Controls otherwise.
    func section(named name: String?) -> HarnessSettingsSection {
        guard let name, let section = HarnessSettingsSection(rawValue: name), sections.contains(section) else {
            return .controls
        }
        return section
    }
}

/// Projects a task's Codex or provider capability state into the one harness settings sheet.
enum HarnessSettingsSheetProjection {
    /// - Parameter canBranch: whether the task's adapter can fork it (`AppModel.canBranch`).
    static func content(
        source: HarnessSettingsSource,
        codex: CodexCapabilityState,
        provider: ProviderCapabilityState,
        switches: HarnessSwitchState = HarnessSwitchState(),
        canBranch: Bool
    ) -> HarnessSettingsSheetContent {
        switch source {
        case .codex: codexContent(codex, switches: switches, canBranch: canBranch)
        case .provider: providerContent(provider, switches: switches, canBranch: canBranch)
        }
    }

    static func codexContent(
        _ state: CodexCapabilityState, switches: HarnessSwitchState = HarnessSwitchState(), canBranch: Bool
    ) -> HarnessSettingsSheetContent {
        var controls = [codexModeSelector(state)]
        if canBranch { controls.append(forkControl) }
        controls.append(HarnessSettingsControl(
            id: "codex.review",
            title: L10n.string("Review working tree"),
            description: L10n.string("Start Codex review against uncommitted changes."),
            systemImage: "checkmark.bubble",
            kind: .action(buttonTitle: L10n.string("Start review"), command: .reviewCodexWorkingTree)
        ))
        return HarnessSettingsSheetContent(
            controls: controls,
            skills: state.skills.map(skillItem),
            plugins: state.plugins.map(pluginItem),
            errors: state.errors + switches.errors,
            actionMessage: state.actionMessage,
            isLoading: state.isLoading || switches.isLoading,
            switchNote: switchNote(for: switches.reach)
        )
    }

    static func providerContent(
        _ state: ProviderCapabilityState, switches: HarnessSwitchState = HarnessSwitchState(), canBranch: Bool
    ) -> HarnessSettingsSheetContent {
        var controls = state.selectors.map(providerSelector)
        if canBranch { controls.append(forkControl) }
        controls += state.actions.map(providerAction)
        return HarnessSettingsSheetContent(
            controls: controls,
            notes: state.notes,
            plugins: switches.accountPlugins?.map(accountPluginItem),
            errors: state.errors + switches.errors,
            actionMessage: state.actionMessage,
            isLoading: state.isLoading || switches.isLoading,
            switchNote: switches.accountPlugins == nil ? nil : switchNote(for: switches.reach)
        )
    }

    /// Both harnesses keep a running session's skills and plugins as it started with them: a Codex
    /// thread keeps the skill list its first turn sent, and Claude Code loads plugins when it starts
    /// (until something asks it to reload them, which Yardlet does not). So a change reaches the
    /// tasks that start after it, on every account that reads the same settings file.
    static func switchNote(for reach: HarnessSwitchReach) -> String {
        switch reach {
        case .account: L10n.string("Applies to all tasks on this account, starting with new tasks.")
        case .sharedSettings:
            L10n.string("Applies to all tasks on the accounts that share these settings, starting with new tasks.")
        }
    }

    // MARK: - Controls

    private static let defaultModeChoiceID = "harness-default"

    private static func codexModeSelector(_ state: CodexCapabilityState) -> HarnessSettingsControl {
        let selected = state.selectedModeID.flatMap { id in state.modes.first { $0.id == id } }
        let presets = state.modes.enumerated().map { index, mode in
            HarnessSettingsChoice(id: mode.id, title: mode.name, command: .selectCodexMode(mode.id),
                                  startsGroup: index == 0)
        }
        return HarnessSettingsControl(
            id: "codex.collaborationMode",
            title: L10n.string("Collaboration mode"),
            description: L10n.string("Choose how the next Codex turn approaches the task."),
            systemImage: "switch.2",
            kind: .selector(
                currentTitle: selected?.name ?? L10n.string("Harness default"),
                choices: [HarnessSettingsChoice(id: defaultModeChoiceID, title: L10n.string("Harness default"),
                                                command: .selectCodexMode(nil))] + presets
            )
        )
    }

    private static let forkControl = HarnessSettingsControl(
        id: "fork",
        title: L10n.string("Fork task"),
        description: L10n.string("Create a new task from this conversation."),
        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
        kind: .action(buttonTitle: L10n.string("Fork"), command: .fork)
    )

    private static func providerSelector(_ selector: ProviderCapabilitySelector) -> HarnessSettingsControl {
        HarnessSettingsControl(
            id: "option.\(selector.id)",
            title: selector.name,
            description: selector.description,
            systemImage: selectorSymbol(for: selector.category),
            kind: .selector(
                currentTitle: ProviderCapabilityAccessibility.selectedChoiceName(for: selector),
                choices: selector.choices.map {
                    HarnessSettingsChoice(id: $0.value, title: $0.name,
                                          command: .setProviderOption(id: selector.id, value: $0.value),
                                          confirmation: confirmation(for: $0.value, in: selector))
                }
            )
        )
    }

    /// Claude Code's and Antigravity's Bypass permissions ask here too, as in the composer's menu.
    private static func confirmation(for value: String, in selector: ProviderCapabilitySelector)
        -> ComposerPermissionSlot.Confirmation? {
        guard selector.id == ClaudeLaunchOption.permissionMode else { return nil }
        return ComposerSessionOptionsProjection.permissionModeConfirmations[value]
    }

    private static func providerAction(_ action: ProviderCapabilityAction) -> HarnessSettingsControl {
        HarnessSettingsControl(
            id: "action.\(action.id)",
            title: action.title,
            description: ProviderCapabilityAccessibility.actionHint(for: action),
            systemImage: action.systemImage,
            kind: .action(buttonTitle: L10n.string("Run"), command: .performProviderAction(id: action.id))
        )
    }

    static func selectorSymbol(for category: String?) -> String {
        switch category {
        case "model": "cpu"
        case "mode": "switch.2"
        case "thought_level", "model_config": "brain"
        default: "slider.horizontal.3"
        }
    }

    // MARK: - Skills and plugins

    private static func skillItem(_ skill: CodexSkillSummary) -> HarnessSettingsListItem {
        HarnessSettingsListItem(
            id: skill.id,
            title: skill.displayName,
            description: skill.description.isEmpty ? nil : skill.description,
            detail: skill.scope,
            systemImage: "wand.and.stars",
            badges: [],
            switchState: .init(target: .codexSkill(path: skill.path), isOn: skill.enabled)
        )
    }

    /// A Claude Code plugin the account installed, on or off. Its marketplace is the row's detail,
    /// as a Codex plugin's is.
    private static func accountPluginItem(_ plugin: HarnessAccountPlugin) -> HarnessSettingsListItem {
        HarnessSettingsListItem(
            id: plugin.id,
            title: plugin.name,
            description: plugin.description,
            detail: plugin.marketplace ?? plugin.id,
            systemImage: "puzzlepiece.extension",
            badges: [],
            switchState: .init(target: .accountPlugin(id: plugin.id), isOn: plugin.isEnabled)
        )
    }

    private static func pluginItem(_ plugin: CodexPluginSummary) -> HarnessSettingsListItem {
        HarnessSettingsListItem(
            id: plugin.id,
            title: plugin.displayName,
            description: plugin.description.flatMap { $0.isEmpty ? nil : $0 },
            detail: plugin.marketplace,
            systemImage: "puzzlepiece.extension",
            badges: plugin.statusLabels.map { label in
                switch label {
                case .installed: .init(text: label.text, tone: .positive)
                case .available: .init(text: label.text, tone: .neutral)
                case .disabled: .init(text: label.text, tone: .warning)
                }
            }
        )
    }
}

/// The app model calls a harness settings sheet makes, bound to one task by the window. Each
/// command goes to the same call the former Codex or provider sheet made.
@MainActor
struct HarnessSettingsActions {
    var loadCodex: () async -> Void
    var loadProvider: () async -> Void
    var selectCodexMode: (CodexCollaborationPreset.ID?) async -> Void
    var setProviderOption: (String, String) async -> Void
    var performProviderAction: (String) async -> Void
    var fork: () async -> Void
    var reviewCodexWorkingTree: () async -> Void
    var loadSwitches: () async -> Void
    var setSwitch: (HarnessSettingsSwitch, Bool) async -> Void
    var dismiss: () -> Void

    /// Rereads the sheet's capabilities from its source, then what its switches stand for.
    func refresh(_ source: HarnessSettingsSource) async {
        switch source {
        case .codex: await loadCodex()
        case .provider: await loadProvider()
        }
        await loadSwitches()
    }

    /// What the sheet reads as it opens: its source when the task does not have it yet, and what
    /// its switches stand for every time, since the harness's own app, its CLI or another task may
    /// have changed that since.
    func open(_ source: HarnessSettingsSource, sourceIsLoaded: Bool) async {
        if sourceIsLoaded { await loadSwitches() } else { await refresh(source) }
    }

    /// Closes the sheet first when the command continues outside it, then starts the command.
    func perform(_ command: HarnessSettingsCommand) {
        if command.dismissesSheet { dismiss() }
        Task { await run(command) }
    }

    /// The app model call for `command`.
    func run(_ command: HarnessSettingsCommand) async {
        switch command {
        case let .selectCodexMode(id): await selectCodexMode(id)
        case let .setProviderOption(id, value): await setProviderOption(id, value)
        case let .performProviderAction(id): await performProviderAction(id)
        case .fork: await fork()
        case .reviewCodexWorkingTree: await reviewCodexWorkingTree()
        case let .setSwitch(target, enabled): await setSwitch(target, enabled)
        }
    }
}

extension HarnessSettingsActions {
    /// The calls the former sheets made for `session`, from the window's model.
    init(model: AppModel, session: SessionRecord, dismiss: @escaping () -> Void) {
        self.init(
            loadCodex: { await model.loadCodexCapabilities(for: session) },
            loadProvider: { await model.loadProviderCapabilities(for: session) },
            selectCodexMode: { await model.selectCodexMode($0, for: session) },
            setProviderOption: { await model.setProviderOption($0, value: $1, for: session) },
            performProviderAction: { await model.performProviderAction($0, for: session) },
            fork: { _ = await model.branch(session) },
            reviewCodexWorkingTree: { await model.reviewCodexWorkingTree(session) },
            loadSwitches: { await model.loadHarnessSwitches(for: session) },
            setSwitch: { await model.setHarnessSwitch($0, enabled: $1, for: session) },
            dismiss: dismiss
        )
    }
}

extension AppModel {
    /// What a task's harness settings sheet shows now.
    func harnessSettings(for session: SessionRecord) -> HarnessSettingsSheetContent {
        HarnessSettingsSheetProjection.content(
            source: HarnessSettingsSource(harness: session.harness),
            codex: codexCapabilitiesBySessionID[session.id] ?? .empty,
            provider: providerCapabilitiesBySessionID[session.id] ?? .empty,
            switches: harnessSwitchesBySessionID[session.id] ?? HarnessSwitchState(),
            canBranch: canBranch(session)
        )
    }

    /// Whether the sheet has what it shows for this task; it reads its source when it opens
    /// otherwise. Codex counts only the sheet's own listing, because the composer stores a Codex
    /// state with just the model list and skills. A provider's state is used as it is, so a
    /// detached task's saved metadata (Grok) is shown without waking the runtime.
    func hasLoadedHarnessSettings(for session: SessionRecord) -> Bool {
        switch HarnessSettingsSource(harness: session.harness) {
        case .codex: codexCapabilitiesBySessionID[session.id]?.hasListedCapabilities == true
        case .provider: providerCapabilitiesBySessionID[session.id] != nil
        }
    }
}
