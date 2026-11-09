import Foundation

/// A Codex file change card's rows, as the Codex app lists a patch: one row per file with a verb
/// for the change's state, the file's name, `+n −m`, and a diff folded until the reader opens it.
///
/// The Codex app keys a patch's files by path (a later change to the same path replaces the
/// earlier one in place), builds each file's diff from the App Server `FileUpdateChange`, and
/// declines to preview a diff over 1 MiB. Rows keep the path as their identity so that
/// `item/fileChange/patchUpdated`, which replaces the whole list while the model writes the
/// patch, leaves an opened row open.
enum CodexFileChangeCardProjection {
    /// The Codex app's preview limit for one file's diff.
    static let fileByteLimit = 1_048_576
    /// All previews of one card together; files past it read as too large.
    static let cardByteLimit = 4 * 1_048_576
    /// Diff lines a row draws; the rest are counted and left to the Changes panel.
    static let previewLineLimit = 1_000
    /// Characters of one diff line a row draws.
    static let lineCharacterLimit = 1_000

    enum Kind: Equatable, Sendable {
        case add, delete, update
    }

    enum State: Equatable, Sendable {
        /// The provider is still writing or applying the patch.
        case inProgress
        /// The turn ended before the patch was applied.
        case stopped
        case applied
        /// Declined or failed; the Codex app calls both rejected.
        case rejected
    }

    enum PreviewAvailability: Equatable, Sendable {
        case available
        case tooLarge
        /// The provider sent no diff for this file, so there is nothing to unfold.
        case missing
    }

    struct LineCounts: Equatable, Sendable {
        let additions: Int
        let deletions: Int
    }

    struct Row: Equatable, Identifiable, Sendable {
        /// The provider path the change is keyed by.
        let id: String
        let change: JSONValue
        /// Inside the task's folder, relative to it; the destination for a moved file.
        let displayPath: String
        let fileName: String
        let kind: Kind
        let state: State
        /// Nil when there is no diff to count, as the Codex app hides counts it cannot preview.
        let lineCounts: LineCounts?
        let preview: PreviewAvailability
        /// The file the name opens (`openableURL`): inside the task's folder, or elsewhere by its absolute path.
        let fileURL: URL?
        /// The lines a harness activity's edit draws, worked out from the text it replaced
        /// (`PermissionRequestPreviewProjection`); nil where `change` carries a diff to read.
        var precomputedPreview: Preview? = nil

        var canExpand: Bool { preview != .missing }

        /// The lines the row's diff box draws.
        var previewLines: Preview {
            precomputedPreview ?? CodexFileChangeCardProjection.preview(for: change)
        }

        var verb: String {
            switch (state, kind) {
            case (.inProgress, .add): L10n.string("Creating")
            case (.inProgress, .delete): L10n.string("Deleting")
            case (.inProgress, .update): L10n.string("Editing")
            case (.stopped, .add): L10n.string("Stopped creating")
            case (.stopped, .delete): L10n.string("Stopped deleting")
            case (.stopped, .update): L10n.string("Stopped editing")
            case (.applied, .add): L10n.string("Created")
            case (.applied, .delete): L10n.string("Deleted")
            case (.applied, .update): L10n.string("Edited")
            case (.rejected, _): L10n.string("Rejected")
            }
        }

        /// An opened, applied row names the change on its own line and moves the file name and
        /// counts to the diff's header, as the Codex app does.
        var expandedTitle: String? {
            guard state == .applied, preview == .available else { return nil }
            switch kind {
            case .add: return L10n.string("Created file")
            case .delete: return L10n.string("Deleted file")
            case .update: return L10n.string("Edited file")
            }
        }

        var accessibilityValue: String {
            guard let lineCounts else { return verb }
            return "\(verb), +\(lineCounts.additions) −\(lineCounts.deletions)"
        }
    }

    struct Preview: Equatable, Sendable {
        struct Line: Equatable, Identifiable, Sendable {
            enum Kind: Equatable, Sendable {
                case addition, deletion, context
                /// Between two hunks, drawn as a rule rather than the `@@` header.
                case separator
            }

            let id: Int
            let kind: Kind
            let number: Int?
            /// The line without its diff marker, cut at `lineCharacterLimit`.
            let text: String
        }

        let lines: [Line]
        /// Lines past `previewLineLimit`, not drawn.
        let hiddenLineCount: Int
        /// Where opening the file lands: the first added line, else the first removed one.
        let firstChangedLine: Int?

        static let empty = Preview(lines: [], hiddenLineCount: 0, firstChangedLine: nil)
    }

    static func rows(for item: CodexFileChangeItem, isTurnFinished: Bool, workspaceURL: URL?) -> [Row] {
        var paths: [String] = []
        var latest: [String: JSONValue] = [:]
        for change in item.changes {
            guard let path = change["path"]?.stringValue, !path.isEmpty else { continue }
            if latest[path] == nil { paths.append(path) }
            latest[path] = change
        }
        let state = state(for: item.status, isTurnFinished: isTurnFinished)
        var budget = cardByteLimit
        return paths.compactMap { path in
            guard let change = latest[path] else { return nil }
            let preview: PreviewAvailability
            if let size = change["diff"]?.stringValue?.utf8.count {
                if size > fileByteLimit || size > budget {
                    preview = .tooLarge
                } else {
                    budget -= size
                    preview = .available
                }
            } else {
                preview = .missing
            }
            let counts = preview == .available ? CodexFileChangeDiff.lineCounts(for: change) : nil
            let target = change["kind"]?["move_path"]?.stringValue ?? path
            let displayPath = CodexFileChangeDiff.displayPath(target, workspaceURL: workspaceURL)
            return Row(
                id: path,
                change: change,
                displayPath: displayPath,
                fileName: URL(filePath: displayPath).lastPathComponent,
                kind: kind(of: change),
                state: state,
                lineCounts: counts.flatMap { counts in
                    counts.additions == 0 && counts.deletions == 0
                        ? nil : LineCounts(additions: counts.additions, deletions: counts.deletions)
                },
                preview: preview,
                fileURL: workspaceURL.flatMap { openableURL(for: target, workspaceURL: $0) }
            )
        }
    }

    /// App Server statuses are `inProgress`, `completed`, `failed` and `declined`. A change still
    /// in progress when its turn has ended was stopped.
    static func state(for status: String, isTurnFinished: Bool) -> State {
        switch status.lowercased() {
        case "inprogress", "in_progress": isTurnFinished ? .stopped : .inProgress
        case "completed": .applied
        default: .rejected
        }
    }

    static func preview(for change: JSONValue, lineLimit: Int = previewLineLimit) -> Preview {
        guard let text = CodexFileChangeDiff.unifiedDiff(for: change, workspaceURL: nil) else { return .empty }
        var lines: [Preview.Line] = []
        var hidden = 0
        var firstAddition: Int?
        var firstDeletion: Int?
        var sawHunk = false
        for line in UnifiedDiffParser().parse(text).lines {
            let kind: Preview.Line.Kind
            let number: Int?
            switch line.kind {
            case .hunkHeader:
                let isFirstHunk = !sawHunk
                sawHunk = true
                if isFirstHunk { continue }
                kind = .separator
                number = nil
            case .addition:
                kind = .addition
                number = line.newLine
                firstAddition = firstAddition ?? line.newLine
            case .deletion:
                kind = .deletion
                number = line.oldLine
                firstDeletion = firstDeletion ?? line.oldLine
            case .context:
                kind = .context
                number = line.newLine
            case .fileHeader, .metadata:
                continue
            }
            guard lines.count < lineLimit else {
                hidden += 1
                continue
            }
            let body = kind == .separator ? "" : String(line.text.dropFirst())
            lines.append(Preview.Line(
                id: lines.count,
                kind: kind,
                number: number,
                text: body.count > lineCharacterLimit ? String(body.prefix(lineCharacterLimit)) + "…" : body
            ))
        }
        return Preview(lines: lines, hiddenLineCount: hidden, firstChangedLine: firstAddition ?? firstDeletion)
    }

    /// App Server paths are absolute; a relative one is read against the task's folder. Either
    /// way the file must lie inside that folder.
    static func fileURL(for path: String, workspaceURL: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !PathRules.current.names(trimmed).contains("..") else { return nil }
        let root = workspaceURL.standardizedFileURL
        let candidate = PathRules.current.url(for: trimmed, in: root).standardizedFileURL
        return PathRules.current.isStrictlyInside(candidate, folder: root) ? candidate : nil
    }

    /// The file a row's name opens for the person: inside the task's folder as `fileURL` reads it,
    /// or a file the task changed elsewhere by its absolute path, which the files panel shows read-only.
    static func openableURL(for path: String, workspaceURL: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return fileURL(for: trimmed, workspaceURL: workspaceURL)
            ?? (PathRules.current.isAbsolute(trimmed) ? URL(filePath: trimmed).standardizedFileURL : nil)
    }

    private static func kind(of change: JSONValue) -> Kind {
        switch change["kind"]?["type"]?.stringValue ?? change["kind"]?.stringValue {
        case "add": .add
        case "delete": .delete
        default: .update
        }
    }
}
