import SwiftUI

/// An answer's Markdown (CommonMark and GFM tables, docs/REMOTE_PROTOCOL.md §6.3), drawn in blocks: paragraphs and
/// lists with their inline styles, headings, quotes, code blocks that scroll sideways, and tables as monospaced
/// text. Selectable, so a part can be copied.
struct MarkdownView: View {
    let text: String
    var font: Font = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .paragraph(text):
            Text(Self.inline(text)).font(font).textSelection(.enabled)
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .textSelection(.enabled)
                .padding(.top, 4)
        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(.systemGray4)).frame(width: 3)
                Text(Self.inline(text)).font(font).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case let .code(code), let .table(code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .rule:
            Divider()
        }
    }

    enum Block: Equatable {
        case paragraph(String)
        case heading(Int, String)
        case quote(String)
        case code(String)
        case table(String)
        case rule
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var lines = text.components(separatedBy: "\n")[...]

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                var code: [String] = []
                while let next = lines.popFirst(), !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(next)
                }
                blocks.append(.code(code.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flush()
            } else if let level = heading(trimmed) {
                flush()
                blocks.append(.heading(level, String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("|") {
                flush()
                var rows = [trimmed]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(next.trimmingCharacters(in: .whitespaces))
                    lines.removeFirst()
                }
                blocks.append(.table(table(rows)))
            } else if trimmed.hasPrefix(">") {
                flush()
                var quote = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(next.trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    lines.removeFirst()
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
            } else {
                paragraph.append(bullet(line))
            }
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    /// "- item" and "* item" as "• item", keeping the indent of a nested item.
    private static func bullet(_ line: String) -> String {
        let indent = line.prefix(while: { $0 == " " })
        let rest = line.dropFirst(indent.count)
        if rest.hasPrefix("- [ ] ") { return indent + "☐ " + rest.dropFirst(6) }
        if rest.hasPrefix("- [x] ") || rest.hasPrefix("- [X] ") { return indent + "☑ " + rest.dropFirst(6) }
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") { return indent + "• " + rest.dropFirst(2) }
        return line
    }

    /// A GFM table as aligned columns, its delimiter row left out.
    private static func table(_ rows: [String]) -> String {
        let cells = rows.compactMap { row -> [String]? in
            var parts = row.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.first == "" { parts.removeFirst() }
            if parts.last == "" { parts.removeLast() }
            if parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { return nil }
            return parts
        }
        let columns = cells.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in cells.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0 }
        return cells.map { row in
            (0..<columns).map { column in
                let cell = column < row.count ? row[column] : ""
                return cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var parsed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        // Code in a sentence: monospaced a size smaller, so it sits in the line as the Mac draws it.
        for run in parsed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            parsed[run.range].font = .system(.callout, design: .monospaced)
        }
        return parsed
    }
}
