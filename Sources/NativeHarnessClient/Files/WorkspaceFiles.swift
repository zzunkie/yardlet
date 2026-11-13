import Foundation

/// The Files panel reads and saves through this boundary. Remote providers never resolve host paths on this Mac.
@MainActor
protocol WorkspaceFiles {
    var isLocal: Bool { get }
    func index(in workspace: URL) async throws -> WorkspaceFileIndex
    func read(_ location: WorkspaceFileLocation, in workspace: URL) async throws -> WorkspaceFileContent
    /// Saves `text` over the file at `path` while it still holds the bytes it was read as (`expectedDigest`); the file
    /// as saved, or `WorkspaceFileError.changedOnDisk` when it changed since.
    func save(path: String, text: String, expectedDigest: String, encoding: WorkspaceFileEncoding,
              in workspace: URL) async throws -> WorkspaceFileDocument
}

enum WorkspaceFileContent: Sendable {
    case document(WorkspaceFileDocument)
    case media(WorkspaceFileMedia)
}

struct LocalWorkspaceFiles: WorkspaceFiles {
    let isLocal = true
    func index(in workspace: URL) async throws -> WorkspaceFileIndex {
        let worker = Task.detached(priority: .utility) { try WorkspaceFileService.index(in: workspace) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    func read(_ location: WorkspaceFileLocation, in workspace: URL) async throws -> WorkspaceFileContent {
        let worker = Task.detached(priority: .utility) {
            if let media = WorkspaceFileMedia(WorkspaceFileLocation.url(for: location.relativePath, in: workspace)),
               FileManager.default.fileExists(atPath: media.url.path(percentEncoded: false)) { return WorkspaceFileContent.media(media) }
            return .document(try WorkspaceFileService.read(location, in: workspace))
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    func save(path: String, text: String, expectedDigest: String, encoding: WorkspaceFileEncoding,
              in workspace: URL) async throws -> WorkspaceFileDocument {
        try await Task.detached(priority: .userInitiated) {
            try WorkspaceFileService.save(path: path, text: text, expectedDigest: expectedDigest, encoding: encoding, in: workspace)
        }.value
    }
}
