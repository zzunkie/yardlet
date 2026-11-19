import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Small previews of images sent, viewed or returned in a conversation. A local file, an inline
/// `data:` image or a tool's bytes are decoded off the main thread at a bounded size, and only the
/// downscaled bitmap is cached, so a long conversation does not keep its originals in memory. A
/// remote URL is never fetched.
final class TranscriptImageThumbnails: @unchecked Sendable {
    static let shared = TranscriptImageThumbnails()

    enum Preview: @unchecked Sendable {
        case image(CGImage)
        case unavailable
    }

    /// How large a preview is decoded: a tile (a thumbnail, cropped to fill), a call's opened
    /// details, where the image is shown whole up to the conversation's width, or a picture an answer
    /// shows on its own, as wide as the conversation on a 2x display.
    enum Size: String, Sendable {
        case tile, detail, inline
    }

    /// Pixels on a preview's shorter side: an 80 pt tile on a 2x display, with headroom for the
    /// larger interface scales.
    static let shortSidePixels = 240
    static let longSidePixels = 1_024
    /// Pixels on a detail preview's longer side: a 320 pt high screenshot on a 2x display.
    static let detailLongSidePixels = 1_280
    /// Pixels on an inline picture's longer side: the conversation's 768 pt column on a 2x display.
    static let inlineLongSidePixels = 1_600
    /// A larger file is not read for a preview; the attachment shows as its name instead.
    static let maximumFileBytes = 64 * 1_048_576

    private final class Entry {
        let preview: Preview
        init(_ preview: Preview) { self.preview = preview }
    }

    // NSCache is thread-safe; an inline image's key is its data URL, so the key counts toward the cost.
    private let cache = NSCache<NSString, Entry>()
    /// Each image's size in points, read from its header alone, so a picture takes its place before it is
    /// decoded and keeps it while its bitmap is let go. Small, so many are kept.
    private let sizes = NSCache<NSString, NSValue>()
    private let durations = NSCache<NSString, NSNumber>()
    /// Set only by tests: NSCache may drop entries whenever the system is short of memory, as on a
    /// heavily loaded machine, so a test that checks caching keeps its entries here as well.
    private let kept: NSMutableDictionary?
    private let keptLock = NSLock()

    init(costLimit: Int = 48 * 1_048_576, keepsEntriesForTesting: Bool = false) {
        cache.totalCostLimit = costLimit
        kept = keepsEntriesForTesting ? NSMutableDictionary() : nil
    }

    static func canPreview(_ url: URL) -> Bool {
        url.isFileURL || url.scheme == "data"
    }

    func cachedPreview(for url: URL, size: Size = .tile) -> Preview? {
        guard Self.canPreview(url) else { return .unavailable }
        return cachedPreview(forKey: Self.key(url.absoluteString, size))
    }

    /// The preview of bytes a tool returned, cached under `key`, which names them for as long as the
    /// conversation shows them.
    func cachedPreview(forKey key: String, size: Size) -> Preview? {
        cachedPreview(forKey: Self.key(key, size))
    }

    private func cachedPreview(forKey key: String) -> Preview? {
        keptEntry(for: key as NSString)?.preview ?? cache.object(forKey: key as NSString)?.preview
    }

    private static func key(_ key: String, _ size: Size) -> String {
        size == .tile ? key : key + "#" + size.rawValue
    }

    /// Forgets `url`'s preview, as NSCache does to any entry when the system is short of memory or
    /// the cache is over its cost. Tests use it to drop one entry at a known moment.
    func discardCachedPreview(for url: URL) {
        let key = url.absoluteString as NSString
        cache.removeObject(forKey: key)
        guard let kept else { return }
        keptLock.withLock { kept.removeObject(forKey: key) }
    }

    private func keptEntry(for key: NSString) -> Entry? {
        guard let kept else { return nil }
        return keptLock.withLock { kept[key] as? Entry }
    }

    private func keep(_ entry: Entry, for key: NSString) {
        guard let kept else { return }
        keptLock.withLock { kept[key] = entry }
    }

    func preview(for url: URL, size: Size = .tile) async -> Preview {
        if let cached = cachedPreview(for: url, size: size) { return cached }
        if Self.isMovie(url) { return await poster(for: url, size: size) }
        return await decode(key: Self.key(url.absoluteString, size), size: size) { Self.readOriginal(url) }
    }

    /// Whether `url` is a video file, whose preview is a frame of it.
    static func isMovie(_ url: URL) -> Bool {
        url.isFileURL && UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }

    /// A video's frame a moment in (its first is often black), decoded off the main thread at a bounded size.
    private func poster(for url: URL, size: Size) async -> Preview {
        let key = Self.key(url.absoluteString, size)
        let pixels = switch size {
        case .tile: Self.longSidePixels
        case .detail: Self.detailLongSidePixels
        case .inline: Self.inlineLongSidePixels
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        let seconds = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
        let at = CMTime(seconds: min(1, seconds / 10), preferredTimescale: 600)
        let preview: Preview
        if let image = try? await generator.image(at: at).image { preview = .image(image) } else { preview = .unavailable }
        var cost = key.utf8.count
        if case let .image(image) = preview { cost += image.bytesPerRow * image.height }
        cache.setObject(Entry(preview), forKey: key as NSString, cost: cost)
        keep(Entry(preview), for: key as NSString)
        return preview
    }

    /// A video's or a sound's length in seconds, once `pointSize(for:)` or `duration(of:)` has read it.
    func cachedDuration(of url: URL) -> Double? {
        durations.object(forKey: url.absoluteString as NSString)?.doubleValue
    }

    func duration(of url: URL) async -> Double? {
        if let cached = cachedDuration(of: url) { return cached }
        guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite, seconds > 0
        else { return nil }
        durations.setObject(NSNumber(value: seconds), forKey: url.absoluteString as NSString)
        return seconds
    }

    /// The preview of bytes a tool returned, cached under `key` (`cachedPreview(forKey:size:)`).
    func preview(of data: Data, forKey key: String, size: Size) async -> Preview {
        if let cached = cachedPreview(forKey: key, size: size) { return cached }
        return await decode(key: Self.key(key, size), size: size) { data }
    }

    private func decode(key: String, size: Size, read: @escaping @Sendable () -> Data?) async -> Preview {
        let preview = await Task.detached(priority: .utility) { Self.decodePreview(read(), size: size) }.value
        var cost = key.utf8.count
        if case let .image(image) = preview { cost += image.bytesPerRow * image.height }
        cache.setObject(Entry(preview), forKey: key as NSString, cost: cost)
        keep(Entry(preview), for: key as NSString)
        return preview
    }

    /// The size `url`'s image is drawn at, in points: its pixels at its own resolution, as the image viewer and the
    /// Files panel draw it (a 144 dpi screenshot at half its pixels). Nil when it cannot be read as an image.
    func cachedPointSize(for url: URL) -> CGSize? {
        sizes.object(forKey: url.absoluteString as NSString)?.sizeValue
    }

    func pointSize(for url: URL) async -> CGSize? {
        guard Self.canPreview(url) else { return nil }
        if let cached = cachedPointSize(for: url) { return cached }
        if Self.isMovie(url) {
            // A video's picture, turned as it plays; a sound alone has none.
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            let size = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
            guard size.width > 0, size.height > 0 else { return nil }
            sizes.setObject(NSValue(size: size), forKey: url.absoluteString as NSString)
            _ = await duration(of: url)
            return size
        }
        let size = await Task.detached(priority: .utility) { () -> CGSize? in
            guard let data = Self.readOriginal(url), let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }
            return Self.pointSize(of: source)
        }.value
        if let size { sizes.setObject(NSValue(size: size), forKey: url.absoluteString as NSString) }
        return size
    }

    private static func pointSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              var height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        // EXIF orientations 5 to 8 turn the picture a quarter.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? CGFloat).flatMap { $0 > 0 ? $0 : nil } ?? 72
        return CGSize(width: (width * 72 / dpi).rounded(), height: (height * 72 / dpi).rounded())
    }

    /// The original bytes, for the image viewer.
    func originalData(for url: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) { Self.readOriginal(url) }.value
    }

    private static func decodePreview(_ data: Data?, size: Size) -> Preview {
        guard let data, data.count <= maximumFileBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return .unavailable }
        // The tile fills a square, so the shorter side sets the resolution; a very long image is capped.
        // A detail shows the whole image, so the longer side does.
        let longSide = max(width, height)
        let aspect = Double(longSide) / Double(min(width, height))
        let pixels = switch size {
        case .tile: min(longSide, longSidePixels, Int((Double(shortSidePixels) * aspect).rounded(.up)))
        case .detail: min(longSide, detailLongSidePixels)
        case .inline: min(longSide, inlineLongSidePixels)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .unavailable
        }
        return .image(image)
    }

    private static func readOriginal(_ url: URL) -> Data? {
        if url.isFileURL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= maximumFileBytes else { return nil }
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        // `data:image/<type>;base64,<payload>`, no larger than an inline image may be.
        guard url.scheme == "data" else { return nil }
        let text = url.absoluteString
        guard text.hasPrefix("data:image/"), let comma = text.firstIndex(of: ","),
              text[..<comma].hasSuffix(";base64"),
              text.utf8.count - text[...comma].utf8.count <= (InlineImageInput.maximumBytes + 2) / 3 * 4 else {
            return nil
        }
        return Data(base64Encoded: String(text[text.index(after: comma)...]))
    }
}
