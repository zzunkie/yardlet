import SwiftUI

/// Removing a saved account whose tasks can go on under another folder of the same account
/// (`ProviderConnectionStore.taskMoveTargets`). As account tools offer to hand a removed account's
/// work to another account, it moves the tasks there first, archived ones too; or it leaves them in
/// the account's folder, as Remove from List does. The login and the folder stay either way.
struct AccountRemovalSheet: View {
    struct Request: Identifiable {
        let connection: ProviderConnection
        /// The folders the tasks can move to.
        let targets: [Target]
        let tasks: AccountTaskCount
        var id: String { connection.id }
    }

    /// A folder the tasks can move to, named as the account list names it.
    struct Target: Identifiable {
        let connection: ProviderConnection
        let title: String
        var id: String { connection.id }
    }

    let request: Request
    let onMove: (ProviderConnection) -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void
    @State private var movesTasks = true
    @State private var targetID: String

    init(request: Request, onMove: @escaping (ProviderConnection) -> Void, onRemove: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.request = request
        self.onMove = onMove
        self.onRemove = onRemove
        self.onCancel = onCancel
        _targetID = State(initialValue: request.targets.first?.id ?? "")
    }

    private var target: ProviderConnection? {
        request.targets.first { $0.id == targetID }?.connection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.format("Remove %@ from the List?", request.connection.name)).font(.headline)
            Text(request.tasks.archived == 0
                 ? L10n.format("%lld tasks use this account. The login and its folder stay.", Int64(request.tasks.total))
                 : L10n.format("%lld tasks use this account, %lld of them archived. The login and its folder stay.",
                               Int64(request.tasks.total), Int64(request.tasks.archived)))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $movesTasks) {
                choice(L10n.string("Move the tasks to another folder of this account"),
                       detail: L10n.string("Each task keeps its conversation and goes on under that folder's login. Archived tasks move too."))
                    .tag(true)
                choice(L10n.string("Leave the tasks in this folder"),
                       detail: L10n.string("They go on in that folder as before."))
                    .tag(false)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            if movesTasks {
                VStack(alignment: .leading, spacing: 8) {
                    if request.targets.count > 1 {
                        Picker(L10n.string("Move to"), selection: $targetID) {
                            ForEach(request.targets) { Text($0.title).tag($0.id) }
                        }.fixedSize()
                    } else if let only = request.targets.first {
                        LabeledContent(L10n.string("Move to"), value: only.title)
                    }
                    if request.tasks.working > 0 {
                        Text(L10n.format("%lld tasks are working now. They move when their turns end, and the account leaves the list once every task has moved.",
                                         Int64(request.tasks.working)))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.callout).padding(.leading, 20)
            }
            HStack {
                Spacer()
                Button(L10n.string("Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L10n.string(movesTasks ? "Move and Remove" : "Remove from List")) {
                    if movesTasks, let target { onMove(target) } else if !movesTasks { onRemove() }
                }
                .parityProminentButton()
                .keyboardShortcut(.defaultAction)
                .disabled(movesTasks && target == nil)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func choice(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }
}
