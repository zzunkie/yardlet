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
    /// The sign-in's other secrets beside the password (design §17), which the item's keychain secret keeps.
    var secretFields: [VaultFormField] = []
    /// `updates` has this password and these secrets already: the bar adds the username or the other fields to it.
    var addsAccount = false
    /// A password sent with no username: the site's items the bar's menu offers to update instead of `updates`
    /// (`VaultCenter.update(forUnnamed:origin:fields:excluding:)`).
    var choices: [VaultItem] = []

    /// The account the bar names: the item it updates as updating leaves it, or its name for one that names no account.
    var account: String {
        guard var item = updates else { return "" }
        if item.username.isEmpty { item.username = username }
        item.fields = item.merging(fields)
        return item.identity.isEmpty ? "“\(item.name)”" : item.identity
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

/// An empty username, email or password field of a sign-in form took the focus on a site with a saved item: the bar
/// above the page offers to fill it (design §6.1), as Chrome's and Safari's at-the-field suggestion does. Yardlet
/// never fills from focus alone; the person has to click the bar's Fill button. A dismissed page stays dismissed for
/// as long as the panel keeps that address; a new navigation or a new tab resets the dismissed list.
struct BrowserVaultSignInOffer: Equatable {
    /// The step the field is at: the username/email field of the first step, or the password field of the
    /// second step (or a one-step form's password field). A password step prefers an item whose username
    /// was filled in the tab's earlier step (`BrowserVaultSignInStep`) when there is one.
    enum Step: String { case username, password }
    var origin: String
    /// The document the field is in; moving to another one ends the offer.
    var page: String
    var step: Step
    /// The items the bar offers, in the order the key button's list would use. The step narrows them: a password
    /// step keeps only items with a password; a username step keeps items with a username or a password.
    var items: [VaultItem]
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
    /// The agent's ask this bar answers (`BrowserTab.vaultSetupAsk`), when the agent's code fill found the setup.
    var ask: UUID?

    var isImport: Bool { site == nil || setups.count > 1 }
}

/// Where the person saves from a bar's menu: another of the site's items, or a new one.
enum BrowserVaultTarget {
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
        // The watch tells of the person's sign-ins, which the vault offers to save.
        guard vault.isAllowedBuild && (vault.isEnabled || vault.isWalletEnabled) else { return }
        // The vault binding carries the OOPIF's session id, read from the CDP envelope (not from the page's own
        // script), so `pageSaid` can refuse an event from a session whose chain is not same-site to the main frame —
        // the cross-site OOPIF defense this PR's second round added.
        tab.devTools.onVaultBinding = { [weak self, weak tab] params, session in
            guard params["name"]?.stringValue == VaultPageScripts.offerBinding,
                  let tab, let payload = params["payload"]?.stringValue else { return }
            self?.pageSaid(payload, session: session, on: tab)
        }
        // A nested OOPIF attaches on its parent OOPIF's session (the dev-tools client forwards it through
        // `onFrameAttached`), so the watch also goes into frames that come to life after `installWatch` ran.
        tab.devTools.onFrameAttached = { [weak tab] session in
            guard let tab else { return }
            Task { await VaultPageScripts.installWatchForAttached(tab.devTools, session: session) }
        }
        vaultWatch = (tab.id, UUID())
        Task { await VaultPageScripts.installWatch(tab.devTools) }
    }

    func releaseVault(_ tab: BrowserTab) {
        if let watch = vaultWatch, watch.tab == tab.id {
            tab.devTools.onVaultBinding = nil
            tab.devTools.onFrameAttached = nil
        }
        vaultWatch = nil
        vaultOffer = nil
        vaultCodeOffer = nil
        vaultSetupOffer = nil
        vaultPasswordOffer = nil
        vaultSignInOffer = nil
        vaultLinkOffer = nil
        isVaultPickerShown = false
        focusedPasswordPage = nil
        offeredPasswordPages = []
        dismissedSignInPages = []
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
        if let offer = vaultSetupOffer, offer.page != address {
            vaultSetupOffer = nil
            if offer.ask != nil, tab?.vaultSetupAsk?.id == offer.ask { tab?.answerSetupAsk(.pageMoved) }
        }
        if let offer = vaultPasswordOffer, offer.page != address { vaultPasswordOffer = nil }
        if let offer = vaultSignInOffer, offer.page != address { vaultSignInOffer = nil }
        // Moving to another address clears the sign-in dismissed list — Not Now holds only on the page it was pressed,
        // as design §8.3 states. Pages in `offeredPasswordPages` are independent.
        if !dismissedSignInPages.contains(address) { dismissedSignInPages.removeAll() }
        // A filled code often sends the page on at once; the offer stays while the page is on that site.
        if let offer = vaultLinkOffer, !VaultSite.matches(offer.site, origin: address) { vaultLinkOffer = nil }
        if focusedPasswordPage != address { focusedPasswordPage = nil }
        if let offer = walletFillOffer, offer.page != address { walletFillOffer = nil }
    }

    /// What the watch in the page saw (`VaultPageScripts.offerBinding`). `session` is the CDP session id of the frame
    /// that sent the payload: `nil` is the tab's own session (the main frame or a same-process subframe), and anything
    /// else is an attached out-of-process iframe. An OOPIF whose chain to the main frame is not same-site has every
    /// event it sends discarded, so a cross-site OOPIF cannot push a save prompt, a typed-secret notice or a sign-in
    /// focus onto the main frame's address.
    private func pageSaid(_ payload: String, session: String?, on tab: BrowserTab) {
        guard let data = payload.data(using: .utf8),
              let fields = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        if let session {
            Task { @MainActor [weak self, weak tab] in
                // A late event that arrives after the panel switched to another tab goes nowhere: the handlers below
                // read `self.tab`, so an event for a tab the panel no longer shows would land on the wrong page.
                guard let self, let tab, self.tab === tab,
                      await self.isSameSiteOOPIF(session: session, on: tab) else { return }
                self.handleWatchFields(fields, on: tab)
            }
            return
        }
        handleWatchFields(fields, on: tab)
    }

    /// Whether an OOPIF whose own session id is `session` sits in a chain that is same-site to the tab's main frame:
    /// every origin on the way (`origins(around:)`) and the OOPIF's own origin have to be pages of the main frame's
    /// site (`VaultSite.matches`). A frame the browser does not describe, or a chain that reaches no main frame,
    /// reads as not same-site — fail-closed, matching the rest of the vault.
    private func isSameSiteOOPIF(session: String, on tab: BrowserTab) async -> Bool {
        guard let frames = try? await VaultPageScripts.frames(tab.devTools, timeout: .seconds(5)),
              let main = frames.first,
              let sessionFrame = frames.first(where: { $0.session == session }),
              let around = VaultPageScripts.origins(around: sessionFrame, in: frames),
              let site = VaultSite.suggestion(for: main.origin, suffixes: vault.suffixes) else { return false }
        return VaultSite.matches([site], origins: [sessionFrame.origin] + around)
    }

    private func handleWatchFields(_ fields: [String: String], on tab: BrowserTab) {
        switch fields["kind"] {
        case "codeField":
            codeFieldShown(on: tab, page: fields["page"] ?? "")
        case "typedSecret": personTypedSecret(on: tab)
        case "qr": scanForCodes(on: tab, page: fields["page"] ?? "", asked: false)
        case "setup": setupsFound(OneTimeCodeSetup.setups(in: fields["text"] ?? ""), on: tab, page: fields["page"] ?? "",
                                  asked: false)
        case "passwordFocus": passwordFieldFocused(on: tab, page: fields["page"] ?? "", isNew: fields["isNew"] == "1")
        case "passwordBlur": focusedPasswordPage = nil
        case "signInFocus":
            signInFieldFocused(on: tab, page: fields["page"] ?? "",
                               step: BrowserVaultSignInOffer.Step(rawValue: fields["step"] ?? ""))
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
        let secrets = made ? [] : fields["secrets"].flatMap { try? JSONDecoder().decode([VaultFormField].self, from: Data($0.utf8)) } ?? []
        MacAgentToolService.shared.broker.noteVaultValues([fields["password"]] + secrets.map(\.value))
        let typedUsername = (fields["username"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let others = fields["fields"].flatMap { try? JSONDecoder().decode([VaultFormField].self, from: Data($0.utf8)) } ?? []
        Task { @MainActor [weak self] in
            // The origin comes from the browser, not from the page's script.
            guard let self, let frame = try? await VaultPageScripts.mainFrame(tab.devTools, timeout: .seconds(10)),
                  let site = VaultSite.suggestion(for: frame.origin, suffixes: self.vault.suffixes) else { return }
            guard self.vault.isAllowedBuild, self.vault.isEnabled else { return }
            // A password step with no username takes the one its earlier step asked for.
            let step = self.signInStep.flatMap { $0.holds(tab.id, origin: frame.origin) ? $0 : nil }
            let username = typedUsername.isEmpty ? step?.username ?? "" : typedUsername
            if made {
                return await self.madePasswordSubmitted(username: username, fields: others, origin: frame.origin, site: site, on: tab)
            }
            guard let password = fields["password"] else { return }
            let never = UserDefaults.yardlet.stringArray(forKey: Self.neverSaveKey) ?? []
            guard !never.contains(site) else { return }
            // A password sent with no username (a reset or change dialog, a password-only step) updates the item Chrome
            // would, and the bar's menu offers the site's other items; an item that holds it already only takes new fields.
            // Whether the item holds this password and these secrets already.
            @MainActor func holds(_ item: VaultItem) async -> Bool {
                guard let secret = await self.vault.secret(of: item.id), secret.password == password else { return false }
                return Set(secret.fields?.merging(secrets) ?? secrets) == Set(secret.fields ?? [])
            }
            if username.isEmpty {
                let update = await self.vault.update(forUnnamed: password, origin: frame.origin, fields: others)
                if update.holdsIt, let item = update.item, await holds(item) {
                    guard self.tab === tab, self.vault.isEnabled,
                          Set(item.merging(others) ?? []) != Set(item.fields ?? []) else { return }
                    self.vaultOffer = BrowserVaultSaveOffer(origin: frame.origin, site: site, username: username, password: password,
                                                            updates: item, fields: others, secretFields: secrets, addsAccount: true)
                    return
                }
                guard self.tab === tab, self.vault.isEnabled else { return }
                self.vaultOffer = BrowserVaultSaveOffer(origin: frame.origin, site: site, username: username, password: password,
                                                        updates: update.item, fields: others, secretFields: secrets,
                                                        choices: update.choices)
                return
            }
            let here = self.vault.items(for: frame.origin)
            // The item of this account: the same username, and no other value in a field the form had (one IAM user
            // name in two AWS accounts is two items). Its secrets are no account's name: new ones update it.
            if let same = here.first(where: { $0.username == username && $0.admits(others) }) {
                let held = await holds(same)
                guard self.tab === tab, self.vault.isEnabled,
                      !held || Set(same.merging(others) ?? []) != Set(same.fields ?? []) else { return }
                self.vaultOffer = BrowserVaultSaveOffer(origin: frame.origin, site: site, username: username, password: password,
                                                        updates: same, fields: others, secretFields: secrets, addsAccount: held)
                return
            }
            // An item saved without a username (a password step's before Yardlet kept the first step's) takes it once
            // its password signs in; it is not changed until the person says so.
            for blank in here where blank.username.isEmpty && blank.admits(others) {
                guard await holds(blank) else { continue }
                guard self.tab === tab, self.vault.isEnabled else { return }
                self.vaultOffer = BrowserVaultSaveOffer(origin: frame.origin, site: site, username: username, password: password,
                                                        updates: blank, fields: others, secretFields: secrets, addsAccount: true)
                return
            }
            guard self.tab === tab, self.vault.isEnabled else { return }
            self.vaultOffer = BrowserVaultSaveOffer(origin: frame.origin, site: site, username: username,
                                                    password: password, updates: nil, fields: others, secretFields: secrets)
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

    /// Saves the bar's sign-in into the item it names, or into the one the person chose from its menu (`choice`).
    func acceptVaultOffer(_ presented: BrowserVaultSaveOffer? = nil, into choice: BrowserVaultTarget? = nil) async {
        guard var offer = vaultOffer, presented == nil || presented == offer else { return }
        vaultOffer = nil
        switch choice {
        case .item(let item):
            offer.updates = item
            offer.addsAccount = false
        case .newItem:
            offer.updates = nil
            // A made password is in its own item already.
            if let presaved = offer.presaved, let item = vault.items.first(where: { $0.id == presaved }) {
                return vault.logMadePassword(item, .saved, origin: offer.origin, taskID: session,
                                             "The person kept it in its own item.")
            }
        case nil:
            break
        }
        do {
            if let target = offer.updates {
                let item: VaultItem
                do {
                    await vault.beginChange()
                    defer { vault.endChange() }
                    guard var current = vault.items(for: offer.origin).first(where: { $0.id == target.id }),
                          current.username == target.username, current.admits(offer.fields),
                          var secret = await vault.secret(of: current.id) else {
                        return showVaultNotice(L10n.string("Yardlet could not read this sign-in from the keychain."))
                    }
                    secret.password = offer.password
                    secret.fields = (secret.fields ?? []).merging(offer.secretFields)
                    if current.username.isEmpty { current.username = offer.username }
                    current.fields = current.merging(offer.fields)
                    try await vault.saveItem(current, secret: secret)
                    item = current
                }
                if let presaved = offer.presaved {
                    vault.logMadePassword(item, .saved, origin: offer.origin, taskID: session,
                                          "The person updated the item with the password made on this page.")
                    try await vault.deleteMadePassword(presaved, origin: offer.origin, taskID: session,
                                                 "Its password went into “\(item.name)”, which the person updated.")
                    if madePassword?.item == presaved { madePassword = nil }
                }
            } else {
                let item = VaultItem(name: VaultSite.host(of: offer.origin), sites: [offer.site], username: offer.username,
                                     fields: offer.fields.isEmpty ? nil : offer.fields)
                try await vault.save(item, secret: VaultSecret(password: offer.password,
                                                         fields: offer.secretFields.isEmpty ? nil : offer.secretFields))
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
            // The field may be in a frame on the page's site, which the new item keeps (design §6.2).
            guard let self, let frame = try? await VaultPageScripts.mainFrame(tab.devTools, timeout: .seconds(10)),
                  let site = VaultSite.suggestion(for: frame.origin, suffixes: self.vault.suffixes), self.tab === tab,
                  !self.offeredPasswordPages.contains(page),
                  let shown = await VaultPageScripts.showing(page, tab.devTools, sites: [[site]]) else { return }
            self.offeredPasswordPages.insert(page)
            self.vaultSignInOffer = nil
            self.vaultPasswordOffer = BrowserVaultPasswordOffer(origin: frame.origin, page: shown)
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
            guard let field = await VaultPageScripts.newPasswordField(tab.devTools, suffixes: self.vault.suffixes) else {
                return self.showVaultNotice(L10n.string("This page has no password field to fill."))
            }
            let context = field.context
            guard let password = self.vault.makePassword(rules: context["rules"]?.stringValue,
                                                         minLength: Int(context["minLength"]?.integerValue ?? 0),
                                                         maxLength: Int(context["maxLength"]?.integerValue ?? 0)) else {
                return self.showVaultNotice(L10n.string("Yardlet could not make a password."))
            }
            let earlier = self.madePassword.flatMap { $0.tab == tab.id && !$0.submitted ? $0.item : nil }
            let origin = field.frame.frame.origin
            let item: VaultItem
            do {
                item = try await self.vault.presaveMadePassword(password, origin: origin, username: context["username"]?.stringValue ?? "",
                                                          into: earlier, taskID: self.session)
            } catch {
                return self.showVaultNotice((error as? VaultRefusal)?.message ?? error.localizedDescription)
            }
            // Before the value goes in, as for the key button's fill.
            MacAgentToolService.shared.broker.noteVaultValues([password])
            if password.count >= VaultScrubList.shortest {
                tab.send(.guardFilledValues(tab: tab.id, values: VaultScrubList.spellings(of: password)))
            }
            switch await VaultPageScripts.fillNewPassword(tab.devTools, frame: field.frame, fills: tab.vaultFills,
                                                          into: field.objectID, password: password) {
            case .nothing:
                // Only a fill that certainly put nothing in drops the item made for it.
                if earlier != item.id {
                    try? await self.vault.deleteMadePassword(item.id, origin: origin, taskID: self.session,
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
    /// password page), beside the item a password sent with no username updates, the bar asks to update it, and its menu
    /// offers the site's other items.
    private func madePasswordSubmitted(username: String, fields: [VaultFormField], origin: String, site: String,
                                       on tab: BrowserTab) async {
        guard let made = madePassword, made.tab == tab.id else { return }
        await vault.beginChange()
        defer { vault.endChange() }
        guard var item = vault.items(for: origin).first(where: { $0.id == made.item }),
              let secret = await vault.secret(of: item.id), let password = secret.password,
              self.tab === tab, madePassword?.item == made.item else { return }
        madePassword?.submitted = true
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let unnamed = username.isEmpty && item.username.isEmpty
            ? await vault.unnamedUpdate(password, origin: origin, fields: fields, excluding: item.id) : nil
        let saved: VaultItem? = !username.isEmpty
            ? vault.items(for: origin).first(where: { $0.id != item.id && $0.username == username && $0.admits(fields) })
            : unnamed?.item
        if let saved {
            guard await vault.secret(of: saved.id)?.password != password else {
                return vault.logMadePassword(item, .saved, origin: origin, taskID: session,
                                             "The form holding it was sent; “\(saved.name)” already has it.")
            }
            vaultOffer = BrowserVaultSaveOffer(origin: origin, site: site, username: saved.username, password: password,
                                               updates: saved, presaved: item.id, fields: fields, choices: unnamed?.choices ?? [])
            return vault.logMadePassword(item, .saved, origin: origin, taskID: session,
                                         "The form holding it was sent; the bar asks to update “\(saved.name)”.")
        }
        let merged = item.merging(fields)
        guard !username.isEmpty && item.username != username || Set(merged ?? []) != Set(item.fields ?? []) else {
            return vault.logMadePassword(item, .saved, origin: origin, taskID: session, "The form holding it was sent.")
        }
        if !username.isEmpty { item.username = username }
        item.fields = merged
        guard (try? await vault.saveItem(item, secret: secret)) != nil else { return }
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

    // MARK: Sign-in focus (design §6.1)

    /// An empty username/email or password field took the focus in a document the vault may fill: the bar beside the
    /// page offers a saved item (design §6.1). Nothing is filled from focus alone — the bar's Fill button is what
    /// fills, matching Chrome's and Safari's behavior. A page the person dismissed stays dismissed until the panel
    /// opens another address. Other bars take precedence: a one-time code bar at a code field, a strong-password bar
    /// at an empty new-password field, and a wallet fill bar at a card or address field.
    private func signInFieldFocused(on tab: BrowserTab, page: String, step: BrowserVaultSignInOffer.Step?) {
        guard let step, vault.isAllowedBuild, vault.isEnabled,
              vaultCodeOffer == nil, vaultPasswordOffer == nil, walletFillOffer == nil else { return }
        Task { @MainActor [weak self] in
            // The origin comes from the browser, not the page's script, as every other bar does.
            guard let self, let frame = try? await VaultPageScripts.mainFrame(tab.devTools, timeout: .seconds(10)),
                  self.tab === tab else { return }
            // `pickerItems` orders the site's items the way the key button's list does (last-used first, then by
            // account name) and puts the item filled at the sign-in's earlier step (`BrowserVaultSignInStep`) at the
            // front — no hand-rolled `sorted` that could break Swift's strict weak ordering.
            let step1 = self.vaultItemFromEarlierStep(on: tab.currentURL)
            let items = self.vault.pickerItems(for: frame.origin, matching: "", kind: .signIn, first: step1).here
                .filter { step == .password ? $0.hasPassword : !$0.username.isEmpty }
            guard !items.isEmpty else { return }
            // The field's document must be fillable by one of the items (the same chain `fillFrames` enforces for the
            // key button). `showing` returns the main frame's address when a frame `page` is below it, so the offer
            // keeps `page` as its own address and matches by main-frame address — a report from any subframe URL
            // raises the bar the same way it does for the one-time code and strong-password bars.
            guard let shown = await VaultPageScripts.showing(page, tab.devTools, sites: items.map(\.sites)) else { return }
            // `dismissedSignInPages` holds the main-frame address `shown` names, so a report from a different subframe
            // of the same page stays dismissed too.
            guard !self.dismissedSignInPages.contains(shown) else { return }
            // Another bar may have taken the page after the browser answered.
            guard self.vaultCodeOffer == nil, self.vaultPasswordOffer == nil, self.walletFillOffer == nil else { return }
            self.vaultSignInOffer = BrowserVaultSignInOffer(origin: frame.origin, page: shown, step: step, items: items)
        }
    }

    /// The person closed the sign-in bar: the same page does not offer it again. A new navigation or a new tab resets
    /// the dismissed list (`releaseVault`, `vaultPageMoved`).
    func dismissSignInOffer() {
        guard let offer = vaultSignInOffer else { return }
        vaultSignInOffer = nil
        dismissedSignInPages.insert(offer.page)
    }

    /// The person chose an item from the sign-in bar: the fill goes through the same path as the key button's list,
    /// so a frame of the item's site (the chain `fillFrames` builds) is filled the same way. Checks the panel's main
    /// frame origin against the offer's origin before anything goes in: if the page moved while the person read the
    /// bar, the click fills nothing. The bar is cleared either way, as a dismissed one.
    func fillFromSignInOffer(_ item: VaultItem) {
        let offer = vaultSignInOffer
        vaultSignInOffer = nil
        let item = vault.items.first { $0.id == item.id } ?? item
        guard let tab, let offer else { return }
        Task { @MainActor [weak self] in
            guard let self, let frame = try? await VaultPageScripts.mainFrame(tab.devTools, timeout: .seconds(10)),
                  self.tab === tab, frame.origin == offer.origin else { return }
            self.fill(item, codeOnly: false)
        }
    }

    // MARK: Addresses and cards (design §18)

    /// An empty field of a card or an address form took the focus: the bar offers the saved ones, once a page.
    private func walletFieldFocused(on tab: BrowserTab, page: String, which: String) {
        guard vault.offersWallet, let which = BrowserWalletFillOffer.Which(rawValue: which), walletFillOffer == nil,
              !dismissedWalletPages.contains(page) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let wallet = await self.vault.loadWallet()
            guard which == .card ? !wallet.cards.isEmpty : !wallet.addresses.isEmpty,
                  await VaultPageScripts.shows(page, tab.devTools), self.tab === tab, self.vault.offersWallet,
                  self.walletFillOffer == nil, !self.dismissedWalletPages.contains(page) else { return }
            self.vaultSignInOffer = nil
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
        Task {
            let wallet = await vault.loadWallet()
            guard self.tab === tab, vault.offersWallet else { return }
            guard var saved = wallet.cards.first(where: { $0.number == card.number }) else {
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
    }

    /// The person sent an address the wallet does not have: the bar offers to save it.
    private func addressSent(_ json: String, on tab: BrowserTab) {
        guard vault.offersWallet, let values = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)),
              let address = VaultAddress(values: values) else { return }
        Task {
            let wallet = await vault.loadWallet()
            guard self.tab === tab, vault.offersWallet, !wallet.addresses.contains(where: { $0.isSame(as: address) }) else { return }
            walletSaveOffer = BrowserWalletSaveOffer(address: address)
        }
    }

    func acceptWalletOffer(_ presented: BrowserWalletSaveOffer? = nil) async {
        guard let offer = walletSaveOffer, presented == nil || presented == offer else { return }
        walletSaveOffer = nil
        do {
            if let card = offer.card { try await vault.saveCard(card) }
            if let address = offer.address { try await vault.saveAddress(address) }
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

    /// Opens the key button's list with an empty search, offering what the page's field takes, as a password manager's
    /// list at a field offers its sign-ins or its codes; `codes` keeps it to two-factor codes (the code bar's "Choose
    /// Another Code…"). A page that does not answer in half a second gets every item.
    func openVaultPicker(codes: Bool = false) {
        vaultPickerQuery = ""
        guard !codes, let tab else {
            vaultPickerKind = codes ? .code : nil
            isVaultPickerShown = true
            return
        }
        Task { @MainActor [weak self] in
            let sites = self?.vaultItemsForPage(tab.currentURL).flatMap(\.sites) ?? []
            let kind = await VaultPageScripts.personFieldKind(tab.devTools, sites: sites, timeout: .milliseconds(500))
            guard let self, self.tab === tab else { return }
            self.vaultPickerKind = kind
            self.isVaultPickerShown = true
        }
    }

    /// The person chose an item from the key button's list: it fills now, whatever the item's agent policy. A code
    /// with no password, and any item chosen from a list of codes, fills the current code into the page's code field,
    /// or is copied when the page has none; any other item fills the sign-in, or the code from a code field.
    func fillForPerson(_ item: VaultItem) {
        // What the item holds as saved now decides what fills.
        let item = vault.items.first { $0.id == item.id } ?? item
        let codes = vaultPickerKind == .code
        vaultPickerKind = nil
        isVaultPickerShown = false
        vaultPickerQuery = ""
        if codes { vaultCodeOffer = nil }
        fill(item, codeOnly: codes || !item.hasPassword && item.hasOneTimeCode)
    }

    func copyPasswordForPerson(_ item: VaultItem) {
        isVaultPickerShown = false
        Task { @MainActor in
            guard let password = await vault.passwordForCopy(of: item.id) else {
                return showVaultNotice(L10n.string("Password was not copied."))
            }
            MacAgentToolService.shared.broker.noteVaultValues([password])
            VaultClipboard.copy(password, to: vaultPasteboard)
            showVaultNotice(L10n.string("Password copied. It will be cleared from the clipboard in 90 seconds."))
        }
    }

    /// Saves the page's site in the item the person filled there from the list (design §16).
    func acceptVaultLinkOffer(_ presented: BrowserVaultLinkOffer? = nil) async {
        guard let offer = vaultLinkOffer, presented == nil || presented == offer else { return }
        vaultLinkOffer = nil
        if await vault.link(offer.item.id, to: offer.site) == nil {
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
            if let site, VaultSite.matches(site, origin: frame.origin) { item = await self.vault.link(item.id, to: site) ?? item }
            // An item for another site asks for Touch ID here before its password goes in.
            guard let grant = await self.vault.valuesForPerson(item, origin: frame.origin, codeOnly: codeOnly) else { return }
            guard self.tab === tab, self.vault.isEnabled else { return }
            let secrets = [grant.password] + (grant.secretFields ?? []).map(\.value)
            MacAgentToolService.shared.broker.noteVaultValues(secrets + [grant.code])
            let guarded = secrets.compactMap { $0 }.filter { $0.count >= VaultScrubList.shortest }
            if !guarded.isEmpty {
                tab.send(.guardFilledValues(tab: tab.id, values: guarded.flatMap(VaultScrubList.spellings(of:))))
            }
            let filled = await VaultPageScripts.fillForPerson(tab.devTools, frame: frame, sites: grant.item.sites,
                                                              codeSites: grant.codeSites, fills: tab.vaultFills,
                                                              username: grant.username, password: grant.password,
                                                              code: grant.code, fields: grant.item.fields,
                                                              secretFields: grant.secretFields, codeOnly: codeOnly)
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
            self.vault.noteUsed(grant.item.id)
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
            // On a setup page the field is for the new code, which saving the setup fills. The field may be in a frame
            // one of the items may fill (design §6.2).
            guard !items.isEmpty, self.tab === tab, self.vaultSetupOffer == nil,
                  let shown = await VaultPageScripts.showing(page, tab.devTools, sites: items.map(\.sites)) else { return }
            self.vaultSignInOffer = nil
            self.vaultCodeOffer = BrowserVaultCodeOffer(
                origin: frame.origin, page: shown, items: items,
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            var new: [OneTimeCodeSetup] = []
            for setup in found.setups where asked || !dismissedSetups.contains(setup.secret.key) {
                if await !vault.holds(setup.secret) { new.append(setup) }
            }
            guard self.tab === tab, vault.isEnabled else { return }
            guard !new.isEmpty else {
                if asked {
                    showVaultNotice(found.setups.isEmpty
                        ? L10n.string("No two-factor QR code is on the screen.")
                        : L10n.string("The two-factor code on the screen is already saved."))
                }
                return
            }
            // The origin comes from the browser, not from the page's script.
            guard let frame = try? await VaultPageScripts.mainFrame(tab.devTools, timeout: .seconds(10)),
                  self.tab === tab, await VaultPageScripts.shows(page, tab.devTools),
                  // The agent's ask about the page's setup holds the bar until the person answers it.
                  tab.vaultSetupAsk.map({ $0.answer != nil }) ?? true else { return }
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

    /// The agent's code fill found a two-factor setup on its page and asks the person to keep it (design §20): the setup
    /// bar, as for one the watch found, while the ask waits; it goes once the ask is answered or ended.
    func showSetupAsk(of tab: BrowserTab) {
        guard let ask = tab.vaultSetupAsk, ask.answer == nil, vault.isAllowedBuild, vault.isEnabled,
              let site = VaultSite.suggestion(for: ask.origin, suffixes: vault.suffixes) else {
            if let offer = vaultSetupOffer, offer.ask != nil, offer.ask != tab.vaultSetupAsk?.id
                || tab.vaultSetupAsk?.answer != nil { vaultSetupOffer = nil }
            return
        }
        guard vaultSetupOffer?.ask != ask.id else { return }
        vaultCodeOffer = nil
        vaultSetupOffer = BrowserVaultSetupOffer(
            origin: ask.origin, site: site, page: tab.currentURL ?? "", setups: [ask.setup], unsupported: 0,
            target: vault.oneTimeCodeTarget(for: ask.setup, origin: ask.origin), choices: vault.items(for: ask.origin),
            ask: ask.id)
    }

    /// Saves the setup bar's code: a site's into its item (the default target unless the person chose
    /// another), then fills its current code if the page asks for one to confirm the setup; an export's as
    /// items of their own. For the agent's ask, the agent fills the code once it reads the answer.
    func acceptSetupOffer(_ presented: BrowserVaultSetupOffer? = nil, into choice: BrowserVaultTarget? = nil) async {
        guard let offer = vaultSetupOffer, presented == nil || presented == offer else { return }
        vaultSetupOffer = nil
        guard let site = offer.site, !offer.isImport else {
            let count = await vault.importOneTimeCodes(offer.setups)
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
        // The agent's ask: its call keeps the code and fills the first one.
        if let ask = offer.ask {
            guard let tab, tab.vaultSetupAsk?.id == ask else { return }
            switch choice {
            case .item(let item): tab.answerSetupAsk(.save(.item(item.id)))
            case .newItem: tab.answerSetupAsk(.save(.newItem))
            case nil: tab.answerSetupAsk(.save(.suggested))
            }
            return
        }
        let sourceTab = tab
        let saved: VaultItem
        do {
            saved = try await vault.saveOneTimeCode(offer.setups[0], site: site, into: target)
        } catch {
            return showVaultNotice(error.localizedDescription)
        }
        showVaultNotice(L10n.format("Saved the two-factor code in “%@”.", saved.name))
        guard let tab = sourceTab, self.tab === tab else { return }
        Task { @MainActor [weak self] in
            // Sites ask for the first code to finish turning two-factor on.
            guard await VaultPageScripts.hasCodeField(tab.devTools), await VaultPageScripts.shows(offer.page, tab.devTools),
                  let self, self.tab === tab, self.vault.isEnabled else { return }
            self.fillCodeForPerson(saved)
        }
    }

    func dismissSetupOffer() {
        guard let offer = vaultSetupOffer else { return }
        vaultSetupOffer = nil
        offer.setups.forEach { dismissedSetups.insert($0.secret.key) }
        if let ask = offer.ask, tab?.vaultSetupAsk?.id == ask { tab?.answerSetupAsk(.declined) }
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
