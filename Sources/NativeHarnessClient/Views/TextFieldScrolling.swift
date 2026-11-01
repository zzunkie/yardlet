import AppKit
import SwiftUI

extension View {
    /// A growing text field (a vertical `TextField` with no upper line limit) that grows to `lines`
    /// lines and then scrolls inside, as the Codex and Claude apps' composers do: a scroller, the
    /// wheel, and the caret kept in view as it moves. A vertical `TextField` given an upper line limit
    /// instead stops growing there and keeps the rest out of reach: its field editor has no scroller,
    /// the wheel does not move it, and only the caret brings the other lines into view.
    ///
    /// The field's font and style must reach it from outside this modifier, as environment values
    /// (`.font`, `.textFieldStyle` applied after it): the height of `lines` lines is the height a
    /// field in that font and style takes for them.
    func scrollsPastLines(_ lines: Int) -> some View {
        modifier(TextFieldScrolling(lines: lines))
    }
}

private struct TextFieldScrolling: ViewModifier {
    let lines: Int
    /// The field takes the height of the most lines, so it may scroll: only then can its scroller show.
    @State private var isFull = false
    @State private var heights = Heights()

    /// The scroll view's height and the most lines' height, read by the geometry actions without
    /// redrawing the field.
    private final class Heights {
        var shown: CGFloat = 0
        var most: CGFloat = .infinity
    }

    func body(content: Content) -> some View {
        TextFieldScrollingLayout {
            ScrollView(.vertical) {
                content.background { TextFieldCaretFollower().accessibilityHidden(true) }
            }
            .scrollBounceBehavior(.basedOnSize)
            // A growing field lays out its taller text a moment before the scroll view takes the new
            // height. A scroller that shows for that moment and takes width (as scrollers do with a
            // mouse connected) narrows the text, which wraps again, and the field jumps to another
            // height and back. Below the most lines there is nothing to scroll, so no scroller.
            .scrollIndicators(isFull ? .automatic : .never)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                heights.shown = $0
                updateIsFull()
            }
            TextField(String(), text: .constant(""), axis: .vertical)
                .lineLimit(lines, reservesSpace: true)
                .disabled(true)
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    heights.most = $0
                    updateIsFull()
                }
        }
    }

    private func updateIsFull() {
        let full = heights.shown >= heights.most - 0.5
        if full != isFull { isFull = full }
    }
}

/// The scrolling field (first) as tall as its content, up to the height the hidden field (second)
/// takes for the most lines.
private struct TextFieldScrollingLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let content = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let most = subviews[1].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? content.width, height: min(content.height, most.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// Keeps the caret of the field being edited in view of the scroll view around the field. The field
/// editor scrolls only the clip view inside the field, which now shows all of it, so the caret
/// leaving the scroll view (typing on past its bottom, arrows, a click near its edge, the field
/// growing under it) has to move the scroll view from here. It sits behind the field, as tall.
private struct TextFieldCaretFollower: NSViewRepresentable {
    func makeNSView(context: Context) -> FollowerView { FollowerView() }
    func updateNSView(_ view: FollowerView, context: Context) {}

    final class FollowerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: nil)
            guard window != nil else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)),
                                                   name: NSTextView.didChangeSelectionNotification, object: nil)
        }

        @objc private func selectionChanged(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, edits(editor) else { return }
            // Once the field has taken its new height.
            DispatchQueue.main.async { [weak self] in self?.revealCaret() }
        }

        override func setFrameSize(_ newSize: NSSize) {
            let resized = newSize.height != frame.height
            super.setFrameSize(newSize)
            if resized { revealCaret() }
        }

        /// The field editor works in a field this scroll view holds.
        private func edits(_ editor: NSTextView) -> Bool {
            guard editor.window === window, window?.firstResponder === editor,
                  let document = enclosingScrollView?.documentView else { return false }
            return editor.isDescendant(of: document)
        }

        private func revealCaret() {
            guard let editor = window?.firstResponder as? NSTextView, edits(editor),
                  let document = enclosingScrollView?.documentView, let caret = Self.caretRect(in: editor)
            else { return }
            document.scrollToVisible(document.convert(caret, from: editor))
        }

        /// The selection's end, or the caret, in the editor's coordinates.
        private static func caretRect(in editor: NSTextView) -> NSRect? {
            guard let layout = editor.textLayoutManager, let content = layout.textContentManager,
                  let location = content.location(content.documentRange.location,
                                                  offsetBy: NSMaxRange(editor.selectedRange()))
            else { return nil }
            var caret: NSRect?
            layout.enumerateTextSegments(in: NSTextRange(location: location), type: .selection,
                                         options: []) { _, frame, _, _ in
                caret = frame
                return false
            }
            guard let caret else { return nil }
            let origin = editor.textContainerOrigin
            return caret.offsetBy(dx: origin.x, dy: origin.y)
        }
    }
}
