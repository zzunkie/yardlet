import Foundation
import YardletRemote

struct RemoteWorkspaceFiles: WorkspaceFiles {
    let model: RemoteHostModel
    let taskID: String
    let isLocal = false

    func index(in workspace: URL) async throws -> WorkspaceFileIndex {
        let response = await model.response(to: .workspaceFiles(taskID: taskID))
        guard response.ok, let paths = response.filePaths else { throw WorkspaceFileError.notAFile }
        return WorkspaceFileIndex(paths: paths, isLimited: response.filesLimited == true,
            workspaceURL: response.workspaceRoot.flatMap { $0.hasPrefix("/") ? URL(filePath: $0) : nil })
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
        let savable = Self.isSavable(location.relativePath)
        return try await Task.detached(priority: .utility) {
            // The copy's digest is the host file's: it holds the same bytes.
            let document = try WorkspaceFileService.read(.init(relativePath: url.lastPathComponent), in: url.deletingLastPathComponent())
            return .document(WorkspaceFileDocument(path: location.relativePath, text: document.text, sourceDigest: document.sourceDigest,
                encoding: document.encoding, isPartial: document.isPartial, isLossy: document.isLossy,
                isEditable: document.isEditable && savable))
        }.value
    }

    /// Saves to the host as the local panel saves (§15.27): over the bytes the copy was read from, or not at all.
    func save(path: String, text: String, expectedDigest: String, encoding: WorkspaceFileEncoding,
              in workspace: URL) async throws -> WorkspaceFileDocument {
        // An older host lists and reads the folder's files but saves none.
        guard model.offersWorkspaceFileWrites else { throw Refusal(L10n.string("Update Yardlet on the host to use this panel.")) }
        guard let data = encoding.data(text) else { throw WorkspaceFileError.notWritable }
        guard data.count <= WorkspaceFileService.editableBytes else { throw WorkspaceFileError.tooLarge }
        let response = await model.response(to: .writeFile(taskID: taskID, path: path, data: data, sha256: expectedDigest))
        guard response.ok else { throw Self.refusal(response.error, host: model.name, connected: model.isConnected) }
        return await Task.detached(priority: .userInitiated) {
            WorkspaceFileDocument(path: path, text: text, sourceDigest: WorkspaceFileService.digest(data), encoding: encoding,
                                  highlight: .later(keeping: UUID()))
        }.value
    }

    /// A file the host saves: one in the task's folder by the names its listing gives, not one elsewhere that a
    /// conversation's link opened.
    static func isSavable(_ path: String) -> Bool {
        let names = PathRules.current.names(path)
        return PathRules.current.isRelative(path) && names.first != "~"
            && !names.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// The host's refusal in the local panel's words where it means the same, else in the remote window's.
    static func refusal(_ error: RemoteError?, host: String, connected: Bool) -> any Error {
        switch (error?.code, error?.reason) {
        case (.notAllowed?, .fileChanged?): WorkspaceFileError.changedOnDisk
        // Not a file of the task's folder the host writes: outside it, through a link, or not a regular file.
        case (.notAllowed?, nil): WorkspaceFileError.notWritable
        case (.tooLarge?, _): WorkspaceFileError.tooLarge
        case (.unavailable?, _) where connected: WorkspaceFileError.notWritable
        default: Refusal(RemoteHostModel.message(for: error, host: host))
        }
    }

    struct Refusal: LocalizedError {
        let errorDescription: String?
        init(_ words: String) { errorDescription = words }
    }
}
