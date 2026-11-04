import Foundation

/// What the schedule views do, in one place for the sidebar list, the detail and the menus.
struct ScheduledTaskActions {
    var canEdit = true
    var canImport = true
    var select: (UUID) -> Void = { _ in }
    var create: () -> Void = {}
    var importFromApps: () -> Void = {}
    var runNow: (UUID) -> Void = { _ in }
    var setEnabled: (UUID, Bool) -> Void = { _, _ in }
    var edit: (UUID) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
    /// Asks before deleting every one-off that ran.
    var deleteCompleted: () -> Void = {}
    var openTask: (UUID) -> Void = { _ in }
}

