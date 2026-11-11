import Foundation

/// A shared transcript's activity (`HarnessActivity`) as the card it converges on (plan M12b):
/// - Claude Code's Bash call is the command line, also while the CLI tracks it as a task
///   (`local_bash`): the line stops the task while it runs (2026-10-16);
/// - any other provider subtask is the subagent card, opened and stopped by the provider's own
///   route (B8);
/// - a call that carries the file change it made (Claude Code's Edit and Write, an ACP or Pi edit)
///   is the file change card, its lines in the Codex diff box (B11);
/// - every other call is the tool card.
/// The card reads only what is projected here, not the activity itself.
enum ConversationActivityProjection {
    /// Claude Code's shell tool. Its call names the command (`HarnessActivity.detail`) apart from
    /// its other arguments.
    static let claudeShellTools: Set<String> = ["Bash"]

    static func kind(
        _ activity: HarnessActivity,
        harness: HarnessKind,
        phase: ConversationItemPhase,
        isApproved: Bool
    ) -> ConversationItemKind {
        if harness == .claudeCode, let command = claudeShellCommand(activity, phase: phase, isApproved: isApproved) {
            return .command(command)
        }
        if let subtask = activity.subtask {
            return .subagent(ConversationSubagent(
                title: activity.title, status: nil, detail: legacyDetail(activity),
                routes: [.harnessSubtask(subtask, activityID: activity.id)], isApproved: isApproved,
                kind: activity.kind, input: activity.input, output: activity.output,
                isBackground: activity.isBackground == true, model: subtask.model
            ))
        }
        if let diff = activity.diff {
            return .fileChange(ConversationFileChange(
                rows: [ConversationFileChangeProjection.row(for: diff, phase: phase, workspaceURL: nil)],
                handoffs: [],
                errorMessage: phase == .failed ? activity.output : nil,
                isApproved: isApproved,
                placesRowsInWorkspace: true
            ))
        }
        if phase == .completed, let suggestion = ConversationTaskSuggestionProjection.suggestion(from: activity) {
            return .taskSuggestion(suggestion)
        }
        if phase == .completed, let creation = ConversationScheduleProjection.creation(from: activity) {
            return .scheduleCreated(creation)
        }
        if phase == .completed, let change = ConversationSettingProjection.change(from: activity) {
            return .settingChanged(change)
        }
        if let run = ConversationAgentRunProjection.subagent(from: activity, phase: phase, isApproved: isApproved) {
            return .subagent(run)
        }
        // Claude Code names a connector's tool in the call's kind, Antigravity in its kind or title.
        let connector = ConnectorToolLabels.shared.label(forHarnessTool: activity.kind)
            ?? ConnectorToolLabels.shared.label(forHarnessTool: activity.title)
        return .tool(ConversationTool(
            kind: .activity(activity.kind), name: activity.title, input: activity.input,
            output: activity.output, isBackground: activity.isBackground == true, isApproved: isApproved,
            detail: legacyDetail(activity), images: activity.images ?? [],
            connector: connector?.label,
            view: phase == .completed ? connector.flatMap { connector in
                ConversationConnectorView.of(tool: connector.name, label: connector.label,
                                             arguments: MCPAppArguments.parse(activity.input),
                                             harnessResult: ConversationConnectorView.textResult(activity.output))
            } : nil
        ))
    }

    /// Claude Code's Bash call, and a shell task the CLI reported without the call that started it
    /// (its description is all it names), as a command; nil for any other activity.
    private static func claudeShellCommand(
        _ activity: HarnessActivity, phase: ConversationItemPhase, isApproved: Bool
    ) -> ConversationCommand? {
        let isShellCall = claudeShellTools.contains(activity.kind)
        guard isShellCall || activity.subtask?.taskType == "local_bash" else { return nil }
        return ConversationCommand(
            command: activity.detail ?? (isShellCall ? activity.input ?? activity.title : ""),
            workingDirectory: nil,
            status: statusWord(phase),
            output: activity.output,
            exitCode: nil,
            durationMilliseconds: nil,
            liveOutputHeadByteCount: nil,
            isApproved: isApproved,
            isBackground: activity.isBackground == true,
            description: isShellCall
                ? ClaudeToolArguments(tool: activity.kind, input: activity.input, lead: activity.detail)["description"]
                : activity.title,
            task: activity.subtask.map { ConversationCommandTask(activityID: activity.id, reference: $0) }
        )
    }

    /// What "Copy item details" copies for an activity: its title, what it was given, what it
    /// returned and the file it changed.
    static func copyDetails(_ activity: HarnessActivity) -> String? {
        let parts = [activity.title, activity.input ?? activity.detail, activity.output, activity.diff?.path]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// The one text an activity without separate input and output carries.
    private static func legacyDetail(_ activity: HarnessActivity) -> String? {
        activity.hasSeparatedContent ? nil : activity.detail
    }

    /// The command card reads a status word, as Codex sends one.
    private static func statusWord(_ phase: ConversationItemPhase) -> String {
        switch phase {
        case .running: "inProgress"
        case .completed: "completed"
        case .failed: "failed"
        case .stopped: "interrupted"
        }
    }
}
