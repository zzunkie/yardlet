import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A sent picture as the small JPEG another Mac's Yardlet draws (`RemoteImagePreviews`): the first frame,
/// upright, at most `maximumSide` pixels on its long side, without the original's metadata. Read from a local
/// file or an inline `data:` image, on a background thread.
enum RemoteImagePreviewMaker {
    static let make: RemoteImagePreviews.Make = { url, maximumSide in
        await Task.detached(priority: .utility) { preview(of: url, maximumSide: maximumSide) }.value
    }

    static func preview(of url: URL, maximumSide: Int) -> Data? {
        let source: CGImageSource?
        if url.isFileURL {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        } else if let data = inlineData(url) {
            source = CGImageSourceCreateWithData(data as CFData, nil)
        } else {
            source = nil
        }
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSide
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The bytes of a base64 `data:` URL.
    private static func inlineData(_ url: URL) -> Data? {
        let text = url.absoluteString
        guard text.hasPrefix("data:"), let comma = text.firstIndex(of: ","),
              text[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(text[text.index(after: comma)...]), options: .ignoreUnknownCharacters)
    }
}
