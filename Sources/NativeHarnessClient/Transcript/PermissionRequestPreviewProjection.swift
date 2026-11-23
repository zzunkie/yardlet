import Foundation

/// A requested change in the lines the file change card draws for an applied one. The tool sends
/// the text it replaces rather than where that text sits in the file, so the lines carry no
/// numbers, and unchanged lines away from a change fold into a rule as between hunks.
enum PermissionRequestPreviewProjection {
    typealias Line = CodexFileChangeCardProjection.Preview.Line

    /// Unchanged lines kept on each side of a change.
    static let contextRadius = 3
    /// Lines one preview draws; the rest are counted.
    static let lineLimit = 400

    struct Diff: Equatable {
        let lines: [Line]
        let additions: Int
        let deletions: Int
        /// Lines not drawn: past `lineLimit`, or past the bound the request was built with.
        let hiddenLineCount: Int
        let omittedEditCount: Int
    }

    /// Each edit's removed and added lines with nearby unchanged ones. When the request holds
    /// several edits, or replaces every occurrence, a caption row says so above the edit.
    static func diff(edits: [PermissionEditPreview], omittedEditCount: Int = 0) -> Diff {
        var rows: [(kind: Line.Kind, text: String)] = []
        var omitted = 0
        let total = edits.count + omittedEditCount
        for (index, edit) in edits.enumerated() {
            var caption: [String] = []
            if total > 1 { caption.append(L10n.format("Edit %lld of %lld", Int64(index + 1), Int64(total))) }
            if edit.replacesAll { caption.append(L10n.string("Replaces every occurrence")) }
            if !caption.isEmpty { rows.append((.separator, caption.joined(separator: " · "))) }
            rows += changedLines(from: lines(edit.oldText.text), to: lines(edit.newText.text))
            omitted += edit.oldText.omittedLineCount + edit.newText.omittedLineCount
        }
        return diff(rows, omitted: omitted, omittedEditCount: omittedEditCount)
    }

    /// A file's new contents, every line added.
    static func content(_ text: PermissionPreviewText) -> Diff {
        diff(lines(text.text).map { (.addition, $0) }, omitted: text.omittedLineCount, omittedEditCount: 0)
    }

    private static func diff(
        _ rows: [(kind: Line.Kind, text: String)], omitted: Int, omittedEditCount: Int
    ) -> Diff {
        let limit = CodexFileChangeCardProjection.lineCharacterLimit
        return Diff(
            lines: rows.prefix(lineLimit).enumerated().map { index, row in
                Line(
                    id: index,
                    kind: row.kind,
                    number: nil,
                    text: row.text.count > limit ? String(row.text.prefix(limit)) + "…" : row.text
                )
            },
            additions: rows.count(where: { $0.kind == .addition }),
            deletions: rows.count(where: { $0.kind == .deletion }),
            hiddenLineCount: max(0, rows.count - lineLimit) + omitted,
            omittedEditCount: omittedEditCount
        )
    }

    /// Upper bound on differing middle lines passed to `Array.difference(from:)` so a massive
    /// un-hunked rewrite cannot stall the main thread with O((N+M)*D) Myers work.
    static let maxDiffLines = 4_000

    /// Old lines a change removes come before the new lines it adds, as in a unified diff.
    static func changedLines(from old: [String], to new: [String]) -> [(kind: Line.Kind, text: String)] {
        let minCount = min(old.count, new.count)
        var prefix = 0
        while prefix < minCount, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while prefix + suffix < minCount, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let oldEnd = old.count - suffix
        let newEnd = new.count - suffix
        guard prefix < oldEnd || prefix < newEnd else { return [] }

        let oldMid = Array(old[prefix..<oldEnd])
        let newMid = Array(new[prefix..<newEnd])

        var midRows: [(kind: Line.Kind, text: String)] = []
        if oldMid.count + newMid.count > maxDiffLines {
            midRows.reserveCapacity(oldMid.count + newMid.count)
            for line in oldMid { midRows.append((.deletion, line)) }
            for line in newMid { midRows.append((.addition, line)) }
        } else {
            var removed: Set<Int> = []
            var inserted: Set<Int> = []
            for change in newMid.difference(from: oldMid) {
                switch change {
                case let .remove(offset, _, _): removed.insert(offset)
                case let .insert(offset, _, _): inserted.insert(offset)
                }
            }
            var oldIndex = 0
            var newIndex = 0
            while oldIndex < oldMid.count || newIndex < newMid.count {
                if oldIndex < oldMid.count, removed.contains(oldIndex) {
                    midRows.append((.deletion, oldMid[oldIndex]))
                    oldIndex += 1
                } else if newIndex < newMid.count, inserted.contains(newIndex) {
                    midRows.append((.addition, newMid[newIndex]))
                    newIndex += 1
                } else if oldIndex < oldMid.count, newIndex < newMid.count {
                    midRows.append((.context, newMid[newIndex]))
                    oldIndex += 1
                    newIndex += 1
                } else {
                    break
                }
            }
        }

        let changes = midRows.indices.filter { midRows[$0].kind != .context }
        var kept = Array(repeating: false, count: midRows.count)
        for index in changes {
            for near in max(0, index - contextRadius)...min(midRows.count - 1, index + contextRadius) {
                kept[near] = true
            }
        }
        var trimmed: [(kind: Line.Kind, text: String)] = []
        let leadStart = max(0, prefix - contextRadius)
        if leadStart < prefix {
            for index in leadStart..<prefix {
                trimmed.append((.context, old[index]))
            }
        }
        var skipped = false
        for (index, row) in midRows.enumerated() {
            guard kept[index] else {
                skipped = true
                continue
            }
            if skipped, !trimmed.isEmpty { trimmed.append((.separator, "")) }
            skipped = false
            trimmed.append(row)
        }
        let trailEnd = min(old.count, oldEnd + contextRadius)
        if oldEnd < trailEnd {
            for index in oldEnd..<trailEnd {
                trimmed.append((.context, old[index]))
            }
        }
        return trimmed
    }

    /// Splits text on LF, CRLF, or CR using UTF-8 bytes to avoid per-character grapheme validation
    /// on large file contents (`Swift._StringGuts.validateScalarIndex`).
    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        let handled = text.utf8.withContiguousStorageIfAvailable { buf -> Bool in
            let count = buf.count
            var start = 0
            var i = 0
            while i < count {
                let byte = buf[i]
                if byte == 0x0A || byte == 0x0D {
                    result.append(String(decoding: buf[start..<i], as: UTF8.self))
                    if byte == 0x0D, i + 1 < count, buf[i + 1] == 0x0A {
                        i += 2
                    } else {
                        i += 1
                    }
                    start = i
                } else {
                    i += 1
                }
            }
            if start < count {
                result.append(String(decoding: buf[start..<count], as: UTF8.self))
            }
            return true
        } ?? false
        if handled { return result }

        let utf8 = text.utf8
        var start = utf8.startIndex
        var i = start
        while i < utf8.endIndex {
            let byte = utf8[i]
            if byte == 0x0A || byte == 0x0D {
                result.append(String(decoding: utf8[start..<i], as: UTF8.self))
                let next = utf8.index(after: i)
                if byte == 0x0D, next < utf8.endIndex, utf8[next] == 0x0A {
                    i = utf8.index(after: next)
                } else {
                    i = next
                }
                start = i
            } else {
                i = utf8.index(after: i)
            }
        }
        if start < utf8.endIndex {
            result.append(String(decoding: utf8[start..<utf8.endIndex], as: UTF8.self))
        }
        return result
    }

    /// Counts logical lines in `text` without allocating per-line Strings.
    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        if let counted = text.utf8.withContiguousStorageIfAvailable({ buf -> Int in
            let count = buf.count
            var lines = 0
            var start = 0
            var i = 0
            while i < count {
                let byte = buf[i]
                if byte == 0x0A || byte == 0x0D {
                    lines += 1
                    if byte == 0x0D, i + 1 < count, buf[i + 1] == 0x0A {
                        i += 2
                    } else {
                        i += 1
                    }
                    start = i
                } else {
                    i += 1
                }
            }
            if start < count { lines += 1 }
            return lines
        }) {
            return counted
        }
        let utf8 = text.utf8
        var lines = 0
        var start = utf8.startIndex
        var i = start
        while i < utf8.endIndex {
            let byte = utf8[i]
            if byte == 0x0A || byte == 0x0D {
                lines += 1
                let next = utf8.index(after: i)
                if byte == 0x0D, next < utf8.endIndex, utf8[next] == 0x0A {
                    i = utf8.index(after: next)
                } else {
                    i = next
                }
                start = i
            } else {
                i = utf8.index(after: i)
            }
        }
        if start < utf8.endIndex { lines += 1 }
        return lines
    }
}
