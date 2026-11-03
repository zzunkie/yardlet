import Foundation
import YardletAgentTools

/// Yardlet's own passkeys (docs/BROWSER_VAULT_DESIGN.md §5.2) over CDP's virtual authenticator, which
/// CEF 154 carries (QA 2026-10-24): one authenticator per tab for a short while, holding one saved
/// credential to answer the page's next passkey request, or none to receive a new one.
@MainActor
enum VaultPasskeyAuthenticator {
    /// A platform authenticator that verifies its user and is present without a touch.
    nonisolated static let options: JSONValue = .object([
        "protocol": .string("ctap2"), "ctap2Version": .string("ctap2_1"), "transport": .string("internal"),
        "hasResidentKey": .bool(true), "hasUserVerification": .bool(true), "isUserVerified": .bool(true),
        "automaticPresenceSimulation": .bool(true)
    ])

    /// Whether a page on `host` may use a credential for `relyingPartyID` (WebAuthn: the RP ID is the
    /// host or a registrable suffix of it).
    nonisolated static func host(_ host: String, mayUse relyingPartyID: String) -> Bool {
        host == relyingPartyID || host.hasSuffix("." + relyingPartyID)
    }

    static func attach(_ cdp: any BrowserAgentCDP, timeout: Duration) async throws -> String {
        _ = try await cdp.send("WebAuthn.enable", ["enableUI": .bool(false)], timeout: timeout)
        let added = try await cdp.send("WebAuthn.addVirtualAuthenticator", ["options": options], timeout: timeout)
        guard let id = added["authenticatorId"]?.stringValue else {
            throw BrowserAgentToolError("The browser did not make an authenticator for the passkey.")
        }
        return id
    }

    static func detach(_ cdp: any BrowserAgentCDP, _ authenticatorID: String, timeout: Duration) async {
        _ = try? await cdp.send("WebAuthn.removeVirtualAuthenticator", ["authenticatorId": .string(authenticatorID)],
                                timeout: timeout)
        _ = try? await cdp.send("WebAuthn.disable", [:], timeout: timeout)
    }

    static func credential(_ passkey: VaultPasskey) -> JSONValue {
        .object([
            "credentialId": .string(passkey.credentialID), "isResidentCredential": .bool(true),
            "rpId": .string(passkey.relyingPartyID), "privateKey": .string(passkey.privateKey),
            "userHandle": .string(passkey.userHandle), "signCount": .integer(Int64(passkey.signCount))
        ])
    }

    /// Waits for an event of `method` after `mark` in the tab's event log; nil after `limit`.
    static func event(_ method: String, on cdp: any BrowserAgentCDP, after mark: Int, limit: Duration,
                      stop: @MainActor () -> Bool = { false }) async -> JSONValue? {
        let deadline = ContinuousClock.now + limit
        var checked = mark
        while ContinuousClock.now < deadline, !stop() {
            let log = cdp.eventLog
            if log.count > checked {
                if let found = log[checked...].first(where: { $0.method == method }) { return found.params }
                checked = log.count
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}

/// A passkey the vault put into a tab's authenticator, until the page uses it or its time runs out.
struct BrowserAgentArmedPasskey {
    var authenticatorID: String
    var itemID: UUID
    var generation: Int
}

extension BrowserAgentTools {
    /// How long an armed passkey waits for the page's request.
    static let passkeyWindow: Duration = .seconds(60)

    /// `browser_fill_credential` with `kind: passkey`.
    func armPasskey(itemName: String?, on page: BrowserAgentPage, sessionID: UUID) async throws -> AgentToolResult {
        guard let vault else { throw BrowserAgentToolError("Yardlet's password manager is not available in this build.") }
        let tree = try await send(page, "Page.getFrameTree")
        let frame = tree["frameTree"]?["frame"]
        let origin = frame?["securityOrigin"]?.stringValue.flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
            ?? frame?["url"]?.stringValue.flatMap(VaultSite.origin(of:)) ?? ""
        let request = VaultFillRequest(sessionID: sessionID, itemName: itemName, kind: .passkey, origin: origin)
        let grant: VaultFillGrant
        switch await vault.authorize(request) {
        case .success(let allowed): grant = allowed
        case .failure(let refusal): throw BrowserAgentToolError(refusal.message, refusal.failure)
        }
        let host = VaultSite.host(of: origin)
        guard let passkey = grant.passkey, VaultPasskeyAuthenticator.host(host, mayUse: passkey.relyingPartyID) else {
            vault.record(grant, for: request, filled: [], failure: "The passkey is for another site.")
            throw BrowserAgentToolError("“\(grant.item.name)”'s passkey is not for \(host).")
        }
        await disarmPasskey(on: page)
        let authenticator = try await VaultPasskeyAuthenticator.attach(page.cdp, timeout: commandTimeout)
        do {
            _ = try await send(page, "WebAuthn.addCredential", [
                "authenticatorId": .string(authenticator), "credential": VaultPasskeyAuthenticator.credential(passkey)
            ])
        } catch {
            await VaultPasskeyAuthenticator.detach(page.cdp, authenticator, timeout: commandTimeout)
            vault.record(grant, for: request, filled: [], failure: "The browser did not take the passkey.")
            throw error
        }
        passkeyGeneration += 1
        let generation = passkeyGeneration
        page.onArmedPasskeyChange = { [weak self] page in
            if page.armedPasskey == nil {
                self?.pagesWithPasskeys[ObjectIdentifier(page)] = nil
            } else {
                self?.pagesWithPasskeys[ObjectIdentifier(page)] = { [weak page] in page }
            }
        }
        page.armedPasskey = BrowserAgentArmedPasskey(authenticatorID: authenticator, itemID: grant.item.id, generation: generation)
        vault.record(grant, for: request, filled: ["passkey"])
        let mark = page.cdp.eventLog.count
        // The authenticator answers one request, then goes; unused, it goes after the window.
        Task { @MainActor [weak self, weak page] in
            guard let page else { return }
            let asserted = await VaultPasskeyAuthenticator.event("WebAuthn.credentialAsserted", on: page.cdp, after: mark,
                                                                 limit: Self.passkeyWindow) {
                page.armedPasskey?.generation != generation
            }
            guard page.armedPasskey?.generation == generation else { return }
            if let count = asserted?["credential"]?["signCount"]?.integerValue {
                self?.vault?.updatePasskeyCount(of: grant.item.id, to: Int(count))
            }
            await self?.disarmPasskey(on: page)
        }
        return .text("“\(grant.item.name)”'s passkey answers this tab's next passkey request on \(host) within 60 seconds, "
            + "without a dialog; start the page's passkey sign-in now. The key is not shown to you."
            + Self.chosenNote(grant, host: host))
    }

    /// The vault was turned off or emptied: every armed passkey goes.
    func disarmAllPasskeys() async {
        for page in pagesWithPasskeys.values.compactMap({ $0() }) {
            await disarmPasskey(on: page)
        }
        pagesWithPasskeys = [:]
    }

    /// Takes the vault's authenticator off the tab, if one is there.
    func disarmPasskey(on page: BrowserAgentPage) async {
        guard let armed = page.armedPasskey else { return }
        page.armedPasskey = nil
        await VaultPasskeyAuthenticator.detach(page.cdp, armed.authenticatorID, timeout: commandTimeout)
    }
}
