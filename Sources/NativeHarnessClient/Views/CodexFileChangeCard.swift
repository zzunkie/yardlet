import SwiftUI

private struct OpenTaskChangesKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}

private struct OpenTaskFileChangesKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (String) -> Void)? = nil
}

extension EnvironmentValues {
    /// Opens the same panel with a particular task-relative file selected.
    var openTaskFileChanges: (@MainActor @Sendable (String) -> Void)? {
        get { self[OpenTaskFileChangesKey.self] }
        set { self[OpenTaskFileChangesKey.self] = newValue }
    }

    /// Opens the task's Changes panel, where a diff the conversation leaves out continues. Nil
    /// where the conversation has no task panels to open.
    var openTaskChanges: (@MainActor @Sendable () -> Void)? {
        get { self[OpenTaskChangesKey.self] }
        set { self[OpenTaskChangesKey.self] = newValue }
    }
}

/// A file change card's files, one row each, as `CodexFileChangeCardProjection` lays them out.
/// The rows of a file change card, already laid out: a Codex patch's files, or the file a harness
/// activity changed (`ConversationFileChangeProjection`).
struct CodexFileChangeRows: View {
    let rows: [CodexFileChangeCardProjection.Row]
    let handoffs: [CodexChangeHandoff]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                CodexFileChangeRow(row: row, handoff: handoffs.first { $0.relativePath == row.id })
            }
        }
    }
}

/// Folded by default. The row keeps its open state by path while the provider rewrites the
/// card's file list. Opening it leaves transcript following as it was, as for any card.
private struct CodexFileChangeRow: View {
    let row: CodexFileChangeCardProjection.Row
    let handoff: CodexChangeHandoff?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            summary
            if isExpanded {
                CodexFileDiffBox(row: row) { fileLink(row.displayPath) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.displayPath)
        .accessibilityValue(row.accessibilityValue)
    }

    private var summary: some View {
        HStack(spacing: 5) {
            if isExpanded, let title = row.expandedTitle {
                Text(title)
            } else {
                Text(row.verb)
                fileLink(row.fileName)
                if let counts = row.lineCounts {
                    CodexLineCountsText(counts: counts)
                }
            }
            if row.canExpand {
                Button(action: toggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .parityPointer()
                .accessibilityLabel(L10n.format("Toggle diff for %@", row.fileName))
                .accessibilityValue(L10n.string(isExpanded ? "Expanded" : "Collapsed"))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .onTapGesture { if row.canExpand { toggle() } }
    }

    private func fileLink(_ label: String) -> some View {
        CodexFileChangeLink(row: row, handoff: handoff, label: label)
    }

    private func toggle() {
        isExpanded.toggle()
    }
}

/// A changed file's name that opens the file where the change begins, as the Codex app does,
/// unless the provider named a line itself. A path outside the task's folder does not open.
struct CodexFileChangeLink: View {
    let row: CodexFileChangeCardProjection.Row
    let handoff: CodexChangeHandoff?
    let label: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(action: open) {
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .parityPointer()
        .disabled(target == nil)
        .help(target == nil ? L10n.string("Path is outside the task workspace") : row.displayPath)
        .accessibilityLabel(row.displayPath)
        .accessibilityValue(
            target == nil ? L10n.string("Path is outside the task workspace") : L10n.string("Open file")
        )
        .conversationLinkMenu(target, open: open)
    }

    /// The move destination when there is one; the handoff verifies only relative provider paths.
    private var target: URL? {
        row.fileURL ?? handoff?.verifiedURL
    }

    private func open() {
        guard let url = target else { return }
        let line = handoff?.line.map(Int.init)
            ?? (row.preview == .available ? row.previewLines.firstChangedLine : nil)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let line {
            components?.fragment = "L\(line)" + (handoff?.column.map { "C\($0)" } ?? "")
        }
        openURL(components?.url ?? url)
    }
}

/// A file's diff under its name and line counts: the box a file change's row and a file change's
/// status line open into.
struct CodexFileDiffBox<FileLink: View>: View {
    let row: CodexFileChangeCardProjection.Row
    @ViewBuilder let fileLink: () -> FileLink

    @Environment(\.openTaskChanges) private var openTaskChanges
    @Environment(\.openTaskFileChanges) private var openTaskFileChanges

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                fileLink()
                if let counts = row.lineCounts {
                    CodexLineCountsText(counts: counts)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            content
        }
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(ParityTheme.separator) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var content: some View {
        switch row.preview {
        case .missing:
            EmptyView()
        case .tooLarge:
            notice(L10n.string("Diff too large to preview"), continuesInChanges: true)
        case .available:
            let preview = row.previewLines
            if preview.lines.isEmpty {
                notice(L10n.string(row.kind == .delete ? "Contents deleted" : "No changes"), continuesInChanges: false)
            } else {
                CodexDiffPreviewLines(lines: preview.lines)
                if preview.hiddenLineCount > 0 {
                    Divider()
                    notice(L10n.format("%lld more lines", Int64(preview.hiddenLineCount)), continuesInChanges: true)
                }
            }
        }
    }

    private func notice(_ text: String, continuesInChanges: Bool) -> some View {
        HStack(spacing: 8) {
            Text(text).foregroundStyle(.secondary)
            if continuesInChanges, openTaskFileChanges != nil || openTaskChanges != nil {
                Button(L10n.string("Open in Changes")) {
                    if let openTaskFileChanges { openTaskFileChanges(row.displayPath) }
                    else { openTaskChanges?() }
                }
                    .buttonStyle(.link)
                    .parityPointer()
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// Fixed-height lines, so the box can size itself without measuring: up to `visibleLineLimit`
/// lines as they are, more inside a box of that height that scrolls, as the Codex app caps its
/// preview. Approval cards draw a requested change with it too; their lines have no numbers and
/// may carry a caption in place of a hunk rule.
struct CodexDiffPreviewLines: View {
    static let visibleLineLimit = 14

    let lines: [CodexFileChangeCardProjection.Preview.Line]
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        let lineHeight = 17 * interfaceScale
        let scrolls = lines.count > Self.visibleLineLimit
        let largest = lines.compactMap(\.number).max()
        let gutterWidth = largest.map { CGFloat(max(String($0).count, 2)) * 7 * interfaceScale + 10 } ?? 6
        GeometryReader { viewport in
            ScrollView(scrolls ? [.horizontal, .vertical] : .horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        lineView(line, gutterWidth: gutterWidth, width: viewport.size.width)
                            .frame(minWidth: viewport.size.width, minHeight: lineHeight,
                                   maxHeight: lineHeight, alignment: .leading)
                            .background(background(for: line.kind))
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
        }
        .frame(height: CGFloat(min(lines.count, Self.visibleLineLimit)) * lineHeight)
    }

    @ViewBuilder
    private func lineView(
        _ line: CodexFileChangeCardProjection.Preview.Line, gutterWidth: CGFloat, width: CGFloat
    ) -> some View {
        if line.kind == .separator, !line.text.isEmpty {
            Text(verbatim: line.text)
                .font(.system(size: 10.5 * interfaceScale, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(width: width, alignment: .leading)
                .overlay(alignment: .top) {
                    if line.id > 0 { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
                }
        } else if line.kind == .separator {
            Rectangle()
                .fill(ParityTheme.separator)
                .frame(width: max(0, width - 20), height: 1)
                .padding(.horizontal, 10)
        } else {
            HStack(spacing: 0) {
                Text(verbatim: line.number.map(String.init) ?? "")
                    .foregroundStyle(.tertiary)
                    .frame(width: gutterWidth, alignment: .trailing)
                Text(verbatim: marker(for: line.kind))
                    .foregroundStyle(markerColor(for: line.kind))
                    .frame(width: 16)
                Text(verbatim: line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(line.kind == .context ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
                    .padding(.trailing, 10)
            }
            .font(.system(size: 11 * interfaceScale, design: .monospaced))
            .lineLimit(1)
        }
    }

    private func marker(for kind: CodexFileChangeCardProjection.Preview.Line.Kind) -> String {
        switch kind {
        case .addition: "+"
        case .deletion: "-"
        case .context, .separator: ""
        }
    }

    private func markerColor(for kind: CodexFileChangeCardProjection.Preview.Line.Kind) -> Color {
        switch kind {
        case .addition: .green
        case .deletion: .red
        case .context, .separator: .clear
        }
    }

    private func background(for kind: CodexFileChangeCardProjection.Preview.Line.Kind) -> Color {
        switch kind {
        case .addition: .green.opacity(0.1)
        case .deletion: .red.opacity(0.1)
        case .context, .separator: .clear
        }
    }
}

/// The row's accessibility value already carries the counts.
struct CodexLineCountsText: View {
    let counts: CodexFileChangeCardProjection.LineCounts

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(counts.additions)").foregroundStyle(.green)
            Text(verbatim: "−\(counts.deletions)").foregroundStyle(.red)
        }
        .font(.system(size: 11).monospacedDigit())
        .fixedSize()
        .accessibilityHidden(true)
    }
}
