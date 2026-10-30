import AppKit
import Foundation

/// A sign-in the person just made in the panel, offered for the vault (design §8.3 "Save prompt").
struct BrowserVaultSaveOffer: Equatable {
    var origin: String
    var site: String
    var username: String
    var password: String
    /// The item it would update (same site and username, another password); nil saves a new one.
    var updates: VaultItem?
    /// The item a password the vault made was presaved in beside `updates` (design §15), which updating
    /// makes needless.
    var presaved: UUID?
    /// The form's other fields the person filled, such as an account ID (design §17), which the item keeps.
    var fields: [VaultFormField] = []
    /// `updates` has this password already: the bar adds the username or the other fields to it.
    var addsAccount = false

    /// The account the bar names: the item it updates as updating leaves it.
    var account: String {
        guard var item = updates else { return "" }
        if item.username.isEmpty { item.username = username }
        item.fields = item.merging(fields)
        return item.identity
    }
}

/// A sign-in's earlier step in a tab (design §17), as Chrome keeps a username-first flow's username: the username the
/// person typed there, or the item they filled there from the key button, for the password step that follows on the
/// same site in the same tab, within five minutes.
struct BrowserVaultSignInStep: Equatable {
    static let keep: Duration = .seconds(300)
    var tab: BrowserTabID
    var site: String
    var username: String
    var item: UUID?
    var at = ContinuousClock.now

    func holds(_ tab: BrowserTabID, origin: String) -> Bool {
        self.tab == tab && VaultSite.matches(site, origin: origin) && ContinuousClock.now - at < Self.keep
    }
}

/// A password the vault made in a tab and the item it was presaved in (design §15): submitting the form
/// completes the item; emptying the field before that leaves the item as it is, where Chrome drops it.
struct BrowserVaultMadePassword: Equatable {
    var tab: BrowserTabID
    var item: UUID
    var origin: String
    var submitted = false
}

/// An empty new-password field took the focus (design §15): the bar offers a strong password for it, as
/// Chrome's and Safari's suggestion at the field does.
struct BrowserVaultPasswordOffer: Equatable {
    var origin: String
    /// The document the field is in; moving to another one ends the offer.
    var page: String
}

/// Saved addresses or cards the bar offers to fill at an empty field of their form (design §18).
struct BrowserWalletFillOffer: Equatable {
    enum Which: String { case address, card }
    var which: Which
    /// The document the field is in; moving to another one ends the offer.
    var page: String
}

/// An address or a card the person sent in a form, offered for saving (design §18); `updates` when it is a saved card
/// whose expiry or name changed.
struct BrowserWalletSaveOffer: Equatable {
    var address: VaultAddress?
    var card: VaultCard?
    var updates = false
}

/// A new item the person starts from the page ("Add to Password Manager…").
struct BrowserVaultDraft: Identifiable, Equatable {
    let id = UUID()
    var sites: [String]
    var username: String
}

/// A one-time code field showed on a site whose items have a two-factor code (design §14): the code bar
/// offers to fill the current code, as a password manager's suggestion at the field does.
struct BrowserVaultCodeOffer: Equatable {
    var origin: String
    /// The document the field is in; moving to another one ends the offer.
    var page: String
    var items: [VaultItem]
    /// The site the chosen item keeps, when the items have no site yet and only their name points here.
    var newSite: String? = nil
}

/// An item the person chose from the key button's list and filled on a site it is not saved for (design §16): the
/// bar offers to save that site in it, so it is offered there from then on.
struct BrowserVaultLinkOffer: Equatable {
    var item: VaultItem
    var site: String
}

/// A two-factor setup QR code or link the page showed (design §14), offered for the vault.
struct BrowserVaultSetupOffer: Equatable {
    var origin: String
    /// The site a single code goes with; nil for a page that is no site (a file) and for an
    /// authenticator app's export, whose codes become items of their own.
    var site: String?
    var page: String
    var setups: [OneTimeCodeSetup]
    /// Accounts in an export that Yardlet cannot keep (counter-based codes).
    var unsupported: Int
    /// The item a single code goes into by default; nil makes a new item for the site.
    var target: VaultItem?
    /// The site's items, to choose another target from.
    var choices: [VaultItem]

    var isImport: Bool { site == nil || setups.count > 1 }
}

/// Where the person saves a site's code from the setup bar.
enum BrowserVaultSetupTarget {
    case item(VaultItem)
    case newItem
}

/// The vault in the browser panel: the person's own side (save offers, the key button's fill, making a
/// passkey) and the header's note while an agent's fill goes in.
extension BrowserHostPaneController {
    var vault: VaultCenter { MacAgentToolService.shared.vault }

    /// The sites the person said not to offer saving for.
    static let neverSaveKey = "Yardlet.vault.neverSave"

    func adoptVault(_ tab: BrowserTab, in view: BrowserHostView) {
        view.extraContextMenuItems = { [weak self] in (self?.vaultMenuItems() ?? []) + (self?.loginImportMenuItems() ?? []) }
        if vaultFillObserver == nil {
            vaultFillObserver = NotificationCenter.default.addObserver(forName: .vaultFilled, object: nil, queue: .main) { [weak self] note in
                let filledTab = note.userInfo?[VaultFillNotice.tabKey] as? BrowserTabID
                MainActor.assumeIsolated { self?.vaultFilled(tab: filledTab) }
            }
        }
        // The watch tells of the person's sign-ins: the vault offers saving them, and with per-task
        // profiles the tasks that follow the person's sign-ins take the site's cookies.
        let offers = vault.isAllowedBuild && (vault.isEnabled || vault.isWalletEnabled)
        guard offers || MacBrowserHost.shared.profiles.storage == .perTask else { return }
        let token = tab.devTools.observeEvents { [weak self, weak tab] method, params in
            guard method == "Runtime.bindingCalled", params["name"]?.stringValue == VaultPageScripts.offerBinding,
                  let tab, let payload = params["payload"]?.stringValue else { return }
            self?.pageSaid(payload, on: tab)
        }
        vaultWatch = (tab.id, token)
        Task { await VaultPageScripts.installWatch(tab.devTools) }
    }

    func releaseVault(_ tab: BrowserTab) {
        if let watch = vaultWatch, watch.tab == tab.id { tab.devTools.stopObservingEvents(watch.token) }
        vaultWatch = nil
        vaultOffer = nil
        vaultCodeOffer = nil
        vaultSetupOffer = nil
        vaultPasswordOffer = nil
        vaultLinkOffer = nil
        isVaultPickerShown = false
        focusedPasswordPage = nil
        offeredPasswordPages = []
        madePassword = nil
        walletFillOffer = nil
        walletSaveOffer = nil
        dismissedWalletPages = []
        dismissedSetups = []
        passkeyTask?.cancel()
        view?.extraContextMenuItems = nil
    }

    /// The page moved to another address: the code and setup bars were for the document left.
    func vaultPageMoved(to address: String) {
        if let offer = vaultCodeOffer, offer.page != address { vaultCodeOffer = nil }
        if let offer = vaultSetupOffer, offer.page != address { vaultSetupOffer = nil }
        if let offer = vaultPasswordOffer, offer.page != address { vaultPasswordOffer = nil }
        // A filled code often sends the page on at once; the offer stays while the page is on that site.
        if let offer = vaultLinkOffer, !VaultSite.matches(offer.site, origin: address) { vaultLinkOffer = nil }
        if focusedPasswordPage != address { focusedPasswordPage = nil }
        if let offer = walletFillOffer, offer.page != address { walletFillOffer = nil }
    }

    /// What the watch in the page saw (`VaultPageScripts.offerBinding`).
    private func pageSaid(_ payload: String, on tab: BrowserTab) {
        guard let data = payload.data(using: .utf8),
              let fields = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        switch fields["kind"] {
        case "codeField":
            MacBrowserHost.shared.loginFollow.codeFieldShown(on: tab)
            codeFieldShown(on: tab, page: fields["page"] ?? "")
        case "typedSecret": personTypedSecret(on: tab)
        case "qr": scanForCodes(on: tab, page: fields["page"] ?? "", asked: false)
        case "setup": setupsFound(OneTimeCodeSetup.setups(in: fields["text"] ?? ""), on: tab, page: fields["page"] ?? "",
                                  asked: false)
        case "passwordFocus": passwordFieldFocused(on: tab, page: fields["page"] ?? "", isNew: fields["isNew"] == "1")
        case "passwordBlur": focusedPasswordPage = nil
        case "madeCleared": madePasswordCleared(on: tab)
        case "username": usernameStepTyped(fields["username"] ?? "", on: tab)
        case "walletFocus": walletFieldFocused(on: tab, page: fields["page"] ?? "", which: fields["which"] ?? "")
        case "card": cardSent(fields, on: tab)
        case "address": addressSent(fields["values"] ?? "", on: tab)
        default: personSignedIn(fields, on: tab)
        }
    }

    // MARK: Save offers

    private func personSignedIn(_ fields: [String: String], on tab: BrowserTab) {
        let made = fields["made"] == "1"
        guard made || !(fields["password"] ?? "").isEmpty else { return }
        // A form sent in the address carries what the person typed there too: no tool result does. A made
        // password is on that list since it was filled.
        if let password = fields["password"] { MacAgentToolService.shared.broker.noteVaultValues([password]) }
        let typedUsername = (fields["username"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let others = fields["fields"].flatMap { try? JSONDecoder().decode([VaultFormField].self, from: Data($0.utf8)) } ?? []
        Task { @MainActor [weak self] in
            // The origin comes from the browser, not from the page's script.
            guard let self, let frame = try? await VaultPageScripts.mainFrame(tab.devTools, timeout: .seconds(10)),
                  let site = VaultSite.suggestion(for: frame.origin, suffixes: self.vault.suffixes) else { return }
            MacBrowserHost.shared.loginFollow.signInSubmitted(on: tab)
            guard self.vault.isAllowedBuild, self.vault.isEnabled else { return }
            // A password step with no username takes the one its earlier step asked for.
            let step = self.signInStep.flatMap { $0.holds(tab.id, origin: frame.origin) ? $0 : nil }
            let username = typedUsername.isEmpty ? step?.username ?? "" : typedUsername
            if made {
                return self.madePasswordSubmitted(username: username, fields: others, origin: frame.origin, site: site, on: tab)
            }
            guard let password = fields["password"] else { return }
            let never = UserDefaults.yardlet.stringArray(forKey: Self.neverSaveKey) ?? []
            guard !never.contains(site) else { return }
            let here = self.vault.items(for: frame.origin)
            // The item of this account: the same username, and no other value in a field the form had (one IAM user
            // name in two AWS accounts is two items).
            if let same = here.first(where: { $0.username == username && $0.admits(others) }) {
                let samePassword = self.vault.secret(of: same.id)?.password == password
                guard !samePassword || Set(same.merging(others) ?? []) != Set(same.fields ?? []) else { return }
                self.vaultOffer = BrowserVaultSaveOffer(origin: frame.origin, site: site, username: username, password: password,
                                                        updates: same, fields: others, addsAccount: samePassword)
                return
            }
            // An item saved without a username (a password step's before Yardlet kept the first step's) takes it once
            // its password signs in; it is not changed until the person says so.
            if !username.isEmpty, let blank = here.first(where: {
                $0.username.isEmpty && $0.admits(others) && self.vault.secret(of: $0.id)?.password == password
            }) {
                self.vaultOffer = BrowserVaultSaveOffer(origin: frame.origin, site: site, username: username, password: password,
                                                        updates: blank, fields: others, addsAccount: true)
                return
            }
            self.vaultOffer = BrowserVaultSaveOffer(origin: frame.origin, site: site, username: username,
                                                    password: password, updates: nil, fields: others)
        }
    }

    /// The person typed a username on a step that asks for it alone: the password step after it in the tab takes it.
    private func usernameStepTyped(_ username: String, on tab: BrowserTab) {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, vault.isAllowedBuild, vault.isEnabled else { return }
        Task { @MainActor [weak self] in
            guard let self, let frame = try? await VaultPageScripts.mainFrame(tab.devTools, timeout: .seconds(10)),
                  let site = VaultSite.suggestion(for: frame.origin, suffixes: self.vault.suffixes) else { return }
            // An item filled on the step keeps its place while the username is its own.
            let item = self.signInStep.flatMap { $0.holds(tab.id, origin: frame.origin) && $0.username == username ? $0.item : nil }
            self.signInStep = BrowserVaultSignInStep(tab: tab.id, site: site, username: username, item: item)
        }
    }

    /// The item the key button's list puts first on the page: the one the person filled on the sign-in's earlier step.
    func vaultItemFromEarlierStep(on address: String?) -> UUID? {
        guard let tab, let origin = address.flatMap(VaultSite.origin(of:)), let step = signInStep,
              step.holds(tab.id, origin: origin) else { return nil }
        return step.item
    }

    /// The person typed a password into the page (the agent's typing is no use of the panel): the agent's tools treat
    /// the page as one the vault filled, as after the key button, though the value is not known until it is sent.
    private func personTypedSecret(on tab: BrowserTab) {
        guard vault.isAllowedBuild, vault.isEnabled || vault.isWalletEnabled, let used = tab.lastPersonUse,
              ContinuousClock.now - used < .seconds(5) else { return }
        Task { await VaultPageScripts.noteSecretsShown([], on: tab.devTools, fills: tab.vaultFills) }
    }

    func acceptVaultOffer() {
        guard let offer = vaultOffer else { return }
        vaultOffer = nil
        do {
            if let item = offer.updates {
                var item = item
                var secret = vault.secret(of: item.id) ?? VaultSecret()
                secret.password = offer.password
                // An item saved without a username takes the sign-in's, and the form's other fields.
                if item.username.isEmpty { item.username = offer.username }
                item.fields = item.merging(offer.fields)
                // The replaced password stays in the item's previous ones (`VaultCenter.save`).
                try vault.save(item, secret: secret)
                if let presaved = offer.presaved {
                    vault.logMadePassword(item, .saved, origin: offer.origin, taskID: session,
                                          "The person updated the item with the password made on this page.")
                    try vault.deleteMadePassword(presaved, origin: offer.origin, taskID: session,
                                                 "Its password went into “\(item.name)”, which the person updated.")
                    if madePassword?.item == presaved { madePassword = nil }
                }
            } else {
                let item = VaultItem(name: VaultSite.host(of: offer.origin), sites: [offer.site], username: offer.username,
                                     fields: offer.fields.isEmpty ? nil : offer.fields)
                try vault.save(item, secret: VaultSecret(password: offer.password))
            }
        } catch {
            showVaultNotice(error.localizedDescription)
        }
    }

    func neverSaveHere() {
        guard let offer = vaultOffer else { return }
        vaultOffer = nil
        var never = UserDefaults.yardlet.stringArray(forKey: Self.neverSaveKey) ?? []
        if !never.contains(offer.site) { never.append(offer.site) }
        UserDefaults.yardlet.set(never, forKey: Self.neverSaveKey)
    }

    // MARK: Strong passwords (design §15)

    private func passwordFieldFocused(on tab: BrowserTab, page: String, isNew: Bool) {
        focusedPasswordPage = page
        guard isNew, vault.isAllowedBuild, vault.isEnabled, vaultPasswordOffer == nil, !offeredPasswordPages.contains(page) else { return }
        Task { @MainActor [weak self] in
            guard let self, let frame = try? await VaultPageScripts.mainFrame(tab.devTools, timeout: .seconds(10)),
                  VaultSite.suggestion(for: frame.origin, suffixes: self.vault.suffixes) != nil, self.tab === tab,
                  !self.offeredPasswordPages.contains(page), await VaultPageScripts.shows(page, tab.devTools) else { return }
            self.offeredPasswordPages.insert(page)
            self.vaultPasswordOffer = BrowserVaultPasswordOffer(origin: frame.origin, page: page)
        }
    }

    /// The person chose a strong password from the bar or the page's menu: Yardlet makes one within what the
    /// field asks, keeps it in the vault first (Chrome's presave: a new item for the site, or the item this
    /// tab presaved before; never over a saved password), then fills the field and its confirmation.
    func useStrongPassword() {
        vaultPasswordOffer = nil
        guard let tab, vault.isAllowedBuild, vault.isEnabled else { return }
        Task { @MainActor [weak self] in
            // The site is the one of the document the field is in, as the browser reports it.
            guard let self else { return }
            guard let field = await VaultPageScripts.newPasswordField(tab.devTools) else {
                return self.showVaultNotice(L10n.string("This page has no password field to fill."))
            }
            let context = field.context
            guard let password = self.vault.makePassword(rules: context["rules"]?.stringValue,
                                                         minLength: Int(context["minLength"]?.integerValue ?? 0),
                                                         maxLength: Int(context["maxLength"]?.integerValue ?? 0)) else {
                return self.showVaultNotice(L10n.string("Yardlet could not make a password."))
            }
            let earlier = self.madePassword.flatMap { $0.tab == tab.id && !$0.submitted ? $0.item : nil }
            let origin = field.frame.origin
            let item: VaultItem
            do {
                item = try self.vault.presaveMadePassword(password, origin: origin, username: context["username"]?.stringValue ?? "",
                                                          into: earlier, taskID: self.session)
            } catch {
                return self.showVaultNotice((error as? VaultRefusal)?.message ?? error.localizedDescription)
            }
            // Before the value goes in, as for the key button's fill.
            MacAgentToolService.shared.broker.noteVaultValues([password])
            if password.count >= VaultScrubList.shortest {
                tab.send(.guardFilledValues(tab: tab.id, values: VaultScrubList.spellings(of: password)))
            }
            MacBrowserHost.shared.loginFollow.personFilling(on: tab)
            switch await VaultPageScripts.fillNewPassword(tab.devTools, frame: field.frame, fills: tab.vaultFills,
                                                          into: field.objectID, password: password) {
            case .nothing:
                // Only a fill that certainly put nothing in drops the item made for it.
                if earlier != item.id {
                    try? self.vault.deleteMadePassword(item.id, origin: origin, taskID: self.session,
                                                       "The page took nothing: it moved on first or had no password field.")
                }
                return self.showVaultNotice(L10n.string("This page has no password field to fill."))
            case .unanswered:
                self.vault.logMadePassword(item, .saved, origin: origin, taskID: self.session,
                                           "The page gave no answer to the fill, so the item stays.")
            case .filled:
                break
            }
            self.madePassword = BrowserVaultMadePassword(tab: tab.id, item: item.id, origin: origin)
            self.showVaultNotice(L10n.format("Saved the new password in “%@”.", item.name))
        }
    }

    /// The person submitted a form holding the password the vault made (Chrome saves it then), or the page sent it
    /// with its own script (the watch's `inPlace`): the presaved item takes the username the form held. Beside a saved
    /// item of that username, or, when neither the form nor the item has one (a change dialog, a recovery's new
    /// password page), beside the site's one item with a password, the bar asks to update it.
    private func madePasswordSubmitted(username: String, fields: [VaultFormField], origin: String, site: String,
                                       on tab: BrowserTab) {
        guard let made = madePassword, made.tab == tab.id,
              var item = vault.items(for: origin).first(where: { $0.id == made.item }),
              let password = vault.secret(of: item.id)?.password else { return }
        madePassword?.submitted = true
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let others = vault.items(for: origin).filter { $0.id != item.id }
        let signIns = others.filter(\.hasPassword)
        let saved: VaultItem? = !username.isEmpty ? others.first(where: { $0.username == username && $0.admits(fields) })
            : item.username.isEmpty && signIns.count == 1 ? signIns[0] : nil
        if let saved {
            guard vault.secret(of: saved.id)?.password != password else {
                return vault.logMadePassword(item, .saved, origin: origin, taskID: session,
                                             "The form holding it was sent; “\(saved.name)” already has it.")
            }
            vaultOffer = BrowserVaultSaveOffer(origin: origin, site: site, username: saved.username, password: password,
                                               updates: saved, presaved: item.id, fields: fields)
            return vault.logMadePassword(item, .saved, origin: origin, taskID: session,
                                         "The form holding it was sent; the bar asks to update “\(saved.name)”.")
        }
        let merged = item.merging(fields)
        guard !username.isEmpty && item.username != username || Set(merged ?? []) != Set(item.fields ?? []),
              let secret = vault.secret(of: item.id) else {
            return vault.logMadePassword(item, .saved, origin: origin, taskID: session, "The form holding it was sent.")
        }
        if !username.isEmpty { item.username = username }
        item.fields = merged
        try? vault.save(item, secret: secret)
        vault.logMadePassword(item, .saved, origin: origin, taskID: session,
                              "The form holding it was sent; the item took the form's username.")
    }

    /// The fields holding the made password were emptied before the form was seen to be sent. Chrome drops its presave
    /// then; the item keeps the password (design §15), since the page may have taken it already, and choosing a strong
    /// password again on the page puts a new one into the same item.
    private func madePasswordCleared(on tab: BrowserTab) {
        guard let made = madePassword, made.tab == tab.id, !made.submitted,
              let item = vault.items.first(where: { $0.id == made.item }) else { return }
        vault.logMadePassword(item, .saved, origin: made.origin, taskID: session,
                              "Its fields were emptied before the form was seen to be sent; the item keeps it.")
    }

    // MARK: Addresses and cards (design §18)

    /// An empty field of a card or an address form took the focus: the bar offers the saved ones, once a page.
    private func walletFieldFocused(on tab: BrowserTab, page: String, which: String) {
        guard vault.offersWallet, let which = BrowserWalletFillOffer.Which(rawValue: which), walletFillOffer == nil,
              !dismissedWalletPages.contains(page),
              which == .card ? !vault.wallet.cards.isEmpty : !vault.wallet.addresses.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self, self.tab === tab, await VaultPageScripts.shows(page, tab.devTools) else { return }
            self.walletFillOffer = BrowserWalletFillOffer(which: which, page: page)
        }
    }

    func dismissWalletFillOffer() {
        guard let offer = walletFillOffer else { return }
        walletFillOffer = nil
        dismissedWalletPages.insert(offer.page)
    }

    /// The person sent a card: a new one is offered for saving, a saved one whose expiry or name changed for updating.
    /// Its number goes on the scrubbing list at once, as a typed password does.
    private func cardSent(_ fields: [String: String], on tab: BrowserTab) {
        guard vault.offersWallet, let number = fields["number"], VaultCard.isCardNumber(number),
              let month = Int(fields["month"] ?? ""), (1...12).contains(month), let year = Int(fields["year"] ?? "") else { return }
        let card = VaultCard(name: (fields["name"] ?? "").trimmingCharacters(in: .whitespaces), number: number,
                             expiryMonth: month, expiryYear: year)
        MacAgentToolService.shared.broker.noteVaultValues(card.spellings)
        guard var saved = vault.wallet.cards.first(where: { $0.number == card.number }) else {
            walletSaveOffer = BrowserWalletSaveOffer(card: card)
            return
        }
        guard saved.expiryMonth != card.expiryMonth || saved.expiryYear != card.expiryYear
                || !card.name.isEmpty && saved.name != card.name else { return }
        saved.expiryMonth = card.expiryMonth
        saved.expiryYear = card.expiryYear
        if !card.name.isEmpty { saved.name = card.name }
        walletSaveOffer = BrowserWalletSaveOffer(card: saved, updates: true)
    }

    /// The person sent an address the wallet does not have: the bar offers to save it.
    private func addressSent(_ json: String, on tab: BrowserTab) {
        guard vault.offersWallet, let values = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)),
              let address = VaultAddress(values: values),
              !vault.wallet.addresses.contains(where: { $0.isSame(as: address) }) else { return }
        walletSaveOffer = BrowserWalletSaveOffer(address: address)
    }

    func acceptWalletOffer() {
        guard let offer = walletSaveOffer else { return }
        walletSaveOffer = nil
        do {
            if let card = offer.card { try vault.saveCard(card) }
            if let address = offer.address { try vault.saveAddress(address) }
        } catch {
            showVaultNotice(error.localizedDescription)
        }
    }

    func fillWallet(address: VaultAddress) {
        fillWallet(values: address.values, card: nil)
    }

    /// A card fills after Touch ID or the login password, as Chrome and Safari ask; its number is on the scrubbing list
    /// and the address guard before it goes in, and its document is recorded as filled, as a password's is.
    func fillWallet(card: VaultCard) {
        fillWallet(values: card.values, card: card)
    }

    private func fillWallet(values: [String: String], card: VaultCard?) {
        walletFillOffer = nil
        guard let tab, vault.offersWallet else { return }
        Task { @MainActor [weak self] in
            guard let self, let frame = try? await VaultPageScripts.mainFrame(tab.devTools, timeout: .seconds(10)) else { return }
            if let card {
                guard await self.vault.confirmPerson(L10n.format("fill the card %@", card.label)) else { return }
                MacAgentToolService.shared.broker.noteVaultValues(card.spellings)
                tab.send(.guardFilledValues(tab: tab.id, values: card.spellings.filter { $0.count >= 12 }))
            }
            let kinds = await VaultPageScripts.fillWallet(tab.devTools, frame: frame, fills: tab.vaultFills, values: values,
                                                          secret: card != nil)
            if kinds?.isEmpty != false { self.showVaultNotice(L10n.string("This page has no field to fill.")) }
        }
    }

    // MARK: The key button

    /// The items saved for the page the panel shows.
    func vaultItemsForPage(_ address: String?) -> [VaultItem] {
        guard let address, let origin = VaultSite.origin(of: address) else { return [] }
        return vault.items(for: origin)
    }

    /// Whether the address field shows the key button: on a site's page while the vault holds any item, so that a
    /// sign-in or code saved for another site, or for none, is found from the page too (design §16).
    func showsVaultKey(for address: String?) -> Bool {
        vault.isAllowedBuild && vault.isEnabled && !vault.items.isEmpty && !showsStartPage
            && address.flatMap(VaultSite.origin(of:)) != nil
    }

    /// Opens the key button's list with an empty search; `codes` keeps it to two-factor codes (the code bar's
    /// "Choose Another Code…").
    func openVaultPicker(codes: Bool = false) {
        vaultPickerCodes = codes
        vaultPickerQuery = ""
        isVaultPickerShown = true
    }

    /// The person chose an item from the key button's list: it fills now, whatever the item's agent policy. A code
    /// with no password, and any item chosen from the code bar's list, fills the current code into the page's code
    /// field, or is copied when the page has none; any other item fills the sign-in, or the code from a code field.
    func fillForPerson(_ item: VaultItem) {
        // What the item holds as saved now decides what fills.
        let item = vault.items.first { $0.id == item.id } ?? item
        let codes = vaultPickerCodes
        vaultPickerCodes = false
        isVaultPickerShown = false
        vaultPickerQuery = ""
        if codes { vaultCodeOffer = nil }
        fill(item, codeOnly: codes || !item.hasPassword && item.hasOneTimeCode)
    }

    /// Saves the page's site in the item the person filled there from the list (design §16).
    func acceptVaultLinkOffer() {
        guard let offer = vaultLinkOffer else { return }
        vaultLinkOffer = nil
        if vault.link(offer.item.id, to: offer.site) == nil {
            showVaultNotice(L10n.string("Yardlet could not read this sign-in from the keychain."))
        }
    }

    /// The person chose the code bar's item: its current code goes into the page's code field. An item the
    /// bar offered by its name alone keeps the page's site from now on.
    func fillCodeForPerson(_ item: VaultItem) {
        let offer = vaultCodeOffer
        vaultCodeOffer = nil
        fill(item, codeOnly: true, linking: offer?.items.contains { $0.id == item.id } == true ? offer?.newSite : nil)
    }

    private func fill(_ item: VaultItem, codeOnly: Bool, linking site: String? = nil) {
        guard let tab else { return }
        Task { @MainActor [weak self] in
            guard let self, let frame = try? await VaultPageScripts.mainFrame(tab.devTools, timeout: .seconds(10)) else { return }
            var item = item
            // Saved only while the page is still on that site.
            if let site, VaultSite.matches(site, origin: frame.origin) { item = self.vault.link(item.id, to: site) ?? item }
            // An item for another site asks for Touch ID here before its password goes in.
            guard let grant = await self.vault.valuesForPerson(item, origin: frame.origin, codeOnly: codeOnly) else { return }
            MacAgentToolService.shared.broker.noteVaultValues([grant.password, grant.code])
            if let password = grant.password, password.count >= VaultScrubList.shortest {
                tab.send(.guardFilledValues(tab: tab.id, values: VaultScrubList.spellings(of: password)))
            }
            MacBrowserHost.shared.loginFollow.personFilling(on: tab)
            let filled = await VaultPageScripts.fillForPerson(tab.devTools, frame: frame, fills: tab.vaultFills,
                                                              username: grant.username, password: grant.password,
                                                              code: grant.code, fields: grant.item.fields, codeOnly: codeOnly)
            guard filled else {
                if codeOnly, let code = grant.code {
                    // As Settings → Passwords copies a code: marked concealed and cleared after 90 seconds.
                    VaultClipboard.copy(code, to: self.vaultPasteboard)
                    return self.showVaultNotice(L10n.format(
                        "This page has no code field, so the code from “%@” is copied. It is cleared from the clipboard in 90 seconds.",
                        item.name))
                }
                return self.showVaultNotice(codeOnly ? L10n.string("This page has no code field to fill.")
                                                     : L10n.string("This page has no sign-in field to fill."))
            }
            // A sign-in in steps asks for the password next: the key button's list puts this item first there.
            if !codeOnly, let site = VaultSite.suggestion(for: frame.origin, suffixes: self.vault.suffixes) {
                self.signInStep = BrowserVaultSignInStep(tab: tab.id, site: site, username: grant.username ?? item.username,
                                                         item: grant.item.id)
            }
            if !grant.item.sites.contains(where: { VaultSite.matches($0, origin: frame.origin) }),
               let site = VaultSite.suggestion(for: frame.origin, suffixes: self.vault.suffixes), self.tab === tab {
                self.vaultLinkOffer = BrowserVaultLinkOffer(item: grant.item, site: site)
            }
        }
    }

    // MARK: Two-factor codes (design §14)

    private func codeFieldShown(on tab: BrowserTab, page: String) {
        guard vault.isAllowedBuild, vault.isEnabled else { return }
        Task { @MainActor [weak self] in
            guard let self, let frame = try? await VaultPageScripts.mainFrame(tab.devTools, timeout: .seconds(10)) else { return }
            let own = self.vault.items(for: frame.origin).filter(\.hasOneTimeCode)
            // Codes brought over from an authenticator app have no site until the person picks one here.
            let items = own.isEmpty ? self.vault.unlinkedCodeItems(for: frame.origin) : own
            // On a setup page the field is for the new code, which saving the setup fills.
            guard !items.isEmpty, self.tab === tab, self.vaultSetupOffer == nil,
                  await VaultPageScripts.shows(page, tab.devTools) else { return }
            self.vaultCodeOffer = BrowserVaultCodeOffer(
                origin: frame.origin, page: page, items: items,
                newSite: own.isEmpty ? VaultSite.suggestion(for: frame.origin, suffixes: self.vault.suffixes) : nil)
        }
    }

    /// Reads the QR codes on the tab's screen (Vision) for two-factor setups. `asked` is the person's
    /// right-click; they hear when nothing was found.
    func scanForCodes(on tab: BrowserTab? = nil, page: String? = nil, asked: Bool) {
        guard vault.isAllowedBuild, vault.isEnabled, let tab = tab ?? self.tab, !isScanningForCodes else { return }
        isScanningForCodes = true
        Task { @MainActor [weak self] in
            let shot = try? await tab.devTools.send("Page.captureScreenshot", ["format": .string("png")], timeout: .seconds(10))
            let image = shot?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) }
            let found = await Task.detached(priority: .utility) {
                VaultQRCodeReader.setups(in: image.map(VaultQRCodeReader.messages(in:)) ?? [])
            }.value
            guard let self else { return }
            self.isScanningForCodes = false
            self.setupsFound(found, on: tab, page: page ?? tab.currentURL ?? "", asked: asked)
        }
    }

    private func setupsFound(_ found: (setups: [OneTimeCodeSetup], unsupported: Int), on tab: BrowserTab, page: String,
                             asked: Bool) {
        guard vault.isAllowedBuild, vault.isEnabled else { return }
        keepSetupKeysFromAgents(found.setups, on: tab)
        let new = found.setups.filter { !vault.holds($0.secret) && (asked || !dismissedSetups.contains($0.secret.key)) }
        guard !new.isEmpty else {
            if asked {
                showVaultNotice(found.setups.isEmpty
                    ? L10n.string("No two-factor QR code is on the screen.")
                    : L10n.string("The two-factor code on the screen is already saved."))
            }
            return
        }
        Task { @MainActor [weak self] in
            // The origin comes from the browser, not from the page's script.
            guard let self, let frame = try? await VaultPageScripts.mainFrame(tab.devTools, timeout: .seconds(10)),
                  self.tab === tab, await VaultPageScripts.shows(page, tab.devTools) else { return }
            let site = new.count == 1 ? VaultSite.suggestion(for: frame.origin, suffixes: self.vault.suffixes) : nil
            self.vaultCodeOffer = nil
            self.vaultSetupOffer = BrowserVaultSetupOffer(
                origin: frame.origin, site: site, page: page, setups: new, unsupported: found.unsupported,
                target: site == nil ? nil : self.vault.oneTimeCodeTarget(for: new[0], origin: frame.origin),
                choices: site == nil ? [] : self.vault.items(for: frame.origin))
        }
    }

    /// A setup's key makes the account's codes for good: no tool result carries it, and the agent's tools treat the
    /// page that shows it as one the vault filled, whether or not the person saves it.
    private func keepSetupKeysFromAgents(_ setups: [OneTimeCodeSetup], on tab: BrowserTab) {
        let spellings = setups.flatMap { VaultPageScripts.spellings(ofSetupKey: $0.secret.key) }
        guard !spellings.isEmpty else { return }
        MacAgentToolService.shared.broker.noteVaultValues(spellings)
        Task { await VaultPageScripts.noteSecretsShown(spellings, on: tab.devTools, fills: tab.vaultFills) }
    }

    /// Saves the setup bar's code: a site's into its item (the default target unless the person chose
    /// another), then fills its current code if the page asks for one to confirm the setup; an export's as
    /// items of their own.
    func acceptSetupOffer(into choice: BrowserVaultSetupTarget? = nil) {
        guard let offer = vaultSetupOffer else { return }
        vaultSetupOffer = nil
        guard let site = offer.site, !offer.isImport else {
            let count = vault.importOneTimeCodes(offer.setups)
            showVaultNotice(offer.unsupported > 0
                ? L10n.format("Imported %lld two-factor codes. %lld counter-based codes were left out.",
                              Int64(count), Int64(offer.unsupported))
                : L10n.format("Imported %lld two-factor codes.", Int64(count)))
            return
        }
        let target: VaultItem?
        switch choice {
        case .item(let item): target = item
        case .newItem: target = nil
        case nil: target = offer.target
        }
        let saved: VaultItem
        do {
            saved = try vault.saveOneTimeCode(offer.setups[0], site: site, into: target)
        } catch {
            return showVaultNotice(error.localizedDescription)
        }
        showVaultNotice(L10n.format("Saved the two-factor code in “%@”.", saved.name))
        guard let tab else { return }
        Task { @MainActor [weak self] in
            // Sites ask for the first code to finish turning two-factor on.
            guard await VaultPageScripts.hasCodeField(tab.devTools), let self, self.tab === tab else { return }
            self.fillCodeForPerson(saved)
        }
    }

    func dismissSetupOffer() {
        guard let offer = vaultSetupOffer else { return }
        vaultSetupOffer = nil
        offer.setups.forEach { dismissedSetups.insert($0.secret.key) }
    }

    // MARK: The page's context menu

    private func vaultMenuItems() -> [(title: String, action: () -> Void)] {
        guard vault.isAllowedBuild, vault.isEnabled, let address = tab?.currentURL else { return [] }
        var items: [(title: String, action: () -> Void)] = []
        if VaultSite.suggestion(for: address, suffixes: vault.suffixes) != nil {
            // Chrome's "Generate password" on a password field.
            if focusedPasswordPage != nil {
                items.append((L10n.string("Use Strong Password"), { [weak self] in self?.useStrongPassword() }))
            }
            items.append((L10n.string("Add to Password Manager…"), { [weak self] in self?.startVaultDraft() }))
            if !isMakingPasskey {
                items.append((L10n.string("Make a Yardlet Passkey"), { [weak self] in self?.makeVaultPasskey() }))
            }
        }
        // Also on a page that is no site: a picture of an authenticator app's export.
        items.append((L10n.string("Add Two-Factor Code from QR Code"), { [weak self] in self?.scanForCodes(asked: true) }))
        return items
    }

    private func startVaultDraft() {
        guard let tab, let address = tab.currentURL, let site = VaultSite.suggestion(for: address, suffixes: vault.suffixes) else { return }
        Task { @MainActor [weak self] in
            let username = await VaultPageScripts.typedUsername(tab.devTools)
            self?.vaultDraft = BrowserVaultDraft(sites: [site], username: username)
        }
    }

    /// For two minutes the tab's next passkey registration goes into the vault.
    private func makeVaultPasskey() {
        guard let tab, let address = tab.currentURL else { return }
        isMakingPasskey = true
        showVaultNotice(L10n.string("The next passkey this site makes is saved in the password manager."), for: .seconds(120))
        passkeyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await VaultPasskeyEnrollment.enroll(on: tab.devTools, pageAddress: address, vault: self.vault) {
                Task.isCancelled
            }
            self.isMakingPasskey = false
            switch outcome {
            case .saved(let name): self.showVaultNotice(L10n.format("Saved the passkey in “%@”.", name))
            case .timedOut: self.showVaultNotice(L10n.string("No passkey was made, so none was saved."))
            case .failed(let message): self.showVaultNotice(message)
            }
        }
    }

    // MARK: The header

    private func vaultFilled(tab filledTab: BrowserTabID?) {
        guard let filledTab, filledTab == tab?.id else { return }
        isVaultFilling = true
        vaultIndicatorTask?.cancel()
        vaultIndicatorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.isVaultFilling = false
        }
    }
}
