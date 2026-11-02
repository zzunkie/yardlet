import SwiftUI

/// What the task's area gives a conversation's code blocks to run a block's command in the task's terminal
/// (`TerminalCodeBlockCommand`). A conversation shown without a terminal (a side chat, another task's
/// conversation in the side panel, a personal agent's) has none, and its blocks offer only "Copy code". Equal
/// while it is there or not, as `ConversationLinkPlaces` is, so the area's redraws leave the texts alone.
struct TranscriptTerminalRun: Equatable {
    var run: (@MainActor (String) -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.run == nil) == (rhs.run == nil)
    }
}

private struct TranscriptTerminalRunKey: EnvironmentKey {
    static let defaultValue = TranscriptTerminalRun()
}

extension EnvironmentValues {
    var transcriptTerminalRun: TranscriptTerminalRun {
        get { self[TranscriptTerminalRunKey.self] }
        set { self[TranscriptTerminalRunKey.self] = newValue }
    }
}

/// "Run in terminal" beside a code block's "Copy code", in its look, with the terminal symbol the command
/// cards' button has.
struct TranscriptRunInTerminalButton: View {
    /// The block's first line, for assistive apps, where several blocks' buttons read alike.
    var detail: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(L10n.string("Run in terminal"), systemImage: "apple.terminal")
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel(L10n.string("Run in terminal"))
        .accessibilityValue(detail ?? "")
        .help(L10n.string("Run in terminal"))
    }
}
