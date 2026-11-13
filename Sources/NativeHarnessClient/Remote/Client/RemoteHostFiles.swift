import Foundation
import Observation
import YardletRemote

/// What a host's tasks made, as its window opens it (docs/REMOTE_PROTOCOL.md §15.22): a task's outputs,
/// as the host's Outputs card lists them, and a file the host serves, read in parts into a folder of its
/// own under this Mac's temporary folder, readable only by the person and never executable, so this Mac's
/// own viewer opens the copy. The copies go when the host's window closes. Offered only by a host whose
/// snapshot says `taskFiles`.
@MainActor
@Observable
final class RemoteHostFiles {
    enum Failure: Error, Equatable {
        /// The host does not serve it: not one of the task's outputs or folders, or not there.
        case notServed
        case tooLarge
        case unavailable(RemoteError?)
    }

    /// Each task's outputs once read, newest first.
    private(set) var outputs: [String: [RemoteOutput]] = [:]
    /// The file being read now, by its name, for the window's line.
    private(set) var reading: String?
    /// Each task's Files panel as it was left: the file open, where it was read and edits not saved yet, kept in memory
    /// only, so they outlast the panel while this window shows another task or tab.
    @ObservationIgnored var panels: [String: WorkspaceFilePreferences] = [:]
    @ObservationIgnored weak var model: RemoteHostModel?
    @ObservationIgnored private let folder: URL
    /// A read that waited this many times for the host's budget gives up.
    @ObservationIgnored static let rateLimitedRetries = 30

    init(hostID: String, temporaryFolder: URL = FileManager.default.temporaryDirectory) {
        folder = temporaryFolder.appending(path: "Yardlet remote files", directoryHint: .isDirectory)
            .appending(path: hostID, directoryHint: .isDirectory)
    }

    /// Reads the task's outputs again.
    func loadOutputs(_ taskID: String) {
        model?.request(.taskOutputs(taskID: taskID)) { [weak self] response in
            guard let self, response.ok else { return }
            let outputs = response.outputs ?? []
            if self.outputs[taskID] != outputs { self.outputs[taskID] = outputs }
        }
    }

    /// The file at `path` (absolute, `~/`, or relative to the task's folder as a conversation writes it),
    /// copied here. A link's line suffix (`:42`, `:42:5`) is tried without it when the whole path is not
    /// served, as a file link on the Mac is read.
    func copy(taskID: String, path: String) async -> Result<URL, Failure> {
        let result = await read(taskID: taskID, path: path)
        if case .failure(.notServed) = result, let range = path.firstRange(of: /:[0-9]+(:[0-9]+)?$/) {
            return await read(taskID: taskID, path: String(path[..<range.lowerBound]))
        }
        return result
    }

    /// Removes every copy this window made.
    func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func read(taskID: String, path: String) async -> Result<URL, Failure> {
        guard let model else { return .failure(.unavailable(nil)) }
        reading = URL(filePath: path).lastPathComponent
        defer { reading = nil }
        var restarts = 0
        var waits = 0
        restart: while restarts < 3 {
            restarts += 1
            var copy: (url: URL, handle: FileHandle)?
            var size: Int?
            var modifiedAt: Int64?
            var offset = 0
            defer { try? copy?.handle.close() }
            while true {
                let response = await model.response(to: .readFile(taskID: taskID, path: path, offset: offset))
                guard response.ok else {
                    switch response.error?.code {
                    case .rateLimited? where waits < Self.rateLimitedRetries:
                        // The host's budget refills in seconds (§15.22).
                        waits += 1
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    case .notFound?: return .failure(.notServed)
                    case .tooLarge?: return .failure(.tooLarge)
                    default: return .failure(.unavailable(response.error))
                    }
                }
                if size == nil {
                    size = response.size
                    modifiedAt = response.modifiedAt
                    guard let created = makeCopy(named: response.name ?? URL(filePath: path).lastPathComponent) else {
                        return .failure(.unavailable(nil))
                    }
                    copy = created
                } else if response.size != size || response.modifiedAt != modifiedAt {
                    // The file changed between parts: read it again from its start.
                    if let copy { try? FileManager.default.removeItem(at: copy.url.deletingLastPathComponent()) }
                    continue restart
                }
                let data = response.data ?? Data()
                do { try copy?.handle.write(contentsOf: data) } catch { return .failure(.unavailable(nil)) }
                offset += data.count
                if data.isEmpty || offset >= (size ?? 0) { break }
            }
            guard let url = copy?.url else { return .failure(.unavailable(nil)) }
            return .success(url)
        }
        return .failure(.unavailable(nil))
    }

    /// An empty file named as the host named it, alone in a new folder that only the person can open.
    private func makeCopy(named name: String) -> (url: URL, handle: FileHandle)? {
        let manager = FileManager.default
        let last = URL(filePath: name).lastPathComponent
        let safe = last.isEmpty || last == "." || last == ".." || last == "/" ? "file" : last
        let directory = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path(percentEncoded: false))
            let url = directory.appending(path: safe)
            try StateFile.write(Data(), to: url, isPrivate: true)
            return (url, try FileHandle(forWritingTo: url))
        } catch {
            return nil
        }
    }
}
