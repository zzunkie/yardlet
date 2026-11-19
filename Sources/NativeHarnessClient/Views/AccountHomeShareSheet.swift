import SwiftUI

/// What linking a Claude account's folder with the default folder changes, before anything changes:
/// the links to add, the empty folders that give way to them, and what stays because it has content
/// or links elsewhere. Adding a found folder can also keep it as it is. Only links are made.
struct AccountHomeShareSheet: View {
    struct Request: Identifiable {
        let connection: ProviderConnection
        /// The found folder this adds, or nil for a saved account.
        let found: DiscoveredAccountHome?
        let plan: ClaudeAccountHome.Plan
        var id: String { connection.id }
    }

    let request: Request
    let defaultFolder: URL
    let onShare: () -> Void
    let onKeep: () -> Void
    let onCancel: () -> Void

    private var plan: ClaudeAccountHome.Plan { request.plan }
    private func folder(_ path: String) -> String { ProjectSidebarPresentation.abbreviatedPath(for: URL(filePath: path)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string(request.found == nil ? "Share With the Default Folder" : "Add Account"))
                .font(.headline)
            Text(L10n.format("%@ keeps its conversations, settings, plugins and skills apart from the default folder (%@). Linking them lets tasks continue under either login, with one set of settings. Only links are made; nothing is copied, moved or deleted.",
                             folder(request.connection.homePath ?? ""), folder(defaultFolder.path(percentEncoded: false))))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("Links to add", plan.links)
                    section("Empty folders that become links", plan.emptyFolders)
                    section("Kept as they are, because they have content", plan.kept)
                    section("Linked elsewhere, kept as they are", plan.linkedElsewhere)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            if plan.keepsOwnConversations {
                Text(L10n.format("This folder's own conversations (projects) stay apart, so its tasks cannot move to another account. To merge them, quit Claude Code everywhere, move the folders inside this folder's projects into %@, remove the empty projects folder, and share again. Yardlet does not move or delete them.",
                                 folder(defaultFolder.appending(path: "projects").path(percentEncoded: false))))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L10n.string("Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                if request.found != nil {
                    Button(L10n.string("Add As It Is"), action: onKeep)
                }
                if plan.hasChanges {
                    Button(L10n.string(request.found == nil ? "Make Links" : "Link and Add"), action: onShare)
                        .parityProminentButton()
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    @ViewBuilder private func section(_ title: String, _ names: [String]) -> some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(title)).font(.system(size: 12, weight: .semibold))
                Text(names.joined(separator: ", "))
                    .font(.system(size: 12, design: .monospaced)).fontDesign(nil).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
