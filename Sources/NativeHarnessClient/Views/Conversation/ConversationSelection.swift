import AppKit
import os
import SwiftUI

/// The conversation's one selection, as a page's in the Claude and Codex apps: a drag runs from a
/// question through its answers and on into later turns, a double or triple click selects a word or
/// a paragraph and a drag from it goes on by words or paragraphs, a shift-click extends what is
/// selected, and a press anywhere else in the window drops it. A press in a message's text
/// (`TranscriptProseTextView`) starts it, and so does a drag that starts beside the words (a
/// message's padding, the space between messages, the margins), from the place in reading order
/// nearest the pointer, as a page's does (`ConversationPressSurface`). It takes every piece it passes
/// in reading order: the texts it covers whole, the ends it starts and stops in, and the visible
/// titles of folded lines, turn headers and answered questions (`ConversationSelectionMark`). A copy
/// gives them as plain text in that order.
///
/// Every piece paints its part the same way (`TranscriptProseContainerView.conversationSelection`),
/// whether the selection stays in one text or not, so it keeps its look as a drag crosses from one
/// text into the next; the texts' own selections stay empty.
///
/// The pieces are AppKit views in the conversation's scroll view, wherever SwiftUI hosts them (each
/// turn draws in a hosting view of its own, `ConversationTurnHost`), so the selection reads their
/// places in the scroll view's document and needs nothing from the views around them. It reads them
/// again as the pointer moves, so a block a streaming answer adds is there to select.
@MainActor
enum ConversationSelection {
    /// One piece of a selection: a text and the part of it selected, or a mark taken whole.
    struct Part {
        weak var view: NSView?
        var range: NSRange
    }

    /// What a press selects as the pointer moves: characters from a drag, words after a double
    /// click, paragraphs after a triple click.
    enum Granularity {
        case character, word, paragraph

        init(clickCount: Int) {
            self = clickCount >= 3 ? .paragraph : clickCount == 2 ? .word : .character
        }
    }

    private struct Piece {
        let view: NSView
        let frame: CGRect
        var text: TranscriptProseTextView? { view as? TranscriptProseTextView }
        var length: Int { text.map { ($0.string as NSString).length } ?? 1 }
    }

    private struct Point: Comparable {
        let piece: Int
        let index: Int
        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.piece, lhs.index) < (rhs.piece, rhs.index)
        }
    }

    /// Where a selection started: the piece, and the part the press took there (a word after a double
    /// click), which the selection always covers and a shift-click extends from.
    private struct Anchor {
        weak var view: NSView?
        var range: NSRange
        var granularity: Granularity
    }

    /// What became of a press beside the words (`track(beside:with:)`).
    enum PressBeside {
        /// Not one the conversation follows: a press with a modifier or a second click, or no
        /// conversation there. The view hands it on as before.
        case declined
        /// It selected; nothing else is to happen.
        case selected
        /// A click that selected nothing; the view hands it on, with the release, as before.
        case clicked(up: NSEvent)
    }

    /// The selection's pieces, while there is one.
    private(set) static var parts: [Part] = []
    private static var anchor: Anchor?
    private static var clickMonitor: Any?
    private static var keyObservers: [NSObjectProtocol] = []
    private static var pressLog: Any?

    /// What the selection made of each press, while a drag that the app showed nothing of
    /// (2026-10-25) is confirmed fixed in the installed app: view classes and counts, never the words.
    /// Debug level; the app's `OSLogPreferences` keeps this category on disk, so a drag can be read
    /// afterwards with `log show --debug`.
    static let log = Logger(logHandle)
    /// Asked whether debug messages are kept (`logHandle.isEnabled(type:)`, the C library's
    /// `os_log_type_enabled`, which every macOS has): `Logger.isEnabled(type:)` is a symbol newer SDKs
    /// link that macOS 15 does not have, and an app linking it does not start there.
    static let logHandle = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.zzunkie.yardlet",
                                 category: "conversation-selection")

    /// Whether `view` holds part of the selection, whose copy is the selection's.
    static func spans(_ view: NSView) -> Bool {
        parts.contains { $0.view === view }
    }

    /// The selection as it reads: each piece's selected words, the pieces apart by a blank line.
    static var text: String {
        parts.compactMap { part -> String? in
            guard let view = part.view else { return nil }
            if let text = view as? TranscriptProseTextView, let storage = text.textStorage {
                let range = NSIntersectionRange(part.range, NSRange(location: 0, length: storage.length))
                return TranscriptProseCopy.text(of: storage, in: [range])
            }
            return (view as? ConversationSelectionMarkView)?.text
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// Follows a press in `origin` until the button comes up: a drag selects as it goes, a double or
    /// triple click by words or paragraphs, and a shift-click extends the selection there was. A
    /// click that does not move selects nothing.
    static func track(from origin: TranscriptProseTextView, with down: NSEvent) {
        guard let document = origin.enclosingScrollView?.documentView else { return }
        _ = follow(down, in: document, origin: origin)
    }

    /// Follows a primary press beside the conversation's words, which SwiftUI handed on as nothing of
    /// its own took it: a message's padding, the space beside or between messages, the margins
    /// (`ConversationPressSurface`). A drag selects from the place in reading order nearest where it
    /// started, as a page's does; a click selects nothing and goes on as it did.
    static func track(beside view: NSView, with down: NSEvent) -> PressBeside {
        guard down.type == .leftMouseDown, down.clickCount == 1,
              down.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              let document = view.enclosingScrollView?.documentView, !pieces(in: document).isEmpty
        else { return .declined }
        let (up, selected) = follow(down, in: document, origin: nil)
        // The loop ends only on the release; without one there is nothing to hand on.
        guard !selected, let up else { return .selected }
        return .clicked(up: up)
    }

    /// Follows `down` until the button comes up, from `origin` when the press is in a text and from
    /// the place nearest it otherwise, and returns the release and whether anything is selected.
    private static func follow(_ down: NSEvent, in document: NSView, origin: TranscriptProseTextView?)
        -> (up: NSEvent?, selected: Bool) {
        guard let window = document.window else {
            log.debug("selection: the conversation is in no window")
            return (nil, false)
        }
        var pieces = Self.pieces(in: document)
        let granularity = Granularity(clickCount: down.clickCount)
        let press: (piece: Int, range: NSRange)
        var pressed = 0
        if let origin {
            guard let index = pieces.firstIndex(where: { $0.view === origin }) else {
                log.debug("selection: the pressed text is not among the \(pieces.count, privacy: .public) pieces")
                return (nil, false)
            }
            pressed = origin.characterIndexForInsertion(at: origin.convert(down.locationInWindow, from: nil))
            press = (index, range(around: pressed, in: origin, by: granularity))
        } else {
            guard !pieces.isEmpty else { return (nil, false) }
            // A caret where the press is nearest: a click beside a folded line's title takes none of it.
            let nearest = focus(at: document.convert(down.locationInWindow, from: nil), in: pieces,
                                document: document, by: .character)
            press = (nearest.piece, NSRange(location: nearest.range.location, length: 0))
        }
        let extended = origin != nil && down.modifierFlags.contains(.shift) ? anchor.flatMap { previous in
            previous.view.flatMap { view in pieces.contains { $0.view === view } ? previous : nil }
        } : nil
        let start = extended ?? Anchor(view: pieces[press.piece].view, range: press.range, granularity: granularity)
        clear()
        anchor = start
        if let origin {
            window.makeFirstResponder(origin)
            origin.setSelectedRange(NSRange(location: pressed, length: 0))
        }
        var shown: [Part] = []
        func show(focus: (piece: Int, range: NSRange)) {
            guard let anchorPiece = pieces.firstIndex(where: { $0.view === start.view }) else { return }
            shown = select(anchor: (anchorPiece, start.range), focus: focus, in: pieces, replacing: shown)
        }
        show(focus: press)
        var lastDrag: NSEvent?
        var up: NSEvent?
        var drags = 0
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if event.type == .leftMouseUp {
                up = event
                break
            }
            if event.type == .leftMouseDragged {
                lastDrag = event
                drags += 1
            }
            guard let drag = lastDrag else { continue }
            // Past the conversation's edge it scrolls on, as a text's own drag does.
            document.autoscroll(with: drag)
            // The conversation can change under a drag: a streamed block, a turn laid out again.
            pieces = Self.pieces(in: document)
            show(focus: focus(at: document.convert(drag.locationInWindow, from: nil), in: pieces, document: document,
                              by: start.granularity))
        }
        parts = shown
        let place = origin == nil ? "beside the words" : "in a text"
        guard !parts.isEmpty else {
            log.debug("selection \(place, privacy: .public): \(drags, privacy: .public) drags, nothing selected")
            return (up, false)
        }
        // Copy goes to the first responder: a text that holds part of the selection.
        if !(window.firstResponder.map { responder in parts.contains { $0.view === responder } } ?? false),
           let text = parts.lazy.compactMap({ $0.view as? TranscriptProseTextView }).first {
            window.makeFirstResponder(text)
        }
        watch(window)
        let characters = parts.reduce(0) { $0 + $1.range.length }
        log.debug("""
            selection \(place, privacy: .public): \(drags, privacy: .public) drags, \(parts.count, privacy: .public) \
            pieces, \(characters, privacy: .public) characters, responder \(name(window.firstResponder), privacy: .public), \
            key \(window.isKeyWindow, privacy: .public)
            """)
        return (up, true)
    }

    /// Drops the selection, leaving each text without one.
    static func clear() {
        let previous = parts
        parts = []
        for part in previous { show(nil, in: part.view) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        keyObservers = []
    }

    /// The selection's colour: a selection's own, or the colour of one in a window not being used.
    static func color(in window: NSWindow?) -> NSColor {
        window?.isKeyWindow == false ? .unemphasizedSelectedTextBackgroundColor : .selectedTextBackgroundColor
    }

    /// Shows `range` of `view` as selected, or nothing.
    private static func show(_ range: NSRange?, in view: NSView?) {
        if let text = view as? TranscriptProseTextView {
            (text.superview as? TranscriptProseContainerView)?.conversationSelection = range
            if text.selectedRange().length > 0 {
                text.setSelectedRange(NSRange(location: text.selectedRange().location, length: 0))
            }
        }
        (view as? ConversationSelectionMarkView)?.isSelected = range != nil
    }

    /// The part of `text` a press at `index` takes: nothing for a drag, the word or the paragraph
    /// around it after a double or triple click.
    private static func range(around index: Int, in text: TranscriptProseTextView, by granularity: Granularity)
        -> NSRange {
        let caret = NSRange(location: index, length: 0)
        switch granularity {
        case .character: return caret
        case .word: return text.selectionRange(forProposedRange: caret, granularity: .selectByWord)
        case .paragraph: return text.selectionRange(forProposedRange: caret, granularity: .selectByParagraph)
        }
    }

    // MARK: - Pieces

    /// The texts and marks in the conversation's document, in reading order.
    private static func pieces(in document: NSView) -> [Piece] {
        var pieces: [Piece] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            if view is TranscriptProseTextView || view is ConversationSelectionMarkView {
                pieces.append(Piece(view: view, frame: view.convert(view.bounds, to: document)))
                return
            }
            for subview in view.subviews { visit(subview) }
        }
        visit(document)
        let flipped = document.isFlipped
        return pieces.sorted { lhs, rhs in
            let lhsTop = flipped ? lhs.frame.minY : -lhs.frame.maxY
            let rhsTop = flipped ? rhs.frame.minY : -rhs.frame.maxY
            return abs(lhsTop - rhsTop) > 2 ? lhsTop < rhsTop : lhs.frame.minX < rhs.frame.minX
        }
    }

    /// What the pointer at `point` (in the document) takes in reading order: in the text under it, the
    /// character, word or paragraph there; a mark under it whole; below a piece, its end; above the
    /// first, its start.
    private static func focus(at point: CGPoint, in pieces: [Piece], document: NSView, by granularity: Granularity)
        -> (piece: Int, range: NSRange) {
        let flipped = document.isFlipped
        func top(_ frame: CGRect) -> CGFloat { flipped ? frame.minY : -frame.maxY }
        func bottom(_ frame: CGRect) -> CGFloat { flipped ? frame.maxY : -frame.minY }
        let y = flipped ? point.y : -point.y
        guard let index = pieces.lastIndex(where: { top($0.frame) <= y }) else { return (0, NSRange()) }
        let piece = pieces[index]
        if y > bottom(piece.frame) { return (index, NSRange(location: piece.length, length: 0)) }
        guard let text = piece.text else { return (index, NSRange(location: 0, length: piece.length)) }
        let character = text.characterIndexForInsertion(at: text.convert(point, from: document))
        return (index, range(around: character, in: text, by: granularity))
    }

    /// Shows the selection from `anchor` to `focus`, each a piece and the part of it the selection
    /// covers, and returns its parts, clearing what `shown` selected that it no longer covers.
    private static func select(anchor: (piece: Int, range: NSRange), focus: (piece: Int, range: NSRange),
                               in pieces: [Piece], replacing shown: [Part]) -> [Part] {
        let start = min(Point(piece: anchor.piece, index: anchor.range.location),
                        Point(piece: focus.piece, index: focus.range.location))
        let end = max(Point(piece: anchor.piece, index: NSMaxRange(anchor.range)),
                      Point(piece: focus.piece, index: NSMaxRange(focus.range)))
        var parts: [Part] = []
        if start < end {
            for index in start.piece...end.piece {
                let piece = pieces[index]
                let from = index == start.piece ? start.index : 0
                let to = index == end.piece ? end.index : piece.length
                guard to > from else { continue }
                parts.append(Part(view: piece.view, range: NSRange(location: from, length: to - from)))
            }
        }
        for part in shown where !parts.contains(where: { $0.view === part.view }) {
            show(nil, in: part.view)
        }
        for part in parts {
            show(part.range, in: part.view)
        }
        return parts
    }

    /// A press anywhere in a window's content but a conversation's text or a scroller drops the
    /// selection, as a press on a page's background does; a press in a text decides for itself (a new
    /// selection, a shift-click extending this one, a right click for its menu's Copy). A press outside
    /// the content, on the title bar, leaves it. The window's going in and out of use recolours it.
    private static func watch(_ window: NSWindow) {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    for part in parts {
                        (part.view?.superview as? TranscriptProseContainerView)?.paintBackgrounds()
                        part.view?.needsDisplay = true
                    }
                }
            })
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                guard let content = event.window?.contentView,
                      let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil)
                                                ?? event.locationInWindow),
                      !(hit is NSScroller) else { return }
                var view: NSView? = hit
                while let current = view, !(current is TranscriptProseTextView) { view = current.superview }
                if view == nil {
                    log.debug("selection dropped by a press on \(name(hit), privacy: .public)")
                    clear()
                }
            }
            return event
        }
    }

    // MARK: - Log

    /// Notes each primary press over a conversation's text before the window hands it on: the view
    /// it goes to, which is the text unless something lies over it, and the window's key and first
    /// responder.
    static func logPresses() {
        guard pressLog == nil else { return }
        pressLog = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                guard logHandle.isEnabled(type: .debug), let window = event.window, let content = window.contentView,
                      let text = proseText(at: event.locationInWindow, in: content) else { return }
                let root = content.superview ?? content
                let hit = root.hitTest(root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
                log.debug("""
                    press over a text goes to \(hit === text ? "the text" : name(hit), privacy: .public), \
                    clicks \(event.clickCount, privacy: .public), key \(window.isKeyWindow, privacy: .public), \
                    responder \(name(window.firstResponder), privacy: .public)
                    """)
            }
            return event
        }
    }

    /// The conversation text shown at `point` (in the window) under `view`.
    private static func proseText(at point: NSPoint, in view: NSView) -> TranscriptProseTextView? {
        guard !view.isHidden, view.bounds.contains(view.convert(point, from: nil)) else { return nil }
        if let text = view as? TranscriptProseTextView {
            return text.visibleRect.contains(text.convert(point, from: nil)) ? text : nil
        }
        return view.subviews.reversed().lazy.compactMap { proseText(at: point, in: $0) }.first
    }

    /// A view's or responder's class, for the log.
    static func name(_ object: AnyObject?) -> String {
        object.map { String(String(describing: type(of: $0)).prefix(120)) } ?? "none"
    }
}

/// A view under the conversation's content that takes the presses SwiftUI hands on because nothing of
/// its own used them: a message's padding, the space beside and between messages, the margins. A drag
/// from there selects as a page's does (`ConversationSelection.track(beside:with:)`); a click, or any
/// press the conversation does not follow, goes on up the responder chain as it did before.
class ConversationPressSurface: NSView {
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        switch ConversationSelection.track(beside: self, with: event) {
        case .declined:
            ConversationSelection.log.debug("press beside the words handed on, clicks \(event.clickCount, privacy: .public)")
            super.mouseDown(with: event)
        case .selected:
            break
        case let .clicked(up):
            super.mouseDown(with: event)
            super.mouseUp(with: up)
        }
    }
}

/// The conversation's margins and the space between its turns, behind its content
/// (`ConversationPressSurface`).
struct ConversationPressBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> ConversationPressSurface {
        let view = ConversationPressSurface()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: ConversationPressSurface, context: Context) {}
}

/// The visible title of a folded line, a turn's header or an answered question, which a selection
/// across the conversation takes whole and tints while it does.
final class ConversationSelectionMarkView: NSView {
    var text = ""
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    /// Clicks go to the line under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        ConversationSelection.color(in: window).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
    }
}

private struct ConversationSelectionMark: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> ConversationSelectionMarkView {
        let view = ConversationSelectionMarkView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: ConversationSelectionMarkView, context: Context) {
        view.text = text
    }
}

extension View {
    /// What a selection across the conversation copies of this view: its visible title.
    func conversationSelectionText(_ text: String) -> some View {
        background { ConversationSelectionMark(text: text).accessibilityHidden(true) }
    }
}
