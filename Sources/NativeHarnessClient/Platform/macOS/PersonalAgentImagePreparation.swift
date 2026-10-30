import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepares a picture as the provider's composer does before its ordinary upload. HEIC, HEIF, MPO
/// and AVIF become a JPEG named after the original's stem, or fail to prepare; a PNG, JPEG, GIF or
/// WebP larger than 2048 pixels on a side or 1 MiB is drawn again at most 2048 pixels on its long
/// side, in its own type, and sent as it was if that fails. Both are drawn upright, without the
/// original's metadata or later frames. Only the draft's private copy is read.
struct PersonalAgentImagePreparation: PersonalAgentFilePreparing {
    static let live = PersonalAgentImagePreparation()
    static let maximumSide = 2048
    static let reencodeAbove = 1024 * 1024

    func prepare(_ file: URL, name: String, mimeType: String) async throws -> PersonalAgentPreparedFile {
        try await Task.detached(priority: .userInitiated) { try Self.prepared(file, name: name, mimeType: mimeType) }.value
    }

    static func prepared(_ file: URL, name: String, mimeType: String) throws -> PersonalAgentPreparedFile {
        var result = PersonalAgentPreparedFile(data: try Data(contentsOf: file), name: name, mimeType: mimeType)
        let type = mimeType.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if ["image/heic", "image/heif", "image/mpo", "image/avif"].contains(type) || ["heic", "heif", "mpo", "avif"].contains(ext) {
            guard let jpeg = draw(result.data, as: .jpeg, limit: nil) else { throw PersonalAgentFailure.filePreparation }
            let stem = (name as NSString).deletingPathExtension
            result = .init(data: jpeg, name: (stem.isEmpty ? name : stem) + ".jpg", mimeType: "image/jpeg")
        }
        let resizable: [String: UTType] = ["image/png": .png, "image/jpeg": .jpeg, "image/gif": .gif, "image/webp": .webP]
        guard let target = resizable[result.mimeType.lowercased()],
              let size = uprightSize(result.data) else { return result }
        guard size.width > maximumSide || size.height > maximumSide || result.data.count > reencodeAbove else { return result }
        let longest = max(size.width, size.height)
        // Never enlarged; a type this Mac cannot write (WebP) keeps the original.
        guard let drawn = draw(result.data, as: target, limit: min(longest, maximumSide)) else { return result }
        return .init(data: drawn, name: result.name, mimeType: result.mimeType)
    }

    /// The first frame's pixel size as it is shown, after its orientation.
    private static func uprightSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    /// The first frame, upright, at most `limit` pixels on its long side (its own size when nil).
    private static func draw(_ data: Data, as type: UTType, limit: Int?) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let size = uprightSize(data),
              (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(type.identifier) == true else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit ?? max(size.width, size.height)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        // A canvas's default JPEG quality.
        let properties: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// The type the system declares for a chosen file, as a browser's file input reports it.
enum PersonalAgentFileTypes {
    static func source(_ url: URL) -> PersonalAgentFileSource {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        return .init(url: url, declaredType: type?.preferredMIMEType)
    }
}
