import SwiftUI

// The Codex app's local diff comments drawn natively (`use-diff-annotations` `Vt`, `diff-comment-card`;
// `commentAttachments` in `app-primary`): a card under the commented line with the author, the line it
// is on and the words, and one chip in the composer that counts the comments waiting for the message.

/// A comment under its line in the review's diff: a new one being written, or one waiting to be sent.
/// A new comment has Cancel and Comment; a waiting one shows its words and Delete, and clicking the
/// words edits them with Delete, Cancel and Save (`code.diffComment.*`).
struct DiffCommentCard: View {
    let title: String
    let text: String
    let isNew: Bool
    let onSave: (String) -> Void
    let onCancel: () -> Void
    var onDelete: (() -> Void)? = nil

    @State private var editedText: String
    @State private var isEditing: Bool
    @FocusState private var isFocused: Bool
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    init(title: String, text: String = "", isNew: Bool, onSave: @escaping (String) -> Void,
         onCancel: @escaping () -> Void = {}, onDelete: (() -> Void)? = nil) {
        self.title = title
        self.text = text
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        _editedText = State(initialValue: text)
        _isEditing = State(initialValue: isNew)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isEditing { editor } else { reader }
        }
        .padding(10)
        .background { cardBackground }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isEditing && isFocused ? Color.secondary.opacity(0.6) : ParityTheme.separator)
        }
        .onAppear { if isEditing { isFocused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 17 * interfaceScale))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.string("You"))
                .font(.system(size: 12 * interfaceScale, weight: .semibold))
            Text(verbatim: title)
                .font(.system(size: 11 * interfaceScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var editor: some View {
        TextField(L10n.string("Add a comment…"), text: $editedText, axis: .vertical)
            .lineLimit(1...)
            .focused($isFocused)
            .onSubmit(save)
            .onExitCommand(perform: cancel)
            .accessibilityLabel(title)
            .scrollsPastLines(12)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5 * interfaceScale))
        editorButtons
    }

    private var editorButtons: some View {
        HStack(spacing: 8) {
            if !isNew, let onDelete {
                Button(L10n.string("Delete"), role: .destructive, action: onDelete)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            Button(L10n.string("Cancel"), action: cancel)
            Button(isNew ? L10n.string("Comment") : L10n.string("Save"), action: save)
                .parityProminentButton()
                .disabled(!canSave)
        }
        .controlSize(.small)
        .parityPointer()
    }

    @ViewBuilder
    private var reader: some View {
        Text(verbatim: text)
            .font(.system(size: 12.5 * interfaceScale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture(perform: edit)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, edit)
        if let onDelete {
            HStack {
                Spacer(minLength: 0)
                Button(L10n.string("Delete"), action: onDelete)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
                    .parityPointer()
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay { RoundedRectangle(cornerRadius: 8).fill(ParityTheme.subtleFill) }
    }

    private var canSave: Bool {
        let trimmed = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && (isNew || trimmed != text)
    }

    private func edit() {
        editedText = text
        isEditing = true
        isFocused = true
    }

    private func save() {
        guard canSave else { return }
        onSave(editedText.trimmingCharacters(in: .whitespacesAndNewlines))
        if !isNew { isEditing = false }
    }

    private func cancel() {
        if isNew {
            onCancel()
        } else {
            editedText = text
            isEditing = false
        }
    }
}

/// The comments waiting for the next message, one chip in the composer's row as the Codex app has it
/// (`commentAttachments.numComments`): their count, their places and words on hover, and a button
/// that removes them all (`commentAttachments.removeAriaLabel`).
struct DiffCommentsChip: View {
    let comments: [DiffComment]
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.bubble")
            Text(Self.title(count: comments.count))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(L10n.string("Remove comments attachment"))
            .help(L10n.string("Remove comments attachment"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(ParityTheme.subtleFill, in: Capsule())
        .help(Self.tooltip(comments))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.title(count: comments.count))
    }

    /// "1 comment", "3 comments".
    static func title(count: Int) -> String { DiffComment.countTitle(count) }

    /// Each comment's file and lines, then its words (`tB` in `app-primary`).
    static func tooltip(_ comments: [DiffComment]) -> String {
        comments.map { comment in
            let words = comment.body.split(whereSeparator: \.isNewline).joined(separator: " ")
            let snippet = words.count > 160 ? String(words.prefix(159)) + "…" : words
            return "\(comment.path):\(comment.linesLabel) — \(snippet)"
        }.joined(separator: "\n")
    }
}
