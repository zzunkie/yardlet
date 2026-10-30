import Foundation

/// Reads what a Claude Code background task wrote: the CLI keeps each task's output in a file of its
/// own while it runs (2.1.291 `cp`: `<temp root>/<folder>/<session>/tasks/<task>.output`, the temp root
/// `claude-<uid>` under the system's temporary folder, the folder a sanitized form of the task's
/// working directory). The Claude app shows that file when a background task's row is opened
/// ("View live output"). Yardlet only reads it: it finds the file by the session and task IDs under
/// the temp root, never builds the folder's name, and reads the newest part.
struct ClaudeTaskOutputReader: Sendable {
    /// The CLI's temp roots to look under.
    var roots: [URL]
    /// The most of the file's end that is read.
    var limit = 64 * 1024

    init(roots: [URL] = ClaudeTaskOutputReader.defaultRoots, limit: Int = 64 * 1024) {
        self.roots = roots
        self.limit = limit
    }

    /// `/tmp/claude-<uid>` (the CLI's default, `/private/tmp` on macOS) and the same under the
    /// process's temporary folder and `CLAUDE_CODE_TMPDIR`, each once.
    static var defaultRoots: [URL] {
        #if os(Windows)
        // Where the CLI keeps a task's output on Windows is not confirmed, so nothing is looked up there.
        return []
        #else
        let name = "claude-\(getuid())"
        var bases = ["/private/tmp", NSTemporaryDirectory()]
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CODE_TMPDIR"], !configured.isEmpty {
            bases.insert(configured, at: 0)
        }
        var seen = Set<String>()
        return bases.compactMap { base in
            let url = URL(filePath: base, directoryHint: .isDirectory).appending(path: name, directoryHint: .isDirectory)
                .standardizedFileURL.resolvingSymlinksInPath()
            return seen.insert(url.path(percentEncoded: false)).inserted ? url : nil
        }
        #endif
    }

    /// The task's output file, or nil where none is found. IDs that are not the CLI's shapes find nothing.
    func file(taskID: String, sessionID: String) -> URL? {
        guard Self.isTaskID(taskID), UUID(uuidString: sessionID) != nil else { return nil }
        let manager = FileManager.default
        for root in roots {
            guard let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles]) else { continue }
            for folder in folders {
                let candidate = folder.appending(path: sessionID, directoryHint: .isDirectory)
                    .appending(path: "tasks", directoryHint: .isDirectory)
                    .appending(path: "\(taskID).output")
                if manager.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
            }
        }
        return nil
    }

    /// The newest `limit` bytes of the task's output, starting at a whole line; nil where no file is found.
    func read(taskID: String, sessionID: String) -> Output? {
        guard let url = file(taskID: taskID, sessionID: sessionID),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        try? handle.seek(toOffset: start)
        var data = (try? handle.readToEnd()) ?? Data()
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: newline)...]
        }
        return Output(text: String(decoding: data, as: UTF8.self), isTruncated: start > 0, url: url)
    }

    struct Output: Equatable, Sendable {
        var text: String
        /// Earlier output is left out.
        var isTruncated: Bool
        var url: URL
    }

    /// Claude Code's task IDs: a type letter and eight base-36 characters (`fE`), or a longer agent ID.
    static func isTaskID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
