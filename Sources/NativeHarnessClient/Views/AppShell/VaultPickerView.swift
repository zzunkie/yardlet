import SwiftUI

/// The key button's list in the browser panel (docs/BROWSER_VAULT_DESIGN.md §16): the page's own sign-ins or codes,
/// whichever its field takes, and a search over the others by name, username or site, as Chrome's "Select password"
/// and the toolbar lists of 1Password and Bitwarden offer. A row names the account first and says what it fills.
/// Choosing a row fills the page for the person; the list never goes to an agent.
struct VaultPickerView: View {
    @ObservedObject var vault: VaultCenter
    /// The page's origin as the browser reports it.
    let origin: String?
    /// What the page's field takes, or codes from the code bar; nil offers every item.
    var kind: VaultPickerKind? = nil
    /// The item the person filled on the sign-in's earlier step, listed first (design §17).
    var first: UUID? = nil
    @Binding var query: String
    let onPick: (VaultItem) -> Void
    @State private var selected: UUID?
    /// The row the arrow keys moved to, which the list scrolls to (a row the pointer is over is in view already).
    @State private var keyed: UUID?
    @State private var listHeight: CGFloat = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let found = vault.pickerItems(for: origin, matching: query, kind: kind, first: first)
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
                header(siteTitle(VaultSite.host(of: origin)))
                if found.here.isEmpty { note(emptySiteNote) }
                ForEach(found.here) { row($0, here: true) }
            }
            if !found.elsewhere.isEmpty {
                header(kind == .code ? L10n.string("Other two-factor codes") : L10n.string("Other passwords"))
                ForEach(found.elsewhere) { row($0, here: false) }
            }
            if searching, found.here.isEmpty, found.elsewhere.isEmpty {
                note(kind == .code ? L10n.string("No matching two-factor codes") : L10n.string("No matching passwords"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func siteTitle(_ host: String) -> String {
        switch kind {
        case .signIn: L10n.format("Passwords for %@", host)
        case .code: L10n.format("Two-factor codes for %@", host)
        case nil: L10n.format("Saved for %@", host)
        }
    }

    private var emptySiteNote: String {
        switch kind {
        case .signIn: L10n.string("No password is saved for this site. Search for one saved elsewhere.")
        case .code: L10n.string("No two-factor code is saved for this site. Search for one saved elsewhere.")
        case nil: L10n.string("Nothing is saved for this site. Search for a sign-in or code saved elsewhere.")
        }
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

    /// A row: the account, what choosing it fills, and what tells it apart from the site's others; an item saved for
    /// other sites also says where.
    private func row(_ item: VaultItem, here: Bool) -> some View {
        let place = item.sites.first.map { site in
            item.sites.count == 1 ? site : L10n.format("%@ and %lld more", site, Int64(item.sites.count - 1))
        } ?? L10n.string("No site")
        let detail = [item.accountDetail, here ? "" : place].filter { !$0.isEmpty }.joined(separator: " · ")
        let fills = item.kindTitle(for: kind)
        return Button { onPick(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbolName(for: kind))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.accountTitle)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(fills)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
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
        .accessibilityLabel(item.accountTitle)
        .accessibilityValue([fills, detail].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

extension VaultItem {
    /// What tells the item apart from others of its account in the key button's list and the code bar's menu (design
    /// §16, §17): its other fields' values, such as an AWS account ID, then its name, or that it has no username.
    var accountDetail: String {
        let named = username.isEmpty ? L10n.string("No username")
            : name.caseInsensitiveCompare(username) == .orderedSame ? "" : name
        return ((fields ?? []).map(\.value) + [named]).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What choosing the item in a list of this kind fills: its password (or passkey) at a sign-in field, its code at
    /// a code field, and what it holds where the field says neither.
    func kindTitle(for kind: VaultPickerKind?) -> String {
        switch kind {
        case .code: L10n.string("Verification code")
        case .signIn: hasPassword ? L10n.string("Password") : L10n.string("Passkey")
        case nil:
            [hasPassword ? L10n.string("Password") : nil, hasPasskey ? L10n.string("Passkey") : nil,
             hasOneTimeCode ? L10n.string("Verification code") : nil].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// The row's symbol for what it fills: a key for a password, a person with a key for a passkey, digits for a code.
    func symbolName(for kind: VaultPickerKind?) -> String {
        if kind == .code || !hasPassword && !hasPasskey { return "number" }
        return hasPassword ? "key.horizontal" : "person.badge.key"
    }
}
