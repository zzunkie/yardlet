import Foundation

enum DiffLineKind: String, Codable, Equatable, Sendable {
    case fileHeader, hunkHeader, addition, deletion, context, metadata
}

struct DiffLine: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let kind: DiffLineKind
    let text: String
    var oldLine: Int? = nil
    var newLine: Int? = nil
}

struct DiffFile: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let oldPath: String?
    let newPath: String?
    let lines: [DiffLine]

    var path: String { newPath ?? oldPath ?? L10n.string("Unknown file") }
    var additionCount: Int { lines.filter { $0.kind == .addition }.count }
    var deletionCount: Int { lines.filter { $0.kind == .deletion }.count }
    var isBinary: Bool { lines.contains { $0.text.hasPrefix("Binary files ") || $0.text == "GIT binary patch" } }
    var status: String {
        if oldPath == nil { return L10n.string("Added") }
        if newPath == nil { return L10n.string("Deleted") }
        if oldPath != newPath { return L10n.string("Renamed") }
        return L10n.string("Modified")
    }
}

struct DiffSnapshot: Codable, Equatable, Sendable {
    let lines: [DiffLine]
    let isTruncated: Bool
    let files: [DiffFile]

    init(lines: [DiffLine], isTruncated: Bool) {
        self.lines = lines
        self.isTruncated = isTruncated
        self.files = UnifiedDiffParser.files(from: lines)
    }

    var isEmpty: Bool { files.isEmpty }
    var fileCount: Int { files.count }
    var additionCount: Int { lines.filter { $0.kind == .addition }.count }
    var deletionCount: Int { lines.filter { $0.kind == .deletion }.count }
    /// The unified diff again, as the remote Review sends it and identifies it before a change (§15.26).
    var text: String { lines.map(\.text).joined(separator: "\n") }
}

struct UnifiedDiffParser: Sendable {
    /// Parses at most `byteLimit` bytes, ending on a whole line; a longer text is marked truncated.
    func parse(_ text: String, byteLimit: Int) -> DiffSnapshot {
        guard text.utf8.count > byteLimit else { return parse(text) }
        var head = String(decoding: text.utf8.prefix(byteLimit), as: UTF8.self)
        if let newline = head.lastIndex(of: "\n") { head = String(head[...newline]) }
        return parse(head, isTruncated: true)
    }

    func parse(_ text: String, isTruncated: Bool = false) -> DiffSnapshot {
        guard !text.isEmpty else { return DiffSnapshot(lines: [], isTruncated: isTruncated) }
        var source = text.components(separatedBy: "\n")
        if source.last == "" { source.removeLast() }
        var oldLine: Int?
        var newLine: Int?
        let lines = source.enumerated().map { index, text -> DiffLine in
            var kind: DiffLineKind = .metadata
            var oldNumber: Int?
            var newNumber: Int?
            if text.hasPrefix("diff --git ") {
                oldLine = nil; newLine = nil
                kind = .fileHeader
            } else if text.hasPrefix("@@ ") {
                (oldLine, newLine) = Self.hunkStart(text)
                kind = .hunkHeader
            } else if oldLine != nil, newLine != nil {
                // Content can start with --- or +++; only pre-hunk lines are file headers.
                if text.hasPrefix("+") {
                    kind = .addition; newNumber = newLine; newLine! += 1
                } else if text.hasPrefix("-") {
                    kind = .deletion; oldNumber = oldLine; oldLine! += 1
                } else if text.hasPrefix(" ") {
                    kind = .context; oldNumber = oldLine; newNumber = newLine
                    oldLine! += 1; newLine! += 1
                }
            } else if text.hasPrefix("--- ") || text.hasPrefix("+++ ") {
                kind = .fileHeader
            }
            return DiffLine(id: index, kind: kind, text: text, oldLine: oldNumber, newLine: newNumber)
        }
        return DiffSnapshot(lines: lines, isTruncated: isTruncated)
    }

    static func hunkStart<Line: StringProtocol>(_ text: Line) -> (Int?, Int?) {
        let parts = text.split(separator: " ")
        guard parts.count >= 4, parts[0] == "@@", parts[3] == "@@",
              parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return (nil, nil) }
        return (parts[1].dropFirst().split(separator: ",").first.flatMap { Int($0) },
                parts[2].dropFirst().split(separator: ",").first.flatMap { Int($0) })
    }

    static func files(from lines: [DiffLine]) -> [DiffFile] {
        let starts = lines.indices.filter { lines[$0].text.hasPrefix("diff --git ") }
        return starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1] : lines.endIndex
            let block = Array(lines[start..<end])
            let header = String(block[0].text.dropFirst("diff --git ".count))
            let paths = headerPaths(header)
            var oldPath = paths.0
            var newPath = paths.1
            for line in block where line.kind == .fileHeader || line.kind == .metadata {
                if line.text.hasPrefix("--- ") { oldPath = path(String(line.text.dropFirst(4))) }
                if line.text.hasPrefix("+++ ") { newPath = path(String(line.text.dropFirst(4))) }
                if line.text.hasPrefix("new file mode ") { oldPath = nil }
                if line.text.hasPrefix("deleted file mode ") { newPath = nil }
                if line.text.hasPrefix("rename from ") { oldPath = unquote(String(line.text.dropFirst(12))) }
                if line.text.hasPrefix("rename to ") { newPath = unquote(String(line.text.dropFirst(10))) }
            }
            return DiffFile(id: start, oldPath: oldPath, newPath: newPath, lines: block)
        }
    }

    private static func headerPaths(_ value: String) -> (String?, String?) {
        if value.hasPrefix("\"") {
            var escaped = false
            for index in value.indices.dropFirst() {
                let character = value[index]
                if character == "\"", !escaped {
                    let end = value.index(after: index)
                    return (path(String(value[..<end])), path(String(value[end...]).trimmingCharacters(in: .whitespaces)))
                }
                if character == "\\", !escaped { escaped = true } else { escaped = false }
            }
        }
        var search = value.startIndex..<value.endIndex
        while let separator = value.range(of: " b/", range: search) {
            let left = String(value[..<separator.lowerBound])
            let right = String(value[separator.upperBound...])
            if left.hasPrefix("a/"), String(left.dropFirst(2)) == right {
                return (right, right)
            }
            search = separator.upperBound..<value.endIndex
        }
        if let separator = value.range(of: " b/", options: .backwards) {
            return (path(String(value[..<separator.lowerBound])), path(String(value[separator.upperBound...]), prefixed: false))
        }
        return (nil, nil)
    }

    private static func path(_ value: String, prefixed: Bool = true) -> String? {
        let raw = value.hasPrefix("\"") ? value : value.components(separatedBy: "\t")[0]
        let decoded = unquote(raw)
        guard decoded != "/dev/null" else { return nil }
        if prefixed && (decoded.hasPrefix("a/") || decoded.hasPrefix("b/")) { return String(decoded.dropFirst(2)) }
        return decoded
    }

    /// Git's quoted paths use C escapes and octal UTF-8 bytes, including spaces/newlines.
    private static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        let bytes = Array(value.dropFirst().dropLast().utf8)
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 92, index + 1 < bytes.count {
                index += 1
                if (48...55).contains(bytes[index]) {
                    var number = 0
                    var count = 0
                    while index < bytes.count, (48...55).contains(bytes[index]), count < 3 {
                        number = number * 8 + Int(bytes[index] - 48); index += 1; count += 1
                    }
                    result.append(UInt8(truncatingIfNeeded: number)); continue
                }
                result.append([UInt8(110): 10, 116: 9, 114: 13, 98: 8, 102: 12, 118: 11, 97: 7][bytes[index]] ?? bytes[index])
            } else { result.append(bytes[index]) }
            index += 1
        }
        return String(decoding: result, as: UTF8.self)
    }
}
