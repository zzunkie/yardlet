import Foundation
import YardletRemote

struct RemoteWorkspaceFiles: WorkspaceFiles {
    let model: RemoteHostModel
    let taskID: String
    let isLocal = false

    func index(in workspace: URL) async throws -> WorkspaceFileIndex {
        let response = await model.response(to: .workspaceFiles(taskID: taskID))
        guard response.ok, let paths = response.filePaths else { throw WorkspaceFileError.notAFile }
        return WorkspaceFileIndex(paths: paths, isLimited: response.filesLimited == true)
    }

    func read(_ location: WorkspaceFileLocation, in workspace: URL) async throws -> WorkspaceFileContent {
        let result = await model.files.copy(taskID: taskID, path: location.relativePath)
        let url: URL
        switch result {
        case let .success(copy): url = copy
        case .failure(.tooLarge): throw WorkspaceFileError.tooLarge
        case .failure: throw WorkspaceFileError.notAFile
        }
        try Task.checkCancellation()
        if let media = WorkspaceFileMedia(url) { return .media(media) }
        return try await Task.detached(priority: .utility) {
            let document = try WorkspaceFileService.read(.init(relativePath: url.lastPathComponent), in: url.deletingLastPathComponent())
            return .document(WorkspaceFileDocument(path: location.relativePath, text: document.text, encoding: document.encoding,
                isPartial: document.isPartial, isLossy: document.isLossy, isEditable: false))
        }.value
    }
}
