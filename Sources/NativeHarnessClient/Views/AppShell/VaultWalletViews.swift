import SwiftUI

/// Settings → Passwords, "Addresses and cards" (docs/BROWSER_VAULT_DESIGN.md §18): the switch for saving and filling
/// them in the browser panel, the saved addresses and cards (a card by its network and last four digits), adding and
/// editing one, and deleting them all. Rows follow the password list's.
struct VaultWalletSection: View {
    @ObservedObject var vault: VaultCenter
    @State private var editing: Editing?
    @State private var confirmsDeleting = false
    @State private var failure: String?

    private enum Editing: Identifiable {
        case address(VaultAddress?)
        case card(VaultCard?)

        var id: String {
            switch self {
            case .address(let address): "address-\(address?.id.uuidString ?? "new")"
            case .card(let card): "card-\(card?.id.uuidString ?? "new")"
            }
        }
    }

    var body: some View {
        let wallet = vault.wallet
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Addresses and cards"))
                .font(.callout.weight(.semibold))
            VStack(alignment: .trailing, spacing: 8) {
                VStack(spacing: 0) {
                    switchRow
                    ForEach(wallet.addresses) { address in
                        Divider().padding(.leading, SettingsCenterView.dividerLeading)
                        row(systemName: "house", title: address.name.isEmpty ? address.place : address.name,
                            detail: address.name.isEmpty ? "" : address.place) {
                            editing = .address(address)
                        }
                    }
                    ForEach(wallet.cards) { card in
                        Divider().padding(.leading, SettingsCenterView.dividerLeading)
                        row(systemName: "creditcard", title: card.label,
                            detail: [L10n.format("Expires %@", card.expiry), card.name].filter { !$0.isEmpty }
                                .joined(separator: " · ")) {
                            editing = .card(card)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .parityCard()
                HStack(spacing: 8) {
                    if !wallet.isEmpty {
                        Button(L10n.string("Delete All Addresses and Cards…"), role: .destructive) { confirmsDeleting = true }
                    }
                    Spacer(minLength: 8)
                    if let failure {
                        Text(failure).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                    Button(L10n.string("Add Address…")) { editing = .address(nil) }
                    Button(L10n.string("Add Card…")) { editing = .card(nil) }
                }
                .controlSize(.small)
                .disabled(!vault.isAllowedBuild)
            }
        }
        .alert(L10n.string("Delete all saved addresses and cards?"), isPresented: $confirmsDeleting) {
            Button(L10n.string("Delete All"), role: .destructive) {
                do { try vault.deleteWallet() } catch { failure = error.localizedDescription }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("They are deleted from this Mac's keychain."))
        }
        .sheet(item: $editing) { editing in
            switch editing {
            case .address(let address): VaultAddressSheet(vault: vault, address: address) { self.editing = nil }
            case .card(let card): VaultCardSheet(vault: vault, card: card) { self.editing = nil }
            }
        }
    }

    private var switchRow: some View {
        HStack(spacing: 12) {
            VaultSettingsIcon(systemName: "creditcard")
            Text(L10n.string("Save and fill addresses and cards")).font(.callout.weight(.medium))
            Spacer(minLength: 8)
            Toggle(L10n.string("Save and fill addresses and cards"), isOn: Binding(
                get: { vault.offersWallet }, set: { vault.isWalletEnabled = $0 }))
                .labelsHidden()
                .toggleStyle(.paritySwitch)
                .controlSize(.small)
                .disabled(!vault.isAllowedBuild)
        }
        .padding(.vertical, 12)
    }

    private func row(systemName: String, title: String, detail: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 12) {
                VaultSettingsIcon(systemName: systemName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
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
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }
}

/// The frame both wallet sheets share, as the item sheet's: a title, the fields, and Delete, Cancel and Save.
private struct VaultWalletSheetFrame<Fields: View>: View {
    let title: String
    let canDelete: Bool
    let canSave: Bool
    let failure: String?
    let onDelete: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void
    @ViewBuilder let fields: () -> Fields

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                fields()
            }
            .textFieldStyle(.roundedBorder)
            .padding(20)
            Divider()
            HStack(spacing: 8) {
                if canDelete { Button(L10n.string("Delete"), role: .destructive, action: onDelete) }
                if let failure {
                    Text(failure).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer(minLength: 8)
                Button(L10n.string("Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L10n.string("Save"), action: onSave).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
        .background(ParityTheme.canvas)
    }
}

private func walletLabel(_ text: String) -> some View {
    Text(text).font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
}

/// One address, as forms ask for it.
struct VaultAddressSheet: View {
    @ObservedObject var vault: VaultCenter
    private let original: VaultAddress?
    private let onDone: () -> Void
    @State private var address: VaultAddress
    @State private var failure: String?

    init(vault: VaultCenter, address: VaultAddress?, onDone: @escaping () -> Void) {
        self.vault = vault
        original = address
        self.onDone = onDone
        _address = State(initialValue: address ?? VaultAddress())
    }

    var body: some View {
        VaultWalletSheetFrame(title: original == nil ? L10n.string("New address") : L10n.string("Address"),
                              canDelete: original != nil,
                              canSave: !address.street.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              failure: failure, onDelete: delete, onCancel: onDone, onSave: save) {
            row(L10n.string("Name"), $address.name)
            row(L10n.string("Organization"), $address.organization)
            GridRow {
                walletLabel(L10n.string("Street"))
                TextField(L10n.string("Street"), text: $address.street, axis: .vertical).lineLimit(2...4)
            }
            row(L10n.string("City"), $address.city)
            row(L10n.string("State or province"), $address.region)
            row(L10n.string("Postal code"), $address.postalCode)
            row(L10n.string("Country"), $address.country)
            row(L10n.string("Phone"), $address.phone)
            row(L10n.string("Email"), $address.email)
        }
    }

    private func row(_ title: String, _ value: Binding<String>) -> some View {
        GridRow {
            walletLabel(title)
            TextField(title, text: value)
        }
    }

    private func save() {
        do {
            try vault.saveAddress(address)
            onDone()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func delete() {
        do {
            try vault.deleteWalletEntry(address.id)
            onDone()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// One card: the name on it, its number (kept unchanged when left empty), its expiry and a nickname. No security code
/// is asked for or kept (design §18).
struct VaultCardSheet: View {
    @ObservedObject var vault: VaultCenter
    private let original: VaultCard?
    private let onDone: () -> Void
    @State private var name: String
    @State private var number = ""
    @State private var month: String
    @State private var year: String
    @State private var nickname: String
    @State private var failure: String?

    init(vault: VaultCenter, card: VaultCard?, onDone: @escaping () -> Void) {
        self.vault = vault
        original = card
        self.onDone = onDone
        _name = State(initialValue: card?.name ?? "")
        _month = State(initialValue: card.map { String(format: "%02d", $0.expiryMonth) } ?? "")
        _year = State(initialValue: card.map { String($0.expiryYear) } ?? "")
        _nickname = State(initialValue: card?.nickname ?? "")
    }

    /// The card as saving leaves it, or nil while a field holds what no card could.
    private var card: VaultCard? {
        let digits = number.isEmpty ? original?.number ?? "" : VaultCard.digits(number)
        guard VaultCard.isCardNumber(digits), let month = Int(month), (1...12).contains(month),
              let year = Int(year), (0...2099).contains(year) else { return nil }
        var card = VaultCard(name: name.trimmingCharacters(in: .whitespaces), number: digits, expiryMonth: month,
                             expiryYear: year, nickname: nickname.trimmingCharacters(in: .whitespaces))
        card.id = original?.id ?? card.id
        return card
    }

    var body: some View {
        VaultWalletSheetFrame(title: original?.label ?? L10n.string("New card"), canDelete: original != nil,
                              canSave: card != nil, failure: failure, onDelete: delete, onCancel: onDone, onSave: save) {
            GridRow {
                walletLabel(L10n.string("Name on card"))
                TextField(L10n.string("Name on card"), text: $name)
            }
            GridRow {
                walletLabel(L10n.string("Card number"))
                SecureField(L10n.string("Card number"), text: $number,
                            prompt: original.map { _ in Text(L10n.string("Unchanged")) })
                    .foregroundColor(!number.isEmpty && !VaultCard.isCardNumber(number) ? .red : nil)
            }
            GridRow {
                walletLabel(L10n.string("Expires"))
                HStack(spacing: 6) {
                    TextField(L10n.string("Month"), text: $month, prompt: Text(verbatim: "MM")).frame(width: 56)
                    Text(verbatim: "/").foregroundStyle(.secondary)
                    TextField(L10n.string("Year"), text: $year, prompt: Text(verbatim: "YYYY")).frame(width: 72)
                }
            }
            GridRow {
                walletLabel(L10n.string("Nickname"))
                TextField(L10n.string("Nickname"), text: $nickname)
            }
        }
    }

    private func save() {
        guard let card else { return }
        do {
            try vault.saveCard(card)
            onDone()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func delete() {
        guard let original else { return }
        do {
            try vault.deleteWalletEntry(original.id)
            onDone()
        } catch {
            failure = error.localizedDescription
        }
    }
}
