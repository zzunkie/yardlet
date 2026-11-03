import Foundation
import YardletRemote

/// A host task's settings (docs/REMOTE_PROTOCOL.md §15.23) as the composer's bottom row reads them
/// (`ComposerSessionOptions`), so the local controls draw them: the mode or the Plan indicator, the permissions and the
/// model menu. Every choice goes back under the host's own ID and value (`ComposerApplyPath.providerOption`), and the
/// host applies it by the path its own menu takes.
enum RemoteTaskSettingsProjection {
    static func options(_ settings: [RemoteSetting], task: RemoteTask?) -> ComposerSessionOptions {
        let harness = HarnessKind(rawValue: task?.harness ?? HarnessKind.claudeCode.rawValue)
        var options = ComposerSessionOptions(harnessName: task?.harnessName ?? harness.displayName,
                                             input: HarnessComposerInputPolicy(harness: harness), submission: .providerInput)
        // A request waiting on the person, as the host's permissions control marks it (Codex's control does not).
        let isWaiting = harness != .codex && task?.pendingRequest != nil && task?.pendingKind != "browserHandoff"
        var menu = ComposerModelMenu()
        for setting in settings {
            switch setting.role {
            case "plan":
                options.mode = .planIndicator
            case "mode":
                options.mode = .selector(selector(setting), canChoose: setting.prepare != true, apply: .providerOption)
            case "permission":
                options.permission = permission(setting, isWaiting: isWaiting)
            case "model":
                menu.model = selector(setting)
            case "effort":
                menu.effort = selector(setting)
            case "speed":
                menu.speed = selector(setting)
            default:
                continue
            }
            if ["model", "effort", "speed"].contains(setting.role), setting.prepare == true { menu.canChoose = false }
        }
        if !menu.isEmpty { options.model = ComposerModelSlot(menu: menu, apply: .providerOption) }
        return options
    }

    private static func selector(_ setting: RemoteSetting) -> ProviderCapabilitySelector {
        ProviderCapabilitySelector(
            id: setting.id, name: setting.name, description: nil, category: setting.role, currentValue: setting.value,
            choices: setting.choices.map { ProviderCapabilityChoice(value: $0.value, name: $0.name, description: $0.description) })
    }

    private static func permission(_ setting: RemoteSetting, isWaiting: Bool) -> ComposerPermissionSlot {
        let selector = setting.choices.isEmpty ? nil : selector(setting)
        let confirmations = Dictionary(setting.choices.compactMap { choice in
            choice.confirm.map { (choice.value, ComposerPermissionSlot.Confirmation(title: $0.title, message: $0.message, confirm: $0.button)) }
        }, uniquingKeysWith: { first, _ in first })
        var slot = ComposerPermissionSlot(
            title: selector.map(ProviderCapabilityAccessibility.selectedChoiceName(for:)) ?? setting.title ?? setting.name,
            selector: selector, confirmations: confirmations, canChoose: setting.prepare != true,
            preparesBeforeOpening: setting.prepare == true && setting.choices.count > 1, apply: .providerOption,
            isElevated: setting.elevated == true, hasPendingRequest: isWaiting,
            accessibilityHint: L10n.string("Show permission details"), help: L10n.string("Show permission details"))
        if let note = setting.note { slot.explanation = .init(text: note, icon: isWaiting ? "hand.raised.fill" : "hand.raised") }
        return slot
    }
}
