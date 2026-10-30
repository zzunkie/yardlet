import Foundation

/// What a file's name extension says it holds, for the common types.
enum FileTypes {
    private static let mimeTypes: [String: String] = [
        "pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "heic": "image/heic", "tif": "image/tiff",
        "tiff": "image/tiff", "bmp": "image/bmp", "svg": "image/svg+xml", "ico": "image/x-icon",
        "txt": "text/plain", "md": "text/markdown", "csv": "text/csv", "html": "text/html",
        "htm": "text/html", "css": "text/css", "js": "text/javascript", "json": "application/json",
        "xml": "application/xml", "zip": "application/zip", "gz": "application/gzip",
        "doc": "application/msword", "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel", "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "mp3": "audio/mpeg", "wav": "audio/wav", "mp4": "video/mp4", "mov": "video/quicktime"
    ]

    static func mimeType(forExtension pathExtension: String) -> String? {
        mimeTypes[pathExtension.lowercased()]
    }

    /// A PDF or an image, which the Files panel previews.
    static func mediaKind(forExtension pathExtension: String) -> WorkspaceFileMedia.Kind? {
        guard let type = mimeType(forExtension: pathExtension) else { return nil }
        if type == "application/pdf" { return .pdf }
        return type.hasPrefix("image/") ? .image : nil
    }
}
