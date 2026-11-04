import SwiftUI

/// The same title field and confirmation in local and host windows.
struct TaskRenameAlert: ViewModifier {
    @Binding var session: SessionRecord?
    @Binding var title: String
    var presentationID: UUID?
    let rename: (SessionRecord, String) -> Void

    func body(content: Content) -> some View {
        content.alert(L10n.string("Rename task"), isPresented: Binding(
            get: { session != nil }, set: { if !$0 { session = nil } })) {
            TextField(L10n.string("Task title"), text: $title).id(presentationID ?? session?.id)
            Button(L10n.string("Cancel"), role: .cancel) { session = nil }
            Button(L10n.string("Rename")) {
                guard let current = session else { return }
                let value = title
                session = nil
                rename(current, value)
            }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
