import Foundation
import YardletRemote

extension AppModelRemoteBridge {
    /// A device's save from the remote Files panel (docs/REMOTE_PROTOCOL.md §15.27), as the local panel saves: the
    /// task's working folder only, over the bytes the device read, through the same replacement. The server took the
    /// permit with its `fileWrites` check.
    func writeFile(taskID: String, path: String, data: Data, sha256: String,
                   permit: RemoteFileWritePermit) async -> RemoteError? {
        guard let session = session(taskID) else { return RemoteError(.notFound) }
        let scope = RemoteFileScope(folder: session.workspaceURL)
        return await RemoteFileReader.perform {
            Self.writeWorkspaceFile(path, data: data, sha256: sha256, in: scope, permit: permit)
        }
    }

    /// Replaces the file `RemoteFileReader.writeTarget` allows with `data` while it still holds the bytes whose SHA-256
    /// is `sha256`, in one rename, keeping its permissions, and only while `permit` holds when the new file takes the old
    /// one's place. A refusal names neither the path nor what the file holds. Blocks.
    nonisolated static func writeWorkspaceFile(_ path: String, data: Data, sha256: String, in scope: RemoteFileScope,
                                               permit: RemoteFileWritePermit,
                                               home: String = NSHomeDirectory()) -> RemoteError? {
        guard data.count <= RemoteProtocol.maxWriteFileBytes else { return RemoteError(.tooLarge) }
        let target: RemoteFileWriteTarget
        switch RemoteFileReader.writeTarget(path, in: scope, home: home) {
        case let .success(found): target = found
        case let .failure(error): return error
        }
        do {
            try WorkspaceFileReplacement.replace(path: target.path, in: target.folder, with: data, expectedDigest: sha256,
                                                 maximumBytes: RemoteProtocol.maxWriteFileBytes) {
                guard permit.isValid else { throw RemoteError(.notAllowed, "Write files is off", reason: .fileWrites) }
            }
            return nil
        } catch let error as RemoteError {
            return error
        } catch WorkspaceFileError.changedOnDisk {
            return RemoteError(.notAllowed, "The file changed since it was read", reason: .fileChanged)
        } catch WorkspaceFileError.notAFile {
            return RemoteError(.notAllowed, "Not a file of the task's folder that can be written")
        } catch {
            // The file system's own errors can name the file.
            return RemoteError(.unavailable, "The file could not be written")
        }
    }
}
