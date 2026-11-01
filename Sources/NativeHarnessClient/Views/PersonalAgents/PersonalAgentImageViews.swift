import SwiftUI

/// How a dot's conversation gets its pictures' thumbnails: what memory already holds, a read of the
/// room when a picture's row is shown, and a retry of one that could not be read. Renders without a
/// reader get none of them and show each picture's retry.
struct PersonalAgentImageLoader {
    var cached: @MainActor (PersonalAgentAttachment, TranscriptImageThumbnails.Size) -> TranscriptImageThumbnails.Preview? = { _, _ in nil }
    var load: @MainActor (PersonalAgentAttachment, TranscriptImageThumbnails.Size) async -> TranscriptImageThumbnails.Preview? = { _, _ in .unavailable }
    var retry: @MainActor (PersonalAgentAttachment, TranscriptImageThumbnails.Size) -> Void = { _, _ in }
}

/// A message's pictures in place, as the coding conversation shows images: the person's as 80 pt
/// squares above their words, as a sent request's are; the dot's whole, at most 320 pt tall (240 pt
/// when there are several) and 400 pt wide, as a call's images open. Each one's
/// frame is set before its picture arrives, from the size the provider recorded, or as a square when it
/// recorded none, so a picture arriving moves nothing being read. A click opens the picture in the
/// native preview, with Save…, as a file attachment opens.
struct PersonalAgentImageAttachments: View {
    let images: [PersonalAgentAttachment]
    let isPerson: Bool
    let loader: PersonalAgentImageLoader
    let isOpening: Bool
    let open: (PersonalAgentAttachment) -> Void

    var body: some View {
        SentAttachmentFlow(spacing: isPerson ? 6 : 8, alignsTrailing: isPerson) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                PersonalAgentImageTile(attachment: image,
                                       shape: !isPerson ? image.pixelSize.map { .whole($0, several: images.count > 1) } ?? .square : .square,
                                       loader: loader, isOpening: isOpening) { open(image) }
            }
        }
    }
}

private struct PersonalAgentImageTile: View {
    enum Shape: Equatable {
        /// An 80 pt square, the picture cropped to fill it.
        case square
        /// The picture whole at its recorded size, scaled down to fit.
        case whole(PersonalAgentPixelSize, several: Bool)

        var size: TranscriptImageThumbnails.Size { if case .whole = self { .detail } else { .tile } }
    }

    let attachment: PersonalAgentAttachment
    let shape: Shape
    let loader: PersonalAgentImageLoader
    let isOpening: Bool
    let open: () -> Void

    @Environment(\.yardletInterfaceScale) private var scale
    @State private var loaded: (key: String, preview: TranscriptImageThumbnails.Preview)?
    /// Raised by a retry, which reads the picture again.
    @State private var attempt = 0

    private var key: String { (attachment.fileID ?? "") + "#" + shape.size.rawValue }

    private struct Reading: Equatable { let key: String; let attempt: Int }

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.personalAgentImage)
#endif
        framed { content }
            .task(id: Reading(key: key, attempt: attempt)) {
                guard !attachment.isLoading, preview == nil else { return }
                guard let preview = await loader.load(attachment, shape.size), !Task.isCancelled else { return }
                loaded = (key, preview)
            }
    }

    /// The tile's frame, which only the recorded size and the width offered decide.
    @ViewBuilder
    private func framed(@ViewBuilder _ content: () -> some View) -> some View {
        switch shape {
        case .square:
            let side = 80 * scale
            content().frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 8))
        case let .whole(pixels, several):
            ConversationToolImageFrame(pixelSize: CGSize(width: pixels.width, height: pixels.height),
                                       maxHeight: (several ? 240 : 320) * scale, maxWidth: 400 * scale) {
                content()
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch preview {
        case let .image(image):
            Button(action: open) {
                Color.clear
                    .overlay {
                        Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFill()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(ParityTheme.separator) }
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .parityPointer()
            .disabled(isOpening)
            .accessibilityLabel(attachment.name)
            .help(L10n.string("View the image"))
        case .unavailable:
            // The picture stays where it is, and its own retry reads it again; the conversation carries on.
            Button {
                loader.retry(attachment, shape.size)
                loaded = nil
                attempt += 1
            } label: {
                placeholder
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text(L10n.string("Try again")).font(.system(size: 11 * scale))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(L10n.format("Load %@ again", attachment.name))
            .help(L10n.string("This image could not be loaded."))
        case nil:
            placeholder
                .overlay { if attachment.isLoading { ProgressView().controlSize(.small) } }
                .accessibilityElement()
                .accessibilityLabel(attachment.name)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(ParityTheme.subtleFill)
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(ParityTheme.separator) }
    }

    /// The picture read for this tile, or one memory already holds, so a row shown again does not flash.
    private var preview: TranscriptImageThumbnails.Preview? {
        if let loaded, loaded.key == key { return loaded.preview }
        return loader.cached(attachment, shape.size)
    }
}
