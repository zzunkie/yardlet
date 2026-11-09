import Foundation

/// Every schedule and what it has done, as one file.
struct ScheduleSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var schedules: [ScheduledTask] = []
}

@MainActor
protocol ScheduledTaskRepository {
    func load() -> ScheduleSnapshot?
    func save(_ snapshot: ScheduleSnapshot)
}

@MainActor
final class InMemoryScheduledTaskRepository: ScheduledTaskRepository {
    var snapshot: ScheduleSnapshot?

    init(snapshot: ScheduleSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() -> ScheduleSnapshot? { snapshot }
    func save(_ snapshot: ScheduleSnapshot) { self.snapshot = snapshot }
}

/// Schedules are Yardlet's own records, beside the other `~/.yardlet` files: prompts, triggers,
/// destinations and the run history (task IDs, times, outcomes). No credential, no conversation, and
/// nothing outside Yardlet's folder. Saves are encoded and written on `StateFileWriter`'s queue: the
/// file holds every schedule's prompt, and written on the main thread each time a schedule ran or
/// changed, it held the window while the disk was busy (2026-11-09).
struct FileScheduledTaskRepository: ScheduledTaskRepository {
    let fileURL: URL

    static func live(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> FileScheduledTaskRepository {
        FileScheduledTaskRepository(
            fileURL: homeURL
                .appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
                .appending(path: "schedules.json")
        )
    }

    /// A file this build cannot read (a later version, or damaged) is copied aside before the next
    /// save replaces it, so no schedule is lost to an older build.
    func load() -> ScheduleSnapshot? {
        StateFileWriter.shared.flush()
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if let snapshot = try? JSONDecoder().decode(ScheduleSnapshot.self, from: data), snapshot.version == 1 {
            return snapshot
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = fileURL.deletingLastPathComponent().appending(path: "schedules-unreadable-\(stamp).json")
        try? FileManager.default.copyItem(at: fileURL, to: aside)
        return nil
    }

    func save(_ snapshot: ScheduleSnapshot) {
        let fileURL = fileURL
        StateFileWriter.shared.write(fileURL) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        }
    }
}
