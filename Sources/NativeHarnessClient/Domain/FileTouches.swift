import Foundation

// The files a task read and edited, which the review and the files panel read back as "the tasks that
// edited this file". Each task's touches are kept in Yardlet's own folder
// (`FileTouchRepository`, docs/NATIVE_SESSION_STORAGE.md, "Index of tasks that touched a file"): a Claude Code task's are read
// from its transcript, which they can be read again from; any other task's are what Yardlet has read of
// it. Nothing here writes a provider's record.

enum FileTouchKind: String, Codable, Equatable, Sendable {
    case edit
    case read
}

/// One call that read or edited a file: the path as the call named it, when, and the call's ID, which
/// the conversation finds the call by (a Claude Code `tool_use` ID, a Codex item ID).
struct FileTouch: Codable, Equatable, Sendable {
    let path: String
    let kind: FileTouchKind
    let at: Date
    let callID: String
}

struct FileTouchMark: Codable, Equatable, Sendable {
    let at: Date
    let callID: String
}

/// A task's newest edit and newest read of one file.
struct FileTouchMarks: Codable, Equatable, Sendable {
    var edit: FileTouchMark?
    var read: FileTouchMark?

    mutating func record(_ kind: FileTouchKind, _ mark: FileTouchMark) {
        switch kind {
        case .edit: if edit.map({ $0.at <= mark.at }) ?? true { edit = mark }
        case .read: if read.map({ $0.at <= mark.at }) ?? true { read = mark }
        }
    }
}

/// Where the reading of a Claude Code transcript stopped: the conversation, the file it was (device
/// and inode), and just past the last whole line read.
struct ClaudeFileTouchCursor: Codable, Equatable, Sendable {
    let providerSessionID: String
    let device: Int64
    let inode: UInt64
    let offset: Int64
    /// Where beneath the config's `projects` folder the transcript was, so the next reading of the same
    /// file need not look through every project folder for it.
    var path: [String]? = nil
}

/// One task's touches as Yardlet keeps them.
struct FileTouches: Codable, Equatable, Sendable {
    /// The calls whose result has not been read yet: a read or an edit counts as one once its result
    /// does not say it failed, and a call still running counts as one meanwhile.
    static let openCallLimit = 256

    var files: [String: FileTouchMarks] = [:]
    var openCalls: [String: FileTouch] = [:]
    /// Nil for a task whose touches are what Yardlet has read of it rather than a Claude Code transcript.
    var claudeScan: ClaudeFileTouchCursor?

    mutating func record(_ touch: FileTouch) {
        files[touch.path, default: FileTouchMarks()].record(touch.kind, FileTouchMark(at: touch.at, callID: touch.callID))
    }

    /// A call whose result is still to come.
    mutating func open(_ touch: FileTouch) {
        openCalls[touch.callID] = touch
        guard openCalls.count > Self.openCallLimit,
              let oldest = openCalls.values.min(by: { $0.at < $1.at }) else { return }
        openCalls.removeValue(forKey: oldest.callID)
    }

    /// The call's result came: it counts unless the result says it failed.
    mutating func close(_ callID: String, failed: Bool) {
        guard let touch = openCalls.removeValue(forKey: callID) else { return }
        if !failed { record(touch) }
    }

    /// Every file with its marks, the calls still open counted.
    var marksWithOpenCalls: [String: FileTouchMarks] {
        var marks = files
        for touch in openCalls.values {
            marks[touch.path, default: FileTouchMarks()].record(touch.kind, FileTouchMark(at: touch.at, callID: touch.callID))
        }
        return marks
    }
}

/// Reads the files a Claude Code conversation's calls read and edited from its transcript, forward from
/// where the last reading stopped, whole lines only, as `ClaudePullRequestLinkScanner` reads forward.
///
/// A call is an `assistant` record's `tool_use` block: Read reads `file_path`; Edit, MultiEdit and Write
/// edit `file_path`; NotebookEdit edits `notebook_path`. Its result is a `user` record's `tool_result`
/// block naming the call's ID, which says `"is_error":true` when the call failed. A line is parsed only
/// when it holds a call (`"type":"tool_use"`) or the result of a call still open; a result line is parsed
/// only when it also says a call failed. A subagent's own records (`isSidechain`) are not the task's
/// conversation and are left out.
enum ClaudeFileTouchScanner {
    static let chunkBytes = 1 << 20

    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    static let readTools: Set<String> = ["Read"]

    /// - Parameters:
    ///   - size: the file's size now.
    ///   - previous: the task's touches so far; their reading goes on when it was this conversation's
    ///     file and the file has not shrunk, and starts over otherwise.
    ///   - read: the bytes at an offset, at most `count` of them.
    static func scan(
        providerSessionID: String, device: Int64, inode: UInt64, size: Int64, previous: FileTouches,
        read: (_ offset: Int64, _ count: Int) throws -> Data
    ) throws -> FileTouches {
        var touches = previous
        var position: Int64 = 0
        if let cursor = previous.claudeScan, cursor.providerSessionID == providerSessionID,
           cursor.device == device, cursor.inode == inode, cursor.offset <= size {
            position = cursor.offset
        } else {
            touches = FileTouches()
        }
        var scannedThrough = position
        var carry = Data()
        while position < size {
            let count = Int(min(Int64(chunkBytes), size - position))
            let bytes = try read(position, count)
            guard !bytes.isEmpty else { break }
            position += Int64(bytes.count)
            carry.append(bytes)
            // Only whole lines: a line still being written is read next time.
            guard let lastNewline = carry.lastIndex(of: 10) else { continue }
            let whole = carry[carry.startIndex...lastNewline]
            readLines(whole, into: &touches)
            scannedThrough += Int64(whole.count)
            carry = Data(carry[(lastNewline + 1)...])
        }
        touches.claudeScan = ClaudeFileTouchCursor(providerSessionID: providerSessionID, device: device,
                                                   inode: inode, offset: scannedThrough)
        return touches
    }

    private static let callMarker = Data(#""type":"tool_use""#.utf8)
    private static let resultMarker = Data(#""tool_use_id":""#.utf8)
    private static let failureMarker = Data(#""is_error":true"#.utf8)

    static func readLines(_ data: Data, into touches: inout FileTouches) {
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 10) ?? data.endIndex
            let line = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : end
            if line.range(of: callMarker) != nil {
                for touch in calls(in: line) { touches.open(touch) }
            }
            guard !touches.openCalls.isEmpty else { continue }
            let named = resultIDs(in: line).filter { touches.openCalls[$0] != nil }
            guard !named.isEmpty else { continue }
            let failed = line.range(of: failureMarker) == nil ? [] : failedCalls(in: line)
            for id in named { touches.close(id, failed: failed.contains(id)) }
        }
    }

    /// The call IDs a line's results name (`"tool_use_id":"…"`), read without parsing the line: a
    /// result line can hold a whole file's text.
    private static func resultIDs(in line: Data) -> [String] {
        var ids: [String] = []
        var searchStart = line.startIndex
        while let marker = line.range(of: resultMarker, in: searchStart..<line.endIndex) {
            guard let close = line[marker.upperBound...].firstIndex(of: 34) else { break }
            ids.append(String(decoding: line[marker.upperBound..<close], as: UTF8.self))
            searchStart = close
        }
        return ids
    }

    /// The file calls an `assistant` record makes.
    private static func calls(in line: Data) -> [FileTouch] {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              record["type"] as? String == "assistant", record["isSidechain"] as? Bool != true,
              let content = (record["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
        let at = (record["timestamp"] as? String).flatMap(ClaudeSubagentTranscriptReader.timestamp) ?? Date(timeIntervalSince1970: 0)
        return content.compactMap { block in
            guard block["type"] as? String == "tool_use", let id = block["id"] as? String,
                  let name = block["name"] as? String, let input = block["input"] as? [String: Any] else { return nil }
            let kind: FileTouchKind
            if editTools.contains(name) { kind = .edit } else if readTools.contains(name) { kind = .read } else { return nil }
            guard let path = (input["file_path"] ?? input["notebook_path"]) as? String, PathRules.current.isAbsolute(path) else { return nil }
            return FileTouch(path: path, kind: kind, at: at, callID: id)
        }
    }

    /// The calls a `user` record's results say failed.
    private static func failedCalls(in line: Data) -> Set<String> {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let content = (record["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
        return Set(content.compactMap { block in
            block["type"] as? String == "tool_result" && block["is_error"] as? Bool == true
                ? block["tool_use_id"] as? String : nil
        })
    }
}
