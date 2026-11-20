import SwiftUI

/// "Move to project" with the projects a task can go to and, for a task that can become a project
/// of its own folder, "New project"; then "Move to Chats" when it is in a project
/// (`TaskProjectMove`), for a task row's context menu and the task actions menu. Nothing shows when
/// there is no move to offer.
struct TaskProjectMoveMenuItems: View {
    let options: TaskProjectMove.Options
    let onMove: (Project?) -> Void
    /// Makes the task a project of its own folder; nil where the window cannot, and the item is left out.
    var onMakeProject: (() -> Void)? = nil

    private var makesProject: (() -> Void)? { options.canMakeProject ? onMakeProject : nil }

    var body: some View {
        if !options.destinations.isEmpty || makesProject != nil {
            Menu(TaskProjectMove.moveTitle) {
                ForEach(options.destinations) { project in
                    Button(project.name) { onMove(project) }
                }
                if let makesProject {
                    if !options.destinations.isEmpty { Divider() }
                    Button(TaskProjectMove.newProjectTitle, action: makesProject)
                }
            }
        }
        if options.removableFrom != nil {
            Button(TaskProjectMove.chatsTitle) { onMove(nil) }
        }
    }
}
