import Foundation

/// Codex file changes as git-style unified diffs, the form the review panel's parser reads.
///
/// An App Server `FileUpdateChange` is `{path, kind, diff}`. For `update` the diff is the hunks
/// alone (`@@ …`), with no file headers, and `kind.move_path` names a rename; for `add` and
/// `delete` it is the file's whole text. Paths are absolute. Recorded Codex rollouts carry the
/// same shapes (`unified_diff` for updates, `content` for additions), which is what these
/// headers are built around.
enum CodexFileChangeDiff {
    /// One change as a unified diff with `diff --git` headers, or nil without a path.
    static func unifiedDiff(for change: JSONValue, workspaceURL: URL?) -> String? {
        guard let path = change["path"]?.stringValue, !path.isEmpty else { return nil }
        let kind = change["kind"]?["type"]?.stringValue ?? change["kind"]?.stringValue ?? "update"
        let body = change["diff"]?.stringValue ?? ""
        let oldPath = displayPath(path, workspaceURL: workspaceURL)
        let newPath = change["kind"]?["move_path"]?.stringValue.map { displayPath($0, workspaceURL: workspaceURL) } ?? oldPath
        var lines = ["diff --git a/\(oldPath) b/\(newPath)"]
        switch kind {
        case "add":
            lines += ["new file mode 100644", "--- /dev/null", "+++ b/\(newPath)"]
            lines += isHunks(body) ? hunkLines(body) : wholeFile(body, marker: "+")
        case "delete":
            lines += ["deleted file mode 100644", "--- a/\(oldPath)", "+++ /dev/null"]
            lines += isHunks(body) ? hunkLines(body) : wholeFile(body, marker: "-")
        default:
            if newPath != oldPath { lines += ["rename from \(oldPath)", "rename to \(newPath)"] }
            lines += ["--- a/\(oldPath)", "+++ b/\(newPath)"]
            lines += hunkLines(body)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Every change of a file change item, in order.
    static func unifiedDiff(for changes: [JSONValue], workspaceURL: URL?) -> String {
        changes.compactMap { unifiedDiff(for: $0, workspaceURL: workspaceURL) }.joined()
    }

    /// Added and removed line counts of one change, for a file row's `+n −m`. The same counts the
    /// parser gives for `unifiedDiff(for:)`, read in one pass over the provider's text because a
    /// streaming card asks again on every update.
    static func lineCounts(for change: JSONValue) -> (additions: Int, deletions: Int) {
        guard let path = change["path"]?.stringValue, !path.isEmpty else { return (0, 0) }
        let kind = change["kind"]?["type"]?.stringValue ?? change["kind"]?.stringValue ?? "update"
        let body = change["diff"]?.stringValue ?? ""
        if !isHunks(body), kind == "add" || kind == "delete" {
            let newlines = body.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
            let count = newlines + (body.isEmpty || body.hasSuffix("\n") ? 0 : 1)
            return kind == "add" ? (count, 0) : (0, count)
        }
        var additions = 0
        var deletions = 0
        var inHunk = false
        let utf8 = body.utf8
        var start = utf8.startIndex
        while start < utf8.endIndex {
            let end = utf8[start...].firstIndex(of: UInt8(ascii: "\n")) ?? utf8.endIndex
            let line = body[start..<end]
            start = end < utf8.endIndex ? utf8.index(after: end) : end
            if line.hasPrefix("diff --git ") {
                inHunk = false
            } else if line.hasPrefix("@@ ") {
                let (old, new) = UnifiedDiffParser.hunkStart(line)
                inHunk = old != nil && new != nil
            } else if inHunk, line.hasPrefix("+") {
                additions += 1
            } else if inHunk, line.hasPrefix("-") {
                deletions += 1
            }
        }
        return (additions, deletions)
    }

    /// Inside the task's folder a path is shown relative to it; elsewhere it stays absolute.
    static func displayPath(_ path: String, workspaceURL: URL?) -> String {
        guard let workspaceURL else { return path }
        let relative = PathRules.current.relativePath(of: URL(filePath: path).standardizedFileURL,
                                                      in: workspaceURL.standardizedFileURL)
        return relative.flatMap { $0.isEmpty ? nil : $0 } ?? path
    }

    private static func isHunks(_ body: String) -> Bool {
        body.hasPrefix("@@ ")
    }

    private static func hunkLines(_ body: String) -> [String] {
        var lines = body.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// A whole file's text as one hunk of added or removed lines.
    private static func wholeFile(_ text: String, marker: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return [] }
        let range = marker == "+" ? "@@ -0,0 +1,\(lines.count) @@" : "@@ -1,\(lines.count) +0,0 @@"
        return [range] + lines.map { marker + $0 }
    }
}
