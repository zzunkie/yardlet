import AppKit
import SwiftUI

/// What the New project sheet asks about: the chat a project is made of, and the name it starts with
/// (`AppModel.proposedProjectName(for:)`).
struct NewProjectRequest: Identifiable, Equatable {
    let session: SessionRecord
    let name: String

    var id: UUID { session.id }
}

/// Confirms making a chat a project of its own folder, dropped on Projects or chosen as "New
/// project": nothing is made until Create, and Cancel leaves the chat in Chats. The name and the
/// folders are the ones Edit project shows; the chat's folder is the primary one.
struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: NewProjectRequest
    /// The name and the other folders, once the person confirms.
    let onCreate: (String, [URL]) -> Void
    @State private var name: String
    @State private var otherRoots: [URL] = []
    @FocusState private var isNameFocused: Bool

    init(request: NewProjectRequest, onCreate: @escaping (String, [URL]) -> Void) {
        self.request = request
        self.onCreate = onCreate
        _name = State(initialValue: request.name)
    }

    private var primaryRoot: URL { Project.canonical(request.session.workspaceURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("New project"))
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("Project name"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField(L10n.string("Project name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(create)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.string("Root folders"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.string("Add folder…"), action: addRoot)
                        .parityPointer()
                }
                VStack(spacing: 0) {
                    rootRow(primaryRoot, isPrimary: true)
                    ForEach(otherRoots, id: \.self) { root in
                        Divider()
                        rootRow(root, isPrimary: false)
                    }
                }
                .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
                Text(L10n.string("A task runs in the primary folder. The other folders are passed to the harness."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L10n.string("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("Create"), action: create)
                    .keyboardShortcut(MacShortcut.confirmDialog.binding)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { isNameFocused = true }
    }

    private func rootRow(_ root: URL, isPrimary: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(ProjectSidebarPresentation.abbreviatedPath(for: root))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(root.path(percentEncoded: false))
            Spacer(minLength: 8)
            if isPrimary {
                Text(L10n.string("Primary folder"))
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(ParityTheme.selectedFill, in: Capsule())
            } else {
                Button {
                    otherRoots.removeAll { Project.isSamePath($0, root) }
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .help(L10n.string("Remove folder"))
                .accessibilityLabel(L10n.string("Remove folder"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isPrimary ? L10n.string("Primary folder") : "")
    }

    private func create() {
        onCreate(name, otherRoots)
        dismiss()
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = L10n.string("Add folder")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls.map(\.standardizedFileURL)
        where !Project.isSamePath(url, primaryRoot) && !otherRoots.contains(where: { Project.isSamePath($0, url) }) {
            otherRoots.append(url)
        }
    }
}
