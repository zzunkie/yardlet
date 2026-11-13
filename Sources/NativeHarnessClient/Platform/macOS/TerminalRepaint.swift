import Foundation
@preconcurrency import SwiftTerm

/// What draws a shell's screen again on a renderer that attaches to it while it runs (docs/REMOTE_PROTOCOL.md §15.29,
/// "Kept terminals"): the host emulator's screen (the alternate one when it shows), each cell's character and pen, the
/// scroll region, the cursor and its visibility, and the input modes a renderer encodes keys with (application cursor
/// keys, bracketed paste, keyboard enhancement flags). It first leaves the renderer's alternate screen, resets its modes
/// and clears its screen, so a renderer that showed the shell before keeps its scrollback and loses only its stale screen.
///
/// Built from the emulator's public cells, not from its parser, so a sequence the shell was in the middle of printing is
/// not carried over, and neither are mouse reporting and focus reporting, whose encoding the emulator keeps private:
/// a program that asked for them gets ordinary keys until it asks again. The host emulator stays the only one that
/// answers terminal queries.
enum TerminalRepaint {
    static func bytes(of terminal: Terminal, cursorHidden: Bool) -> Data {
        var out = "\u{1b}[?1049l\u{1b}[!p\u{1b}[?2004l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?1004l\u{1b}[=0u"
        if terminal.isCurrentBufferAlternate { out += "\u{1b}[?1049h" }
        out += "\u{1b}[H\u{1b}[2J"
        let firstRow = screenTop(of: terminal)
        // nil: the plain pen the reset left.
        var pen: Attribute?
        for row in 0..<terminal.rows {
            guard let line = terminal.getScrollInvariantLine(row: firstRow + row) else { continue }
            let cells = min(line.count, terminal.cols)
            guard let last = (0..<cells).last(where: { drawn(line[$0], in: terminal) }) else { continue }
            out += "\u{1b}[\(row + 1);1H"
            var column = 0
            while column <= last {
                let cell = line[column]
                // The second column of a wide character belongs to the one before it.
                guard cell.width > 0 else { column += 1; continue }
                if pen.map({ $0 != cell.attribute }) ?? !isPlain(cell.attribute) {
                    out += sgr(cell.attribute)
                    pen = cell.attribute
                }
                let character = terminal.getCharacter(for: cell)
                out += character == "\0" ? " " : String(character)
                column += Int(cell.width)
            }
        }
        let buffer = terminal.buffer
        if buffer.scrollTop != 0 || buffer.scrollBottom != terminal.rows - 1 {
            out += "\u{1b}[\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r"
        }
        let cursor = terminal.getCursorLocation()
        out += "\u{1b}[\(cursor.y + 1);\(min(cursor.x, terminal.cols - 1) + 1)H"
        out += sgr(terminal.currentAttribute)
        if terminal.applicationCursor { out += "\u{1b}[?1h" }
        if terminal.bracketedPasteMode { out += "\u{1b}[?2004h" }
        if !terminal.keyboardEnhancementFlags.isEmpty { out += "\u{1b}[=\(terminal.keyboardEnhancementFlags.rawValue)u" }
        if cursorHidden { out += "\u{1b}[?25l" }
        return Data(out.utf8)
    }

    /// The buffer row the shell's screen starts at. A view scrolled back shows earlier rows (`getLine` reads those), so
    /// the screen is found as the buffer's last `rows` lines.
    private static func screenTop(of terminal: Terminal) -> Int {
        let top = terminal.buffer.totalLinesTrimmed
        var last = top + terminal.rows - 1
        guard terminal.getScrollInvariantLine(row: last) != nil else { return top }
        var step = terminal.rows
        while terminal.getScrollInvariantLine(row: last + step) != nil { last += step; step *= 2 }
        var beyond = last + step
        while beyond - last > 1 {
            let middle = (last + beyond) / 2
            if terminal.getScrollInvariantLine(row: middle) != nil { last = middle } else { beyond = middle }
        }
        return last - terminal.rows + 1
    }

    /// A cell that differs from what the cleared screen already shows there.
    private static func drawn(_ cell: CharData, in terminal: Terminal) -> Bool {
        guard cell.width == 1, isPlain(cell.attribute) else { return true }
        let character = terminal.getCharacter(for: cell)
        return character != "\0" && character != " "
    }

    private static func isPlain(_ attribute: Attribute) -> Bool {
        attribute.fg == .defaultColor && attribute.bg == .defaultColor && attribute.style.isEmpty
            && attribute.underlineStyle == .none && attribute.underlineColor == nil
    }

    private static func sgr(_ attribute: Attribute) -> String {
        var values = ["0"]
        let styles: [(CharacterStyle, String)] = [(.bold, "1"), (.dim, "2"), (.italic, "3"), (.blink, "5"), (.inverse, "7"),
                                                  (.invisible, "8"), (.crossedOut, "9")]
        for (style, code) in styles where attribute.style.contains(style) { values.append(code) }
        if attribute.underlineStyle != .none {
            values.append("4:\(attribute.underlineStyle.rawValue)")
        } else if attribute.style.contains(.underline) {
            values.append("4")
        }
        if let fg = color(attribute.fg, base: 38) { values.append(fg) }
        if let bg = color(attribute.bg, base: 48) { values.append(bg) }
        if let underline = attribute.underlineColor, let code = color(underline, base: 58) { values.append(code) }
        return "\u{1b}[" + values.joined(separator: ";") + "m"
    }

    private static func color(_ color: Attribute.Color, base: Int) -> String? {
        switch color {
        case let .ansi256(code): "\(base);5;\(code)"
        case let .trueColor(red, green, blue): "\(base);2;\(red);\(green);\(blue)"
        case .defaultColor, .defaultInvertedColor: nil
        }
    }
}
