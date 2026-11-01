import Foundation
import Observation

/// Which account each task an agent started, or a schedule's run moved, runs on, and why
/// (`AccountAssignment`), for the task's hover card and `read_task` after a restart. The account
/// itself is the task's own connection; this
/// keeps only the reason line's facts, for the latest `capacity` tasks, in one small file
/// (`~/.yardlet/account-assignments.json`; per-task records stay out of the preferences). A deleted
/// task takes its line along.
@MainActor @Observable
final class AccountAssignmentLog {
    static let capacity = 500
    static let fileName = "account-assignments.json"

    private(set) var assignments: [UUID: AccountAssignment] = [:]
    @ObservationIgnored private let fileURL: URL?

    /// Nil keeps the lines in memory only.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let saved = try? Self.decoder.decode([String: AccountAssignment].self, from: data) else { return }
        assignments = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    func assignment(for taskID: UUID) -> AccountAssignment? { assignments[taskID] }

    func record(_ assignment: AccountAssignment, for taskID: UUID) {
        assignments[taskID] = assignment
        if assignments.count > Self.capacity {
            let oldest = assignments.sorted { $0.value.assignedAt < $1.value.assignedAt }
                .prefix(assignments.count - Self.capacity).map(\.key)
            for id in oldest { assignments[id] = nil }
        }
        save()
    }

    func remove(for taskID: UUID) {
        guard assignments.removeValue(forKey: taskID) != nil else { return }
        save()
    }

    private func save() {
        guard let fileURL else { return }
        let values = Dictionary(uniqueKeysWithValues: assignments.map { ($0.key.uuidString, $0.value) })
        guard let data = try? Self.encoder.encode(values) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
