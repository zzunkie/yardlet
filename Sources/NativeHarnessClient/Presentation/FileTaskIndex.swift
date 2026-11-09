import Foundation

/// The tasks that read or edited a file (docs/NATIVE_SESSION_STORAGE.md, "Index of tasks that touched a file"), read from each task's touches
/// (`FileTouches`): a Claude Code task's transcript, read on from where the last reading stopped, and what
/// Yardlet holds in memory of any other task. A file and a call's path are the same file when they are one
/// file of one repository, whichever of its checkouts each is in (`FileRepositoryKey`).
///
/// Only tasks that worked in the file's repository are read for it: a task's folder, or one of its other
/// folders, is in that repository (outside any repository, the file is in the folder). The reading runs
/// off the main thread, one question at a time.
actor FileTaskIndex {
    struct Candidate: Sendable {
        let id: UUID
        /// The folders the task works in, which say which repository it worked in.
        let folders: [String]
        /// A Claude Code task's transcript reader and conversation; nil for any other task.
        let claude: ClaudeSource?
        /// What Yardlet holds in memory of the task's reads and edits (a task other than Claude Code's).
        let liveTouches: [FileTouch]
    }

    struct ClaudeSource: Sendable {
        let reader: ClaudeSubagentTranscriptReader
        let sessionID: String
    }

    struct Match: Equatable, Sendable {
        let taskID: UUID
        let marks: FileTouchMarks
    }

    private let repository: FileTouchRepository
    private var touches: [UUID: FileTouches] = [:]
    private var resolver = FileRepositoryResolver()
    private var keys: [String: FileRepositoryKey] = [:]

    init(repository: FileTouchRepository) {
        self.repository = repository
    }

    /// The tasks among `candidates` that touched `file`, each with its newest edit and newest read of it.
    /// `knownWorktrees` are the worktree folders the tasks were made in, with the folders they were made
    /// from.
    func matches(for file: String, among candidates: [Candidate], knownWorktrees: [String: String]) -> [Match] {
        if resolver.knownWorktrees != knownWorktrees {
            resolver = FileRepositoryResolver(knownWorktrees: knownWorktrees)
            keys = [:]
        }
        let target = key(for: file)
        let targetPath = FileRepositoryResolver.standardized(file)
        var matches: [Match] = []
        for candidate in candidates {
            let worksThere = candidate.folders.contains { folder in
                if let repository = target.repository { return resolver.repository(of: folder) == repository }
                return PathRules.current.isStrictlyInside(targetPath, folder: FileRepositoryResolver.standardized(folder))
            }
            guard worksThere else { continue }
            var marks = FileTouchMarks()
            for (path, pathMarks) in updated(candidate).marksWithOpenCalls where key(for: path) == target {
                if let edit = pathMarks.edit { marks.record(.edit, edit) }
                if let read = pathMarks.read { marks.record(.read, read) }
            }
            if marks.edit != nil || marks.read != nil { matches.append(Match(taskID: candidate.id, marks: marks)) }
        }
        return matches
    }

    /// Forgets a deleted task's touches, and the file they were kept in.
    func remove(_ taskID: UUID) {
        touches.removeValue(forKey: taskID)
        repository.remove(for: taskID)
    }

    /// The candidate's touches brought up to date: its transcript read on, or what Yardlet holds of it
    /// added. Kept when they changed.
    private func updated(_ candidate: Candidate) -> FileTouches {
        let before = touches[candidate.id] ?? repository.load(for: candidate.id) ?? FileTouches()
        var current = before
        if let claude = candidate.claude {
            if let read = try? claude.reader.fileTouchScan(sessionID: claude.sessionID, previous: current) {
                current = read
            }
        } else {
            for touch in candidate.liveTouches { current.record(touch) }
        }
        touches[candidate.id] = current
        if current != before { repository.save(current, for: candidate.id) }
        return current
    }

    private func key(for path: String) -> FileRepositoryKey {
        if let known = keys[path] { return known }
        let key = resolver.key(for: path)
        keys[path] = key
        return key
    }
}
