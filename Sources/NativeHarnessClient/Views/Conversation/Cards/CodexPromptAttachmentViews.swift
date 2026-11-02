import SwiftUI

// The context a sent message carried, drawn as the Codex app draws it around the request
// (`CodexPromptAttachments`; the `user-message` case in `sites-end-resource`, `user-message-attachments`):
// a row of chips above the bubble — the files mentioned or pasted, each opening the file at its lines,
// and counts of the comments, annotations and selections, with their words on hover — and the mode
// the request was sent in, in small words under it.

/// The chips above a sent message's bubble, in the Codex app's order, against the trailing edge.
struct CodexPromptAttachmentRow: View {
    let attachments: CodexPromptAttachments
    /// The images the message also sent; an attached image shows as its image, not as a chip.
    var imagePaths: [String] = []

    @Environment(\.openURL) private var openURL

    var body: some View {
        SentAttachmentFlow(spacing: 6) {
            if attachments.referencesPriorConversation {
                CodexPromptChip(symbol: "clock.arrow.circlepath", title: L10n.string("Previous context"))
            }
            ForEach(Array(attachments.shownFiles(imagePaths: imagePaths).enumerated()), id: \.offset) { _, file in
                Button { openURL(file.link) } label: {
                    CodexPromptChip(symbol: Self.symbol(for: file), title: file.name, detail: file.lineInfo)
                }
                .buttonStyle(.plain)
                .parityPointer()
                .help(file.path)
                .accessibilityLabel(file.lineInfo.map { "\(file.name) \($0)" } ?? file.name)
                .conversationLinkMenu(file.link)
            }
            ForEach(Array(attachments.uploads.enumerated()), id: \.offset) { _, name in
                CodexPromptChip(symbol: "doc", title: name)
            }
            if let number = attachments.mergeTaskPullRequest {
                CodexPromptChip(symbol: "arrow.triangle.pull", title: L10n.format("PR #%@", String(number)))
            }
            if let first = attachments.failingChecks.first {
                let more = attachments.failingChecks.count - 1
                CodexPromptChip(symbol: "xmark.circle",
                                title: more == 0 ? first : L10n.format("%@ +%lld more", first, more))
            }
            if let conflict = attachments.mergeConflict {
                CodexPromptChip(symbol: "arrow.triangle.merge", title: conflict.pullRequest.map {
                    L10n.format("Merge conflicts - PR #%@", String($0))
                } ?? L10n.string("Merge conflicts"))
            }
            let annotations = attachments.annotations.count + attachments.responseAnnotationCount
            if annotations > 0 {
                CodexPromptChip(symbol: "pencil.tip.crop.circle",
                                title: annotations == 1 ? L10n.string("1 annotation") : L10n.format("%lld annotations", annotations))
                    .help(Self.tooltip(attachments.annotations))
            }
            if !attachments.comments.isEmpty {
                let count = attachments.comments.count
                CodexPromptChip(symbol: "text.bubble",
                                title: count == 1 ? L10n.string("1 attached comment") : L10n.format("%lld attached comments", count))
                    .help(Self.tooltip(attachments.comments))
            }
            if !attachments.selections.isEmpty {
                let count = attachments.selections.count
                CodexPromptChip(symbol: "text.quote",
                                title: count == 1 ? L10n.string("1 selection") : L10n.format("%lld selections", count))
                    .help(attachments.selections.map { "“\(Self.snippet($0))”" }.joined(separator: "\n"))
            }
        }
    }

    /// Whether the row has a chip to draw.
    static func drawsChips(_ attachments: CodexPromptAttachments, imagePaths: [String]) -> Bool {
        var drawn = attachments
        drawn.modes = []
        drawn.files = attachments.shownFiles(imagePaths: imagePaths)
        return !drawn.isEmpty
    }

    private static func symbol(for file: CodexPromptAttachments.File) -> String {
        if file.path.hasSuffix("/") { return "folder" }
        if file.isPasted { return "doc.plaintext" }
        return file.isImage ? "photo" : "doc"
    }

    /// The comments' places and words, for hovering their count.
    private static func tooltip(_ comments: [CodexPromptAttachments.Comment]) -> String {
        comments.map { comment in
            let place = [comment.path, comment.lines].compactMap { $0 }.joined(separator: ":")
            return place.isEmpty ? snippet(comment.body) : "\(place) — \(snippet(comment.body))"
        }.joined(separator: "\n")
    }

    private static func snippet(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 160 ? String(flat.prefix(159)) + "…" : flat
    }
}

/// One chip: a symbol, a title and an optional detail in a quieter colour (`qxn`, `Cxn`).
struct CodexPromptChip: View {
    let symbol: String
    let title: String
    var detail: String? = nil

    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10 * interfaceScale))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.system(size: 12 * interfaceScale, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(verbatim: detail)
                    .font(.system(size: 12 * interfaceScale))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 320 * interfaceScale)
        .background(ParityTheme.subtleFill, in: Capsule())
        .overlay { Capsule().stroke(ParityTheme.separator) }
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// The mode a request was sent in, in small words under its bubble (`It` in `user-message`).
struct CodexPromptModes: View {
    let modes: [CodexPromptAttachments.Mode]

    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 8) {
            ForEach(modes, id: \.self) { mode in
                Text(Self.title(mode))
            }
        }
        .font(.system(size: 11 * interfaceScale))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    static func title(_ mode: CodexPromptAttachments.Mode) -> String {
        switch mode {
        case .review: L10n.string("Review mode")
        case .pullRequestFix: L10n.string("PR fix")
        case .autoResolveConflicts: L10n.string("Auto resolve conflicts")
        }
    }
}
