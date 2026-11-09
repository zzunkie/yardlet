import AppKit
import SwiftUI

/// Two lines of a file's diff the person chose, by line ID: where the choice started and where it
/// reaches (a click, then a Shift-click).
struct DiffLineSelection: Equatable, Sendable {
    var anchor: Int
    var extent: Int

    init(anchor: Int, extent: Int) {
        self.anchor = anchor
        self.extent = extent
    }

    init(line: Int) {
        self.init(anchor: line, extent: line)
    }
}

/// A Markdown file's rendered view in the review (`MarkdownReviewDiff`): whether it is on, and how
/// the change is read.
struct DiffMarkdownPreview {
    var isOn: Binding<Bool>
    /// Changes whenever what `load` reads does: the scope, the file and its diff.
    let loadID: String
    /// The file's folder, which the document's relative links are read against.
    let documentFolder: URL?
    let load: @MainActor () async -> MarkdownReviewDiff.Outcome
}

/// One file of the review's diff, line by line, with its diff comments under their lines.
///
/// As in the Codex app's diff (`code-diff`, `use-diff-annotations`): pointing at a line shows a "+" in
/// its gutter that opens a comment on it; clicking line numbers chooses a line and Shift-clicking
/// another makes a range, which the "+" then comments on. The line's context menu has the same
/// "Request changes" (`wham.diff.contextMenu.requestChanges`). A comment waits in the task's draft
/// until the next message carries it.
struct DiffFileContent: View {
    let file: DiffFile
    let width: CGFloat
    let showsHeader: Bool
    /// The folder the file's path is relative to; nil leaves the file without comments.
    let commentRoot: String?
    @Binding var comments: [DiffComment]

    /// A Markdown file's rendered view; nil for any other file.
    let markdownPreview: DiffMarkdownPreview?
    /// The tasks that edited or read the file, under its name in the header.
    let fileTasks: FileTasks

    @State private var newComment: DiffLineSelection?
    @State private var selection: DiffLineSelection?
    @State private var hoveredLineID: Int?
    @State private var markdownOutcome: MarkdownReviewDiff.Outcome?
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    init(file: DiffFile, width: CGFloat, showsHeader: Bool, commentRoot: String?,
         comments: Binding<[DiffComment]>, newComment: DiffLineSelection? = nil,
         markdownPreview: DiffMarkdownPreview? = nil, fileTasks: FileTasks = FileTasks()) {
        self.file = file
        self.width = width
        self.showsHeader = showsHeader
        self.commentRoot = commentRoot
        self.markdownPreview = markdownPreview
        self.fileTasks = fileTasks
        _comments = comments
        _newComment = State(initialValue: newComment)
        _selection = State(initialValue: newComment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.path).font(.callout.weight(.semibold)).textSelection(.enabled)
                            .lineLimit(2).truncationMode(.middle).help(file.path)
                        Self.summary(file)
                        if !fileTasks.isEmpty { FileTasksLine(tasks: fileTasks) }
                    }
                    Spacer(minLength: 0)
                    if let markdownPreview { MarkdownReviewToggle(isOn: markdownPreview.isOn) }
                }.padding(12)
                Divider()
            }
            if let markdownPreview, markdownPreview.isOn.wrappedValue {
                switch markdownOutcome {
                case nil:
                    ProgressView(L10n.string("Loading preview…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .rows(rows)?:
                    MarkdownReviewView(rows: rows, documentFolder: markdownPreview.documentFolder)
                case let .unavailable(message)?:
                    Label(message, systemImage: "doc.richtext")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ParityTheme.subtleFill)
                    lines
                }
            } else {
                lines
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: markdownPreview.flatMap { $0.isOn.wrappedValue ? $0.loadID : nil }) {
            guard let markdownPreview, markdownPreview.isOn.wrappedValue else { return }
            markdownOutcome = nil
            let outcome = await markdownPreview.load()
            guard !Task.isCancelled else { return }
            markdownOutcome = outcome
        }
    }

    /// The file's diff line by line, with its comments under their lines.
    @ViewBuilder
    private var lines: some View {
        let maxLine = file.lines.reduce(0) { max($0, $1.oldLine ?? 0, $1.newLine ?? 0) }
        let gutterWidth = max(38, CGFloat(String(maxLine).count) * 7 * interfaceScale + 14)
        let shown = shownComments
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(L10n.string("Old")).frame(width: gutterWidth)
                Text(L10n.string("New")).frame(width: gutterWidth)
                Text(L10n.string("Changes")).padding(.leading, 10)
            }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 5)
            Divider()
            GeometryReader { viewport in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(file.lines.filter { $0.kind != .fileHeader && !$0.text.hasPrefix("index ") }) { line in
                            row(line, gutterWidth: gutterWidth)
                            ForEach(shown[line.id] ?? []) { comment in
                                commentCard(savedCard(comment), gutterWidth: gutterWidth, viewport: viewport.size.width)
                            }
                            if let newComment, endLineID(of: newComment) == line.id {
                                commentCard(newCard(newComment), gutterWidth: gutterWidth, viewport: viewport.size.width)
                            }
                        }
                    }
                    .frame(minWidth: width, minHeight: viewport.size.height, alignment: .topLeading)
                }
                .defaultScrollAnchor(.topLeading)
                .defaultScrollAnchor(.topLeading, for: .alignment)
            }
        }
    }

    // MARK: - Lines

    private func row(_ line: DiffLine, gutterWidth: CGFloat) -> some View {
        let commentable = commentRoot != nil && line.commentAnchor != nil
        let isSelected = isInSelection(line)
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                lineNumber(line.oldLine, width: gutterWidth)
                lineNumber(line.newLine, width: gutterWidth)
            }
            .overlay(alignment: .leading) {
                if commentable, hoveredLineID == line.id {
                    Button { startComment(at: line) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9 * interfaceScale, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 16 * interfaceScale, height: 16 * interfaceScale)
                            .background(ParityTheme.accent, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .parityPointer()
                    .padding(.leading, 3)
                    .help(L10n.string("Request changes"))
                    .accessibilityLabel(L10n.string("Request changes"))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard commentable else { return }
                choose(line, extending: NSEvent.modifierFlags.contains(.shift))
            }
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 12 * interfaceScale, weight: Self.weight(for: line.kind), design: .monospaced))
                .textSelection(.enabled).foregroundStyle(Self.foreground(for: line.kind))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10).padding(.vertical, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.background(for: line.kind))
        .background(isSelected ? ParityTheme.accent.opacity(0.14) : .clear)
        .onHover { hovering in
            if hovering { hoveredLineID = line.id } else if hoveredLineID == line.id { hoveredLineID = nil }
        }
        .contextMenu {
            if commentable {
                Button(L10n.string("Request changes")) { startComment(at: line) }
            }
        }
    }

    private func lineNumber(_ number: Int?, width: CGFloat) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 11 * interfaceScale, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: width - 6, alignment: .trailing).padding(.trailing, 6)
            .padding(.vertical, 3)
            .background(ParityTheme.subtleFill)
    }

    // MARK: - Comments

    /// The file's comments, by the line each shows under.
    private var shownComments: [Int: [DiffComment]] {
        guard let commentRoot else { return [:] }
        var shown: [Int: [DiffComment]] = [:]
        for comment in comments where comment.workspaceRoot == commentRoot {
            if let line = file.lineID(showing: comment) { shown[line, default: []].append(comment) }
        }
        return shown
    }

    private func commentCard(_ card: DiffCommentCard, gutterWidth: CGFloat, viewport: CGFloat) -> some View {
        card
            .frame(width: max(240, min(640, viewport - gutterWidth * 2 - 24)), alignment: .leading)
            .padding(.leading, gutterWidth * 2 + 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func savedCard(_ comment: DiffComment) -> DiffCommentCard {
        DiffCommentCard(
            title: comment.lineTitle, text: comment.body, isNew: false,
            onSave: { body in
                guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
                comments[index].body = body
            },
            onDelete: { comments.removeAll { $0.id == comment.id } }
        )
    }

    private func newCard(_ lines: DiffLineSelection) -> DiffCommentCard {
        let title = file.comment(from: lines.anchor, to: lines.extent, workspaceRoot: commentRoot, body: "")?.lineTitle ?? ""
        return DiffCommentCard(
            title: title, isNew: true,
            onSave: { body in
                if let comment = file.comment(from: lines.anchor, to: lines.extent, workspaceRoot: commentRoot, body: body) {
                    comments.append(comment)
                }
                newComment = nil
                selection = nil
            },
            onCancel: {
                newComment = nil
                selection = nil
            }
        )
    }

    /// A comment opens on the chosen lines when `line` is among them, otherwise on `line` alone.
    private func startComment(at line: DiffLine) {
        let lines = selection.flatMap { isInSelection(line) ? $0 : nil } ?? DiffLineSelection(line: line.id)
        newComment = lines
        selection = lines
    }

    /// A click chooses a line; a Shift-click reaches from the chosen line to this one.
    private func choose(_ line: DiffLine, extending: Bool) {
        guard newComment == nil else { return }
        if extending, var current = selection {
            current.extent = line.id
            selection = current
        } else {
            selection = selection == DiffLineSelection(line: line.id) ? nil : DiffLineSelection(line: line.id)
        }
    }

    private func isInSelection(_ line: DiffLine) -> Bool {
        guard let selection else { return false }
        return min(selection.anchor, selection.extent) <= line.id && line.id <= max(selection.anchor, selection.extent)
    }

    /// The line a new comment shows under: the later of its two lines.
    private func endLineID(of lines: DiffLineSelection) -> Int {
        max(lines.anchor, lines.extent)
    }

    // MARK: - Drawing

    static func summary(_ file: DiffFile) -> some View {
        HStack(spacing: 5) {
            Text(file.status).foregroundStyle(.secondary)
            Text("+\(file.additionCount)").foregroundStyle(.green)
            Text("−\(file.deletionCount)").foregroundStyle(.red)
        }
        .font(.caption.monospacedDigit()).fixedSize()
        .accessibilityElement(children: .combine)
    }

    private static func weight(for kind: DiffLineKind) -> Font.Weight {
        switch kind {
        case .fileHeader, .hunkHeader: .semibold
        default: .regular
        }
    }

    private static func foreground(for kind: DiffLineKind) -> Color {
        switch kind {
        case .addition: .green
        case .deletion: .red
        case .hunkHeader: .blue
        case .fileHeader: .primary
        case .context, .metadata: .secondary
        }
    }

    private static func background(for kind: DiffLineKind) -> Color {
        switch kind {
        case .addition: .green.opacity(0.075)
        case .deletion: .red.opacity(0.075)
        case .hunkHeader: .blue.opacity(0.055)
        case .fileHeader: ParityTheme.subtleFill
        default: .clear
        }
    }
}
