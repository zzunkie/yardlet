import SwiftUI

/// The key button's list in the browser panel (docs/BROWSER_VAULT_DESIGN.md §16): the page's own sign-ins and codes,
/// and a search over every item by name, username or site, as Chrome's "Select password" and the toolbar lists of
/// 1Password and Bitwarden offer. Choosing a row fills the page for the person; the list never goes to an agent.
struct VaultPickerView: View {
    @ObservedObject var vault: VaultCenter
    /// The page's origin as the browser reports it.
    let origin: String?
    /// Only items with a two-factor code (opened from the code bar).
    var codes = false
    @Binding var query: String
    let onPick: (VaultItem) -> Void
    @State private var selected: UUID?
    /// The row the arrow keys moved to, which the list scrolls to (a row the pointer is over is in view already).
    @State private var keyed: UUID?
    @State private var listHeight: CGFloat = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let found = vault.pickerItems(for: origin, matching: query, codes: codes)
        let rows = found.here + found.elsewhere
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            searchField(rows)
            // A popover takes its content's own height, so the list is measured and scrolls past 320 points.
            ScrollViewReader { proxy in
                ScrollView {
                    list(found, searching: searching)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .onChange(of: keyed) { _, id in if let id { proxy.scrollTo(id) } }
            }
            .frame(height: min(max(listHeight, 24), 320))
        }
        .padding(10)
        .frame(width: 340)
        .onAppear { isSearchFocused = true }
        .onChange(of: query) { _, _ in selected = nil }
    }

    private func searchField(_ rows: [VaultItem]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.string("Search passwords"), text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit {
                    if let item = rows.first(where: { $0.id == selected }) ?? rows.first { onPick(item) }
                }
                .onKeyPress(.downArrow) { move(by: 1, in: rows) }
                .onKeyPress(.upArrow) { move(by: -1, in: rows) }
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
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
    }

    private func move(by step: Int, in rows: [VaultItem]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let index = rows.firstIndex { $0.id == selected }.map { $0 + step } ?? (step > 0 ? 0 : rows.count - 1)
        selected = rows[min(max(index, 0), rows.count - 1)].id
        keyed = selected
        return .handled
    }

    private func list(_ found: (here: [VaultItem], elsewhere: [VaultItem]), searching: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let origin, !searching || !found.here.isEmpty {
                header(L10n.format("Saved for %@", VaultSite.host(of: origin)))
                if found.here.isEmpty {
                    note(L10n.string("Nothing is saved for this site. Search for a sign-in or code saved elsewhere."))
                }
                ForEach(found.here) { row($0, here: true) }
            }
            if !found.elsewhere.isEmpty {
                header(L10n.string("Other passwords"))
                ForEach(found.elsewhere) { row($0, here: false) }
            }
            if searching, found.here.isEmpty, found.elsewhere.isEmpty {
                note(L10n.string("No matching passwords"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }

    /// A row: the page's own items say what they hold, the others where they are saved.
    private func row(_ item: VaultItem, here: Bool) -> some View {
        let place = item.sites.isEmpty ? L10n.string("No site") : item.sites.joined(separator: ", ")
        let detail = [item.username, here ? item.kindsTitle : place].filter { !$0.isEmpty }.joined(separator: " · ")
        return Button { onPick(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.hasPassword || item.hasPasskey ? "key.horizontal" : "number")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.callout)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected == item.id ? ParityTheme.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .onHover { if $0 { selected = item.id } }
        .accessibilityLabel(item.name)
        .accessibilityValue(detail)
    }
}
