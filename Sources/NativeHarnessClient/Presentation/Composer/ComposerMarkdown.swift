import Foundation

/// The Markdown a composer reads as the person types, for its look and its list keys. The draft stays
/// plain Markdown text; this only reads it. Ranges are UTF-16, as `NSString` and `NSTextView` count.
enum ComposerMarkdown {
    /// The spaces a Tab adds before a list line, and Shift-Tab takes away.
    static let indentUnit = "  "

    /// One line's list or quote prefix: its leading spaces, its marker and the space after it.
    struct LinePrefix: Equatable {
        enum Marker: Equatable {
            /// `-`, `*` or `+`.
            case bullet(Character)
            /// `1.` or `1)`.
            case ordered(Int, delimiter: Character)
            /// `>`.
            case quote
        }

        /// The leading spaces (a Tab counts as `indentUnit`).
        var indent: Int
        var marker: Marker
        /// From the line's start to the end of the space after the marker.
        var length: Int
        /// The line holds nothing after its prefix.
        var isEmpty: Bool

        var isList: Bool {
            if case .quote = marker { return false }
            return true
        }

        /// The prefix the next line of the same list starts with: the next number for an ordered list.
        var continued: String {
            let spaces = String(repeating: " ", count: indent)
            switch marker {
            case let .bullet(character): return spaces + String(character) + " "
            case let .ordered(number, delimiter): return spaces + "\(number + 1)\(delimiter) "
            case .quote: return spaces + "> "
            }
        }
    }

    /// The prefix of `line`, which excludes its line break, when it starts a list item or a quote.
    static func prefix(of line: Substring) -> LinePrefix? {
        var indent = 0, offset = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            indent += line[index] == "\t" ? indentUnit.count : 1
            offset += 1
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }
        let marker: LinePrefix.Marker
        let character = line[index]
        if character == "-" || character == "*" || character == "+" {
            marker = .bullet(character)
            index = line.index(after: index)
            offset += 1
        } else if character == ">" {
            marker = .quote
            index = line.index(after: index)
            offset += 1
        } else if character.isASCII, character.isNumber {
            var digits = ""
            while index < line.endIndex, line[index].isASCII, line[index].isNumber, digits.count < 9 {
                digits.append(line[index])
                index = line.index(after: index)
            }
            guard index < line.endIndex, line[index] == "." || line[index] == ")", let number = Int(digits) else {
                return nil
            }
            marker = .ordered(number, delimiter: line[index])
            offset += digits.count + 1
            index = line.index(after: index)
        } else {
            return nil
        }
        if index == line.endIndex {
            // A quote may end at its marker; a list marker needs its space ("-" alone is not a list yet).
            guard case .quote = marker else { return nil }
            return LinePrefix(indent: indent, marker: marker, length: offset, isEmpty: true)
        }
        guard line[index] == " " || line[index] == "\t" else { return nil }
        offset += 1
        index = line.index(after: index)
        let rest = line[index...]
        // A rule ("- - -", "* * *") is not a list.
        if case .bullet = marker, rest.allSatisfy({ $0 == character || $0 == " " }), rest.contains(character) {
            return nil
        }
        return LinePrefix(indent: indent, marker: marker, length: offset,
                          isEmpty: rest.allSatisfy { $0 == " " || $0 == "\t" })
    }

    /// A change to the text: `range` (in the text before it) becomes `replacement`, and `selection` is the
    /// selection after it, in the changed text.
    struct Edit: Equatable {
        var range: NSRange
        var replacement: String
        var selection: NSRange

        /// `text` with this edit applied.
        func applied(to text: String) -> String {
            (text as NSString).replacingCharacters(in: range, with: replacement)
        }
    }

    // MARK: - Return

    /// A line break at the selection that carries the list on: on a list item that holds something, the
    /// next item at the same depth (an ordered list renumbers the items after it); on an empty item, the
    /// list ends and its marker goes. Nil where a plain line break does.
    static func newline(in text: String, selection: NSRange) -> Edit? {
        let string = text as NSString
        guard NSMaxRange(selection) <= string.length else { return nil }
        let line = string.lineRange(for: NSRange(location: selection.location, length: 0))
        let content = lineContent(line, in: string)
        guard NSMaxRange(selection) <= NSMaxRange(content),
              let prefix = prefix(of: Substring(string.substring(with: content))),
              selection.location >= content.location + prefix.length else { return nil }
        if prefix.isEmpty {
            // An empty item ends the list: the line keeps no marker. A nested one steps out a level first.
            if prefix.indent > 0, prefix.isList {
                return outdent(lines: [content], in: string, selection: selection)
            }
            return Edit(range: NSRange(location: content.location, length: content.length), replacement: "",
                        selection: NSRange(location: content.location, length: 0))
        }
        var insertion = "\n" + prefix.continued
        var range = selection
        // The rest of the line moves to the new item, and the items after it count on.
        if case let .ordered(number, delimiter) = prefix.marker {
            let following = renumbered(after: line, in: string, indent: prefix.indent, from: number + 2,
                                       delimiter: delimiter)
            if let following {
                insertion += string.substring(with: NSRange(location: NSMaxRange(selection),
                                                            length: following.range.location - NSMaxRange(selection)))
                insertion += following.text
                range = NSRange(location: selection.location, length: NSMaxRange(following.range) - selection.location)
            }
        }
        let caret = selection.location + 1 + (prefix.continued as NSString).length
        return Edit(range: range, replacement: insertion, selection: NSRange(location: caret, length: 0))
    }

    /// The ordered items after `line` in the same list at `indent`, numbered from `start`: the range
    /// from the next line to the last item's end and its renumbered text. Nil when none needs a new number.
    private static func renumbered(after line: NSRange, in string: NSString, indent: Int, from start: Int,
                                   delimiter: Character) -> (range: NSRange, text: String)? {
        var location = NSMaxRange(line)
        var number = start
        var text = ""
        var end = location
        var changed = false
        while location < string.length {
            let next = string.lineRange(for: NSRange(location: location, length: 0))
            let content = lineContent(next, in: string)
            let lineText = string.substring(with: next)
            guard let prefix = prefix(of: Substring(string.substring(with: content))) else { break }
            if prefix.indent > indent {
                // A nested item belongs to the item above it.
                text += lineText
            } else if prefix.indent == indent, case let .ordered(old, mark) = prefix.marker, mark == delimiter {
                let spaces = String(repeating: " ", count: indent)
                let rest = (lineText as NSString).substring(from: prefix.length)
                text += spaces + "\(number)\(delimiter) " + rest
                changed = changed || old != number
                number += 1
            } else {
                break
            }
            end = NSMaxRange(next)
            location = end
        }
        guard changed else { return nil }
        return (NSRange(location: NSMaxRange(line), length: end - NSMaxRange(line)), text)
    }

    // MARK: - Tab and Shift-Tab

    /// Tab on a list line, or with a selection over more than one line: each line moves in a level.
    /// Shift-Tab moves them out. Nil where Tab keeps its other uses (a single line that is not a list).
    static func indent(in text: String, selection: NSRange, outdent: Bool) -> Edit? {
        let string = text as NSString
        guard NSMaxRange(selection) <= string.length else { return nil }
        let lines = selectedLines(selection, in: string)
        if lines.count == 1 {
            guard let prefix = prefix(of: Substring(string.substring(with: lines[0]))), prefix.isList else {
                return nil
            }
        }
        return outdent ? self.outdent(lines: lines, in: string, selection: selection)
            : self.indent(lines: lines, in: string, selection: selection)
    }

    private static func indent(lines: [NSRange], in string: NSString, selection: NSRange) -> Edit? {
        let unit = (indentUnit as NSString).length
        let first = lines[0].location
        let range = NSRange(location: first, length: NSMaxRange(lines[lines.count - 1]) - first)
        var text = ""
        var start = selection.location, end = NSMaxRange(selection)
        for (index, line) in lines.enumerated() {
            if index > 0 { text += string.substring(with: NSRange(location: NSMaxRange(lines[index - 1]),
                                                                  length: line.location - NSMaxRange(lines[index - 1]))) }
            let content = string.substring(with: line)
            // Blank lines in a selection stay empty.
            if lines.count > 1, content.allSatisfy({ $0 == " " || $0 == "\t" }) {
                text += content
                continue
            }
            text += indentUnit + content
            if line.location <= selection.location { start += unit }
            if line.location <= NSMaxRange(selection) { end += unit }
        }
        if selection.length == 0 { end = start }
        return Edit(range: range, replacement: text, selection: NSRange(location: start, length: end - start))
    }

    private static func outdent(lines: [NSRange], in string: NSString, selection: NSRange) -> Edit? {
        let first = lines[0].location
        let range = NSRange(location: first, length: NSMaxRange(lines[lines.count - 1]) - first)
        var text = ""
        var changed = false
        for (index, line) in lines.enumerated() {
            if index > 0 { text += string.substring(with: NSRange(location: NSMaxRange(lines[index - 1]),
                                                                  length: line.location - NSMaxRange(lines[index - 1]))) }
            let content = string.substring(with: line) as NSString
            let removed = outdentWidth(of: content)
            changed = changed || removed > 0
            text += content.substring(from: removed)
        }
        guard changed else { return nil }
        let start = shifted(selection.location, lines: lines, in: string)
        let end = selection.length == 0 ? start : shifted(NSMaxRange(selection), lines: lines, in: string)
        return Edit(range: range, replacement: text, selection: NSRange(location: start, length: end - start))
    }

    /// The leading spaces one level out takes from a line: up to `indentUnit`, or one Tab.
    private static func outdentWidth(of content: NSString) -> Int {
        var removed = 0
        while removed < (indentUnit as NSString).length, removed < content.length {
            let character = content.character(at: removed)
            if character == 0x20 { removed += 1 } else if character == 0x09 { return removed + 1 } else { break }
        }
        return removed
    }

    /// Where `location` lands once each of `lines` moves out a level. An edge inside the removed spaces
    /// moves to the line's new start.
    private static func shifted(_ location: Int, lines: [NSRange], in string: NSString) -> Int {
        var result = location
        for line in lines where line.location < location {
            let removed = outdentWidth(of: string.substring(with: line) as NSString)
            result -= min(removed, location - line.location)
        }
        return result
    }

    // MARK: - Backspace

    /// Backspace right after a list marker: a nested item moves out a level, a top-level one loses its
    /// marker and keeps its text. Nil where Backspace deletes a character as usual.
    static func deleteBackward(in text: String, selection: NSRange) -> Edit? {
        guard selection.length == 0 else { return nil }
        let string = text as NSString
        guard selection.location <= string.length else { return nil }
        let line = string.lineRange(for: NSRange(location: selection.location, length: 0))
        let content = lineContent(line, in: string)
        guard let prefix = prefix(of: Substring(string.substring(with: content))),
              selection.location == content.location + prefix.length else { return nil }
        if prefix.indent > 0, prefix.isList {
            return outdent(lines: [content], in: string, selection: selection)
        }
        let spaces = (string.substring(with: content) as NSString).substring(to: prefix.length)
            .prefix { $0 == " " || $0 == "\t" }
        let removed = NSRange(location: content.location + (String(spaces) as NSString).length,
                              length: prefix.length - (String(spaces) as NSString).length)
        return Edit(range: removed, replacement: "", selection: NSRange(location: removed.location, length: 0))
    }

    // MARK: - ⌘B, ⌘I, ⌘E

    /// The inline marks the format keys put around a selection.
    enum InlineMark: String, CaseIterable {
        case bold = "**"
        case italic = "*"
        case code = "`"
    }

    /// Puts `mark` around the selection, or takes it away when the selection already has it around or
    /// inside its edges. With no selection, the marks go in with the caret between them.
    static func toggle(_ mark: InlineMark, in text: String, selection: NSRange) -> Edit {
        let string = text as NSString
        let marker = mark.rawValue
        let width = (marker as NSString).length
        let selected = string.substring(with: selection)
        // The marks are inside the selection: `**word**` selected.
        if selection.length >= 2 * width, selected.hasPrefix(marker), selected.hasSuffix(marker),
           isExactly(mark, inner: (selected as NSString).substring(with: NSRange(location: width,
                                                                                  length: selection.length - 2 * width))) {
            let inner = (selected as NSString).substring(with: NSRange(location: width, length: selection.length - 2 * width))
            return Edit(range: selection, replacement: inner,
                        selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }
        // The marks are just outside it: `word` selected in `**word**`.
        let before = NSRange(location: selection.location - width, length: width)
        let after = NSRange(location: NSMaxRange(selection), length: width)
        if before.location >= 0, NSMaxRange(after) <= string.length,
           string.substring(with: before) == marker, string.substring(with: after) == marker,
           !extendsMark(mark, before: before, after: after, in: string) {
            return Edit(range: NSRange(location: before.location, length: NSMaxRange(after) - before.location),
                        replacement: selected, selection: NSRange(location: before.location, length: selection.length))
        }
        return Edit(range: selection, replacement: marker + selected + marker,
                    selection: NSRange(location: selection.location + width, length: selection.length))
    }

    /// A single `*` next to another `*` is part of a bold mark, not an italic one.
    private static func extendsMark(_ mark: InlineMark, before: NSRange, after: NSRange, in string: NSString) -> Bool {
        guard mark == .italic else { return false }
        let left = before.location > 0 && string.character(at: before.location - 1) == 0x2A
        let right = NSMaxRange(after) < string.length && string.character(at: NSMaxRange(after)) == 0x2A
        return left || right
    }

    private static func isExactly(_ mark: InlineMark, inner: String) -> Bool {
        guard mark == .italic else { return true }
        // `**word**` selected is bold, not italic around `*word*`.
        return !(inner.hasPrefix("*") && inner.hasSuffix("*"))
    }

    // MARK: - Lines

    /// A line's range without its line break.
    static func lineContent(_ line: NSRange, in string: NSString) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location {
            let character = string.character(at: end - 1)
            guard character == 0x0A || character == 0x0D else { break }
            end -= 1
        }
        return NSRange(location: line.location, length: end - line.location)
    }

    /// The lines a selection touches, without their line breaks. A selection that ends at the start of
    /// a line does not take that line.
    static func selectedLines(_ selection: NSRange, in string: NSString) -> [NSRange] {
        var lines: [NSRange] = []
        var location = selection.location
        let end = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        repeat {
            let line = string.lineRange(for: NSRange(location: min(location, string.length), length: 0))
            lines.append(lineContent(line, in: string))
            location = NSMaxRange(line)
        } while location <= end && location < string.length
        return lines
    }
}
