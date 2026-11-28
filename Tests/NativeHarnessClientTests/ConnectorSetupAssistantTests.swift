import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// The "Set up in one go" assistants (docs/CONNECTORS.md, "Google" and "Slack"): Slack's app manifest and the link
/// that opens Slack's create-from-manifest page with it, each step's state and the fields' checks,
/// and the services found by name in claude.ai accounts and Codex's apps, from fixtures with fake
/// values. No network.
final class ConnectorSetupAssistantTests: XCTestCase {
    // MARK: - Slack's manifest

    /// What Slack's manifest reference names: the app, the loopback redirect, the user scopes Slack's
    /// MCP server advertises, MCP on, PKCE on, and no bot.
    func testTheSlackManifestHasWhatSlacksMCPServerNeeds() throws {
        let manifest = SlackAppManifest.manifest
        XCTAssertEqual(manifest["display_information"]?["name"], .string("Yardlet"))
        XCTAssertEqual(manifest["oauth_config"]?["redirect_urls"], .array([.string("http://127.0.0.1:47823/callback")]))
        XCTAssertEqual(manifest["oauth_config"]?["redirect_urls"]?.arrayValue?.first?.stringValue,
                       ConnectorOAuth.registeredClientRedirectURI.absoluteString)
        XCTAssertEqual(manifest["oauth_config"]?["pkce_enabled"], .bool(true))
        XCTAssertEqual(manifest["settings"]?["is_mcp_enabled"], .bool(true))
        XCTAssertNil(manifest["oauth_config"]?["scopes"]?["bot"], "A desktop redirect asks for no bot scopes")
        XCTAssertNil(manifest["features"]?["bot_user"])
        let scopes = try XCTUnwrap(manifest["oauth_config"]?["scopes"]?["user"]?.arrayValue?.compactMap(\.stringValue))
        // The 30 scopes in `scopes_supported` at mcp.slack.com/.well-known/oauth-authorization-server.
        XCTAssertEqual(scopes.count, 30)
        XCTAssertEqual(Set(scopes).count, 30)
        XCTAssertEqual(Set(scopes), [
            "canvases:read", "canvases:write", "channels:history", "channels:read", "channels:write", "chat:write", "emoji:read",
            "files:read", "files:write", "groups:history", "groups:read", "groups:write", "im:history", "im:read", "im:write",
            "lists:read", "lists:write", "mpim:history", "mpim:read", "mpim:write", "reactions:read", "reactions:write",
            "search:read.files", "search:read.im", "search:read.mpim", "search:read.private", "search:read.public",
            "search:read.users", "users:read", "users:read.email"
        ])
        XCTAssertLessThanOrEqual(manifest["display_information"]?["description"]?.stringValue?.count ?? 0, 140)

        // The JSON is the manifest, compact with its keys in order; the readable copy is the same.
        let compact = try JSONDecoder().decode(ToolJSON.self, from: Data(SlackAppManifest.json.utf8))
        XCTAssertEqual(compact, manifest)
        XCTAssertFalse(SlackAppManifest.json.contains("\n"))
        XCTAssertEqual(try JSONDecoder().decode(ToolJSON.self, from: Data(SlackAppManifest.prettyJSON.utf8)), manifest)
        XCTAssertTrue(SlackAppManifest.json.hasPrefix("{\"display_information\""), "Sorted keys")
    }

    /// `https://api.slack.com/apps?new_app=1&manifest_json=<URL-encoded JSON>`, as Slack's
    /// manifest guide gives it: every character outside the unreserved set encoded, so the JSON's
    /// own `&`, `=`, `+`, `#`, `/`, `:`, quotes, and braces cannot end or split the parameter.
    func testTheCreateLinkCarriesTheManifestEncoded() throws {
        let url = SlackAppManifest.createURL
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host(), "api.slack.com")
        XCTAssertEqual(url.path(), "/apps")
        let raw = try XCTUnwrap(url.query(percentEncoded: true))
        XCTAssertTrue(raw.hasPrefix("new_app=1&manifest_json="), raw)
        let encoded = String(raw.dropFirst("new_app=1&manifest_json=".count))
        XCTAssertFalse(encoded.contains { "&=+#/:\"{}[], ".contains($0) }, encoded)
        XCTAssertTrue(encoded.contains("%22display_information%22"))
        XCTAssertTrue(encoded.contains("http%3A%2F%2F127.0.0.1%3A47823%2Fcallback"))
        XCTAssertEqual(encoded.removingPercentEncoding, SlackAppManifest.json)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["new_app", "manifest_json"])
        XCTAssertEqual(items.last?.value, SlackAppManifest.json, "Read back, the parameter is the manifest itself")
    }

    // MARK: - The assistants' steps

    func testGoogleSetupOpensPersonalModeForAnAgentDesktopClient() throws {
        let fresh = ConnectorSetupAssistant.google(opened: [], appSaved: false, connectedAccounts: 0)
        XCTAssertEqual(fresh.steps.map(\.id), [.project, .client, .googleSignIn])
        XCTAssertEqual(fresh.steps.first?.link?.url.absoluteString,
                       "https://console.cloud.google.com/auth/overview/personal?apis=ws,wsmcp&clientType=desktop&isAgent=true")
        XCTAssertEqual(ConnectorSetupAssistant.google(opened: [.project], appSaved: false, connectedAccounts: 0).current, .client)
        XCTAssertTrue(ConnectorSetupAssistant.google(opened: [], appSaved: true, connectedAccounts: 1).isComplete)

        // The opened steps keep across launches as one defaults string.
        let kept = ConnectorSetupProgress.encode([.scopes, .project])
        XCTAssertEqual(kept, "project,scopes")
        XCTAssertEqual(ConnectorSetupProgress.decode(kept + ",unknown,"), [.project, .scopes])
    }

    func testSlackStepsGoFromTheManifestToTheSignIn() throws {
        let fresh = ConnectorSetupAssistant.slack(opened: [], clientEntered: false, connected: false)
        XCTAssertEqual(fresh.steps.map(\.id), [.slackCreate, .slackCredentials, .slackSignIn])
        XCTAssertEqual(fresh.current, .slackCreate)
        XCTAssertEqual(fresh.steps.first?.link?.url, SlackAppManifest.createURL)
        XCTAssertEqual(fresh.steps.first?.copies.map(\.value), [SlackAppManifest.prettyJSON, "http://127.0.0.1:47823/callback"])
        XCTAssertEqual(fresh.steps[1].link?.url.absoluteString, "https://api.slack.com/apps")
        XCTAssertEqual(ConnectorSetupAssistant.slack(opened: [.slackCreate], clientEntered: false, connected: false).current,
                       .slackCredentials)
        XCTAssertEqual(ConnectorSetupAssistant.slack(opened: [], clientEntered: true, connected: false).current, .slackSignIn,
                       "A client ID pasted means the app exists")
        XCTAssertTrue(ConnectorSetupAssistant.slack(opened: [], clientEntered: false, connected: true).isComplete)
        let guide = try XCTUnwrap(ConnectorSetupGuide.guide(for: try XCTUnwrap(ConnectorPreset.preset(id: "slack"))))
        XCTAssertEqual(guide.steps, fresh.steps.map(\.title))
        XCTAssertEqual(guide.links.first?.url, SlackAppManifest.createURL)
    }

    // MARK: - Fields

    func testPastedValuesAreCheckedAsTheyAreTyped() {
        typealias A = ConnectorSetupAssistant
        // Built from parts so secret scanners do not take these fixtures for real credentials.
        let secret = "GOC" + "SPX-", apps = ".apps." + "googleusercontent.com"
        XCTAssertEqual(A.validateGoogleClientID(""), .empty)
        XCTAssertEqual(A.validateGoogleClientID("  123456789012-abc123def456" + apps + " \n"), .valid)
        XCTAssertFalse(A.validateGoogleClientID("123456789012-abc123def456").isValid)
        XCTAssertFalse(A.validateGoogleClientID(apps).isValid)
        XCTAssertFalse(A.validateGoogleClientID("123 456" + apps).isValid)
        XCTAssertEqual(A.validateGoogleClientID(secret + "abcdefghijklmnop").message,
                       L10n.string("That is the client secret; the client ID ends with .apps.googleusercontent.com."))
        XCTAssertEqual(A.validateGoogleSecret(""), .empty)
        XCTAssertEqual(A.validateGoogleSecret(secret + "abcdefghijklmnopqrstuvwxyz12"), .valid)
        XCTAssertFalse(A.validateGoogleSecret(secret + "abc").isValid, "Cut off")
        XCTAssertFalse(A.validateGoogleSecret(secret + "abcdefghij klmnopqrstu").isValid)
        XCTAssertEqual(A.validateGoogleSecret("1-x" + apps).message,
                       L10n.string("That is the client ID; the secret is the other value, often starting with GOCSPX-."))

        XCTAssertEqual(A.validateSlackClientID(""), .empty)
        XCTAssertEqual(A.validateSlackClientID("123.456"), .valid)
        XCTAssertEqual(A.validateSlackClientID(" 1234567890123.9876543210987 "), .valid)
        for wrong in ["123", "123.", ".456", "123.456.789", "12a.456", "123,456", "xoxp-123.456", "１２３.４５６"] {
            XCTAssertEqual(A.validateSlackClientID(wrong).message,
                           L10n.string("A Slack client ID is two numbers with a dot between, like 123.456."), wrong)
        }
        XCTAssertEqual(A.validateSlackSecret(""), .empty, "A PKCE app has none")
        XCTAssertEqual(A.validateSlackSecret("0123456789abcdef0123456789abcdef"), .valid)
        XCTAssertFalse(A.validateSlackSecret("0123456789abcdef").isValid)
        XCTAssertFalse(A.validateSlackSecret("0123456789abcdef0123456789abcdeg").isValid)
    }

    // MARK: - Services used elsewhere

    /// A Session Switch account's `.claude.json` with claude.ai connectors, and a Codex home whose
    /// configuration has ChatGPT apps by ID (one turned off, one named only by its tools) and whose
    /// cache names the connected ones. Names come out, and the account a folder is signed in to in
    /// place of the folder's name; nothing else is kept.
    func testServicesUsedInClaudeAIAndCodexAppsAreSuggestedByName() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "connector-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appending(path: "Session Switch/accounts/e0824000-fake/.claude.json")
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.claudeAccount.utf8).write(to: claude)
        // The same account through an older folder.
        let older = root.appending(path: "Session Switch/accounts/496a0000-fake/.claude.json")
        try FileManager.default.createDirectory(at: older.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.claudeAccount.utf8).write(to: older)
        let codex = root.appending(path: "codex", directoryHint: .isDirectory)
        let cache = codex.appending(path: "cache/codex_apps_tools", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(Self.codexConfig.utf8).write(to: codex.appending(path: "config.toml"))
        try Data(Self.appsCacheOld.utf8).write(to: cache.appending(path: "aaa111.json"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)],
                                              ofItemAtPath: cache.appending(path: "aaa111.json").path(percentEncoded: false))
        try Data(Self.appsCacheNew.utf8).write(to: cache.appending(path: "bbb222.json"))

        let config = CodexNativeMCPConfig.parse(Self.codexConfig)
        XCTAssertEqual(config.apps.map(\.id), ["connector_github_fake", "asdk_app_linear_fake", "connector_gcal_fake",
                                               "asdk_app_slack_fake"])
        XCTAssertEqual(config.apps.first { $0.id == "connector_gcal_fake" }?.isEnabled, false)
        XCTAssertEqual(config.apps.first { $0.id == "asdk_app_linear_fake" }?.serviceFromToolNames, "linear")
        XCTAssertEqual(config.apps.first { $0.id == "connector_github_fake" }?.serviceFromToolNames, "github",
                       "github_create_pull_request and \"github.update_pull_request\" agree")
        XCTAssertEqual(config.plugins, ["linear@openai-curated"])
        let names = NativeMCPConfigFiles.codexAppNames(home: codex)
        XCTAssertEqual(names["connector_gmail_fake"], "Gmail")
        XCTAssertEqual(names["connector_drive_fake"], "Google Drive", "The newer cache file's name wins")
        XCTAssertNil(names["connector_openai_hotline"], "OpenAI's own built-in apps are left out")

        let inventory = NativeMCPInventory.read([
            NativeMCPHome(kind: .claude(file: claude), account: "Session Switch e0824000"),
            NativeMCPHome(kind: .claude(file: older), account: "Session Switch 496a0000"),
            NativeMCPHome(kind: .codex(home: codex))
        ])
        let codexEntry = try XCTUnwrap(inventory.first { $0.home.harness == .codex })
        XCTAssertEqual(codexEntry.apps, ["github", "Gmail", "Google Drive", "linear", "Sites", "Slack"],
                       "Google Calendar is turned off in Codex; GitHub and Linear are named by their tools")
        let text = String(describing: inventory)
        for secret in ["SECRET-A", "SECRET-B", "SECRET-C", "fake-org-uuid"] {
            XCTAssertFalse(text.contains(secret), "\(secret) is not kept")
        }
        // The folder reads as the account it is signed in to, so one account in two folders reads once.
        let account = "person@fake.test"

        let notion = ConnectorRecord(name: "Notion", slug: "notion", serverURL: URL(string: "https://mcp.notion.com/mcp")!,
                                     status: .connected, presetID: "notion")
        let suggestions = ConnectorImportSuggestion.suggestions(from: inventory, connected: [notion])
        XCTAssertEqual(suggestions.map(\.name), ["Linear", "Slack", "Gmail", "Google Calendar", "Google Drive", "GitHub"],
                       "The directory's order; Notion is connected; claude.ai's own and unknown apps are left out")
        let slack = try XCTUnwrap(suggestions.first { $0.name == "Slack" })
        XCTAssertEqual(slack.foundIn, [L10n.format("claude.ai · %@", account), L10n.string("Codex app")])
        XCTAssertFalse(slack.connectsInOneClick, "Slack opens its setup assistant")
        let gmail = try XCTUnwrap(suggestions.first { $0.name == "Gmail" })
        XCTAssertEqual(gmail.foundIn, [L10n.format("claude.ai · %@", account), L10n.string("Codex app")])
        XCTAssertEqual(suggestions.first { $0.name == "Google Calendar" }?.foundIn,
                       [L10n.format("claude.ai · %@", account)], "Only claude.ai; Codex turned it off")
        XCTAssertEqual(suggestions.first { $0.name == "Linear" }?.foundIn,
                       [L10n.format("claude.ai · %@", account), L10n.string("Codex plugin"),
                        L10n.string("Codex app")])
        XCTAssertTrue(try XCTUnwrap(suggestions.first { $0.name == "Linear" }).connectsInOneClick)
        XCTAssertFalse(suggestions.contains { $0.name.contains("Claude Docs") || $0.name == "Sites" })

        // Once a Google account has Calendar, Calendar is not suggested again.
        let calendar = ConnectorRecord(name: "Google Calendar", slug: "calendar", serverURL: GoogleOAuth.Endpoints.live.calendarAPI,
                                       status: .connected, presetID: "google-calendar", localService: .googleCalendar)
        XCTAssertFalse(ConnectorImportSuggestion.suggestions(from: inventory, connected: [notion, calendar])
            .contains { $0.name == "Google Calendar" })
    }

    static let claudeAccount = #"""
    {
      "oauthAccount": {"emailAddress": "person@fake.test", "organizationUuid": "fake-org-uuid"},
      "mcpServers": {},
      "claudeAiMcpEverConnected": ["claude.ai Gmail", "claude.ai Slack", "claude.ai Linear", "claude.ai Google Calendar",
                                   "claude.ai Claude Docs", "claude.ai Claude Code Remote", "claude.ai Notion"],
      "projects": {"/work/x": {"history": [{"display": "SECRET-A"}]}}
    }
    """#

    static let codexConfig = #"""
    model = "gpt-5"
    [plugins."linear@openai-curated"]
    enabled = true
    [apps.connector_github_fake.tools.github_create_pull_request]
    approval_mode = "approve"
    [apps.connector_github_fake.tools."github.update_pull_request"]
    approval_mode = "approve"
    [apps.asdk_app_linear_fake]
    enabled = true
    [apps.asdk_app_linear_fake.tools."linear.save_comment"]
    approval_mode = "approve"
    [apps.connector_gcal_fake]
    enabled = false
    [apps.asdk_app_slack_fake]
    enabled = true
    [shell_environment_policy.set]
    TOKEN = "SECRET-B"
    """#

    static let appsCacheOld = #"""
    {"schema_version": 1, "tools": [
      {"connector_id": "connector_drive_fake", "connector_name": "Drive (old name)", "tool_name": "search",
       "tool": {"description": "SECRET-C"}}
    ]}
    """#

    static let appsCacheNew = #"""
    {"schema_version": 1, "tools": [
      {"connector_id": "connector_gmail_fake", "connector_name": "Gmail", "tool_name": "search_emails", "tool": {}},
      {"connector_id": "connector_gmail_fake", "connector_name": "Gmail", "tool_name": "send_email", "tool": {}},
      {"connector_id": "connector_gcal_fake", "connector_name": "Google Calendar", "tool_name": "search_events", "tool": {}},
      {"connector_id": "connector_drive_fake", "connector_name": "Google Drive", "tool_name": "fetch", "tool": {}},
      {"connector_id": "asdk_app_slack_fake", "connector_name": "Slack", "tool_name": "slack_search", "tool": {}},
      {"connector_id": "connector_sites_fake", "connector_name": "Sites", "tool_name": "deploy", "tool": {}},
      {"connector_id": "connector_openai_hotline", "connector_name": "Hotline", "tool_name": "call", "tool": {}}
    ]}
    """#
}
