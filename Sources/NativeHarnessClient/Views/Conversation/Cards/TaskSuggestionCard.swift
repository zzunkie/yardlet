import SwiftUI

/// What a conversation's suggested-task chips ask of the app, bound to the task they appear in.
struct TaskSuggestionActions {
    /// What became of a suggestion. A chip reads it as it draws, so a change draws it again.
    var resolution: @MainActor (String) -> TaskSuggestionResolution?
    /// What Start or Do it here is doing for a suggestion, or why it did not happen.
    var progress: @MainActor (String) -> TaskSuggestionStore.Progress? = { _ in nil }
    /// Start: the task starts now, nested under this one, in its project and folder
    /// (`AppModel.startTaskSuggestion`).
    var start: @MainActor (ConversationTaskSuggestion) -> Void
    /// Do it here: the suggestion goes to this task as the person's message.
    var doHere: @MainActor (ConversationTaskSuggestion) -> Void = { _ in }
    /// Options: what Start starts the suggestion with and where, to change in a popover
    /// (`TaskSuggestionOptionsPopover`); nil where it cannot start now.
    var optionsContext: @MainActor (ConversationTaskSuggestion) -> (any TaskSuggestionOptionsSource)? = { _ in nil }
    /// Why Options is not offered where the chip is shown, as its help: a Mac too old to take
    /// another device's choices starts a suggestion with its own. Nil where it is.
    var optionsUnavailable: String? = nil
    /// Where Start starts the suggestion, as the row's summary leads with it.
    var startPlace: @MainActor (ConversationTaskSuggestion) -> TaskSuggestionStartPlace = {
        TaskSuggestionStartPlace(startsInWorktree: $0.startsInNewWorktree)
    }
    /// ✕: the chip leaves the conversation for good.
    var dismiss: @MainActor (String) -> Void
    /// Opens the task a suggestion started; nil where it is gone.
    var openTask: (@MainActor (UUID) -> Void)?
    /// Whether the task a suggestion started is still there to open.
    var canOpenTask: @MainActor (UUID) -> Bool = { _ in false }
}

/// Where a suggestion starts and with what, in the words its row leads the summary with: the place
/// the agent named ("Starts in web-app", "As a subtask of ‘Release notes’"), "In a worktree", then
/// quietly the harness, model and permissions ("Claude Code · Opus High · Bypass permissions").
struct TaskSuggestionStartPlace: Equatable {
    var label: String? = nil
    var startsInWorktree: Bool
    var settings: String? = nil
}

private struct TaskSuggestionActionsKey: EnvironmentKey {
    static let defaultValue: TaskSuggestionActions? = nil
}

extension EnvironmentValues {
    /// The task's suggested-task actions. Nil where the conversation cannot start a task; a chip
    /// then shows its suggestion without Start or ✕.
    var taskSuggestionActions: TaskSuggestionActions? {
        get { self[TaskSuggestionActionsKey.self] }
        set { self[TaskSuggestionActionsKey.self] = newValue }
    }
}

/// Suggested tasks in the Claude app's chip (`code.spawn_tasks`, desktop 3.1623.3): an outlined
/// card at most 480 pt wide, a band reading "New session" over one suggestion or "N suggested
/// tasks · N started" over several, and a row per suggestion — its title (which shows the prompt),
/// the summary under it, ✕, and Options, Do it here and Start. A suggestion being started is a quiet
/// row reading "Starting…"; a started one reads "Started" and opens its task; one sent here reads
/// "Sent to this session", and a card of that one alone is gone, as the message shows it; a
/// dismissed one is gone.
struct TaskSuggestionCard: View {
    let items: [ConversationItem]

    static let maximumWidth: CGFloat = 480

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.taskSuggestionActions) private var actions

    private var suggestions: [ConversationTaskSuggestion] {
        items.compactMap { item in
            if case let .taskSuggestion(suggestion) = item.kind { return suggestion }
            return nil
        }
    }

    var body: some View {
        let rows = Self.shownRows(suggestions.map { ($0, actions?.resolution($0.id)) })
        if !rows.isEmpty {
            let started = rows.filter { $0.1?.outcome == .started }.count
            VStack(alignment: .leading, spacing: 0) {
                band(count: rows.count, started: started)
                ForEach(Array(rows.enumerated()), id: \.element.0.id) { index, row in
                    if index > 0 { Divider().overlay(ParityTheme.separator) }
                    switch row.1?.outcome {
                    case .started?:
                        if let resolution = row.1 {
                            TaskSuggestionStartedRow(suggestion: row.0, resolution: resolution, actions: actions)
                        }
                    case .sentHere?:
                        TaskSuggestionStatusRow(suggestion: row.0, status: L10n.string("Sent to this session"))
                    case .dismissed?, nil:
                        if actions?.progress(row.0.id) == .starting {
                            TaskSuggestionStatusRow(suggestion: row.0, status: L10n.string("taskSuggestion.starting"),
                                                    isActive: true)
                        } else {
                            TaskSuggestionRow(suggestion: row.0, actions: actions)
                        }
                    }
                }
            }
            .frame(maxWidth: Self.maximumWidth, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius))
            .overlay { RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius).stroke(ParityTheme.strongSeparator) }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Self.countText(rows.count))
        }
    }

    /// "New session" over one suggestion, "N suggested tasks" over several, with how many started.
    private func band(count: Int, started: Int) -> some View {
        HStack(spacing: 8) {
            Text(count == 1 ? L10n.string("New session") : Self.countText(count))
                .lineLimit(1)
            if count > 1, started > 0 {
                Text(L10n.format("%lld started", started))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13 * interfaceScale))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(ParityTheme.subtleFill)
        .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
    }

    static func countText(_ count: Int) -> String {
        count == 1 ? L10n.string("1 suggested task") : L10n.format("%lld suggested tasks", count)
    }

    /// The rows a card draws: not the dismissed ones, and none when the one left was sent here,
    /// as the Claude app drops a card whose one suggestion went to its own session.
    static func shownRows(
        _ rows: [(ConversationTaskSuggestion, TaskSuggestionResolution?)]
    ) -> [(ConversationTaskSuggestion, TaskSuggestionResolution?)] {
        let shown = rows.filter { $0.1?.outcome != .dismissed }
        return shown.count == 1 && shown[0].1?.outcome == .sentHere ? [] : shown
    }
}

/// A suggestion waiting for the person: its title over its summary and ✕, then Options on the
/// leading side and Do it here and Start on the trailing one, as the Claude app lays them out. Why
/// the last Start or Do it here did not happen shows under the summary.
private struct TaskSuggestionRow: View {
    let suggestion: ConversationTaskSuggestion
    let actions: TaskSuggestionActions?

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @State private var showsPrompt = false
    @State private var options: (any TaskSuggestionOptionsSource)?

    private var title: String { suggestion.title ?? L10n.string("Untitled task") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ✕ on the title's first line, not the top of the row.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button {
                    showsPrompt.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13 * interfaceScale, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let summary {
                            summary
                                .font(.system(size: 13 * interfaceScale))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .parityPointer()
                .accessibilityLabel(title)
                .accessibilityValue(summaryWords)
                .popover(isPresented: $showsPrompt, arrowEdge: .bottom) {
                    TaskSuggestionPromptPopover(title: suggestion.title, prompt: suggestion.prompt)
                }
                if let actions {
                    Button {
                        actions.dismiss(suggestion.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11 * interfaceScale, weight: .medium))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .parityPointer()
                    .centeredOnCapHeight(ofTextSize: 13 * interfaceScale)
                    .help(L10n.format("Dismiss suggestion %@", title))
                    .accessibilityLabel(L10n.format("Dismiss suggestion %@", title))
                }
            }
            if case let .failed(reason)? = actions?.progress(suggestion.id) {
                Text(reason)
                    .font(.system(size: 12 * interfaceScale))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let actions {
                let busy = actions.progress(suggestion.id) == .sending
                HStack(spacing: 6) {
                    Button(L10n.string("Options")) { options = actions.optionsContext(suggestion) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(actions.optionsUnavailable ?? L10n.string("taskSuggestion.optionsHelp"))
                        .disabled(actions.optionsUnavailable != nil)
                        .accessibilityHint(title)
                        .popover(isPresented: Binding(get: { options != nil }, set: { if !$0 { options = nil } }),
                                 arrowEdge: .bottom) {
                            if let options {
                                TaskSuggestionOptionsPopover(context: options) { self.options = nil }
                            }
                        }
                    Spacer(minLength: 0)
                    Button(L10n.string("Do it here")) { actions.doHere(suggestion) }
                        .buttonStyle(.bordered)
                        .accessibilityHint(title)
                    Button(L10n.string("Start")) { actions.start(suggestion) }
                        .parityProminentButton()
                        .accessibilityLabel(L10n.string("Start"))
                        .accessibilityHint(title)
                }
                .controlSize(.small)
                .font(.system(size: 12 * interfaceScale))
                .parityPointer()
                .disabled(busy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var startPlace: TaskSuggestionStartPlace {
        actions?.startPlace(suggestion) ?? TaskSuggestionStartPlace(startsInWorktree: suggestion.startsInNewWorktree)
    }

    /// Where Start starts it: the place the agent named, then "In a worktree" when Start makes one.
    private var placeWords: [String] {
        let place = startPlace
        return [place.label, place.startsInWorktree ? L10n.string("In a worktree") : nil].compactMap { $0 }
    }

    /// The summary line's words, for assistive apps.
    private var summaryWords: String {
        (placeWords + [startPlace.settings, suggestion.tldr].compactMap { $0 }).joined(separator: " · ")
    }

    /// Where it starts and, quieter, with what, before the summary, as the Claude app leads the line
    /// with where the session will start ("In a worktree · …").
    private var summary: Text? {
        let parts = [placeWords.isEmpty ? nil : Text(placeWords.joined(separator: " · ")).foregroundStyle(.primary),
                     startPlace.settings.map { Text($0).foregroundStyle(.tertiary) },
                     suggestion.tldr.map { Text($0).foregroundStyle(.secondary) }].compactMap { $0 }
        guard var line = parts.first else { return nil }
        for part in parts.dropFirst() { line = line + Text(" · ").foregroundStyle(.secondary) + part }
        return line
    }
}

/// A suggestion being started, or sent here: its title and what is happening, quiet, without
/// controls, as the Claude app's status rows are.
private struct TaskSuggestionStatusRow: View {
    let suggestion: ConversationTaskSuggestion
    let status: String
    var isActive = false

    @Environment(\.yardletInterfaceScale) private var interfaceScale

    private var title: String { suggestion.title ?? L10n.string("Untitled task") }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(status)
                .font(.system(size: 11 * interfaceScale))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13 * interfaceScale))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("%@: %@", title, status))
    }
}

/// A suggestion that started a task: its title, quiet, and "Started"; it opens that task.
private struct TaskSuggestionStartedRow: View {
    let suggestion: ConversationTaskSuggestion
    let resolution: TaskSuggestionResolution
    let actions: TaskSuggestionActions?

    @Environment(\.yardletInterfaceScale) private var interfaceScale

    private var title: String { suggestion.title ?? L10n.string("Untitled task") }

    var body: some View {
        let target = resolution.startedTaskID.flatMap { id in actions?.canOpenTask(id) == true ? id : nil }
        Button {
            if let target { actions?.openTask?(target) }
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.string("Started"))
                    .font(.system(size: 11 * interfaceScale))
                    .foregroundStyle(.secondary)
                if target != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9 * interfaceScale, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 13 * interfaceScale))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .parityPointer()
        .accessibilityLabel(L10n.format("%@: %@", title, L10n.string("Started")))
        .help(target == nil ? "" : L10n.format("Open session %@", title))
        .conversationLinkMenu(target.map(TaskLink.url), text: title) {
            if let target { actions?.openTask?(target) }
        }
    }
}

/// A suggestion still waiting for the person, on the session rail: its title (which shows the prompt,
/// as the chip's does) over where and with what Start starts it, and Start and ✕ on the title's line.
/// It reads and acts through the chip's own actions, so starting or dismissing it in either place
/// changes both; a started suggestion leaves the rail and its task is a row of the Agents card.
struct TaskSuggestionRailRow: View {
    let suggestion: ConversationTaskSuggestion

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.taskSuggestionActions) private var actions
    @State private var showsPrompt = false

    private var title: String { suggestion.title ?? L10n.string("Untitled task") }

    var body: some View {
        let progress = actions?.progress(suggestion.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { showsPrompt.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.bubble")
                            .font(.system(size: 11 * interfaceScale))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .parityPointer()
                .help(title)
                .accessibilityLabel(title)
                .accessibilityValue(summaryWords)
                .popover(isPresented: $showsPrompt, arrowEdge: .leading) {
                    TaskSuggestionPromptPopover(title: suggestion.title, prompt: suggestion.prompt)
                }
                if progress == .starting {
                    Text(L10n.string("taskSuggestion.starting"))
                        .font(.system(size: 11.5 * interfaceScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                } else if let actions {
                    Button(L10n.string("Start")) { actions.start(suggestion) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: 11.5 * interfaceScale))
                        .parityPointer()
                        .disabled(progress == .sending)
                        .accessibilityHint(title)
                    BackgroundTasksGhostButton(action: { actions.dismiss(suggestion.id) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10 * interfaceScale, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .help(L10n.format("Dismiss suggestion %@", title))
                    .accessibilityLabel(L10n.format("Dismiss suggestion %@", title))
                }
            }
            .frame(minHeight: 24)
            if let summary {
                summary
                    .font(.system(size: 11.5 * interfaceScale))
                    .lineLimit(2)
                    .padding(.leading, 22)
            }
            if case let .failed(reason)? = progress {
                Text(reason)
                    .font(.system(size: 11.5 * interfaceScale))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var startPlace: TaskSuggestionStartPlace {
        actions?.startPlace(suggestion) ?? TaskSuggestionStartPlace(startsInWorktree: suggestion.startsInNewWorktree)
    }

    private var placeWords: [String] {
        let place = startPlace
        return [place.label, place.startsInWorktree ? L10n.string("In a worktree") : nil].compactMap { $0 }
    }

    private var summaryWords: String {
        (placeWords + [startPlace.settings, suggestion.tldr].compactMap { $0 }).joined(separator: " · ")
    }

    /// Where it starts and, quieter, with what: the chip's summary without its sentences, which the
    /// rail has no room for (the title's popover has the prompt).
    private var summary: Text? {
        let parts = [placeWords.isEmpty ? nil : Text(placeWords.joined(separator: " · ")).foregroundStyle(.secondary),
                     startPlace.settings.map { Text($0).foregroundStyle(.tertiary) }].compactMap { $0 }
        guard var line = parts.first else { return nil }
        for part in parts.dropFirst() { line = line + Text(" · ").foregroundStyle(.tertiary) + part }
        return line
    }
}

/// The title's popover: "Suggested task", the title and the prompt the new task would send.
private struct TaskSuggestionPromptPopover: View {
    let title: String?
    let prompt: String

    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("taskSuggestion.popoverLabel"))
                .font(.system(size: 11 * interfaceScale, weight: .medium))
                .foregroundStyle(.secondary)
            if let title {
                Text(title)
                    .font(.system(size: 13 * interfaceScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Text(prompt)
                    .font(.system(size: 12 * interfaceScale))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 360)
        }
        .padding(14)
        .frame(width: TaskSuggestionCard.maximumWidth)
    }
}
