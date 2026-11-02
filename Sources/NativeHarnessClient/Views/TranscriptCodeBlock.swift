import AppKit
import SwiftUI

struct TranscriptCodeBlock: View {
    let language: String?
    let text: String
    /// Where this block sits in its message, for find's marks.
    var findKey: ConversationFindSegmentKey? = nil
    let copyPayload: () -> String?
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationFindSlot) private var findSlot
    @State private var fullCode: FullCode?
    @State private var focusBookmark: WindowFocusBookmark?
    @Environment(\.pauseTranscriptFollowing) private var pauseFollowing
    @Environment(\.transcriptTerminalRun) private var terminalRun

    private struct FullCode: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        let window = TranscriptCodeWindow(text)
        var code = highlightedText(window.text)
        let findFraction = findKey.flatMap { key in
            findSlot.flatMap { slot in
                ConversationFindStyle.mark(&code, query: slot.query, active: slot.active,
                                           key: key, scheme: colorScheme, byLine: true)
            }
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? L10n.string("Code"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if let run = terminalRun.run, let command = TerminalCodeBlockCommand.command(language: language, code: text) {
                    TranscriptRunInTerminalButton { run(command) }
                }
                TranscriptCopyButton(title: L10n.string("Copy code"), payload: copyPayload)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(ParityTheme.subtleFill)
            Divider()
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 12.5 * interfaceScale, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
            // Outside the horizontal scroll view, so finding a match moves the conversation.
            .conversationFindAnchor(findFraction)
            if window.isTruncated {
                Divider()
                Button(L10n.string("View full code")) {
                    guard let text = copyPayload() else { return }
                    focusBookmark = WindowFocusBookmark(window: NSApp.keyWindow)
                    pauseFollowing()
                    fullCode = FullCode(text: text)
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .font(.caption)
                .padding(10)
            }
        }
        .background(ParityTheme.subtleFill)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(ParityTheme.separator) }
        .sheet(item: $fullCode, onDismiss: {
            focusBookmark?.restore()
            focusBookmark = nil
        }) { code in
            TranscriptFullCodeSheet(language: language, text: code.text, fontSize: 12.5 * interfaceScale) { fullCode = nil }
        }
    }

    private func highlightedText(_ text: String) -> AttributedString {
        Self.highlighted(text, language: language, isDark: colorScheme == .dark)
    }

    /// Code coloured as the conversation's code blocks colour it, for other code-like rows.
    static func highlighted(_ text: String, language: String?, isDark: Bool) -> AttributedString {
        AttributedString(highlightedText(text, language: language, isDark: isDark))
    }

    /// The same colours for a message's text view, which sets the font.
    static func highlightedText(_ text: String, language: String?, isDark: Bool) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: text)
        for token in TranscriptCodeSyntax.tokens(in: text, language: language) {
            result.addAttribute(.foregroundColor, value: color(for: token.kind, isDark: isDark), range: token.range)
        }
        return result
    }

    private static func color(for kind: TranscriptCodeSyntax.Kind, isDark dark: Bool) -> NSColor {
        switch kind {
        case .comment: return .secondaryLabelColor
        case .string: return dark
            ? NSColor(calibratedRed: 0.65, green: 0.84, blue: 0.60, alpha: 1)
            : NSColor(calibratedRed: 0.17, green: 0.39, blue: 0.22, alpha: 1)
        case .keyword: return dark
            ? NSColor(calibratedRed: 0.83, green: 0.67, blue: 0.96, alpha: 1)
            : NSColor(calibratedRed: 0.45, green: 0.21, blue: 0.64, alpha: 1)
        case .number: return dark
            ? NSColor(calibratedRed: 0.58, green: 0.77, blue: 0.96, alpha: 1)
            : NSColor(calibratedRed: 0.12, green: 0.34, blue: 0.62, alpha: 1)
        }
    }
}

/// A whole code block in a sheet, from "View full code".
struct TranscriptFullCodeSheet: View {
    let language: String?
    let text: String
    let fontSize: CGFloat
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language ?? L10n.string("Code")).font(.headline)
                Spacer()
                TranscriptCopyButton(title: L10n.string("Copy code")) { text }
                Button(L10n.string("Done"), action: done)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            TranscriptTextReader(text: text, fontSize: fontSize)
        }
        .frame(minWidth: 420, idealWidth: 680, minHeight: 300, idealHeight: 500)
    }
}
