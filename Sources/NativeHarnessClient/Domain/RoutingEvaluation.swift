import Foundation
import Observation

/// One line of the routing ledger: what ran a turn (or a `run_agent` subagent) and how it ended,
/// kept so the daily evaluation can tell which harness and model suit which work for this person
/// Only facts Yardlet already holds; no model call writes it.
struct RoutingLedgerEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A turn of a sidebar task.
        case turn
        /// A `run_agent` subagent, start to finish.
        case agentRun
    }

    /// Who set the work going.
    enum Origin: String, Codable, Sendable {
        case person
        case schedule
        /// A task another task started (`create_task`, a Codex subagent thread).
        case childTask
        case agentRun
    }

    enum Outcome: String, Codable, Sendable {
        case completed
        case failed
        /// The person stopped it.
        case stopped
        /// It ended on the account's usage limit.
        case usageLimit
    }

    struct Tokens: Codable, Equatable, Sendable {
        var input: Int64?
        var cachedInput: Int64?
        var output: Int64?
    }

    struct Changes: Codable, Equatable, Sendable {
        var files: Int
        var additions: Int
        var deletions: Int
    }

    var version = 1
    var kind: Kind
    /// The sidebar task, or for a subagent the task whose conversation shows it.
    var taskID: UUID
    var runID: UUID?
    var parentTaskID: UUID?
    var origin: Origin
    var harness: String
    /// As the harness names it; nil where it has not said and the task named none.
    var model: String?
    var effort: String?
    /// The Yardlet account connection; nil for the harness's own default login.
    var account: String?
    var projectID: UUID?
    var workspacePath: String
    var startedAt: Date?
    var endedAt: Date
    var outcome: Outcome
    /// What the harness reported for the turn: Codex's last-turn breakdown, else the usage the
    /// harness last reported for the task.
    var tokens: Tokens?
    /// The folder's commit and uncommitted changes when the work ended, so a later look can see
    /// whether what it made was kept.
    var head: String?
    var changes: Changes?
}

/// The evaluation switch and its ledger (Settings): off unless the person turns
/// it on. Off, nothing is recorded, and turning it off removes what was.
@MainActor
@Observable
final class RoutingEvaluationStore {
    static let enabledKey = "Yardlet.routingEvaluation.enabled"

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            // Through the writer, so a line already on its way is written before the folder goes.
            if !isEnabled {
                timesTurnedOff += 1
                state = RoutingEvaluationState()
                let writer = writer
                Task { await writer.removeAll() }
            }
        }
    }

    /// Counts the times it was turned off: a run that saw it change stops its judge and keeps
    /// nothing, even when it was turned on again since.
    @ObservationIgnored private(set) var timesTurnedOff = 0
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let writer: RoutingLedgerWriter

    /// The last run, its report and the routing it settled on.
    private(set) var state: RoutingEvaluationState

    var ledgerURL: URL { directory.appending(path: "ledger.jsonl") }
    var stateURL: URL { directory.appending(path: "state.json") }
    var reportsDirectory: URL { directory.appending(path: "reports", directoryHint: .isDirectory) }
    /// The empty folder judges run in, so nothing of the person's is in reach.
    var judgeFolder: URL { directory.appending(path: "judges", directoryHint: .isDirectory) }

    var lastReportURL: URL? { state.lastReport.map { reportsDirectory.appending(path: $0) } }

    /// What tasks receive with Yardlet instructions while the evaluation is on; nil before it has chosen.
    var routingBlock: String? {
        isEnabled ? RoutingEvaluationAggregation.routingBlock(state.routing) : nil
    }

    init(directory: URL, defaults: UserDefaults = .yardlet) {
        self.directory = directory
        self.defaults = defaults
        writer = RoutingLedgerWriter(url: directory.appending(path: "ledger.jsonl"))
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        state = (try? Data(contentsOf: directory.appending(path: "state.json")))
            .flatMap { try? RoutingLedgerWriter.decoder.decode(RoutingEvaluationState.self, from: $0) }
            ?? RoutingEvaluationState()
    }

    static func live() -> RoutingEvaluationStore {
        RoutingEvaluationStore(directory: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
            .appending(path: "evaluation", directoryHint: .isDirectory))
    }

    /// Appends one line; nothing while the switch is off.
    func record(_ entry: RoutingLedgerEntry) async {
        guard isEnabled else { return }
        await writer.append(entry)
    }

    /// Every line written so far, oldest first; lines that do not read are skipped.
    func entries() async -> [RoutingLedgerEntry] {
        await writer.entries()
    }

    /// Keeps a finished run: its report, the routing, and how far the ledger was read.
    func finish(_ result: RoutingEvaluationResult, evaluatedThrough: Date?, at now: Date) async {
        guard isEnabled else { return }
        let name = "\(Self.reportName.string(from: now)).md"
        let next = RoutingEvaluationState(lastRunAt: now, lastReport: name,
                                          evaluatedThrough: evaluatedThrough ?? state.evaluatedThrough,
                                          routing: result.routing)
        state = next
        await writer.write(report: result.report, named: name, state: next)
    }

    private static let reportName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}

/// Appends ledger lines in order, off the main thread, readable only by the person.
actor RoutingLedgerWriter {
    let url: URL

    init(url: URL) { self.url = url }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func append(_ entry: RoutingLedgerEntry) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(0x0A)
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path(percentEncoded: false)) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
            manager.createFile(atPath: url.path(percentEncoded: false), contents: nil,
                               attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Writes a report beside the ledger and the state that names it.
    func write(report: String, named name: String, state: RoutingEvaluationState) {
        let folder = url.deletingLastPathComponent()
        let reports = folder.appending(path: "reports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        Self.writePrivately(Data(report.utf8), to: reports.appending(path: name))
        if let data = try? Self.encoder.encode(state) {
            Self.writePrivately(data, to: folder.appending(path: "state.json"))
        }
    }

    private static func writePrivately(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }

    /// Removes the ledger's folder and everything in it.
    func removeAll() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func entries() -> [RoutingLedgerEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(RoutingLedgerEntry.self, from: Data($0)) }
    }
}

/// The model and effort a task's controls show, read from what the harness advertised.
enum RoutingModelReading {
    static let effortSelectorIDs: Set<String> = ["effort", "reasoningEffort", "thinking", "thinkingLevel"]

    static func model(in selectors: [ProviderCapabilitySelector]) -> String? {
        value(selectors.first { $0.id == "model" || $0.category == "model" })
    }

    static func effort(in selectors: [ProviderCapabilitySelector]) -> String? {
        value(selectors.first { effortSelectorIDs.contains($0.id) || $0.category == "thought_level" })
    }

    private static func value(_ selector: ProviderCapabilitySelector?) -> String? {
        guard let value = selector?.currentValue.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}
