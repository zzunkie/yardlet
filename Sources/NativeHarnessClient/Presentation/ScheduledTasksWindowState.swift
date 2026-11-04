import Foundation
import Observation

/// A window's scheduled-tasks place: whether it shows, the chosen schedule, and the editor, delete
/// question and import sheet it has open.
@MainActor
@Observable
final class ScheduledTasksWindowState {
    struct EditorRequest: Identifiable {
        let id = UUID()
        let draft: ScheduleDraft
        let existing: ScheduledTask?
    }

    var isShowing = false
    var selection: UUID?
    var editor: EditorRequest?
    var pendingDelete: UUID?
    /// The one-offs that ran, which "Delete All…" asks about.
    var pendingDeleteCompleted: Set<UUID>?
    var isImporting = false
    var importListing: ScheduleImportListing?
    /// The list's folded groups that are open, kept while the window leaves the list and comes back.
    var expandedSections: Set<ScheduleListSections.Section> = []

    var hasModal: Bool { editor != nil || pendingDelete != nil || pendingDeleteCompleted != nil || isImporting }
}

