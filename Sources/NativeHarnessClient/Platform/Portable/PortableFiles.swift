import Foundation

/// No block-sharing copy here; the caller copies the file itself.
enum FileCloning {
    static func clone(_ source: URL, to destination: URL) -> Bool { false }
}

/// No trash here: nothing is moved, and the caller keeps what it would have deleted.
enum Trash {
    static func move(_ url: URL) throws {
        throw CocoaError(.featureUnsupported)
    }
}
