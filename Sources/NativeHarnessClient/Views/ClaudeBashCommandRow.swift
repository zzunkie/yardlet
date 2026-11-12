import SwiftUI

/// A Claude task's bash mode for its composer and conversation. Present only for Claude tasks;
/// without it the composer has no bash mode, as the Claude app offers it only in local sessions.
@MainActor
struct ClaudeShellCommandActions: @MainActor Equatable {
    var isRunning: Bool
    var run: (String) -> Void
    var stop: () -> Void
    var runForEntry: (UUID) -> ClaudeShellCommandRun?
    /// The task the actions are bound to. The window makes them afresh each time the task's
    /// conversation changes; bound to the same task they are the same actions, so the composer
    /// and the bash rows that read them are not drawn again for it.
    var task: SessionRecord? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isRunning == rhs.isRunning && lhs.task == rhs.task
    }
}

private struct ClaudeShellCommandActionsKey: EnvironmentKey {
    static let defaultValue: ClaudeShellCommandActions? = nil
}

extension EnvironmentValues {
    var claudeShellCommands: ClaudeShellCommandActions? {
        get { self[ClaudeShellCommandActionsKey.self] }
        set { self[ClaudeShellCommandActionsKey.self] = newValue }
    }
}

/// A Claude bash-mode command in the conversation, as the Claude app's Code tab shows one: the
/// command as shell code, and below it a bordered box with its output, scrolling past about ten
/// lines and following the end while it runs. "(no output)" when it printed nothing; "Running…"
/// before any output. Not a chat bubble, though the person sent it. Where the task has a terminal,
/// the command offers "Run in terminal" as every command card does (plan B10).
struct ClaudeBashCommandRow: View {
    let entryID: UUID
    let message: ClaudeBashMessage
    var runInTerminal: ((String) -> Void)? = nil
    @Environment(\.claudeShellCommands) private var shellCommands
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.yardletCodeFont) private var codeFont
    @Environment(\.colorScheme) private var colorScheme

    /// The Claude app's output box is at most 160 points tall.
    static let outputMaximumHeight: CGFloat = 160

    var body: some View {
        let run = shellCommands?.runForEntry(entryID)
        let command = run?.command ?? message.command
        let terminalCommand = ConversationRunInTerminalButton.offer(command, runInTerminal)
        VStack(alignment: .leading, spacing: 5) {
            Text(TranscriptCodeBlock.highlighted(command, language: "bash", isDark: colorScheme == .dark))
                .font(codeFont.font(ofSize: codeFont.size(12.5, scale: interfaceScale)))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.trailing, terminalCommand == nil ? 12 : 34)
                .padding(.vertical, 9)
                .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(ParityTheme.separator) }
                .accessibilityLabel(L10n.format("Shell command: %@", command))
                .overlay(alignment: .topTrailing) {
                    if let terminalCommand {
                        ConversationRunInTerminalButton(action: terminalCommand)
                            .padding(.top, 5)
                            .padding(.trailing, 6)
                    }
                }
            output(for: run)
            if run?.state == .stopped {
                Label(L10n.string("Stopped"), systemImage: "stop")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func output(for run: ClaudeShellCommandRun?) -> some View {
        let content = outputContent(for: run)
        let text = Text(verbatim: content.text)
            .font(codeFont.font(ofSize: codeFont.size(12, scale: interfaceScale)))
            .foregroundStyle(content.isError ? Color.red : Color.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        Group {
            if Self.needsScrolling(content.text) {
                ScrollView(.vertical) { text }
                    .frame(height: Self.outputMaximumHeight * interfaceScale)
                    .defaultScrollAnchor(.bottom)
            } else {
                text
            }
        }
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(ParityTheme.separator) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string("Shell command output"))
    }

    private func outputContent(for run: ClaudeShellCommandRun?) -> (text: String, isError: Bool) {
        if let run {
            switch run.state {
            case let .failed(message):
                return (message, true)
            case .running:
                return (run.output.isEmpty ? L10n.string("Running…") : run.output, false)
            case .finished, .stopped:
                return (run.output.isEmpty ? L10n.string("(no output)") : run.output, false)
            }
        }
        return (message.output.isEmpty ? L10n.string("(no output)") : message.output, false)
    }

    /// About ten lines fit the box without scrolling; long lines wrap at roughly ninety columns.
    static func needsScrolling(_ text: String) -> Bool {
        var lines = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += max(1, (line.count + 89) / 90)
            if lines > 9 { return true }
        }
        return false
    }
}
