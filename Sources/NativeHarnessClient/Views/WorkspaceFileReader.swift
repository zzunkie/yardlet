import AppKit
import SwiftUI

struct WorkspaceFileReader: NSViewRepresentable {
    let document: WorkspaceFileDocument
    let bookmark: FileReadingBookmark
    let location: WorkspaceFileLocation?
    let navigationID: UUID
    let fontSize: CGFloat
    let focus: TaskKeyboardFocus?
    let onBookmark: (FileReadingBookmark) -> Void
    let onNavigated: (UUID) -> Void
    var onEdit: ((String) -> Void)? = nil
    var isSaving = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WorkspaceFileContainer {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        // TextKit 2 lays out the lines in view, so a 20 MB file opens and scrolls without laying
        // out the rest. Asking the view for its `layoutManager` would turn it back to TextKit 1.
        let text = WorkspaceFileTextView(usingTextLayoutManager: true)
        text.isEditable = false
        text.delegate = context.coordinator
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = true
        text.autoresizingMask = []
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 10, height: 12)
        scroll.documentView = text
        let view = WorkspaceFileContainer(scroll: scroll)
        context.coordinator.gutter = view.gutter
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scroll = scroll
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didScroll),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        // TextKit 2 refines the heights it estimated as it lays out more; the line numbers follow.
        text.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didResize),
            name: NSView.frameDidChangeNotification, object: text)
        return view
    }

    func updateNSView(_ view: WorkspaceFileContainer, context: Context) {
        let scroll = view.scroll
        guard let text = scroll.documentView as? WorkspaceFileTextView else { return }
        let coordinator = context.coordinator
        coordinator.onBookmark = onBookmark
        coordinator.document = document
        coordinator.onEdit = onEdit
        text.isEditable = onEdit != nil && !isSaving
        // Typing changes the text under the same document; only another text is drawn again.
        // Nothing here grows with the file: this runs again whenever the reading position is kept.
        let changed = coordinator.documentID != document.id || coordinator.fontSize != fontSize
            || text.documentLength != document.utf16Length
        coordinator.isApplying = true
        if changed {
            coordinator.documentID = document.id
            coordinator.fontSize = fontSize
            coordinator.highlightID = document.highlightID
            text.show(document, font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
            text.setAccessibilityLabel(document.path)
            view.gutter.document = document
            view.gutter.fontSize = fontSize
            view.gutter.ruleThickness = max(42, CGFloat(String(document.lineStarts.count).count) * fontSize * 0.65 + 18)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        } else if coordinator.highlightID != document.highlightID {
            coordinator.highlightID = document.highlightID
            text.color(document.tokens)
        }
        if changed || coordinator.navigationID != navigationID {
            coordinator.navigationID = navigationID
            let range = document.range(line: location?.line ?? bookmark.line, column: location?.column)
            if location?.line != nil { text.select(documentRange: range) }
            if let top = text.lineTop(atUTF16Offset: range.location) {
                let point = NSPoint(x: location?.line == nil ? max(0, bookmark.horizontalOffset) : 0,
                                    y: max(0, top + (location?.line == nil ? bookmark.lineOffset : 0)))
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: point, size: scroll.contentView.bounds.size)).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            let id = navigationID
            DispatchQueue.main.async { onNavigated(id) }
        }
        coordinator.isApplying = false
        view.gutter.document = document
        view.gutter.needsDisplay = true
        if let request = focus?.request, request.target == .files {
            DispatchQueue.main.async { [weak text] in
                guard let text, let window = text.window, focus?.consume(request) == true else { return }
                window.makeFirstResponder(text)
            }
        }
    }

    static func dismantleNSView(_ view: WorkspaceFileContainer, coordinator: Coordinator) {
        coordinator.didScroll()
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        weak var scroll: NSScrollView?
        weak var gutter: FileLineNumberView?
        var document: WorkspaceFileDocument?
        var documentID: UUID?
        var fontSize: CGFloat?
        var highlightID: UUID?
        var navigationID: UUID?
        var isApplying = false
        var onBookmark: ((FileReadingBookmark) -> Void)?
        var onEdit: ((String) -> Void)?

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let text = notification.object as? WorkspaceFileTextView else { return }
            onEdit?(text.documentText)
        }

        @objc func didResize() { gutter?.needsDisplay = true }

        @objc func didScroll() {
            gutter?.needsDisplay = true
            guard !isApplying, let scroll, let document, let text = scroll.documentView as? WorkspaceFileTextView else { return }
            let origin = scroll.contentView.bounds.origin
            let value: FileReadingBookmark
            if document.utf16Length == 0 {
                value = FileReadingBookmark(line: 1, lineOffset: origin.y - text.textContainerOrigin.y, horizontalOffset: origin.x)
            } else {
                guard let line = text.line(atY: origin.y) else { return }
                value = FileReadingBookmark(line: document.line(atUTF16Offset: line.offset), lineOffset: origin.y - line.top,
                                            horizontalOffset: origin.x)
            }
            let callback = onBookmark
            DispatchQueue.main.async { callback?(value) }
        }
    }
}

/// The Files panel's text on TextKit 2, laid out where it is seen.
///
/// A file the panel edits (up to 2 MB) is the text storage whole; questions about where a line is go
/// to the layout fragments TextKit 2 has, and syntax colors go on the lines laid out for the
/// viewport as they come into view.
///
/// A read-only file (over 2 MB) is seen through a window: every line one height, a few thousand of
/// them in the text storage, drawn at their place in the file. Where any line is follows from its
/// number, and moving far moves the window. TextKit 2 otherwise reckons each paragraph's height on
/// its way to a far place, 3 s to the end of 430,000 lines.
final class WorkspaceFileTextView: NSTextView {
    private typealias Edit = (location: Int, removed: Int, inserted: Int)

    private struct LineWindow {
        let text: NSString
        let lineStarts: [Int]
        var first = 0
        var count = 0
        func start(_ line: Int) -> Int { line < lineStarts.count ? lineStarts[line] : text.length }
        var startOffset: Int { start(first) }
        var endOffset: Int { start(first + count) }
    }

    /// Lines above the viewport a new window starts with, the most lines and UTF-16 units it holds,
    /// and the fewest lines it holds however long they are.
    private static let windowLead = 200
    private static let windowLines = 4_000
    private static let windowUnits = 1 << 20
    private static let windowMinimum = 400

    private var lineWindow: LineWindow?
    private var lineHeight: CGFloat = 15
    private var attributes: [NSAttributedString.Key: Any] = [:]
    private var addsLineBreak = false
    private var isPrepared = false
    /// The colors by UTF-16 range, in order, for the text as it was when they were worked out.
    private var tokens: [TranscriptCodeSyntax.Token] = []
    /// The edits since then, in order, which move the colors along until new ones arrive.
    private var edits: [Edit] = []
    /// The UTF-16 offsets that already have `tokens`' colors in the text storage.
    private var colored = IndexSet()

    /// The file's length as the panel has it, without the line break `show(_:font:)` may add after
    /// the last line.
    var documentLength: Int { lineWindow?.text.length ?? shownLength }

    /// The storage's length without that line break. Read from the storage, so it is current while
    /// an edit moves the selection.
    private var shownLength: Int { (textStorage?.length ?? 0) - (addsLineBreak ? 1 : 0) }

    /// The inset, and in a window the place of its first line. `NSTextView` otherwise lays out the
    /// whole document to place a container wider than itself, 14 s for a 20 MB file.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: textContainerInset.height + CGFloat(lineWindow?.first ?? 0) * lineHeight)
    }

    /// The text as the file has it.
    var documentText: String {
        if let lineWindow { return lineWindow.text as String }
        return addsLineBreak ? (string as NSString).substring(to: shownLength) : string
    }

    func show(_ document: WorkspaceFileDocument, font: NSFont) {
        prepare()
        // One height for every line, Korean and emoji in other fonts too.
        lineHeight = ceil(font.ascender - font.descender + font.leading)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        attributes = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        tokens = document.tokens
        if document.isEditable {
            lineWindow = nil
            isVerticallyResizable = true
            minSize = .zero
            let text = document.text as NSString
            addsLineBreak = Self.needsLineBreak(text, range: NSRange(location: 0, length: text.length),
                                                lastLineStart: document.lineStarts.last ?? 0)
            textStorage?.setAttributedString(shownText(text, range: NSRange(location: 0, length: text.length)))
            colored = tokens.isEmpty ? IndexSet(integersIn: 0..<(textStorage?.length ?? 0)) : IndexSet()
        } else {
            lineWindow = LineWindow(text: document.text as NSString, lineStarts: document.lineStarts)
            isVerticallyResizable = false
            let height = 2 * textContainerInset.height + CGFloat(document.lineStarts.count) * lineHeight
            minSize = NSSize(width: 0, height: height)
            setFrameSize(NSSize(width: frame.width, height: height))
            place(around: 0)
        }
        edits = []
        needsLayout = true
    }

    /// `range` of `text` with the line break that keeps an unterminated long last line cheap.
    private func shownText(_ text: NSString, range: NSRange) -> NSAttributedString {
        let shown = NSMutableAttributedString(string: range.location == 0 && range.length == text.length ? text as String
                                                  : text.substring(with: range), attributes: attributes)
        if addsLineBreak { shown.append(NSAttributedString(string: "\n", attributes: attributes)) }
        return shown
    }

    /// Whether `range` ends the text with a long line that has no line break. `NSTextView` finds the
    /// end of such a line caret by caret whenever it lays out, seconds for a minified file; one more
    /// line break, never selected or edited, puts the end on an empty line instead.
    private static func needsLineBreak(_ text: NSString, range: NSRange, lastLineStart: Int) -> Bool {
        NSMaxRange(range) == text.length && text.length - lastLineStart > 1_024
            && ![10, 13].contains(text.character(at: text.length - 1))
    }

    // MARK: Window

    /// Puts the lines from a little above `line` into the text storage.
    private func place(around line: Int) {
        guard var lineWindow, let storage = textStorage else { return }
        let selection = documentSelection
        let first = max(0, min(line, lineWindow.lineStarts.count - 1) - Self.windowLead)
        var last = first
        let limit = lineWindow.start(first) + Self.windowUnits
        while last < lineWindow.lineStarts.count, last - first < Self.windowLines,
              last - first < Self.windowMinimum || lineWindow.start(last) < limit { last += 1 }
        lineWindow.first = first
        lineWindow.count = last - first
        self.lineWindow = lineWindow
        let range = NSRange(location: lineWindow.startOffset, length: lineWindow.endOffset - lineWindow.startOffset)
        addsLineBreak = Self.needsLineBreak(lineWindow.text, range: range, lastLineStart: lineWindow.lineStarts.last ?? 0)
        storage.setAttributedString(shownText(lineWindow.text, range: range))
        colored = IndexSet(integersIn: 0..<storage.length)
        select(documentRange: selection, placing: false)
        needsLayout = true
        needsDisplay = true
    }

    /// Moves the window when the viewport comes near its edge, before TextKit 2 lays out there.
    @objc private func followViewport() {
        guard let lineWindow, let clip = enclosingScrollView?.contentView else { return }
        let top = lineIndex(atY: clip.bounds.minY), bottom = lineIndex(atY: clip.bounds.maxY)
        let end = lineWindow.first + lineWindow.count
        if lineWindow.first > 0 && top < lineWindow.first + 50 || end < lineWindow.lineStarts.count && bottom >= end - 50 {
            place(around: top)
        }
    }

    private func lineIndex(atY y: CGFloat) -> Int {
        guard let lineWindow else { return 0 }
        return min(lineWindow.lineStarts.count - 1, max(0, Int(((y - textContainerInset.height) / lineHeight).rounded(.down))))
    }

    private func lineIndex(atUTF16Offset offset: Int) -> Int {
        guard let lineWindow else { return 0 }
        var low = 0, high = lineWindow.lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineWindow.lineStarts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    /// The selection in the file's offsets.
    private var documentSelection: NSRange {
        let range = selectedRange()
        guard let lineWindow else { return range }
        return NSRange(location: range.location + lineWindow.startOffset, length: range.length)
    }

    /// Selects `range` of the file, moving the window there first when it is elsewhere.
    func select(documentRange range: NSRange, placing: Bool = true) {
        guard let lineWindow else { return setSelectedRange(range) }
        if placing, range.location < lineWindow.startOffset || range.location > lineWindow.endOffset {
            place(around: lineIndex(atUTF16Offset: range.location))
        }
        guard let current = self.lineWindow else { return }
        let start = min(max(range.location, current.startOffset), current.endOffset)
        let end = min(max(NSMaxRange(range), start), current.endOffset)
        setSelectedRange(NSRange(location: start - current.startOffset, length: end - start))
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        if let clip = superview as? NSClipView {
            NotificationCenter.default.addObserver(self, selector: #selector(followViewport),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    override func scrollToBeginningOfDocument(_ sender: Any?) {
        guard lineWindow != nil else { return super.scrollToBeginningOfDocument(sender) }
        scrollTo(y: 0)
    }

    override func scrollToEndOfDocument(_ sender: Any?) {
        guard lineWindow != nil else { return super.scrollToEndOfDocument(sender) }
        scrollTo(y: frame.height)
    }

    override func moveToBeginningOfDocument(_ sender: Any?) {
        guard lineWindow != nil else { return super.moveToBeginningOfDocument(sender) }
        scrollTo(y: 0)
        select(documentRange: NSRange(location: 0, length: 0))
    }

    override func moveToEndOfDocument(_ sender: Any?) {
        guard lineWindow != nil else { return super.moveToEndOfDocument(sender) }
        scrollTo(y: frame.height)
        select(documentRange: NSRange(location: documentLength, length: 0))
    }

    private func scrollTo(y: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: Colors

    /// Colors the text again once an edit's colors were worked out: the lines in view now, the
    /// rest as they come into view.
    func color(_ tokens: [TranscriptCodeSyntax.Token]) {
        guard lineWindow == nil else { return }
        self.tokens = tokens
        edits = []
        colored = IndexSet()
        colorLinesInView()
    }

    override func layout() {
        super.layout()
        colorLinesInView()
    }

    private func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        NotificationCenter.default.addObserver(self, selector: #selector(storageDidProcessEditing),
                                               name: NSTextStorage.didProcessEditingNotification, object: textStorage)
    }

    /// An edit moves the colors with the text; what is typed keeps the color it was typed in.
    @objc private func storageDidProcessEditing() {
        guard lineWindow == nil, let storage = textStorage, storage.editedMask.contains(.editedCharacters) else { return }
        let range = storage.editedRange, change = storage.changeInLength
        let edit: Edit = (range.location, range.length - change, range.length)
        edits.append(edit)
        colored.shift(startingAt: edit.location + edit.removed, by: -edit.removed)
        colored.shift(startingAt: edit.location, by: edit.inserted)
        colored.insert(integersIn: edit.location..<(edit.location + edit.inserted))
    }

    /// Colors what TextKit 2 laid out for the viewport and is not colored yet.
    private func colorLinesInView() {
        guard lineWindow == nil, let storage = textStorage, let layout = textLayoutManager, let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let start = content.documentRange.location
        let lower = content.offset(from: start, to: viewport.location)
        let upper = min(storage.length, content.offset(from: start, to: viewport.endLocation))
        guard lower < upper else { return }
        let missing = IndexSet(integersIn: lower..<upper).subtracting(colored)
        guard !missing.isEmpty else { return }
        colored.formUnion(missing)
        storage.beginEditing()
        for range in missing.rangeView {
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor,
                                 range: NSRange(location: range.lowerBound, length: range.count))
            // The range in the text the colors were worked out for.
            let from = Self.before(range.lowerBound, edits), to = Self.before(range.upperBound, edits)
            var low = 0, high = tokens.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(tokens[middle].range) <= from { low = middle + 1 } else { high = middle }
            }
            for token in tokens[low...] {
                guard token.range.location < to else { break }
                guard let tokenStart = Self.after(token.range.location, edits),
                      let tokenEnd = Self.after(NSMaxRange(token.range), edits) else { continue }
                let first = max(tokenStart, range.lowerBound), last = min(tokenEnd, range.upperBound)
                guard first < last else { continue }
                storage.addAttribute(.foregroundColor, value: Self.color(token.kind), range: NSRange(location: first, length: last - first))
            }
        }
        storage.endEditing()
        // The new colors set those lines aside for layout again; lay them out before they are drawn.
        layout.textViewportLayoutController.layoutViewport()
    }

    /// Where an offset in the colored text is now, or nil inside text an edit replaced.
    private static func after(_ offset: Int, _ edits: [Edit]) -> Int? {
        var offset = offset
        for edit in edits {
            if offset >= edit.location + edit.removed { offset += edit.inserted - edit.removed }
            else if offset > edit.location { return nil }
        }
        return offset
    }

    /// Where an offset now was in the colored text.
    private static func before(_ offset: Int, _ edits: [Edit]) -> Int {
        var offset = offset
        for edit in edits.reversed() {
            if offset >= edit.location + edit.inserted { offset -= edit.inserted - edit.removed }
            else if offset > edit.location { offset = edit.location }
        }
        return offset
    }

    static func color(_ kind: TranscriptCodeSyntax.Kind) -> NSColor {
        switch kind {
        case .comment: .secondaryLabelColor
        case .string: .systemGreen
        case .keyword: .systemPurple
        case .number: .systemBlue
        }
    }

    // MARK: The added line break

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        guard addsLineBreak else { return super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting) }
        let length = shownLength
        let kept = ranges.map { value -> NSValue in
            let range = value.rangeValue, start = min(range.location, length)
            return NSValue(range: NSRange(location: start, length: min(NSMaxRange(range), length) - start))
        }
        super.setSelectedRanges(kept, affinity: affinity, stillSelecting: stillSelecting)
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard !addsLineBreak || affectedRanges.allSatisfy({ NSMaxRange($0.rangeValue) <= shownLength }) else { return false }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    // MARK: Where lines are

    /// The top of the line holding `offset`, in this view, laying out that line alone.
    func lineTop(atUTF16Offset offset: Int) -> CGFloat? {
        let origin = textContainerOrigin
        if lineWindow != nil { return textContainerInset.height + CGFloat(lineIndex(atUTF16Offset: offset)) * lineHeight }
        guard documentLength > 0 else { return origin.y }
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let atEnd = offset >= documentLength
        guard let location = content.location(content.documentRange.location, offsetBy: atEnd ? documentLength - 1 : offset)
        else { return nil }
        layout.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = layout.textLayoutFragment(for: location) else { return nil }
        let frame = fragment.layoutFragmentFrame
        // The empty line after a final line break.
        guard atEnd, !addsLineBreak, (string as NSString).character(at: documentLength - 1) == 10 else { return frame.minY + origin.y }
        if fragment.textLineFragments.count > 1, let extra = fragment.textLineFragments.last, extra.characterRange.length == 0 {
            return frame.minY + extra.typographicBounds.minY + origin.y
        }
        return frame.maxY + origin.y
    }

    /// Where the line at `y` in this view starts and its top.
    func line(atY y: CGFloat) -> (offset: Int, top: CGFloat)? {
        if let lineWindow {
            let line = lineIndex(atY: y)
            return (lineWindow.lineStarts[line], textContainerInset.height + CGFloat(line) * lineHeight)
        }
        let origin = textContainerOrigin
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y - origin.y))) else { return nil }
        let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        guard offset < max(1, documentLength) else { return nil }
        return (offset, fragment.layoutFragmentFrame.minY + origin.y)
    }

    /// Each line that starts within `rect`: its offset and its top in this view, the empty line
    /// after a final line break included.
    func enumerateLines(in rect: NSRect, _ body: (_ offset: Int, _ top: CGFloat) -> Void) {
        if let lineWindow {
            for line in lineIndex(atY: rect.minY)...lineIndex(atY: rect.maxY) {
                body(lineWindow.lineStarts[line], textContainerInset.height + CGFloat(line) * lineHeight)
            }
            return
        }
        let origin = textContainerOrigin
        guard documentLength > 0 else { return body(0, origin.y) }
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return }
        let start = content.documentRange.location
        let bottom = rect.maxY - origin.y
        // Without a laid-out line at the top, start from the viewport, never from the start of the file.
        guard let first = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, rect.minY - origin.y)))?.rangeInElement.location
                ?? layout.textViewportLayoutController.viewportRange?.location else { return }
        let endsWithLineBreak = !addsLineBreak && (string as NSString).character(at: documentLength - 1) == 10
        layout.enumerateTextLayoutFragments(from: first, options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let offset = content.offset(from: start, to: fragment.rangeInElement.location)
            guard frame.minY <= bottom, offset < documentLength else { return false }
            body(offset, frame.minY + origin.y)
            let end = content.offset(from: start, to: fragment.rangeInElement.endLocation)
            if endsWithLineBreak, end >= documentLength, fragment.textLineFragments.count > 1,
               let extra = fragment.textLineFragments.last, extra.characterRange.length == 0 {
                body(documentLength, frame.minY + extra.typographicBounds.minY + origin.y)
            }
            return true
        }
    }
}

final class WorkspaceFileContainer: NSView {
    let scroll: NSScrollView
    let gutter = FileLineNumberView()
    override var isFlipped: Bool { true }

    init(scroll: NSScrollView) {
        self.scroll = scroll
        super.init(frame: .zero)
        gutter.scrollView = scroll
        addSubview(scroll)
        addSubview(gutter)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        let scroll = scroll
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { (scroll.documentView as? NSTextView)?.releaseTextKitLayout() }
    }

    override func layout() {
        super.layout()
        let width = gutter.ruleThickness
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scroll.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        gutter.needsDisplay = true
    }
}

final class FileLineNumberView: NSView {
    weak var scrollView: NSScrollView?
    var ruleThickness: CGFloat = 42
    var document: WorkspaceFileDocument?
    var fontSize: CGFloat = 12
    override var isFlipped: Bool { true }

    override func draw(_ rect: NSRect) {
        guard let scroll = scrollView, let text = scroll.documentView as? WorkspaceFileTextView, let document else { return }
        let visible = scroll.contentView.bounds
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor
        ]
        text.enumerateLines(in: visible) { offset, top in
            let label = NSAttributedString(string: String(document.line(atUTF16Offset: offset)), attributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - label.size().width - 9, y: top - visible.minY))
        }
    }
}
