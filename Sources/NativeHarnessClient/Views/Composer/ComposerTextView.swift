import AppKit
import SwiftUI

/// How the composer's text looks: its size, its face, the theme's text color and bash mode's plain
/// monospaced text.
struct ComposerTextStyle: Equatable {
    var scale: CGFloat = 1
    var font = InterfaceFont.system
    var codeFont = YardletCodeFont.standard
    var text: ThemeRGB?
    var isBashMode = false
    /// Markdown shows as it is typed: lists hang, marks dim and bold reads bold. Off in bash mode.
    var showsMarkdown: Bool { !isBashMode }

    var size: CGFloat { (isBashMode ? 13 : ParityType.body.size) * scale }

    @MainActor var bodyFont: NSFont {
        isBashMode ? .monospacedSystemFont(ofSize: size, weight: .regular) : font.font(size: size)
    }

    /// The first line's baseline from the field's top, which the bash badge beside it lines up with.
    @MainActor var firstBaseline: CGFloat {
        Self.layout.defaultBaselineOffset(for: bodyFont)
    }

    @MainActor private static let layout = NSLayoutManager()
}

/// What the composer's text field asks of the composer around it. Each runs with no input method
/// composing unless it says otherwise.
@MainActor
struct ComposerTextActions {
    /// A key the text has not handled yet: true when the composer used it.
    var key: (NSEvent, ComposerMarkdownTextView) -> Bool = { _, _ in false }
    /// A key pressed while an input method composes, which the input method handles first.
    var composingKey: (NSEvent) -> Void = { _ in }
    /// A line break the input method passed on after committing its composition, or one the field was
    /// asked for: true when the composer took it (to send, say) instead of a line.
    var newline: () -> Bool = { false }
}

/// The composer's text: an AppKit text view that shows its Markdown as it is typed (`ComposerMarkdownStyler`),
/// carries lists on with Return, Tab and Backspace (`ComposerMarkdown`), and grows from its least lines to its
/// most, then scrolls. The draft holds only what is typed; an input method's composition stays in the view
/// until it is committed.
struct ComposerTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let accessibilityHint: String?
    let style: ComposerTextStyle
    let lineLimit: ClosedRange<Int>
    let minHeight: CGFloat?
    let actions: ComposerTextActions

    func makeCoordinator() -> ComposerTextController { ComposerTextController() }

    func makeNSView(context: Context) -> ComposerTextScrollView {
        let controller = context.coordinator
        let scroll = ComposerTextScrollView(controller: controller)
        controller.text = $text
        controller.actions = actions
        controller.lineLimit = lineLimit
        controller.minHeight = minHeight
        controller.apply(style: style)
        controller.textView.placeholder = placeholder
        controller.replaceText(with: text)
        controller.setEnabled(context.environment.isEnabled)
        return scroll
    }

    func updateNSView(_ scroll: ComposerTextScrollView, context: Context) {
        let controller = context.coordinator
        let textView = controller.textView
        controller.text = $text
        controller.actions = actions
        if controller.lineLimit != lineLimit || controller.minHeight != minHeight {
            controller.lineLimit = lineLimit
            controller.minHeight = minHeight
            scroll.invalidateIntrinsicContentSize()
        }
        controller.apply(style: style)
        if textView.placeholder != placeholder { textView.placeholder = placeholder }
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHint)
        // The draft changed from outside the field (a chosen command, a sent message): the field shows
        // it. Its own typing reached the draft already, and a composition in progress is left alone.
        if !textView.hasMarkedText(), !textView.string.utf16.elementsEqual(text.utf16) {
            controller.replaceText(with: text)
        }
        controller.setEnabled(context.environment.isEnabled)
    }

    /// As wide as offered, as a text field is; with no width offered, as wide as its longest line.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerTextScrollView, context: Context) -> CGSize? {
        let controller = context.coordinator
        guard let width = proposal.width, width.isFinite else {
            let ideal = controller.idealWidth
            return CGSize(width: ideal, height: controller.height(forWidth: ideal))
        }
        return CGSize(width: width, height: controller.height(forWidth: width))
    }
}

/// The text view's scroll view, which grows with its text up to the most lines and only then shows a
/// scroller: a scroller that showed while the text grew would narrow it, wrap it again and make the
/// composer jump a line too tall and back.
final class ComposerTextScrollView: NSScrollView {
    let controller: ComposerTextController

    init(controller: ComposerTextController) {
        self.controller = controller
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = false
        autohidesScrollers = true
        verticalScrollElasticity = .automatic
        documentView = controller.textView
        controller.scrollView = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let isFull = newSize.height >= controller.maxHeight - 0.5
        if hasVerticalScroller != isFull { hasVerticalScroller = isFull }
        controller.textView.minSize = NSSize(width: 0, height: contentSize.height)
        if controller.textView.frame.height < contentSize.height {
            controller.textView.setFrameSize(NSSize(width: controller.textView.frame.width, height: contentSize.height))
        }
    }
}

/// The text view's delegate and the composer's hold on it: the draft, the look and the edits.
@MainActor
final class ComposerTextController: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    let textView: ComposerMarkdownTextView
    weak var scrollView: ComposerTextScrollView?
    var text: Binding<String>?
    var actions = ComposerTextActions()
    var lineLimit: ClosedRange<Int> = 1...8
    var minHeight: CGFloat?
    private(set) var styler = ComposerMarkdownStyler(style: ComposerTextStyle())
    /// The composer's own undo, so the window's undo never reaches into a draft that changed under it.
    private let undo = UndoManager()
    /// The text the last edits touched, restyled once no input method composes.
    private var pendingStyle: NSRange?
    private var isStyling = false
    /// How many fence lines the text holds, so an edit that makes or unmakes one restyles what follows.
    private var fenceCount = 0
    /// A second layout of the same text at the width SwiftUI proposes, so measuring never moves the
    /// text the person sees.
    private let measuring = NSLayoutManager()
    private let measuringContainer = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))

    override init() {
        textView = ComposerMarkdownTextView()
        super.init()
        textView.controller = self
        textView.delegate = self
        textView.textStorage?.delegate = self
        measuringContainer.lineFragmentPadding = 0
        measuring.addTextContainer(measuringContainer)
        measuring.allowsNonContiguousLayout = false
        textView.textStorage?.addLayoutManager(measuring)
        install()
    }

    // MARK: - Size

    var lineHeight: CGFloat {
        measuring.defaultLineHeight(for: styler.baseFont)
    }

    var minimumHeight: CGFloat {
        max(minHeight ?? 0, CGFloat(lineLimit.lowerBound) * lineHeight).rounded(.up)
    }

    var maxHeight: CGFloat {
        max(minimumHeight, (CGFloat(lineLimit.upperBound) * lineHeight).rounded(.up))
    }

    /// The longest line's width, or the placeholder's in an empty field.
    var idealWidth: CGFloat {
        let shown = textView.string.isEmpty ? textView.placeholder : textView.string
        let longest = shown.split(separator: "\n", omittingEmptySubsequences: false).lazy
            .map { NSAttributedString(string: String($0), attributes: self.styler.baseAttributes).size().width }
            .max() ?? 0
        return ceil(longest) + 2 * textView.textContainerInset.width + 1
    }

    /// The text's height at `width`, between the least lines and the most.
    func height(forWidth width: CGFloat) -> CGFloat {
        let inset = textView.textContainerInset
        let textWidth = max(1, width - 2 * inset.width)
        // Past the most lines the height is the most lines', so the measuring stops there rather than
        // laying out a long draft whole on every keystroke.
        let size = NSSize(width: textWidth, height: maxHeight + lineHeight)
        if measuringContainer.size != size { measuringContainer.size = size }
        measuring.ensureLayout(for: measuringContainer)
        var used = measuring.usedRect(for: measuringContainer).maxY
        used = max(used, measuring.extraLineFragmentRect.maxY)
        return min(max((used + 2 * inset.height).rounded(.up), minimumHeight), maxHeight)
    }

    // MARK: - Text

    /// A disabled composer (`.disabled`, which reaches AppKit views only through the environment) takes no
    /// typing, and lets go of the keyboard.
    func setEnabled(_ enabled: Bool) {
        guard textView.isEditable != enabled else { return }
        textView.isEditable = enabled
        textView.isSelectable = enabled
        // At once, as a disabled text field ends its editing.
        guard !enabled, let window = textView.window, window.firstResponder === textView else { return }
        window.makeFirstResponder(nil)
    }

    func apply(style: ComposerTextStyle) {
        guard styler.style != style else { return }
        styler = ComposerMarkdownStyler(style: style)
        install()
    }

    private func install() {
        textView.font = styler.baseFont
        textView.placeholderFont = styler.baseFont
        textView.markdownEditing = styler.style.showsMarkdown
        textView.typingAttributes = styler.baseAttributes
        textView.insertionPointColor = styler.textColor
        restyle(NSRange(location: 0, length: textView.textStorage?.length ?? 0))
        scrollView?.invalidateIntrinsicContentSize()
    }

    /// Shows `text` in place of what the field shows, with the caret at its end, as a text field does
    /// when its value is set.
    func replaceText(with text: String) {
        guard let storage = textView.textStorage else { return }
        isStyling = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                  with: NSAttributedString(string: text, attributes: styler.baseAttributes))
        storage.endEditing()
        isStyling = false
        pendingStyle = nil
        fenceCount = ComposerMarkdownSpans.fenceLineCount(in: storage.string as NSString)
        restyle(NSRange(location: 0, length: storage.length))
        undo.removeAllActions()
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        textView.textReplaced()
        scrollView?.invalidateIntrinsicContentSize()
    }

    /// Puts an edit through the text view, so undo and the delegate see it as typing.
    /// Each is its own undo step.
    func perform(_ edit: ComposerMarkdown.Edit) {
        textView.breakUndoCoalescing()
        defer { textView.breakUndoCoalescing() }
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement),
              let storage = textView.textStorage else { return }
        storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement,
                                                                          attributes: styler.baseAttributes))
        textView.didChangeText()
        textView.setSelectedRange(edit.selection)
        textView.scrollRangeToVisible(edit.selection)
    }

    /// Once no input method composes: restyles what changed and gives the draft the committed text. A
    /// composition committed by a click elsewhere or a send (`unmarkText`) changes the text without
    /// `textDidChange`.
    func compositionEnded() {
        guard !textView.hasMarkedText() else { return }
        restylePending()
        syncDraft()
    }

    private func syncDraft() {
        let string = textView.string
        if let text, !text.wrappedValue.utf16.elementsEqual(string.utf16) { text.wrappedValue = string }
    }

    private func restylePending() {
        guard let range = pendingStyle else { return }
        pendingStyle = nil
        restyle(range)
    }

    private func restyle(_ range: NSRange) {
        guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        isStyling = true
        styler.apply(to: storage, in: NSRange(location: clamped.location, length: clamped.length))
        isStyling = false
        textView.typingAttributes = styler.typingAttributes(in: storage, at: textView.selectedRange().location)
    }

    // MARK: - NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard !isStyling, editedMask.contains(.editedCharacters) else { return }
        var range = editedRange
        // A fence opened or closed changes every line after it.
        let string = textStorage.string as NSString
        let fences = ComposerMarkdownSpans.fenceLineCount(in: string)
        if fences != fenceCount {
            fenceCount = fences
            let paragraph = string.paragraphRange(for: range)
            range = NSRange(location: paragraph.location, length: textStorage.length - paragraph.location)
        }
        if let pending = pendingStyle {
            var earlier = pending
            if earlier.location > editedRange.location { earlier.location = max(editedRange.location, earlier.location + delta) }
            range = NSUnionRange(earlier, range)
        }
        pendingStyle = range
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        scrollView?.invalidateIntrinsicContentSize()
        guard !textView.hasMarkedText() else { return }
        restylePending()
        syncDraft()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        textView.typingAttributes = styler.typingAttributes(in: storage, at: selection.location)
        // The caret moved by the composer (a restored selection, a chosen file) comes into view, as one
        // moved by a key does. A selection being extended scrolls as AppKit scrolls it.
        if selection.length == 0 { textView.scrollRangeToVisible(selection) }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    /// The size follows text an input method composes too, which the draft does not hold yet.
    func markedTextChanged() {
        scrollView?.invalidateIntrinsicContentSize()
    }
}

/// The text view: Markdown's list keys and format keys, plain-text paste, a placeholder, and the keys
/// the composer answers (`ComposerTextActions`). An input method's composition always has its keys.
class ComposerMarkdownTextView: NSTextView {
    weak var controller: ComposerTextController?
    var placeholder = "" { didSet { if string.isEmpty { needsDisplay = true } } }
    var placeholderFont: NSFont?
    /// The placeholder was drawn last: the whole field redraws when it comes or goes, as an edit redraws
    /// only the text it changed.
    private var showsPlaceholder = true
    var markdownEditing = true

    /// TextKit 1, for the measuring layout that shares this text (`ComposerTextController`). A text view
    /// made around a container does not keep its text, so it keeps it here.
    private let ownedStorage: NSTextStorage

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        ownedStorage = storage
        super.init(frame: .zero, textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = .zero
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = false
    }

    @available(*, unavailable)
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        fatalError("init(frame:textContainer:) is unavailable")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            controller?.actions.composingKey(event)
            super.keyDown(with: event)
            return
        }
        if controller?.actions.key(event, self) == true || takeFormatKey(event) { return }
        // Shift-Tab, which the composer leaves to the text: a list line steps out.
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           event.modifierFlags.contains(.shift), indentMarkdown(outdent: true) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, takeFormatKey(event) else { return super.performKeyEquivalent(with: event) }
        return true
    }

    /// ⌘B, ⌘I and ⌘E, unless one of the app's shortcuts has the key.
    private func takeFormatKey(_ event: NSEvent) -> Bool {
        guard markdownEditing, !hasMarkedText(), event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function]) == .command,
              let mark = Self.mark(for: MacShortcutEvent(event).character),
              !MacShortcut.all.contains(where: { $0.matches(MacShortcutEvent(event)) }) else { return false }
        toggle(mark)
        return true
    }

    private static func mark(for character: String?) -> ComposerMarkdown.InlineMark? {
        switch character {
        case "b": .bold
        case "i": .italic
        case "e": .code
        default: nil
        }
    }

    func toggle(_ mark: ComposerMarkdown.InlineMark) {
        controller?.perform(ComposerMarkdown.toggle(mark, in: string, selection: selectedRange()))
    }

    /// Tab or Shift-Tab on a list line or over several lines. False where Tab keeps its other uses.
    @discardableResult
    func indentMarkdown(outdent: Bool) -> Bool {
        guard markdownEditing, !hasMarkedText(),
              let edit = ComposerMarkdown.indent(in: string, selection: selectedRange(), outdent: outdent) else {
            return false
        }
        controller?.perform(edit)
        return true
    }

    override func insertNewline(_ sender: Any?) {
        insertLine()
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        insertLine()
    }

    override func insertLineBreak(_ sender: Any?) {
        insertLine()
    }

    /// A line break, unless the composer takes it; on a list line, the next item or the list's end.
    private func insertLine() {
        guard !hasMarkedText() else { return super.insertNewlineIgnoringFieldEditor(nil) }
        if controller?.actions.newline() == true { return }
        if markdownEditing, let edit = ComposerMarkdown.newline(in: string, selection: selectedRange()) {
            controller?.perform(edit)
            return
        }
        super.insertNewlineIgnoringFieldEditor(nil)
    }

    override func deleteBackward(_ sender: Any?) {
        if markdownEditing, !hasMarkedText(),
           let edit = ComposerMarkdown.deleteBackward(in: string, selection: selectedRange()) {
            controller?.perform(edit)
            return
        }
        super.deleteBackward(sender)
    }

    /// Tab and Shift-Tab the composer and the text left alone move the keyboard on, as in a text field.
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(self)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(self)
    }

    // MARK: - Composition

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        updatePlaceholder()
        controller?.markedTextChanged()
    }

    override func unmarkText() {
        super.unmarkText()
        updatePlaceholder()
        controller?.compositionEnded()
        controller?.markedTextChanged()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        updatePlaceholder()
        controller?.compositionEnded()
    }

    // MARK: - Paste and drop

    /// Copied text arrives as its words, without the styles of where it came from. Files and pictures
    /// are the composer's (`ComposerExternalInputTarget`).
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    /// AppKit's own `-[NSTextView pasteAsPlainText:]` and its menu-item validation restrict the
    /// `preferredPasteboardType` pick to the legacy `"NSStringPboardType"` (`paste:` sends no
    /// restriction and relies on this list alone). Leaving the legacy type out makes
    /// `pasteAsPlainText:`'s intersection empty, which silently drops every text paste
    /// (`paste(_:)` forwards there) and grays out `Edit › Paste and Match Style`.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string, Self.legacyStringPasteboardType]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.string, Self.legacyStringPasteboardType]
    }

    static let legacyStringPasteboardType = NSPasteboard.PasteboardType("NSStringPboardType")

    // MARK: - Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: placeholderFont ?? font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: ComposerMarkdownStyler.wrappingParagraph
        ]
        let origin = textContainerOrigin
        let width = bounds.width - origin.x * 2
        NSAttributedString(string: placeholder, attributes: attributes)
            .draw(with: NSRect(x: origin.x, y: origin.y, width: max(width, 1), height: bounds.height - origin.y),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func didChangeText() {
        super.didChangeText()
        updatePlaceholder()
    }

    /// The whole text was set from outside.
    func textReplaced() {
        showsPlaceholder = string.isEmpty && !hasMarkedText()
        needsDisplay = true
    }

    private func updatePlaceholder() {
        let shows = string.isEmpty && !hasMarkedText()
        guard shows != showsPlaceholder else { return }
        showsPlaceholder = shows
        needsDisplay = true
    }
}

/// Draws the Markdown a composer holds as it reads: the marks stay and are dimmed, bold reads bold, code
/// in the code face, and a list item's wrapped lines hang under its text.
@MainActor
struct ComposerMarkdownStyler {
    let style: ComposerTextStyle
    let baseFont: NSFont
    let baseAttributes: [NSAttributedString.Key: Any]
    private let strongFont: NSFont
    private let emphasisFont: NSFont
    private let codeFont: NSFont
    let textColor: NSColor
    private let secondaryColor: NSColor
    private let syntaxColor: NSColor
    private let codeBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.11) : NSColor(white: 0, alpha: 0.06)
    }
    /// The width of one indent level (`ComposerMarkdown.indentUnit`), wider than its two spaces.
    private let levelWidth: CGFloat

    /// Korean wraps at its spaces, as the rest of the app's text does.
    static let wrappingParagraph: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = .standard
        return paragraph
    }()

    init(style: ComposerTextStyle) {
        self.style = style
        let size = style.size
        baseFont = style.bodyFont
        strongFont = style.font.font(size: size, weight: .semibold)
        emphasisFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        codeFont = style.codeFont.nsFont(ofSize: style.codeFont.size(13, scale: style.scale))
        textColor = style.text?.nsColor ?? .textColor
        secondaryColor = style.text?.nsColor.withAlphaComponent(0.72) ?? .secondaryLabelColor
        syntaxColor = style.text?.nsColor.withAlphaComponent(0.42) ?? .tertiaryLabelColor
        levelWidth = (size * 1.3).rounded()
        baseAttributes = [.font: baseFont, .foregroundColor: textColor, .paragraphStyle: Self.wrappingParagraph]
    }

    /// Styles the lines `range` touches.
    func apply(to storage: NSTextStorage, in range: NSRange) {
        let string = storage.string as NSString
        let lines = string.paragraphRange(for: range)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(baseAttributes, range: lines)
        guard style.showsMarkdown, string.length > 0 else { return }
        let spans = ComposerMarkdownSpans(text: string, range: lines)
        for line in spans.lines {
            if let indent = line.indent {
                let space = (" " as NSString).size(withAttributes: [.font: baseFont]).width
                let kern = max(0, levelWidth / CGFloat((ComposerMarkdown.indentUnit as NSString).length) - space)
                storage.addAttribute(.kern, value: kern, range: indent)
            }
            if let prefix = line.hangingPrefix {
                let paragraph = Self.wrappingParagraph.mutableCopy() as! NSMutableParagraphStyle
                paragraph.headIndent = storage.attributedSubstring(from: prefix).size().width
                let full = string.paragraphRange(for: line.range)
                storage.addAttribute(.paragraphStyle, value: paragraph, range: full)
            }
        }
        for run in spans.runs where run.range.length > 0 {
            switch run.kind {
            case .syntax:
                storage.addAttribute(.foregroundColor, value: syntaxColor, range: run.range)
            case .strong, .heading:
                storage.enumerateAttribute(.font, in: run.range) { value, sub, _ in
                    let current = value as? NSFont ?? baseFont
                    let isItalic = current.fontDescriptor.symbolicTraits.contains(.italic)
                    let font = isItalic ? NSFontManager.shared.convert(strongFont, toHaveTrait: .italicFontMask) : strongFont
                    storage.addAttribute(.font, value: font, range: sub)
                }
            case .emphasis:
                storage.enumerateAttribute(.font, in: run.range) { value, sub, _ in
                    let current = value as? NSFont ?? baseFont
                    storage.addAttribute(.font, value: current == strongFont
                        ? NSFontManager.shared.convert(strongFont, toHaveTrait: .italicFontMask) : emphasisFont, range: sub)
                }
            case .code:
                storage.addAttributes([.font: codeFont, .backgroundColor: codeBackground], range: run.range)
            case .codeBlock:
                storage.addAttributes([.font: codeFont, .backgroundColor: codeBackground], range: run.range)
            case .fence:
                storage.addAttributes([.font: codeFont, .foregroundColor: syntaxColor], range: run.range)
            case .quote:
                storage.addAttribute(.foregroundColor, value: secondaryColor, range: run.range)
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: secondaryColor, range: run.range)
            }
        }
    }

    /// What typing at `location` starts with: the plain text in its line's paragraph, so a wrapped list
    /// line hangs as soon as it wraps.
    func typingAttributes(in storage: NSTextStorage, at location: Int) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes
        guard storage.length > 0 else { return attributes }
        let string = storage.string as NSString
        var index = min(max(0, location - 1), storage.length - 1)
        // At a line's start the line's own paragraph counts, not the one before its line break.
        if location > 0, [0x0A, 0x0D].contains(string.character(at: index)) {
            guard location < storage.length, ![0x0A, 0x0D].contains(string.character(at: location)) else { return attributes }
            index = location
        }
        if let paragraph = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) {
            attributes[.paragraphStyle] = paragraph
        }
        return attributes
    }
}
