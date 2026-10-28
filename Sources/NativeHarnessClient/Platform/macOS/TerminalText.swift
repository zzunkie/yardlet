import SwiftTerm

extension Terminal {
    /// The terminal's text from the top of its scrollback, one line per line the program wrote: a
    /// row the terminal wrapped is joined to the line it continues. `getBufferAsData()` ends every
    /// row with a line break, so a line wider than the terminal (a sign-in link, or a long prompt and
    /// the command typed after it) would read as two.
    var unwrappedText: String {
        var text = ""
        var row = buffer.totalLinesTrimmed
        while let line = getScrollInvariantLine(row: row) {
            let continues = getScrollInvariantLine(row: row + 1)?.isWrapped == true
            text += line.translateToString(trimRight: !continues, skipNullCellsFollowingWide: true)
            if !continues { text += "\n" }
            row += 1
        }
        return text
    }
}
