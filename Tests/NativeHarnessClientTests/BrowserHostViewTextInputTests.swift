import AppKit
import XCTest
@testable import NativeHarnessClient

/// The panel view is the NSTextInputClient for off-screen Chromium. An input method's marked and
/// inserted text must reach the host as composition commands (cefclient's ImeSetComposition,
/// ImeCommitText, ImeFinishComposingText).
@MainActor
final class BrowserHostViewTextInputTests: XCTestCase {
    private var sent: [BrowserHostCommand] = []

    private func makeView() -> BrowserHostView {
        let view = BrowserHostView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.tabID = 7
        view.sendCommand = { [unowned self] in sent.append($0) }
        return view
    }

    private let noRange = NSRange(location: NSNotFound, length: 0)

    func testMarkedTextBecomesCompositionAndInsertCommitsIt() {
        let view = makeView()
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        view.setMarkedText("한글", selectedRange: NSRange(location: 2, length: 0), replacementRange: noRange)
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 2))
        XCTAssertEqual(sent.last, .composition(tab: 7, composition: .set(
            text: "한글",
            underlines: [BrowserCompositionUnderline(range: BrowserTextRange(location: 0, length: 2), isThick: false)],
            selection: BrowserTextRange(location: 2, length: 0),
            replacement: nil
        )))

        view.insertText("한글", replacementRange: noRange)
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(sent.last, .composition(tab: 7, composition: .commit(text: "한글", replacement: nil, relativeCursor: 0)))
        XCTAssertEqual(sent.count, 3)
    }

    /// Korean commits the syllable and passes Return or an arrow on; the page gets that key after the
    /// text, as in Chrome. A key the input method uses (Backspace taking a jamo, Japanese Return
    /// confirming) stays "Process" only.
    func testAKeyTheInputMethodPassesOnReachesThePageAfterItsText() throws {
        let view = makeView()
        func key(_ characters: String, _ keyCode: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode))
        }
        let process = { (event: NSEvent) -> BrowserHostCommand in
            var input = BrowserHostView.keyInput(.rawDown, event)
            input.windowsKeyCode = BrowserKeyCodes.inputMethodProcessKey
            return .key(tab: 7, input: input)
        }

        view.setMarkedText("가", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        sent = []
        let returnKey = try key("\r", 36)
        view.keyDown(returnKey) {
            view.insertText("가", replacementRange: noRange)
            view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        var character = BrowserHostView.keyInput(.character, returnKey)
        character.character = 13
        XCTAssertEqual(sent, [
            process(returnKey),
            .composition(tab: 7, composition: .commit(text: "가", replacement: nil, relativeCursor: 0)),
            .key(tab: 7, input: BrowserHostView.keyInput(.rawDown, returnKey)),
            .key(tab: 7, input: character),
        ], "before, the first Return after Hangul never reached the page")

        view.setMarkedText("나", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        sent = []
        let left = try key("\u{F702}", 123)
        view.keyDown(left) {
            view.insertText("나", replacementRange: noRange)
            view.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        }
        XCTAssertEqual(sent.last, .key(tab: 7, input: BrowserHostView.keyInput(.rawDown, left)))

        view.setMarkedText("각", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        sent = []
        let backspace = try key("\u{7F}", 51)
        view.keyDown(backspace) { view.setMarkedText("가", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange) }
        XCTAssertEqual(sent.first, process(backspace))
        XCTAssertEqual(sent.count, 2, "Process and the composition only")
        view.keyDown(returnKey) { view.insertText("가", replacementRange: noRange) }
        XCTAssertEqual(sent.dropFirst(2).map { $0 }, [
            process(returnKey), .composition(tab: 7, composition: .commit(text: "가", replacement: nil, relativeCursor: 0)),
        ], "a Return the input method used to confirm")
    }

    func testUnmarkFinishesAndEmptyMarkedTextCancels() {
        let view = makeView()
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        view.unmarkText()
        XCTAssertEqual(sent.last, .composition(tab: 7, composition: .finish(keepSelection: false)))

        view.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: noRange)
        XCTAssertEqual(sent.last, .composition(tab: 7, composition: .cancel))
        XCTAssertFalse(view.hasMarkedText())

        let count = sent.count
        view.unmarkText()
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: noRange)
        XCTAssertEqual(sent.count, count, "nothing is sent when no composition is open")
    }

    /// A press moves the page's focus while the view stays first responder, so the view finishes the shown
    /// text before the press reaches the page; otherwise the input method carried the word into the next field.
    func testAPressOrTheKeyboardLeavingWhileComposingFinishesTheShownText() throws {
        let view = makeView()
        func press(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        for (type, down) in [(NSEvent.EventType.leftMouseDown, view.mouseDown), (.rightMouseDown, view.rightMouseDown),
                             (.otherMouseDown, view.otherMouseDown)] {
            view.setMarkedText("안녕", selectedRange: NSRange(location: 2, length: 0), replacementRange: noRange)
            sent = []
            down(try press(type))
            XCTAssertEqual(sent.first, .composition(tab: 7, composition: .finish(keepSelection: false)), "\(type)")
            XCTAssertEqual(sent.count, 2, "the finish, then the press (\(type))")
            XCTAssertFalse(view.hasMarkedText())
        }

        sent = []
        view.mouseDown(with: try press(.leftMouseDown))
        XCTAssertEqual(sent.count, 1, "only the press when nothing is composed")

        // The keyboard leaving the page keeps it too: before, the view cancelled it and the word went missing.
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        view.setMarkedText("안녕", selectedRange: NSRange(location: 2, length: 0), replacementRange: noRange)
        sent = []
        window.makeFirstResponder(nil)
        XCTAssertEqual(sent, [.composition(tab: 7, composition: .finish(keepSelection: false)), .focus(tab: 7, isFocused: false)])
        XCTAssertFalse(view.hasMarkedText())
    }

    func testClauseSegmentsBecomeUnderlinesWithTheSelectedClauseThick() {
        let text = NSMutableAttributedString(string: "今日は天気")
        text.addAttribute(.markedClauseSegment, value: 0, range: NSRange(location: 0, length: 3))
        text.addAttribute(.markedClauseSegment, value: 1, range: NSRange(location: 3, length: 2))
        XCTAssertEqual(BrowserHostView.underlines(for: text, selectedRange: NSRange(location: 3, length: 2)), [
            BrowserCompositionUnderline(range: BrowserTextRange(location: 0, length: 3), isThick: false),
            BrowserCompositionUnderline(range: BrowserTextRange(location: 3, length: 2), isThick: true)
        ])
    }

    func testReplacementRangeTravelsWithCommittedText() {
        let view = makeView()
        view.insertText("가", replacementRange: NSRange(location: 4, length: 1))
        XCTAssertEqual(sent.last, .composition(tab: 7, composition: .commit(
            text: "가", replacement: BrowserTextRange(location: 4, length: 1), relativeCursor: 0
        )))
    }

    /// Secure keyboard entry and Roman input sources are on exactly while the page's password field has
    /// the keyboard, and every path out turns them off once (left on, they hold back other apps' input).
    func testSecureInputIsOnExactlyWhileThePasswordFieldHasTheKeyboard() {
        let recorder = BrowserSecureInputRecorder()
        let view = makeView()
        view.secureInput = recorder
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        func expect(_ on: Bool, _ step: String, line: UInt = #line) {
            XCTAssertEqual(view.isInSecureInputState, on, step, line: line)
            XCTAssertEqual(recorder.secureEventInputCount, on ? 1 : 0, step, line: line)
        }

        view.isPasswordFieldFocused = true
        expect(false, "the panel does not have the keyboard")
        window.makeFirstResponder(view)
        expect(true, "the password field has the keyboard")
        view.isPasswordFieldFocused = false
        expect(false, "another field")
        view.isPasswordFieldFocused = true
        expect(true, "back in the password field")

        recorder.windowIsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        expect(false, "another window or app")
        recorder.windowIsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        expect(true, "the window is key again")

        view.isHidden = true
        expect(false, "the panel shows something else, and AppKit takes the keyboard from it")
        view.isHidden = false
        window.makeFirstResponder(view)
        expect(true, "shown again with the keyboard")

        window.makeFirstResponder(nil)
        expect(false, "the keyboard left the panel")
        window.makeFirstResponder(view)
        expect(true, "the keyboard came back")

        view.tabID = 8
        expect(false, "another tab")
        view.isPasswordFieldFocused = true
        expect(true, "its password field")
        view.tabID = nil
        expect(false, "the tab or its host ended")
        view.tabID = 7
        view.isPasswordFieldFocused = true
        expect(true, "a tab again")

        view.removeFromSuperview()
        expect(false, "the panel closed")
        let turns = ["secure on", "roman only", "all sources", "secure off"]
        XCTAssertEqual(recorder.calls, Array(repeating: turns, count: 7).flatMap { $0 }, "each turn on has one turn off")
    }

    func testNothingIsSentBeforeTheTabExists() {
        let view = makeView()
        view.tabID = nil
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        view.insertText("한", replacementRange: noRange)
        XCTAssertTrue(sent.isEmpty)
    }
}
