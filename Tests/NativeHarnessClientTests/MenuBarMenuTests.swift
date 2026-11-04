import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote
@testable import YardletRemoteFixtureSupport

/// The menu bar item's menu (Codex tray menu: Running, Unread, Pinned, Recent, Usage, then New
/// task, Open and Quit), what choosing its items does, its setting, and `⌥⌘U`. Nothing here shows
/// a status item, a notification or a window: the menu is built from a model with a recording
/// stand-in for activation.
@MainActor
final class MenuBarMenuTests: XCTestCase {
    private let yardlet = URL(filePath: "/tmp/menu-bar-tests/yardlet", directoryHint: .isDirectory)
    private let website = URL(filePath: "/tmp/menu-bar-tests/website", directoryHint: .isDirectory)
    private let now = Date(timeIntervalSince1970: 1_792_158_000) // 2026-10-16 13:40 UTC

    private func task(_ title: String, in folder: URL? = nil, status: SessionStatus = .ready,
                      unread: Bool = false, pinned: Bool = false, minutesAgo: Double) -> SessionRecord {
        SessionRecord(harness: .claudeCode, workspaceURL: folder ?? yardlet, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                      title: title, titleOrigin: .provider, status: status,
                      updatedAt: now.addingTimeInterval(-minutesAgo * 60), hasUnreadUpdate: unread, isPinned: pinned)
    }

    // MARK: - Sections

    func testSectionsFollowTheAttentionDefinitionAndItsOrder() {
        let approval = task("Approve the migration", status: .waitingForApproval, minutesAgo: 5)
        let question = task("Pick the icon set", status: .running, minutesAgo: 3)
        let working = task("Build the release", status: .running, minutesAgo: 1)
        let shell = task("Tail the server log", minutesAgo: 8)
        let unread = task("Summarize the crashes", status: .completed, unread: true, minutesAgo: 2)
        let failed = task("Fix the flaky test", status: .failed, unread: true, minutesAgo: 6)
        let pinnedIdle = task("Release checklist", pinned: true, minutesAgo: 20)
        let pinnedWorking = task("Nightly benchmarks", status: .running, pinned: true, minutesAgo: 4)
        let idle = (0..<3).map { task("Old task \($0)", minutesAgo: 30 + Double($0)) }
        let sessions = [approval, question, working, shell, unread, failed, pinnedIdle, pinnedWorking] + idle

        let menu = MenuBarMenuProjection.menu(
            sessions: sessions, pinnedIDs: [pinnedIdle.id, pinnedWorking.id],
            details: [question.id: TaskAttentionDetail(pendingRequest: .input)], shellBusy: [shell.id],
            place: { _ in "yardlet" })

        XCTAssertEqual(menu.sections.map(\.kind), [.running, .unread, .pinned, .recent])
        func titles(_ kind: MenuBarMenu.SectionKind) -> [String] {
            let section = menu.sections.first { $0.kind == kind }
            return (section?.rows ?? []).map(\.title) + ["|"] + (section?.more ?? []).map(\.title)
        }
        // Waiting on the person first, then working, each most recent first.
        XCTAssertEqual(titles(.running), ["Pick the icon set", "Approve the migration", "Build the release", "|",
                                          "Nightly benchmarks", "Tail the server log"])
        XCTAssertEqual(titles(.unread), ["Summarize the crashes", "Fix the flaky test", "|"])
        // Pinned whatever their state, as the Codex menu also lists a pinned running thread here.
        XCTAssertEqual(titles(.pinned), ["Nightly benchmarks", "Release checklist", "|"])
        // Everything else but the unread, most recent first.
        XCTAssertEqual(titles(.recent), ["Build the release", "Pick the icon set", "Approve the migration", "|",
                                         "Tail the server log", "Old task 0", "Old task 1", "Old task 2"])
        XCTAssertEqual(menu.sections.first?.rows.first?.subtitle, "yardlet")

        // Each row carries its sidebar mark, whichever section lists it; an idle task has none.
        func statuses(_ kind: MenuBarMenu.SectionKind) -> [SidebarTaskStatus?] {
            let section = menu.sections.first { $0.kind == kind }
            return ((section?.rows ?? []) + (section?.more ?? [])).map(\.status)
        }
        XCTAssertEqual(statuses(.running), [.needsInput, .awaitingApproval, .running, .running, .running])
        XCTAssertEqual(statuses(.unread), [.unread, .failed(message: nil)])
        XCTAssertEqual(statuses(.pinned), [.running, nil])
        XCTAssertEqual(statuses(.recent), [.running, .needsInput, .awaitingApproval, .running, nil, nil, nil])
        for session in sessions {
            let row = menu.sections.flatMap { $0.rows + $0.more }.first { $0.sessionID == session.id }
            XCTAssertEqual(row?.status, SidebarTaskIndicatorProjection.status(
                of: session, detail: session.id == question.id ? TaskAttentionDetail(pendingRequest: .input) : nil,
                isShellBusy: session.id == shell.id))
        }

        // The same tasks the Dock badge counts are the waiting and unread ones.
        let needing = TaskAttentionProjection.count(in: sessions,
            details: [question.id: TaskAttentionDetail(pendingRequest: .input)], shellBusy: [shell.id])
        XCTAssertEqual(needing, 4)
    }

    func testSectionsWithoutTasksAreLeftOut() {
        XCTAssertEqual(MenuBarMenuProjection.menu(sessions: [], pinnedIDs: [], place: { _ in "" }), .empty)

        let idle = task("Tidy the README", minutesAgo: 1)
        let menu = MenuBarMenuProjection.menu(sessions: [idle], pinnedIDs: [], place: { _ in "" })
        XCTAssertEqual(menu.sections.map(\.kind), [.recent])
        XCTAssertEqual(menu.sections[0].more, [])
    }

    func testTitlesAreCutAsTheCodexMenuCutsThem() {
        let exact = String(repeating: "a", count: 35)
        XCTAssertEqual(MenuBarMenuProjection.menuTitle(exact), exact)
        XCTAssertEqual(MenuBarMenuProjection.menuTitle(exact + "b"), String(repeating: "a", count: 34) + "…")
        // A cut that ends on a space drops it.
        let spaced = String(repeating: "a", count: 33) + " bcdef"
        XCTAssertEqual(MenuBarMenuProjection.menuTitle(spaced), String(repeating: "a", count: 33) + "…")
        XCTAssertEqual(MenuBarMenuProjection.menuTitle("한국어 제목"), "한국어 제목")
    }

    func testTasksAreNamedByProjectOrChatsAndPinnedSplitsCount() throws {
        let home = URL(filePath: "/tmp/menu-bar-tests/home", directoryHint: .isDirectory)
        let chatFolder = ChatWorkspaces.yardletRoot(home: home).appending(path: "chat-1", directoryHint: .isDirectory)
        let left = task("Compare parsers", minutesAgo: 1)
        let right = task("Benchmark parsers", in: website, minutesAgo: 2)
        let chat = task("Ask about Swift", in: chatFolder, minutesAgo: 3)
        let (model, _) = makeModel(sessions: [left, right, chat], chatHome: home)
        model.projects.rename(model.projects.ensureProject(forRoot: yardlet).id, to: "Yardlet")
        model.projects.rename(model.projects.ensureProject(forRoot: website).id, to: "Website")
        model.splits.activate(.session(left.id))
        model.splits.split(.right, placing: right.id, pinned: true)
        let split = try XCTUnwrap(model.splits.activeSplit)
        XCTAssertTrue(split.isPinned)

        let menu = model.menuBarMenu(now: now)
        let pinned = try XCTUnwrap(menu.sections.first { $0.kind == .pinned })
        XCTAssertEqual(pinned.rows.map(\.title), ["Compare parsers", "Benchmark parsers"])
        XCTAssertEqual(pinned.rows.map(\.subtitle), ["Yardlet", "Website"])
        let recent = try XCTUnwrap(menu.sections.first { $0.kind == .recent })
        XCTAssertEqual(recent.rows.map(\.title), ["Ask about Swift"])
        XCTAssertEqual(recent.rows.map(\.subtitle), [L10n.string("Chats")])
    }

    // MARK: - Usage

    func testUsageNamesEveryAccountOfEveryHarnessWithItsHarnessAndWhatIsLeft() throws {
        let store = ProviderConnectionStore()
        let reset = now.addingTimeInterval(2 * 60 * 60)
        store.publishDefaults([
            snapshot(.claudeCode, "jordan@example.test", provider: "anthropic", usage: [
                metric("5 hour limit", used: 0.28, resetsAt: reset, id: "claude:session:"),
                metric("7 day limit", used: 0.6, resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60), id: "claude:weekly_all:"),
                metric("Opus · 7 day limit", used: 0.9, resetsAt: nil, id: "claude:weekly_scoped:Opus"),
            ]),
            snapshot(.codex, "codex@example.test", provider: "openai-codex", usage: [
                metric("codex · 5 hour limit", used: 1, resetsAt: now.addingTimeInterval(-60), id: "codex:primary"),
                metric("codex · 7 day limit", used: nil, resetsAt: nil, id: "codex:secondary"),
            ]),
        ])
        // Saved Claude accounts: one read three hours ago while Yardlet was in Korean with the same
        // name at another domain, one in a team's organization with both windows, one never read. A
        // saved Codex account beside Codex's default login.
        func home() -> URL { FileManager.default.temporaryDirectory.appending(path: "menu-bar-tests-\(UUID().uuidString)") }
        let work = try store.add(name: "Work", harness: .claudeCode, home: home())
        store.publish(snapshot(.claudeCode, "jordan@work.test", provider: "anthropic", usage: [
            metric("5시간 한도", used: 0.9, resetsAt: reset, id: "claude:five_hour:"),
        ], organization: "jordan@work.test's Organization", checkedAt: now.addingTimeInterval(-3 * 60 * 60)), for: work)
        let spare = try store.add(name: "Spare", harness: .claudeCode, home: home())
        store.publish(snapshot(.claudeCode, "spare@example.test", provider: "anthropic", usage: [
            metric("7일 한도", used: 0.5, resetsAt: nil, id: "claude:seven_day:"),
            metric("5 hour limit", used: 0.05, resetsAt: reset, id: "claude:session:"),
        ], organization: "Example Team"), for: spare)
        _ = try store.add(name: "Unchecked", harness: .claudeCode, home: home())
        let otherCodex = try store.add(name: "Other", harness: .codex, home: home())
        store.publish(snapshot(.codex, "other@example.test", provider: "openai-codex", usage: [
            metric("codex · 5 hour limit", used: 0.1, resetsAt: nil, id: "codex:primary"),
        ]), for: otherCodex)

        let english = Locale(identifier: "en_GB"), utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        func usage() -> [MenuBarMenu.UsageAccount] {
            MenuBarMenuProjection.usage(choices: store.menuBarUsageChoices(for: [.codex, .claudeCode, .openCode]),
                                        now: now, locale: english, timeZone: utc)
        }
        let hours = L10n.string("5h"), week = L10n.string("Weekly")
        func left(_ percent: Int64) -> String { L10n.format("%lld%% left", percent) }
        // Each account in full, a team's organization after it (a personal one only repeats the
        // address). Under it the harness in words, what is left of the five-hour window, then of the
        // weekly one when it has one ("–" without a figure), and the age of a reading an hour old.
        XCTAssertEqual(usage().map(\.line), [
            "codex@example.test", "other@example.test", "jordan@example.test", "jordan@work.test",
            "spare@example.test (Example Team)",
        ])
        XCTAssertEqual(usage().map(\.detail), [
            "Codex · \(hours) \(left(0)) · \(week) –",
            "Codex · \(hours) \(left(90))",
            "Claude Code · \(hours) \(left(72)) · \(week) \(left(40))",
            "Claude Code · \(hours) \(left(10)) · "
                + MenuBarMenuProjection.age(of: now.addingTimeInterval(-3 * 60 * 60), now: now, locale: english),
            "Claude Code · \(hours) \(left(95)) · \(week) \(left(50))",
        ])
        XCTAssertEqual(usage().map(\.harness), [.codex, .codex, .claudeCode, .claudeCode, .claudeCode])
        // The help has the account in full and every window with its reset, Codex's tray words: the
        // time within a day, the date beyond, "now" once passed.
        XCTAssertEqual(usage()[2].help, """
            jordan@example.test · Claude Code
            5 hour limit 72% · 15:40
            7 day limit 40% · 20 Oct
            Opus · 7 day limit 10%
            """)
        XCTAssertEqual(usage()[0].help, "codex@example.test · Codex\ncodex · 5 hour limit 0% · now\ncodex · 7 day limit –")

        // Every account is listed whichever one new tasks start on, as the person moves between
        // accounts by what is left of each, for Codex as for Claude.
        store.selection[.codex] = otherCodex.id
        XCTAssertEqual(Array(usage().map(\.line).prefix(2)), ["codex@example.test", "other@example.test"])

        // An account without limits is left out.
        store.publishDefaults([snapshot(.claudeCode, "jordan@example.test", provider: "anthropic", usage: [])])
        XCTAssertFalse(usage().map(\.line).contains("jordan@example.test"))
        XCTAssertEqual(Array(usage().map(\.line).suffix(2)), ["jordan@work.test", "spare@example.test (Example Team)"])
    }

    func testTheSameAccountUnderTwoHarnessesShowsOnceAndOtherWindowsKeepTheirNames() {
        let store = ProviderConnectionStore()
        let limits = [metric("5 hour limit", used: 0.5, resetsAt: nil)]
        store.publishDefaults([
            snapshot(.codex, "same@example.test", provider: "openai-codex", usage: limits),
            snapshot(.openCode, "same@example.test", provider: "openai-codex", usage: limits),
            snapshot(.museCode, "muse@example.test", provider: "muse", usage: [metric("Primary limit", used: 0.25, resetsAt: nil)]),
        ])
        let usage = MenuBarMenuProjection.usage(
            choices: store.menuBarUsageChoices(for: [.codex, .openCode, .museCode]), now: now)
        XCTAssertEqual(usage, [
            MenuBarMenu.UsageAccount(harness: .codex, line: "same@example.test",
                                     help: "same@example.test · Codex, OpenCode\n5 hour limit 50%",
                                     detail: "Codex, OpenCode · \(L10n.string("5h")) \(L10n.format("%lld%% left", 50))"),
            MenuBarMenu.UsageAccount(harness: .museCode, line: "muse@example.test",
                                     help: "muse@example.test · Muse Code\nPrimary limit 75%",
                                     detail: "Muse Code · Primary limit \(L10n.format("%lld%% left", 75))"),
        ])
    }

    // MARK: - The menu's items

    func testTheMenuIsBuiltOnlyWhenItOpens() {
        var reads = 0
        let controller = MenuBarMenuController(content: { reads += 1; return .empty }, actions: .init())
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(controller.buildCount, 0)
        XCTAssertTrue(controller.menu.items.isEmpty)

        controller.menuNeedsUpdate(controller.menu)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(controller.buildCount, 1)
        // With nothing to list, the Codex menu's end alone: New Chat, Open and Quit.
        XCTAssertEqual(describe(controller.menu.items), [newTask, "—", openYardlet, "—", quitYardlet])
    }

    func testOpeningTheMenuChecksTheAccountsItsUsageShowsAndTheOpenMenuTakesTheAnswers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "menu-bar-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let connectionsURL = root.appending(path: "provider-connections.json")
        let cacheURL = root.appending(path: ProviderConnectionStore.snapshotCacheFileName)
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        // An earlier run read Codex's default login two days ago and a saved Claude account three
        // hours ago; another saved account and Claude's default login have no limits to show.
        let earlier = ProviderConnectionStore(fileURL: connectionsURL, snapshotCacheURL: cacheURL)
        earlier.publishDefaults([
            snapshot(.codex, "codex@example.test", provider: "openai-codex",
                     usage: [metric("5 hour limit", used: 0.2, resetsAt: nil)], checkedAt: twoDaysAgo),
            HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil, state: .signedOut,
                accountLabel: nil, detail: "", credentialOwner: "", checkedAt: twoDaysAgo, usage: [],
                canLogin: true, canLogout: false),
        ])
        let work = try earlier.add(name: "Work", harness: .claudeCode, home: root.appending(path: "work"))
        earlier.publish(snapshot(.claudeCode, "jordan@work.test", provider: "anthropic",
            usage: [metric("5 hour limit", used: 0.5, resetsAt: nil)], checkedAt: Date().addingTimeInterval(-3 * 60 * 60)),
            for: work)
        _ = try earlier.add(name: "Unchecked", harness: .claudeCode, home: root.appending(path: "unchecked"))

        // Codex's check cannot finish this time; the saved account answers with what is left now.
        let reads = MenuBarReadLog()
        let store = ProviderConnectionStore(fileURL: connectionsURL, snapshotCacheURL: cacheURL,
            defaultLoader: { descriptor, _ in
                await reads.add(descriptor.id.rawValue)
                return HarnessAccountSnapshot(id: descriptor.id.rawValue, harness: descriptor.id, providerID: nil,
                    state: .unknown, accountLabel: nil, detail: "", credentialOwner: "", checkedAt: Date(),
                    usage: [], canLogin: false, canLogout: false)
            },
            connectionLoader: { connection, _ in
                await reads.add(connection.name)
                return HarnessAccountSnapshot(id: connection.id, harness: .claudeCode, providerID: "anthropic",
                    state: .signedIn, accountLabel: "jordan@work.test", detail: "", credentialOwner: "",
                    checkedAt: Date(), usage: [AccountUsageMetric(id: "5 hour limit", label: "5 hour limit",
                        usedFraction: 0.75, detail: "", resetsAt: nil, evidence: .exactQuota)],
                    canLogin: false, canLogout: false)
            })
        let runtime = RuntimeSelectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("MenuBarUsage"))),
                                            discoversRuntimes: false, loadsPersistedSelections: false)
        let controller = MenuBarMenuController(content: { MenuBarMenu(usage: store.usageLines()) }, actions: .init(),
            checkUsage: { await store.checkUsageAccounts(runtimeSelections: runtime) })
        let hours = L10n.string("5h")
        func left(_ percent: Int64) -> String { L10n.format("%lld%% left", percent) }
        func usageItems() -> [NSMenuItem] { controller.menu.items.filter { !$0.isSeparatorItem && !$0.isSectionHeader && $0.action == nil } }

        // Nothing is checked until the menu opens; it opens on the readings it has, each with its age.
        try await Task.sleep(for: .milliseconds(50))
        let unread = await reads.keys
        XCTAssertEqual(unread, [])
        controller.menuNeedsUpdate(controller.menu)
        controller.menuWillOpen(controller.menu)
        let shown = usageItems()
        let opening = "Codex · \(hours) \(left(80)) · " + MenuBarMenuProjection.age(of: twoDaysAgo, now: Date(), locale: .current)
        XCTAssertEqual(shown.map(\.title), ["codex@example.test", "jordan@work.test"])
        XCTAssertEqual(shown[0].subtitle, opening)

        // The accounts its lines show are checked, the others are not; the open menu's own items take
        // the answers: Codex's line says its check failed beside the reading it still shows.
        try await waitUntil { usageItems().first?.subtitle != opening }
        let checked = await reads.keys
        XCTAssertEqual(Set(checked), ["codex", "Work"])
        XCTAssertEqual(store.readingStatus[AccountChoice.nativeID(for: .codex)], .checkFailed)
        XCTAssertTrue(usageItems()[0] === shown[0], "Updated in place, not replaced under the pointer")
        XCTAssertEqual(usageItems()[0].subtitle, "Codex · \(hours) \(left(80)) · \(L10n.string("Couldn't refresh")) · "
            + MenuBarMenuProjection.age(of: twoDaysAgo, now: Date(), locale: .current))
        XCTAssertEqual(usageItems()[1].subtitle, "Claude Code · \(hours) \(left(25))")
    }


    func testItemsShowEachSectionThenUsageThenNewTaskOpenAndQuit() throws {
        let states: [SidebarTaskStatus?] = [.awaitingApproval, .needsInput, .running, nil, .unread]
        let rows = (0..<5).map {
            MenuBarMenu.TaskRow(sessionID: UUID(), title: "Task \($0)", subtitle: "Yardlet", status: states[$0])
        }
        let menu = MenuBarMenu(
            sections: [
                MenuBarMenu.Section(kind: .running, rows: Array(rows.prefix(3)), more: Array(rows.dropFirst(3))),
                MenuBarMenu.Section(kind: .recent, rows: [rows[0]], more: []),
            ],
            usage: [MenuBarMenu.UsageAccount(harness: .claudeCode, line: "jordan@example.test",
                                             help: "jordan@example.test · Claude Code\n5 hour limit 72% · 15:40",
                                             detail: "Claude Code · 5h 72% left · Weekly 40% left")])
        let controller = MenuBarMenuController(content: { menu }, actions: .init())
        let items = controller.items(for: menu)
        XCTAssertEqual(describe(items), [
            "[\(L10n.string("Running"))]", "Task 0 / Yardlet", "Task 1 / Yardlet", "Task 2 / Yardlet",
            "\(L10n.string("More")) ▸ Task 3, Task 4",
            "—", "[\(L10n.string("Recent"))]", "Task 0 / Yardlet",
            "—", "[\(L10n.string("Usage"))]", "(jordan@example.test / Claude Code · 5h 72% left · Weekly 40% left)",
            "—", newTask, "—", openYardlet, "—", quitYardlet,
        ])
        XCTAssertEqual(items[1].representedObject as? UUID, rows[0].sessionID)

        // A task row starts with the sidebar's mark, in colour, its state the accessibility description;
        // a task with no state keeps an empty mark so the titles line up.
        let taskRows = items.filter { $0.representedObject is UUID }
            + (items.first { $0.submenu != nil }?.submenu?.items ?? [])
        for item in taskRows {
            let status = rows.first { $0.sessionID == item.representedObject as? UUID }?.status
            let image = try XCTUnwrap(item.image)
            XCTAssertFalse(image.isTemplate)
            XCTAssertEqual(image.size, NSSize(width: 14, height: 14))
            XCTAssertEqual(image.accessibilityDescription, status?.accessibilityName)
            XCTAssertEqual(item.accessibilityLabel(),
                           ([item.title, "Yardlet"] + [status?.accessibilityName].compactMap { $0 }).joined(separator: ", "))
        }
        XCTAssertEqual(items[1].accessibilityLabel(), "Task 0, Yardlet, \(L10n.string("Awaiting input"))")
        XCTAssertEqual(items[2].accessibilityLabel(), "Task 1, Yardlet, \(L10n.string("Awaiting answer"))")
        XCTAssertEqual(items[3].accessibilityLabel(), "Task 2, Yardlet, \(L10n.string("Running"))")
        // An account line shows its harness's mark and keeps the windows' resets in its help.
        let account = try XCTUnwrap(items.first { $0.title.hasPrefix("jordan") })
        XCTAssertEqual(account.toolTip, "jordan@example.test · Claude Code\n5 hour limit 72% · 15:40")
        XCTAssertEqual(account.image?.accessibilityDescription, "Claude Code")
        // Every item to choose answers to the controller, the More submenu's tasks too.
        let chosen = items.filter { $0.target === controller }
        XCTAssertEqual(chosen.map(\.title), ["Task 0", "Task 1", "Task 2", "Task 0", newTask, openYardlet, quitYardlet])
        XCTAssertTrue(chosen.allSatisfy { $0.action != nil })
        let more = try XCTUnwrap(items.first { $0.submenu != nil }?.submenu?.items)
        XCTAssertEqual(more.map { $0.representedObject as? UUID }, rows.suffix(2).map(\.sessionID))
        XCTAssertTrue(more.allSatisfy { $0.target === controller && $0.action != nil })
    }

    /// A staged build ready to install adds "Restart to update" before Quit, which goes where Install
    /// Update… goes; while the update waits for tasks the line is dimmed and does nothing.
    func testAStagedBuildAddsRestartToUpdateBeforeQuit() throws {
        var installs = 0
        var actions = MenuBarMenuController.Actions()
        actions.installUpdate = { installs += 1 }
        let controller = MenuBarMenuController(content: { .empty }, actions: actions)
        var menu = MenuBarMenu.empty
        menu.update = .ready(build: "abc1234")
        let items = controller.items(for: menu)
        let restart = L10n.string("Restart to update")
        XCTAssertEqual(describe(items), [newTask, "—", openYardlet, "—", restart, quitYardlet])
        let line = try XCTUnwrap(items.first { $0.title == restart })
        XCTAssertEqual(line.toolTip, "\(restart) · abc1234")
        controller.chooseInstallUpdate(line)
        XCTAssertEqual(installs, 1)

        menu.update = .waiting
        XCTAssertEqual(describe(controller.items(for: menu)),
                       [newTask, "—", openYardlet, "—", "(\(L10n.string("Waiting to Update")))", quitYardlet])
    }

    // MARK: - Choosing an item

    func testChoosingATaskOpensItAsANotificationClickDoesSplitPaneIncluded() async throws {
        let left = task("Left", minutesAgo: 1), right = task("Right", minutesAgo: 2), other = task("Other", minutesAgo: 3)
        let (model, attention) = makeModel(sessions: [left, right, other])
        model.splits.activate(.session(left.id))
        model.splits.split(.right, placing: right.id)
        let split = try XCTUnwrap(model.splits.activeSplit)
        model.splits.activate(.session(other.id))
        let controller = MenuBarMenuController(content: { model.menuBarMenu(now: self.now) }, actions: .routing(to: model))
        controller.rebuild()

        let item = try XCTUnwrap(taskItems(controller.menu.items).first { ($0.representedObject as? UUID) == left.id })
        controller.chooseTask(item)
        try await waitUntil { model.splits.selection == .split(split.id) }

        XCTAssertEqual(model.splits.focusedSessionID, left.id)
        XCTAssertEqual(model.store.selectedSessionID, left.id)
        XCTAssertEqual(attention.bringForwardCount, 1)
    }

    func testChoosingATaskArchivedSinceTheMenuOpenedShowsTheArchivedTasks() async throws {
        let kept = task("Kept", minutesAgo: 1), archived = task("Archived", minutesAgo: 2)
        let (model, attention) = makeModel(sessions: [kept, archived])
        model.splits.activate(.session(kept.id))
        let controller = MenuBarMenuController(content: { model.menuBarMenu(now: self.now) }, actions: .routing(to: model))
        controller.rebuild()
        try await model.store.archiveSession(id: archived.id)

        let item = try XCTUnwrap(taskItems(controller.menu.items).first { ($0.representedObject as? UUID) == archived.id })
        controller.chooseTask(item)
        try await waitUntil { model.archivedTasksRevealRequest == 1 }
        XCTAssertEqual(model.splits.selection, .session(kept.id))
        XCTAssertEqual(attention.bringForwardCount, 1)
    }

    func testNewTaskAndOpenBringYardletForward() throws {
        let first = task("First", minutesAgo: 1)
        let (model, attention) = makeModel(sessions: [first])
        model.splits.activate(.session(first.id))
        let controller = MenuBarMenuController(content: { model.menuBarMenu(now: self.now) }, actions: .routing(to: model))
        controller.rebuild()
        let items = controller.menu.items

        controller.chooseOpenApp(try XCTUnwrap(items.first { $0.title == openYardlet }))
        XCTAssertEqual(attention.bringForwardCount, 1)
        XCTAssertEqual(model.splits.selection, .session(first.id))

        controller.chooseNewTask(try XCTUnwrap(items.first { $0.title == newTask }))
        XCTAssertEqual(attention.bringForwardCount, 2)
        XCTAssertEqual(model.splits.selection, .home)
    }

    func testOpenRemoteHostTasksNeedingThePersonShowInTheMenuBarAndBringTheirHostWindowForward() async throws {
        typealias ID = RemoteFixtureBridge.ID
        let localWorking = task("Local build", status: .running, minutesAgo: 1)
        let (model, attention) = makeModel(sessions: [localWorking])
        model.projects.rename(model.projects.ensureProject(forRoot: yardlet).id, to: "Yardlet")

        let stack = try await LoopbackStack(name: "Mac Studio", bridge: RemoteFixtureBridge(speed: 0.01))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                        name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let directory = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        var openedHostWindows: [String] = []
        directory.openHostWindow = { openedHostWindows.append($0) }
        model.followRemoteHosts(directory)
        let paired = try await directory.pair(link: link.absoluteString)
        let host = try XCTUnwrap(directory.model(for: paired.id))
        try await waitUntil { host.hasSnapshot }

        let controller = MenuBarMenuController(content: { model.menuBarMenu(now: self.now) }, actions: .routing(to: model))
        controller.rebuild()
        let menu = model.menuBarMenu(now: now)
        let running = try XCTUnwrap(menu.sections.first { $0.kind == .running })
        let unread = try XCTUnwrap(menu.sections.first { $0.kind == .unread })
        let runningRows = running.rows + running.more
        let unreadRows = unread.rows + unread.more

        // Waiting remote tasks appear in Running before local working tasks, labeled with the host's name.
        XCTAssertTrue(runningRows.contains {
            $0.remoteTask == RemoteTaskReveal(hostID: paired.id, taskID: ID.approval)
                && $0.subtitle == "Mac Studio · Yardlet"
                && $0.status == .awaitingApproval
        }, runningRows.description)
        XCTAssertTrue(runningRows.contains { $0.sessionID == localWorking.id && $0.subtitle == "Yardlet" })
        // Remote working (not waiting) tasks do not clutter Running.
        XCTAssertFalse(runningRows.contains { $0.remoteTask?.taskID == ID.streaming })

        // Unread remote tasks appear in Unread, labeled with the host's name.
        XCTAssertTrue(unreadRows.contains {
            $0.remoteTask == RemoteTaskReveal(hostID: paired.id, taskID: ID.history)
                && $0.subtitle == "Mac Studio · Website"
                && $0.status == .unread
        }, unreadRows.description)

        // Choosing a remote task brings Yardlet forward, opens that host's window, and selects the task.
        let allItems = controller.menu.items.flatMap { [$0] + ($0.submenu?.items ?? []) }
        let approvalItem = try XCTUnwrap(allItems.first {
            ($0.representedObject as? RemoteTaskReveal) == RemoteTaskReveal(hostID: paired.id, taskID: ID.approval)
        })
        controller.chooseTask(approvalItem)
        try await waitUntil { host.selection == .task(ID.approval) }
        XCTAssertEqual(openedHostWindows, [paired.id])
        XCTAssertEqual(attention.bringForwardCount, 1)

        // Two hosts with the same display name ("Mac Studio") match their own NSWindow by host ID, not by title.
        let secondStack = try await LoopbackStack(name: "Mac Studio", bridge: RemoteFixtureBridge(speed: 0.01))
        defer { secondStack.stop() }
        let secondTicket = await secondStack.server.openPairing()
        let secondLink = try XCTUnwrap(RemoteSecurePairingURL(
            macKey: secondStack.identity.noise.publicKey, secret: secondTicket.secret,
            name: "Mac Studio", hosts: ["127.0.0.1:\(secondStack.port)"]).url)
        let secondPaired = try await directory.pair(link: secondLink.absoluteString)
        let windowOne = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        windowOne.isReleasedWhenClosed = false
        windowOne.title = "Mac Studio"
        windowOne.orderBack(nil)
        let windowTwo = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        windowTwo.isReleasedWhenClosed = false
        windowTwo.title = "Mac Studio"
        windowTwo.orderBack(nil)
        RemoteHostWindow.register(window: windowOne, forHostID: paired.id)
        RemoteHostWindow.register(window: windowTwo, forHostID: secondPaired.id)
        defer {
            windowOne.close()
            windowTwo.close()
            RemoteHostWindow.unregister(window: windowOne, forHostID: paired.id)
            RemoteHostWindow.unregister(window: windowTwo, forHostID: secondPaired.id)
        }
        XCTAssertTrue(RemoteHostWindow.bringForward(hostID: paired.id) === windowOne)
        XCTAssertTrue(RemoteHostWindow.bringForward(hostID: secondPaired.id) === windowTwo)

        // Closing a host window unregisters it, and bringForward ignores a window that is neither visible nor miniaturized.
        windowOne.close()
        XCTAssertNil(RemoteHostWindow.bringForward(hostID: paired.id))
        RemoteHostWindow.register(window: windowOne, forHostID: paired.id)
        XCTAssertNil(RemoteHostWindow.bringForward(hostID: paired.id))

        // Disconnecting a host removes its tasks from the menu bar menu even while its window stays open.
        stack.stop()
        try await waitUntil { !host.isConnected }
        let afterDisconnect = model.menuBarMenu(now: now)
        XCTAssertNil(afterDisconnect.sections.first { $0.kind == .unread })
        XCTAssertEqual(afterDisconnect.sections.first { $0.kind == .running }?.rows.map(\.sessionID), [localWorking.id])

        // Closing the host window keeps its tasks out of the menu bar menu.
        directory.close(paired.id)
        let afterClose = model.menuBarMenu(now: now)
        XCTAssertNil(afterClose.sections.first { $0.kind == .unread })
        XCTAssertEqual(afterClose.sections.first { $0.kind == .running }?.rows.map(\.sessionID), [localWorking.id])
    }

    // MARK: - Setting and shortcut

    func testShowInMenuBarIsOnUntilTurnedOff() throws {
        let suite = testDefaultsSuite("MenuBarMenuTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(MenuBarPreference.isShown(in: defaults))
        defaults.set(false, forKey: MenuBarPreference.key)
        XCTAssertFalse(MenuBarPreference.isShown(in: defaults))
        defaults.set(true, forKey: MenuBarPreference.key)
        XCTAssertTrue(MenuBarPreference.isShown(in: defaults))
        XCTAssertEqual(L10n.string("Show in menu bar", languageCode: "ko"), "메뉴 막대에 표시")
    }

    func testToggleActivityViewIsOptionCommandUAndClashesWithNoOtherShortcut() {
        XCTAssertEqual(key(TaskCommandShortcut.toggleActivityView), key(KeyboardShortcut("u", modifiers: [.command, .option])))
        XCTAssertEqual(L10n.string("Toggle activity view", languageCode: "en"), "Toggle activity view")
        XCTAssertEqual(L10n.string("Toggle activity view", languageCode: "ko"), "활동 보기 전환")

        // Every other shortcut the menu bar and the window bind (Settings, the command palette, New
        // task, Find, Split View, pinned rows, the task surfaces).
        var others: [KeyboardShortcut] = [
            KeyboardShortcut(",", modifiers: .command), KeyboardShortcut("k", modifiers: .command),
            KeyboardShortcut("n", modifiers: .command), KeyboardShortcut("f", modifiers: .command),
            KeyboardShortcut("g", modifiers: .command), KeyboardShortcut("g", modifiers: [.command, .shift]),
            KeyboardShortcut("d", modifiers: [.command, .shift]), KeyboardShortcut("d", modifiers: [.command, .shift, .option]),
            KeyboardShortcut("w", modifiers: [.command, .control]),
            // The terminal's second key (`TerminalToggleKey`).
            KeyboardShortcut("`", modifiers: .control),
        ]
        others += PaneFocusDirection.allCases.map {
            KeyboardShortcut(SplitCommandTitle.focusShortcut($0), modifiers: [.command, .option])
        }
        others += (1...9).map { KeyboardShortcut(KeyEquivalent(Character(String($0))), modifiers: .control) }
        others += TaskSurface.allCases.map { KeyboardShortcut($0.keyboardShortcut, modifiers: .command) }
        let all = (TaskCommandShortcut.all + others).map(key)
        XCTAssertEqual(Set(all).count, all.count, "A shortcut is bound twice: \(all)")
    }

    // MARK: - Helpers

    private var newTask: String { L10n.string("New task") }
    private var openYardlet: String { L10n.format("Open %@", "Yardlet") }
    private var quitYardlet: String { L10n.format("Quit %@", "Yardlet") }

    private func key(_ shortcut: KeyboardShortcut) -> String {
        "\(shortcut.key.character)|\(shortcut.modifiers.rawValue)"
    }

    private func snapshot(_ harness: HarnessKind, _ label: String, provider: String,
                          usage: [AccountUsageMetric], organization: String? = nil,
                          checkedAt: Date? = nil) -> HarnessAccountSnapshot {
        HarnessAccountSnapshot(id: "\(harness.rawValue):\(label)", harness: harness, providerID: provider, state: .signedIn,
                               accountLabel: label, accountOrganization: organization, detail: "",
                               credentialOwner: harness.displayName, checkedAt: checkedAt ?? now,
                               usage: usage, canLogin: false, canLogout: false)
    }

    private func metric(_ label: String, used: Double?, resetsAt: Date?, id: String? = nil) -> AccountUsageMetric {
        AccountUsageMetric(id: id ?? label, label: label, usedFraction: used, detail: "", resetsAt: resetsAt,
                           evidence: .exactQuota)
    }

    private func makeModel(sessions: [SessionRecord], chatHome: URL? = nil) -> (AppModel, MenuBarRecordingAttention) {
        let attention = MenuBarRecordingAttention()
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(
                defaults: UserDefaults(suiteName: testDefaultsSuite("MenuBarMenuTests"))!),
            chatWorkspaceHome: chatHome ?? URL(filePath: "/tmp/menu-bar-tests/home", directoryHint: .isDirectory),
            systemNotificationCenter: MenuBarQuietNotificationCenter(),
            applicationAttention: attention,
            restoresIndexOnLaunch: false
        )
        return (model, attention)
    }

    private func taskItems(_ items: [NSMenuItem]) -> [NSMenuItem] {
        items.flatMap { item in [item] + (item.submenu.map { taskItems($0.items) } ?? []) }
            .filter { $0.representedObject is UUID }
    }

    /// One line per item: `—` a separator, `[Header]` a section header, `(…)` a line to read only,
    /// `title / subtitle`, and `More ▸ …` with the submenu's titles; indentation as two spaces.
    private func describe(_ items: [NSMenuItem]) -> [String] {
        items.map { item in
            if item.isSeparatorItem { return "—" }
            if item.isSectionHeader { return "[\(item.title)]" }
            var text = String(repeating: "  ", count: item.indentationLevel) + item.title
            if let subtitle = item.subtitle { text += " / \(subtitle)" }
            if let submenu = item.submenu { text += " ▸ " + submenu.items.map(\.title).joined(separator: ", ") }
            return item.isEnabled ? text : "(\(text))"
        }
    }
}

private actor MenuBarReadLog {
    private(set) var keys: [String] = []
    func add(_ key: String) { keys.append(key) }
}

/// Records activation; never brings anything forward.
@MainActor
final class MenuBarRecordingAttention: ApplicationAttention {
    var isActive = true
    private(set) var bringForwardCount = 0

    func setDockBadge(_ label: String?) {}
    func requestAttention() {}
    func bringForward() { bringForwardCount += 1 }
}

final class MenuBarQuietNotificationCenter: SystemNotificationCenter {
    func authorization() async -> SystemNotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(title: String, body: String, identifier: String) async {}
}
