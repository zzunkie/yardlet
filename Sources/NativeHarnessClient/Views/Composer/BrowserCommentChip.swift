import AppKit
import SwiftUI

/// An element picked in the task's browser, waiting in the composer for the next message: its capture
/// as an attached image shows (a click marks it up), then what the element is and the page's host. The
/// pointer reads its page and selector. Without a capture it is a chip of its name.
struct BrowserCommentChip: View {
    let comment: BrowserComment
    /// The marked-up capture that takes the comment's capture's place.
    var onMarkedUp: ((URL) -> Void)?
    let onRemove: () -> Void

    /// The sent message's chip for the comments (`1 annotation`), which a queued message alone with
    /// them is named by.
    static func title(count: Int) -> String { BrowserComment.countTitle(count) }

    /// What the chip names: the element (its tag and words), on the page's host.
    static func label(_ comment: BrowserComment) -> String {
        guard let host = URL(string: comment.pageURL)?.host(), !host.isEmpty else { return comment.target }
        return "\(comment.target) · \(host)"
    }

    static func tooltip(_ comment: BrowserComment) -> String {
        [comment.target, comment.selector, comment.pageURL].joined(separator: "\n")
    }

    var body: some View {
        if let image = comment.image {
            HStack(spacing: 6) {
                ComposerImageChip(url: image, name: comment.target, onMarkup: markup(image), onRemove: onRemove)
                Text(Self.label(comment))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 160, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(Self.tooltip(comment))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.string("Picked element"))
            .accessibilityValue(Self.label(comment))
        } else {
            ComposerLabelChip(symbol: "cursorarrow.rays", label: Self.label(comment), onRemove: onRemove)
                .help(Self.tooltip(comment))
        }
    }

    private func markup(_ image: URL) -> (() -> Void)? {
        guard let onMarkedUp else { return nil }
        return { ImageMarkupPresenter.open(image, nil, onMarkedUp) }
    }
}
