import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Passwords (docs/BROWSER_VAULT_DESIGN.md §8.1, §9, §14, §16): the switch that gives tasks
/// `browser_fill_credential`, a search over the lists, the current two-factor codes as an authenticator app lists
/// them, the codes with no site to link to theirs, the saved items with their sites, kinds, agent use and last use,
/// adding one, importing a browser's CSV export or an authenticator app's export QR code, and emptying the vault.
/// Rows follow Settings → General and Connectors.
struct VaultSettingsView: View {
    @ObservedObject var vault: VaultCenter
    @State private var editing: Editing?
    @State private var confirmsEmptying = false
    /// Sites that held a Yardlet passkey, shown once the vault is emptied.
    @State private var passkeySites: [String] = []
    @State private var imported: Imported?
    @State private var failure: String?
    /// The items' code secrets, read from the keychain while the page shows codes.
    @State private var codeSecrets: [UUID: OneTimeCodeSecret] = [:]
    /// The site in each code-with-no-site row: the vault's suggestion, or what the person typed.
    @State private var linkSites: [UUID: String] = [:]
    @State private var linkFailure: String?
    /// The search over the lists (design §16): by name, username or site, as Chrome's and the Passwords app's.
    @State private var query: String

    init(vault: VaultCenter, query: String = "") {
        self.vault = vault
        _query = State(initialValue: query)
    }

    private struct Editing: Identifiable {
        let id = UUID()
        let item: VaultItem?
    }

    private struct Imported {
        let title: String
        let count: Int
        let files: [URL]
    }

    private var codeItems: [VaultItem] { vault.items.filter(\.hasOneTimeCode) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var shownItems: [VaultItem] { vault.items.filter { $0.matches(query) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switchCard
            if !vault.items.isEmpty { searchField }
            if codeItems.contains(where: { $0.matches(query) }) { codeList }
            if vault.unlinkedCodes.contains(where: { $0.matches(query) }) { unlinkedList }
            VStack(alignment: .trailing, spacing: 8) {
                itemList
                HStack(spacing: 8) {
                    Button(L10n.string("Import QR Code…"), action: importQRCodes)
                    Button(L10n.string("Import CSV…"), action: importCSV)
                    Button {
                        editing = Editing(item: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help(L10n.string("Add sign-in"))
                    .accessibilityLabel(L10n.string("Add sign-in"))
                }
                .controlSize(.small)
                .disabled(!vault.isAllowedBuild)
                .alert(imported?.title ?? "",
                       isPresented: Binding(get: { imported != nil }, set: { if !$0 { imported = nil } }),
                       presenting: imported) { result in
                    if result.count > 0 {
                        // An export holds secrets in the clear.
                        Button(L10n.string("Move the file to the Trash")) {
                            for file in result.files { try? FileManager.default.trashItem(at: file, resultingItemURL: nil) }
                        }
                        Button(L10n.string("Keep"), role: .cancel) {}
                    } else {
                        Button(L10n.string("OK"), role: .cancel) {}
                    }
                }
            }
            HStack(spacing: 8) {
                Button(L10n.string("Delete all passwords…"), role: .destructive) { confirmsEmptying = true }
                    .controlSize(.small)
                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .alert(L10n.string("Delete all saved passwords?"), isPresented: $confirmsEmptying) {
                Button(L10n.string("Delete All"), role: .destructive, action: empty)
                Button(L10n.string("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.string("Every saved sign-in and its history is deleted from this Mac."))
            }
            // The person's own addresses and cards, filled in the browser panel and never for agents (design §18).
            if !isSearching { VaultWalletSection(vault: vault).padding(.top, 8) }
        }
        .alert(L10n.string("Remove Yardlet's passkey on these sites too"),
               isPresented: Binding(get: { !passkeySites.isEmpty }, set: { if !$0 { passkeySites = [] } })) {
            Button(L10n.string("OK"), role: .cancel) {}
        } message: {
            Text(passkeySites.joined(separator: "\n"))
        }
        .sheet(item: $editing) { editing in
            VaultItemSheet(vault: vault, item: editing.item) { self.editing = nil }
        }
    }

    private var switchCard: some View {
        HStack(spacing: 12) {
            VaultSettingsIcon(systemName: "lock.shield")
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("Password manager for agents")).font(.callout.weight(.medium))
                if !vault.isAllowedBuild {
                    Text(L10n.string("Available in team-signed builds of Yardlet."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            // A build that cannot keep items behind the team's code requirement shows the vault off.
            Toggle(L10n.string("Password manager for agents"), isOn: Binding(
                get: { vault.isAllowedBuild && vault.isEnabled }, set: { vault.isEnabled = $0 }))
                .labelsHidden()
                .toggleStyle(.paritySwitch)
                .controlSize(.small)
                .disabled(!vault.isAllowedBuild)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .parityCard()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.string("Search passwords"), text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel(L10n.string("Search passwords"))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Clear search"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .parityCard(cornerRadius: 8)
    }

    /// Every item's current code, as an authenticator app lists them; the row's button copies one.
    private var codeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Two-factor codes"))
                .font(.callout.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(Array(codeItems.filter { $0.matches(query) }.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, SettingsCenterView.dividerLeading) }
                    HStack(spacing: 12) {
                        VaultSettingsIcon(systemName: "number")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            let detail = [item.identity, item.sites.joined(separator: ", ")].filter { !$0.isEmpty }
                                .joined(separator: " · ")
                            if !detail.isEmpty {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 8)
                        if let secret = codeSecrets[item.id] {
                            VaultLiveCode(vault: vault, secret: secret)
                        }
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .contain)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .parityCard()
        }
        .task(id: codeItems.map(\.id)) {
            codeSecrets = Dictionary(uniqueKeysWithValues: codeItems.compactMap { item in
                vault.secret(of: item.id)?.oneTimeCode.map { (item.id, $0) }
            })
        }
    }

    /// The codes with no site (design §14.3), each with the site to link it to: suggested from the vault's items
    /// and log, checked or changed by the person, and saved only when they link it here or all at once.
    private var unlinkedList: some View {
        let all = vault.unlinkedCodes
        let codes = all.filter { $0.matches(query) }
        let ready = codes.filter { siteToLink($0) != nil }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.string("Two-factor codes with no site"))
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Button(L10n.string("Link All")) { link(ready) }
                    .controlSize(.small)
                    .disabled(ready.isEmpty || !vault.isAllowedBuild)
            }
            VStack(spacing: 0) {
                ForEach(Array(codes.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, SettingsCenterView.dividerLeading) }
                    HStack(spacing: 12) {
                        VaultSettingsIcon(systemName: "number")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            if !item.username.isEmpty {
                                Text(item.username)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 8)
                        TextField(L10n.string("Site"), text: Binding(get: { linkSites[item.id] ?? "" },
                                                                     set: { linkSites[item.id] = $0 }),
                                  prompt: Text(verbatim: "example.com"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 180)
                            .onSubmit { link([item]) }
                            .accessibilityLabel(L10n.format("Site for “%@”", item.name))
                        Button(L10n.string("Link")) { link([item]) }
                            .disabled(siteToLink(item) == nil)
                    }
                    .controlSize(.small)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .contain)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .parityCard()
            .disabled(!vault.isAllowedBuild)
            if let linkFailure {
                Text(linkFailure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: all.map(\.id)) {
            let suggested = vault.suggestedSites(for: all.filter { linkSites[$0.id] == nil })
            for (id, site) in suggested { linkSites[id] = site }
        }
    }

    /// The site a row would save, as the item sheet keeps sites; nil for an empty or unusable one.
    private func siteToLink(_ item: VaultItem) -> String? {
        VaultSite.normalize(linkSites[item.id] ?? "", suffixes: vault.suffixes)
    }

    private func link(_ codes: [VaultItem]) {
        linkFailure = nil
        for item in codes {
            guard let site = siteToLink(item) else { continue }
            if vault.link(item.id, to: site) == nil {
                linkFailure = L10n.string("Yardlet could not read this sign-in from the keychain.")
            } else {
                linkSites[item.id] = nil
            }
        }
    }

    private var itemList: some View {
        let shown = shownItems
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, SettingsCenterView.dividerLeading) }
                VaultItemRow(item: item) { editing = Editing(item: item) }
            }
            if isSearching, shown.isEmpty {
                Text(L10n.string("No matching passwords"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        // With no items the list keeps the height of one row.
        .frame(maxWidth: .infinity, minHeight: 54)
        .parityCard()
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string("Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var encoding = String.Encoding.utf8
        let text = (try? String(contentsOf: url, usedEncoding: &encoding)) ?? ""
        let count = vault.importSignIns(VaultCSVImport.entries(text, suffixes: vault.suffixes))
        imported = Imported(title: L10n.format("Imported %lld sign-ins.", Int64(count)), count: count, files: [url])
    }

    /// Pictures of QR codes: an authenticator app's export (Google Authenticator's Transfer accounts, one
    /// or several codes) or a site's setup code. Each code becomes an item of its own.
    private func importQRCodes() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.string("Import")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let found = VaultQRCodeReader.setups(in: panel.urls.flatMap(VaultQRCodeReader.messages(in:)))
        let count = vault.importOneTimeCodes(found.setups)
        var title = found.setups.isEmpty && found.unsupported == 0
            ? L10n.string("No two-factor QR code is in the picture.")
            : L10n.format("Imported %lld two-factor codes.", Int64(count))
        if found.unsupported > 0 {
            title = L10n.format("Imported %lld two-factor codes. %lld counter-based codes were left out.",
                                Int64(count), Int64(found.unsupported))
        }
        imported = Imported(title: title, count: count, files: panel.urls)
    }

    private func empty() {
        do {
            failure = nil
            let sites = try vault.clear()
            guard !sites.isEmpty else { return }
            // The confirmation closes first; the list of sites is a second alert.
            Task { @MainActor in passkeySites = sites }
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// One saved sign-in: its name, its sites and kinds, how an agent may use it and when one last did.
private struct VaultItemRow: View {
    let item: VaultItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                VaultSettingsIcon(systemName: "key.horizontal")
                VStack(alignment: .leading, spacing: 2) {
                    // The account beside the name tells apart a site's items (design §17): the name gives way first.
                    HStack(spacing: 8) {
                        Text(item.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !item.identity.isEmpty {
                            Text(item.identity)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(item.policy.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 104, alignment: .leading)
                Text(lastUsed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 72, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(([item.identity, detail, item.policy.title, lastUsed]).filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private var detail: String {
        [item.sites.joined(separator: ", "), item.kindsTitle].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var lastUsed: String {
        item.lastUsedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "—"
    }
}

struct VaultSettingsIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(ParityTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
    }
}
