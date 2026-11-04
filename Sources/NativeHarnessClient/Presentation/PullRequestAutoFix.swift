import Foundation
import Observation

/// Settings › General "Fix failing CI automatically": whether a task is asked, the first time it has
/// a pull request, if Yardlet should send it failing checks to fix. Asking is the default. Either
/// way auto-fix stays off for a task until the person turns it on for that task (a
/// Yardlet setting, no trace outside Yardlet, and the agent's own judgment untouched).
enum PullRequestAutoFixPrompt: String, CaseIterable, Sendable {
    case ask
    case never

    static let preferenceKey = "YardletPullRequestAutoFixPrompt"

    static func current(in defaults: UserDefaults = .yardlet) -> PullRequestAutoFixPrompt {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .ask
    }

    var title: String {
        switch self {
        case .ask: L10n.string("autoFix.prompt.ask")
        case .never: L10n.string("autoFix.prompt.never")
        }
    }
}

/// One task's auto-fix: whether the person turned it on, and which failures it already sent.
struct PullRequestAutoFixRecord: Codable, Equatable, Sendable {
    enum Choice: String, Codable, Sendable {
        case on
        case off
    }

    /// Nil until the person answered the question or used the switch.
    var choice: Choice?
    /// The pull request auto-fix watches and the task's folder, so it can look while the task is
    /// off screen.
    var pullRequestURL: URL?
    var folderPath: String?
    /// The failures already sent to the task (`PullRequestAutoFixPolicy.eventKey`), newest last.
    var sentEvents: [String] = []
    /// When the last one went, for the card's line.
    var lastSentAt: Date?

    static let sentEventLimit = 20

    var isOn: Bool { choice == .on }

    mutating func recordSent(_ key: String, at date: Date) {
        sentEvents.removeAll { $0 == key }
        sentEvents.append(key)
        if sentEvents.count > Self.sentEventLimit { sentEvents.removeFirst(sentEvents.count - Self.sentEventLimit) }
        lastSentAt = date
    }
}

/// What auto-fix does about a task's pull request now.
enum PullRequestAutoFixDecision: Equatable, Sendable {
    /// Nothing: auto-fix is off for the task, nothing failed, or this failure was sent already.
    case none
    /// A new failure, but the task is working or the person is editing; it waits for the turn.
    case wait(eventKey: String)
    /// Send this message to the task as its next turn, once.
    case send(eventKey: String, message: String)
}

/// The rules of auto-fix and of the card's "Fix CI" draft. Nothing here starts a turn: the decision
/// says whether one may start, and only `PullRequestDetailCenter` acts on it.
enum PullRequestAutoFixPolicy {
    /// The question shows on the task's Changes card while the setting asks, the person has not
    /// chosen for this task, and the task has an open pull request.
    static func asks(record: PullRequestAutoFixRecord?, prompt: PullRequestAutoFixPrompt,
                     detail: PullRequestDetail?) -> Bool {
        prompt == .ask && record?.choice == nil && detail?.isOpen == true
    }

    /// A failure is the head commit's set of failed checks once none is still running, so one push
    /// whose checks fail gives one message however the checks report.
    static func eventKey(_ detail: PullRequestDetail) -> String? {
        let failed = detail.failedChecks
        guard detail.isOpen, !failed.isEmpty, detail.count(.pending) == 0 else { return nil }
        let names = failed.map { [$0.workflow, $0.name].compactMap { $0 }.joined(separator: "/") }.sorted()
        return ([detail.headSHA ?? "?"] + names).joined(separator: "|")
    }

    /// - Parameters:
    ///   - record: the task's auto-fix record; without one, or with it off, nothing is sent.
    ///   - detail: GitHub's last answer about the task's pull request.
    ///   - taskIsIdle: the task has no turn running, waits for nobody, and has no message being edited.
    static func decide(record: PullRequestAutoFixRecord?, detail: PullRequestDetail?,
                       taskIsIdle: Bool) -> PullRequestAutoFixDecision {
        guard let record, record.isOn, let detail, let key = eventKey(detail),
              !record.sentEvents.contains(key) else { return .none }
        guard taskIsIdle else { return .wait(eventKey: key) }
        return .send(eventKey: key, message: message(for: detail))
    }

    /// The message auto-fix sends: the request the person would type, in the Claude app's words for
    /// its CI line ("Fix the failing CI checks on {branch}: …").
    static func message(for detail: PullRequestDetail) -> String {
        let branch = detail.headBranch ?? "this branch"
        let checks = detail.failedChecks.map(\.name).joined(separator: ", ")
        var lines = ["Fix the failing CI checks on \(branch) (pull request #\(detail.number)): \(checks)."]
        let runs = Array(Set(detail.failedChecks.compactMap(\.runID))).sorted()
        if !runs.isEmpty {
            lines.append("Read the failed logs with " + runs.map { "`gh run view \($0) --log-failed`" }
                .joined(separator: ", ") + ", fix the cause, and push the fix to this branch.")
        } else {
            lines.append("Read the failed checks' logs, fix the cause, and push the fix to this branch.")
        }
        return lines.joined(separator: "\n")
    }

    /// The card's "Fix CI": the same request with the failed log excerpts the card has read, put in
    /// the composer for the person to send.
    static func draft(for detail: PullRequestDetail, logs: [String: String]) -> String {
        var text = message(for: detail)
        for check in detail.failedChecks {
            guard let log = logs[check.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !log.isEmpty else {
                continue
            }
            let excerpt = GitHubPullRequestDetailClient.tail(log, lines: 40, bytes: 6 * 1024)
            text += "\n\n\(check.name):\n```\n\(excerpt)\n```"
        }
        return text
    }
}

/// Each task's auto-fix record, kept in Yardlet's own defaults. A task that is archived or deleted
/// loses its record.
@MainActor
@Observable
final class PullRequestAutoFixStore {
    static let defaultsKey = "Yardlet.pullRequestAutoFix.tasks"

    private(set) var records: [UUID: PullRequestAutoFixRecord]
    @ObservationIgnored private let defaults: UserDefaults?

    /// `defaults` nil keeps records in memory only (tests and visual fixtures).
    init(defaults: UserDefaults? = .yardlet) {
        self.defaults = defaults
        let stored = defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: PullRequestAutoFixRecord].self, from: $0) } ?? [:]
        records = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    func record(for taskID: UUID) -> PullRequestAutoFixRecord? { records[taskID] }

    func setChoice(_ choice: PullRequestAutoFixRecord.Choice, for taskID: UUID, pullRequestURL: URL?,
                   folder: URL?) {
        var record = records[taskID] ?? PullRequestAutoFixRecord()
        record.choice = choice
        if let pullRequestURL { record.pullRequestURL = pullRequestURL }
        if let folder { record.folderPath = folder.path(percentEncoded: false) }
        save(record, for: taskID)
    }

    /// The task's card shows another pull request than auto-fix watched: auto-fix follows it.
    func follow(_ pullRequestURL: URL, folder: URL, for taskID: UUID) {
        guard var record = records[taskID], record.isOn,
              record.pullRequestURL != pullRequestURL || record.folderPath != folder.path(percentEncoded: false)
        else { return }
        record.pullRequestURL = pullRequestURL
        record.folderPath = folder.path(percentEncoded: false)
        save(record, for: taskID)
    }

    func recordSent(_ key: String, at date: Date, for taskID: UUID) {
        var record = records[taskID] ?? PullRequestAutoFixRecord()
        record.recordSent(key, at: date)
        save(record, for: taskID)
    }

    func forget(_ taskID: UUID) {
        guard records.removeValue(forKey: taskID) != nil else { return }
        write()
    }

    /// The tasks whose auto-fix is on.
    var enabledTaskIDs: [UUID] { records.filter { $0.value.isOn }.map(\.key) }

    private func save(_ record: PullRequestAutoFixRecord, for taskID: UUID) {
        guard records[taskID] != record else { return }
        records[taskID] = record
        write()
    }

    private func write() {
        guard let defaults else { return }
        if records.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        let stored = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
