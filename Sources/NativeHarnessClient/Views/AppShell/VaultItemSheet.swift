import AppKit
import SwiftUI

/// One sign-in in the vault for agents (docs/BROWSER_VAULT_DESIGN.md §8.2): its name, sites,
/// username, password, two-factor setup key and how an agent may use it, with its recent uses and
/// deletion for a saved one. Settings → Passwords opens it, and so does the browser's "Add to Password Manager…"
/// with the page's site filled in. Secrets the person leaves blank stay as saved; the saved password
/// shows only after Touch ID or the login password, as Chrome's and Safari's password pages do. An
/// item may hold a two-factor code alone, without a site or password, as an authenticator app's
/// entry (§14); its current code shows here to copy. The passwords a saved one replaced are kept and
/// show the same way (§15), so a change a site did not take loses nothing.
struct VaultItemSheet: View {
    let vault: VaultCenter
    private let original: VaultItem?
    private let onDone: () -> Void
    private let uses: [VaultUse]
    @State private var name: String
    @State private var sitesText: String
    @State private var username: String
    @State private var password = ""
    @State private var setupKey = ""
    @State private var policy: VaultItem.Policy
    @State private var showsPassword = false
    @State private var confirmsDeleting = false
    /// Sites that held the deleted item's Yardlet passkey; the sheet closes once they are seen.
    @State private var deletedPasskeySites: [String] = []
    @State private var failure: String?
    /// The saved item's code secret, for its current code.
    @State private var savedCode: OneTimeCodeSecret?
    /// How many passwords the saved one replaced, and those passwords once the person confirmed.
    @State private var previousCount = 0
    @State private var previousPasswords: [VaultPreviousPassword]?

    /// - Parameters:
    ///   - item: the saved item to edit, or nil for a new one.
    ///   - draftSites: a new item's sites, such as the page's (`VaultSite.suggestion(for:)`).
    ///   - draftUsername: a new item's username, such as the one the person typed on the page.
    ///   - onDone: called when the sheet is finished (saved, deleted or cancelled); the presenter closes it.
    init(vault: VaultCenter, item: VaultItem?, draftSites: [String] = [], draftUsername: String = "",
         onDone: @escaping () -> Void) {
        self.vault = vault
        original = item
        self.onDone = onDone
        uses = item.map { vault.uses(of: $0.id, limit: 20) } ?? []
        _name = State(initialValue: item?.name ?? draftSites.first ?? "")
        _sitesText = State(initialValue: (item?.sites ?? draftSites).joined(separator: ", "))
        _username = State(initialValue: item?.username ?? draftUsername)
        _policy = State(initialValue: item?.policy ?? .always)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(original?.name ?? L10n.string("New sign-in"))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                fields
                if !uses.isEmpty { recentUses }
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(width: 520)
        .background(ParityTheme.canvas)
        .task {
            guard let original, original.hasOneTimeCode || original.hasPassword, let secret = vault.secret(of: original.id) else { return }
            savedCode = secret.oneTimeCode
            previousCount = secret.previousPasswords?.count ?? 0
        }
        // A password, a previous one or a setup key the person copies out of the sheet goes on the clipboard as the
        // vault's own copies do.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didSendActionNotification)) { note in
            let action = (note.userInfo?["MenuItem"] as? NSMenuItem)?.action
            guard action == #selector(NSText.copy(_:)) || action == #selector(NSText.cut(_:)) else { return }
            VaultClipboard.conceal(ifPartOf: [password, setupKey] + (previousPasswords ?? []).map(\.password))
        }
        .alert(L10n.format("Delete “%@”?", original?.name ?? ""), isPresented: $confirmsDeleting) {
            Button(L10n.string("Delete"), role: .destructive, action: delete)
            Button(L10n.string("Cancel"), role: .cancel) {}
        }
        .alert(L10n.string("Remove Yardlet's passkey on these sites too"), isPresented: Binding(
            get: { !deletedPasskeySites.isEmpty },
            set: { shown in
                guard !shown, !deletedPasskeySites.isEmpty else { return }
                deletedPasskeySites = []
                onDone()
            })) {
            Button(L10n.string("OK"), role: .cancel) {}
        } message: {
            Text(deletedPasskeySites.joined(separator: "\n"))
        }
    }

    // MARK: Fields

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                label(L10n.string("Name"))
                TextField(L10n.string("Name"), text: $name)
            }
            GridRow {
                label(L10n.string("Sites"))
                TextField(L10n.string("Sites"), text: $sitesText, prompt: Text(verbatim: "example.com"))
                    .foregroundColor(sites == nil ? .red : nil)
                    .overlay {
                        if sites == nil {
                            RoundedRectangle(cornerRadius: 5).stroke(Color.red.opacity(0.7))
                        }
                    }
            }
            GridRow {
                label(L10n.string("Username"))
                TextField(L10n.string("Username"), text: $username)
            }
            GridRow {
                label(L10n.string("Password"))
                HStack(spacing: 6) {
                    Group {
                        if showsPassword {
                            TextField(L10n.string("Password"), text: $password, prompt: unchangedPrompt(original?.hasPassword))
                        } else {
                            SecureField(L10n.string("Password"), text: $password, prompt: unchangedPrompt(original?.hasPassword))
                        }
                    }
                    if original?.hasPassword == true {
                        Button(showsPassword ? L10n.string("Hide") : L10n.string("Show a saved password"),
                               action: togglePassword)
                    }
                }
            }
            if previousCount > 0 {
                GridRow {
                    label(L10n.string("Previous passwords"))
                    previousPasswordsView
                }
            }
            GridRow {
                label(L10n.string("Two-factor setup key"))
                TextField(L10n.string("Two-factor setup key"), text: $setupKey,
                          prompt: unchangedPrompt(original?.hasOneTimeCode)
                            ?? Text(L10n.string("Setup key or otpauth:// address")))
                    .foregroundColor(oneTimeCode == nil ? .red : nil)
            }
            if let savedCode, setupKey.isEmpty {
                GridRow {
                    label(L10n.string("Code"))
                    VaultLiveCode(vault: vault, secret: savedCode)
                }
            }
            GridRow {
                label(L10n.string("Agent use"))
                Picker(L10n.string("Agent use"), selection: $policy) {
                    ForEach(VaultItem.Policy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if let original, original.hasPasskey {
                GridRow {
                    Text(verbatim: "")
                    Text(L10n.format("Passkey · made %@", original.createdAt.formatted(date: .abbreviated, time: .omitted)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
    }

    @ViewBuilder
    private var previousPasswordsView: some View {
        if let previousPasswords {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(previousPasswords.enumerated()), id: \.offset) { _, previous in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: previous.password)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(L10n.format("Replaced %@", previous.replacedAt.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button(L10n.string("Hide")) { self.previousPasswords = nil }
            }
        } else {
            HStack(spacing: 6) {
                Text(L10n.format("%lld kept", Int64(previousCount)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L10n.string("Show a saved password"), action: showPreviousPasswords)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    /// "Unchanged" in a saved item's secret field that has a value: left blank, the value stays.
    private func unchangedPrompt(_ hasValue: Bool?) -> Text? {
        hasValue == true ? Text(L10n.string("Unchanged")) : nil
    }

    private var recentUses: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("Recent use"))
                .font(.callout.weight(.semibold))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(uses.enumerated()), id: \.offset) { index, use in
                        if index > 0 { Divider() }
                        useRow(use)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func useRow(_ use: VaultUse) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(use.at.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text([use.taskTitle ?? "—", VaultSite.host(of: use.origin)].joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(use.outcome == .filled ? L10n.string("Filled") : L10n.string("Refused"))
                .fontWeight(.medium)
                .foregroundStyle(use.outcome == .filled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        }
        .font(.caption)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if original != nil {
                Button(L10n.string("Delete…"), role: .destructive) { confirmsDeleting = true }
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button(L10n.string("Cancel"), action: onDone)
                .keyboardShortcut(.cancelAction)
            Button(L10n.string("Save"), action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Values

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The sites as kept, or nil while any part is one no page could match.
    private var sites: [String]? {
        let suffixes = vault.suffixes
        var sites: [String] = []
        for part in sitesText.split(separator: ",") {
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard let site = VaultSite.normalize(text, suffixes: suffixes) else { return nil }
            if !sites.contains(site) { sites.append(site) }
        }
        return sites
    }

    /// The new setup key's secret: `.some(nil)` when the field is blank, nil when it cannot be read.
    private var oneTimeCode: OneTimeCodeSecret?? {
        let text = setupKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .some(nil) }
        return OneTimeCodeSecret(setupText: text).map { .some($0) }
    }

    /// A name, and sites unless the item is a two-factor code alone (an authenticator app's entry, shown
    /// and copied in Settings but filled nowhere).
    private var canSave: Bool {
        guard !trimmedName.isEmpty, let sites, let code = oneTimeCode else { return false }
        return !sites.isEmpty || code != nil || original?.hasOneTimeCode == true
    }

    private func togglePassword() {
        if showsPassword {
            showsPassword = false
            return
        }
        guard let id = original?.id else { return }
        Task { @MainActor in
            guard await vault.confirmPerson(L10n.string("show the saved password")) else { return }
            if password.isEmpty, let saved = vault.secret(of: id)?.password { password = saved }
            showsPassword = true
        }
    }

    private func showPreviousPasswords() {
        guard let id = original?.id else { return }
        Task { @MainActor in
            guard await vault.confirmPerson(L10n.string("show the previous passwords")) else { return }
            previousPasswords = vault.secret(of: id)?.previousPasswords ?? []
        }
    }

    private func save() {
        guard canSave, let sites, let code = oneTimeCode else { return }
        var secret = VaultSecret()
        if let original, original.hasPassword || original.hasOneTimeCode || original.hasPasskey {
            // The values left blank are kept, so they are read first; one the keychain will not give
            // back is not overwritten.
            guard let saved = vault.secret(of: original.id) else {
                failure = L10n.string("Yardlet could not read this sign-in from the keychain.")
                return
            }
            secret = saved
        }
        if !password.isEmpty { secret.password = password }
        if let code { secret.oneTimeCode = code }
        var item = original ?? VaultItem(name: trimmedName, sites: sites, username: "", policy: .always)
        item.name = trimmedName
        item.sites = sites
        item.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        item.policy = policy
        do {
            try vault.save(item, secret: secret)
            onDone()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func delete() {
        guard let original else { return }
        do {
            try vault.delete(original.id)
        } catch {
            failure = error.localizedDescription
            return
        }
        guard original.hasPasskey, !original.sites.isEmpty else { return onDone() }
        // The confirmation closes first; the sites to clean up are a second alert, then the sheet closes.
        Task { @MainActor in deletedPasskeySites = original.sites }
    }
}

extension VaultItem.Policy {
    /// The words for the policy in Settings and the item sheet (design §6.1).
    var title: String {
        switch self {
        case .always: L10n.string("Always")
        case .whileUnlocked: L10n.string("While unlocked")
        case .everyTime: L10n.string("Every time")
        }
    }
}

extension VaultItem {
    /// The kinds of secret the item holds, as "Password · Code · Passkey"; empty for none.
    var kindsTitle: String {
        [hasPassword ? L10n.string("Password") : nil,
         hasOneTimeCode ? L10n.string("Code") : nil,
         hasPasskey ? L10n.string("Passkey") : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
