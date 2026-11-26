import Foundation
import Observation
import YardletRemote

/// Where files read from a Mac are kept while they are shown (docs/REMOTE_PROTOCOL.md §15.22): the app's Caches, which
/// are never backed up, one folder per file under the Mac's own, `mac-files/<Mac>/<file>/<its name>`. A file goes when
/// its viewer closes, a Mac's folder when that Mac is forgotten or the demo ends, and all of them when the app starts.
enum MacFileStore {
    static let root = URL.cachesDirectory.appending(path: "mac-files", directoryHint: .isDirectory)

    /// A new folder for one of the Mac's files; `RemoteFileDownload` creates it.
    static func newFolder(hostID: String) -> URL {
        folder(hostID: hostID).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    static func clear(hostID: String) {
        try? FileManager.default.removeItem(at: folder(hostID: hostID))
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func folder(hostID: String) -> URL {
        root.appending(path: RemoteFileDownload.safeName(hostID), directoryHint: .isDirectory)
    }
}

/// One of a task's files asked for from the conversation (an output, or a path an answer names), while it comes from
/// the Mac and while it is shown. It shows once the first part came or after a moment, so a path the Mac refuses gives
/// only its line; then how far it came and a way to stop. Cancelling it, or closing the viewer, deletes what was read.
@MainActor
@Observable
final class MacFileReading {
    private(set) var name: String
    private(set) var received = 0
    private(set) var size: Int?
    private(set) var isShown = false
    /// The file read whole, for the viewer.
    private(set) var file: URL?

    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var reading: Task<Void, Never>?

    /// A refusal is quicker than this, so a path the Mac will not open never flashes the progress.
    static let revealDelay: Duration = .milliseconds(400)

    init(path: String, hostID: String) {
        name = URL(filePath: path).lastPathComponent
        folder = MacFileStore.newFolder(hostID: hostID)
    }

    enum Outcome {
        case read(URL)
        /// Why it did not come, in a line; nil when it was cancelled.
        case failed(String?)
    }

    /// Reads it from the Mac; `finished` gets the file, or why it did not come.
    func start(_ path: String, of taskID: String, from session: HostSession,
               finished: @escaping @MainActor (Outcome) -> Void) {
        let reveal = Task { [weak self] in
            try? await Task.sleep(for: Self.revealDelay)
            if !Task.isCancelled { self?.isShown = true }
        }
        let folder = folder
        let host = session.name
        reading = Task { [weak self] in
            let result = await session.readFile(path, of: taskID, into: folder) { [weak self] progress in
                guard let self else { return }
                name = progress.name
                received = progress.received
                size = progress.size
                isShown = true
            }
            reveal.cancel()
            switch result {
            case let .success(file):
                self?.name = file.name
                self?.file = file.url
                finished(.read(file.url))
            case let .failure(failure):
                finished(.failed(Self.message(for: failure, host: host)))
            }
        }
    }

    /// Stops it, or lets go of the file read, deleting it either way.
    func close() {
        reading?.cancel()
        reading = nil
        try? FileManager.default.removeItem(at: folder)
    }

    /// Why a file did not come, in a line (§15.22): refused or not there, which the Mac does not tell apart.
    static func message(for failure: RemoteFileDownload.Failure, host: String) -> String? {
        switch failure {
        case let .refused(error?) where error.code == .notFound:
            String(localized: "Can't open this file on \(host).")
        case let .refused(error?) where error.code == .rateLimited:
            HostSession.message(for: error, host: host)
        case .tooLarge:
            String(localized: "This file is too large to open on the phone.")
        case .changing:
            String(localized: "The file kept changing on \(host).")
        case .notConnected:
            HostSession.message(for: RemoteError(.unavailable), host: host)
        case .refused, .unwritable:
            String(localized: "Couldn't get the file.")
        case .cancelled:
            nil
        }
    }
}

/// Which words of an agent's answer name a file the phone may ask the Mac for (§15.22), and which links name a task.
/// The Mac decides what it serves; this only keeps words that are clearly not files (a command, an API route, a web
/// address) from looking like something to open.
enum ConversationLinks {
    /// The scheme of the links the phone puts on code spans that name a file.
    static let fileScheme = "yardlet-file"

    /// The task a link `[title](#<task ID>)` or `conversation://<ID>` (as Antigravity links a conversation) names,
    /// in upper case as the Mac writes its IDs. No app opens a conversation link, so it never leaves the phone.
    static func task(_ url: URL) -> String? {
        let text = url.absoluteString
        if text.hasPrefix("#") { return UUID(uuidString: String(text.dropFirst()))?.uuidString }
        guard url.scheme?.lowercased() == "conversation", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, ["", "/"].contains(url.path(percentEncoded: false)),
              let host = url.host(percentEncoded: false) else { return nil }
        return UUID(uuidString: host)?.uuidString
    }

    /// The file a link names: a code span's (`fileLink`) or an answer's own link to a path.
    static func file(_ url: URL) -> String? {
        if url.scheme == fileScheme {
            guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, !raw.isEmpty else { return nil }
            if let normalized = path(raw) { return normalized }
            // A Markdown image/file chip may name a bare workspace-relative file such as `chart.png`.
            return bareFilePath(raw)
        }
        return path(url.absoluteString, link: true)
    }

    private static func bareFilePath(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 1_024, !text.contains("/"), !text.hasPrefix("$"),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "*?<>|\"`\\".unicodeScalars.contains($0) })
        else { return nil }
        return hasExtension(text) ? text : nil
    }

    /// The link a code span that names a file opens.
    static func fileLink(_ path: String) -> URL? {
        var components = URLComponents()
        components.scheme = fileScheme
        components.path = path
        return components.url
    }

    /// The path a code span or a link names, or nil. It counts when it is:
    /// - under the home folder (`~/notes.md`),
    /// - absolute and either under one of a Mac's top folders (`/Users/…`, `/tmp/…`) or ending in a name with an
    ///   extension (`/srv/report.pdf`), so `/v2/search` stays a route,
    /// - relative with a folder and a name with an extension (`reports/crash-notes.txt`), as the task's folder holds
    ///   it, without a shell variable, and in a code span without spaces (`cat src/app.ts` is a command).
    ///
    /// A line or column after it (`:12`, `:12:3`, `#L12-L20`) is left off. A link's `file://` and its
    /// percent-escapes are undone. An absolute path may have spaces when it ends in a name with an extension.
    static func path(_ raw: String, link: Bool = false) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<"), text.hasSuffix(">"), text.count >= 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if link {
            if text.lowercased().hasPrefix("file://") {
                text = String(text.dropFirst("file://".count))
                if text.hasPrefix("localhost") { text = String(text.dropFirst("localhost".count)) }
                guard text.hasPrefix("/") else { return nil }
            }
            guard let decoded = text.removingPercentEncoding else { return nil }
            text = decoded
        }
        guard !text.isEmpty, text.count <= 1_024, text.firstMatch(of: /^[A-Za-z][A-Za-z0-9+.\-]*:\/\//) == nil else {
            return nil
        }
        text = text.replacing(/(:\d+(:\d+)?|#L\d+(C\d+)?(-L?\d+(C\d+)?)?)$/, with: "")
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "*?<>|\"`\\".unicodeScalars.contains($0) })
        else { return nil }
        let name = text.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? text
        let hasExtension = hasExtension(name)
        let hasSpace = text.contains { $0.isWhitespace }
        if hasSpace && !hasExtension { return nil }
        if text.hasPrefix("~/") { return text.count > 2 ? text : nil }
        if text.hasPrefix("/") {
            guard !text.hasPrefix("//"), text.count >= 2 else { return nil }
            let top = text.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return hasExtension || (macTopFolders.contains(top) && text.filter { $0 == "/" }.count >= 2) ? text : nil
        }
        if text.hasPrefix("$") || (!link && hasSpace) { return nil }
        return text.contains("/") && !text.contains("//") && hasExtension ? text : nil
    }

    /// `report.pdf`, `.env`: a name with an extension of letters or digits that is not all digits.
    private static func hasExtension(_ name: String) -> Bool {
        if name.count > 1, name.hasPrefix("."), name.filter({ $0 == "." }).count == 1 { return true }
        guard let dot = name.lastIndex(of: ".") else { return false }
        let ext = name[name.index(after: dot)...]
        return dot > name.startIndex && (1...10).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber }
            && !ext.allSatisfy(\.isNumber)
    }

    /// Folders at the top of a Mac's disk that paths start from.
    private static let macTopFolders: Set<String> = [
        "Users", "Volumes", "private", "tmp", "var", "opt", "etc", "Applications", "Library", "System", "usr", "home"
    ]
}

// MARK: - In-memory file reading for inline images (§15.22)

enum MacFileDataFailure: Error, Equatable, Sendable {
    /// The file exceeds the requested byte limit; carries the host-reported byte size when known.
    case tooLarge(size: Int?)
    case refused(RemoteError?)
    case changing
    case notConnected
    case cancelled
}

extension HostSession {
    /// Reads a task file directly into memory via `readFile` (§15.22) without writing to disk. Stops immediately on
    /// the first part if the reported size exceeds `maxBytes` so mobile and relay bandwidth are protected.
    func readFileData(_ path: String, of taskID: String, maxBytes: Int) async -> Result<Data, MacFileDataFailure> {
        let maxRestarts = 3
        let maxRateLimitedWaits = 10
        var firstSize: Int?
        var firstModifiedAt: Int64?
        var buffer = Data()
        var offset = 0
        var restarts = 0
        var waits = 0

        while true {
            if Task.isCancelled { return .failure(.cancelled) }
            guard isConnected else { return .failure(.notConnected) }

            let part = await response(to: .readFile(taskID: taskID, path: path, offset: offset))
            if Task.isCancelled { return .failure(.cancelled) }

            guard part.ok else {
                switch part.error?.code {
                case .unavailable?:
                    return .failure(.notConnected)
                case .rateLimited? where waits < maxRateLimitedWaits:
                    waits += 1
                    try? await Task.sleep(for: .seconds(1))
                    continue
                case .tooLarge?:
                    return .failure(.tooLarge(size: nil))
                default:
                    return .failure(.refused(part.error))
                }
            }

            waits = 0
            guard let size = part.size, let chunk = part.data, part.offset == offset, offset + chunk.count <= size else {
                return .failure(.refused(nil))
            }
            if size > maxBytes {
                return .failure(.tooLarge(size: size))
            }
            if let expectedSize = firstSize, size != expectedSize || part.modifiedAt != firstModifiedAt {
                restarts += 1
                guard restarts <= maxRestarts else { return .failure(.changing) }
                firstSize = nil
                firstModifiedAt = nil
                buffer.removeAll(keepingCapacity: true)
                offset = 0
                continue
            }
            if firstSize == nil {
                firstSize = size
                firstModifiedAt = part.modifiedAt
                buffer.reserveCapacity(size)
            }
            buffer.append(chunk)
            if buffer.count > maxBytes {
                return .failure(.tooLarge(size: size))
            }
            offset += chunk.count
            if offset >= size { return .success(buffer) }
            if chunk.isEmpty { return .failure(.refused(nil)) }
        }
    }
}
