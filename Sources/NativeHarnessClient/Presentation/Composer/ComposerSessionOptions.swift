import Foundation

/// What one composer offers for its harness: the session controls in the shared bottom row and the
/// paths its sends, commands and queue take. The frame, places and kinds of control are the same
/// for every harness; the choices, their names, effects and current values stay the provider's own.
/// `ComposerSessionOptionsProjection` is the only place that tells harnesses
/// apart for the composer; the views read these values.
struct ComposerSessionOptions: Equatable {
    /// The harness's own name, as the empty composer asks for it.
    var harnessName: String
    /// What a turn from this composer can carry (images, audio, mentions).
    var input: HarnessComposerInputPolicy
    /// `!` switches the composer to running a shell command, as the Claude app has it, where the
    /// window can run one for the task.
    var bashMode = false
    var submission: ComposerSubmissionPath
    var draftRetention: ComposerDraftRetention = .none
    /// The follow-up queue and steering while a turn runs, for a provider that has them.
    var followUp: ComposerFollowUpOptions?
    /// The slash command list, for a provider that has one.
    var commands: ComposerCommandOptions?
    /// Whether the composer rereads the session's status (models, skills, selectors) when the
    /// task attaches or detaches. Reading never wakes a detached task.
    var refreshesStatusOnAttach = false

    // MARK: Session controls, in the bottom row's order

    var mode: ComposerModeSlot?
    var permission: ComposerPermissionSlot?
    var skills: ComposerSkillsSlot?
    var isLoadingSettings = false
    var settingsError: String?
    var contextUsage: HarnessProtocolUsage?
    /// The token counts the context ring's details list (D5).
    var usageBreakdowns: [ComposerUsageBreakdown] = []
    /// Whether the harness reports its context window once a turn has run, so the ring is there,
    /// empty, before it has (Claude Code, Codex). Others show it once they report one.
    var reportsContextWindow = false
    /// How the context window's "Compact session" compacts, for a harness the composer can ask.
    var compact: ComposerCompactPath?
    var model: ComposerModelSlot?
    /// The "+" menu's connector list: the session's MCP servers and Yardlet's connectors.
    var connectors: ComposerConnectorsSlot?

    var placeholder: String { L10n.format("Ask %@…", harnessName) }
}

/// How a composer compacts its task's context: Claude Code's `/compact` sent as the next message,
/// or Codex's own Compact command.
enum ComposerCompactPath: Equatable, Sendable {
    case providerCommand(String)
    case codexCommand
}

/// A choice from a session control, in the form the path that applies it takes.
enum ComposerSessionChoice: Equatable, Sendable {
    /// Codex's typed model, effort and speed, applied together.
    case codexModel(CodexModelSelection)
    /// Codex's sandbox policy for the next turn.
    case codexRunLocation(CodexRunLocation)
    /// The provider's own selector and value.
    case providerOption(id: String, value: String)
}

/// How a control's choices are applied.
enum ComposerApplyPath: Equatable {
    /// The menu's model, effort and speed rows resolve against Codex's typed catalog.
    case codexModel(CodexModelCatalog)
    case codexRunLocation
    /// The selector's own ID and value go to the provider (or, before a task exists, to the draft).
    case providerOption

    func choice(id: String, value: String) -> ComposerSessionChoice? {
        switch self {
        case let .codexModel(catalog):
            CodexModelMenuProjection.selection(id: id, value: value, catalog: catalog).map { .codexModel($0) }
        case .codexRunLocation:
            CodexRunLocation(rawValue: value).map { .codexRunLocation($0) }
        case .providerOption:
            .providerOption(id: id, value: value)
        }
    }
}

/// How a typed draft leaves the composer.
enum ComposerSubmissionPath: Equatable, Sendable {
    /// Codex's typed draft, whose own envelopes (skills, audio, mentions) and built-in commands
    /// travel as they are; the same submit queues and steers.
    case codexDraft
    /// The harness-neutral input, after the input policy has checked what it carries.
    case providerInput
}

/// When a sent draft stays in the composer instead of being cleared.
enum ComposerDraftRetention: Equatable, Sendable {
    /// Codex's `/compact` and `/review` run from the draft.
    case codexBuiltinCommands
    /// Claude's chat reset commands (`/clear`) clear only once the new chat exists.
    case claudeChatReset
    case none

    func keepsDraft(afterSending text: String) -> Bool {
        switch self {
        case .codexBuiltinCommands: CodexComposerCommands.isBuiltin(text)
        case .claudeChatReset: ClaudeComposerCommands.isResetCandidate(text)
        case .none: false
        }
    }
}

/// The follow-up queue a provider keeps while its turn runs.
struct ComposerFollowUpOptions: Equatable, Sendable {
    /// Whose queue semantics the chips follow; the wording is the provider's (plan D9).
    typealias Policy = FollowUpPolicy

    var policy: Policy
    /// Which submit queues or steers a typed draft.
    var delivery: ComposerSubmissionPath

    /// What the composer says Return and ⌘Return send while a turn runs, in place of its placeholder.
    func runningPlaceholder(preferred: FollowUpMode) -> String { policy.runningPlaceholder(preferred: preferred) }

    /// The same for VoiceOver.
    func returnHint(preferred: FollowUpMode) -> String { policy.returnHint(preferred: preferred) }

    /// What ⌘Return sends while a turn runs: the other of the follow-up setting, which Return
    /// follows, as the Codex app inverts its follow-up behavior for one message with ⌘Enter (by
    /// default Return steers and ⌘Return queues for after the turn). Nil where ⌘Return is Return:
    /// the harness cannot steer, or that is steering and the turn cannot be steered yet.
    func alternateAction(preferred: FollowUpMode, canSteer: Bool) -> CodexComposerAction? {
        guard policy.steers else { return nil }
        return Self.alternateAction(preferred: preferred, canSteer: canSteer)
    }

    static func alternateAction(preferred: FollowUpMode, canSteer: Bool) -> CodexComposerAction? {
        let other = preferred.other
        return other == .steer && !canSteer ? nil : other.action
    }
}

/// One queued message's chip: where it goes, said on the chip, and what it offers.
struct ComposerQueueChip: Equatable, Sendable {
    let icon: String
    /// Where the message goes, shown on the chip: when the turn ends, or at Claude's next step.
    let status: String
    let help: String?
    /// "Send now", which leaves the turn running (Codex's Steer, Claude Code's next step).
    let send: Send?
    /// The one action that stops the running turn for the message, in its own words (Claude
    /// Code's Send now), offered in the chip's menu only.
    let stopAndSend: String?
    let removeLabel: String
    let canMoveUp: Bool
    let canMoveDown: Bool

    struct Send: Equatable, Sendable {
        let label: String
        let icon: String
        /// Where it puts the message, without stopping the turn.
        let help: String
    }

    /// The same chip for every provider, in the provider's words. A message the provider holds
    /// says when it reads it and, where sent messages cannot move, stays where it is.
    static func make(policy: FollowUpPolicy, queue: [QueuedFollowUp], at index: Int,
                     canSend: Bool) -> ComposerQueueChip {
        let item = queue[index]
        let movable = { (other: Int) in
            queue.indices.contains(other)
                && (policy.canReorderSent || (item.state != .sent && queue[other].state != .sent))
        }
        let stopAndSend = canSend ? policy.stopAndSendLabel : nil
        if policy.holdsSentMessages, item.state == .sent {
            return ComposerQueueChip(
                icon: "checkmark.circle", status: policy.heldStatus, help: policy.heldStatus, send: nil,
                stopAndSend: stopAndSend, removeLabel: policy.removeLabel, canMoveUp: false, canMoveDown: false)
        }
        // A failed message says why on every provider, beside the task's own error.
        if item.state == .failed {
            return ComposerQueueChip(
                icon: "exclamationmark.circle", status: L10n.string("Failed"),
                help: item.failureMessage, send: nil, stopAndSend: nil,
                removeLabel: policy.removeLabel, canMoveUp: movable(index - 1), canMoveDown: movable(index + 1))
        }
        return ComposerQueueChip(
            icon: "clock", status: policy.pendingHelp, help: policy.pendingHelp,
            send: canSend ? policy.sendLabel.map {
                Send(label: $0, icon: "arrow.turn.up.right", help: policy.sendHelp ?? $0)
            } : nil,
            stopAndSend: stopAndSend,
            removeLabel: policy.removeLabel, canMoveUp: movable(index - 1), canMoveDown: movable(index + 1))
    }
}

/// A provider's slash command list.
struct ComposerCommandOptions: Equatable {
    enum Source: Equatable {
        /// The Codex app's commands, built from the composer's own state when the list opens.
        case codexCatalog
        /// The commands the session advertised.
        case provider([ProviderComposerCommand])
    }

    enum Selection: Equatable, Sendable {
        /// A chosen command runs (Codex); nothing is sent.
        case runCodexCommand
        /// A chosen command is typed into the draft.
        case insert
    }

    enum Preparation: Equatable, Sendable {
        /// Reads what the Codex list shows beyond its fixed commands, without a turn.
        case codexCommands
        /// Rereads an attached session's status, or a detached task's saved settings.
        case providerSettings
    }

    var source: Source
    var selection: Selection
    var preparation: Preparation
    /// Why the list could not be read.
    var error: String?
    /// The typed `/` list prepares itself when it opens.
    var preparesWhenListOpens = false
    /// Code review needs to know whether the folder is in Git.
    var readsGitRepository = false
    /// An explicit `/` typed into a detached task's composer reads the session's catalog.
    var readsCatalogWhenTypedDetached = false
}

/// The bottom row's mode control.
enum ComposerModeSlot: Equatable {
    /// Codex's collaboration mode: the Codex app's "Plan" indicator, shown while Plan is on;
    /// choosing it turns Plan off.
    case planIndicator
    /// The provider's own mode selector.
    case selector(ProviderCapabilitySelector, canChoose: Bool, apply: ComposerApplyPath)
}

/// The bottom row's permissions control: the policy the next turn runs with.
struct ComposerPermissionSlot: Equatable {
    struct Confirmation: Equatable, Sendable {
        let title: String
        let message: String
        let confirm: String
    }

    struct Explanation: Equatable, Sendable {
        let text: String
        let icon: String
    }

    /// The current policy's name, on the button and in the menu's heading.
    var title: String
    /// The provider's policies, when it offers more than one.
    var selector: ProviderCapabilitySelector?
    /// Choices the provider asks about before applying, by value, in its own words.
    var confirmations: [String: Confirmation] = [:]
    /// Choices apply now. Otherwise the menu shows the current one and says how to change it.
    var canChoose: Bool
    /// Opening the menu first reads the choices.
    var preparesBeforeOpening = false
    var apply: ComposerApplyPath
    /// The policy lifts the sandbox or skips asking (drawn in orange).
    var isElevated = false
    /// A request waits for an answer (drawn in orange, with a warning shield).
    var hasPendingRequest = false
    /// What the menu says when there is nothing to choose.
    var explanation: Explanation?
    var accessibilityHint: String
    var help: String?

    var showsChoices: Bool { (selector?.choices.count ?? 0) > 1 }
}

/// Skills the composer can attach to the next message.
struct ComposerSkillsSlot: Equatable {
    var skills: [CodexSkillSummary]
}

/// The model, effort and speed menu beside Send.
struct ComposerModelSlot: Equatable {
    var menu: ComposerModelMenu
    var apply: ComposerApplyPath
}

/// The one place that tells harnesses apart for the composer. Every other composer file reads
/// `ComposerSessionOptions` (HarnessBranchLintTests).
enum ComposerSessionOptionsProjection {
    /// A task composer's options.
    ///
    /// - Parameters:
    ///   - session: the task. Without one, a provider's session controls are not offered.
    ///   - entries: the conversation, whose pending requests a provider's permissions control
    ///     shows. Codex's control does not show them until its conversation model counts its
    ///     own requests (plan A6.3).
    static func make(
        harness: HarnessKind,
        session: SessionRecord?,
        codexCapabilities: CodexCapabilityState = .empty,
        providerCapabilities: ProviderCapabilityState?,
        providerUsage: HarnessProtocolUsage?,
        codexTokenUsage: CodexThreadTokenUsage? = nil,
        entries: [TranscriptEntry] = [],
        isAttached: Bool
    ) -> ComposerSessionOptions {
        let input = HarnessComposerInputPolicy(harness: harness,
                                               negotiatedImageInput: providerCapabilities?.acceptsImageInput)
        if harness == .codex {
            return codex(codexCapabilities, tokenUsage: codexTokenUsage, input: input, harness: harness)
        }
        var options = ComposerSessionOptions(harnessName: harness.displayName, input: input,
                                             submission: .providerInput)
        // A harness that takes no message while its turn runs keeps what is sent meanwhile for
        // the next turn; Claude Code's own queue replaces this below.
        options.followUp = ComposerFollowUpOptions(policy: .afterTurn, delivery: .providerInput)
        if harness == .claudeCode {
            // The window supplies the shell; without it there is no bash mode.
            options.bashMode = true
            options.draftRetention = .claudeChatReset
            options.followUp = ComposerFollowUpOptions(policy: .claudeCode, delivery: .providerInput)
            options.commands = ComposerCommandOptions(
                source: .provider(providerCapabilities?.composerCommands ?? []), selection: .insert,
                preparation: .providerSettings, error: providerCapabilities?.errors.first,
                readsCatalogWhenTypedDetached: true)
        }
        options.contextUsage = providerUsage
        options.usageBreakdowns = ComposerUsageBreakdown.provider(providerUsage)
        if harness == .claudeCode {
            options.reportsContextWindow = true
            options.compact = .providerCommand("/compact")
        }
        options.connectors = connectorsSlot(harness: harness, servers: providerCapabilities?.mcpServers)
        guard let session else { return options }
        options.refreshesStatusOnAttach = true
        let selectors = ConversationSessionStatusProjection.inlineSelectors(from: providerCapabilities)
        func selector(_ role: ConversationSessionControlRole) -> ProviderCapabilitySelector? {
            selectors.first { ConversationSessionStatusProjection.role(for: $0) == role }
        }
        if let mode = selector(.mode) {
            options.mode = .selector(mode, canChoose: isAttached, apply: .providerOption)
        }
        options.permission = providerPermission(
            selector(.permission), harness: harness, session: session,
            pendingRequestCount: ConversationSessionStatusProjection.pendingPermissionCount(in: entries),
            isAttached: isAttached)
        options.isLoadingSettings = providerCapabilities?.isLoading == true
        options.settingsError = providerCapabilities?.errors.first
        let menu = ComposerModelMenu.provider(
            selectors, speed: providerCapabilities?.selectors.first { $0.id == "fastMode" },
            canChoose: isAttached || providerCapabilities?.offersModelsBeforeAttach == true)
        if !menu.isEmpty { options.model = ComposerModelSlot(menu: menu, apply: .providerOption) }
        return options
    }

    private static func codex(_ capabilities: CodexCapabilityState, tokenUsage: CodexThreadTokenUsage?,
                              input: HarnessComposerInputPolicy, harness: HarnessKind) -> ComposerSessionOptions {
        var options = ComposerSessionOptions(harnessName: harness.displayName, input: input, submission: .codexDraft,
                                             draftRetention: .codexBuiltinCommands)
        options.followUp = ComposerFollowUpOptions(policy: .codex, delivery: .codexDraft)
        options.commands = ComposerCommandOptions(source: .codexCatalog, selection: .runCodexCommand,
                                                  preparation: .codexCommands, preparesWhenListOpens: true,
                                                  readsGitRepository: true)
        options.refreshesStatusOnAttach = true
        if capabilities.modes.first(where: { $0.id == capabilities.selectedModeID })?.mode == "plan" {
            options.mode = .planIndicator
        }
        options.permission = codexPermission(capabilities.selectedRunLocation)
        let skills = capabilities.skills.filter(\.enabled)
        if !skills.isEmpty { options.skills = ComposerSkillsSlot(skills: skills) }
        options.contextUsage = codexContextUsage(tokenUsage)
        options.usageBreakdowns = ComposerUsageBreakdown.codex(tokenUsage)
        options.reportsContextWindow = true
        options.compact = .codexCommand
        options.connectors = connectorsSlot(harness: harness, servers: capabilities.mcpServers)
        options.model = ComposerModelSlot(menu: .codex(capabilities.modelCatalog),
                                          apply: .codexModel(capabilities.modelCatalog))
        return options
    }

    /// A session gets Yardlet's connectors where its harness takes the Yardlet MCP server per
    /// session (Claude, Codex, ACP); the servers are whatever the harness reported.
    private static func connectorsSlot(harness: HarnessKind, servers: [HarnessMCPServerStatus]?) -> ComposerConnectorsSlot? {
        let route = AgentToolInjectionRoute.route(for: harness)
        let carries = route != nil
        guard carries || servers != nil else { return nil }
        // Claude Code lists the server's tools again on `notifications/tools/list_changed`.
        return ComposerConnectorsSlot(sessionServers: servers, carriesYardletConnectors: carries,
                                      toolListFollowsNextTurn: carries && route == .claudeMCPConfig)
    }

    /// Codex's four sandbox policies. Full access asks first, in Codex's words.
    static func codexPermission(_ location: CodexRunLocation) -> ComposerPermissionSlot {
        ComposerPermissionSlot(
            title: location.displayName,
            selector: ProviderCapabilitySelector(
                id: "runLocation", name: L10n.string("Permissions"), description: nil, category: "permission",
                currentValue: location.rawValue,
                choices: CodexRunLocation.allCases.map { .init(value: $0.rawValue, name: $0.displayName, description: nil) }),
            confirmations: [CodexRunLocation.dangerFullAccess.rawValue: .init(
                title: L10n.string("Allow full access?"),
                // Full access is the Codex app's: no sandbox and no asking (`approvalPolicy: never`).
                message: L10n.string("Codex will run commands, use the internet, and create and edit files anywhere on this Mac without asking."),
                confirm: L10n.string("Allow full access"))],
            canChoose: true, apply: .codexRunLocation, isElevated: location == .dangerFullAccess,
            accessibilityHint: L10n.string("Choose the sandbox policy for the next Codex turn"))
    }

    /// The provider's permission selector, or what the session says about permissions without one.
    private static func providerPermission(
        _ liveSelector: ProviderCapabilitySelector?, harness: HarnessKind, session: SessionRecord,
        pendingRequestCount: Int, isAttached: Bool
    ) -> ComposerPermissionSlot? {
        let hasPending = session.status == .waitingForApproval || pendingRequestCount > 0
        let supportsRequests = ConversationSessionStatusProjection.supportsPermissionRequests(harness)
        var selector = liveSelector
        if selector == nil, harness == .claudeCode, !hasPending {
            // A Claude task not attached yet shows the mode it will launch in (without a saved one,
            // the launch flag's default) and its modes; opening the menu reads them from the CLI.
            selector = claudeModeSelector(current: session.providerOptions[ClaudeLaunchOption.permissionMode])
        }
        if selector == nil, harness == .antigravityCLI {
            // An Antigravity task not attached yet shows the mode it attaches with.
            selector = AntigravityPermissionMode.askingSelector(current: antigravitySavedPermissionMode(session))
        }
        guard selector != nil || hasPending || supportsRequests else { return nil }
        let title: String
        if let selector {
            title = ProviderCapabilityAccessibility.selectedChoiceName(for: selector)
        } else if hasPending {
            title = L10n.string("Approval required")
        } else {
            title = supportsRequests ? L10n.string("On request") : L10n.string("Unavailable")
        }
        let choiceCount = selector?.choices.count ?? 0
        var slot = ComposerPermissionSlot(
            title: title, selector: selector,
            confirmations: permissionConfirmations(for: harness),
            canChoose: isAttached,
            preparesBeforeOpening: !isAttached && choiceCount > 1, apply: .providerOption,
            isElevated: selector.map(isElevated) ?? false,
            hasPendingRequest: hasPending,
            accessibilityHint: L10n.string("Show permission details"), help: L10n.string("Show permission details"))
        if choiceCount <= 1 {
            let icon = hasPending ? "hand.raised.fill" : supportsRequests ? "hand.raised" : "info.circle"
            let text = if hasPending {
                L10n.string("Review the pending request card to approve or deny this action.")
            } else if selector != nil {
                L10n.string("The active runtime exposes only this permission policy.")
            } else if supportsRequests {
                L10n.string("Protected actions ask before they run. Approve or deny them from the request card.")
            } else {
                L10n.string("This harness does not expose permission controls for this session.")
            }
            slot.explanation = .init(text: text, icon: icon)
        }
        return slot
    }

    /// A policy that lifts the sandbox or skips asking, read from its name or its value: Codex's
    /// Full access, Claude Code's Bypass permissions, or another provider's "full" or "bypass".
    private static func isElevated(_ selector: ProviderCapabilitySelector) -> Bool {
        ConversationSessionStatusProjection.isElevatedPermission(ProviderCapabilityAccessibility.selectedChoiceName(for: selector))
            || ClaudePermissionMode.isElevated(selector.currentValue)
            || (selector.id == AntigravityPermissionMode.optionID && AntigravityPermissionMode.isElevated(selector.currentValue))
    }

    /// The mode an Antigravity task saved, under its current key or the earlier `executionMode`.
    static func antigravitySavedPermissionMode(_ session: SessionRecord) -> String? {
        session.providerOptions[AntigravityPermissionMode.optionID]
            ?? session.providerOptions[StructuredHeadlessOptionID.executionMode]
    }

    /// Claude Code's permission modes, as its selector offers them, with `current` chosen (Manual
    /// when nothing or an unknown mode was saved).
    private static func claudeModeSelector(current: String?) -> ProviderCapabilitySelector {
        ProviderCapabilitySelector(
            id: ClaudeLaunchOption.permissionMode, name: L10n.string("Permission mode"),
            description: L10n.string("Controls how Claude Code asks before using tools."), category: "mode",
            currentValue: current.flatMap { ClaudePermissionMode.selectable.contains($0) ? $0 : nil }
                ?? ClaudePermissionMode.manual,
            choices: ClaudePermissionMode.selectable.compactMap { mode in
                ClaudePermissionMode.displayName(mode).map { ProviderCapabilityChoice(value: mode, name: $0, description: nil) }
            })
    }

    /// Bypass permissions asks first, as Codex's Full access does.
    static var claudePermissionConfirmations: [String: ComposerPermissionSlot.Confirmation] {
        [ClaudePermissionMode.bypassPermissions: .init(
            title: L10n.string("Bypass permission checks?"),
            message: L10n.string("Claude Code will change files and run commands without asking."),
            confirm: L10n.string("Use bypass permissions"))]
    }

    /// Antigravity's Bypass permissions (`--dangerously-skip-permissions`) asks the same way.
    static var antigravityPermissionConfirmations: [String: ComposerPermissionSlot.Confirmation] {
        [AntigravityPermissionMode.bypass: .init(
            title: L10n.string("Bypass permission checks?"),
            message: L10n.string("Antigravity will change files and run commands without asking."),
            confirm: L10n.string("Use bypass permissions"))]
    }

    /// The choices a harness's permission menu asks about first, in its own words.
    static func permissionConfirmations(for harness: HarnessKind) -> [String: ComposerPermissionSlot.Confirmation] {
        switch harness {
        case .claudeCode: claudePermissionConfirmations
        case .antigravityCLI: antigravityPermissionConfirmations
        default: [:]
        }
    }

    /// Every `permissionMode` selector's confirmations, for a surface that does not know the
    /// harness (the harness settings sheet). The values do not overlap between harnesses.
    static var permissionModeConfirmations: [String: ComposerPermissionSlot.Confirmation] {
        claudePermissionConfirmations.merging(antigravityPermissionConfirmations) { claude, _ in claude }
    }

    /// The last turn's tokens against the model window, as Codex's `/status` and the Codex app's
    /// ring count them (`min(last.totalTokens, window) / window`). Without a window there is no
    /// ring (`ComposerContextSummary`), rather than a guess.
    static func codexContextUsage(_ usage: CodexThreadTokenUsage?) -> HarnessProtocolUsage? {
        guard let usage, usage.last.totalTokens >= 0 else { return nil }
        let window = usage.modelContextWindow.flatMap { $0 > 0 ? $0 : nil }
        return HarnessProtocolUsage(inputTokens: nil, cachedInputTokens: nil, outputTokens: nil, reasoningTokens: nil,
            totalCostUSD: nil, contextWindowTokens: window.map(UInt64.init),
            contextUsedTokens: window.map { UInt64(min(usage.last.totalTokens, $0)) }, extensionValues: [:])
    }
}

/// Token counts the context ring's details list under one heading (D5): a provider's reported usage,
/// or, for Codex, its last turn and the thread's running total, as the Codex usage footer listed them.
struct ComposerUsageBreakdown: Equatable, Sendable {
    struct Count: Equatable, Sendable {
        let label: String
        let tokens: UInt64
    }

    let title: String
    var total: UInt64?
    var counts: [Count]
    /// Cached input as a share of input, where the provider's counts make the ratio honest.
    var cacheHitFraction: Double? = nil

    /// The usage a provider reported, under "Usage", when it reported any tokens or a cost.
    static func provider(_ usage: HarnessProtocolUsage?) -> [ComposerUsageBreakdown] {
        guard let usage, usage.inputTokens != nil || usage.cachedInputTokens != nil || usage.outputTokens != nil
            || usage.reasoningTokens != nil || usage.totalCostUSD != nil else { return [] }
        let counts: [(String, UInt64?)] = [
            ("Input", usage.inputTokens), ("Cached input", usage.cachedInputTokens),
            ("Output", usage.outputTokens), ("Reasoning", usage.reasoningTokens)
        ]
        return [ComposerUsageBreakdown(
            title: L10n.string("Usage"),
            total: ConversationSessionStatusProjection.totalUsageTokens(usage),
            counts: counts.compactMap { label, tokens in tokens.map { Count(label: L10n.string(label), tokens: $0) } }
        )]
    }

    /// Codex's last turn and the thread's running total, every count the footer listed.
    static func codex(_ usage: CodexThreadTokenUsage?) -> [ComposerUsageBreakdown] {
        guard let usage else { return [] }
        func breakdown(_ title: String, _ value: CodexTokenUsageBreakdown) -> ComposerUsageBreakdown {
            let counts: [(String, Int64)] = [
                ("Input", value.inputTokens), ("Cached input", value.cachedInputTokens),
                ("Cache write", value.cacheWriteInputTokens), ("Output", value.outputTokens),
                ("Reasoning", value.reasoningOutputTokens)
            ]
            return ComposerUsageBreakdown(
                title: L10n.string(title), total: UInt64(max(0, value.totalTokens)),
                counts: counts.map { Count(label: L10n.string($0.0), tokens: UInt64(max(0, $0.1))) },
                cacheHitFraction: value.cacheHitFraction
            )
        }
        return [breakdown("Last turn", usage.last), breakdown("Cumulative", usage.total)]
    }
}

/// The app paths behind a task's composer, which the window wires its `ComposerActions` to.
struct ComposerWiring: Equatable, Sendable {
    enum SettingsSource: Equatable, Sendable {
        /// Codex's model list, read from its own App Server.
        case codexModels
        /// The provider's capability selectors.
        case providerCapabilities
    }

    /// Which submit the composer's drafts take (`ComposerSessionOptions.submission`).
    var submission: ComposerSubmissionPath
    /// Whose follow-up queue the composer shows and acts on.
    var followUpQueue: FollowUpPolicy?
    /// Where the session controls read choices they do not have yet.
    var settings: SettingsSource
    /// The composer runs the Codex app's slash commands.
    var runsCodexCommands: Bool
    /// The composer has bash mode, whose commands the window runs.
    var runsShellCommands: Bool
}

extension ComposerSessionOptionsProjection {
    static func wiring(for harness: HarnessKind) -> ComposerWiring {
        let followUpQueue = FollowUpPolicy(harness: harness)
        if harness == .codex {
            return ComposerWiring(submission: .codexDraft, followUpQueue: followUpQueue, settings: .codexModels,
                                  runsCodexCommands: true, runsShellCommands: false)
        }
        return ComposerWiring(submission: .providerInput, followUpQueue: followUpQueue, settings: .providerCapabilities,
                              runsCodexCommands: false, runsShellCommands: harness == .claudeCode)
    }
}

// MARK: - The new-task composer

extension ComposerSessionOptionsProjection {
    /// The new-task composer's options: what the chosen harness can take before its task exists.
    /// The model and effort come from the lists and settings Yardlet keeps; Claude Code also starts
    /// in a chosen permission mode (its `--permission-mode` launch flag). Controls that cannot take
    /// effect when the task starts are not offered.
    @MainActor
    static func newTask(harness: HarnessKind, choice: NewTaskModelChoice?, catalogs: HarnessModelCatalogStore?,
                        connection: ProviderConnection?, workspaceURL: URL?) -> ComposerSessionOptions {
        var options = ComposerSessionOptions(harnessName: harness.displayName,
                                             input: HarnessComposerInputPolicy(harness: harness),
                                             submission: harness == .codex ? .codexDraft : .providerInput)
        if let catalogs, let menu = NewTaskModelProjection.menu(harness: harness, choice: choice, catalogs: catalogs,
                                                                connection: connection, workspaceURL: workspaceURL) {
            options.model = ComposerModelSlot(menu: menu, apply: .providerOption)
        }
        if harness == .claudeCode {
            // The home list reads the commands from a session that sends nothing.
            options.commands = ComposerCommandOptions(source: .provider([]), selection: .insert,
                                                      preparation: .providerSettings)
            options.permission = claudeLaunchPermission(choice?.permissionMode)
        }
        if harness == .antigravityCLI {
            options.permission = antigravityLaunchPermission(choice?.permissionMode)
        }
        return options
    }

    /// Antigravity's permission modes for the new task. Bypass permissions asks first here too.
    private static func antigravityLaunchPermission(_ chosen: String?) -> ComposerPermissionSlot {
        let selector = AntigravityPermissionMode.askingSelector(current: chosen)
        return ComposerPermissionSlot(
            title: ProviderCapabilityAccessibility.selectedChoiceName(for: selector), selector: selector,
            confirmations: antigravityPermissionConfirmations, canChoose: true, apply: .providerOption,
            isElevated: isElevated(selector),
            accessibilityHint: L10n.string("Show permission details"), help: L10n.string("Show permission details"))
    }

    /// Claude Code's permission modes, the ones its selector offers, for the task's launch.
    private static func claudeLaunchPermission(_ chosen: String?) -> ComposerPermissionSlot {
        let selector = claudeModeSelector(current: chosen)
        return ComposerPermissionSlot(
            title: ProviderCapabilityAccessibility.selectedChoiceName(for: selector), selector: selector,
            confirmations: claudePermissionConfirmations, canChoose: true, apply: .providerOption,
            isElevated: isElevated(selector),
            accessibilityHint: L10n.string("Show permission details"), help: L10n.string("Show permission details"))
    }
}

/// The new-task screen's model menu: what the chosen harness and account will start a task on —
/// the choice remembered for that harness, else the account's settings, else the runtime's
/// default — from the list the runtime last gave Yardlet. Harnesses whose models Yardlet cannot
/// know before a session exists show no menu.
@MainActor
enum NewTaskModelProjection {
    static func menu(harness: HarnessKind, choice: NewTaskModelChoice?, catalogs: HarnessModelCatalogStore,
                     connection: ProviderConnection?, workspaceURL: URL?) -> ComposerModelMenu? {
        switch harness {
        case .claudeCode:
            let catalog = catalogs.claudeModels(for: connection)
            let selectors = ClaudeComposerModelProjection.selectors(
                model: choice?.model, effort: choice?.effort,
                defaults: catalogs.defaults(for: .claudeCode, connection: connection, workspaceURL: workspaceURL),
                catalog: catalog)
            return .provider(selectors, speed: nil, canChoose: !catalog.isEmpty)
        case .codex:
            return .codex(codexCatalog(choice: choice, catalogs: catalogs, connection: connection))
        case .antigravityCLI:
            let catalog = catalogs.antigravity
            return .provider(antigravitySelectors(choice: choice, catalog: catalog), speed: nil,
                             canChoose: !catalog.isEmpty)
        default:
            return nil
        }
    }

    /// Antigravity's folded models and, for one with variants, its efforts, from the list a task
    /// last read. Before any has, the menu shows the default and opening it reads the list.
    static func antigravitySelectors(choice: NewTaskModelChoice?, catalog: [HarnessModelOption]) -> [ProviderCapabilitySelector] {
        let defaultChoice = ProviderCapabilityChoice(value: "default", name: L10n.string("Default"), description: nil)
        let current = catalog.first { $0.value == choice?.model }
        var selectors = [ProviderCapabilitySelector(
            id: StructuredHeadlessOptionID.model, name: L10n.string("Model"), description: nil, category: "model",
            currentValue: current?.value ?? "default",
            choices: [defaultChoice] + catalog.map { ProviderCapabilityChoice(value: $0.value, name: $0.name, description: nil) })]
        if let current, !current.effortLevels.isEmpty {
            selectors.append(ProviderCapabilitySelector(
                id: StructuredHeadlessOptionID.reasoningEffort, name: L10n.string("Reasoning effort"), description: nil,
                category: "thought_level",
                currentValue: choice?.effort.flatMap { current.effortLevels.contains($0) ? $0 : nil } ?? "default",
                choices: [defaultChoice] + current.effortLevels.map {
                    ProviderCapabilityChoice(value: $0, name: CodexReasoningLabel.name($0), description: nil)
                }))
        }
        return selectors
    }

    /// The remembered choice after picking `value` for `id`, or nil when the list does not offer it.
    static func choosing(_ id: String, value: String, harness: HarnessKind, choice: NewTaskModelChoice?,
                         catalogs: HarnessModelCatalogStore, connection: ProviderConnection?,
                         workspaceURL: URL?) -> NewTaskModelChoice? {
        switch harness {
        case .claudeCode:
            if id == ClaudeLaunchOption.permissionMode {
                guard ClaudePermissionMode.selectable.contains(value) else { return nil }
                var chosen = choice ?? NewTaskModelChoice(model: nil)
                chosen.permissionMode = value
                return chosen
            }
            let model = choice?.model
                ?? catalogs.defaults(for: .claudeCode, connection: connection, workspaceURL: workspaceURL)?.model
                ?? ClaudeComposerModelProjection.defaultModel
            // Choosing only an effort leaves the model to the account's settings.
            return ClaudeComposerModelProjection.choosing(id, value: value, model: model, effort: choice?.effort,
                                                          catalog: catalogs.claudeModels(for: connection))
                .map { NewTaskModelChoice(model: id == "model" ? $0.model : choice?.model, effort: $0.effort,
                                          permissionMode: choice?.permissionMode) }
        case .codex:
            let catalog = codexCatalog(choice: choice, catalogs: catalogs, connection: connection)
            return CodexModelMenuProjection.selection(id: id, value: value, catalog: catalog)
                .map { NewTaskModelChoice($0) }
        case .antigravityCLI:
            var chosen = choice ?? NewTaskModelChoice(model: nil)
            switch id {
            case StructuredHeadlessOptionID.permissionMode:
                guard AntigravityPermissionMode.askingSelector(current: nil).choices.contains(where: { $0.value == value })
                else { return nil }
                chosen.permissionMode = value == AntigravityPermissionMode.standard ? nil : value
            case StructuredHeadlessOptionID.model:
                if value == "default" {
                    chosen.model = nil
                    chosen.effort = nil
                } else {
                    guard let model = catalogs.antigravity.first(where: { $0.value == value }) else { return nil }
                    chosen.model = value
                    // The CLI refuses an effort the model does not take.
                    if let effort = chosen.effort, !model.effortLevels.contains(effort) { chosen.effort = nil }
                }
            case StructuredHeadlessOptionID.reasoningEffort:
                if value == "default" {
                    chosen.effort = nil
                } else {
                    guard let model = catalogs.antigravity.first(where: { $0.value == chosen.model }),
                          model.effortLevels.contains(value) else { return nil }
                    chosen.effort = value
                }
            default:
                return nil
            }
            return chosen
        default:
            return nil
        }
    }

    private static func codexCatalog(choice: NewTaskModelChoice?, catalogs: HarnessModelCatalogStore,
                                     connection: ProviderConnection?) -> CodexModelCatalog {
        CodexComposerModelProjection.catalog(
            live: CodexModelCatalog(), stored: choice?.codexSelection,
            defaults: catalogs.defaults(for: .codex, connection: connection, workspaceURL: nil),
            cached: catalogs.codexModels(for: connection))
    }
}
