import Foundation

/// What the import sheet lists: each app's schedules, each one's Yardlet task where it goes on with
/// one, and which are already here.
struct ScheduleImportListing: Equatable {
    var claude: [ImportableSchedule] = []
    var codex: [ImportableSchedule] = []
    var linkedTasks: [String: UUID] = [:]
    var imported: Set<String> = []

    var all: [ImportableSchedule] { claude + codex }

    func isImported(_ item: ImportableSchedule) -> Bool { imported.contains(item.id) }

    /// The rows checked when the sheet opens: on in their app, still ahead, and not here yet.
    func preselected(now: Date) -> Set<String> {
        Set(all.filter { $0.canImport && !isImported($0) && $0.isUpcoming(now: now) }.map(\.id))
    }
}

