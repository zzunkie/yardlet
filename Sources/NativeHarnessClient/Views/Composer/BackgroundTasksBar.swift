import SwiftUI

/// The line above a task's composer while its background agents and tasks run
/// (`BackgroundTasksProjection`): the Codex app's background agents row on the composer rail — the
/// count, "Stop all" and a chevron that lists them inside the rail — with the Claude app's words for
/// Claude Code's tasks. A row opens the task's conversation in the subtask panel and stops it as its
/// card does; "Stop all" asks first. Nothing shows while none runs.
struct BackgroundTasksBar: View {
    let projection: BackgroundTasksProjection
    /// The task's subtask controls; without them the line only counts and lists.
    let actions: HarnessActivityActions?
    /// How far the tray runs under the composer, which covers it.
    var tuck: CGFloat = 0
    /// Starts with the list open (renders only).
    var startsExpanded = false

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @State private var isExpanded: Bool?
    @State private var stopAll = BackgroundTasksStopAll()

    /// The tray on the composer rail, tucked under the composer's top edge like the status panel.
    func attachedAboveComposer() -> some View {
        var tray = self
        tray.tuck = CodexStatusPanel.composerTuck
        return tray
            .padding(.horizontal, ParitySpace.s12)
            .conversationColumn()
            .padding(.top, 6)
            .padding(.bottom, -CodexStatusPanel.composerTuck)
    }

    private var expanded: Bool { isExpanded ?? startsExpanded }

    private var canStopAll: Bool {
        guard let actions, actions.stop != nil else { return false }
        return !projection.stopAllTargets(isStopping: actions.isStopping).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(projection.rows) { row in
                            BackgroundTaskRowView(row: row, actions: actions)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 96 * interfaceScale)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
                .accessibilityLabel(L10n.string("Background tasks"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, tuck)
        .background(ParityTheme.subtleFill, in: tray)
        .background(ParityTheme.canvas, in: tray)
        .overlay { tray.stroke(ParityTheme.separator) }
        .clipShape(tray)
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            L10n.string("Stop all running tasks?"),
            isPresented: Binding(get: { stopAll.isConfirming }, set: { if !$0 { stopAll.cancel() } })
        ) {
            Button(L10n.string("Stop all"), role: .destructive) {
                if let actions { stopAll.confirm(projection, actions: actions) }
            }
            Button(L10n.string("Keep running"), role: .cancel) { stopAll.cancel() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { isExpanded = !expanded } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.2")
                        .font(.system(size: 11 * interfaceScale))
                    Text(projection.countText)
                        .font(.system(size: 13 * interfaceScale))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityValue(expanded ? L10n.string("Expanded") : L10n.string("Collapsed"))

            if canStopAll {
                BackgroundTasksGhostButton(action: { stopAll.request() }) {
                    Text(L10n.string("Stop all"))
                        .font(.system(size: 13 * interfaceScale))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
            }
            BackgroundTasksGhostButton(action: { isExpanded = !expanded }) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10 * interfaceScale, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .accessibilityLabel(L10n.string("Background tasks"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(minHeight: 30 * interfaceScale)
    }

    private var tray: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16)
    }
}

/// One running task in the list: its title, how long it has run, and its stop control in the Claude
/// app's words ("Stop this task", "Stopping…"). The title opens the agent's conversation where it
/// has one. The session rail's Background tasks card lists the same rows.
struct BackgroundTaskRowView: View {
    let row: BackgroundTasksProjection.Row
    let actions: HarnessActivityActions?
    /// How far the row starts in from the list's edge: under the line's icon, or flush in the rail.
    var leadingInset: CGFloat = 28
    /// Opens a shell's or a monitor's output beside the task (the rail's card); nil leaves its title quiet.
    var openOutput: ((HarnessActivity) -> Void)? = nil
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    private var isStopping: Bool { actions?.isStopping(row.id) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                title
                Spacer(minLength: 8)
                Group {
                    if isStopping {
                        Text(L10n.string("Stopping…"))
                    } else {
                        TimelineView(.periodic(from: row.startedAt, by: 1)) { context in
                            Text(BackgroundTasksProjection.elapsedText(since: row.startedAt, now: context.date))
                                .monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 12 * interfaceScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                if row.canStop, let stop = actions?.stop {
                    BackgroundTasksGhostButton(action: { stop(row.activity) }) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 12 * interfaceScale))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .disabled(isStopping)
                    .help(L10n.string("Stop this task"))
                    .accessibilityLabel(L10n.string("Stop this task"))
                }
            }
            if let error = actions?.error(row.id) {
                Text(error)
                    .font(.system(size: 11 * interfaceScale))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, leadingInset + CGFloat(row.depth) * 18)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var title: some View {
        let label = HStack(spacing: 6) {
            if row.depth > 0 {
                // Under its subagent's row, as the subagent's own work.
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9 * interfaceScale))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Image(systemName: row.opensConversation ? "person.crop.circle" : "terminal")
                .font(.system(size: 11 * interfaceScale))
                .foregroundStyle(.secondary)
            Text(row.title)
                .font(.system(size: 12 * interfaceScale))
                .lineLimit(1)
                .truncationMode(.tail)
            if row.showsHarnessModel {
                HarnessModelLabel(model: row.activity.subtask?.model)
            }
        }
        if row.opensConversation, let actions {
            Button { actions.open(row.activity) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .parityPointer()
                .help(L10n.string("Open child task"))
        } else if !row.opensConversation, let openOutput {
            // The Claude app's "Open {name} in Background tasks", the Codex app's output tab.
            Button { openOutput(row.activity) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .parityPointer()
                .help(L10n.string("View output"))
        } else {
            label
        }
    }
}

/// A quiet borderless button that fills on hover, as the rail's other controls.
struct BackgroundTasksGhostButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .background(isHovered ? ParityTheme.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .parityPointer()
    }
}
