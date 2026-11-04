import Foundation

/// What the detail reads beside the schedule: its tasks, places and accounts by name.
struct ScheduledTaskContext {
    var task: (UUID) -> SessionRecord? = { _ in nil }
    var projectName: (ScheduledTask) -> String = { _ in "" }
    var accountName: (ScheduledTask) -> String? = { _ in nil }
}

