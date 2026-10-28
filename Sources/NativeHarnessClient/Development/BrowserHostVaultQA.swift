#if DEBUG
import AppKit
import Foundation
import YardletAgentTools

/// QA for the vault for agents against the real browser host (docs/BROWSER_VAULT_DESIGN.md §12 stages
/// 1, 3 and 5), run by `run-check.sh … --ui-fixture-browser-check-only=vault`. The vault is the app's
/// own, in memory for this run (`MacVault`), and holds made-up test sign-ins for the QA server only.
/// Every call goes through the Yardlet MCP broker, as a harness's would. Checks land in `result.json`.
@MainActor
final class BrowserHostVaultQA {
    private let output: URL
    private let base: String
    private let session = UUID()
    /// The task the QA window shows, whose browser panel the person's side is checked in.
    private let panelSession: UUID
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var client: BrowserHostClient { MacBrowserHost.shared.client }
    private var broker: AgentToolBroker { MacAgentToolService.shared.broker }
    private var vault: VaultCenter { MacAgentToolService.shared.vault }
    private var token = ""

    /// Made-up values for the QA server; nothing here signs in anywhere.
    private static let username = "ada@example.test"
    private static let password = "qa-vault-Passw0rd-not-real"

    init(output: URL, base: String, panelSession: UUID) {
        self.output = output
        self.panelSession = panelSession
        // WebAuthn needs a domain for its relying party, so the vault pages load from localhost.
        self.base = base.replacingOccurrences(of: "127.0.0.1", with: "localhost")
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        guard let launch = broker.agentToolServer(for: session, workspaceRoots: []) else {
            check("the broker issues a task its tools", false, "no launch")
            return await finish()
        }
        token = launch.environment[AgentToolEnvironment.token] ?? ""
        let origin = VaultSite.origin(of: base) ?? base
        let item = VaultItem(name: "QA sign-in", sites: [origin], username: Self.username, policy: .always)
        let strict = VaultItem(name: "QA strict", sites: [origin], username: "strict@example.test", policy: .everyTime)
        let codeKey = OneTimeCodeSecret(key: Data("12345678901234567890".utf8))

        let emptyList = await toolNames()
        check("an empty vault offers no fill tool", !emptyList.contains(VaultToolCatalog.fillCredential),
              "\(emptyList.count) tools")
        try? vault.save(item, secret: VaultSecret(password: Self.password, oneTimeCode: codeKey))
        let listed = await toolNames()
        check("a vault with an item offers browser_fill_credential", listed.contains(VaultToolCatalog.fillCredential),
              "\(listed.count) tools")

        await exerciseLogin()
        await exerciseAddresses()
        await exerciseUsernameStep()
        await exerciseControlledFields()
        await exerciseCodes()
        await exerciseReveal()
        await exerciseRefusals(strict: strict)
        await exerciseNewPasswords()
        await exerciseVirtualAuthenticator()
        await exercisePasskeys()
        await exercisePanel()
        record["profileFiles"] = .array(profileFiles().map { .string($0) })
        await finish()
    }

    // MARK: Fills

    /// An agent's new password for a sign-up (design §15): Yardlet makes one within the field's passwordrules,
    /// fills it and its confirmation, saves it as a new item with the form's username, and gives no value back;
    /// a page script cannot read it, and a username already saved for the site is refused.
    private func exerciseNewPasswords() async {
        await navigate("vault/signup")
        let snapshot = await call(AgentToolCatalog.snapshot)
        guard let email = Self.ref(in: snapshot.text, role: "textbox", name: "Email"),
              let field = Self.ref(in: snapshot.text, role: "textbox", name: "Password") else {
            return check("the sign-up page's snapshot names its fields", false, snapshot.text)
        }
        _ = await call(AgentToolCatalog.type, ["ref": .string(email), "text": .string("agent@example.test")])
        let made = await call(VaultToolCatalog.fillCredential, ["ref": .string(field), "kind": .string("new_password"),
                                                                "submit": .bool(true)])
        let value = await pageValue("document.getElementById('pass').value")?.stringValue ?? ""
        let submitted = await pageValue("window.qa.submitted")
        let saved = vault.items.first { $0.username == "agent@example.test" }
        check("an agent's new password meets the field's rules, fills its confirmation and is saved with the form's username, "
                + "and the result has no value",
              !made.isError && !value.isEmpty && !made.text.contains(value) && submitted?["ok"]?.boolValue == true
                && submitted?["user"]?.stringValue == "agent@example.test"
                && saved.flatMap { vault.secret(of: $0.id)?.password } == value,
              made.text)
        let after = await call(AgentToolCatalog.snapshot)
        let read = await call(AgentToolCatalog.evaluate, ["function": .string("() => document.getElementById('pass').value")])
        check("the new password stays out of snapshots and page scripts",
              !value.isEmpty && !after.text.contains(value) && read.isError && !read.text.contains(value), read.text)

        await navigate("vault/signup")
        let again = await call(AgentToolCatalog.snapshot)
        if let email = Self.ref(in: again.text, role: "textbox", name: "Email"),
           let field = Self.ref(in: again.text, role: "textbox", name: "Password") {
            _ = await call(AgentToolCatalog.type, ["ref": .string(email), "text": .string("agent@example.test")])
            let refused = await call(VaultToolCatalog.fillCredential, ["ref": .string(field), "kind": .string("new_password")])
            let untouched = await pageValue("document.getElementById('pass').value") == .string("")
            check("an agent gets no new password for an account already saved", refused.isError && untouched
                    && vault.items.filter { $0.username == "agent@example.test" }.count == 1, refused.text)
        }
    }

    private func exerciseLogin() async {
        await navigate("vault/login")
        let snapshot = await call(AgentToolCatalog.snapshot)
        guard let ref = Self.ref(in: snapshot.text, role: "textbox", name: "Password") else {
            return check("the sign-in page's snapshot names its password field", false, snapshot.text)
        }
        let filled = await call(VaultToolCatalog.fillCredential, ["ref": .string(ref), "submit": .bool(true)])
        check("the fill's result names the item and carries no value",
              !filled.isError && filled.text.contains("QA sign-in") && !filled.text.contains(Self.password), filled.text)
        let submitted = await pageValue("window.qa.submitted")
        check("the page received the username and password and its form submitted",
              submitted?["user"]?.stringValue == Self.username && submitted?["pass"]?.stringValue == Self.password
                && submitted?["note"]?.stringValue == "",
              "user \(submitted?["user"]?.stringValue ?? "nil"), password matches \(submitted?["pass"]?.stringValue == Self.password)")
        let inputs = await pageValue("window.qa.inputs")
        check("the page's input listeners heard the fill", (inputs?["user"]?.integerValue ?? 0) > 0
              && (inputs?["pass"]?.integerValue ?? 0) > 0, "\(String(describing: inputs))")

        let raw = await accessibilityValue(ofPasswordFieldIn: "vault/login")
        record["passwordFieldAccessibilityValue"] = .string(raw.map { $0.allSatisfy { $0 == "•" || $0 == "●" }
            ? "\($0.count) bullets" : ($0 == Self.password ? "the password itself" : "other: \($0.count) characters") } ?? "none")
        let after = await call(AgentToolCatalog.snapshot)
        check("a snapshot after the fill shows the password field as <redacted> and no value",
              after.text.contains("<redacted>") && !after.text.contains(Self.password), String(after.text.prefix(600)))

        let paused = await call(AgentToolCatalog.evaluate, ["function": .string("() => document.title")])
        check("browser_evaluate waits while a filled value is on the page", paused.isError && paused.text.contains("password or code"), paused.text)
        await exerciseLinkedPopup()
        _ = await pageValue("(() => { document.getElementById('pass').value = ''; document.getElementById('user').value = ''; return true })()")
        let emptied = await call(AgentToolCatalog.evaluate, ["function": .string("() => document.title")])
        await navigate("vault/login")
        let reloaded = await call(AgentToolCatalog.evaluate, ["function": .string("() => document.title")])
        check("browser_evaluate stays refused once the filled fields are empty, and runs again after a reload",
              emptied.isError && !reloaded.isError, emptied.text + " / " + reloaded.text)
        // The agent's own script ran on the page: an "always" item's fill asks the person first (the QA answers no).
        let again = await call(AgentToolCatalog.snapshot)
        let field = Self.ref(in: again.text, role: "textbox", name: "Password") ?? "@e1"
        let asked = await call(VaultToolCatalog.fillCredential, ["ref": .string(field)])
        let left = await pageValue("document.getElementById('pass').value")
        check("a fill on a page where the agent ran its own script asks the person first and fills nothing without them",
              asked.isError && asked.text.contains("ran your own scripts") && left == .string(""), asked.text)
    }

    /// A same-site window the filled page opens keeps `window.opener`, through which a script could read the filled
    /// field: the agent's scripts do not run there either while the filled page is shown.
    private func exerciseLinkedPopup() async {
        guard let opener = client.tab(forSession: session) else { return check("linked popup: the task's tab", false, "no tab") }
        _ = try? await opener.devTools.send("Runtime.evaluate", [
            "expression": .string("window.open('/vault/step', 'qa-popup'); true"), "userGesture": .bool(true),
            "returnByValue": .bool(true)
        ], timeout: .seconds(10))
        let opened = await waitUntilAsync(.seconds(10)) {
            self.client.tabs(forSession: self.session).contains { $0 !== opener && $0.currentURL?.contains("vault/step") == true }
        }
        guard opened, let popup = client.tabs(forSession: session).first(where: { $0 !== opener }) else {
            return check("linked popup: the page's window opens as a tab of the task", false,
                         "\(client.tabs(forSession: session).map { $0.currentURL ?? "-" })")
        }
        _ = await waitUntilAsync(.seconds(10)) { !popup.isLoading }
        let reached = await call(AgentToolCatalog.evaluate, [
            "tabId": .string(String(popup.id)),
            "function": .string("() => document.title")
        ])
        check("a window the filled page opened runs no agent script while the filled page is shown",
              reached.isError && reached.text.contains("linked"), reached.text)
        _ = await call(AgentToolCatalog.tabClose, ["tabId": .string(String(popup.id))])
        _ = await call(AgentToolCatalog.tabSelect, ["tabId": .string(String(opener.id))])
    }

    /// How many requests reached the QA server's landing page (`/vault/landed`) so far, as the server says over
    /// loopback (`/qa/landed`): none may come from a refused sign-in. -1 when it does not answer.
    private func landedRequests() async -> Int {
        guard let url = URL(string: base + "qa/landed"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return -1 }
        return Int(String(decoding: data, as: UTF8.self)) ?? -1
    }

    /// A filled password stays out of addresses and other sites (docs/BROWSER_VAULT_DESIGN.md, "Filled values and
    /// addresses"), on the real host: a form sent by GET is filled but not submitted; its button, a script that builds
    /// such an address and one that puts it inside another's query are each refused before the request leaves, so the
    /// server never hears of them, and the next result says so; no result and nothing the tab remembers carries the
    /// password. A form that posts to the other site is not filled. A navigation without the password still goes.
    private func exerciseAddresses() async {
        await navigate("vault/get")
        var texts: [String] = []
        let snapshot = await call(AgentToolCatalog.snapshot)
        guard let field = Self.ref(in: snapshot.text, role: "textbox", name: "Password") else {
            return check("addresses: the GET sign-in's snapshot names its password field", false, snapshot.text)
        }
        let filled = await call(VaultToolCatalog.fillCredential, ["ref": .string(field), "submit": .bool(true)])
        texts.append(filled.text)
        let held = await pageValue("document.getElementById('pass').value")
        check("addresses: a form sent by GET is filled but not submitted",
              !filled.isError && filled.text.contains("did not submit it") && held == .string(Self.password), filled.text)
        for (button, name) in [("Sign in", "its sign-in button"), ("Script sign-in", "a script that builds the address"),
                               ("Nested sign-in", "an address inside another's query")] {
            let current = await call(AgentToolCatalog.snapshot)
            guard let ref = Self.ref(in: current.text, role: "button", name: button) else {
                check("addresses: \(name) is on the page", false, current.text)
                continue
            }
            let clicked = await call(AgentToolCatalog.click, ["ref": .string(ref)])
            try? await Task.sleep(for: .seconds(1))
            let after = await call(AgentToolCatalog.snapshot)
            texts += [clicked.text, after.text]
            let path = await pageValue("location.pathname")
            let landed = await landedRequests()
            check("addresses: \(name) is refused before it is sent, and the next result says so",
                  landed == 0 && path == .string("/vault/get")
                    && (clicked.text + after.text).contains("tried to go to an address carrying the password"),
                  "landed \(landed), at \(path?.stringValue ?? "nil"): \(String((clicked.text + after.text).suffix(400)))")
        }
        let remembered = client.tab(forSession: session)?.lastPageURL ?? ""
        check("addresses: no result and nothing the tab remembers carries the password",
              !texts.joined().contains(Self.password) && !remembered.contains(Self.password), remembered)

        await navigate("vault/elsewhere")
        let elsewhere = await call(AgentToolCatalog.snapshot)
        if let ref = Self.ref(in: elsewhere.text, role: "textbox", name: "Password") {
            let refused = await call(VaultToolCatalog.fillCredential, ["ref": .string(ref)])
            let empty = await pageValue("document.getElementById('pass').value")
            check("addresses: a form that posts to another site is not filled",
                  refused.isError && refused.text.contains("not one of the item's sites") && empty == .string(""), refused.text)
        } else {
            check("addresses: the other-site sign-in's snapshot names its password field", false, elsewhere.text)
        }

        await navigate("vault/landed?after=refusals")
        let arrived = await landedRequests()
        check("addresses: a navigation without the password still goes", arrived == 1, "landed \(arrived)")
    }

    /// A sign-in's first step asks for the email alone: the username is no secret, so the agent's
    /// scripts keep running on the page.
    private func exerciseUsernameStep() async {
        await navigate("vault/step")
        let snapshot = await call(AgentToolCatalog.snapshot)
        guard let ref = Self.ref(in: snapshot.text, role: "textbox", name: "Email") else {
            return check("the first step's snapshot names its email field", false, snapshot.text)
        }
        let filled = await call(VaultToolCatalog.fillCredential, ["ref": .string(ref), "submit": .bool(true)])
        let submitted = await pageValue("window.qa.submitted")
        let evaluated = await call(AgentToolCatalog.evaluate, ["function": .string("() => document.title")])
        check("a first step takes the username alone and leaves browser_evaluate running",
              !filled.isError && filled.text.contains("the username of") && submitted == .string(Self.username) && !evaluated.isError,
              filled.text + " / " + evaluated.text)
    }

    private func exerciseControlledFields() async {
        await navigate("vault/react")
        let snapshot = await call(AgentToolCatalog.snapshot)
        guard let ref = Self.ref(in: snapshot.text, role: "textbox", name: nil) else {
            return check("the controlled page's snapshot has a field", false, snapshot.text)
        }
        // Its form has no method: the fill leaves it unsent and the agent clicks the page's button, as the result says.
        let filled = await call(VaultToolCatalog.fillCredential, ["ref": .string(ref), "submit": .bool(true)])
        if let button = Self.ref(in: (await call(AgentToolCatalog.snapshot)).text, role: "button", name: "Sign in") {
            _ = await call(AgentToolCatalog.click, ["ref": .string(button)])
        }
        _ = await waitUntilAsync(.seconds(3)) { await self.pageValue("window.qa.submitted") != .null }
        let submitted = await pageValue("window.qa.submitted")
        check("fields kept the way React keeps them take the fill into their state",
              !filled.isError && submitted?["user"]?.stringValue == Self.username && submitted?["pass"]?.stringValue == Self.password,
              filled.text + " user \(submitted?["user"]?.stringValue ?? "nil")")
    }

    private func exerciseCodes() async {
        await navigate("vault/otp")
        let snapshot = await call(AgentToolCatalog.snapshot)
        let refs = Self.refs(in: snapshot.text, role: "textbox")
        guard refs.count >= 7 else { return check("the code page's snapshot has its fields", false, snapshot.text) }
        let one = await call(VaultToolCatalog.fillCredential, ["ref": .string(refs[0]), "kind": .string("one_time_code"),
                                                              "submit": .bool(true)])
        _ = await waitUntilAsync(.seconds(3)) { await self.pageValue("window.qa.one") != .null }
        let oneOK = await pageValue("window.qa.one")
        check("a one-time code field gets the current RFC 6238 code", !one.isError && oneOK == .bool(true), one.text)
        let boxes = await call(VaultToolCatalog.fillCredential, ["ref": .string(refs[1]), "kind": .string("one_time_code"),
                                                                "submit": .bool(true)])
        _ = await waitUntilAsync(.seconds(3)) { await self.pageValue("window.qa.boxes") != .null }
        let boxesOK = await pageValue("window.qa.boxes")
        check("six one-digit boxes get the code a digit each", !boxes.isError && boxesOK == .bool(true), boxes.text)
        let read = await call(AgentToolCatalog.snapshot)
        let shown = read.text.split(separator: "\n").filter { $0.contains("textbox") && $0.range(of: #": "\d""#, options: .regularExpression) != nil }
        check("a snapshot of the filled code page leaves out the code field and each box",
              !read.isError && shown.isEmpty && read.text.components(separatedBy: "\"<redacted>\"").count - 1 >= 7,
              shown.joined(separator: " | ") + " / " + String(read.text.prefix(600)))
    }

    private func exerciseReveal() async {
        await navigate("vault/reveal")
        let snapshot = await call(AgentToolCatalog.snapshot)
        guard let ref = Self.ref(in: snapshot.text, role: "textbox", name: nil) else {
            return check("the reveal page's snapshot has a field", false, snapshot.text)
        }
        _ = await call(VaultToolCatalog.fillCredential, ["ref": .string(ref)])
        _ = await pageValue("(() => { document.getElementById('show').click(); return document.getElementById('pass').type })()")
        let shot = await call(AgentToolCatalog.screenshot)
        await navigate("vault/reveal")
        let reloaded = await call(AgentToolCatalog.screenshot)
        if case .image(let data, _)? = reloaded.content.first, let png = Data(base64Encoded: data) {
            try? png.write(to: output.appending(path: "vault-reveal-screenshot.png"))
        }
        check("a screenshot of a filled page is refused, however it shows the value, and works again after a reload",
              shot.isError && shot.content.allSatisfy { if case .image = $0 { false } else { true } } && !reloaded.isError,
              shot.text + " / " + reloaded.text)
        await navigate("vault/reveal")
        if let again = Self.ref(in: await call(AgentToolCatalog.snapshot).text, role: "textbox", name: nil) {
            _ = await call(VaultToolCatalog.fillCredential, ["ref": .string(again)])
            _ = await pageValue("(() => { document.getElementById('show').click(); return true })()")
        }
        // The person's own capture of the panel for comparison: the page shows the password in the panel.
        let plain = try? await client.tab(forSession: session)?.devTools.send("Page.captureScreenshot",
                                                                               ["format": .string("png")], timeout: .seconds(10))
        if let data = plain?["data"]?.stringValue, let png = Data(base64Encoded: data) {
            try? png.write(to: output.appending(path: "vault-reveal-panel.png"))
        }
    }

    private func exerciseRefusals(strict: VaultItem) async {
        // Another host serving the same page: not a site the item is for.
        await navigate("vault/login", host: "127.0.0.1")
        let snapshot = await call(AgentToolCatalog.snapshot)
        let ref = Self.ref(in: snapshot.text, role: "textbox", name: "Password") ?? "@e1"
        let named = await call(VaultToolCatalog.fillCredential, ["ref": .string(ref), "item": .string("QA sign-in")])
        let leftEmpty = await pageValue("document.getElementById('pass').value")
        check("an item named on another site is refused and nothing is filled",
              named.isError && named.text.contains("not saved for") && leftEmpty == .string(""), named.text)

        try? vault.save(strict, secret: VaultSecret(password: "qa-strict-not-real"))
        await navigate("vault/login")
        let again = await call(AgentToolCatalog.snapshot)
        let strictRef = Self.ref(in: again.text, role: "textbox", name: "Password") ?? "@e1"
        let unconfirmed = await call(VaultToolCatalog.fillCredential, ["ref": .string(strictRef), "item": .string("QA strict")])
        check("an every-time item that the person does not confirm is not filled",
              unconfirmed.isError && unconfirmed.text.contains("did not confirm"), unconfirmed.text)
        let unnamed = await call(VaultToolCatalog.fillCredential, ["ref": .string(strictRef)])
        check("two items for a site need the agent to name one", unnamed.isError && unnamed.text.contains("Name one"), unnamed.text)

        vault.isEnabled = false
        let off = await call(VaultToolCatalog.fillCredential, ["ref": .string(strictRef), "item": .string("QA sign-in")])
        let offList = await toolNames()
        check("turning the vault off refuses fills and takes the tool from the list",
              off.isError && !offList.contains(VaultToolCatalog.fillCredential), off.text)
        vault.isEnabled = true
        try? vault.delete(strict.id)
    }

    // MARK: Stage 1: CDP's virtual authenticator in this CEF

    private func exerciseVirtualAuthenticator() async {
        await navigate("vault/webauthn")
        guard let devTools = client.tab(forSession: session)?.devTools else {
            return check("CDP WebAuthn: the task's tab", false, "no tab")
        }
        var detail: [String: JSONValue] = [:]
        func send(_ method: String, _ params: [String: JSONValue] = [:]) async -> (JSONValue?, String?) {
            do {
                return (try await devTools.send(method, params, timeout: .seconds(20)), nil)
            } catch {
                return (nil, "\(error)")
            }
        }
        let options: JSONValue = .object([
            "protocol": .string("ctap2"), "ctap2Version": .string("ctap2_1"), "transport": .string("internal"),
            "hasResidentKey": .bool(true), "hasUserVerification": .bool(true), "isUserVerified": .bool(true),
            "automaticPresenceSimulation": .bool(true)
        ])
        let (_, enableError) = await send("WebAuthn.enable", ["enableUI": .bool(false)])
        let (added, addError) = await send("WebAuthn.addVirtualAuthenticator", ["options": options])
        detail["enable"] = .string(enableError ?? "ok")
        detail["addVirtualAuthenticator"] = .string(addError ?? "ok")
        guard let authenticator = added?["authenticatorId"]?.stringValue else {
            record["virtualAuthenticator"] = .object(detail)
            return check("CDP WebAuthn: CEF 154 has the virtual authenticator", false, "\(addError ?? "no id")")
        }
        let mark = devTools.events.count
        let created = await pageValue("""
            navigator.credentials.create({publicKey: {challenge: new Uint8Array(32), rp: {id: 'localhost', name: 'QA'},
              user: {id: new Uint8Array([1, 2, 3, 4]), name: 'qa', displayName: 'QA'},
              pubKeyCredParams: [{type: 'public-key', alg: -7}],
              authenticatorSelection: {residentKey: 'required', userVerification: 'required'}}})
              .then(c => ({ok: true, id: c.id, attachment: c.authenticatorAttachment})).catch(e => ({ok: false, error: String(e)}))
            """, awaitPromise: true)
        let addedEvent = devTools.events[mark...].contains { $0.method == "WebAuthn.credentialAdded" }
        let (listed, _) = await send("WebAuthn.getCredentials", ["authenticatorId": .string(authenticator)])
        let credential = listed?["credentials"]?.arrayValue?.first
        detail["create"] = created ?? .null
        detail["credentialAddedEvent"] = .bool(addedEvent)
        detail["privateKeyPresent"] = .bool((credential?["privateKey"]?.stringValue?.isEmpty == false))
        detail["rpId"] = credential?["rpId"] ?? .null
        _ = await send("WebAuthn.removeVirtualAuthenticator", ["authenticatorId": .string(authenticator)])

        var asserted = false
        var signedIn: JSONValue?
        if let credential {
            let (second, _) = await send("WebAuthn.addVirtualAuthenticator", ["options": options])
            if let id = second?["authenticatorId"]?.stringValue {
                let (_, putError) = await send("WebAuthn.addCredential", ["authenticatorId": .string(id), "credential": credential])
                detail["addCredential"] = .string(putError ?? "ok")
                let assertMark = devTools.events.count
                signedIn = await pageValue("""
                    navigator.credentials.get({publicKey: {challenge: new Uint8Array(32), rpId: 'localhost', userVerification: 'required'}})
                      .then(c => ({ok: true, id: c.id})).catch(e => ({ok: false, error: String(e)}))
                    """, awaitPromise: true)
                asserted = devTools.events[assertMark...].contains { $0.method == "WebAuthn.credentialAsserted" }
                _ = await send("WebAuthn.removeVirtualAuthenticator", ["authenticatorId": .string(id)])
            }
        }
        _ = await send("WebAuthn.disable")
        detail["get"] = signedIn ?? .null
        detail["credentialAssertedEvent"] = .bool(asserted)
        record["virtualAuthenticator"] = .object(detail)
        check("CDP WebAuthn: a virtual authenticator registers a passkey and hands over its private key",
              created?["ok"]?.boolValue == true && detail["privateKeyPresent"] == .bool(true) && addedEvent,
              "create \(String(describing: created)), event \(addedEvent)")
        check("CDP WebAuthn: the saved credential put into a new authenticator signs in",
              signedIn?["ok"]?.boolValue == true && asserted, "get \(String(describing: signedIn)), event \(asserted)")
    }

    // MARK: Stage 5: Yardlet's passkeys

    /// The person makes a Yardlet passkey on the page (the right-click item's work), then the agent signs
    /// in with it without a dialog; the authenticator answers once and goes, and another site gets nothing.
    private func exercisePasskeys() async {
        await navigate("vault/webauthn")
        guard let tab = client.tab(forSession: session) else { return check("passkeys: the task's tab", false, "no tab") }
        let address = base + "vault/webauthn"
        async let enrolled = VaultPasskeyEnrollment.enroll(on: tab.devTools, pageAddress: address, vault: vault)
        try? await Task.sleep(for: .seconds(1))
        let created = await pageValue(Self.createPasskey, awaitPromise: true)
        let outcome = await enrolled
        let item = vault.items.first { $0.hasPasskey }
        check("the person's passkey registration goes into the vault", created?["ok"]?.boolValue == true
              && outcome == .saved(itemName: "QA sign-in") && item != nil, "create \(String(describing: created)), \(outcome)")
        guard let item else { return }
        let countBefore = vault.secret(of: item.id)?.passkey?.signCount ?? -1

        let armed = await call(VaultToolCatalog.fillCredential, ["kind": .string("passkey")])
        let signedIn = await pageValue(Self.getPasskey(abortAfter: 10_000), awaitPromise: true)
        _ = await waitUntilAsync(.seconds(3)) { tab.devTools.events.contains { $0.method == "WebAuthn.credentialAsserted" } }
        try? await Task.sleep(for: .seconds(1))
        let countAfter = vault.secret(of: item.id)?.passkey?.signCount ?? -1
        check("the agent's passkey signs in without a dialog and the key is not in the result",
              !armed.isError && signedIn?["ok"]?.boolValue == true && !armed.text.contains(vault.secret(of: item.id)?.passkey?.privateKey ?? "-"),
              armed.text + " / \(String(describing: signedIn))")
        check("the signature count is kept after the sign-in", countAfter > countBefore, "\(countBefore) → \(countAfter)")
        let again = await pageValue(Self.getPasskey(abortAfter: 2_000), awaitPromise: true)
        check("the authenticator answered once and is gone", again?["ok"]?.boolValue == false, "\(String(describing: again))")
        _ = await call(AgentToolCatalog.handleDialog, ["accept": .bool(false)])

        await navigate("vault/webauthn", host: "127.0.0.1")
        let elsewhere = await call(VaultToolCatalog.fillCredential, ["kind": .string("passkey"), "item": .string(item.name)])
        check("a passkey is not armed on another site", elsewhere.isError, elsewhere.text)
    }

    private static let createPasskey = """
        navigator.credentials.create({publicKey: {challenge: new Uint8Array(32), rp: {id: 'localhost', name: 'QA'},
          user: {id: new Uint8Array([9, 8, 7, 6]), name: 'ada@example.test', displayName: 'Ada'},
          pubKeyCredParams: [{type: 'public-key', alg: -7}],
          authenticatorSelection: {residentKey: 'required', userVerification: 'required'}}})
          .then(c => ({ok: true, id: c.id})).catch(e => ({ok: false, error: String(e)}))
        """

    private static func getPasskey(abortAfter milliseconds: Int) -> String {
        """
        (() => { const stop = new AbortController(); setTimeout(() => stop.abort(), \(milliseconds));
          return navigator.credentials.get({signal: stop.signal, publicKey: {challenge: new Uint8Array(32), rpId: 'localhost',
            userVerification: 'required'}}).then(c => ({ok: true, id: c.id})).catch(e => ({ok: false, error: String(e)})); })()
        """
    }

    // MARK: Stage 4: the person's side in the panel

    /// In the task's panel: the person signs in (typed, trusted input) and the save bar offers the password;
    /// saving makes an item; the key button's fill puts it back; the page's menu has the vault's two items;
    /// an agent's fill shows "Passwords" in the header. Each state is drawn to a PNG.
    private func exercisePanel() async {
        let previous = BrowserHostPaneController.current
        NotificationCenter.default.post(name: BrowserHostQAFixture.openBrowserPanel, object: nil)
        guard await waitUntilAsync(.seconds(10), { BrowserHostPaneController.current !== previous
                && BrowserHostPaneController.current?.view != nil }),
              let controller = BrowserHostPaneController.current else {
            return check("panel: the task's browser panel opens", false, "no panel")
        }
        controller.addressInput = base + "vault/login"
        controller.submitAddress()
        guard await waitUntilAsync(.seconds(20), {
            controller.tab?.currentURL?.contains("vault/login") == true && controller.tab?.isLoading == false
        }), let tab = controller.tab else { return check("panel: the sign-in page loads", false, "not loaded") }
        try? await Task.sleep(for: .seconds(1))
        func page(_ expression: String) async -> JSONValue? {
            let result = try? await tab.devTools.send("Runtime.evaluate", ["expression": .string(expression), "returnByValue": .bool(true)],
                                                      timeout: .seconds(10))
            return result?["result"]?["value"]
        }
        // The person types: trusted text input, as the panel's keyboard gives the page.
        for (field, text) in [("user", "person@example.test"), ("pass", "person-typed-not-real")] {
            _ = await page("document.getElementById('\(field)').focus()")
            _ = try? await tab.devTools.send("Input.insertText", ["text": .string(text)], timeout: .seconds(10))
        }
        _ = await page("document.getElementById('go').click()")
        let offered = await waitUntilAsync(.seconds(5)) { controller.vaultOffer != nil }
        capture(controller, named: "vault-panel-offer.png")
        check("panel: signing in offers to save the typed password",
              offered && controller.vaultOffer?.username == "person@example.test" && controller.vaultOffer?.updates == nil,
              "offer \(controller.vaultOffer.map { "\($0.username) on \($0.site)" } ?? "none")")
        controller.acceptVaultOffer()
        let saved = vault.items.first { $0.username == "person@example.test" }
        check("panel: Save makes an item for the site", saved != nil && saved?.policy == .always,
              saved.map { "\($0.name): \($0.sites)" } ?? "none")

        _ = await page("(() => { user.value = ''; pass.value = ''; return true })()")
        try? await Task.sleep(for: .milliseconds(500))
        capture(controller, named: "vault-panel-key.png")
        if let saved { controller.fillForPerson(saved) }
        let refilled = await waitUntilAsync(.seconds(5)) {
            await page("document.getElementById('pass').value") == .string("person-typed-not-real")
        }
        check("panel: the key button's fill puts the saved sign-in into the form", refilled,
              "\(String(describing: await page("document.getElementById('user').value")))")
        // The person's fill closes the page to the agent's scripts, as an agent's fill does.
        if let launch = broker.agentToolServer(for: panelSession, workspaceRoots: []),
           let panelToken = launch.environment[AgentToolEnvironment.token] {
            let evaluated = await broker.handle(AgentToolCall(
                token: panelToken, session: panelSession.uuidString, tool: AgentToolCatalog.evaluate,
                arguments: .object(["function": .string("() => document.title")])))
            check("panel: after the key button's fill the agent's scripts do not run on the page",
                  evaluated.isError && evaluated.text.contains("password or code"), evaluated.text)
        }

        // The strong password item shows only while a password field has the focus.
        let menuItems = (controller.view?.extraContextMenuItems?() ?? []).filter { $0.title != L10n.string("Use Strong Password") }
        // The vault's three, then the browser's own import of another browser's sign-ins.
        check("panel: the page's menu has the vault's three items", menuItems.count == 4
                && menuItems[2].title == L10n.string("Add Two-Factor Code from QR Code")
                && menuItems[3].title == L10n.string("Import Sign-ins from Another Browser…"),
              menuItems.map(\.title).joined(separator: ", "))
        menuItems.first?.action()
        let drafted = await waitUntilAsync(.seconds(5)) { controller.vaultDraft != nil }
        try? await Task.sleep(for: .seconds(1))
        if let sheet = controller.view?.window?.attachedSheet, let content = sheet.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appending(path: "vault-panel-add-sheet.png"))
        }
        check("panel: Add to Password Manager opens the item sheet with the site and the typed username",
              drafted && controller.vaultDraft?.username == "person@example.test"
                && controller.vaultDraft?.sites == [VaultSite.origin(of: base) ?? ""] && controller.view?.window?.attachedSheet != nil,
              "\(String(describing: controller.vaultDraft)), sheet \(controller.view?.window?.attachedSheet != nil)")
        controller.vaultDraft = nil
        try? await Task.sleep(for: .milliseconds(500))

        NotificationCenter.default.post(name: .vaultFilled, object: nil, userInfo: [VaultFillNotice.tabKey: tab.id])
        try? await Task.sleep(for: .milliseconds(300))
        capture(controller, named: "vault-panel-header.png")
        check("panel: an agent's fill shows Passwords in the header", controller.isVaultFilling, "\(controller.isVaultFilling)")

        await exercisePanelAddress(controller, item: saved)
        await exercisePanelCodes(controller)
        await exercisePanelPasswords(controller)
    }

    /// The person's key-button fill holds the page's addresses too: a GET form's submission is refused before it is
    /// sent, the panel says so over the page, and the tab remembers the page before it.
    private func exercisePanelAddress(_ controller: BrowserHostPaneController, item: VaultItem?) async {
        guard let item else { return check("panel: an item to fill the GET sign-in with", false, "none") }
        controller.addressInput = base + "vault/get"
        controller.submitAddress()
        guard await waitUntilAsync(.seconds(20), {
            controller.tab?.currentURL?.contains("vault/get") == true && controller.tab?.isLoading == false
        }), let tab = controller.tab else { return check("panel: the GET sign-in loads", false, "not loaded") }
        func page(_ expression: String) async -> JSONValue? {
            let result = try? await tab.devTools.send("Runtime.evaluate", ["expression": .string(expression), "returnByValue": .bool(true)],
                                                      timeout: .seconds(10))
            return result?["result"]?["value"]
        }
        let before = await landedRequests()
        _ = await page("document.getElementById('pass').focus()")
        controller.fillForPerson(item)
        _ = await waitUntilAsync(.seconds(5)) { await page("document.getElementById('pass').value") != .string("") }
        _ = await page("document.getElementById('go').click()")
        let told = await waitUntilAsync(.seconds(5)) { controller.notice != nil }
        try? await Task.sleep(for: .milliseconds(300))
        capture(controller, named: "vault-panel-address-blocked.png")
        let landed = await landedRequests()
        check("panel: the person's fill holds the GET sign-in's address, and the panel says so",
              told && controller.notice == L10n.string("The page tried to put the filled password in its address. Yardlet stopped it, so the page did not move.")
                && landed == before && tab.lastPageURL?.contains("vault/get") == true,
              "notice \(controller.notice ?? "none"); landed \(landed - before); at \(tab.lastPageURL ?? "nil")")
    }

    /// The person's two-factor codes in the panel (design §14): a code field on a site whose item has a
    /// code offers the code bar, whose fill (and the key button's, into one-digit boxes) passes the page's
    /// check; a site's setup QR code offers its code for the site's item of that account, and saving it
    /// fills the first code the page asks for; an authenticator app's export QR code offers its accounts,
    /// again from the page's menu, and imports each as an item of its own. Values are the QA server's.
    private func exercisePanelCodes(_ controller: BrowserHostPaneController) async {
        func open(_ path: String) async -> BrowserTab? {
            controller.addressInput = base + path
            controller.submitAddress()
            guard await waitUntilAsync(.seconds(20), {
                controller.tab?.currentURL?.hasSuffix(path) == true && controller.tab?.isLoading == false
            }), let tab = controller.tab else {
                check("panel: \(path) loads", false, controller.tab?.currentURL ?? "no tab")
                return nil
            }
            return tab
        }
        func page(_ tab: BrowserTab, _ expression: String) async -> JSONValue? {
            let result = try? await tab.devTools.send("Runtime.evaluate", ["expression": .string(expression), "returnByValue": .bool(true)],
                                                      timeout: .seconds(10))
            return result?["result"]?["value"]
        }

        guard let codes = await open("vault/otp") else { return }
        let offered = await waitUntilAsync(.seconds(6)) { controller.vaultCodeOffer != nil }
        capture(controller, named: "vault-panel-code-bar.png")
        check("panel: a code field on a site whose item has a code offers the code bar",
              offered && controller.vaultCodeOffer?.items.map(\.name) == ["QA sign-in"],
              controller.vaultCodeOffer.map { $0.items.map(\.name).joined(separator: ", ") } ?? "no offer")
        if let item = controller.vaultCodeOffer?.items.first { controller.fillCodeForPerson(item) }
        let filled = await waitUntilAsync(.seconds(5)) { await page(codes, "document.getElementById('code').value.length")?.integerValue == 6 }
        _ = await page(codes, "document.querySelector('#one button').click()")
        let one = await waitUntilAsync(.seconds(3)) { await page(codes, "window.qa.one") == .bool(true) }
        check("panel: the code bar fills the current code and the page takes it", filled && one && controller.vaultCodeOffer == nil,
              "filled \(filled), checked \(one)")

        _ = await page(codes, "document.getElementById('d0').focus()")
        if let item = vault.items.first(where: { $0.name == "QA sign-in" }) { controller.fillForPerson(item) }
        let boxes = await waitUntilAsync(.seconds(5)) { await page(codes, "document.getElementById('d5').value") != .string("") }
        _ = await page(codes, "document.querySelector('#boxes button').click()")
        let boxesOK = await waitUntilAsync(.seconds(3)) { await page(codes, "window.qa.boxes") == .bool(true) }
        check("panel: the key button in one-digit boxes fills the code a digit each", boxes && boxesOK,
              "filled \(boxes), checked \(boxesOK)")

        guard let setup = await open("vault/otp/setup") else { return }
        let person = vault.items.first { $0.username == "person@example.test" }
        let setupOffered = await waitUntilAsync(.seconds(8)) { controller.vaultSetupOffer != nil }
        capture(controller, named: "vault-panel-setup-bar.png")
        let setupOffer = controller.vaultSetupOffer
        check("panel: a setup QR code on the page offers its code for the site's item of that account, without the code bar",
              setupOffered && setupOffer?.setups.first?.account == "person@example.test" && setupOffer?.target?.id == person?.id
                && setupOffer?.isImport == false && controller.vaultCodeOffer == nil,
              setupOffer.map { "\($0.setups.map(\.account)) → \($0.target?.name ?? "new")" } ?? "no offer")
        controller.acceptSetupOffer()
        let confirmFilled = await waitUntilAsync(.seconds(6)) {
            await page(setup, "document.getElementById('code').value.length")?.integerValue == 6
        }
        _ = await page(setup, "document.querySelector('#confirm button').click()")
        let confirmed = await waitUntilAsync(.seconds(3)) { await page(setup, "window.qa.confirmed") == .bool(true) }
        let saved = vault.items.first { $0.id == person?.id }
        check("panel: saving it keeps the code in that item and fills the first code the page asks for",
              saved?.hasOneTimeCode == true && confirmFilled && confirmed,
              "saved \(saved?.hasOneTimeCode == true), filled \(confirmFilled), checked \(confirmed)")

        guard await open("vault/otp/export") != nil else { return }
        let exportOffered = await waitUntilAsync(.seconds(8)) { controller.vaultSetupOffer != nil }
        capture(controller, named: "vault-panel-import-bar.png")
        let exportOffer = controller.vaultSetupOffer
        check("panel: an authenticator export's QR code offers its time-based accounts and counts the rest",
              exportOffered && exportOffer?.isImport == true && exportOffer?.setups.map(\.itemName) == ["QA Export", "QA Second"]
                && exportOffer?.unsupported == 1,
              exportOffer.map { "\($0.setups.map(\.itemName)), \($0.unsupported) left out" } ?? "no offer")
        controller.dismissSetupOffer()
        let menu = controller.view?.extraContextMenuItems?() ?? []
        menu.first { $0.title == L10n.string("Add Two-Factor Code from QR Code") }?.action()
        let again = await waitUntilAsync(.seconds(8)) { controller.vaultSetupOffer != nil }
        controller.acceptSetupOffer()
        let imported = vault.items.filter { $0.sites.isEmpty && $0.hasOneTimeCode }
        let second = imported.first { $0.name == "QA Second" }.flatMap { vault.secret(of: $0.id)?.oneTimeCode }
        check("panel: the page menu's QR item reads it again and imports each account as an item of its own",
              again && imported.map(\.username).sorted() == ["export-one@example.test", "export-two@example.test"]
                && imported.allSatisfy { !$0.hasPassword } && second?.algorithm == .sha256 && second?.digits == 8
                && second?.key == Data("qa-export-key-two!!!".utf8),
              imported.map { "\($0.name): \($0.username)" }.joined(separator: ", "))

        await exerciseUnlinkedCode(controller, page: page)
    }

    /// A code brought over with no site (design §14.3) on a page of the site its name names: the code bar
    /// offers it with the site it will keep, and filling it saves that site. The QA server's code page is
    /// served at an https address under the reserved `.test` name through CDP request interception, so
    /// the page has a registrable domain and nothing leaves the Mac.
    private func exerciseUnlinkedCode(_ controller: BrowserHostPaneController,
                                      page: @escaping (BrowserTab, String) async -> JSONValue?) async {
        guard let tab = controller.tab else { return check("panel: a tab for the code with no site", false, "no tab") }
        let host = "https://accounts.qa-vendor.test/"
        let vendor = VaultItem(name: "QA Vendor", sites: [], username: "vendor@example.test")
        try? vault.save(vendor, secret: VaultSecret(oneTimeCode: OneTimeCodeSecret(key: Data("12345678901234567890".utf8))))
        let base = base
        let served = tab.devTools.observeEvents { method, params in
            guard method == "Fetch.requestPaused", let id = params["requestId"]?.stringValue,
                  let url = params["request"]?["url"]?.stringValue, url.hasPrefix(host),
                  let source = URL(string: base + url.dropFirst(host.count)) else { return }
            Task { @MainActor in
                let (body, response) = (try? await URLSession.shared.data(from: source)) ?? (Data(), nil)
                _ = try? await tab.devTools.send("Fetch.fulfillRequest", [
                    "requestId": .string(id),
                    "responseCode": .integer(Int64((response as? HTTPURLResponse)?.statusCode ?? 404)),
                    "responseHeaders": .array([.object(["name": .string("Content-Type"),
                                                        "value": .string("text/html; charset=utf-8")])]),
                    "body": .string(body.base64EncodedString())
                ])
            }
        }
        defer {
            tab.devTools.stopObservingEvents(served)
            Task { _ = try? await tab.devTools.send("Fetch.disable") }
        }
        _ = try? await tab.devTools.send("Fetch.enable", ["patterns": .array([.object(["urlPattern": .string(host + "*")])])])

        controller.addressInput = host + "vault/otp"
        controller.submitAddress()
        let loaded = await waitUntilAsync(.seconds(20)) {
            controller.tab?.currentURL == host + "vault/otp" && controller.tab?.isLoading == false
        }
        let offered = await waitUntilAsync(.seconds(6)) { controller.vaultCodeOffer != nil }
        capture(controller, named: "vault-panel-unlinked-code-bar.png")
        let offer = controller.vaultCodeOffer
        check("panel: a code with no site is offered on the site its name names, with the site it will keep",
              loaded && offered && offer?.items.map(\.id) == [vendor.id] && offer?.newSite == "qa-vendor.test",
              offer.map { "\($0.items.map(\.name)) → \($0.newSite ?? "no new site")" } ?? "loaded \(loaded), no offer")
        if let item = offer?.items.first { controller.fillCodeForPerson(item) }
        let filled = await waitUntilAsync(.seconds(5)) { await page(tab, "document.getElementById('code').value.length")?.integerValue == 6 }
        _ = await page(tab, "document.querySelector('#one button').click()")
        let taken = await waitUntilAsync(.seconds(3)) { await page(tab, "window.qa.one") == .bool(true) }
        let kept = vault.items.first { $0.id == vendor.id }?.sites
        check("panel: filling it keeps the site for that item and the page takes the code",
              filled && taken && kept == ["qa-vendor.test"],
              "filled \(filled), checked \(taken), sites \(kept ?? [])")
    }

    /// The person's strong passwords in the panel (design §15): an empty new-password field offers one; taking
    /// it fills the field and its confirmation within the site's passwordrules and saves an item at once, which
    /// submitting completes with the form's username. On a change form the made password is kept beside the
    /// saved item, which updating after the change replaces while keeping its old password; and the page's
    /// menu offers one while a password field has the focus.
    private func exercisePanelPasswords(_ controller: BrowserHostPaneController) async {
        func open(_ path: String) async -> BrowserTab? {
            controller.addressInput = base + path
            controller.submitAddress()
            guard await waitUntilAsync(.seconds(20), {
                controller.tab?.currentURL?.hasSuffix(path) == true && controller.tab?.isLoading == false
            }), let tab = controller.tab else {
                check("panel: \(path) loads", false, controller.tab?.currentURL ?? "no tab")
                return nil
            }
            try? await Task.sleep(for: .seconds(1))
            return tab
        }
        func page(_ tab: BrowserTab, _ expression: String) async -> JSONValue? {
            let result = try? await tab.devTools.send("Runtime.evaluate", ["expression": .string(expression), "returnByValue": .bool(true)],
                                                      timeout: .seconds(10))
            return result?["result"]?["value"]
        }
        func type(_ tab: BrowserTab, _ field: String, _ text: String) async {
            _ = await page(tab, "document.getElementById('\(field)').focus()")
            _ = try? await tab.devTools.send("Input.insertText", ["text": .string(text)], timeout: .seconds(10))
        }
        let origin = VaultSite.origin(of: base) ?? base

        guard let signup = await open("vault/signup") else { return }
        await type(signup, "user", "newperson@example.test")
        _ = await page(signup, "document.getElementById('pass').focus()")
        let offered = await waitUntilAsync(.seconds(5)) { controller.vaultPasswordOffer != nil }
        capture(controller, named: "vault-panel-password-bar.png")
        check("panel: an empty new-password field offers a strong password", offered, "\(String(describing: controller.vaultPasswordOffer))")
        controller.useStrongPassword()
        let filled = await waitUntilAsync(.seconds(5)) { await page(signup, "window.qa.ok()") == .bool(true) }
        let value = await page(signup, "pass.value")?.stringValue ?? ""
        let presaved = vault.items.first { $0.username == "newperson@example.test" }
        try? await Task.sleep(for: .milliseconds(300))
        capture(controller, named: "vault-panel-password-saved.png")
        check("panel: Use Strong Password fills the field and its confirmation within the site's rules and saves an item at once",
              filled && !value.isEmpty && presaved.flatMap { vault.secret(of: $0.id)?.password } == value
                && controller.vaultPasswordOffer == nil,
              "filled \(filled), saved \(presaved?.name ?? "none")")
        _ = await page(signup, "document.getElementById('go').click()")
        let created = await waitUntilAsync(.seconds(3)) { await page(signup, "window.qa.submitted?.ok") == .bool(true) }
        try? await Task.sleep(for: .milliseconds(500))
        check("panel: submitting the made password asks nothing and keeps the item",
              created && controller.vaultOffer == nil && vault.items.filter { $0.username == "newperson@example.test" }.count == 1,
              "submitted \(created), offer \(controller.vaultOffer != nil)")

        guard let change = await open("vault/change"),
              let person = vault.items.first(where: { $0.username == "person@example.test" }),
              let old = vault.secret(of: person.id)?.password else {
            return check("panel: the change form loads for the person's saved item", false, "no item")
        }
        await type(change, "current", old)
        _ = await page(change, "document.getElementById('fresh').focus()")
        let changeOffered = await waitUntilAsync(.seconds(5)) { controller.vaultPasswordOffer != nil }
        controller.useStrongPassword()
        let changeFilled = await waitUntilAsync(.seconds(5)) {
            await page(change, "fresh.value !== '' && fresh.value === again.value && current.value !== fresh.value") == .bool(true)
        }
        let fresh = await page(change, "fresh.value")?.stringValue ?? ""
        let beside = vault.items.first { $0.username.isEmpty && $0.sites == [origin] && $0.hasPassword }
        check("panel: on a change form the made password goes into the new and confirmation fields and beside the saved item",
              changeOffered && changeFilled && vault.secret(of: person.id)?.password == old
                && beside.flatMap { vault.secret(of: $0.id)?.password } == fresh,
              "offered \(changeOffered), filled \(changeFilled), beside \(beside?.name ?? "none")")
        _ = await page(change, "document.getElementById('go').click()")
        let asked = await waitUntilAsync(.seconds(5)) { controller.vaultOffer?.updates?.id == person.id }
        capture(controller, named: "vault-panel-password-update.png")
        controller.acceptVaultOffer()
        let updated = vault.secret(of: person.id)
        check("panel: updating after the change gives the item the new password, keeps the old one and drops the item beside it",
              asked && updated?.password == fresh && updated?.previousPasswords?.first?.password == old
                && !vault.items.contains { $0.id == beside?.id },
              "asked \(asked), previous \(updated?.previousPasswords?.count ?? 0)")

        _ = await page(change, "document.getElementById('current').focus()")
        let focused = await waitUntilAsync(.seconds(3)) { controller.focusedPasswordPage != nil }
        let menu = controller.view?.extraContextMenuItems?() ?? []
        check("panel: the page's menu offers a strong password while a password field has the focus",
              focused && menu.first?.title == L10n.string("Use Strong Password"), menu.map(\.title).joined(separator: ", "))
    }

    private func capture(_ controller: BrowserHostPaneController, named name: String) {
        guard let content = controller.view?.window?.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appending(path: name))
    }

    // MARK: Pieces

    private func call(_ tool: String, _ arguments: [String: ToolJSON] = [:]) async -> AgentToolResult {
        await broker.handle(AgentToolCall(token: token, session: session.uuidString, tool: tool, arguments: .object(arguments)))
    }

    private func toolNames() async -> [String] {
        let list = await broker.list(AgentToolCall(token: token, session: session.uuidString, tool: "",
                                                   arguments: .object([:]), method: AgentToolCall.listMethod))
        return list?.tools.compactMap { $0["name"]?.stringValue } ?? []
    }

    private func navigate(_ path: String, host: String? = nil) async {
        var address = base + path
        if let host { address = address.replacingOccurrences(of: "localhost", with: host) }
        let result = await call(AgentToolCatalog.navigate, ["url": .string(address)])
        if result.isError { check("load \(path)", false, result.text) }
    }

    /// A value from the page itself, read over the tab's own CDP connection (not an agent tool).
    private func pageValue(_ expression: String, awaitPromise: Bool = false) async -> JSONValue? {
        let result = try? await client.tab(forSession: session)?.devTools.send("Runtime.evaluate", [
            "expression": .string(expression), "returnByValue": .bool(true), "awaitPromise": .bool(awaitPromise)
        ], timeout: .seconds(20))
        return result?["result"]?["value"]
    }

    /// What Chromium's accessibility tree says a password field holds.
    private func accessibilityValue(ofPasswordFieldIn path: String) async -> String? {
        let tree = try? await client.tab(forSession: session)?.devTools.send("Accessibility.getFullAXTree", [:],
                                                                            timeout: .seconds(20))
        let field = tree?["nodes"]?.arrayValue?.first { $0["name"]?["value"]?.stringValue == "Password"
            && $0["role"]?["value"]?.stringValue == "textbox" }
        return field?["value"]?["value"]?.stringValue
    }

    private static func refs(in snapshot: String, role: String) -> [String] {
        snapshot.split(separator: "\n").filter { $0.contains("- \(role)") }.compactMap { line in
            line.range(of: #"\[ref=(@e\d+)\]"#, options: .regularExpression).map {
                String(line[$0].dropFirst(5).dropLast())
            }
        }
    }

    private static func ref(in snapshot: String, role: String, name: String?) -> String? {
        let lines = snapshot.split(separator: "\n").filter { line in
            line.contains("- \(role)") && (name.map { line.contains("\"\($0)\"") } ?? true)
        }
        return lines.first.flatMap { line in
            line.range(of: #"\[ref=(@e\d+)\]"#, options: .regularExpression).map { String(line[$0].dropFirst(5).dropLast()) }
        }
    }

    private func profileFiles() -> [String] {
        let profile = MacBrowserHost.shared.paths.profile
        return ["Login Data", "Web Data", "Login Data For Account"].compactMap { name in
            let path = profile.appending(path: name).path(percentEncoded: false)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else { return nil }
            return "\(name): \(size) bytes"
        }
    }

    private func waitUntilAsync(_ timeout: Duration, _ condition: @escaping @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        checks.append(.object(["check": .string(name), "ok": .bool(ok), "detail": .string(String(detail.prefix(800)))]))
        write()
    }

    private func write() {
        record["checks"] = .array(checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(JSONValue.object(record)).write(to: output.appending(path: "result.json"), options: .atomic)
    }

    private func finish() async {
        write()
        try? "done".write(to: output.appending(path: "markers/finished"), atomically: true, encoding: .utf8)
        client.terminateHost()
        try? await Task.sleep(for: .seconds(1))
        _exit(0)
    }
}
#endif
