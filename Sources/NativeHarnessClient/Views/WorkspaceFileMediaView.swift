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
private struct FilePDFView: View {
    let url: URL
    @State private var document: PDFDocument?
    @State private var isUnavailable = false

    var body: some View {
        Group {
            if let document {
                GeometryReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(0..<document.pageCount, id: \.self) { index in
                                if let page = document.page(at: index) {
                                    PDFPageImage(page: page, width: max(1, proxy.size.width - 32))
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
            document = PDFDocument(url: url)
            isUnavailable = document == nil || document?.pageCount == 0
        }
    }
}

private struct PDFPageImage: View {
    let page: PDFPage
    let width: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let bounds = page.bounds(for: .cropBox)
        // A page turned a quarter is as wide as it is tall unturned.
        let turned = page.rotation % 180 != 0
        let height = width * (turned ? bounds.width : bounds.height) / max(1, turned ? bounds.height : bounds.width)
        Image(nsImage: page.thumbnail(of: NSSize(width: width * displayScale, height: height * displayScale), for: .cropBox))
            .resizable()
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
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
    var onFailure: () -> Void = {}
    final class Coordinator {
        var observation: NSKeyValueObservation?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
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
