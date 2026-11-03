import Foundation
import XCTest
import SwiftTerm

/// Characterizes repainting through the pinned dependency's public API, without modifying its parser.
final class TerminalReattachFeasibilityTests: XCTestCase {
    func testPublicCellsCanRepaintTheCurrentNormalAndAlternateScreens() {
        for alternate in [false, true] {
            let source = ProbeTerminal()
            if alternate { source.terminal.feed(text: "\u{1b}[?1049h") }
            source.terminal.feed(text: "\u{1b}[38;2;12;34;56;48;2;65;43;21;1;3m한글 👩🏽‍💻 é\r\n")
            source.terminal.feed(text: "\u{1b}[0m\u{1b}[4:3munderlined\u{1b}[0m\u{1b}[3;7Hcursor")
            source.terminal.feed(text: "\u{1b}[?1h\u{1b}[?2004h\u{1b}[=3u")
            let target = ProbeTerminal()
            target.terminal.feed(text: redraw(source.terminal))
            assertPicture(source.terminal, target.terminal)
            XCTAssertEqual(source.terminal.getCursorLocation().x, target.terminal.getCursorLocation().x)
            XCTAssertEqual(source.terminal.getCursorLocation().y, target.terminal.getCursorLocation().y)
            XCTAssertEqual(source.terminal.isCurrentBufferAlternate, target.terminal.isCurrentBufferAlternate)
            XCTAssertEqual(source.terminal.applicationCursor, target.terminal.applicationCursor)
            XCTAssertEqual(source.terminal.bracketedPasteMode, target.terminal.bracketedPasteMode)
            XCTAssertEqual(source.terminal.keyboardEnhancementFlags, target.terminal.keyboardEnhancementFlags)
        }
    }

    func testARepaintDoesNotTransferInputModesOrAnIncompleteControlSequence() {
        let source = ProbeTerminal()
        source.terminal.feed(text: "\u{1b}[?1006h\u{1b}[?1004hhello\u{1b}[38;2;12;")
        let target = ProbeTerminal()
        target.terminal.feed(text: redraw(source.terminal))
        // The renderer can draw the current picture, but the next bytes belong to a private parser state.
        source.terminal.feed(text: "34;56mX")
        target.terminal.feed(text: "34;56mX")
        XCTAssertNotEqual(source.terminal.getBufferAsData(), target.terminal.getBufferAsData())
        source.sent.removeAll()
        target.sent.removeAll()
        source.terminal.setTerminalFocus(false)
        target.terminal.setTerminalFocus(false)
        XCTAssertEqual(source.sent, Array("\u{1b}[O".utf8))
        XCTAssertTrue(target.sent.isEmpty, "The public screen state does not include focus reporting")
    }

    func testQueryingPrivateModesThroughFeedWouldChangeAnIncompleteHostSequence() {
        let uninterrupted = ProbeTerminal()
        let queried = ProbeTerminal()
        for probe in [uninterrupted, queried] { probe.terminal.feed(text: "\u{1b}[38;2;12;") }
        queried.terminal.feed(text: "\u{1b}[?1006$p")
        XCTAssertFalse(queried.sent.isEmpty, "The public parser can answer a mode query")
        for probe in [uninterrupted, queried] { probe.terminal.feed(text: "34;56mX") }
        XCTAssertNotEqual(uninterrupted.terminal.getBufferAsData(), queried.terminal.getBufferAsData(),
                          "A query must not be injected into the host's live parser during attach")
    }

    private func assertPicture(_ source: Terminal, _ target: Terminal, file: StaticString = #filePath, line: UInt = #line) {
        for row in 0..<source.rows {
            for column in 0..<source.cols {
                guard let a = source.getCharData(col: column, row: row), let b = target.getCharData(col: column, row: row) else {
                    return XCTFail("Missing cell", file: file, line: line)
                }
                let ac = source.getCharacter(for: a), bc = target.getCharacter(for: b)
                XCTAssertEqual(ac == "\0" ? " " : ac, bc == "\0" ? " " : bc, "Cell \(column),\(row)", file: file, line: line)
                if ac != "\0" && ac != " " {
                    XCTAssertEqual(a.attribute, b.attribute, "Attributes \(column),\(row)", file: file, line: line)
                }
            }
        }
    }

    private func redraw(_ source: Terminal) -> String {
        var result = "\u{1b}c"
        if source.isCurrentBufferAlternate { result += "\u{1b}[?1049h" }
        result += "\u{1b}[?7l"
        for row in 0..<source.rows {
            result += "\u{1b}[\(row + 1);1H"
            for column in 0..<source.cols {
                guard let cell = source.getCharData(col: column, row: row), cell.width != 0 else { continue }
                result += sgr(cell.attribute)
                let character = source.getCharacter(for: cell)
                result += character == "\0" ? " " : String(character)
            }
        }
        let cursor = source.getCursorLocation()
        result += "\u{1b}[?7h\u{1b}[\(cursor.y + 1);\(min(cursor.x, source.cols - 1) + 1)H"
        result += sgr(source.currentAttribute)
        result += "\u{1b}[?1\(source.applicationCursor ? "h" : "l")"
        result += "\u{1b}[?2004\(source.bracketedPasteMode ? "h" : "l")"
        result += "\u{1b}[=\(source.keyboardEnhancementFlags.rawValue)u"
        return result
    }

    private func sgr(_ attribute: Attribute) -> String {
        var values = ["0"]
        for (style, code): (CharacterStyle, String) in [(.bold,"1"),(.dim,"2"),(.italic,"3"),(.blink,"5"),(.inverse,"7"),(.invisible,"8"),(.crossedOut,"9")] {
            if attribute.style.contains(style) { values.append(code) }
        }
        if attribute.underlineStyle != .none { values.append("4:\(attribute.underlineStyle.rawValue)") }
        else if attribute.style.contains(.underline) { values.append("4") }
        func color(_ color: Attribute.Color, foreground: Bool) -> String {
            switch color {
            case let .ansi256(code): "\(foreground ? 38 : 48);5;\(code)"
            case let .trueColor(red, green, blue): "\(foreground ? 38 : 48);2;\(red);\(green);\(blue)"
            case .defaultColor, .defaultInvertedColor: foreground ? "39" : "49"
            }
        }
        values.append(color(attribute.fg, foreground: true))
        values.append(color(attribute.bg, foreground: false))
        return "\u{1b}[" + values.joined(separator: ";") + "m"
    }
}

private final class ProbeTerminal: TerminalDelegate {
    var sent: [UInt8] = []
    lazy var terminal: Terminal = {
        let terminal = Terminal(delegate: self)
        terminal.resize(cols: 30, rows: 6)
        return terminal
    }()
    func send(source: Terminal, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
}
