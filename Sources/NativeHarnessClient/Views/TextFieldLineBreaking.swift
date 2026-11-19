import AppKit
import SwiftUI

extension View {
    /// A text field that wraps (a vertical `TextField`) breaks its lines between words, as `Text`,
    /// AppKit's labels and the field's own editor do (`NSParagraphStyle.LineBreakStrategy.standard`):
    /// Korean wraps at its spaces, not between any two syllables. SwiftUI makes the AppKit field with
    /// no strategy, which its placeholder and its text keep while the field is not being edited, and
    /// has no modifier for one; this sets it on the field it is drawn behind.
    func wrapsBetweenWords() -> some View {
        background { TextFieldLineBreaking().accessibilityHidden(true) }
    }
}

private struct TextFieldLineBreaking: NSViewRepresentable {
    func makeNSView(context: Context) -> FieldFinder { FieldFinder() }
    func updateNSView(_ view: FieldFinder, context: Context) { view.applySoon() }

    final class FieldFinder: NSView {
        private weak var field: NSTextField?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applySoon()
        }

        /// Once SwiftUI has placed the field in front of this view; nothing to do while the field it
        /// found is still in the window.
        func applySoon() {
            guard window != nil, field?.window == nil else { return }
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let window, field?.window == nil, let content = window.contentView else { return }
            let visible = visibleRect
            guard !visible.isEmpty else { return }
            let point = convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
            let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
            // The field itself, or its editor while it is being edited.
            var view = hit
            while let current = view, !(current is NSTextField) { view = current.superview }
            guard let found = (hit as? NSTextView)?.delegate as? NSTextField ?? view as? NSTextField else { return }
            field = found
            guard found.lineBreakStrategy != .standard else { return }
            found.lineBreakStrategy = .standard
            found.invalidateIntrinsicContentSize()
        }
    }
}
