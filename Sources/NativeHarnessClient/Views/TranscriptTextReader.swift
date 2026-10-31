import AppKit
import SwiftUI

private struct TranscriptWorkspaceURLKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

private struct TranscriptOpensLocalFilesKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var transcriptWorkspaceURL: URL? {
        get { self[TranscriptWorkspaceURLKey.self] }
        set { self[TranscriptWorkspaceURLKey.self] = newValue }
    }

    /// Whether the files a transcript names are on this Mac. A record of work done on another computer
    /// names that computer's files: its file links offer no opening or showing in Finder here.
    var transcriptOpensLocalFiles: Bool {
        get { self[TranscriptOpensLocalFilesKey.self] }
        set { self[TranscriptOpensLocalFilesKey.self] = newValue }
    }
}

/// AppKit lays out long output on demand and keeps selection and scroll position on updates.
struct TranscriptTextReader: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    var accessibilityLabel = L10n.string("Code")
    var monospaced = true

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 300))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = view.maxSize
        view.textContainer?.widthTracksTextView = false
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let selection = view.selectedRanges
        let origin = scroll.contentView.bounds.origin
        let font: NSFont = monospaced
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : .systemFont(ofSize: fontSize)
        let changed = view.string != text || view.font != font
        guard changed else { return }
        if view.font != font { view.font = font }
        if view.string != text {
            let old = view.string
            if text.hasPrefix(old), let storage = view.textStorage {
                storage.append(NSAttributedString(string: String(text.dropFirst(old.count)), attributes: [
                    .font: font, .foregroundColor: NSColor.labelColor
                ]))
            } else {
                view.string = text
            }
        }
        let length = view.string.utf16.count
        view.selectedRanges = selection.map { value in
            let range = value.rangeValue
            let start = min(range.location, length)
            return NSValue(range: NSRange(location: start, length: min(range.length, length - start)))
        }
        view.setAccessibilityLabel(accessibilityLabel)
        if let container = view.textContainer {
            view.layoutManager?.ensureLayout(forBoundingRect: NSRect(origin: origin, size: scroll.contentView.bounds.size), in: container)
        }
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: origin, size: scroll.contentView.bounds.size)).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
