import AppKit
import SwiftUI

/// What a paste or drop hands to a composer, beyond plain text.
enum ComposerExternalInput: Equatable {
    case files([URL])
    case image(Data, type: NSPasteboard.PasteboardType)

    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    /// Copied files win; copied text stays text, even when the source also offers a picture of it
    /// (a spreadsheet range, a styled snippet); only a pasteboard with an image and no text
    /// becomes an image attachment. A drop has no text reading to protect, so it skips that rule.
    static func read(from pasteboard: NSPasteboard, isPaste: Bool) -> ComposerExternalInput? {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return .files(urls) }
        if isPaste, pasteboard.availableType(from: [.string]) != nil { return nil }
        for type in imageTypes {
            if let data = pasteboard.data(forType: type), !data.isEmpty { return .image(data, type: type) }
        }
        return nil
    }

    /// Whether a drag offers something `read` would accept, without loading image bytes on
    /// every mouse movement.
    static func canRead(from pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: imageTypes) != nil
    }

    /// PNG bytes for the attachment file. A PNG is kept as it was copied; anything else is
    /// re-encoded once, off the main thread.
    static func pngData(_ data: Data, type: NSPasteboard.PasteboardType) -> Data? {
        if type == .png { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    /// ⌘V as the Paste menu item sees it, under any input source (`NSEvent.commandShortcutKey`).
    static func isPasteShortcut(_ event: NSEvent) -> Bool {
        event.type == .keyDown && MacShortcut.pasteAttachment.matches(MacShortcutEvent(event))
    }
}

/// Sits over a composer without taking its clicks, and receives the files or images dropped
/// on it — including over the text while it is being edited, where the text editor would
/// otherwise insert a file's path. ⌘V reaches it only when the composer's own text field is
/// being edited and the pasteboard holds files or an image without text; every other key,
/// including text paste and input-method composition, goes to the editor untouched.
struct ComposerExternalInputTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onInput: (ComposerExternalInput) -> Void
    /// Backspace in the composer's empty text field, which the field editor would otherwise
    /// swallow before SwiftUI's key handlers see it. True when it was used, as bash mode uses it.
    var onDeleteInEmptyText: (() -> Bool)? = nil

    func makeNSView(context: Context) -> ComposerExternalInputView {
        let view = ComposerExternalInputView()
        view.onInput = onInput
        view.onTargetChange = { isTargeted = $0 }
        view.onDeleteInEmptyText = onDeleteInEmptyText
        return view
    }

    func updateNSView(_ view: ComposerExternalInputView, context: Context) {
        view.onInput = onInput
        view.onTargetChange = { isTargeted = $0 }
        view.onDeleteInEmptyText = onDeleteInEmptyText
    }

    static func dismantleNSView(_ view: ComposerExternalInputView, coordinator: ()) {
        view.stopMonitoringPaste()
    }
}

final class ComposerExternalInputView: NSView {
    var onInput: (ComposerExternalInput) -> Void = { _ in }
    var onTargetChange: (Bool) -> Void = { _ in }
    var onDeleteInEmptyText: (() -> Bool)?
    private var pasteMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL] + ComposerExternalInput.imageTypes)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    // Clicks, scrolling and the text cursor belong to the composer underneath. AppKit chooses a
    // drop destination from registered drag types rather than from this method.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoringPaste()
        guard window != nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handlePaste(event) || self.handleDeleteInEmptyText(event) else { return event }
            return nil
        }
    }

    /// Backspace, unmodified, in this composer's empty editor with no composition in progress.
    func handleDeleteInEmptyText(_ event: NSEvent) -> Bool {
        guard let onDeleteInEmptyText, event.type == .keyDown, MacShortcut.leaveBash.matches(MacShortcutEvent(event)),
              let window, event.window === window,
              let editor = window.firstResponder as? NSTextView, editor.isEditable, editor.string.isEmpty,
              !editor.hasMarkedText(), owns(editor) else { return false }
        return onDeleteInEmptyText()
    }

    func stopMonitoringPaste() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }

    func handlePaste(_ event: NSEvent, pasteboard: NSPasteboard = .general) -> Bool {
        guard ComposerExternalInput.isPasteShortcut(event), let window, event.window === window,
              let editor = window.firstResponder as? NSTextView, editor.isEditable,
              !editor.hasMarkedText(), owns(editor),
              let input = ComposerExternalInput.read(from: pasteboard, isPaste: true) else { return false }
        onInput(input)
        return true
    }

    /// A SwiftUI text field edits through a field editor hosted inside the field. The editor
    /// belongs to this composer when that field lies within this view.
    func owns(_ editor: NSTextView) -> Bool {
        let field = (editor.delegate as? NSView) ?? editor.enclosingScrollView ?? editor
        guard field.window === window else { return false }
        let frame = field.convert(field.bounds, to: nil)
        return convert(bounds, to: nil).contains(NSPoint(x: frame.midX, y: frame.midY))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = dragOperation(for: sender)
        onTargetChange(operation != [])
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargetChange(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onTargetChange(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onTargetChange(false)
        guard let input = ComposerExternalInput.read(from: sender.draggingPasteboard, isPaste: false) else { return false }
        onInput(input)
        return true
    }

    private func dragOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        ComposerExternalInput.canRead(from: sender.draggingPasteboard) ? .copy : []
    }
}

/// Shown while files or an image are dragged over a composer that will take them.
struct ComposerDropHighlight: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ParityTheme.composerCornerRadius)
        shape.fill(ParityTheme.input.opacity(0.92))
            .overlay { shape.strokeBorder(ParityTheme.accent, lineWidth: 1.5) }
            .overlay {
                Text(L10n.string("Drop to attach"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(ParityTheme.accent)
            }
            .allowsHitTesting(false)
    }
}
