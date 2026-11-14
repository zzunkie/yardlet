import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The conversation's one selection, as a page's in the Claude and Codex apps: a drag that starts in
/// one message runs on through the turns below it, a double or triple click takes a word or a
/// paragraph, a shift-click extends, a press anywhere else drops it, and a copy gives the questions,
/// answers, answered questions and folded lines' titles in reading order as plain text. The presses
/// and drags are the window's own events, sent through the application as the person's pointer
/// sends them.
@MainActor
final class ConversationSelectionTests: XCTestCase {
    static let questions = [
        PermissionQuestion(
            question: "Which parts should the notes cover?", header: "Scope",
            options: [PermissionQuestionOption(label: "Composer"), PermissionQuestionOption(label: "Question card")],
            allowsMultipleSelections: true),
        PermissionQuestion(
            question: "Who will read them?", header: "Audience",
            options: [PermissionQuestionOption(label: "The team"), PermissionQuestionOption(label: "Everyone")],
            allowsMultipleSelections: false)
    ]

    private func entries() -> [TranscriptEntry] {
        [
            TranscriptEntry(content: .user(text: "Question one")),
            TranscriptEntry(content: .assistant(text: "Answer one.\n\nA second paragraph.", isStreaming: false)),
            TranscriptEntry(content: .user(text: "Question two")),
            TranscriptEntry(content: .activity(HarnessActivity(
                id: "bash-1", kind: "Bash", title: "Bash",
                input: #"{"command":"swift test","description":"Run the tests"}"#, output: "passed"), state: .completed)),
            TranscriptEntry(content: .assistant(text: "Answer two, which ends here.", isStreaming: false))
        ]
    }

    /// A question the agent asked in the middle of its turn, answered, between the request and the
    /// answer.
    static func answeredQuestionEntries() -> [TranscriptEntry] {
        let answers = HarnessAnsweredQuestions(questions: questions, answers: [
            PermissionQuestionAnswer(question: questions[0].question, selectedLabels: ["Composer", "Question card"]),
            PermissionQuestionAnswer(question: questions[1].question, selectedLabels: ["The team"])
        ])
        return [
            TranscriptEntry(content: .user(text: "Write the release notes")),
            TranscriptEntry(content: .activity(HarnessActivity(
                id: "ask-1", kind: ClaudeAnswerableTool.askUserQuestion, title: "Questions", answeredQuestions: answers),
                state: .completed)),
            TranscriptEntry(content: .assistant(text: "The notes cover the composer.", isStreaming: false))
        ]
    }

    /// Nothing an earlier press left in the queue reaches this test's.
    override func setUp() async throws {
        try await super.setUp()
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp]
        while NSApplication.shared.nextEvent(matching: mouse, until: Date(), inMode: .default, dequeue: true) != nil {}
    }

    private func makeHost(_ entries: [TranscriptEntry]? = nil, status: SessionStatus = .running,
                          _ scheme: ColorScheme = .light) -> WindowlessRender.Host<some View> {
        let host = WindowlessRender.Host(
            TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet-selection"),
                                 entries: entries ?? self.entries(), sessionStatus: status)
                .environment(\.colorScheme, scheme)
                .frame(width: 760, height: 900)
                .background(ParityTheme.canvas),
            size: NSSize(width: 760, height: 900), appearance: scheme == .dark ? .dark : .light)
        show(host)
        return host
    }

    /// Puts the window on the screen, far from where anyone looks, so the application hands it the
    /// presses it is sent, and settles it.
    private func show(_ host: WindowlessRender.Host<some View>) {
        host.window.setFrameOrigin(NSPoint(x: 20_000, y: 20_000))
        host.window.orderFrontRegardless()
        host.settle(passes: 12)
        addTeardownBlock { ConversationSelection.clear() }
    }

    private func text(_ string: String, in host: WindowlessRender.Host<some View>) throws -> TranscriptProseTextView {
        try XCTUnwrap(TranscriptProseRenderingTests.proseTextViews(in: host.hosting).first { $0.string.hasPrefix(string) },
                      "No text \(string)")
    }

    /// The window point at the start (or end) of `word` in `text`.
    private func point(_ word: String, in text: TranscriptProseTextView, atEnd: Bool = false) throws -> NSPoint {
        let container = try XCTUnwrap(text.superview as? TranscriptProseContainerView)
        let range = (text.string as NSString).range(of: word)
        let rect = try XCTUnwrap(container.rect(of: range))
        let local = NSPoint(x: atEnd ? rect.maxX - 0.5 : rect.minX + 0.5, y: rect.midY)
        return container.convert(local, to: nil)
    }

    /// A point on the conversation's background beside `text`, where no text is.
    private func background(beside text: TranscriptProseTextView) -> NSPoint {
        NSPoint(x: 8, y: text.convert(text.bounds, to: nil).midY)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clickCount: Int = 1,
                       modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clickCount,
                           pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Presses at `start`, moves to `end` when there is one, and lets go, as the person's button
    /// would: the press goes through the application, which hands it to the view under it. A view that
    /// follows the press (a text, or the conversation beside its words) reads the moves and the release
    /// from the queue; for any other, they go through the application after it.
    private func press(at start: NSPoint, dragTo end: NSPoint? = nil, in window: NSWindow, clickCount: Int = 1,
                       modifiers: NSEvent.ModifierFlags = []) {
        if let end {
            let steps = 6
            for step in 1...steps {
                let fraction = CGFloat(step) / CGFloat(steps)
                let point = NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
                NSApp.postEvent(event(.leftMouseDragged, at: point, in: window, clickCount: clickCount,
                                      modifiers: modifiers), atStart: false)
            }
        }
        NSApp.postEvent(event(.leftMouseUp, at: end ?? start, in: window, clickCount: clickCount, modifiers: modifiers),
                        atStart: false)
        NSApp.sendEvent(event(.leftMouseDown, at: start, in: window, clickCount: clickCount, modifiers: modifiers))
        let rest: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        while let left = NSApp.nextEvent(matching: rest, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(left)
        }
    }

    private func copied(from text: TranscriptProseTextView) throws -> String {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ConversationSelectionTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes))
        return try XCTUnwrap(pasteboard.string(forType: .string))
    }

    /// The part of `text` the selection paints.
    static func painted(_ text: TranscriptProseTextView) -> NSRange? {
        (text.superview as? TranscriptProseContainerView)?.conversationSelection
    }

    private func marks(in root: NSView) -> [ConversationSelectionMarkView] {
        ((root as? ConversationSelectionMarkView).map { [$0] } ?? []) + root.subviews.flatMap(marks)
    }

    // MARK: - Drags

    func testADragRunsOnThroughTheTurnsBelowAndCopiesThemInOrder() throws {
        let host = makeHost()
        defer { host.close() }
        let firstAnswer = try text("Answer one.", in: host)
        let secondAnswer = try text("Answer two, which ends here.", in: host)
        press(at: try point("Answer one", in: firstAnswer), dragTo: try point("two,", in: secondAnswer, atEnd: true),
              in: host.window)
        XCTAssertTrue(ConversationSelection.spans(firstAnswer))
        XCTAssertEqual(Self.painted(try text("Question two", in: host)), NSRange(location: 0, length: 12),
                       "The question between is selected whole")
        XCTAssertEqual(Self.painted(secondAnswer), NSRange(location: 0, length: 11))
        XCTAssertEqual(firstAnswer.selectedRange().length, 0, "Each text paints its part alike")
        let copy = try copied(from: firstAnswer)
        XCTAssertTrue(copy.hasPrefix("Answer one.\n\nA second paragraph.\n\nQuestion two\n\n"), copy)
        XCTAssertTrue(copy.hasSuffix("\n\nAnswer two,"), copy)
        // The folded command between them reads as its line's words.
        XCTAssertTrue(copy.contains("\n\nRan the tests\n\n"), copy)

        // A press on the conversation's background drops all of it.
        press(at: background(beside: firstAnswer), in: host.window)
        XCTAssertFalse(ConversationSelection.spans(firstAnswer))
        XCTAssertNil(Self.painted(firstAnswer))
        XCTAssertNil(Self.painted(secondAnswer))
        XCTAssertTrue(marks(in: host.hosting).allSatisfy { !$0.isSelected })
    }

    /// 2026-10-23 (a user reported that dragging to select text behaved oddly): a drag that stayed in one text drew the
    /// text's own selection, whole lines out to the text's edge, and turned into the painted marks of a
    /// selection across texts the moment it crossed into the next one. Now it paints from the start.
    func testADragWithinOneTextPaintsAsADragAcrossTextsDoes() throws {
        let host = makeHost()
        defer { host.close() }
        let answer = try text("Answer one.", in: host)
        press(at: try point("one", in: answer), dragTo: try point("second", in: answer, atEnd: true), in: host.window)
        XCTAssertTrue(ConversationSelection.spans(answer))
        XCTAssertEqual(answer.selectedRange().length, 0, "No look of the text's own")
        let painted = try XCTUnwrap(Self.painted(answer))
        XCTAssertEqual((answer.string as NSString).substring(with: painted), "one.\nA second")
        XCTAssertEqual(try copied(from: answer), "one.\n\nA second")
    }

    /// 2026-10-25 (a user reported that dragging still did not copy the conversation): a drag selected, and a render of the view showed it,
    /// but the window showed none of it: TextKit 2 draws a text's lines in views of its own, which
    /// painting the selection left as they were drawn. The window's next display draws them again as a
    /// drag selects and as a press drops it.
    func testTheWindowDrawsTheSelectionAsItChanges() throws {
        let host = makeHost()
        defer { host.close() }
        let answer = try text("Answer one.", in: host)
        let lines = try XCTUnwrap(answer.textLayoutManager)
        host.window.displayIfNeeded()
        XCTAssertEqual(LineDraws.counting(lines) { host.window.displayIfNeeded() }, 0, "Nothing changed")
        let selected = try LineDraws.counting(lines) {
            press(at: try point("one", in: answer), dragTo: try point("second", in: answer, atEnd: true), in: host.window)
            host.window.displayIfNeeded()
        }
        XCTAssertGreaterThan(selected, 0, "The window still shows the text unselected")
        let dropped = LineDraws.counting(lines) {
            press(at: background(beside: answer), in: host.window)
            host.window.displayIfNeeded()
        }
        XCTAssertGreaterThan(dropped, 0, "The window still shows the dropped selection")
    }

    func testADragUpFromAnAnswerTakesTheQuestionAbove() throws {
        let host = makeHost()
        defer { host.close() }
        let answer = try text("Answer two, which ends here.", in: host)
        let question = try text("Question one", in: host)
        press(at: try point("which", in: answer), dragTo: try point("one", in: question), in: host.window)
        let copy = try copied(from: answer)
        XCTAssertTrue(copy.hasPrefix("one\n\nAnswer one."), copy)
        XCTAssertTrue(copy.hasSuffix("Answer two, "), copy)
    }

    /// 2026-10-24 (a user reported that an ordinary trackpad drag selected nothing): a drag that started beside the
    /// words, left of an answer's line, in a request's bubble or between two turns, selected nothing, as
    /// nothing there followed the press. A page in both apps selects from the place nearest the
    /// pointer. A click there still selects nothing, and a click on a control in a turn is the control's.
    func testADragFromBesideTheWordsSelectsFromTheNearestPlace() throws {
        let host = makeHost()
        defer { host.close() }
        let firstAnswer = try text("Answer one.", in: host)
        let question = try text("Question two", in: host)
        let answer = firstAnswer.convert(firstAnswer.bounds, to: nil)
        let bubble = question.convert(question.bounds, to: nil)

        let margin = NSPoint(x: answer.minX - 6, y: answer.maxY - 8)
        press(at: margin, dragTo: try point("one.", in: firstAnswer, atEnd: true), in: host.window)
        XCTAssertEqual(try copied(from: firstAnswer), "Answer one.", "From the margin left of the line")

        press(at: NSPoint(x: bubble.minX - 6, y: bubble.midY), dragTo: try point("Question", in: question, atEnd: true),
              in: host.window)
        XCTAssertEqual(try copied(from: question), "Question", "From the bubble's padding")

        let between = NSPoint(x: bubble.minX - 60, y: (answer.minY + bubble.maxY) / 2)
        press(at: between, dragTo: try point("two", in: question, atEnd: true), in: host.window)
        XCTAssertEqual(try copied(from: question), "Question two", "From the space between the turns")

        press(at: margin, in: host.window)
        XCTAssertTrue(ConversationSelection.parts.isEmpty, "A click beside the words selects nothing")

        // The folded command's line is a control: a click opens it, and selects nothing.
        let foldedLine = try XCTUnwrap(marks(in: host.hosting).first { $0.text == "Ran the tests" })
        let line = foldedLine.convert(foldedLine.bounds, to: nil)
        func lineState() -> String? {
            host.accessibilityElements().first { $0.role == "AXButton" && $0.label == "Ran the tests" }?.value
        }
        let folded = lineState()
        press(at: NSPoint(x: line.midX, y: line.midY), in: host.window)
        host.settle(passes: 4)
        XCTAssertTrue(ConversationSelection.parts.isEmpty)
        XCTAssertNotNil(folded)
        XCTAssertNotEqual(lineState(), folded, "The click opened the folded line")
    }

    /// 2026-10-23 (a user reported that dragging past an answered question felt wrong): a drag past a question the agent
    /// asked left the card out — nothing in it tinted, nothing of it copied — as if the card were not
    /// there. The Claude app's answered card lets a page's selection take its answers.
    func testADragPastAnAnsweredQuestionTakesItsQuestionsAndAnswers() throws {
        let host = makeHost(Self.answeredQuestionEntries(), status: .completed)
        defer { host.close() }
        let request = try text("Write the release notes", in: host)
        let answer = try text("The notes cover", in: host)
        press(at: try point("release", in: request), dragTo: try point("cover", in: answer, atEnd: true),
              in: host.window)
        let copy = try copied(from: answer)
        XCTAssertTrue(copy.hasPrefix("release notes\n\nWhich parts should the notes cover?\n\nComposer, Question card\n\n"
                                     + "Who will read them?\n\nThe team\n\n"), copy)
        XCTAssertTrue(copy.hasSuffix("\n\nThe notes cover"), copy)
        let tinted = Set(marks(in: host.hosting).filter(\.isSelected).map(\.text))
        for line in ["Which parts should the notes cover?", "Composer, Question card", "Who will read them?", "The team"] {
            XCTAssertTrue(tinted.contains(line), "\(line) is not tinted: \(tinted)")
        }
    }

    // MARK: - Presses

    /// 2026-10-23 (a user reported that clicking elsewhere after a drag left part of the selection): a selection that stayed in one
    /// text was the text's own and went only when another view took the keyboard, so a press on what
    /// takes none (the space inside a turn, a folded line, a button) left it there.
    func testAPressAnywhereButATextDropsTheSelection() throws {
        let host = makeHost()
        defer { host.close() }
        let answer = try text("Answer one.", in: host)
        let question = try text("Question two", in: host)
        let bubble = question.convert(question.bounds, to: nil)
        let foldedLine = try XCTUnwrap(marks(in: host.hosting).first { $0.text == "Ran the tests" })
        let places = [
            "the conversation's margin": background(beside: answer),
            "the turn beside a request": NSPoint(x: bubble.minX - 60, y: bubble.midY),
            "a folded line": { let frame = foldedLine.convert(foldedLine.bounds, to: nil); return NSPoint(x: frame.midX, y: frame.midY) }()
        ]
        for (name, place) in places.sorted(by: { $0.key < $1.key }) {
            press(at: try point("Answer", in: answer), dragTo: try point("second", in: answer, atEnd: true),
                  in: host.window)
            XCTAssertTrue(Self.isSelected(answer), name)
            press(at: place, in: host.window)
            XCTAssertFalse(Self.isSelected(answer), "A press on \(name) left the selection")
            host.settle(passes: 2)
        }

        // A press in another text starts a new selection there and drops this one.
        press(at: try point("Answer", in: answer), dragTo: try point("second", in: answer, atEnd: true), in: host.window)
        press(at: try point("two", in: question), in: host.window)
        XCTAssertFalse(Self.isSelected(answer))
        XCTAssertFalse(Self.isSelected(question), "A click that does not move selects nothing")
    }

    /// Whether any of `text` shows as selected, painted or its own.
    static func isSelected(_ text: TranscriptProseTextView) -> Bool {
        painted(text) != nil || text.selectedRange().length > 0
    }

    func testADoubleClickTakesAWordAndADragFromItGoesOnByWords() throws {
        let host = makeHost()
        defer { host.close() }
        let answer = try text("Answer one.", in: host)
        let question = try text("Question two", in: host)
        let word = try point("second", in: answer)
        press(at: word, in: host.window)
        press(at: word, in: host.window, clickCount: 2)
        XCTAssertEqual(try copied(from: answer), "second")

        press(at: word, in: host.window)
        press(at: word, dragTo: try point("Question", in: question), in: host.window, clickCount: 2)
        XCTAssertEqual(try copied(from: answer), "second paragraph.\n\nQuestion", "Whole words at both ends")
    }

    func testATripleClickTakesAParagraph() throws {
        let host = makeHost()
        defer { host.close() }
        let answer = try text("Answer one.", in: host)
        let word = try point("second", in: answer)
        press(at: word, in: host.window)
        press(at: word, in: host.window, clickCount: 2)
        press(at: word, in: host.window, clickCount: 3)
        XCTAssertEqual(try copied(from: answer).trimmingCharacters(in: .newlines), "A second paragraph.")
    }

    func testAShiftClickExtendsTheSelectionFromWhereItStarted() throws {
        let host = makeHost()
        defer { host.close() }
        let firstAnswer = try text("Answer one.", in: host)
        let secondAnswer = try text("Answer two, which ends here.", in: host)
        press(at: try point("Answer", in: firstAnswer), dragTo: try point("second", in: firstAnswer, atEnd: true),
              in: host.window)
        press(at: try point("two,", in: secondAnswer, atEnd: true), in: host.window, modifiers: .shift)
        var copy = try copied(from: firstAnswer)
        XCTAssertTrue(copy.hasPrefix("Answer one.\n\nA second paragraph.\n\nQuestion two"), copy)
        XCTAssertTrue(copy.hasSuffix("Answer two,"), copy)

        // Back up into the first answer: the selection shrinks to there, from the same start.
        press(at: try point("second", in: firstAnswer, atEnd: true), in: host.window, modifiers: .shift)
        copy = try copied(from: firstAnswer)
        XCTAssertEqual(copy, "Answer one.\n\nA second")
        XCTAssertNil(Self.painted(secondAnswer))
    }

    /// A click on a link opens it and selects nothing, also while the answer it is in goes on being
    /// written under the button; a drag from a link selects from there, as a drag from any other word
    /// does. 2026-11-04: the text system's own tracking of such a click, which sets the text's selection
    /// again for every event of the press, held the main thread until the app was quit, and a fragment
    /// arriving during a click opened nothing.
    func testAClickOnALinkOpensItAndADragFromItSelects() throws {
        var opened: [URL] = []
        let words = "It is [the forum thread](https://forums.swift.org/t/1) for now."
        let box = StreamingBox(entries: [
            TranscriptEntry(content: .user(text: "Where is the thread?")),
            TranscriptEntry(content: .assistant(text: words, isStreaming: true))
        ])
        let host = WindowlessRender.Host(
            StreamingConversation(box: box)
                .environment(\.openURL, OpenURLAction { url in
                    opened.append(url)
                    return .handled
                })
                .frame(width: 760, height: 600).background(ParityTheme.canvas),
            size: NSSize(width: 760, height: 600), appearance: .light)
        defer { host.close() }
        show(host)
        let answer = try text("It is", in: host)
        let link = try point("forum", in: answer)

        press(at: link, in: host.window)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://forums.swift.org/t/1"])
        XCTAssertFalse(Self.isSelected(answer))

        // The button comes up once a fragment arrived while it was down.
        let up = event(.leftMouseUp, at: link, in: host.window)
        let deadline = Date().addingTimeInterval(testWaitLimitSeconds)
        func releaseOnceWritten() {
            if answer.string.contains("Another sentence") || Date() > deadline {
                NSApp.postEvent(up, atStart: false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { releaseOnceWritten() }
            }
        }
        DispatchQueue.main.async {
            box.entries[1] = TranscriptEntry(id: box.entries[1].id, createdAt: box.entries[1].createdAt, content: .assistant(
                text: words + "\n\nAnother sentence written while the button is down.", isStreaming: true))
            releaseOnceWritten()
        }
        NSApp.sendEvent(event(.leftMouseDown, at: link, in: host.window))
        XCTAssertTrue(answer.string.contains("Another sentence"), "No fragment arrived during the press")
        XCTAssertEqual(opened.count, 2, "A fragment during the click kept the link from opening")
        XCTAssertFalse(Self.isSelected(answer))

        press(at: link, dragTo: try point("now", in: answer, atEnd: true), in: host.window)
        XCTAssertEqual(opened.count, 2, "A drag opens nothing")
        let painted = try XCTUnwrap(Self.painted(answer))
        XCTAssertEqual((answer.string as NSString).substring(with: painted), "forum thread for now")
    }

    // MARK: - While it is there

    /// The selection stays through scrolling and through the answer it covers growing, as a page's
    /// does; the words it covers keep their tint.
    func testASelectionStaysThroughScrollingAndAStreamingAnswer() throws {
        let box = StreamingBox(entries: [
            TranscriptEntry(content: .user(text: "Question one")),
            TranscriptEntry(content: .assistant(text: "Answer one is streaming", isStreaming: true))
        ])
        let host = WindowlessRender.Host(
            StreamingConversation(box: box).frame(width: 760, height: 600).background(ParityTheme.canvas),
            size: NSSize(width: 760, height: 600), appearance: .light)
        defer { host.close() }
        show(host)
        let question = try text("Question one", in: host)
        let answer = try text("Answer one", in: host)
        press(at: try point("Question", in: question), dragTo: try point("is", in: answer, atEnd: true), in: host.window)
        XCTAssertEqual(Self.painted(answer), NSRange(location: 0, length: 13))

        box.entries[1] = TranscriptEntry(id: box.entries[1].id, content: .assistant(
            text: "Answer one is streaming on into a second sentence.\n\nAnd a paragraph.", isStreaming: true))
        host.settle(passes: 6)
        XCTAssertTrue(ConversationSelection.spans(answer))
        XCTAssertEqual(Self.painted(answer), NSRange(location: 0, length: 13))
        // The streaming text reads as the turn's working notes until it ends.
        XCTAssertEqual(try copied(from: answer), "Question one\n\n\(L10n.string("Commentary"))\n\nAnswer one is")

        let scroll = try XCTUnwrap(answer.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.settle(passes: 4)
        XCTAssertTrue(ConversationSelection.spans(answer))
        XCTAssertNotNil(Self.painted(question))
    }

    /// A selection keeps the turns it holds in the window when the conversation scrolls far from them,
    /// so it is there to copy and to extend; the row list otherwise keeps only the turns near its view.
    func testASelectionKeepsItsTurnsInTheWindowWhenTheConversationScrollsAway() throws {
        let host = makeHost(LongConversationFixture.claude(turns: 9), status: .ready)
        defer { host.close() }
        let scroll = try XCTUnwrap(BlankFrameProbe.conversationScrollView(in: host.hosting))
        // To the conversation's top or its end, whichever way its document counts.
        func go(toTop top: Bool) {
            guard let document = scroll.documentView else { return }
            let end = max(0, document.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: top == document.isFlipped ? 0 : end))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.settle(passes: 3)
        }
        go(toTop: true)
        // The turn at the top is laid out over the next passes, slower on CI.
        var found: TranscriptProseTextView?
        host.settle {
            found = TranscriptProseRenderingTests.proseTextViews(in: host.hosting)
                .first { $0.string.hasPrefix(LongConversationFixture.request(0)) }
            guard let found, let container = found.superview as? TranscriptProseContainerView else { return false }
            return container.rect(of: (found.string as NSString).range(of: "module")) != nil
        }
        let request = try XCTUnwrap(found)
        press(at: try point("look", in: request), dragTo: try point("module", in: request, atEnd: true), in: host.window)
        XCTAssertTrue(ConversationSelection.spans(request))
        go(toTop: false)
        XCTAssertNotNil(request.window, "The selected turn is still in the window")
        XCTAssertTrue(ConversationSelection.spans(request))
        XCTAssertEqual(try copied(from: request), "look at the parser module")
    }

    // MARK: - Renders

    func testASelectionDrawsInBothAppearances() throws {
        let directory = try WindowlessRender.directory("conversation-text")
        for appearance in WindowlessRender.Appearance.allCases {
            do {
                let host = makeHost(nil, appearance.colorScheme)
                defer { host.close() }
                let firstAnswer = try text("Answer one.", in: host)
                let secondAnswer = try text("Answer two, which ends here.", in: host)
                press(at: try point("one", in: firstAnswer), dragTo: try point("ends", in: secondAnswer, atEnd: true),
                      in: host.window)
                host.settle(passes: 2)
                try WindowlessRender.writePNG(host.capture().bitmap,
                                              to: directory.appending(path: "selection-across-\(appearance.suffix).png"))
                press(at: try point("Answer", in: firstAnswer), dragTo: try point("second", in: firstAnswer, atEnd: true),
                      in: host.window)
                host.settle(passes: 2)
                try WindowlessRender.writePNG(host.capture().bitmap,
                                              to: directory.appending(path: "selection-within-\(appearance.suffix).png"))
                // From the margin left of the answer's first line.
                let answer = firstAnswer.convert(firstAnswer.bounds, to: nil)
                press(at: NSPoint(x: answer.minX - 6, y: answer.maxY - 8),
                      dragTo: try point("second", in: firstAnswer, atEnd: true), in: host.window)
                host.settle(passes: 2)
                try WindowlessRender.writePNG(host.capture().bitmap,
                                              to: directory.appending(path: "selection-beside-\(appearance.suffix).png"))
                ConversationSelection.clear()
            }
            do {
                let host = makeHost(Self.answeredQuestionEntries(), status: .completed, appearance.colorScheme)
                defer { host.close() }
                let request = try text("Write the release notes", in: host)
                let answer = try text("The notes cover", in: host)
                press(at: try point("release", in: request), dragTo: try point("cover", in: answer, atEnd: true),
                      in: host.window)
                host.settle(passes: 2)
                try WindowlessRender.writePNG(host.capture().bitmap,
                                              to: directory.appending(path: "selection-question-\(appearance.suffix).png"))
                ConversationSelection.clear()
            }
        }
    }
}

/// How many times a text's lines are drawn (`NSTextLayoutFragment.draw(at:in:)`) while `body` runs:
/// what the window draws again, which a render of the view (`cacheDisplay`) would draw afresh anyway.
@MainActor
private enum LineDraws {
    static func counting(_ lines: NSTextLayoutManager, during body: () throws -> Void) rethrows -> Int {
        let selector = #selector(NSTextLayoutFragment.draw(at:in:))
        let method = class_getInstanceMethod(NSTextLayoutFragment.self, selector)!
        let original = method_getImplementation(method)
        typealias Draw = @convention(c) (NSTextLayoutFragment, Selector, CGPoint, CGContext) -> Void
        let draw = unsafeBitCast(original, to: Draw.self)
        var count = 0
        let counted: @convention(block) (NSTextLayoutFragment, CGPoint, CGContext) -> Void = { fragment, point, context in
            if fragment.textLayoutManager === lines { count += 1 }
            draw(fragment, selector, point, context)
        }
        method_setImplementation(method, imp_implementationWithBlock(counted))
        defer { method_setImplementation(method, original) }
        try body()
        return count
    }
}

/// A conversation whose entries a test changes while it shows, as a streaming turn's do.
@MainActor @Observable
private final class StreamingBox {
    var entries: [TranscriptEntry]
    init(entries: [TranscriptEntry]) { self.entries = entries }
}

private struct StreamingConversation: View {
    let box: StreamingBox

    var body: some View {
        TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet-selection"),
                             entries: box.entries, sessionStatus: .running)
    }
}
