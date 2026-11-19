import AppKit
import SwiftUI

/// The single project editing surface: the name, which folders belong to the project, which one
/// is the primary folder new tasks run in, and the project's Yardlet instructions. Instruction files are
/// never created, copied, or merged here — adding a root only tells the harness the folder exists,
/// and the project's instructions stay in Yardlet's own folder.
struct ProjectEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var projects: ProjectStore
    let projectID: UUID
    /// Nil where the app has no Yardlet instructions (tests, fixtures); the section is then left out.
    var instructions: YardletInstructionsStore? = nil
    @State private var name = ""
    @State private var didLoadName = false

    private var project: Project? { projects.project(id: projectID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("Edit project"))
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("Project name"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField(L10n.string("Project name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitName)
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
                if let project {
                    VStack(spacing: 0) {
                        ForEach(project.roots, id: \.self) { root in
                            rootRow(root, in: project)
                            if root != project.roots.last { Divider() }
                        }
                    }
                    .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
                }
                Text(L10n.string("A task runs in the primary folder. The other folders are passed to the harness."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let instructions {
                instructionsSection(instructions)
            }

            HStack {
                Spacer()
                Button(L10n.string("Done")) {
                    commitName()
                    dismiss()
                }
                .keyboardShortcut(MacShortcut.confirmDialog.binding)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task {
            guard !didLoadName, let project else { return }
            name = project.name
            didLoadName = true
        }
    }

    private func instructionsSection(_ store: YardletInstructionsStore) -> some View {
        let disabled = Binding(get: { store.isDisabled(forProject: projectID) },
                               set: { store.setDisabled($0, forProject: projectID) })
        let text = Binding(get: { store.projectText(for: projectID) },
                           set: { store.setProjectText($0, for: projectID) })
        let off = !store.isEnabled || store.isDisabled(forProject: projectID)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.string("Yardlet Instructions"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(L10n.string("Turn off in this project"), isOn: disabled)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
            TextEditor(text: text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 110)
                .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
                .opacity(off ? 0.6 : 1)
                .accessibilityLabel(L10n.string("Project Yardlet instructions"))
            Text(L10n.string("Added after the global Yardlet instructions in this project's tasks. Turned off here, its tasks receive neither."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rootRow(_ root: URL, in project: Project) -> some View {
        let isPrimary = Project.isSamePath(root, project.primaryRoot)
        return HStack(spacing: 8) {
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
                Button(L10n.string("Make primary")) {
                    projects.setPrimaryRoot(root, for: projectID)
                }
                .buttonStyle(.borderless)
                .parityPointer()
                Button {
                    projects.removeRoot(root, from: projectID)
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

    private func commitName() {
        projects.rename(projectID, to: name)
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = L10n.string("Add folder")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            projects.addRoot(url.standardizedFileURL, to: projectID)
        }
    }
}
