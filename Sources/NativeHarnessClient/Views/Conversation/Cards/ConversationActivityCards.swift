import AppKit
import SwiftUI

// The subagent card that opens and stops a subagent by the provider's own route (B8), and the parts
// a conversation's work draws with: a call's titled text, the "Allowed" mark, "Copy item details",
// "Run in terminal" and the status words. Calls themselves are status lines (`ConversationWorkLine`).

/// A subagent: what it was asked and what it reported, and the provider's own way to open it — a
/// Codex child thread as its own task, a Claude subtask in the panel beside the task, which can
/// also be stopped while it runs (B8). The controls stay in view while the details are folded.
struct ConversationSubagentCard: View {
    let subagent: ConversationSubagent
    let phase: ConversationItemPhase
    let actions: ConversationActions
    var copyDetails: String? = nil
    var isHistoryMatch = false

    var body: some View {
        ConversationActivityDisclosure(
            title: subagent.title, kindLabel: subagent.kind ?? L10n.string("Subagent"), phase: phase,
            isApproved: subagent.isApproved, copyDetails: copyDetails, isHistoryMatch: isHistoryMatch,
            hasDetails: hasDetails, harnessModel: .some(subagent.model), harnessLabel: subagent.harnessLabel
        ) {
            if let detail = subagent.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let input = subagent.input, !input.isEmpty {
                ConversationActivitySection(title: L10n.string("Input"), text: input,
                                            accessibilityLabel: L10n.string("Tool input"))
            }
            if let output = subagent.output, !output.isEmpty {
                ConversationActivitySection(title: L10n.string("Output"), text: output,
                                            accessibilityLabel: L10n.string("Tool output"))
            }
        } controls: {
            controls
        }
    }

    private var hasDetails: Bool {
        [subagent.detail, subagent.input, subagent.output].contains { $0?.isEmpty == false }
    }

    @ViewBuilder
    private var controls: some View {
        let routes = subagent.routes
        if !routes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    ForEach(Array(routes.enumerated()), id: \.offset) { _, route in
                        routeControls(route)
                    }
                }
                .buttonStyle(.link)
                .parityPointer()
                .font(.caption)
                ForEach(Array(routes.enumerated()), id: \.offset) { _, route in
                    if case let .harnessSubtask(_, activityID) = route,
                       let error = actions.subtaskControls?.error(activityID) {
                        Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func routeControls(_ route: ConversationSubagentRoute) -> some View {
        switch route {
        case let .codexThread(threadID):
            Button {
                actions.openCodexSubagent(threadID)
            } label: {
                HarnessSubtaskActionLabel(title: "Open child task", systemName: "arrow.right.circle")
            }
        case let .harnessSubtask(reference, activityID):
            if let controls = actions.subtaskControls {
                let activity = HarnessActivity(id: activityID, kind: subagent.kind ?? "", title: subagent.title,
                                               subtask: reference)
                if reference.hasConversation {
                    Button { controls.open(activity) } label: {
                        HarnessSubtaskActionLabel(title: "Open child task", systemName: "arrow.right.circle")
                    }
                }
                if phase == .running, reference.taskID != nil, let stop = controls.stop {
                    Button { stop(activity) } label: {
                        HarnessSubtaskActionLabel(
                            title: controls.isStopping(activityID) ? "Stop requested" : "Stop task",
                            systemName: "stop.circle"
                        )
                    }
                    .disabled(controls.isStopping(activityID))
                }
            }
        case let .yardletAgent(agentID, prompt):
            AgentRunControls(agentID: agentID, prompt: prompt)
        }
    }
}

// MARK: - Parts

/// The words an item's phase reads in.
enum ConversationActivityStatus {
    static func label(_ phase: ConversationItemPhase) -> String {
        switch phase {
        case .running: L10n.string("In progress")
        case .completed: L10n.string("Completed")
        case .failed: L10n.string("Failed")
        case .stopped: L10n.string("Stopped")
        }
    }
}

extension ConversationTool.Kind {
    /// The badge beside a call's title: the provider's own tool kind, or what Codex calls the item.
    var label: String {
        switch self {
        case let .activity(kind): kind
        case .mcp: L10n.string("MCP tool")
        case .dynamic: L10n.string("Tool call")
        case .webSearch: L10n.string("Web search")
        case .imageView, .imageGeneration: L10n.string("Image")
        case .sleep: L10n.string("Sleep")
        case .review: L10n.string("Review")
        case .hook: L10n.string("Hook")
        case let .unknown(type): type ?? L10n.string("Unknown item")
        }
    }
}

/// The shared transcript's card for a call: a status tile, the title and the kind, the status,
/// and the details folded below. A failed call opens itself.
private struct ConversationActivityDisclosure<Details: View, Controls: View>: View {
    let title: String
    let kindLabel: String
    let phase: ConversationItemPhase
    let isApproved: Bool
    let copyDetails: String?
    let isHistoryMatch: Bool
    let hasDetails: Bool
    /// The harness · model label after the title: present for a subagent, its model nil until
    /// the provider reports one (`HarnessModelLabel`).
    let harnessModel: String??
    /// The harness and model named in full, in place of the task's harness with `harnessModel`.
    var harnessLabel: String? = nil
    @ViewBuilder let details: Details
    @ViewBuilder let controls: Controls

    @State private var isExpanded: Bool

    init(
        title: String, kindLabel: String, phase: ConversationItemPhase, isApproved: Bool, copyDetails: String?,
        isHistoryMatch: Bool, hasDetails: Bool, harnessModel: String?? = nil, harnessLabel: String? = nil,
        @ViewBuilder details: () -> Details,
        @ViewBuilder controls: () -> Controls
    ) {
        self.harnessModel = harnessModel
        self.harnessLabel = harnessLabel
        self.title = title
        self.kindLabel = kindLabel
        self.phase = phase
        self.isApproved = isApproved
        self.copyDetails = copyDetails
        self.isHistoryMatch = isHistoryMatch
        self.hasDetails = hasDetails
        self.details = details()
        self.controls = controls()
        _isExpanded = State(initialValue: phase == .failed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasDetails {
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        details
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 7)
                } label: {
                    header
                }
            } else {
                header
            }
            controls
        }
        // Opening a card, by hand or for a failure, leaves following as it was: at the bottom the
        // conversation stays pinned as the card grows, and only scrolling away pauses it.
        .onChange(of: phase) { _, newPhase in
            if newPhase == .failed { isExpanded = true }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            if isHistoryMatch {
                RoundedRectangle(cornerRadius: 9).stroke(ParityTheme.accent.opacity(0.35))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(ConversationActivityAccessibility.value(phase: phase, isHistoryMatch: isHistoryMatch))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(phase == .running ? ParityTheme.accent.opacity(0.08) : ParityTheme.subtleFill)
                Image(systemName: statusSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(phase == .failed ? Color.red : phase == .running ? ParityTheme.accent : .secondary)
            }
            .frame(width: 26, height: 26)

            HStack(spacing: 7) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if kindLabel != title {
                    Text(kindLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(ParityTheme.subtleFill, in: Capsule())
                }
                if isApproved {
                    ConversationAllowedMark()
                }
                if let harnessLabel {
                    Text(harnessLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                } else if case let .some(model) = harnessModel {
                    HarnessModelLabel(model: model)
                }
            }
            Spacer()
            if phase == .running {
                ProgressView()
                    .controlSize(.small)
            }
            Text(ConversationActivityStatus.label(phase))
                .font(.caption)
                .foregroundStyle(phase == .failed ? Color.red : Color.secondary)
            ConversationCopyDetailsButton(details: copyDetails)
        }
    }

    private var statusSymbol: String {
        switch phase {
        case .running: "gearshape.2"
        case .completed: "checkmark"
        case .failed: "exclamationmark.triangle"
        case .stopped: "stop"
        }
    }
}

/// A titled block of a call's text.
struct ConversationActivitySection: View {
    let title: String
    let text: String
    let accessibilityLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            ConversationActivityText(text: text, accessibilityLabel: accessibilityLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A call's text: as it is while short, in a scrolling reader once it is long.
struct ConversationActivityText: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let text: String
    let accessibilityLabel: String

    var body: some View {
        if TranscriptCodeWindow(text, lineLimit: 12, characterLimit: 2_400).isTruncated {
            TranscriptTextReader(text: text, fontSize: 11 * interfaceScale, accessibilityLabel: accessibilityLabel)
                .frame(height: 280 * interfaceScale)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .font(.system(size: 11 * interfaceScale, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The person allowed this call; the answered request is read here rather than as its own card.
struct ConversationAllowedMark: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
            Text(L10n.string("Allowed"))
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// "Copy item details": what the item ran and returned, on the clipboard.
struct ConversationCopyDetailsButton: View {
    let details: String?
    @State private var didCopy = false

    var body: some View {
        if let details {
            Button {
                TranscriptClipboard.copy(details)
                didCopy = true
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .accessibilityLabel(L10n.string("Copy item details"))
            .accessibilityValue(didCopy ? L10n.string("Copied item details") : "")
            .help(L10n.string("Copy item details"))
        }
    }
}

/// "Run in terminal" on a command, the same control for every harness's command (plan B10): a Codex
/// command, a Claude Bash call, a Claude bash-mode command. The task's terminal opens and runs it,
/// as the terminal's own "Run in terminal" has always run Codex's last command.
struct ConversationRunInTerminalButton: View {
    let action: () -> Void

    /// The button's action for `command`, when the task has a terminal and there is a command.
    static func offer(_ command: String, _ runInTerminal: ((String) -> Void)?) -> (() -> Void)? {
        guard let runInTerminal, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return { runInTerminal(command) }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .accessibilityLabel(L10n.string("Run in terminal"))
        .help(L10n.string("Run in terminal"))
    }
}

enum ConversationActivityAccessibility {
    static func value(phase: ConversationItemPhase, isHistoryMatch: Bool) -> String {
        [ConversationActivityStatus.label(phase), isHistoryMatch ? L10n.string("History match") : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
