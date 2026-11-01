import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The one account list in each of its four modes, drawn in an unshown window in both appearances
/// into `.build/account-list-qa`: the new-task chip's popover, a task's account sheet, a limit
/// card's "Continue with another account" and Settings › Accounts.
@MainActor final class AccountListRenderingTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    func testEachModeDrawsTheSameRows() throws {
        let directory = try WindowlessRender.directory("account-list-qa")
        let (store, task) = try fixture()
        let runtime = RuntimeSelectionStore(discoversRuntimes: false)
        let modes: [(String, AccountListMode, NSSize)] = [
            ("new-task", .newTask(.claudeCode), NSSize(width: 642, height: 520)),
            ("switch-task", .switchTask(task), NSSize(width: 700, height: 470)),
            ("continue-after-limit", .continueAfterLimit(task), NSSize(width: 642, height: 430)),
            ("manage", .manage, NSSize(width: 629, height: 760))
        ]
        for (name, mode, size) in modes {
            let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size) { appearance in
                list(mode, store: store, runtime: runtime)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .background(ParityTheme.canvas)
                    .environment(\.colorScheme, appearance.colorScheme)
            }
            for capture in captures {
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1)), name)
            }
        }
        XCTAssertTrue(store.checkingKeys.isEmpty, "Drawing the lists checked nothing")
    }

    /// Settings › Accounts with one address signed in to a personal and a team organization, and
    /// the folders found with a login that are not saved yet; then the sheet that shows what linking
    /// a found Claude folder with its own history would change.
    func testSettingsNamesOrganizationsAndOffersFoldersFound() async throws {
        let directory = try WindowlessRender.directory("account-list-qa")
        let root = FileManager.default.temporaryDirectory.appending(path: "account-found-render-\(UUID().uuidString)")
        roots.append(root)
        let home = root.appending(path: "home")
        let primary = home.appending(path: ".claude")
        for folder in [".claude/projects/-work", ".claude/skills", ".claude/plugins", ".claude-work/projects/-old",
                       "\(AccountHomeDiscovery.sessionSwitchAccounts)/a1b2c3d4-0000-4000-8000-000000000001/plugins/synced",
                       "codex-alt/sessions"] {
            try FileManager.default.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
        }
        for file in [".claude/settings.json", ".claude/history.jsonl", ".claude-work/projects/-old/one.jsonl"] {
            try Data("{}".utf8).write(to: home.appending(path: file))
        }
        let team = home.appending(path: "\(AccountHomeDiscovery.sessionSwitchAccounts)/a1b2c3d4-0000-4000-8000-000000000001")
        try FileManager.default.createSymbolicLink(at: team.appending(path: "projects"),
            withDestinationURL: primary.appending(path: "projects"))
        try Data(#"{"oauthAccount":{"emailAddress":"owner@example.test","organizationName":"Example Team"}}"#.utf8)
            .write(to: team.appending(path: ".claude.json"))
        try Data(#"{"oauthAccount":{"emailAddress":"work@example.test","organizationName":"work@example.test's Organization"}}"#.utf8)
            .write(to: home.appending(path: ".claude-work/.claude.json"))
        try "alias cw='CLAUDE_CONFIG_DIR=~/.claude-work claude'\nexport CODEX_HOME=$HOME/codex-alt\n"
            .write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)

        let store = ProviderConnectionStore()
        store.homeURL = home
        store.defaultLoginEnvironment = ["CLAUDE_CONFIG_DIR": primary.path]
        let now = Date()
        // The same address in its own organization and, through another folder, in a team's.
        for (id, organization, short) in [("personal", "owner@example.test's Organization", 22.0), ("team", "Example Team", 61)] {
            let folder = root.appending(path: id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: folder.appending(path: "projects"),
                withDestinationURL: primary.appending(path: "projects"))
            let connection = ProviderConnection(id: id, name: "owner@example.test", harness: .claudeCode,
                providerID: nil, homePath: folder.path, credentialSelector: nil)
            try store.save(connection)
            let reading = try claude("owner@example.test", short: short, weekly: 40, at: now)
            store.publish(HarnessAccountSnapshot(id: id, harness: .claudeCode, providerID: nil, state: .signedIn,
                accountLabel: "owner@example.test", accountOrganization: organization,
                accountPlan: L10n.format("Claude %@ plan", id == "team" ? "Team" : "Max"), detail: "", credentialOwner: "",
                checkedAt: now, usage: reading.usage, canLogin: false, canLogout: true), for: connection)
        }
        await store.findUnsavedAccountHomes()
        store.usesFixtureSnapshots = true
        store.publishDefaults([HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil,
            state: .signedOut, accountLabel: nil, detail: "", credentialOwner: "", checkedAt: now, usage: [],
            canLogin: true, canLogout: false),
            HarnessAccountSnapshot(id: "codex", harness: .codex, providerID: "openai-codex", state: .signedIn,
            accountLabel: "codex@example.test", accountPlan: "ChatGPT Pro", detail: "", credentialOwner: "",
            checkedAt: now, usage: [], canLogin: false, canLogout: true)])
        XCTAssertEqual(store.discoveredHomes.map(\.title), ["work@example.test · " + L10n.string("Personal"),
            ProjectSidebarPresentation.abbreviatedPath(for: home.appending(path: "codex-alt")),
            "owner@example.test · Example Team"])
        XCTAssertEqual(store.choices(for: [.claudeCode]).compactMap(\.organizationTitle),
                       [L10n.string("Personal"), "Example Team"])

        let runtime = RuntimeSelectionStore(discoversRuntimes: false)
        let size = NSSize(width: 629, height: 640)
        for capture in try WindowlessRender.hostedInBothAppearances("manage-found", in: directory, size: size, content: { appearance in
            AccountList(mode: .manage, store: store, runtimeSelections: runtime, onChoose: { _ in },
                onConnect: { _ in }, onAdd: { _ in }, onShare: { _ in }, onRemove: { _, _ in }, onAddFound: { _ in },
                harnessUsage: AccountHarnessScope.Usage(withTasks: [.codex, .claudeCode], chosenForNewTask: .claudeCode))
                .padding(.horizontal, 16).padding(.top, 16)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.canvas)
                .environment(\.colorScheme, appearance.colorScheme)
        }) {
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1)))
        }

        let work = try XCTUnwrap(store.discoveredHomes.first)
        let plan = try XCTUnwrap(store.sharingPlan(for: work.connection))
        XCTAssertTrue(plan.keepsOwnConversations)
        let sheetSize = NSSize(width: 520, height: 470)
        for capture in try WindowlessRender.hostedInBothAppearances("share-sheet", in: directory, size: sheetSize, content: { appearance in
            AccountHomeShareSheet(request: .init(connection: work.connection, found: work, plan: plan),
                defaultFolder: primary, onShare: {}, onKeep: {}, onCancel: {})
                .frame(width: sheetSize.width, height: sheetSize.height, alignment: .top)
                .background(ParityTheme.elevated)
                .environment(\.colorScheme, appearance.colorScheme)
        }) {
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1)))
        }
    }

    /// Removing an account whose tasks can go on under another folder of the same account: the sheet
    /// that offers to move them, then the account's row while two of them wait for their turns to end.
    func testRemovingAnAccountOffersToMoveItsTasks() throws {
        let directory = try WindowlessRender.directory("account-list-qa")
        let root = FileManager.default.temporaryDirectory.appending(path: "account-move-render-\(UUID().uuidString)")
        roots.append(root)
        let projects = root.appending(path: "shared/projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let store = ProviderConnectionStore()
        store.usesFixtureSnapshots = true
        store.defaultLoginEnvironment = ["CLAUDE_CONFIG_DIR": root.appending(path: "shared").path]
        let now = Date()
        let personal = "owner@example.test's Organization"
        func account(_ folder: String, name: String, organization: String, short: Double) throws -> ProviderConnection {
            let home = root.appending(path: folder)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: home.appending(path: "projects"), withDestinationURL: projects)
            let connection = ProviderConnection(id: folder, name: name, harness: .claudeCode, providerID: nil,
                homePath: home.path, credentialSelector: nil)
            try store.save(connection)
            let reading = try claude("owner@example.test", short: short, weekly: 40, at: now)
            store.publish(HarnessAccountSnapshot(id: folder, harness: .claudeCode, providerID: nil, state: .signedIn,
                accountLabel: "owner@example.test", accountOrganization: organization, accountPlan: reading.accountPlan,
                detail: "", credentialOwner: "", checkedAt: now, usage: reading.usage, canLogin: false, canLogout: true),
                for: connection)
            return connection
        }
        // A folder another tool made, named by the address, and the one added with Yardlet's own sign-in.
        let old = try account("a1b2c3d4-0000-4000-8000-000000000002", name: "owner@example.test",
                              organization: personal, short: 22)
        let new = try account("new", name: "Claude Code account 6", organization: personal, short: 22)
        _ = try account("team", name: "owner@example.test", organization: "Example Team", short: 61)
        XCTAssertEqual(store.taskMoveTargets(for: old), [new], "The team organization is another account")

        let choices = store.choices(for: [.claudeCode])
        let target = try XCTUnwrap(choices.first { $0.connection == new })
        let request = AccountRemovalSheet.Request(connection: old,
            targets: [.init(connection: new, title: AccountGroupProjection.memberTitle(target, among: choices))],
            tasks: AccountTaskCount(listed: 10, archived: 122, working: 2))
        let sheetSize = NSSize(width: 520, height: 400)
        for capture in try WindowlessRender.hostedInBothAppearances("move-sheet", in: directory, size: sheetSize, content: { appearance in
            AccountRemovalSheet(request: request, onMove: { _ in }, onRemove: {}, onCancel: {})
                .frame(width: sheetSize.width, height: sheetSize.height, alignment: .top)
                .background(ParityTheme.elevated)
                .environment(\.colorScheme, appearance.colorScheme)
        }) {
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1)))
        }

        store.noteTaskMove(AccountTaskMove(target: new, waiting: 2, isConfirmed: true), for: old.id)
        let runtime = RuntimeSelectionStore(discoversRuntimes: false)
        let size = NSSize(width: 629, height: 420)
        for capture in try WindowlessRender.hostedInBothAppearances("move-waiting", in: directory, size: size, content: { appearance in
            AccountList(mode: .manage, store: store, runtimeSelections: runtime, onChoose: { _ in },
                onConnect: { _ in }, onAdd: { _ in }, onShare: { _ in }, onRemove: { _, _ in },
                harnessUsage: AccountHarnessScope.Usage(withTasks: [.claudeCode], chosenForNewTask: .claudeCode))
                .padding(.horizontal, 16).padding(.top, 16)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.canvas)
                .environment(\.colorScheme, appearance.colorScheme)
        }) {
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1)))
        }
    }

    /// Settings › Accounts' default Antigravity login, which the CLI keeps in one keychain item, so
    /// another account means signing out and in again. Its row's menu offers both, as the Harnesses
    /// page does. The CLI signs out in its own terminal and stays open, so the console finishes when
    /// the probe reads the login signed out; signing in with another account then opens the CLI's
    /// sign-in in a new terminal of the same console. A fake `agy` and a fake probe stand in.
    func testTheDefaultLoginSignsOutOrInWithAnotherAccountFromItsRow() async throws {
        let directory = try WindowlessRender.directory("account-list-qa")
        let root = FileManager.default.temporaryDirectory.appending(path: "account-sign-out-\(UUID().uuidString)")
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let agy = root.appending(path: "agy")
        let signedOut = root.appending(path: "signed-out"), signInStarted = root.appending(path: "sign-in-started")
        // Signed in, it signs out on `/logout` and stays open; signed out, it asks for a login method.
        try Data("""
        #!/bin/sh
        root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        if [ -f "$root/signed-out" ]; then
            printf 'Select login method:\\n'
            IFS= read -r input
            touch "$root/sign-in-started"
        else
            IFS= read -r input
            [ "$input" = '/logout' ] || exit 3
            touch "$root/signed-out"
        fi
        /bin/sleep 120 & wait
        """.utf8).write(to: agy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)
        let store = ProviderConnectionStore(defaultLoader: { descriptor, _ in
            let out = FileManager.default.fileExists(atPath: signedOut.path)
            return HarnessAccountSnapshot(id: descriptor.id.rawValue, harness: descriptor.id, providerID: nil,
                state: out ? .signedOut : .signedIn, accountLabel: nil, detail: "", credentialOwner: "",
                checkedAt: Date(), usage: [], canLogin: out, canLogout: !out)
        })
        let descriptor = try XCTUnwrap(HarnessCatalog.descriptor(for: .antigravityCLI))
        store.publishDefaults([await store.readDefault(descriptor, executableURL: agy)])
        let runtime = RuntimeSelectionStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("AccountListRenderingTests"))),
            discoversRuntimes: false, loadsPersistedSelections: false)
        runtime.select(agy, for: .antigravityCLI)
        let model = AccountCenterModel(connections: store)
        defer { model.closeConsole() }
        let size = NSSize(width: 629, height: 400)
        func page(_ appearance: WindowlessRender.Appearance) -> some View {
            ConnectionCenterContent(tab: .accounts, model: model, runtimeSelections: runtime, connections: store,
                harnessUsage: AccountHarnessScope.Usage(withTasks: [.antigravityCLI], chosenForNewTask: nil),
                initialHarness: nil, addingAccount: .constant(false), setupExpanded: .constant(false), onFinish: {})
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.canvas)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        let host = WindowlessRender.Host(page(.light), size: size, appearance: .light)
        defer { host.close() }
        host.settle()

        // The row's menu, built as a right click builds it, without opening it.
        let row = try rowFrame(store.choice(for: .antigravityCLI, connection: nil).title, in: host)
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: row.midX, y: size.height - row.midY),
            modifierFlags: [], timestamp: 0, windowNumber: host.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        var target = host.hosting.hitTest(click.locationInWindow)
        var menu: NSMenu?
        while let view = target, menu == nil { menu = view.menu(for: click); target = view.superview }
        let items = try XCTUnwrap(menu).items
        let titles = items.map { $0.isSeparatorItem ? "-" : $0.title }
        XCTAssertEqual(Array(titles.suffix(3)), [L10n.string("Sign In With Another Account…"), "-",
                                                 L10n.string("Sign Out…")])
        let lines = MenuLine.lines(items)
        try WindowlessRender.hostedInBothAppearances("default-login-menu", in: directory,
                                                     size: NSSize(width: size.width, height: 300)) { appearance in
            ZStack(alignment: .topLeading) {
                page(appearance)
                MenuPanel(lines: lines, width: 250,
                          highlighted: lines.firstIndex { $0.title == L10n.string("Sign In With Another Account…") })
                    .padding(.leading, row.midX).padding(.top, row.midY)
            }
            .frame(width: size.width, height: 300, alignment: .topLeading)
            .clipped()
            .environment(\.colorScheme, appearance.colorScheme)
        }

        // Signing out alone finishes when the probe reads it, and returns rather than using an account.
        await model.logout(descriptor: descriptor, runtimeSelections: runtime)
        await host.settle(until: { model.loginController.phase == .completed })
        XCTAssertEqual(model.loginController.operation, .disconnect)
        XCTAssertFalse(model.loginController.isRunning)
        XCTAssertEqual(store.defaultSnapshots[.antigravityCLI]?.state, .signedOut)
        let labels = host.accessibilityElements().map(\.label)
        XCTAssertTrue(labels.contains(L10n.string("Back")))
        XCTAssertFalse(labels.contains(L10n.string("Use this account")))
        try WindowlessRender.hostedInBothAppearances("default-login-signed-out", in: directory, size: size, content: page)
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertFalse(FileManager.default.fileExists(atPath: signInStarted.path), "Signing out alone signs nothing in")

        // Signing in with another account signs out, then starts the CLI's sign-in in the same console.
        model.closeConsole()
        try FileManager.default.removeItem(at: signedOut)
        store.publishDefaults([await store.readDefault(descriptor, executableURL: agy)])
        await model.logout(descriptor: descriptor, signsInAfter: true, runtimeSelections: runtime)
        await host.settle(until: { FileManager.default.fileExists(atPath: signInStarted.path) })
        XCTAssertEqual(model.activeHarness, .antigravityCLI)
        XCTAssertEqual(model.loginController.operation, .connect)
        XCTAssertTrue(model.loginController.isRunning)
        try WindowlessRender.hostedInBothAppearances("default-login-sign-in", in: directory, size: size, content: page)

        // A CLI whose sign-out exits (Claude Code's `auth logout`) opens its sign-in once it has exited.
        model.closeConsole()
        let claude = root.appending(path: "claude-cli/claude")
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        #!/bin/sh
        [ "$*" = 'auth logout' ] && exit 0
        [ "$*" = 'auth login' ] || exit 3
        touch "$(dirname -- "$0")/sign-in-started"
        /bin/sleep 120 & wait
        """.utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        runtime.select(claude, for: .claudeCode)
        await model.logout(descriptor: try XCTUnwrap(HarnessCatalog.descriptor(for: .claudeCode)), signsInAfter: true,
                           runtimeSelections: runtime)
        await host.settle(until: {
            FileManager.default.fileExists(atPath: claude.deletingLastPathComponent().appending(path: "sign-in-started").path)
        })
        XCTAssertEqual(model.loginController.operation, .connect)
    }

    /// The frame of the row whose accessibility label starts with `title`, in the window's top-left space.
    private func rowFrame(_ title: String, in host: WindowlessRender.Host<some View>) throws -> CGRect {
        host.hosting.layoutSubtreeIfNeeded()
        let window = host.window, height = host.hosting.bounds.height
        return try WindowlessRender.withAccessibilityTree {
            func find(_ node: AnyObject) -> CGRect? {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    if ((child.accessibilityLabel?() ?? nil) ?? "").hasPrefix(title),
                       let screen = child.accessibilityFrame?(), screen.height > 0 {
                        let frame = window.convertFromScreen(screen)
                        return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
                    }
                    if let frame = find(child) { return frame }
                }
                return nil
            }
            return try XCTUnwrap(find(host.hosting), "No row \(title)")
        }
    }

    private func list(_ mode: AccountListMode, store: ProviderConnectionStore, runtime: RuntimeSelectionStore)
        -> some View {
        let isSheet: Bool = if case .switchTask = mode { true } else { false }
        let list = AccountList(mode: mode, store: store, runtimeSelections: runtime, onChoose: { _ in },
            onConnect: mode.session == nil ? { _ in } : nil,
            onAdd: mode.session == nil ? { _ in } : nil,
            onManage: mode == .newTask(.claudeCode) ? {} : nil,
            onDone: isSheet ? {} : nil,
            harnessUsage: AccountHarnessScope.Usage(withTasks: [.codex, .claudeCode], chosenForNewTask: .claudeCode),
            maxListHeight: mode == .manage ? nil : 360)
        return Group {
            switch mode {
            case .switchTask: list.padding(20)
            case .manage: list.padding(.horizontal, 16).padding(.top, 16)
            default: list.padding(16)
            }
        }
    }

    /// Claude accounts sharing one history (one checked twelve minutes ago, one just now, one whose
    /// last check could not finish, one signed out), one with its own history, a signed-out Claude
    /// default, and one ChatGPT account reached through Codex's default login and an OpenCode
    /// connection. A Claude task runs under the account checked twelve minutes ago.
    private func fixture() throws -> (ProviderConnectionStore, SessionRecord) {
        let root = FileManager.default.temporaryDirectory.appending(path: "account-list-render-\(UUID().uuidString)")
        let projects = root.appending(path: "shared/projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        roots.append(root)
        let store = ProviderConnectionStore()
        store.usesFixtureSnapshots = true
        // The default login keeps the shared history, so the account with its own is left out of
        // automatic assignment, and says so.
        store.defaultLoginEnvironment = ["CLAUDE_CONFIG_DIR": root.appending(path: "shared").path]
        let now = Date()
        func account(_ name: String, sharesHistory: Bool = true) throws -> ProviderConnection {
            let home = root.appending(path: name)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            if sharesHistory {
                try FileManager.default.createSymbolicLink(at: home.appending(path: "projects"),
                    withDestinationURL: projects)
            }
            let connection = ProviderConnection(id: name, name: "\(name)@example.test", harness: .claudeCode,
                providerID: nil, homePath: home.path, credentialSelector: nil)
            try store.save(connection)
            return connection
        }
        let developer = try account("developer")
        let personal = try account("personal")
        let jordan = try account("jordan")
        let elsewhere = try account("elsewhere", sharesHistory: false)
        let old = try account("old")
        store.publish(try claude("developer@example.test", short: 84, weekly: 94, at: now.addingTimeInterval(-720)),
            for: developer)
        store.publish(try claude("personal@example.test", short: 4, weekly: 35, at: now), for: personal)
        store.publish(try claude("jordan@example.test", short: 40, weekly: 100, at: now.addingTimeInterval(-1_800)),
            for: jordan)
        store.publish(HarnessAccountSnapshot(id: "jordan", harness: .claudeCode, providerID: nil, state: .unknown,
            accountLabel: nil, detail: "timed out", credentialOwner: "", checkedAt: now, usage: [], canLogin: true,
            canLogout: false), for: jordan)
        store.publish(try claude("elsewhere@example.test", short: 10, weekly: 20, at: now), for: elsewhere)
        store.publish(HarnessAccountSnapshot(id: "old", harness: .claudeCode, providerID: nil, state: .signedOut,
            accountLabel: nil, detail: "", credentialOwner: "", checkedAt: now, usage: [], canLogin: true,
            canLogout: false), for: old)
        let laptop = ProviderConnection(id: "opencode-laptop", name: "Laptop", harness: .openCode,
            providerID: "openai-codex", homePath: root.appending(path: "opencode").path, credentialSelector: nil)
        try store.save(laptop)
        let codex = codexReading(resets: 2, at: now)
        let codexUsage = codex.usage
        store.publish(HarnessAccountSnapshot(id: laptop.id, harness: .openCode, providerID: "openai-codex",
            state: .signedIn, accountLabel: "codex@example.test", accountPlan: "ChatGPT Pro", detail: "",
            credentialOwner: "", checkedAt: now.addingTimeInterval(-180), usage: codexUsage, canLogin: false,
            canLogout: true), for: laptop)
        store.publishDefaults([codex, HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil,
            state: .signedOut, accountLabel: nil, detail: "", credentialOwner: "", checkedAt: now, usage: [],
            canLogin: true, canLogout: false)])
        store.selection[.claudeCode] = personal.id
        let task = SessionRecord(harness: .claudeCode, workspaceURL: root,
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Switch Yardlet account", connection: developer)
        return (store, task)
    }

    /// The fixture's ChatGPT account through Codex's default login, holding `resets` resets of its
    /// limits; the first expires in two hours.
    private func codexReading(resets: Int, at now: Date) -> HarnessAccountSnapshot {
        let usage = (try? claude("codex@example.test", short: 1, weekly: 12, at: now).usage) ?? []
        let available = [AccountUsageResets.Reset(id: "sooner", title: "Full reset", expiresAt: now.addingTimeInterval(7_200)),
                         AccountUsageResets.Reset(id: "later", title: "Full reset", expiresAt: now.addingTimeInterval(9 * 86_400))]
        return HarnessAccountSnapshot(id: "codex", harness: .codex, providerID: "openai-codex", state: .signedIn,
            accountLabel: "codex@example.test", accountPlan: "ChatGPT Pro", detail: "", credentialOwner: "",
            checkedAt: now.addingTimeInterval(-180), usage: usage,
            usageResets: AccountUsageResets(availableCount: resets, resets: Array(available.suffix(resets)),
                                            purchaseURL: HarnessAccountBroker.codexResetPurchaseURL,
                                            restores: usage.prefix(2).map(\.id)),
            canLogin: false, canLogout: true)
    }

    /// The confirmation an account list's and a limit card's "Use a reset" opens, before the person
    /// confirms, after a reset was used, and after a use that got no answer.
    func testUsageResetConfirmationAndItsAnswersRender() async throws {
        let directory = try WindowlessRender.directory("account-list-qa")
        let (store, _) = try fixture()
        let context = UsageResetContext(store: store, runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false))
        let choice = store.choice(for: .codex, connection: nil)
        XCTAssertEqual(choice.snapshot?.usageResets?.next?.id, "sooner")
        let size = NSSize(width: 380, height: 330)
        func render(_ name: String) throws {
            for capture in try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size, content: { appearance in
                UsageResetConfirmation(choice: choice, context: context, close: {})
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .background(ParityTheme.elevated)
                    .environment(\.colorScheme, appearance.colorScheme)
            }) {
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1)), name)
            }
        }
        try render("usage-reset-confirm")

        let now = Date()
        store.usageResetRunner = { _, _, resetID in
            XCTAssertEqual(resetID, "sooner")
            store.publishDefaults([self.codexReading(resets: 1, at: now)])
            return .reset
        }
        await store.useUsageReset(choice, runtimeSelections: context.runtimeSelections)
        XCTAssertEqual(store.usageResetStates[choice.id], .answered(.reset, left: 1))
        try render("usage-reset-answered")

        store.usageResetRunner = { _, _, _ in throw AccountUsageResetError.unrecognizedAnswer }
        await store.useUsageReset(choice, runtimeSelections: context.runtimeSelections)
        try render("usage-reset-failed")
    }

    private func claude(_ email: String, short: Double, weekly: Double, at checkedAt: Date) throws
        -> HarnessAccountSnapshot {
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"rate_limits":{"limits":[{"kind":"session","group":"session","percent":\#(short),"resets_at":"2030-01-01T05:00:00+00:00"},
          {"kind":"weekly_all","group":"weekly","percent":\#(weekly),"resets_at":"2030-01-06T00:00:00+00:00"},
          {"kind":"weekly_scoped","group":"weekly","percent":3,"scope":{"model":{"display_name":"Fable"}}}]}}
        """#.utf8))
        return HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil, state: .signedIn,
            accountLabel: email, accountPlan: "Claude Max plan", detail: "", credentialOwner: "",
            checkedAt: checkedAt, usage: try XCTUnwrap(ClaudeUsageProbe.usage(from: response)), canLogin: false,
            canLogout: true)
    }
}
