import AppKit
import SwiftUI

/// A request the person sent, as the Codex timeline and the shared transcript both draw it: its
/// images above the bubble and its actions beneath: its copy, and what its turn offers to do with it
/// (`ConversationTurnAction`: its edit and the restore of its files). As in both harness apps, the
/// actions show while the pointer is over the message or one has keyboard focus
/// (`HoverRevealedAction`), so a long conversation does not repeat them under every request; their
/// row keeps its place so revealing it moves nothing.
struct SentUserMessage<Bubble: View, Accessory: View>: View {
    let copyText: String
    let images: [TranscriptImageAttachment]
    let minimumLeadingSpace: CGFloat
    @ViewBuilder let bubble: () -> Bubble
    @ViewBuilder let accessory: () -> Accessory

    @Environment(\.conversationMessageActions) private var messageActions

    var body: some View {
        HStack(alignment: .sentBubbleCenter) {
            Spacer(minLength: minimumLeadingSpace)
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty {
                    SentImageAttachments(images: images)
                }
                bubble()
                    .alignmentGuide(.sentBubbleCenter) { $0[VerticalAlignment.center] }
                if !copyText.isEmpty || !messageActions.isEmpty {
                    HStack(spacing: 12) {
                        if !copyText.isEmpty {
                            HoverRevealedAction {
                                TranscriptCopyButton(title: L10n.string("Copy message")) { copyText }
                            }
                        }
                        ConversationMessageActionButtons(actions: messageActions)
                    }
                }
            }
            accessory()
        }
        .modifier(RevealsActionsOnHover())
        // The actions out of sight, for an assistive app wherever its focus is in the message.
        .accessibilityActions {
            if !copyText.isEmpty {
                Button(L10n.string("Copy message")) { TranscriptClipboard.copy(copyText) }
            }
            ForEach(messageActions) { action in
                Button(action.title, action: action.perform)
            }
        }
    }
}

extension SentUserMessage where Accessory == EmptyView {
    init(
        copyText: String, images: [TranscriptImageAttachment], minimumLeadingSpace: CGFloat,
        @ViewBuilder bubble: @escaping () -> Bubble
    ) {
        self.init(
            copyText: copyText, images: images, minimumLeadingSpace: minimumLeadingSpace,
            bubble: bubble, accessory: { EmptyView() }
        )
    }
}

private struct RevealsSentMessageActionsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Shows sent messages' copy action without hover, for window-less renders.
    var revealsSentMessageActions: Bool {
        get { self[RevealsSentMessageActionsKey.self] }
        set { self[RevealsSentMessageActionsKey.self] = newValue }
    }
}

private extension VerticalAlignment {
    /// Keeps a message's side menu level with its bubble rather than with its images.
    enum SentBubbleCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    static let sentBubbleCenter = VerticalAlignment(SentBubbleCenter.self)
}

/// A sent message's images: a thumbnail for each one that can be read, and its name otherwise. A
/// click opens it over the window with the message's other images beside it (`openImageViewer`).
struct SentImageAttachments: View {
    let images: [TranscriptImageAttachment]

    @Environment(\.openImageViewer) private var openImageViewer
    @Environment(\.pauseTranscriptFollowing) private var pauseFollowing

    var body: some View {
        SentAttachmentFlow(spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.offset) { offset, image in
                SentImageThumbnail(attachment: image) { open(at: offset) }
            }
        }
    }

    /// Opens the image at `offset` among the message's images that can be shown: an image whose file
    /// went away since the message was sent shows as its name and is left out.
    private func open(at offset: Int) {
        let shown = images.enumerated().compactMap { offset, image -> (offset: Int, item: ImageViewerItem)? in
            guard let url = image.url, TranscriptImageThumbnails.canPreview(url) else { return nil }
            if case .unavailable? = TranscriptImageThumbnails.shared.cachedPreview(for: url) { return nil }
            return (offset, ImageViewerItem(name: image.name ?? L10n.string("Image"), source: .url(url)))
        }
        guard let index = shown.firstIndex(where: { $0.offset == offset }) else { return }
        pauseFollowing()
        openImageViewer(ImageViewerRequest(items: shown.map(\.item), index: index))
    }
}

private struct SentImageThumbnail: View {
    let attachment: TranscriptImageAttachment
    let open: () -> Void

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @State private var loaded: (url: URL, preview: TranscriptImageThumbnails.Preview)?

    var body: some View {
        content
            .task(id: attachment.url) {
                guard let url = attachment.url, preview == nil else { return }
                let preview = await TranscriptImageThumbnails.shared.preview(for: url)
                guard !Task.isCancelled else { return }
                loaded = (url, preview)
            }
    }

    @ViewBuilder
    private var content: some View {
        let side = 80 * interfaceScale
        switch preview {
        case let .image(image):
            Button(action: open) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(ParityTheme.separator) }
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(name)
            .help(L10n.string("View the image"))
        case .unavailable:
            SentImageNameChip(name: name)
        case nil:
            RoundedRectangle(cornerRadius: 8)
                .fill(ParityTheme.subtleFill)
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(ParityTheme.separator) }
                .frame(width: side, height: side)
                .accessibilityLabel(name)
        }
    }

    /// The loaded preview, or one an earlier row already cached, so scrolling back does not flash.
    private var preview: TranscriptImageThumbnails.Preview? {
        guard let url = attachment.url else { return .unavailable }
        if let loaded, loaded.url == url { return loaded.preview }
        return TranscriptImageThumbnails.shared.cachedPreview(for: url)
    }

    private var name: String { attachment.name ?? L10n.string("Image") }
}

/// An attached image that cannot be previewed, by name, as sent messages showed it before.
/// An image that cannot be shown, by its name.
struct SentImageNameChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "photo")
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: 240)
        .background(ParityTheme.subtleFill, in: Capsule())
        .accessibilityElement(children: .combine)
        .help(name)
    }
}

/// Rows that wrap and sit against the trailing edge, as a sent message's attachments do, or against
/// the leading edge. Items of a row are centered on it, or set against its top.
struct SentAttachmentFlow: Layout {
    var spacing: CGFloat
    var alignsTrailing = true
    var alignsTop = false

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = alignsTrailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = size(of: subviews[index], width: bounds.width)
                subviews[index].place(
                    at: CGPoint(x: x, y: alignsTop ? y : y + (row.height - size.height) / 2),
                    anchor: .topLeading, proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func size(of subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        return ideal.width > width ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = size(of: subviews[index], width: width)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = Row()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
