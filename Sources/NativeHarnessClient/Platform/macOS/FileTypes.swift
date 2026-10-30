import Foundation
import UniformTypeIdentifiers

/// What a file's name extension says it holds, from the system's type database.
enum FileTypes {
    static func mimeType(forExtension pathExtension: String) -> String? {
        UTType(filenameExtension: pathExtension)?.preferredMIMEType
    }

    /// A PDF or an image, which the Files panel previews.
    static func mediaKind(forExtension pathExtension: String) -> WorkspaceFileMedia.Kind? {
        guard let type = UTType(filenameExtension: pathExtension) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        return nil
    }
}
