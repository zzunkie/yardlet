import SwiftUI

/// "Move to project" with the projects a task can go to, and "Move to Chats" when it is in a
/// project (`TaskProjectMove`), for a task row's context menu and the task actions menu. Nothing
/// shows when there is no move to offer.
struct TaskProjectMoveMenuItems: View {
    let options: TaskProjectMove.Options
    let onMove: (Project?) -> Void

    var body: some View {
        if !options.destinations.isEmpty {
            Menu(TaskProjectMove.moveTitle) {
                ForEach(options.destinations) { project in
                    Button(project.name) { onMove(project) }
                }
            }
        }
        if options.removableFrom != nil {
            Button(TaskProjectMove.chatsTitle) { onMove(nil) }
        }
    }
}
