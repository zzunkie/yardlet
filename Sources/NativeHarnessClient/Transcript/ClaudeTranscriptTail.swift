import Foundation

/// How much of a Claude task's saved transcript Yardlet has read (docs/NATIVE_SESSION_STORAGE.md): the
/// newest `initialBytes` of the file first, which is enough for the newest turns unless they saved
/// large outputs (then up to `placeBytes`), so opening a long conversation does not wait on its whole
/// history. Each time the person asks for earlier turns (scrolling to the top, or the rail's "Load
/// more history") the read reaches further back: the budget doubles up to `stepBytes`, then grows
/// by it, until the file's start. Only the newly covered bytes are parsed (`ClaudeTranscriptWindow`),
/// so a request costs the same however much was read before it. Following the file as another app
/// writes it reads the newest part again.
struct ClaudeTranscriptTail: Equatable, Sendable {
    static let initialBytes = 1 << 20
    /// The most one request for earlier turns parses.
    static let stepBytes = 8 << 20
    /// How far back a read goes to keep a place the person was reading, to meet the turns shown when
    /// following, or to hold the turns a conversation draws when it opens: the most a read took
    /// before the window could grow.
    static let placeBytes = 8 << 20

    /// The conversation the reads belong to; another one (a new chat, an edit's branch) starts over.
    let providerSessionID: String
    /// What the reads covered, nil before the first.
    var window: ClaudeTranscriptWindow?

    /// The budget the reads took.
    var bytes: Int { window?.bytes ?? Self.initialBytes }
    /// The file holds turns before the ones read, and a read further back can show them.
    var hasEarlierHistory: Bool { window?.hasEarlierRecords ?? false }

    /// The budget after `bytes`: doubled up to `stepBytes`, then `stepBytes` more.
    static func budget(after bytes: Int) -> Int {
        bytes < stepBytes ? min(bytes * 2, stepBytes) : bytes + stepBytes
    }
}

/// What reads of one Claude transcript covered: every line from `start` to the end the newest read
/// saw, indexed by record ID with what walking the conversation's chain needs (`Record`), and the
/// record the entries shown begin with (`seamRecord`). A read further back parses only the lines
/// before `start` and projects only the chain before the seam, whose entries go in front of the
/// ones shown, so the entries shown keep their IDs and nothing is parsed twice. The index holds no
/// message text; the records a projection needs again are read back from the file by offset.
struct ClaudeTranscriptWindow: Equatable, Sendable {
    /// One saved line the reads covered.
    struct Record: Sendable {
        /// Where the line starts in the file, and its length without the newline.
        let offset: Int64
        let length: Int
        let parent: String?
        /// A compaction's link to the last record before it (`logicalParentUuid`).
        let logicalParent: String?
        let type: String?
        let isMeta: Bool
        let isSidechain: Bool
        let isCompaction: Bool
        /// The tool calls an entry's content blocks make, and the calls its results answer.
        let toolUses: [String]
        let toolResults: [String]
        /// Every content block is a tool result.
        let isOnlyToolResults: Bool
    }

    struct FileIdentity: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
    }

    let sessionID: String
    let file: FileIdentity
    /// The file's size when the newest part was read; budgets count back from it.
    let end: Int64
    /// The budget the reads took: the newest `bytes` of the file as it was at `end`.
    let bytes: Int
    /// Where the first covered line starts.
    let start: Int64
    let records: [String: Record]
    /// The chain record the entries shown begin with (the request of the first turn shown, or the
    /// conversation's first record), and that entry: a read further back puts what it finds before them.
    let seamRecord: String?
    let seamEntry: UUID?
    /// When the newest read began inside a turn: the last entry of that turn's part it shows, and,
    /// when it held no request at all (the conversation's last turn), the record its chain ended at.
    /// A read further back projects that turn again whole, from its request, and its entries go in
    /// place of the ones shown through `partialEntry`.
    var partialRecord: String? = nil
    var partialEntry: UUID? = nil
    /// The conversation's chain goes on before `start`.
    let hasEarlierRecords: Bool
    /// Names one read's result; two windows are the same when they are the same read.
    let version = UUID()

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.version == rhs.version }

    /// The entries of a newer read of the file put in place of the ones `shown` from that read's
    /// first turn on: a read that begins at the request of a turn already shown replaces that turn
    /// and what follows it, and the earlier turns brought in stay, with the end of a turn the read
    /// began inside (which `shown` holds whole). Nil when `newest` holds no turn's request (a part
    /// of a turn reads whole only from its request), or meets none of `shown`.
    static func splicing(_ newest: [TranscriptEntry], into shown: [TranscriptEntry]) -> [TranscriptEntry]? {
        guard let firstTurn = newest.firstIndex(where: \.opensTurn),
              let index = shown.lastIndex(where: { $0.id == newest[firstTurn].id }) else { return nil }
        return Array(shown[..<index]) + newest[firstTurn...]
    }
}

/// A read of a Claude transcript: the entries it adds and what the reads have covered since.
struct ClaudeTranscriptRead: Sendable {
    /// The newest read's whole conversation, or the entries a read further back puts before the
    /// first entry shown (`ClaudeTranscriptWindow.seamEntry`), none when it reached no turn's start.
    var entries: [TranscriptEntry]
    var window: ClaudeTranscriptWindow
    /// Set when the entries go in place of the ones shown through this entry rather than before
    /// them: the newest read held only part of the last turn, which this read holds whole.
    var replacesThrough: UUID? = nil
    /// The context the newest read's last response fills (`ClaudeTranscriptContextUsage`), for the
    /// composer's ring while the task is detached. Reads further back leave it nil.
    var contextUsage: ClaudeTranscriptContextUsage? = nil

    /// `shown` with this read's entries in place: before the first entry shown, or through
    /// `replacesThrough`.
    func applied(to shown: [TranscriptEntry]) -> [TranscriptEntry] {
        guard let replacesThrough else { return entries + shown }
        guard let index = shown.firstIndex(where: { $0.id == replacesThrough }) else { return shown }
        return entries + shown[(index + 1)...]
    }
}
