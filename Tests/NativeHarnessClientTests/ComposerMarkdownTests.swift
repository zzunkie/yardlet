import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The composer's Markdown as it is typed: the list keys' edits (`ComposerMarkdown`), what is drawn
/// differently (`ComposerMarkdownSpans`, `ComposerMarkdownStyler`), and the text view's promise to leave
/// an input method's composition alone. The draft always holds the plain Markdown typed.
@MainActor
final class ComposerMarkdownTests: XCTestCase {
    /// `text` with `|` as the caret, or `[` and `]` around a selection.
    private func marked(_ text: String) -> (String, NSRange) {
        var plain = text
        if let caret = plain.range(of: "|") {
            let location = plain.utf16.distance(from: plain.startIndex, to: caret.lowerBound)
            plain.removeSubrange(caret)
            return (plain, NSRange(location: location, length: 0))
        }
        let open = plain.range(of: "[")!
        let start = plain.utf16.distance(from: plain.startIndex, to: open.lowerBound)
        plain.removeSubrange(open)
        let close = plain.range(of: "]")!
        let end = plain.utf16.distance(from: plain.startIndex, to: close.lowerBound)
        plain.removeSubrange(close)
        return (plain, NSRange(location: start, length: end - start))
    }

    /// The text and selection after `edit`, marked as `marked` reads them.
    private func result(_ edit: ComposerMarkdown.Edit?, on text: String) -> String? {
        guard let edit else { return nil }
        let changed = edit.applied(to: text) as NSString
        if edit.selection.length == 0 {
            return changed.replacingCharacters(in: edit.selection, with: "|")
        }
        return changed.replacingCharacters(in: NSRange(location: NSMaxRange(edit.selection), length: 0), with: "]")
            .inserting("[", at: edit.selection.location)
    }

    private func newline(_ text: String) -> String? {
        let (plain, selection) = marked(text)
        return result(ComposerMarkdown.newline(in: plain, selection: selection), on: plain)
    }

    private func indent(_ text: String, outdent: Bool = false) -> String? {
        let (plain, selection) = marked(text)
        return result(ComposerMarkdown.indent(in: plain, selection: selection, outdent: outdent), on: plain)
    }

    private func backspace(_ text: String) -> String? {
        let (plain, selection) = marked(text)
        return result(ComposerMarkdown.deleteBackward(in: plain, selection: selection), on: plain)
    }

    private func toggle(_ mark: ComposerMarkdown.InlineMark, _ text: String) -> String? {
        let (plain, selection) = marked(text)
        return result(ComposerMarkdown.toggle(mark, in: plain, selection: selection), on: plain)
    }

    func testALineBreakCarriesAListOnAndAnEmptyItemEndsIt() {
        XCTAssertEqual(newline("- 장보기|"), "- 장보기\n- |")
        XCTAssertEqual(newline("* one|"), "* one\n* |")
        XCTAssertEqual(newline("  - nested|"), "  - nested\n  - |", "The depth stays")
        XCTAssertEqual(newline("1. first|"), "1. first\n2. |", "The number counts on")
        XCTAssertEqual(newline("9) ninth|"), "9) ninth\n10) |")
        XCTAssertEqual(newline("- split| here"), "- split\n- | here", "The rest of the line moves to the new item")
        XCTAssertEqual(newline("1. a|\n2. b\n   - note\n3. c\n\nAfter"), "1. a\n2. |\n3. b\n   - note\n4. c\n\nAfter",
                       "The items after it are renumbered, nested lines and what follows the list kept")
        XCTAssertEqual(newline("> quoted|"), "> quoted\n> |")
        XCTAssertEqual(newline("- |"), "|", "An empty item ends the list")
        XCTAssertEqual(newline("Intro\n2. |"), "Intro\n|")
        XCTAssertEqual(newline("  - |"), "- |", "A nested empty item steps out a level first")
        XCTAssertNil(newline("Plain text|"))
        XCTAssertNil(newline("-|"), "A dash alone is not a list yet")
        XCTAssertNil(newline("|- item"), "The caret before the marker breaks the line as usual")
        XCTAssertNil(newline("- - -|"), "A rule is not a list")
    }

    func testTabAndShiftTabMoveListLinesAndSelectedLinesALevel() {
        XCTAssertEqual(indent("- item|"), "  - item|")
        XCTAssertEqual(indent("1. |"), "  1. |")
        XCTAssertEqual(indent("  - item|", outdent: true), "- item|")
        XCTAssertEqual(indent("\t- item|", outdent: true), "- item|", "A Tab counts as one level")
        XCTAssertNil(indent("- item|", outdent: true), "Nothing to take away")
        XCTAssertNil(indent("Plain text|"), "Tab keeps its other uses on a line that is not a list")
        XCTAssertEqual(indent("[first\nsecond]"), "  [first\n  second]", "Any selected lines move")
        XCTAssertEqual(indent("[a\n\nb]"), "  [a\n\n  b]", "Blank lines in between stay empty")
        XCTAssertEqual(indent("  [a\n  b]", outdent: true), "[a\nb]")
        XCTAssertEqual(indent("- a\n[- b\n]- c"), "- a\n  [- b\n]- c", "A line the selection ends at the start of stays")
    }

    func testBackspaceRightAfterAMarkerStepsOutOrTakesTheMarker() {
        XCTAssertEqual(backspace("- |item"), "|item", "The marker goes and the text stays")
        XCTAssertEqual(backspace("12. |"), "|")
        XCTAssertEqual(backspace("  - |item"), "- |item", "A nested item steps out a level")
        XCTAssertEqual(backspace("> |quote"), "|quote")
        XCTAssertNil(backspace("- it|em"), "Inside the text Backspace deletes a character")
        XCTAssertNil(backspace("-| item"))
        XCTAssertNil(backspace("- [it]em"), "A selection is deleted as usual")
    }

    func testTheFormatKeysPutMarksAroundTheSelectionAndTakeThemAway() {
        XCTAssertEqual(toggle(.bold, "make [this] bold"), "make **[this]** bold")
        XCTAssertEqual(toggle(.bold, "make **[this]** bold"), "make [this] bold", "Marks around the selection go")
        XCTAssertEqual(toggle(.bold, "make [**this**] bold"), "make [this] bold", "Marks inside its edges go too")
        XCTAssertEqual(toggle(.italic, "[word]"), "*[word]*")
        XCTAssertEqual(toggle(.italic, "*[word]*"), "[word]")
        XCTAssertEqual(toggle(.italic, "**[word]**"), "***[word]***", "Bold's marks are not italic's")
        XCTAssertEqual(toggle(.code, "run [swift build]"), "run `[swift build]`")
        XCTAssertEqual(toggle(.code, "run `[swift build]`"), "run [swift build]")
        XCTAssertEqual(toggle(.bold, "type |"), "type **|**", "With no selection the caret goes between the marks")
    }

    func testTheSpansDimTheMarksAndKnowListsQuotesAndCodeBlocks() {
        let text = "**굵게** and *slanted* with `code`\n  - item\n> quote\n# Title\n```\n**not bold**\n```\nafter"
            as NSString
        let spans = ComposerMarkdownSpans(text: text, range: NSRange(location: 0, length: text.length))
        func kinds(of word: String) -> [ComposerMarkdownSpans.Kind] {
            let range = text.range(of: word)
            return spans.runs.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.kind)
        }
        XCTAssertEqual(kinds(of: "굵게"), [.strong])
        XCTAssertEqual(kinds(of: "slanted"), [.emphasis])
        XCTAssertEqual(kinds(of: "code`"), [.code, .syntax])
        XCTAssertEqual(spans.runs.filter { $0.kind == .syntax && text.substring(with: $0.range) == "**" }.count, 2)
        XCTAssertEqual(kinds(of: "-"), [.listMarker])
        XCTAssertEqual(kinds(of: "quote"), [.quote])
        XCTAssertEqual(kinds(of: "Title"), [.heading])
        XCTAssertEqual(kinds(of: "not bold"), [.codeBlock], "Nothing inside a fenced block is styled as Markdown")
        XCTAssertEqual(kinds(of: "after"), [])

        let item = spans.lines.first { text.substring(with: $0.range) == "  - item" }
        XCTAssertEqual(item?.hangingPrefix, NSRange(location: text.range(of: "  - item").location, length: 4))
        XCTAssertEqual(item?.indent?.length, 2)

        // A range inside the block still knows it is code: fences are read from the start.
        let inner = text.range(of: "**not bold**")
        let partial = ComposerMarkdownSpans(text: text, range: inner)
        XCTAssertEqual(partial.runs.map(\.kind), [.codeBlock])
    }

    /// The text view hangs a list item's wrapped lines under its text, draws bold and code in their
    /// faces, and keeps the draft the plain Markdown typed. While an input method composes, neither the
    /// text's styles nor the draft change; the commit brings both.
    func testTheFieldStylesWhatIsTypedButNeverAComposition() throws {
        var draft = ""
        let controller = ComposerTextController()
        controller.text = Binding(get: { draft }, set: { draft = $0 })
        controller.apply(style: ComposerTextStyle(scale: 1))
        let scroll = ComposerTextScrollView(controller: controller)
        scroll.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let textView = controller.textView
        let storage = try XCTUnwrap(textView.textStorage)

        textView.insertText("1. **굵게** 그리고 `code` 를 쓰는 아주 긴 첫 번째 항목은 다음 줄로 넘어갑니다",
                            replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(draft, textView.string, "The draft holds what was typed, marks and all")
        let paragraph = try XCTUnwrap(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let prefix = storage.attributedSubstring(from: NSRange(location: 0, length: 3)).size().width
        XCTAssertEqual(paragraph.headIndent, prefix, accuracy: 0.5, "Wrapped lines start under the item's text")
        let bold = try XCTUnwrap(storage.attribute(.font, at: (textView.string as NSString).range(of: "굵게").location,
                                                   effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(bold.fontDescriptor.weight, NSFont.Weight.regular.rawValue)
        let code = (textView.string as NSString).range(of: "code").location
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: code, effectiveRange: nil))

        // A composition is the input method's: nothing restyled, nothing in the draft.
        let typed = draft
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.setMarkedText("**ㅎ", selectedRange: NSRange(location: 3, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        let composing = storage.attributes(at: end + 2, effectiveRange: nil)
        textView.setMarkedText("**하", selectedRange: NSRange(location: 3, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(draft, typed, "The draft waits for the commit")
        XCTAssertEqual(storage.attributes(at: end + 2, effectiveRange: nil)[.underlineStyle] as? Int,
                       composing[.underlineStyle] as? Int, "The composition keeps the input method's marking")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: end + 3, length: 0), "The caret stays in the composition")
        textView.insertText("**하**", replacementRange: textView.markedRange())
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(draft, typed + "**하**", "The commit reaches the draft once")
        let committed = try XCTUnwrap(storage.attribute(.font, at: end + 2, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(committed.fontDescriptor.weight, NSFont.Weight.regular.rawValue, "And is styled then")

        // The draft set from outside (a sent message, a chosen command) replaces the text and its undo.
        controller.replaceText(with: "")
        XCTAssertEqual(textView.string, "")
        XCTAssertFalse(textView.undoManager?.canUndo ?? true)
    }

    /// Bash mode's text is a shell command: no Markdown look and no list keys.
    func testBashModeIsPlainText() throws {
        var draft = ""
        let controller = ComposerTextController()
        controller.text = Binding(get: { draft }, set: { draft = $0 })
        controller.apply(style: ComposerTextStyle(isBashMode: true))
        let textView = controller.textView
        textView.insertText("- **ls**", replacementRange: NSRange(location: 0, length: 0))
        let storage = try XCTUnwrap(textView.textStorage)
        let font = try XCTUnwrap(storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.isFixedPitch)
        XCTAssertEqual(font.fontDescriptor.weight, NSFont.Weight.regular.rawValue, accuracy: 0.01)
        XCTAssertFalse(textView.indentMarkdown(outdent: false))
        textView.insertNewline(nil)
        XCTAssertEqual(draft, "- **ls**\n", "Return adds a plain line")
    }
}

private extension String {
    func inserting(_ text: String, at location: Int) -> String {
        (self as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: text)
    }
}

private extension NSFontDescriptor {
    var weight: CGFloat {
        let traits = object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return traits?[.weight] as? CGFloat ?? 0
    }
}
