import Foundation

/// A suggestion chip's Options (`TaskSuggestionOptionsPopover`) over the new-task screen's own
/// choices: the options a started task keeps, read as the new-task screen's choice
/// (`NewTaskModelChoice`: model, effort and permission) and written back. This is where the chip
/// tells harnesses apart, as `ComposerSessionOptionsProjection` is for the composer.
@MainActor
enum TaskSuggestionStartOptions {
    /// The model menu's choice in `options`, as the new-task screen keeps one.
    static func modelChoice(from options: [String: String], harness: HarnessKind) -> NewTaskModelChoice? {
        let choice: NewTaskModelChoice
        switch harness {
        case .claudeCode:
            choice = NewTaskModelChoice(model: options[ClaudeLaunchOption.model], effort: options[ClaudeLaunchOption.effort],
                                        permissionMode: options[ClaudeLaunchOption.permissionMode])
        case .codex:
            choice = NewTaskModelProjection.choosing(CodexRunLocation.restored(from: options),
                choice: CodexModelSelection.restored(from: options).map(NewTaskModelChoice.init))
        case .antigravityCLI:
            choice = NewTaskModelChoice(model: options[StructuredHeadlessOptionID.model],
                                        effort: options[StructuredHeadlessOptionID.reasoningEffort],
                                        permissionMode: options[StructuredHeadlessOptionID.permissionMode])
        default:
            return nil
        }
        return choice == NewTaskModelChoice(model: nil) ? nil : choice
    }

    /// `base` with the controls' choices in place of what it held for them; the options the
    /// controls do not show stay.
    static func providerOptions(_ base: [String: String], harness: HarnessKind,
                                choice: NewTaskModelChoice?) -> [String: String] {
        var options = base
        for key in controlledKeys(harness) { options[key] = nil }
        options.merge(choice?.providerOptions(for: harness) ?? [:]) { _, new in new }
        return options
    }

    private static func controlledKeys(_ harness: HarnessKind) -> [String] {
        switch harness {
        case .claudeCode: [ClaudeLaunchOption.model, ClaudeLaunchOption.effort, ClaudeLaunchOption.permissionMode]
        case .codex: [CodexModelSelection.storageKey, CodexRunLocation.storageKey]
        case .antigravityCLI:
            [StructuredHeadlessOptionID.model, StructuredHeadlessOptionID.reasoningEffort, StructuredHeadlessOptionID.permissionMode]
        default: []
        }
    }

    /// The new-task screen's model, effort and permission controls for what Start starts with now,
    /// on its harness, account and folder.
    static func sessionOptions(for choice: TaskSuggestionStartChoice,
                               catalogs: HarnessModelCatalogStore?) -> ComposerSessionOptions {
        ComposerSessionOptionsProjection.newTask(
            harness: choice.harness, choice: modelChoice(from: choice.providerOptions, harness: choice.harness),
            catalogs: catalogs, connection: choice.connection, workspaceURL: choice.place.folder)
    }

    /// `choice` on another harness, in the same place: that harness's options and account. Nil
    /// for the harness already chosen, whose choices stay.
    static func choosing(harness: HarnessKind, in choice: TaskSuggestionStartChoice, options: [String: String],
                         connection: ProviderConnection?) -> TaskSuggestionStartChoice? {
        guard harness != choice.harness else { return nil }
        return TaskSuggestionStartChoice(harness: harness, providerOptions: options, place: choice.place, connection: connection)
    }

    /// `choice` after a pick in one of those controls, by the new-task screen's own rule
    /// (`NewTaskModelProjection.choosing`), or nil when the list does not offer it. The options the
    /// controls do not show stay.
    static func choosing(_ picked: ComposerSessionChoice, in choice: TaskSuggestionStartChoice,
                         catalogs: HarnessModelCatalogStore?) -> TaskSuggestionStartChoice? {
        let harness = choice.harness
        let model = modelChoice(from: choice.providerOptions, harness: harness)
        let chosen: NewTaskModelChoice?
        switch picked {
        case let .codexRunLocation(location):
            chosen = harness == .codex ? NewTaskModelProjection.choosing(location, choice: model) : nil
        case let .codexModel(selection):
            chosen = harness == .codex ? NewTaskModelProjection.choosing(selection, choice: model) : nil
        case let .providerOption(id, value):
            chosen = catalogs.flatMap {
                NewTaskModelProjection.choosing(id, value: value, harness: harness, choice: model, catalogs: $0,
                                                connection: choice.connection, workspaceURL: choice.place.folder)
            }
        }
        guard let chosen else { return nil }
        var next = choice
        next.providerOptions = providerOptions(choice.providerOptions, harness: harness, choice: chosen)
        return next
    }

    /// "Claude Code · Opus High · Bypass permissions": the harness, then the model menu's and the
    /// permission control's own names for what the task starts with.
    static func summary(harness: HarnessKind, options: ComposerSessionOptions) -> String {
        [harness.displayName,
         options.model.flatMap { $0.menu.isEmpty ? nil : $0.menu.title },
         options.permission?.title].compactMap { $0 }.joined(separator: " · ")
    }
}
