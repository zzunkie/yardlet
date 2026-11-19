import AppKit
import AVKit
import ImageIO
import PDFKit
import SwiftUI

/// Local media beside the conversation, fitted to the panel without enlarging images or movies.
struct WorkspaceFileMediaView: View {
    let media: WorkspaceFileMedia

    var body: some View {
        switch media.kind {
        case .image: FileImageView(url: media.url)
        case .pdf: FilePDFView(url: media.url)
        case .movie, .audio: FilePlayerView(url: media.url, audioOnly: media.kind == .audio)
        }
    }
}

private struct FileImageView: View {
    let url: URL
    @State private var image: DecodedImage?
    @State private var isUnavailable = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement()
                    .accessibilityLabel(url.lastPathComponent)
                    .accessibilityAddTraits(.isImage)
            } else if isUnavailable {
                WorkSurfaceEmptyState(title: L10n.string("Preview unavailable for this file"), systemName: "photo")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            image = nil
            isUnavailable = false
            let url = url
            let decoder = ImageFrameDecoder(url: url)
            var index = 0
            while !Task.isCancelled {
                let frame = await decoder.frame(index)
                guard !Task.isCancelled else { return }
                image = frame
                isUnavailable = frame == nil
                guard let frame, frame.frameCount > 1 else { return }
                do { try await Task.sleep(for: .seconds(frame.duration)) } catch { return }
                index = (index + 1) % frame.frameCount
            }
        }
    }
}

/// An image decoded off the main thread, at most `longSidePixels` on its longer side, with the size
/// in points its own resolution gives it.
struct DecodedImage: @unchecked Sendable {
    static let longSidePixels = 4_096
    let cgImage: CGImage
    let size: CGSize

    let frameCount: Int
    let duration: Double

    init?(source: CGImageSource, index: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              var height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        // EXIF orientations 5 to 8 turn the picture a quarter.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(Int(max(width, height)), Self.longSidePixels)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        // A screenshot saved at 144 dpi is drawn at half its pixels, as Preview draws it.
        let dpi = (properties[kCGImagePropertyDPIWidth] as? CGFloat).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let animation = [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyHEICSDictionary]
            .compactMap { properties[$0] as? [CFString: Any] }.first
        frameCount = animation == nil ? 1 : CGImageSourceGetCount(source)
        let delay = animation?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            ?? animation?[kCGImagePropertyGIFDelayTime] as? Double
            ?? animation?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double
            ?? animation?[kCGImagePropertyAPNGDelayTime] as? Double
            ?? animation?[kCGImagePropertyHEICSDelayTime] as? Double ?? 0.1
        duration = max(0.02, delay)
        cgImage = image
        size = CGSize(width: width * 72 / dpi, height: height * 72 / dpi)
    }
}

/// A PDF's pages one under another at the panel's width, each drawn by PDFKit as it scrolls into view.
/// PDFKit's own `PDFView` draws only in a window on screen, so the panel could not be checked unshown.
/// The document lives on `PDFPageRenderer`, off the main thread: a long PDF takes a while to read,
/// each page to draw, and its objects a large part of a second to free.
private struct FilePDFView: View {
    let url: URL
    @State private var pages: PDFPages?
    @State private var isUnavailable = false

    var body: some View {
        Group {
            if let pages {
                GeometryReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(pages.sizes.indices, id: \.self) { index in
                                if let size = pages.sizes[index] {
                                    PDFPageImage(renderer: pages.renderer, index: index, size: size,
                                                 width: max(1, proxy.size.width - 32))
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                .accessibilityLabel(url.lastPathComponent)
            } else if isUnavailable {
                WorkSurfaceEmptyState(title: L10n.string("Preview unavailable for this file"), systemName: "doc.richtext")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            close()
            isUnavailable = false
            let renderer = PDFPageRenderer(url: url)
            let sizes = await renderer.open()
            guard !Task.isCancelled, !sizes.isEmpty else {
                isUnavailable = !Task.isCancelled
                return await renderer.close()
            }
            pages = PDFPages(renderer: renderer, sizes: sizes)
        }
        .onDisappear { close() }
    }

    /// Lets the document go on its renderer rather than wherever the view's state is released.
    private func close() {
        guard let renderer = pages?.renderer else { return }
        pages = nil
        Task { await renderer.close() }
    }
}

private struct PDFPages {
    let renderer: PDFPageRenderer
    /// Each page's size in points as it is shown; nil for a page PDFKit cannot read.
    let sizes: [CGSize?]
}

/// One page, drawn by the renderer at the size it is shown and let go once it scrolls out of view.
private struct PDFPageImage: View {
    let renderer: PDFPageRenderer
    let index: Int
    let size: CGSize
    let width: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        let height = width * size.height / max(1, size.width)
        let pixels = CGSize(width: (width * displayScale).rounded(), height: (height * displayScale).rounded())
        Group {
            if let image {
                Image(decorative: image, scale: displayScale).resizable()
            } else {
                Color.white
            }
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        // The page drawn before stays, stretched, while one at the new width is drawn.
        .task(id: pixels) {
            if let drawn = await renderer.image(of: index, pixels: pixels), !Task.isCancelled { image = drawn }
        }
        .onDisappear { image = nil }
    }
}

/// Reads, draws and frees a PDF off the main thread; PDFKit's objects never leave it.
actor PDFPageRenderer {
    private let url: URL
    private var document: PDFDocument?
    init(url: URL) { self.url = url }

    /// Opens the file and gives each page's size in points as it is shown; none when it cannot be read.
    func open() -> [CGSize?] {
        autoreleasepool {
            guard let document = PDFDocument(url: url) else { return [] }
            self.document = document
            return (0..<document.pageCount).map { index in
                document.page(at: index).map { page in
                    let bounds = page.bounds(for: .cropBox)
                    // A page turned a quarter is as wide as it is tall unturned.
                    return page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
                }
            }
        }
    }

    /// The page drawn `pixels` in size; nil once closed, or when the view no longer wants it.
    /// PDFKit's thumbnail rather than a bitmap context of the renderer's own: the panel kept two
    /// copies of every page drawn into such a context until it closed, and none of the thumbnail's.
    func image(of index: Int, pixels: CGSize) -> CGImage? {
        guard !Task.isCancelled, let page = document?.page(at: index) else { return nil }
        return autoreleasepool {
            var rect = CGRect(origin: .zero, size: pixels)
            return page.thumbnail(of: pixels, for: .cropBox).cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
    }

    /// Frees the document here: a long PDF's objects take a large part of a second to free.
    func close() {
        autoreleasepool { document = nil }
    }
}

/// ImageIO reads frames off the main thread; the view retains only its current thumbnail.
actor ImageFrameDecoder {
    private let url: URL
    private var source: CGImageSource?
    init(url: URL) { self.url = url }

    func frame(_ index: Int) -> DecodedImage? {
        if source == nil {
            source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let source else { return nil }
        return autoreleasepool {
            defer { CGImageSourceRemoveCacheAtIndex(source, index) }
            return DecodedImage(source: source, index: index)
        }
    }
}

private struct FilePlayerView: View {
    let url: URL
    let audioOnly: Bool
    @State private var player: AVPlayer?
    @State private var size = CGSize(width: 640, height: 360)
    @State private var unavailable = false

    var body: some View {
        Group {
            if unavailable {
                WorkSurfaceEmptyState(title: L10n.string("Preview unavailable for this file"), systemName: "play.slash") {
                    FileElsewhereButtons(url: url).controlSize(.small)
                }
            } else if let player {
                GeometryReader { proxy in
                    let scale = min(1, max(1, proxy.size.width - 32) / max(1, size.width), max(1, proxy.size.height - 32) / max(1, size.height))
                    let width = audioOnly ? min(640, max(1, proxy.size.width - 32)) : size.width * scale
                    NativeFilePlayer(player: player, audioOnly: audioOnly, onFailure: { unavailable = true; stop() })
                        .frame(width: width, height: audioOnly ? 160 : width * size.height / max(1, size.width))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            stop()
            unavailable = false
            let asset = AVURLAsset(url: url)
            do {
                guard try await asset.load(.isPlayable) else { unavailable = true; return }
                if !audioOnly, let track = try await asset.loadTracks(withMediaType: .video).first {
                    let dimensions = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let rect = CGRect(origin: .zero, size: dimensions).applying(transform)
                    size = CGSize(width: abs(rect.width), height: abs(rect.height))
                }
                guard !Task.isCancelled else { return }
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            } catch {
                if !Task.isCancelled { unavailable = true }
            }
        }
        .onDisappear { stop() }
    }

    private func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

struct NativeFilePlayer: NSViewRepresentable {
    let player: AVPlayer
    let audioOnly: Bool
    /// Full screen and picture in picture, which a video in the conversation offers as the Codex app's does.
    var allowsFullScreen = false
    var onFailure: () -> Void = {}
    final class Coordinator {
        var observation: NSKeyValueObservation?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = allowsFullScreen && !audioOnly
        view.allowsPictureInPicturePlayback = allowsFullScreen && !audioOnly
        view.updatesNowPlayingInfoCenter = false
        view.player = player
        context.coordinator.observation = player.currentItem?.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .failed {
                Task { @MainActor in onFailure() }
            }
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.observation = nil
        view.player?.pause()
        view.player?.replaceCurrentItem(with: nil)
        view.player = nil
    }
}
