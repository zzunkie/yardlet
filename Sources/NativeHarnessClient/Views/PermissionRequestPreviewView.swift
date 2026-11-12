import SwiftUI

/// The change a tool request would make, inside its approval card: a file's edits or new
/// contents in the file change card's diff box, or a command with its description.
struct PermissionRequestPreviewView: View {
    let preview: PermissionRequestPreview

    @Environment(\.transcriptWorkspaceURL) private var workspaceURL

    var body: some View {
        switch preview {
        case let .edits(path, edits, omittedEditCount):
            let diff = PermissionRequestPreviewProjection.diff(edits: edits, omittedEditCount: omittedEditCount)
            box(path: path, diff: diff, emptyText: L10n.string("No changes")) {
                CodexLineCountsText(counts: .init(additions: diff.additions, deletions: diff.deletions))
            }
        case let .write(path, content):
            let diff = PermissionRequestPreviewProjection.content(content)
            box(path: path, diff: diff, emptyText: L10n.string("Empty file")) {
                Text(L10n.format("%lld lines", Int64(diff.additions + content.omittedLineCount)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case let .command(command, description):
            VStack(alignment: .leading, spacing: 6) {
                if let description {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.string("Command"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                CodexBoundedOutput(text: command.text, folds: false)
                if command.omittedLineCount > 0 {
                    Text(L10n.format("%lld more lines", Int64(command.omittedLineCount)))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func box<Summary: View>(
        path: String, diff: PermissionRequestPreviewProjection.Diff, emptyText: String,
        @ViewBuilder summary: () -> Summary
    ) -> some View {
        let displayPath = CodexFileChangeDiff.displayPath(path, workspaceURL: workspaceURL)
        let hasChanges = diff.additions + diff.deletions > 0
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: displayPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                summary()
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            if hasChanges {
                CodexDiffPreviewLines(lines: diff.lines)
            } else {
                notice(emptyText)
            }
            if hasChanges, diff.hiddenLineCount > 0 {
                Divider()
                notice(L10n.format("%lld more lines", Int64(diff.hiddenLineCount)))
            }
            if diff.omittedEditCount > 0 {
                Divider()
                notice(L10n.format("%lld more edits", Int64(diff.omittedEditCount)))
            }
        }
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(ParityTheme.separator) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(displayPath)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }

    /// The card's own summary line when it only repeats what the preview already shows.
    static func repeats(_ detail: String, in preview: PermissionRequestPreview) -> Bool {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        switch preview {
        case let .command(_, description):
            return trimmed == description
        case let .edits(path, _, _), let .write(path, _):
            return !trimmed.isEmpty && (trimmed == path || path.hasSuffix("/" + trimmed))
        }
    }
}
