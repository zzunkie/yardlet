import SwiftUI

struct TranscriptMarkdownText: View {
    @Environment(\.pauseTranscriptFollowing) private var pauseFollowing
    @Environment(\.conversationFindSlot) private var findSlot
    let text: String
    let initialCharacterLimit: Int
    /// A Codex message also draws the directives the Codex app draws (`CodexMessageDirectives`).
    let dialect: TranscriptMarkdownDialect
    @State private var visibleCharacterLimit: Int

    init(text: String, characterLimit: Int = TranscriptRenderWindow.chunkCharacterLimit,
         dialect: TranscriptMarkdownDialect = .standard) {
        self.text = text
        initialCharacterLimit = characterLimit
        self.dialect = dialect
        _visibleCharacterLimit = State(initialValue: characterLimit)
    }

    var body: some View {
        let window = TranscriptRenderWindow(
            text: text, characterLimit: visibleCharacterLimit,
            initialCharacterLimit: initialCharacterLimit,
            lineLimit: TranscriptRenderWindow.chunkLineLimit * max(1, visibleCharacterLimit / max(1, initialCharacterLimit))
        )
        VStack(alignment: .leading, spacing: 8) {
            renderedText(window.text)
            if window.isWindowed {
                Button(
                    window.hasMore
                        ? L10n.string("Show more")
                        : L10n.string("Show less")
                ) {
                    pauseFollowing()
                    if window.hasMore {
                        visibleCharacterLimit += initialCharacterLimit
                    } else {
                        visibleCharacterLimit = initialCharacterLimit
                    }
                }
                .buttonStyle(.link)
                .parityPointer()
                .font(.caption2)
            }
        }
        .onChange(of: findSlot?.active, initial: true) { _, active in revealFindMatch(active) }
    }

    @ViewBuilder
    private func renderedText(_ visibleText: String) -> some View {
        TranscriptMarkdownDocumentView(source: visibleText, fullSource: text, dialect: dialect)
    }

    /// Shows more of a long message when find's current match is past what it shows.
    private func revealFindMatch(_ active: ConversationFindLocation?) {
        guard let active, let query = findSlot?.query else { return }
        let window = TranscriptRenderWindow(
            text: text, characterLimit: visibleCharacterLimit, initialCharacterLimit: initialCharacterLimit,
            lineLimit: TranscriptRenderWindow.chunkLineLimit * max(1, visibleCharacterLimit / max(1, initialCharacterLimit))
        )
        guard window.hasMore else { return }
        let shown = ConversationFindEngine.markdownSegments(window.text, dialect: dialect).first { $0.key == active.key }
        if let shown, ConversationFindEngine.occurrences(of: query, in: shown.text).count > active.occurrence { return }
        visibleCharacterLimit = TranscriptRenderWindow.characterLimitShowingAll(of: text, initialCharacterLimit: initialCharacterLimit)
    }
}

private struct TranscriptMarkdownDocumentView: View {
    let source: String
    let fullSource: String
    let dialect: TranscriptMarkdownDialect
    /// The blocks the message was last read into, which a streaming message's next words keep
    /// (`TranscriptMarkdownReadings`). Nothing observes it.
    @State private var readings = TranscriptMarkdownReadings()

    var body: some View {
        TranscriptMarkdownBlocksView(
            blocks: TranscriptMarkdownDocument(source, dialect: dialect, readings: readings).blocks,
            fullSource: fullSource, dialect: dialect, path: []
        )
    }
}

/// Blocks one after another: each run of prose (`isProse`) as one text that a drag selects across,
/// and the blocks drawn on their own — tables, the Codex cards — between them.
private struct TranscriptMarkdownBlocksView: View {
    let blocks: [TranscriptMarkdownBlock]
    let fullSource: String
    let dialect: TranscriptMarkdownDialect
    let path: [Int]

    private enum Run {
        case prose([TranscriptProseBlock])
        case block(TranscriptMarkdownBlock, index: Int)
    }

    private var runs: [Run] {
        var runs: [Run] = []
        var prose: [TranscriptProseBlock] = []
        for (index, block) in blocks.enumerated() {
            if block.isProse {
                prose.append(TranscriptProseBlock(block: block, path: path + [index]))
                continue
            }
            if !prose.isEmpty { runs.append(.prose(prose)) }
            prose = []
            runs.append(.block(block, index: index))
        }
        if !prose.isEmpty { runs.append(.prose(prose)) }
        return runs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ParityTheme.proseBlockSpacing) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                switch run {
                case let .prose(blocks):
                    TranscriptProseRun(blocks: blocks, fullSource: fullSource, dialect: dialect)
                case let .block(block, index):
                    TranscriptMarkdownBlockView(block: block, fullSource: fullSource, dialect: dialect, path: path + [index])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A run of prose blocks in one text view, with the look and find marks of the message around it.
private struct TranscriptProseRun: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.transcriptWorkspaceURL) private var workspaceURL
    @Environment(\.conversationFindSlot) private var findSlot
    @Environment(\.conversationFind) private var conversationFind
    @Environment(\.transcriptCopyDetails) private var copyDetails
    let blocks: [TranscriptProseBlock]
    let fullSource: String
    let dialect: TranscriptMarkdownDialect

    var body: some View {
        let active = findSlot?.active
        TranscriptProseText(
            blocks: blocks, fullSource: fullSource, dialect: dialect,
            style: TranscriptProseStyle(scale: interfaceScale, isDark: colorScheme == .dark, workspaceURL: workspaceURL),
            // Only the message holding the current match follows find's scroll requests.
            find: TranscriptProseFind(query: findSlot?.query, active: active,
                                      scrollToken: active == nil ? nil : conversationFind?.scrollRequest?.token,
                                      model: conversationFind),
            copyDetails: copyDetails
        )
    }
}

/// A sent message's words, as written, in the conversation's text view: selectable on into the
/// answers around it (`ConversationSelection`), as wide as its longest line, and marked by find as
/// the message's one text.
struct TranscriptPlainText: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationFindSlot) private var findSlot
    @Environment(\.conversationFind) private var conversationFind
    let text: String

    var body: some View {
        let active = findSlot?.active
        TranscriptProseText(
            blocks: [TranscriptProseBlock(block: .paragraph(TranscriptInlineContent(plainText: text)), path: [])],
            fullSource: text, dialect: .standard,
            style: TranscriptProseStyle(scale: interfaceScale, isDark: colorScheme == .dark),
            find: TranscriptProseFind(query: findSlot?.query, active: active,
                                      scrollToken: active == nil ? nil : conversationFind?.scrollRequest?.token,
                                      model: conversationFind),
            segmentKey: .text, fitsWidth: true
        )
    }
}

/// Where a link in a conversation opens: a web page in the task's own browser panel, as the Codex
/// app opens one in its browser (decision of 2026-10-22: the Yardlet browser is the default); a file
/// in the task's files; anything else (mail, other apps' links) where the system sends it.
enum ConversationLinkRoute: Equatable {
    case taskBrowser
    case outside

    init(_ url: URL) {
        self = ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .taskBrowser : .outside
    }
}

private struct TranscriptCopyDetailsKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// "Copy item details" for the message drawn below, which its text's context menu offers.
    var transcriptCopyDetails: String? {
        get { self[TranscriptCopyDetailsKey.self] }
        set { self[TranscriptCopyDetailsKey.self] = newValue }
    }
}

private struct TranscriptMarkdownBlockView: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let block: TranscriptMarkdownBlock
    let fullSource: String
    let dialect: TranscriptMarkdownDialect
    let path: [Int]

    var body: some View {
        switch block {
        case let .paragraph(text):
            TranscriptInlineMarkdownText(
                text: text, font: ParityTheme.conversationFont(scale: interfaceScale), findKey: .block(path)
            ).equatable()

        case let .heading(level, text):
            TranscriptInlineMarkdownText(text: text, font: headingFont(level), findKey: .block(path))
                .padding(.top, level <= 2 ? 3 : 0)

        case let .unorderedList(items, isLoose):
            list(items, start: nil, isLoose: isLoose)

        case let .orderedList(start, items, isLoose):
            list(items, start: start, isLoose: isLoose)

        case let .blockQuote(blocks):
            children(blocks, path: path)
                .padding(.leading, 13)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(ParityTheme.strongSeparator)
                        .frame(width: 3)
                }
                .foregroundStyle(.secondary)

        case let .code(language, text):
            TranscriptCodeBlock(language: language, text: text, findKey: .block(path)) {
                TranscriptCopyPayload.code(in: fullSource, blockPath: path, dialect: dialect)
            }

        case let .table(headers, rows, alignments):
            TranscriptMarkdownTable(headers: headers, rows: rows, alignments: alignments, path: path)

        case .divider:
            Divider()

        case let .suggestedTask(task):
            CodexSuggestedTaskCard(task: task)

        case let .details(summary, isOpen, blocks):
            CodexDetailsBlock(summary: summary, startsOpen: isOpen, path: path) {
                children(blocks, path: path)
            }

        case let .reviewComments(comments):
            CodexReviewCommentsCard(comments: comments)

        case let .visualization(visualization):
            CodexVisualizationCard(visualization: visualization)
        }
    }

    private func list(_ items: [TranscriptMarkdownListItem], start: Int?, isLoose: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 9, verticalSpacing: (isLoose ? 15 : 10) * interfaceScale) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                GridRow(alignment: .firstTextBaseline) {
                    Group {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square" : "square")
                        } else {
                            Text(start.map { "\($0 + offset)." } ?? "•")
                        }
                    }
                    .font(ParityTheme.conversationFont(scale: interfaceScale))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .gridColumnAlignment(.trailing)
                    children(item.blocks, path: path + [offset])
                }
            }
        }
    }

    // Type erase only the recursive edge so arbitrarily mixed containers share one native view.
    private func children(_ blocks: [TranscriptMarkdownBlock], path: [Int]) -> AnyView {
        AnyView(TranscriptMarkdownBlocksView(blocks: blocks, fullSource: fullSource, dialect: dialect, path: path))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.semibold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: .body.weight(.semibold)
        }
    }
}

struct TranscriptInlineMarkdownText: View, Equatable {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.font == rhs.font && lhs.findKey == rhs.findKey
            && lhs.placesFindAnchor == rhs.placesFindAnchor
    }
    @Environment(\.transcriptWorkspaceURL) private var workspaceURL
    @Environment(\.conversationFindSlot) private var findSlot
    @Environment(\.colorScheme) private var colorScheme
    let text: TranscriptInlineContent
    let font: Font
    /// Where this text sits in its message, for find's marks.
    var findKey: ConversationFindSegmentKey? = nil
    /// A table cell scrolls inside its table, so the table places the scroll target instead.
    var placesFindAnchor = true

    var body: some View {
        var attributed = text.resolved(relativeTo: workspaceURL)
        let fraction = findKey.flatMap { key in
            findSlot.flatMap { slot in
                ConversationFindStyle.mark(&attributed, query: slot.query, active: slot.active,
                                           key: key, scheme: colorScheme)
            }
        }
        return Text(attributed)
            .font(font)
            .lineSpacing(ParityTheme.proseLineSpacing * interfaceScale)
            .tint(ParityTheme.accent)
            .fixedSize(horizontal: false, vertical: true)
            .conversationFindAnchor(placesFindAnchor ? fraction : nil)
    }
}

/// A Markdown table: scrolled sideways when it is wider than the message, and, as both apps offer,
/// "Expand table" (a sheet with the whole table) and the Codex app's "Copy table" on hover, which
/// copies the table as Markdown and as an HTML table that documents and spreadsheets paste as a table.
private struct TranscriptMarkdownTable: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.conversationFindSlot) private var findSlot
    @Environment(\.pauseTranscriptFollowing) private var pauseFollowing
    @Environment(\.revealsSentMessageActions) private var revealsActions
    let headers: [TranscriptInlineContent]
    let rows: [[TranscriptInlineContent]]
    let alignments: [TranscriptTableAlignment]
    var path: [Int] = []
    /// Drawn in the expanded sheet: wider columns, no actions of its own.
    var isExpanded = false
    @State private var isHovering = false
    @State private var showsExpanded = false
    @State private var focusBookmark: WindowFocusBookmark?

    var body: some View {
        if isExpanded {
            grid(maximumColumnWidth: 520 * interfaceScale)
        } else {
            compact
        }
    }

    private var compact: some View {
        ScrollView(.horizontal) {
            grid(maximumColumnWidth: 280 * interfaceScale)
        }
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(ParityTheme.separator) }
        .overlay(alignment: .topTrailing) {
            if isHovering || revealsActions {
                HStack(spacing: 2) {
                    TranscriptTableButton(systemName: "doc.on.doc", title: L10n.string("Copy table"), action: copy)
                    TranscriptTableButton(systemName: "arrow.up.left.and.arrow.down.right", title: L10n.string("Expand table"),
                                          action: expand)
                }
                .padding(4)
                .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(ParityTheme.separator) }
                .padding(6)
            }
        }
        .onHover { isHovering = $0 }
        .conversationFindAnchor(findAnchorFraction)
        .accessibilityActions {
            Button(L10n.string("Copy table"), action: copy)
            Button(L10n.string("Expand table"), action: expand)
        }
        .sheet(isPresented: $showsExpanded, onDismiss: {
            focusBookmark?.restore()
            focusBookmark = nil
        }) {
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.string("Table")).font(.headline)
                    Spacer()
                    Button(L10n.string("Copy table"), action: copy)
                    Button(L10n.string("Done")) { showsExpanded = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(14)
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    TranscriptMarkdownTable(headers: headers, rows: rows, alignments: alignments, path: path, isExpanded: true)
                        .padding(14)
                }
            }
            .frame(minWidth: 520, idealWidth: 860, minHeight: 300, idealHeight: 560)
        }
    }

    private func copy() {
        TranscriptTableCopy.copy(headers: headers, rows: rows, alignments: alignments)
    }

    private func expand() {
        focusBookmark = WindowFocusBookmark(window: NSApp.keyWindow)
        pauseFollowing()
        showsExpanded = true
    }

    private func grid(maximumColumnWidth: CGFloat) -> some View {
        TranscriptTableLayout(columns: columnCount, maximumColumnWidth: maximumColumnWidth) {
            ForEach(0..<columnCount, id: \.self) { column in
                cell(value(in: headers, at: column), row: nil, column: column)
                    .padding(.bottom, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(ParityTheme.separator).frame(height: 1) }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                ForEach(0..<columnCount, id: \.self) { column in
                    cell(value(in: row, at: column), row: index, column: column)
                }
            }
        }
        .padding(10)
    }

    /// The current match's row, when it is in this table.
    private var findAnchorFraction: Double? {
        guard findSlot?.query != nil, case let .cell(cellPath, row, _)? = findSlot?.active?.key,
              cellPath == path else { return nil }
        return (Double(row.map { $0 + 1 } ?? 0) + 0.5) / Double(rows.count + 1)
    }

    private func cell(_ text: TranscriptInlineContent, row: Int?, column: Int) -> some View {
        TranscriptInlineMarkdownText(
            text: text, font: .system(size: 13 * interfaceScale, weight: row == nil ? .semibold : .regular),
            findKey: .cell(path, row: row, column: column), placesFindAnchor: false
        )
        .multilineTextAlignment(textAlignment(column))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: cellAlignment(column))
    }

    private var columnCount: Int {
        headers.count
    }

    private func horizontalAlignment(_ column: Int) -> HorizontalAlignment {
        switch alignments.indices.contains(column) ? alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func cellAlignment(_ column: Int) -> Alignment {
        Alignment(horizontal: horizontalAlignment(column), vertical: .top)
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch alignments.indices.contains(column) ? alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func value(in row: [TranscriptInlineContent], at index: Int) -> TranscriptInlineContent {
        row.indices.contains(index) ? row[index] : ""
    }
}

struct TranscriptRenderWindow: Equatable, Sendable {
    static let chunkCharacterLimit = 32_000
    static let chunkLineLimit = 80

    let text: String
    let hasMore: Bool
    let isWindowed: Bool

    init(text: String, characterLimit: Int, initialCharacterLimit: Int = Self.chunkCharacterLimit,
         lineLimit: Int = Self.chunkLineLimit) {
        let boundedLimit = max(1, characterLimit)
        let prefix = text.prefix(boundedLimit + 1)
        var end = prefix.startIndex
        var characterCount = 0
        var lineCount = 1
        // Short lines can create a very tall SwiftUI Text well before the character cap.
        // Bound both dimensions, preserving the original Unicode and line endings.
        for character in prefix {
            if characterCount == boundedLimit { break }
            if character.isNewline {
                if lineCount == max(1, lineLimit) { break }
                lineCount += 1
            }
            characterCount += 1
            end = prefix.index(after: end)
        }
        hasMore = end != text.endIndex
        // Do not scan the complete streamed string merely to decide whether the collapse button
        // remains visible after expansion. The already bounded prefix tells us whether the source
        // ever crossed the initial window, even if a reused view currently holds shorter text.
        isWindowed = hasMore || characterCount > initialCharacterLimit || lineCount > Self.chunkLineLimit
        self.text = hasMore
            ? String(prefix[..<end]) + "\n\n…"
            : text
    }

    /// The visible character limit at which `TranscriptMarkdownText` shows all of `text`; its line
    /// limit grows with the character limit in steps of the initial limit.
    static func characterLimitShowingAll(of text: String, initialCharacterLimit: Int) -> Int {
        let step = max(1, initialCharacterLimit)
        let lines = text.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
        let steps = max((text.count + step - 1) / step, (lines + chunkLineLimit - 1) / chunkLineLimit, 1)
        return step * steps
    }
}

/// A small icon button over a table.
private struct TranscriptTableButton: View {
    let systemName: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .parityPointer()
        .accessibilityLabel(title)
        .help(title)
    }
}

/// A table copied as the Codex app copies one: its Markdown as plain text, and an HTML table that a
/// document or a spreadsheet pastes as a table.
enum TranscriptTableCopy {
    static func markdown(headers: [TranscriptInlineContent], rows: [[TranscriptInlineContent]],
                         alignments: [TranscriptTableAlignment]) -> String {
        func cell(_ text: TranscriptInlineContent) -> String {
            text.plainText.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        let rule = headers.indices.map { column -> String in
            switch alignments.indices.contains(column) ? alignments[column] : .leading {
            case .leading: "---"
            case .center: ":---:"
            case .trailing: "---:"
            }
        }
        let body = rows.map { row in line(headers.indices.map { row.indices.contains($0) ? cell(row[$0]) : "" }) }
        return ([line(headers.map(cell)), line(rule)] + body).joined(separator: "\n")
    }

    static func html(headers: [TranscriptInlineContent], rows: [[TranscriptInlineContent]]) -> String {
        func escaped(_ text: TranscriptInlineContent) -> String {
            text.plainText.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let head = headers.map { "<th>\(escaped($0))</th>" }.joined()
        let body = rows.map { row in
            "<tr>" + headers.indices.map { "<td>\(row.indices.contains($0) ? escaped(row[$0]) : "")</td>" }.joined() + "</tr>"
        }.joined()
        return "<table><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table>"
    }

    @MainActor
    static func copy(headers: [TranscriptInlineContent], rows: [[TranscriptInlineContent]],
                     alignments: [TranscriptTableAlignment], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(markdown(headers: headers, rows: rows, alignments: alignments), forType: .string)
        pasteboard.setString(html(headers: headers, rows: rows), forType: .html)
    }
}
