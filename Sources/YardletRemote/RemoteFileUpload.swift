import Foundation

/// A client sending a file up in parts (docs/REMOTE_PROTOCOL.md §15.20): the phone's composer and Yardlet's window on
/// another Mac. The file is read part by part off the caller's actor, and each part goes from the offset the host says
/// it holds, so a part the connection dropped is sent again.
public enum RemoteFileUpload {
    public enum Failure: Error, Equatable, Sendable {
        /// The file could not be opened or read, or is empty.
        case unreadable
        /// Over `RemoteProtocol.maxFileBytes`.
        case tooLarge
        /// The host refused a part (its error), or answered without taking the upload forward (nil).
        case refused(RemoteError?)
        /// The task sending it was cancelled: the attachment was removed.
        case cancelled
    }

    /// Sends the file at `url` with `send` and returns its upload ID once the host holds all of it. An answer that does
    /// not move the upload forward, with no `received` or one not past the part's offset or past the file's size, ends
    /// it rather than sending the same part again; so does cancelling the task.
    @concurrent
    public static func send(_ url: URL, mediaType: String, uploadID: String = UUID().uuidString,
                            through send: @Sendable (RemoteUploadPart) async -> RemoteResponse) async -> Result<String, Failure> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .failure(.unreadable) }
        defer { try? handle.close() }
        guard let size = try? Int(handle.seekToEnd()), size > 0 else { return .failure(.unreadable) }
        guard size <= RemoteProtocol.maxFileBytes else { return .failure(.tooLarge) }
        var offset = 0
        while offset < size {
            if Task.isCancelled { return .failure(.cancelled) }
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.read(upToCount: RemoteProtocol.maxUploadPartBytes), !data.isEmpty else {
                return .failure(.unreadable)
            }
            let first = offset == 0
            let part = RemoteUploadPart(uploadID: uploadID, name: first ? url.lastPathComponent : nil,
                                        mediaType: first ? mediaType : nil, size: first ? size : nil, offset: offset, data: data)
            let response = await send(part)
            if Task.isCancelled { return .failure(.cancelled) }
            guard response.ok else { return .failure(.refused(response.error)) }
            guard let received = response.received, received > offset, received <= size else {
                return .failure(.refused(nil))
            }
            offset = received
        }
        return .success(uploadID)
    }
}
