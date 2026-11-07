import XCTest
@testable import NativeHarnessClient

@MainActor final class AccountIdentityTests: XCTestCase {
    private func snapshot(
        _ harness: HarnessKind,
        id: String? = nil,
        state: AccountAuthState = .signedIn,
        email: String? = "owner@example.test",
        organization: String? = nil,
        plan: String? = nil,
        provider: String? = nil,
        usage: [AccountUsageMetric] = [],
        checkedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> HarnessAccountSnapshot {
        HarnessAccountSnapshot(
            id: id ?? harness.rawValue, harness: harness, providerID: provider, state: state,
            accountLabel: email, accountOrganization: organization, accountPlan: plan,
            detail: "Provider observation", credentialOwner: harness.displayName,
            checkedAt: checkedAt, usage: usage, canLogin: state != .signedIn, canLogout: state == .signedIn
        )
    }

    private func quota(
        id: String,
        label: String,
        detail: String,
        fraction: Double? = 0.4,
        resetsAt: Date? = Date(timeIntervalSince1970: 1_700_100_000)
    ) -> AccountUsageMetric {
        AccountUsageMetric(id: id, label: label, usedFraction: fraction, detail: detail,
            resetsAt: resetsAt, evidence: .exactQuota)
    }

    func testCodexAndOpenCodeOnOneChatGPTAccountBecomeOneAccountWithOneUsageBlock() throws {
        let store = ProviderConnectionStore()
        // The same ChatGPT login reached through two runtimes. Each runtime assigns
        // its own metric ids, so only the reported values can prove one account.
        let limits = [
            quota(id: "codex-primary", label: "5 hour limit", detail: "60% remaining"),
            quota(id: "codex-secondary", label: "Weekly limit", detail: "88% remaining", fraction: 0.12),
            quota(id: "codex-extra", label: "Code review", detail: "100% remaining", fraction: 0)
        ]
        let openCodeLimits = limits.enumerated().map { index, metric in
            quota(id: "opencode-\(index)", label: metric.label, detail: metric.detail,
                fraction: metric.usedFraction, resetsAt: metric.resetsAt)
        }
        let openCode = ProviderConnection(id: "opencode-chatgpt", name: "Work", harness: .openCode,
            providerID: "openai_codex", homePath: "/tmp/opencode-chatgpt", credentialSelector: nil)
        try store.save(openCode)
        store.publishDefaults([
            snapshot(.codex, provider: "openai-codex", usage: limits),
            snapshot(.openCode, provider: "openai-codex", usage: openCodeLimits)
        ])
        store.publish(snapshot(.openCode, id: openCode.id, provider: "openai_codex", usage: openCodeLimits),
            for: openCode)

        let groups = AccountGroupProjection.groups(from: store.choices(for: [.codex, .openCode]))
        XCTAssertEqual(groups.count, 1, "One ChatGPT account, not one row per harness")
        let group = try XCTUnwrap(groups.first)
        XCTAssertTrue(group.identity.isIdentified)
        XCTAssertEqual(group.identity.provider, "openai-codex", "Spelling differences are not separate providers")
        XCTAssertEqual(group.identity.displayLabel, "owner@example.test")
        XCTAssertEqual(group.choices.map(\.harness), [.codex, .openCode, .openCode])
        XCTAssertEqual(group.choices.map(\.connection?.id), [nil, nil, openCode.id],
            "The account lists its harness connections; it does not replace them")
        XCTAssertEqual(group.usageBlocks.count, 1, "Equal readings collapse into one account usage block")
        let block = try XCTUnwrap(group.usageBlocks.first)
        XCTAssertTrue(block.coversWholeAccount)
        XCTAssertNil(block.title, "A shared reading needs no harness qualifier")
        XCTAssertEqual(block.metrics.count, 3, "The account block keeps every limit, including the +N overflow")
        XCTAssertEqual(block.harnesses, [.codex, .openCode])
    }

    func testRuntimesWithoutAccountIdentificationKeepOneAccountPerConnection() throws {
        let store = ProviderConnectionStore()
        let second = ProviderConnection(id: "hermes-second", name: "Hermes second", harness: .hermes,
            providerID: nil, homePath: "/tmp/hermes-second", credentialSelector: nil)
        try store.save(second)
        store.publishDefaults([
            snapshot(.hermes, state: .unknown, email: nil),
            snapshot(.museCode, state: .unknown, email: nil)
        ])
        store.publish(snapshot(.hermes, id: second.id, state: .unknown, email: nil), for: second)

        let groups = AccountGroupProjection.groups(from: store.choices(for: [.hermes, .museCode]))
        XCTAssertEqual(groups.count, 3, "Without identification each connection is its own account")
        XCTAssertTrue(groups.allSatisfy { !$0.identity.isIdentified })
        XCTAssertTrue(groups.allSatisfy { $0.choices.count == 1 })
        XCTAssertTrue(groups.allSatisfy { $0.identity.providerDisplayName == nil },
            "An unnamed provider stays unknown instead of borrowing one")
        XCTAssertEqual(Set(groups.map(\.id)).count, 3)
        XCTAssertNotEqual(groups[0].id, groups[2].id,
            "Two runtimes without identification never share one account")
    }

    func testDifferentLimitSetsStayUnderTheAccountInsteadOfMovingBackToTheHarness() throws {
        let store = ProviderConnectionStore()
        store.publishDefaults([
            snapshot(.codex, provider: "openai-codex", usage: [
                quota(id: "codex-primary", label: "5 hour limit", detail: "60% remaining")
            ]),
            snapshot(.openCode, provider: "openai-codex", usage: [
                quota(id: "opencode-primary", label: "Requests", detail: "120 remaining",
                    fraction: nil, resetsAt: nil)
            ])
        ])

        let groups = AccountGroupProjection.groups(from: store.choices(for: [.codex, .openCode]))
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.usageBlocks.count, 2, "Different readings are shown, not silently merged")
        XCTAssertFalse(group.usageBlocks.contains { $0.coversWholeAccount })
        XCTAssertEqual(group.usageBlocks.map(\.title), [
            HarnessKind.codex.displayName, HarnessKind.openCode.displayName
        ])
    }

    func testGroupingKeepsFirstAppearanceOrderAndDoesNotChangeSelectionOrBindings() throws {
        let store = ProviderConnectionStore()
        let second = ProviderConnection(id: "codex-second", name: "Second Codex", harness: .codex,
            providerID: nil, homePath: "/tmp/codex-second", credentialSelector: nil)
        try store.save(second)
        store.publishDefaults([
            snapshot(.codex, provider: "openai-codex"),
            snapshot(.claudeCode, email: "owner@example.test")
        ])
        store.publish(snapshot(.codex, id: second.id, email: "other@example.test", provider: "openai-codex"),
            for: second)

        let choices = store.choices(for: [.codex, .claudeCode])
        let groups = AccountGroupProjection.groups(from: choices)
        XCTAssertEqual(groups.map(\.identity.displayLabel),
            ["owner@example.test", "other@example.test", "owner@example.test"])
        XCTAssertEqual(groups.map(\.identity.provider), ["openai-codex", "openai-codex", "anthropic"])
        XCTAssertNotEqual(groups[0].id, groups[2].id, "One address at two providers is two accounts")

        let secondChoice = try XCTUnwrap(groups[1].choices.first)
        store.choose(secondChoice)
        XCTAssertEqual(store.selection[.codex], second.id, "Selection still binds one harness connection")
        XCTAssertNil(store.selection[.claudeCode])
        XCTAssertEqual(store.connections, [second], "Grouping never copies or moves a saved connection")
    }

    func testRowLabelsPreferTheAccountNameWhileAccountMembersNameTheirConnection() throws {
        let saved = ProviderConnection(id: "opencode-work", name: "Work laptop", harness: .openCode,
            providerID: "openai-codex", homePath: "/tmp/opencode-work", credentialSelector: nil)
        let choice = AccountChoice(harness: .openCode, connection: saved,
            snapshot: snapshot(.openCode, id: saved.id, provider: "openai-codex"))
        XCTAssertEqual(choice.title, "owner@example.test", "New-task selection leads with the account name")
        XCTAssertEqual(choice.connectionTitle, "Work laptop", "Under an account the row names its connection")

        let unread = AccountChoice(harness: .hermes, connection: nil, snapshot: nil)
        XCTAssertEqual(unread.title, L10n.string("Checking account…"))
        XCTAssertEqual(unread.connectionTitle, HarnessKind.hermes.displayName)

        // One Claude account signed in through two Session Switch folders, read at different times:
        // the rows and the two readings name their folders where they would read the same.
        let folders = ["4f1c2a8e-3b7d-4e19-9a62-1d8c5b0e7f34", "9b3e6d10-7a45-4c82-b1f9-6e2a0c4d8b57"]
        let twice = folders.enumerated().map { index, folder in
            let connection = ProviderConnection(id: folder, name: "owner@example.test", harness: .claudeCode,
                providerID: nil, homePath: "/tmp/accounts/\(folder)", credentialSelector: nil)
            return AccountChoice(harness: .claudeCode, connection: connection, snapshot: snapshot(.claudeCode, id: folder,
                usage: [quota(id: "claude:session:", label: "5 hour limit", detail: "", fraction: 0.3 + Double(index) / 10)]))
        }
        let group = try XCTUnwrap(AccountGroupProjection.groups(from: twice).first)
        let named = folders.map { "\(HarnessKind.claudeCode.displayName) · " + L10n.format("Folder %@", String($0.prefix(8))) }
        XCTAssertEqual(twice.map(group.memberTitle), named)
        XCTAssertEqual(group.usageBlocks.map(\.title), named)
        XCTAssertEqual(AccountGroupProjection.groups(from: [twice[0]]).first.map { $0.memberTitle(twice[0]) },
                       HarnessKind.claudeCode.displayName, "One folder needs no folder name")
    }

    func testClaudeAuthStatusIdentityUsesEmailOrganizationAndSubscription() throws {
        let output = """
        Checking credentials…
        {
          "loggedIn": true,
          "authMethod": "claude.ai",
          "email": "owner@example.test",
          "orgName": "Example Org",
          "subscriptionType": "max"
        }
        """
        let identity = try XCTUnwrap(HarnessAccountBroker.claudeAccountIdentity(from: output))
        XCTAssertEqual(identity.displayLabel, "owner@example.test")
        XCTAssertEqual(identity.groupingOrganization, "Example Org")
        XCTAssertEqual(identity.planLabel, L10n.format("Claude %@ plan", "Max"))
        // The organization goes beside the address: a team's by name, the address's own as personal.
        XCTAssertEqual(AccountIdentityProjection.organizationTitle("Example Org", of: "owner@example.test"), "Example Org")
        XCTAssertEqual(AccountIdentityProjection.organizationTitle("owner@example.test's Organization",
            of: "owner@example.test"), L10n.string("Personal"))
        XCTAssertNil(AccountIdentityProjection.organizationTitle(nil, of: "owner@example.test"))

        XCTAssertNil(HarnessAccountBroker.claudeAccountIdentity(from: #"{"loggedIn": false}"#),
            "No published identity must not become an invented account")

        let personal = snapshot(.claudeCode, organization: nil, plan: identity.planLabel)
        let organizational = snapshot(.claudeCode, id: "claude-org", organization: "Example Org",
            plan: identity.planLabel)
        XCTAssertNotEqual(personal.accountIdentity.id, organizational.accountIdentity.id,
            "One address in two organizations is not one billing account")
        XCTAssertEqual(organizational.accountIdentity.planLabel, identity.planLabel)
        XCTAssertEqual(organizational.accountIdentity.provider, "anthropic",
            "Claude Code's own service supplies the provider when the runtime names none")
    }

    func testAccountSnapshotStaysDecodableWithoutTheNewIdentityFields() throws {
        let stored = #"""
        {"id":"codex","harness":"codex","state":"signedIn","detail":"Codex App Server account",
         "credentialOwner":"Codex CLI","checkedAt":0,"usage":[],"canLogin":false,"canLogout":true}
        """#
        let decoded = try JSONDecoder().decode(HarnessAccountSnapshot.self, from: Data(stored.utf8))
        XCTAssertNil(decoded.accountOrganization)
        XCTAssertNil(decoded.accountPlan)
        XCTAssertFalse(decoded.accountIdentity.isIdentified)
    }
}
