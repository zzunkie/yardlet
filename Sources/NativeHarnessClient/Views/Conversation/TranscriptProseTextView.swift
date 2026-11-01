import AppKit
import SwiftUI

/// A message's prose in one TextKit 2 text view (`TranscriptProseBuilder`), so a drag selects across
/// its paragraphs, lists, quotes and code blocks and copying gives the words as they read. The text is
/// selectable, not editable; links open through SwiftUI's `openURL`, as `Text`'s do.
struct TranscriptProseText: NSViewRepresentable {
    let blocks: [TranscriptProseBlock]
    /// The whole message, which a code block's Copy reads at click time.
    let fullSource: String
    let dialect: TranscriptMarkdownDialect
    let style: TranscriptProseStyle
    var find = TranscriptProseFind()
    /// "Copy item details" in the text's context menu (Codex's item handoff).
    var copyDetails: String?
    /// Find's key for all of the text, for a text find reads whole (a sent message's `.text`).
    var segmentKey: ConversationFindSegmentKey?
    /// The text is as wide as its longest line, up to what it is offered, as a sent message's bubble is.
    var fitsWidth = false

    func makeNSView(context: Context) -> TranscriptProseContainerView {
        TranscriptProseContainerView()
    }

    func updateNSView(_ view: TranscriptProseContainerView, context: Context) {
        let environment = context.environment
        view.fullSource = fullSource
        view.dialect = dialect
        view.openURL = environment.openURL
        view.opensLocalFiles = environment.transcriptOpensLocalFiles
        view.pauseFollowing = environment.pauseTranscriptFollowing
        view.textView.copyDetails = copyDetails
        view.segmentKey = segmentKey
        view.fitsWidth = fitsWidth
        let appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua)
        if view.appearance?.name != appearance?.name { view.appearance = appearance }
        let changed = view.update(blocks: blocks, style: style)
        view.update(find: find, contentChanged: changed)
        if changed { view.invalidateIntrinsicContentSize() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptProseContainerView, context: Context) -> CGSize? {
        nsView.size(forWidth: proposal.width)
    }
}

/// What find marks in one message's text: the query, the current match when it is in this message,
/// and the scroll request that went to it.
struct TranscriptProseFind: Equatable {
    var query: String?
    var active: ConversationFindLocation?
    var scrollToken: Int?
    /// The find, which says whether a request was already brought into view.
    var model: ConversationFindModel?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.query == rhs.query && lhs.active == rhs.active && lhs.scrollToken == rhs.scrollToken && lhs.model === rhs.model
    }
}

/// The text view and the controls over its code blocks.
final class TranscriptProseContainerView: ConversationFindCenteringView, NSTextViewDelegate {
    let textView = TranscriptProseTextView(usingTextLayoutManager: true)
    var fullSource = ""
    var dialect: TranscriptMarkdownDialect = .standard
    var openURL: OpenURLAction?
    /// The text's file links are on this Mac (`transcriptOpensLocalFiles`).
    var opensLocalFiles = true
    var pauseFollowing: () -> Void = {}
    var segmentKey: ConversationFindSegmentKey?
    var fitsWidth = false

    private struct Built {
        let block: TranscriptProseBlock
        let isFirst: Bool
        let isLast: Bool
        let piece: TranscriptProsePiece
    }

    private var built: [Built] = []
    /// What the items of the text's top-level lists were built into, for the blocks built next.
    private var listItems = TranscriptProseBuilder.ListItems()
    private var style: TranscriptProseStyle?
    private var segments: [TranscriptProsePiece.Segment] = []
    private var codeBlocks: [TranscriptProsePiece.CodeBlock] = []
    private var trailingInset: CGFloat = 0
    /// Heights and the longest line's width, by width, since the text last changed.
    private var sizes: [CGFloat: CGSize] = [:]
    /// The width the text was last laid out whole at, which its lines are placed for; nil once the
    /// text changed.
    private var wholeLayoutWidth: CGFloat?
    private var codeControls: [CodeControls] = []
    private var find = TranscriptProseFind()
    private var activeMatch: NSRange?
    private var findMarks: [(range: NSRange, color: NSColor)] = []
    private let fragments = TranscriptProseFragments()

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = false
        textView.usesFindPanel = false
        textView.isIncrementalSearchingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.displaysLinkToolTips = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.focusRingType = .none
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainer?.lineFragmentPadding = 0
        // The container's width is this view's to set (`layOutAtOwnWidth`): a width the text view
        // set as it joined a window or took its frame left the text laid out only where it showed.
        textView.textContainer?.widthTracksTextView = false
        textView.linkTextAttributes = [.foregroundColor: ParityTheme.accentColor, .cursor: NSCursor.pointingHand]
        textView.delegate = self
        textView.textLayoutManager?.delegate = fragments
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        let textView = textView
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { textView.releaseTextKitLayout() }
    }

    override var isFlipped: Bool { true }

    // MARK: - Content

    /// Builds again only the blocks that changed and replaces the text from the first paragraph that
    /// changed on, so a streaming message lays out and draws again only its end: a list is one block,
    /// and its items before the one being written are taken as they were built and stay as they were
    /// laid out. Returns whether the text changed.
    @discardableResult
    func update(blocks: [TranscriptProseBlock], style: TranscriptProseStyle) -> Bool {
        if style != self.style {
            self.style = style
            built = []
            listItems = .init()
            textView.textStorage?.setAttributedString(NSAttributedString())
        }
        let builder = TranscriptProseBuilder(style: style, listItems: listItems)
        var next: [Built] = []
        var firstChange: Int?
        for (index, block) in blocks.enumerated() {
            let isFirst = index == 0, isLast = index == blocks.count - 1
            if firstChange == nil, index < built.count, built[index].block == block, built[index].isLast == isLast {
                next.append(built[index])
                continue
            }
            if firstChange == nil { listItems.begin() }
            firstChange = firstChange ?? index
            next.append(Built(block: block, isFirst: isFirst, isLast: isLast,
                              piece: builder.piece(block, isFirst: isFirst, isLast: isLast)))
        }
        if blocks.count < built.count { firstChange = min(firstChange ?? blocks.count, blocks.count) }
        guard let start = firstChange, let storage = textView.textStorage else { return false }
        var offset = built.prefix(start).reduce(0) { $0 + $1.piece.text.length }
        let replacement = NSMutableAttributedString()
        for item in next[start...] { replacement.append(item.piece.text) }
        let kept = Self.unchangedParagraphsLength(of: storage, from: offset, in: replacement)
        replacement.deleteCharacters(in: NSRange(location: 0, length: kept))
        offset += kept
        let edit = {
            storage.replaceCharacters(in: NSRange(location: offset, length: storage.length - offset), with: replacement)
        }
        if let contentStorage = textView.textContentStorage {
            contentStorage.performEditingTransaction(edit)
        } else {
            edit()
        }
        built = next
        var location = 0
        segments = []
        codeBlocks = []
        for item in built {
            segments += item.piece.segments.map {
                .init(key: $0.key, range: NSRange(location: $0.range.location + location, length: $0.range.length), text: $0.text)
            }
            codeBlocks += item.piece.codeBlocks.map {
                .init(range: NSRange(location: $0.range.location + location, length: $0.range.length),
                      language: $0.language, path: $0.path, isTruncated: $0.isTruncated)
            }
            location += item.piece.text.length
        }
        trailingInset = built.last?.piece.trailingInset ?? 0
        if let segmentKey {
            segments = segments.map { .init(key: segmentKey, range: $0.range, text: $0.text) }
        }
        sizes = [:]
        wholeLayoutWidth = nil
        updateCodeControls()
        needsLayout = true
        textView.window?.invalidateCursorRects(for: textView)
        return true
    }

    /// How much `replacement` starts with of what `storage` holds from `offset` on, in whole paragraphs
    /// alike in their words and attributes. TextKit keeps those paragraphs' layout and drawing.
    private static func unchangedParagraphsLength(of storage: NSTextStorage, from offset: Int,
                                                  in replacement: NSAttributedString) -> Int {
        let old = storage.string as NSString, new = replacement.string as NSString
        var kept = 0
        while kept < new.length {
            let paragraph = new.paragraphRange(for: NSRange(location: kept, length: 0))
            let earlier = NSRange(location: offset + kept, length: paragraph.length)
            guard NSMaxRange(earlier) <= old.length,
                  old.paragraphRange(for: NSRange(location: earlier.location, length: 0)) == earlier,
                  storage.attributedSubstring(from: earlier).isEqual(to: replacement.attributedSubstring(from: paragraph))
            else { break }
            kept = NSMaxRange(paragraph)
        }
        return kept
    }

    // MARK: - Size

    /// The text's height at `width`, laid out whole.
    ///
    /// SwiftUI asks at other widths than the one the text shows at: a turn built outside the window is
    /// measured at its width and at the narrowest and widest it could take, and a window being
    /// resized at its next width. Measuring lays the text out at that width, so the text is laid out
    /// whole at its own width again before it draws (`layOutAtOwnWidth`): TextKit 2 would otherwise
    /// lay out again only the lines in view, placed after lines still laid out for the width measured
    /// last, and draw them higher or lower than the height its frame took — an empty band under a
    /// turn's answer, above the next request.
    ///
    /// Offered no width at all, as a window measures its smallest size, it answers without laying out:
    /// the text wraps to any width it is given, and a long message laid out whole at widths it never
    /// shows at, then at its own again, held the main thread for most of a second.
    func size(forWidth proposed: CGFloat?) -> CGSize {
        if let width = proposed, width <= 0 {
            return CGSize(width: 0, height: wholeLayoutWidth.flatMap { sizes[$0]?.height } ?? 0)
        }
        guard let width = proposed, width.isFinite else {
            let size = laidOut(atWidth: 100_000)
            layOutAtOwnWidthBeforeDrawing()
            return size
        }
        let size = laidOut(atWidth: width)
        layOutAtOwnWidthBeforeDrawing()
        return CGSize(width: fitsWidth ? min(width, size.width) : width, height: size.height)
    }

    /// The text's height and its longest line at `width`, laid out whole.
    private func laidOut(atWidth width: CGFloat) -> CGSize {
        if let size = sizes[width] { return size }
        guard let layout = textView.textLayoutManager, (textView.textStorage?.length ?? 0) > 0 else { return .zero }
        layOutWhole(atWidth: width)
        let usage = layout.usageBoundsForTextContainer
        let size = CGSize(width: ceil(usage.maxX), height: ceil(usage.height + trailingInset))
        sizes[width] = size
        return size
    }

    /// Lays the whole text out at `width`, the container's width from then on.
    private func layOutWhole(atWidth width: CGFloat) {
        guard let layout = textView.textLayoutManager, let container = textView.textContainer else { return }
        if container.size.width != width {
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
#if DEBUG
            newWidthLayouts += 1
#endif
        }
        guard wholeLayoutWidth != width else { return }
        layout.ensureLayout(for: layout.documentRange)
        wholeLayoutWidth = width
    }

    /// A measurement at another width than the view's own left the text laid out there.
    private func layOutAtOwnWidthBeforeDrawing() {
        if bounds.width > 0, wholeLayoutWidth != ownWidth { needsLayout = true }
    }

    /// The text laid out whole at the view's own width, where it draws.
    private func layOutAtOwnWidth() {
        guard bounds.width > 0, (textView.textStorage?.length ?? 0) > 0 else { return }
        layOutWhole(atWidth: ownWidth)
    }

    /// The width the text draws at: the view's, or the width it was measured at when its frame is that
    /// width rounded to the screen's pixels, whose height the frame took.
    private var ownWidth: CGFloat {
        let nearest = sizes.keys.min { abs($0 - bounds.width) < abs($1 - bounds.width) }
        guard let nearest, abs(nearest - bounds.width) < 1 else { return bounds.width }
        return nearest
    }

#if DEBUG
    /// How many times the text was laid out at a width other than its last, each time whole, for the tests.
    private(set) var newWidthLayouts = 0

    /// The height the text is laid out at now, which is what it draws, for the tests.
    var laidOutHeight: CGFloat {
        guard let layout = textView.textLayoutManager, (textView.textStorage?.length ?? 0) > 0 else { return 0 }
        return ceil(layout.usageBoundsForTextContainer.height + trailingInset)
    }
#endif

    override func layout() {
        super.layout()
        if textView.frame != bounds {
            textView.frame = bounds
            // The links' rects moved with the lines (`TranscriptProseTextView.resetCursorRects`).
            window?.invalidateCursorRects(for: textView)
        }
        layOutAtOwnWidth()
        if let layout = textView.textLayoutManager, !codeControls.isEmpty || activeMatch != nil {
            layout.ensureLayout(for: layout.documentRange)
        }
        layoutCodeControls()
    }

    // MARK: - Code block controls

    /// A code block's Copy over its frame's top row, and "View full code" under a long one.
    private final class CodeControls {
        var block: TranscriptProsePiece.CodeBlock
        let copy: NSHostingView<AnyView>
        let full: NSHostingView<AnyView>?

        init(block: TranscriptProsePiece.CodeBlock, copy: NSHostingView<AnyView>, full: NSHostingView<AnyView>?) {
            self.block = block
            self.copy = copy
            self.full = full
        }

        func remove() {
            copy.removeFromSuperview()
            full?.removeFromSuperview()
        }
    }

    private func updateCodeControls() {
        let same = codeControls.count == codeBlocks.count && zip(codeControls, codeBlocks).allSatisfy {
            $0.block.path == $1.path && $0.block.language == $1.language && $0.block.isTruncated == $1.isTruncated
        }
        if same {
            for (controls, block) in zip(codeControls, codeBlocks) { controls.block = block }
            return
        }
        codeControls.forEach { $0.remove() }
        codeControls = codeBlocks.map { block in
            let payload: () -> String? = { [weak self] in
                guard let self else { return nil }
                return TranscriptCopyPayload.code(in: fullSource, blockPath: block.path, dialect: dialect)
            }
            // The code text is in the text view, so the buttons of two blocks would read alike.
            let firstLine = (textView.string as NSString).substring(with: block.range)
                .split(whereSeparator: { $0 == "\u{2028}" || $0.isNewline }).first.map(String.init) ?? ""
            let detail = [block.language, firstLine.trimmingCharacters(in: .whitespaces)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            let copy = NSHostingView(rootView: AnyView(TranscriptCopyButton(
                title: L10n.string("Copy code"), detail: String(detail.prefix(80)), payload: payload)))
            addSubview(copy)
            var full: NSHostingView<AnyView>?
            if block.isTruncated {
                let view = NSHostingView(rootView: AnyView(TranscriptFullCodeButton(
                    language: block.language, scale: style?.scale ?? 1, payload: payload,
                    pauseFollowing: { [weak self] in self?.pauseFollowing() })))
                addSubview(view)
                full = view
            }
            return CodeControls(block: block, copy: copy, full: full)
        }
    }

    private func layoutCodeControls() {
        for controls in codeControls {
            guard let frame = codeFrame(controls.block) else {
                controls.copy.isHidden = true
                controls.full?.isHidden = true
                continue
            }
            controls.copy.isHidden = false
            let copySize = controls.copy.fittingSize
            controls.copy.frame = CGRect(
                x: frame.maxX - TranscriptProseMetrics.codePadding - copySize.width,
                y: frame.minY + (TranscriptProseMetrics.codeHeaderHeight - 1 - copySize.height) / 2,
                width: copySize.width, height: copySize.height)
            if let full = controls.full {
                full.isHidden = false
                let size = full.fittingSize
                full.frame = CGRect(
                    x: frame.minX, y: frame.maxY - TranscriptProseMetrics.codeFooterHeight
                        + (TranscriptProseMetrics.codeFooterHeight - size.height) / 2,
                    width: size.width, height: size.height)
            }
        }
    }

    // MARK: - What is under a point

    /// The whole of the code block drawn at `point` (in this view), for the menu's "Copy code".
    func code(at point: CGPoint) -> String? {
        guard let block = codeBlocks.first(where: { codeFrame($0)?.contains(point) == true }) else { return nil }
        return TranscriptCopyPayload.code(in: fullSource, blockPath: block.path, dialect: dialect)
    }

    /// The link drawn at `point` (in this view).
    func link(at point: CGPoint) -> URL? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        var found: URL?
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let value, let rect = rect(of: range), rect.insetBy(dx: -2, dy: -2).contains(point),
                  rects(of: range).contains(where: { $0.insetBy(dx: -2, dy: -2).contains(point) }) else { return }
            found = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            stop.pointee = true
        }
        return found
    }

    /// The message as its Copy gives it: a Codex message without its directives' markup.
    var messageText: String { dialect.copyText(fullSource) }

    /// Where `range` is drawn, a rectangle per line, in this view.
    private func rects(of range: NSRange) -> [CGRect] {
        guard let layout = textView.textLayoutManager, let textRange = textRange(range) else { return [] }
        var rects: [CGRect] = []
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            rects.append(frame)
            return true
        }
        return rects
    }

    /// A code block's frame in this view.
    private func codeFrame(_ block: TranscriptProsePiece.CodeBlock) -> CGRect? {
        guard let fragment = fragment(at: block.range.location) as? TranscriptProseFragment,
              let box = fragment.codeBox else { return nil }
        return box.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
    }

    private func fragment(at offset: Int) -> NSTextLayoutFragment? {
        guard let layout = textView.textLayoutManager, let location = location(offset) else { return nil }
        return layout.textLayoutFragment(for: location)
    }

    private func location(_ offset: Int) -> NSTextLocation? {
        guard let content = textView.textContentStorage else { return nil }
        return content.location(content.documentRange.location, offsetBy: offset)
    }

    private func textRange(_ range: NSRange) -> NSTextRange? {
        guard let start = location(range.location), let content = textView.textContentStorage,
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    // MARK: - Find

    /// Marks every hit of the query yellow and the current one orange, as `ConversationFindStyle`
    /// marks a `Text`, without laying the text out again; and brings the current one to the middle of
    /// the conversation when a find request goes to it.
    func update(find: TranscriptProseFind, contentChanged: Bool) {
        let previous = self.find
        self.find = find
        guard contentChanged || find.query != previous.query || find.active != previous.active else {
            scrollToActiveMatchIfAsked()
            return
        }
        let query = find.query.flatMap { $0.isEmpty ? nil : $0 }
        // Nothing to mark and nothing marked: a streamed fragment leaves the marks alone.
        guard query != nil || !findMarks.isEmpty || conversationSelection != nil else { return }
        activeMatch = nil
        findMarks = []
        if let query {
            let isDark = style?.isDark ?? false
            for segment in segments {
                let hits = ConversationFindEngine.occurrences(of: query, in: segment.text)
                for (occurrence, hit) in hits.enumerated() {
                    let range = NSRange(location: segment.range.location + hit.location, length: hit.length)
                    guard NSMaxRange(range) <= NSMaxRange(segment.range) else { continue }
                    let isActive = find.active == ConversationFindLocation(key: segment.key, occurrence: occurrence)
                    if isActive { activeMatch = range }
                    findMarks.append((range, isActive ? ConversationFindStyle.activeNSColor(isDark: isDark)
                                                      : ConversationFindStyle.matchNSColor(isDark: isDark)))
                }
            }
        }
        paintBackgrounds()
        scrollToActiveMatchIfAsked()
    }

    /// The part of this text a selection across the conversation covers (`ConversationSelection`),
    /// painted as a selection is, in every text it covers alike.
    var conversationSelection: NSRange? {
        didSet { if conversationSelection != oldValue { paintBackgrounds() } }
    }

    /// A text back in a window after the selection it held part of was dropped shows none of it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, conversationSelection != nil, !ConversationSelection.spans(textView) {
            conversationSelection = nil
        }
        if window != nil { ConversationSelection.logPresses() }
    }

    /// Repaints find's marks and the conversation's selection as the text's backgrounds, without laying
    /// it out again.
    ///
    /// TextKit 2 draws the lines in views of the text view's own, which a change of rendering
    /// attributes leaves as they were drawn, and marking the text view for display does not reach
    /// them; each is marked. 2026-10-25: a drag selected but the window showed none of it, or a part a
    /// caret had made drawn again, while a render of the view (`cacheDisplay`, drawing it all afresh)
    /// showed it.
    func paintBackgrounds() {
        guard let layout = textView.textLayoutManager else { return }
        layout.removeRenderingAttribute(.backgroundColor, for: layout.documentRange)
        for (range, color) in findMarks {
            if let textRange = textRange(range) { layout.addRenderingAttribute(.backgroundColor, value: color, for: textRange) }
        }
        if let selection = conversationSelection, selection.length > 0, let textRange = textRange(selection) {
            layout.addRenderingAttribute(.backgroundColor, value: ConversationSelection.color(in: window), for: textRange)
        }
        layout.textViewportLayoutController.layoutViewport()
        func display(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(display)
        }
        display(textView)
    }

    private func scrollToActiveMatchIfAsked() {
        guard activeMatch != nil, let token = find.scrollToken, let model = find.model, model.claimCentering(token)
        else { return }
        centerSoon(for: token, in: model) { [weak self] in
            guard let self, let activeMatch, let rect = rect(of: activeMatch) else { return nil }
            return convert(rect, to: nil)
        }
    }

    /// Where `range` is drawn, in this view.
    func rect(of range: NSRange) -> CGRect? {
        guard let layout = textView.textLayoutManager, let textRange = textRange(range) else { return nil }
        layout.ensureLayout(for: textRange)
        var union: CGRect?
        layout.enumerateTextSegments(in: textRange, type: .highlight, options: []) { _, frame, _, _ in
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        return union
    }

    /// Opens `url` as a click on it does: through SwiftUI's `openURL`, which shows a file in the
    /// task's files.
    func open(_ url: URL) {
        guard opensLocalFiles || !url.isFileURL else { return }
        if let openURL { openURL(url) } else { NSWorkspace.shared.open(url) }
    }

    // MARK: - Delegates

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        open(url)
        return true
    }
}

/// Gives a decorated paragraph (`TranscriptProseDecoration`) the fragment that draws it.
final class TranscriptProseFragments: NSObject, NSTextLayoutManagerDelegate {
    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                                       textLayoutFragmentFor location: any NSTextLocation,
                                       in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let decoration = paragraph.attributedString.attribute(.transcriptDecoration, at: 0, effectiveRange: nil)
               as? TranscriptProseDecoration {
            return TranscriptProseFragment(textElement: textElement, range: textElement.elementRange, decoration: decoration)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// The text view: plain-text copies that read as the text does, the message's own menu item, and no
/// selection left behind once it gives up focus.
final class TranscriptProseTextView: NSTextView {
    var copyDetails: String?

    /// A copy gives plain text: list markers as "1. " and lines as lines, without the frame's colours,
    /// which a rich copy of dark text would carry into a light document.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else { return super.writeSelection(to: pboard, type: type) }
        // A selection that runs on into other messages copies all of them, in reading order.
        if ConversationSelection.spans(self) { return pboard.setString(ConversationSelection.text, forType: .string) }
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        return pboard.setString(TranscriptProseCopy.text(of: storage, in: ranges), forType: .string)
    }

    /// Copy, from the keyboard or the menu, copies a selection across the conversation when this text
    /// holds part of it; the text's own selection is empty then.
    override func copy(_ sender: Any?) {
        guard ConversationSelection.spans(self) else { return super.copy(sender) }
        TranscriptClipboard.copy(ConversationSelection.text)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)), ConversationSelection.spans(self) { return true }
        return super.validateUserInterfaceItem(item)
    }

    /// Selectable as a `Text` is, not a stop for Tab: keyboard focus moves between the conversation's
    /// controls.
    override var canBecomeKeyView: Bool { false }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, ConversationSelection.spans(self) {
            ConversationSelection.clear()
            if ConversationSelection.logHandle.isEnabled(type: .debug) {
                // The responder taking focus is the window's once this returns.
                DispatchQueue.main.async { [weak window] in
                    ConversationSelection.log.debug("""
                        selection dropped: its text gave up focus to \
                        \(ConversationSelection.name(window?.firstResponder), privacy: .public)
                        """)
                }
            }
        } else if resigned, selectedRange().length > 0 {
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        }
        return resigned
    }

    /// A press here selects in the conversation (`ConversationSelection`): a drag runs on into the
    /// other messages, a double or triple click takes a word or a paragraph and a drag from it goes on
    /// by words or paragraphs, and a shift-click extends the selection. A click on a link and a press
    /// with Command, Option or Control are the text's own.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        let onLink = event.clickCount == 1 && modifiers.isEmpty && linkRects().contains { $0.contains(point) }
        let inScrollView = enclosingScrollView != nil
        guard modifiers.isEmpty || modifiers == .shift, !onLink, inScrollView else {
            ConversationSelection.log.debug("""
                press in a text left to the text: modifiers \(modifiers.rawValue, privacy: .public), \
                link \(onLink, privacy: .public), in a scroll view \(inScrollView, privacy: .public)
                """)
            // A control-click opens the menu, whose Copy copies the selection, as a right click does.
            if !modifiers.contains(.control) { ConversationSelection.clear() }
            super.mouseDown(with: event)
            return
        }
        ConversationSelection.track(from: self, with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if let menu, let container = superview as? TranscriptProseContainerView {
            let point = container.convert(event.locationInWindow, from: nil)
            let items = TranscriptProseMenu.items(code: container.code(at: point), link: container.link(at: point),
                                                  message: container.messageText, container: container)
            // The text's own link items give way to the conversation's, which also open in the task.
            if container.link(at: point) != nil {
                for item in menu.items where TranscriptProseMenu.isTextLinkItem(item) { menu.removeItem(item) }
            }
            for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
            if !items.isEmpty, menu.items.count > items.count { menu.insertItem(.separator(), at: items.count) }
        }
        if let copyDetails, let menu {
            menu.addItem(.separator())
            let item = NSMenuItem(title: L10n.string("Copy item details"), action: #selector(copyItemDetails(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = copyDetails
            menu.addItem(item)
        }
        return menu
    }

    @objc private func copyItemDetails(_ sender: NSMenuItem) {
        TranscriptClipboard.copy(sender.representedObject as? String)
    }

    // MARK: - Link cursor

    /// The pointing hand over a link. The TextKit 2 text view declares one cursor rect, its I-beam,
    /// and answers a cursor update with it over links too (2026-10-22: no rect for the links'
    /// `.cursor`, under either layout system), so the links' rects are declared here, as SwiftUI
    /// declares `.pointerStyle`, and an update over one shows the hand. Nothing runs while the
    /// pointer moves inside a rect.
    override func resetCursorRects() {
        super.resetCursorRects()
        let visible = visibleRect
        for rect in linkRects() where rect.intersects(visible) {
            addCursorRect(rect.intersection(visible), cursor: .pointingHand)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if linkRects().contains(where: { $0.contains(point) }) {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    /// Where the text's links are drawn, in this view: a rect per line a link spans.
    func linkRects() -> [CGRect] {
        guard let storage = textStorage, storage.length > 0, let layout = textLayoutManager,
              let content = textContentStorage else { return [] }
        let origin = textContainerOrigin
        var rects: [CGRect] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil, let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            layout.ensureLayout(for: textRange)
            layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                if !frame.isEmpty { rects.append(frame.offsetBy(dx: origin.x, dy: origin.y)) }
                return true
            }
        }
        return rects
    }
}

enum TranscriptProseCopy {
    /// The selected text as it reads: a list marker and its tab as "1. " (indented by its depth), a
    /// line break as a newline, a rule as nothing.
    static func text(of storage: NSAttributedString, in ranges: [NSRange]) -> String {
        ranges.map { range -> String in
            var text = ""
            storage.enumerateAttribute(.transcriptCopyText, in: range) { value, run, _ in
                if let replacement = value as? String {
                    text += replacement
                } else {
                    text += (storage.string as NSString).substring(with: run)
                }
            }
            return text.replacingOccurrences(of: "\u{2028}", with: "\n")
        }
        .joined(separator: "\n")
    }
}

/// A paragraph's layout fragment that also draws its code block's frame, its quotes' bars or its rule
/// behind the text.
final class TranscriptProseFragment: NSTextLayoutFragment {
    let decoration: TranscriptProseDecoration

    init(textElement: NSTextElement, range: NSTextRange?, decoration: TranscriptProseDecoration) {
        self.decoration = decoration
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// The code block's frame, in the fragment's coordinates: its header row above the first line and
    /// its padding, and "View full code" below a long block's last.
    var codeBox: CGRect? {
        guard let code = decoration.code, let first = textLineFragments.first, let last = textLineFragments.last
        else { return nil }
        let top = first.typographicBounds.minY - TranscriptProseMetrics.codePadding - TranscriptProseMetrics.codeHeaderHeight
        let bottom = last.typographicBounds.maxY + TranscriptProseMetrics.codePadding
            + (code.isTruncated ? TranscriptProseMetrics.codeFooterHeight : 0)
        return CGRect(x: decoration.indent - layoutFragmentFrame.minX, y: top,
                      width: max(0, containerWidth - decoration.indent), height: bottom - top)
    }

    private var quoteBarRects: [CGRect] {
        guard let first = textLineFragments.first, let last = textLineFragments.last else { return [] }
        let box = codeBox
        return decoration.quoteBars.map { bar in
            let top = bar.startsHere ? (box?.minY ?? first.typographicBounds.minY) : 0
            let bottom = bar.endsHere ? (box?.maxY ?? last.typographicBounds.maxY) : layoutFragmentFrame.height
            return CGRect(x: bar.x - layoutFragmentFrame.minX, y: top, width: TranscriptProseMetrics.quoteBarWidth,
                          height: max(0, bottom - top))
        }
    }

    private var ruleRect: CGRect? {
        guard decoration.isRule, let line = textLineFragments.first else { return nil }
        return CGRect(x: decoration.indent - layoutFragmentFrame.minX, y: line.typographicBounds.midY - 0.5,
                      width: max(0, containerWidth - decoration.indent), height: 1)
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if let codeBox { bounds = bounds.union(codeBox.insetBy(dx: -1, dy: -1)) }
        for bar in quoteBarRects { bounds = bounds.union(bar) }
        if let ruleRect { bounds = bounds.union(ruleRect) }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let appearance = textLayoutManager?.textContainer?.textView?.effectiveAppearance ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            context.saveGState()
            context.translateBy(x: point.x, y: point.y)
            drawDecoration(in: context)
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }

    private func drawDecoration(in context: CGContext) {
        if let box = codeBox, let code = decoration.code {
            let fill = NSColor.labelColor.withAlphaComponent(0.035).cgColor
            let line = NSColor.labelColor.withAlphaComponent(0.10).cgColor
            let path = CGPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerWidth: TranscriptProseMetrics.codeCornerRadius,
                              cornerHeight: TranscriptProseMetrics.codeCornerRadius, transform: nil)
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.setFillColor(fill)
            context.fill(box)
            // The header row is a shade darker, with a rule under it, as `TranscriptCodeBlock` drew it.
            let header = CGRect(x: box.minX, y: box.minY, width: box.width, height: TranscriptProseMetrics.codeHeaderHeight - 1)
            context.fill(header)
            context.setFillColor(NSColor.separatorColor.cgColor)
            context.fill(CGRect(x: box.minX, y: header.maxY, width: box.width, height: 1))
            if code.isTruncated {
                context.fill(CGRect(x: box.minX, y: box.maxY - TranscriptProseMetrics.codeFooterHeight, width: box.width, height: 1))
            }
            context.restoreGState()
            context.addPath(path)
            context.setStrokeColor(line)
            context.setLineWidth(1)
            context.strokePath()
            let label = NSAttributedString(string: code.language, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .mini) + 1, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            let size = label.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            label.draw(at: CGPoint(x: box.minX + TranscriptProseMetrics.codePadding, y: box.minY + (header.height - size.height) / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        if !decoration.quoteBars.isEmpty {
            context.setFillColor(NSColor.labelColor.withAlphaComponent(0.12).cgColor)
            for bar in quoteBarRects {
                context.addPath(CGPath(roundedRect: bar, cornerWidth: 1, cornerHeight: 1, transform: nil))
                context.fillPath()
            }
        }
        if let ruleRect {
            context.setFillColor(NSColor.separatorColor.cgColor)
            context.fill(ruleRect)
        }
    }
}

/// "View full code" under a long code block, which opens the whole block in a sheet.
private struct TranscriptFullCodeButton: View {
    let language: String?
    let scale: CGFloat
    let payload: () -> String?
    let pauseFollowing: () -> Void
    @State private var fullCode: FullCode?
    @State private var focusBookmark: WindowFocusBookmark?

    private struct FullCode: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        Button(L10n.string("View full code")) {
            guard let text = payload() else { return }
            focusBookmark = WindowFocusBookmark(window: NSApp.keyWindow)
            pauseFollowing()
            fullCode = FullCode(text: text)
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .font(.caption)
        .padding(10)
        .sheet(item: $fullCode, onDismiss: {
            focusBookmark?.restore()
            focusBookmark = nil
        }) { code in
            TranscriptFullCodeSheet(language: language, text: code.text, fontSize: 12.5 * scale) { fullCode = nil }
        }
    }
}

/// The conversation's items at the top of a message's menu, as the Claude and Codex apps put them
/// there: "Copy code" over a code block; over a web link, which a click opens in the task's browser
/// (decision of 2026-10-22: the Yardlet browser is the default), open it in the default browser and
/// copy it; over a file link, open it in the task's files, show it in Finder and copy its path (only
/// the path for a file on another computer, `transcriptOpensLocalFiles`); and
/// "Copy message" for the whole message.
@MainActor
enum TranscriptProseMenu {
    static func items(code: String?, link: URL?, message: String, container: TranscriptProseContainerView) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let code {
            items.append(item(L10n.string("Copy code")) { TranscriptClipboard.copy(code) })
        }
        if let link {
            if link.isFileURL {
                // A file on another computer is named, not opened or shown here.
                if container.opensLocalFiles {
                    items.append(item(L10n.string("Open file")) { [weak container] in container?.open(link) })
                    items.append(item(L10n.string("Reveal in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([link])
                    })
                }
                items.append(item(L10n.string("Copy path")) { TranscriptClipboard.copy(link.path(percentEncoded: false)) })
            } else {
                if ConversationLinkRoute(link) == .taskBrowser {
                    items.append(item(L10n.string("Open in default browser")) { OutsideBrowser.open(link) })
                }
                items.append(item(L10n.string("Copy link")) { TranscriptClipboard.copy(link.absoluteString) })
            }
        }
        if !message.isEmpty {
            items.append(item(L10n.string("Copy message")) { TranscriptClipboard.copy(message) })
        }
        return items
    }

    /// The text system's own "Open Link" and "Copy Link", which the conversation's items replace.
    static func isTextLinkItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        return ["openLink:", "copyLink:", "_openLinkFromMenu:", "_copyLinkFromMenu:"].contains(NSStringFromSelector(action))
    }

    private static func item(_ title: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(TranscriptProseMenuTarget.runMenuAction(_:)), keyEquivalent: "")
        let target = TranscriptProseMenuTarget(action)
        item.target = target
        item.representedObject = target
        return item
    }
}

/// A menu item's action, kept alive by the item.
final class TranscriptProseMenuTarget: NSObject {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @MainActor @objc func runMenuAction(_ sender: Any?) {
        action()
    }
}
