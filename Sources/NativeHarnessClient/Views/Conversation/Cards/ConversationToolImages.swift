import SwiftUI

// The images a call looked at, made or returned, as the Claude app's Code screen shows a call's
// screenshots (`TurnStatusStep` media): small at the end of the call's line, the last three with the
// count of the rest before them, and whole when the line is opened. The Codex app's image view row
// opens into the same images. A click on any of them opens the call's images over the window
// (`openImageViewer`). Each is drawn from a downscaled copy decoded off the main thread
// (`TranscriptImageThumbnails`); one that cannot be read shows as its name.

/// One image of a call: a file or an inline `data:` image by its URL, or bytes an MCP result
/// returned. A web image is never fetched.
struct ConversationToolImage: Sendable {
    /// Names the image in the preview cache: its URL, or the MCP block and its length.
    let key: String
    let name: String
    /// Nil for an image whose bytes are not kept (an inline image restored from the reading cache).
    let source: ImageViewerItem.Source?

    /// Whether a preview may exist: a file or inline image, or a tool's bytes.
    var canPreview: Bool {
        switch source {
        case let .url(url)?: TranscriptImageThumbnails.canPreview(url)
        case .data?: true
        case nil: false
        }
    }

    func cachedPreview(size: TranscriptImageThumbnails.Size) -> TranscriptImageThumbnails.Preview? {
        switch source {
        case let .url(url)?: TranscriptImageThumbnails.shared.cachedPreview(for: url, size: size)
        case .data?: TranscriptImageThumbnails.shared.cachedPreview(forKey: key, size: size)
        case nil: .unavailable
        }
    }

    func preview(size: TranscriptImageThumbnails.Size) async -> TranscriptImageThumbnails.Preview {
        switch source {
        case let .url(url)?: await TranscriptImageThumbnails.shared.preview(for: url, size: size)
        case let .data(data)?: await TranscriptImageThumbnails.shared.preview(of: data, forKey: key, size: size)
        case nil: .unavailable
        }
    }

    /// Opens `images` over the window at `index`, leaving out the ones that could not be read.
    @MainActor
    static func open(_ images: [ConversationToolImage], at index: Int,
                     viewer: @MainActor (ImageViewerRequest) -> Void, pauseFollowing: @MainActor () -> Void) {
        let shown = images.enumerated().compactMap { offset, image -> (offset: Int, item: ImageViewerItem)? in
            guard let source = image.source, image.canPreview else { return nil }
            if case .unavailable? = image.cachedPreview(size: .tile) ?? image.cachedPreview(size: .detail) { return nil }
            return (offset, ImageViewerItem(name: image.name, source: source))
        }
        guard let shownIndex = shown.firstIndex(where: { $0.offset == index }) else { return }
        pauseFollowing()
        viewer(ImageViewerRequest(items: shown.map(\.item), index: shownIndex))
    }
}

extension ConversationTool {
    /// The call's images in order: the ones it looked at, made or returned, then its MCP result's.
    var previewImages: [ConversationToolImage] {
        let own = images.map { image in
            ConversationToolImage(key: image.url?.absoluteString ?? "", name: image.name ?? L10n.string("Image"),
                                  source: image.url.map { .url($0) })
        }
        return own + (mcpResult?.previewImages ?? [])
    }
}

extension CodexMCPResultProjection {
    /// The result's images, in order.
    var previewImages: [ConversationToolImage] {
        blocks.compactMap { block in
            guard case let .image(id, data, _) = block else { return nil }
            return ConversationToolImage(key: Self.previewKey(block: id, data: data),
                                         name: L10n.string("Tool result image"), source: .data(data))
        }
    }

    /// An image block's key in the preview cache: the block, which names the call, and its length.
    static func previewKey(block id: String, data: Data) -> String {
        "\(id):\(data.count)"
    }
}

extension ConversationItem {
    /// A call's images (`ConversationTool.previewImages`); none for anything else.
    var toolPreviewImages: [ConversationToolImage] {
        if case let .tool(tool) = kind { tool.previewImages } else { [] }
    }
}

/// A call's images at the end of a folded line (the Claude app's `size: "sm"`): the last three, each
/// as tall as the line and at most 44 pt wide, cropped from the top left, with the count of the
/// earlier ones before them. One that cannot be read is left out, so a line whose images cannot be
/// read reads as its words alone.
struct ConversationToolImageThumbnails: View {
    let images: [ConversationToolImage]

    static let shownCount = 3

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.openImageViewer) private var openImageViewer
    @Environment(\.pauseTranscriptFollowing) private var pauseFollowing

    var body: some View {
        let previewable = images.enumerated().filter { $0.element.canPreview }
        if !previewable.isEmpty {
            let shown = previewable.suffix(Self.shownCount)
            HStack(spacing: 8 * interfaceScale) {
                if previewable.count > shown.count {
                    Text(verbatim: "+\(previewable.count - shown.count)")
                        .font(.system(size: 12 * interfaceScale).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 4 * interfaceScale) {
                    ForEach(Array(shown), id: \.offset) { offset, image in
                        ConversationToolImageThumbnail(image: image) {
                            ConversationToolImage.open(images, at: offset, viewer: openImageViewer,
                                                       pauseFollowing: pauseFollowing)
                        }
                    }
                }
            }
            .fixedSize()
        }
    }
}

private struct ConversationToolImageThumbnail: View {
    let image: ConversationToolImage
    let open: () -> Void

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @State private var loaded: (key: String, preview: TranscriptImageThumbnails.Preview)?

    var body: some View {
        let height = 24 * interfaceScale
        content(height: height)
            .task(id: image.key) {
                guard preview == nil else { return }
                let preview = await image.preview(size: .tile)
                guard !Task.isCancelled else { return }
                loaded = (image.key, preview)
            }
    }

    @ViewBuilder
    private func content(height: CGFloat) -> some View {
        switch preview {
        case let .image(cgImage):
            let aspect = CGFloat(cgImage.width) / CGFloat(max(cgImage.height, 1))
            let width = min(44 * interfaceScale, max(12 * interfaceScale, height * aspect))
            Button(action: open) {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: width, height: height, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay { RoundedRectangle(cornerRadius: 4).stroke(ParityTheme.separator) }
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(image.name)
            .help(L10n.string("View the image"))
        case .unavailable:
            EmptyView()
        case nil:
            RoundedRectangle(cornerRadius: 4)
                .fill(ParityTheme.subtleFill)
                .overlay { RoundedRectangle(cornerRadius: 4).stroke(ParityTheme.separator) }
                .frame(width: height * 1.5, height: height)
                .accessibilityHidden(true)
        }
    }

    /// The loaded preview, or one an earlier line already cached, so scrolling back does not flash.
    private var preview: TranscriptImageThumbnails.Preview? {
        if let loaded, loaded.key == image.key { return loaded.preview }
        return image.cachedPreview(size: .tile)
    }
}

/// A call's images in its opened details (the Claude app's `size: "lg"`): each whole, no larger than
/// it is, as wide as the conversation allows and at most 320 pt tall, or 240 pt when there are
/// several, wrapping onto more rows.
struct ConversationToolImageDetails: View {
    let images: [ConversationToolImage]

    @Environment(\.openImageViewer) private var openImageViewer
    @Environment(\.pauseTranscriptFollowing) private var pauseFollowing

    var body: some View {
        if !images.isEmpty {
            SentAttachmentFlow(spacing: 8, alignsTrailing: false) {
                ForEach(Array(images.enumerated()), id: \.offset) { offset, image in
                    ConversationToolImageTile(image: image, isOneOfSeveral: images.count > 1) {
                        ConversationToolImage.open(images, at: offset, viewer: openImageViewer,
                                                   pauseFollowing: pauseFollowing)
                    }
                }
            }
        }
    }
}

/// One image of a call's opened details.
struct ConversationToolImageTile: View {
    let image: ConversationToolImage
    let isOneOfSeveral: Bool
    let open: () -> Void

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @State private var loaded: (key: String, preview: TranscriptImageThumbnails.Preview)?

    var body: some View {
        content
            .task(id: image.key) {
                guard preview == nil else { return }
                let preview = await image.preview(size: .detail)
                guard !Task.isCancelled else { return }
                loaded = (image.key, preview)
            }
    }

    @ViewBuilder
    private var content: some View {
        let maxHeight = (isOneOfSeveral ? 240 : 320) * interfaceScale
        switch preview {
        case let .image(cgImage):
            Button(action: open) {
                ConversationToolImageFrame(pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
                                           maxHeight: maxHeight) {
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .interpolation(.high)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(ParityTheme.separator) }
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(image.name)
            .help(L10n.string("View the image"))
        case .unavailable:
            SentImageNameChip(name: image.name)
        case nil:
            RoundedRectangle(cornerRadius: 8)
                .fill(ParityTheme.subtleFill)
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(ParityTheme.separator) }
                .frame(width: min(maxHeight * 1.6, 360 * interfaceScale), height: maxHeight / 2)
                .accessibilityLabel(image.name)
        }
    }

    private var preview: TranscriptImageThumbnails.Preview? {
        if let loaded, loaded.key == image.key { return loaded.preview }
        return image.cachedPreview(size: .detail)
    }
}

/// An image at its own size, scaled down to fit the width offered and `maxHeight`.
struct ConversationToolImageFrame: Layout {
    let pixelSize: CGSize
    let maxHeight: CGFloat
    var maxWidth: CGFloat = .infinity

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
        let scale = min(1, maxHeight / pixelSize.height, min(maxWidth, proposal.width ?? .infinity) / pixelSize.width)
        return CGSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}
