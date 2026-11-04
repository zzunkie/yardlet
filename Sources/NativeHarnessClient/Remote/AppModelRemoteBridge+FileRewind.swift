import Foundation
import YardletRemote

extension AppModelRemoteBridge {
    func fileRewind(taskID: String, action: RemoteFileRewindAction, pointID: String?, receipt: String?,
                    confirmed: Bool, permit: RemoteFileWritePermit? = nil) async -> Result<RemoteFileRewind, RemoteError> {
        guard let model, let session = session(taskID), session.harness == .claudeCode else {
            return .failure(RemoteError(.notFound))
        }
        do {
            var value = RemoteFileRewind()
            switch action {
            case .points:
                value.points = try await model.loadClaudeFilePoints(in: session).suffix(200).map {
                    .init(id: $0.id, text: String($0.text.prefix(500)))
                }
                return .success(value)
            case .preview:
                guard let pointID else { return .failure(RemoteError(.badRequest)) }
                let preview = try await model.previewClaudeFiles(pointID: pointID, in: session)
                // The provider can report files outside the task. Refuse the whole restore rather than
                // concealing a file the person would be changing.
                guard safeFiles(preview.result.filesChanged, session: session) else {
                    return .failure(RemoteError(.notAllowed))
                }
                remoteFilePreviews[taskID] = preview
                value = remoteRewindResult(preview.result, session: session)
                value.receipt = preview.id.uuidString
            case .restore:
                guard confirmed, let permit, permit.isValid, let preview = remoteFilePreviews[taskID], preview.id.uuidString == receipt,
                      preview.result.filesChanged != nil,
                      safeFiles(preview.result.filesChanged, session: session) else {
                    return .failure(RemoteError(.notAllowed))
                }
                remoteFilePreviews[taskID] = nil
                let result = try await model.restoreClaudeFiles(preview, authorizing: {
                    guard permit.isValid else { throw RemoteError(.notAllowed) }
                })
                guard safeFiles(result.filesChanged, session: session) else { return .failure(RemoteError(.notAllowed)) }
                value = remoteRewindResult(result, session: session)
            }
            return .success(value)
        } catch let error as RemoteError {
            return .failure(error)
        } catch {
            // Provider errors can contain storage paths or credentials.
            return .failure(RemoteError(.unavailable))
        }
    }

    private func safeFiles(_ files: [String]?, session: SessionRecord) -> Bool {
        guard let files else { return true }
        let root = session.workspaceURL.resolvingSymlinksInPath().standardizedFileURL.path
        return files.count <= 500 && files.allSatisfy { file in
            let url = file.hasPrefix("/") ? URL(fileURLWithPath: file) : session.workspaceURL.appendingPathComponent(file)
            return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/")
        }
    }

    private func remoteRewindResult(_ result: HarnessFileRewindResult, session: SessionRecord) -> RemoteFileRewind {
        var value = RemoteFileRewind()
        value.canRewind = result.canRewind
        value.files = result.filesChanged?.map { path in
            let root = session.workspaceURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : session.workspaceURL.appendingPathComponent(path)
            return String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(root.count))
        }
        value.insertions = result.insertions; value.deletions = result.deletions
        value.skippedLinks = result.skippedLinks; value.inFlight = result.inFlight
        return value
    }
}
