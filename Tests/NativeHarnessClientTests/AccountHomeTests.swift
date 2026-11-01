import XCTest
@testable import NativeHarnessClient

/// Account folders that share everything but their login with the default folder, the folders a
/// person's own setup points Claude Code and Codex at, and taking an account away again. Every
/// folder is a temporary one; no CLI signs in, and nothing goes to the person's Trash.
@MainActor final class AccountHomeTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(path: "account-home-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    /// The default folder as Claude Code leaves it after some use.
    private func defaultFolder() throws -> URL {
        let primary = root.appending(path: "home/.claude")
        for folder in ["projects/-work", "plugins/synced", "skills/mine", "sessions", "cache", "telemetry", "backups"] {
            try fileManager.createDirectory(at: primary.appending(path: folder), withIntermediateDirectories: true)
        }
        for file in ["settings.json", "history.jsonl", "projects/-work/one.jsonl", "skills/mine/SKILL.md",
                     "policy-limits.json", "remote-settings.json", "mcp-needs-auth-cache.json", "hfi-auth.json",
                     ".credentials.json", ".claude.json"] {
            try Data("{}".utf8).write(to: primary.appending(path: file))
        }
        return primary
    }

    private func entries(_ folder: URL) throws -> [String: String?] {
        try Dictionary(uniqueKeysWithValues: fileManager.contentsOfDirectory(atPath: folder.path).map { name in
            (name, try? fileManager.destinationOfSymbolicLink(atPath: folder.appending(path: name).path))
        })
    }

    func testANewClaudeFolderLinksEverythingButWhatTheLoginOwns() throws {
        let primary = try defaultFolder()
        try fileManager.removeItem(at: primary.appending(path: "projects"))
        let home = root.appending(path: "connections/A/claude-code")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try ClaudeAccountHome.prepareNewHome(home, primary: primary)

        let made = try entries(home)
        XCTAssertEqual(Set(made.keys), ["projects", "plugins", "skills", "sessions", "settings.json", "history.jsonl"],
            "The login's own entries (dot files, cache, telemetry, backups, policy and auth files) stay out")
        for (name, destination) in made {
            XCTAssertEqual(destination, primary.appending(path: name).path, name)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: primary.appending(path: "projects").path),
            "The default folder gains the projects folder Claude Code would make, so both logins write there")
        let plan = ClaudeAccountHome.plan(home: home, primary: primary)
        XCTAssertFalse(plan.hasChanges)
        XCTAssertTrue(plan.sharesConversations)
    }

    func testSharingAnExistingFolderOnlyAddsLinksAndKeepsWhatHasContent() throws {
        let primary = try defaultFolder()
        // A Session Switch folder signed in before its links were made: its own plugins and an empty
        // sessions folder, its conversations apart, and its settings linked somewhere else.
        let home = root.appending(path: "Session Switch/accounts/B")
        try fileManager.createDirectory(at: home.appending(path: "plugins/synced/org_account"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appending(path: "sessions"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appending(path: "projects/-work"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appending(path: "projects/-work/two.jsonl"))
        try fileManager.createSymbolicLink(atPath: home.appending(path: "settings.json").path, withDestinationPath: "/tmp/elsewhere.json")

        let plan = ClaudeAccountHome.plan(home: home, primary: primary)
        XCTAssertEqual(plan.links, ["history.jsonl", "skills"])
        XCTAssertEqual(plan.emptyFolders, ["sessions"])
        XCTAssertEqual(plan.kept, ["plugins", "projects"])
        XCTAssertEqual(plan.linkedElsewhere, ["settings.json"])
        XCTAssertTrue(plan.keepsOwnConversations)
        XCTAssertFalse(plan.sharesConversations)

        try ClaudeAccountHome.apply(plan, home: home, primary: primary)
        let after = try entries(home)
        XCTAssertEqual(after["sessions"], primary.appending(path: "sessions").path)
        XCTAssertEqual(after["skills"], primary.appending(path: "skills").path)
        XCTAssertEqual(after["plugins"], .some(nil), "A folder with content is never replaced")
        XCTAssertTrue(fileManager.fileExists(atPath: home.appending(path: "projects/-work/two.jsonl").path))
        XCTAssertEqual(after["settings.json"], "/tmp/elsewhere.json")

        // Removing the links reaches nothing they point to.
        try ClaudeAccountHome.unlinkShared(home: home)
        XCTAssertEqual(Set(try entries(home).keys), ["plugins", "projects"])
        XCTAssertTrue(fileManager.fileExists(atPath: primary.appending(path: "skills/mine/SKILL.md").path))
        XCTAssertTrue(fileManager.fileExists(atPath: primary.appending(path: "sessions").path))
    }

    func testFindsLoginsWhereThePersonsSetupPointsAndNowhereElse() throws {
        let home = root.appending(path: "home")
        let primary = try defaultFolder()
        func claudeFolder(_ path: String, email: String?, organization: String? = nil, linksProjects: Bool = false) throws {
            let folder = home.appending(path: path)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            var account = ""
            if let email {
                account = #""oauthAccount":{"emailAddress":"\#(email)","organizationName":"\#(organization ?? "\(email)'s Organization")"}"#
            }
            try Data("{\(account)}".utf8).write(to: folder.appending(path: ".claude.json"))
            if linksProjects {
                try fileManager.createSymbolicLink(atPath: folder.appending(path: "projects").path,
                    withDestinationPath: primary.appending(path: "projects").path)
            }
        }
        let accounts = AccountHomeDiscovery.sessionSwitchAccounts
        try claudeFolder("\(accounts)/team", email: "owner@example.test", organization: "Example Team", linksProjects: true)
        try claudeFolder("\(accounts)/saved", email: "saved@example.test", linksProjects: true)
        try claudeFolder("\(accounts)/empty", email: nil)
        try claudeFolder(".claude-work", email: "work@example.test")
        try claudeFolder("never-named", email: "hidden@example.test")
        // Another multi-account tool's folders, one of them saved; folders in the home named like
        // Claude's and Codex's, one without a login.
        let tool = "Library/Application Support/Other Tool/profiles"
        try claudeFolder("\(tool)/a", email: "a@example.test")
        try claudeFolder("\(tool)/b", email: "b@example.test")
        try fileManager.createDirectory(at: home.appending(path: "\(tool)/notes"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appending(path: ".claude-empty/projects"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appending(path: ".codex_personal"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appending(path: ".codex_personal/auth.json"))
        try fileManager.createDirectory(at: home.appending(path: "codex-alt/sessions"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appending(path: ".config/fish"), withIntermediateDirectories: true)
        try """
        # export CLAUDE_CONFIG_DIR=~/never-named
        alias cw='CLAUDE_CONFIG_DIR=~/.claude-work claude'
        export CLAUDE_CONFIG_DIR="$SOMEWHERE/else"
        """.write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        try "set -gx CODEX_HOME $HOME/codex-alt\n".write(to: home.appending(path: ".config/fish/config.fish"),
            atomically: true, encoding: .utf8)

        let saved = ["\(accounts)/saved", "\(tool)/a"].map {
            ProviderConnection(id: $0, name: $0, harness: .claudeCode, providerID: nil,
                               homePath: home.appending(path: $0).path, credentialSelector: nil)
        }
        let found = AccountHomeDiscovery.find(saved: saved,
            defaults: [.claudeCode: primary, .codex: home.appending(path: ".codex")], environment: [:], homeURL: home)

        XCTAssertEqual(found.map(\.path), [".claude-work", "codex-alt", ".codex_personal", "\(accounts)/team", "\(tool)/b"]
            .map { home.appending(path: $0).path },
            "A commented line, an unexpandable value, saved folders, folders without a login found by place alone, and the defaults are left out")
        XCTAssertEqual(found.map(\.source), [.shellFile("~/.zshrc"), .shellFile("~/.config/fish/config.fish"), .homeFolder,
                                            .sessionSwitch, .besideSavedAccount])
        XCTAssertEqual(found[3].title, "owner@example.test · Example Team")
        XCTAssertTrue(found[3].sharesConversations)
        XCTAssertEqual(found[0].title, "work@example.test · " + L10n.string("Personal"))
        XCTAssertFalse(found[0].sharesConversations)
        XCTAssertNil(found[1].email, "A Codex folder is named by its path until its own CLI reads it")
    }

    /// Importing from another account folder lists what Claude Code ran there outside the Claude
    /// app, in the folder each transcript records.
    func testAnAccountFoldersOwnConversationsAreOfferedForImport() throws {
        let config = root.appending(path: "Other Tool/profiles/a")
        let id = UUID().uuidString.lowercased()
        let folder = config.appending(path: "projects/-tmp-work")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"type":"user","cwd":"/tmp/work","sessionId":"\(id)","message":{"role":"user","content":"Fix the build"}}
        {"type":"assistant","cwd":"/tmp/work","sessionId":"\(id)","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}
        """.write(to: folder.appending(path: "\(id).jsonl"), atomically: true, encoding: .utf8)
        try "{}".write(to: folder.appending(path: "notes.jsonl"), atomically: true, encoding: .utf8)

        let found = ClaudeConversationCatalog.recentConversations(configDirectory: config)
        XCTAssertEqual(found.map(\.providerSessionID), [id])
        XCTAssertEqual(found.first?.title, "Fix the build")
        XCTAssertEqual(found.first?.workspaceURL.path(percentEncoded: false).trimmingCharacters(in: ["/"]), "tmp/work")
    }

    func testTakingAnAccountAwayKeepsEverythingButWhatYardletMade() async throws {
        let primary = try defaultFolder()
        let store = ProviderConnectionStore(fileURL: root.appending(path: "provider-connections.json"))
        store.defaultLoginEnvironment = ["CLAUDE_CONFIG_DIR": primary.path]
        store.accountsRoot = root.appending(path: "connections")
        var trashed: [URL] = []
        store.moveToTrash = { url in trashed.append(url); try FileManager.default.removeItem(at: url) }

        // A folder Yardlet made and one it did not.
        let made = try store.makeAccountHome(for: .claudeCode)
        let yardlets = try store.add(name: "new@example.test", harness: .claudeCode, home: made)
        let other = root.appending(path: "Session Switch/accounts/C")
        try fileManager.createDirectory(at: other, withIntermediateDirectories: true)
        let sessionSwitch = try store.add(name: "c@example.test", harness: .claudeCode, home: other)
        XCTAssertTrue(store.canSignOutAndDelete(yardlets))
        XCTAssertFalse(store.canSignOutAndDelete(sessionSwitch), "Only a folder Yardlet made can be deleted")
        XCTAssertTrue(store.keepsConversationsInDefaultFolder(yardlets))
        store.selection[.claudeCode] = sessionSwitch.id

        try store.remove(sessionSwitch)
        XCTAssertEqual(store.connections, [yardlets])
        XCTAssertNil(store.selection[.claudeCode])
        XCTAssertTrue(fileManager.fileExists(atPath: other.path), "Taking an account off the list keeps its folder")

        // A CLI that cannot sign out changes nothing.
        let log = root.appending(path: "signed-out")
        func cli(exit code: Int) throws -> URL {
            let script = root.appending(path: "claude-\(code)")
            try "#!/bin/sh\necho \"$CLAUDE_CONFIG_DIR $*\" >> '\(log.path)'\nexit \(code)\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            return script
        }
        do {
            try await store.signOutAndDelete(yardlets, executableURL: try cli(exit: 1))
            XCTFail("A failed sign-out must not delete")
        } catch {}
        XCTAssertEqual(store.connections, [yardlets])
        XCTAssertTrue(trashed.isEmpty)

        try await store.signOutAndDelete(yardlets, executableURL: try cli(exit: 0))
        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertEqual(trashed.map(\.lastPathComponent), [made.deletingLastPathComponent().lastPathComponent])
        XCTAssertFalse(fileManager.fileExists(atPath: made.path))
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("\(made.path) auth logout"))
        for name in ["projects/-work/one.jsonl", "settings.json", "skills/mine/SKILL.md", "sessions"] {
            XCTAssertTrue(fileManager.fileExists(atPath: primary.appending(path: name).path), name)
        }

        // Grok Build signs out of its `GROK_HOME` without asking (`grok logout`); Kimi Code signs
        // out only inside its own screen, so its folder is only taken off the list.
        let grokHome = try store.makeAccountHome(for: .grokBuild)
        let grok = try store.add(name: "grok", harness: .grokBuild, home: grokHome)
        let kimi = try store.add(name: "kimi", harness: .kimiCode, home: try store.makeAccountHome(for: .kimiCode))
        XCTAssertFalse(store.canSignOutAndDelete(kimi))
        XCTAssertTrue(store.canSignOutAndDelete(grok))
        let grokCLI = root.appending(path: "grok")
        try "#!/bin/sh\necho \"$GROK_HOME $*\" >> '\(log.path)'\n".write(to: grokCLI, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: grokCLI.path)
        try await store.signOutAndDelete(grok, executableURL: grokCLI)
        XCTAssertEqual(store.connections, [kimi])
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("\(grokHome.path) logout"))
        XCTAssertFalse(fileManager.fileExists(atPath: grokHome.path))
    }
}
