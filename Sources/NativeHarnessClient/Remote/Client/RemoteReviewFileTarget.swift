import Foundation

/// Resolves a task-relative card path using host Review metadata, without consulting this Mac's disk.
struct RemoteReviewFileTarget: Equatable {
    let repository: String
    let path: String

    static func read(path: String, reader: RemoteGitDiffReading) async throws -> Self? {
        guard RemoteConversationFileLink.url(path) != nil,
              let workspace = try await reader.context().workspace else { return nil }
        let root = try await reader.repositoryRoot(workspaceURL: URL(filePath: workspace)).standardizedFileURL.path
        let file = URL(filePath: workspace).appendingPathComponent(path).standardizedFileURL.path
        guard file.hasPrefix(root + "/") else { return nil }
        return Self(repository: root, path: String(file.dropFirst(root.count + 1)))
    }
}
