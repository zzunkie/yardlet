import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The sidebar's shell as the person asked for it on 2026-10-16: one account button at the bottom
/// whose menu holds Settings and the other app-wide places, projects as faint labels over tasks
/// listed flush under them, and a width the person sets by dragging the line, kept across launches.
/// Renders go to `.build/sidebar-ui-qa`, light and dark, in unshown windows. No provider, process,
/// account or user data.
///
/// - `sidebar-240-*.png`, `sidebar-360-*.png`: the same sidebar at the standard width and wider,
///   beside the line and a strip of the window's content: Pinned, Chats, three projects (one with a
///   family of nested tasks and "Show more", one collapsed with a waiting task's mark, one empty
///   with "No chats"), pull request glyphs, and the account button.
/// - `sidebar-520-*.png`: the widest the line goes.
/// - `sidebar-update-240-*.png`: the standard width with a staged build ready to install, "Restart to
///   update" over the account button.
/// - `account-button-*.png`: the button alone, at rest and hovered, under the update strip at rest,
///   hovered and while the update waits for tasks.
@MainActor
final class SidebarShellTests: XCTestCase {
    private static let identity = SidebarAccountIdentity(fullName: "Alex Kim", userName: "alex")
    private let now = Date()

    // MARK: - Account button and menu

    /// The button names the person signed in to this Mac: the full name, else the user name, else
    /// "Settings" as the Codex app's footer does without a profile; the mark is the first letter.
    func testTheAccountButtonNamesThePersonOnThisMac() {
        let full = SidebarAccountIdentity(fullName: "  Alex Kim ", userName: "alex")
        XCTAssertEqual(full.name, "Alex Kim")
        XCTAssertEqual(full.initial, "A")
        let short = SidebarAccountIdentity(fullName: "", userName: "zoe")
        XCTAssertEqual(short.name, "zoe")
        XCTAssertEqual(short.initial, "Z")
        XCTAssertEqual(SidebarAccountIdentity(fullName: "홍길동", userName: "x").initial, "홍")
        let none = SidebarAccountIdentity(fullName: nil, userName: " ")
        XCTAssertEqual(none.name, L10n.string("Settings"))
        XCTAssertEqual(none.initial, "")
        // A test run (and a visual fixture) names a made-up person, so no render shows whose Mac drew it.
        XCTAssertEqual(SidebarAccountIdentity.current(), .fixture)
    }

    private static let usage = [
        MenuBarMenu.UsageAccount(harness: .claudeCode, line: "work@example.com",
                                 help: "work@example.com · Claude Code\n5 hour limit 80% · 15:40",
                                 detail: "Claude Code · 5h 80% left · Weekly 61% left"),
        MenuBarMenu.UsageAccount(harness: .codex, line: "alex@example.com", help: "alex@example.com · Codex",
                                 detail: "Codex · 5h 97% left"),
    ]

    /// Settings with ⌘, first, as both apps' menus have it; then the Settings sections reached from
    /// elsewhere (Accounts, which the old footer row opened, Connectors, Remote, Harnesses), each
    /// account's usage, Archived tasks (the other old footer row), Task Resource Usage, the two
    /// imports and Install Update. Only Settings has a shortcut, the app menu's own.
    func testTheAccountMenuHoldsEveryAppWidePlaceWithItsShortcut() throws {
        let menu = SidebarAccountMenu.make(
            identity: Self.identity,
            settingsSections: SettingsSection.available(hasAccounts: true, hasConnectors: true, hasRemote: true),
            usage: Self.usage)
        XCTAssertEqual(menu.items.map(\.destination), [
            .settings, .settingsSection(.accounts), .settingsSection(.connectors), .settingsSection(.remote),
            .settingsSection(.harnesses), .accountUsage(.claudeCode), .accountUsage(.codex), .archivedTasks,
            .taskResourceUsage, .importConversation, .importFromOtherApps, .refreshFromOtherApps, .installUpdate,
        ])
        XCTAssertEqual(menu.items.map(\.title), [
            L10n.string("Settings…"), L10n.string("Accounts"), L10n.string("Connectors"), L10n.string("Remote"),
            L10n.string("Harnesses"), Self.usage[0].line, Self.usage[1].line, L10n.string("Archived tasks"),
            L10n.string("Task Resource Usage"), L10n.string("Import conversation…"),
            L10n.string("Import Conversations from Other Apps…"), L10n.string("Refresh from the Claude App and Codex"),
            L10n.string("Install Update…"),
        ])
        XCTAssertEqual(menu.sections.map(\.title), [nil, L10n.string("Usage"), nil, nil, nil])
        let settings = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(settings.shortcut?.key, YardletAppShortcut.settings.key)
        XCTAssertEqual(settings.shortcut?.modifiers, .command)
        XCTAssertEqual(YardletAppShortcut.settings.key, ",")
        XCTAssertEqual(menu.items.filter { $0.shortcut != nil }.map(\.destination), [.settings])
        XCTAssertEqual(menu.items[5].help, Self.usage[0].help)
        XCTAssertEqual(menu.items[5].harness, .claudeCode)

        // A window without Connectors or Remote leaves them out, and without readings there is no
        // Usage heading but one Usage item, which opens the accounts with their usage. Every place
        // is still there.
        let bare = SidebarAccountMenu.make(
            identity: Self.identity, settingsSections: SettingsSection.available(hasAccounts: true, hasConnectors: false))
        XCTAssertEqual(bare.items.map(\.destination), [
            .settings, .settingsSection(.accounts), .settingsSection(.harnesses), .usage, .archivedTasks,
            .taskResourceUsage, .importConversation, .importFromOtherApps, .refreshFromOtherApps, .installUpdate,
        ])
        XCTAssertEqual(bare.items[3].title, L10n.string("Usage"))
        XCTAssertNotNil(bare.items[3].systemName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) })
        XCTAssertEqual(bare.sections.compactMap(\.title), [])
        let bareMenu = SidebarAccountMenuController(content: bare) { _ in }.menu
        XCTAssertTrue(bareMenu.items.filter { $0.action != nil }.allSatisfy { $0.image != nil })

        // The places the person asked the menu to hold, whatever the window offers: Settings ⌘,,
        // the accounts, archived tasks, connectors, remote, usage and updates.
        for menu in [menu, bare] {
            let destinations = Set(menu.items.map(\.destination))
            XCTAssertTrue(destinations.isSuperset(of: [.settings, .settingsSection(.accounts), .archivedTasks,
                                                       .installUpdate]))
            XCTAssertTrue(destinations.contains(.usage)
                || destinations.contains { if case .accountUsage = $0 { true } else { false } })
        }
        XCTAssertTrue(Set(menu.items.map(\.destination)).isSuperset(of: [.settingsSection(.connectors),
                                                                          .settingsSection(.remote)]))
    }

    /// The menu AppKit shows: the person's name as its heading, Settings with ⌘, as in the app
    /// menu, a Usage heading with each harness's mark, and every item calling back with its place.
    func testTheAccountMenuIsAnAppKitMenuThatOpensEachPlace() throws {
        let menu = SidebarAccountMenu.make(
            identity: Self.identity,
            settingsSections: SettingsSection.available(hasAccounts: true, hasConnectors: true, hasRemote: true),
            usage: Self.usage)
        let chosen = Chosen()
        let controller = SidebarAccountMenuController(content: menu) { chosen.destinations.append($0) }
        let items = controller.menu.items
        XCTAssertTrue(items[0].isSectionHeader)
        XCTAssertEqual(items[0].title, "Alex Kim")
        XCTAssertTrue(items.contains { $0.isSectionHeader && $0.title == L10n.string("Usage") })
        let actionable = items.filter { $0.action != nil }
        XCTAssertEqual(actionable.map(\.title), menu.items.map(\.title))
        XCTAssertEqual(actionable.filter { !$0.keyEquivalent.isEmpty }.map(\.title), [L10n.string("Settings…")])
        let settings = try XCTUnwrap(actionable.first)
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
        XCTAssertTrue(actionable.allSatisfy { $0.image != nil && $0.isEnabled })
        XCTAssertEqual(actionable[5].toolTip, Self.usage[0].help)
        // A Usage line names its harness and what is left under the account, in the item's subtitle.
        XCTAssertEqual(actionable[5].subtitle, Self.usage[0].detail)
        for item in actionable { controller.choose(item) }
        for _ in 0..<50 where chosen.destinations.count < actionable.count {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(chosen.destinations, menu.items.map(\.destination))
    }

    // MARK: - Width

    /// The width stays between the Codex app's bounds (240 to 520), starts at Yardlet's 240, is
    /// kept across launches, and narrows in a narrow window so the content keeps a pane's minimum.
    func testTheSidebarWidthStaysInBoundsAndIsKeptAcrossLaunches() throws {
        XCTAssertEqual(SidebarWidth.standard, ParityTheme.sidebarWidth)
        XCTAssertEqual(SidebarWidth.clamped(100), 240)
        XCTAssertEqual(SidebarWidth.clamped(9_999), 520)
        XCTAssertEqual(SidebarWidth.clamped(333.4), 333)
        XCTAssertEqual(SidebarWidth.clamped(.nan), 240)
        XCTAssertEqual(SidebarWidth.clamped(-20), 240)

        let suite = testDefaultsSuite("SidebarShellTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(SidebarWidth.stored(in: defaults), 240, "Nothing set yet: the standard width")
        SidebarWidth.store(333.4, in: defaults)
        XCTAssertEqual(defaults.double(forKey: SidebarWidth.defaultsKey), 333)
        XCTAssertEqual(SidebarWidth.stored(in: defaults), 333, "What was set comes back at the next launch")
        SidebarWidth.store(9_999, in: defaults)
        XCTAssertEqual(SidebarWidth.stored(in: defaults), 520)
        defaults.set(100.0, forKey: SidebarWidth.defaultsKey)
        XCTAssertEqual(SidebarWidth.stored(in: defaults), 240, "A value out of bounds is brought back in")
        defaults.set("wide", forKey: SidebarWidth.defaultsKey)
        XCTAssertEqual(SidebarWidth.stored(in: defaults), 240, "A value that is not a width is the standard one")

        // The window's width follows a drag within bounds and is kept only once the drag ends.
        defaults.removeObject(forKey: SidebarWidth.defaultsKey)
        let state = SidebarWidthState(defaults: defaults)
        XCTAssertEqual(state.width, 240)
        state.resize(to: 9_999)
        XCTAssertEqual(state.width, 520)
        state.resize(to: 300)
        XCTAssertNil(defaults.object(forKey: SidebarWidth.defaultsKey), "Nothing is kept while dragging")
        state.commit()
        XCTAssertEqual(SidebarWidthState(defaults: defaults).width, 300, "The next launch starts where the drag ended")
        XCTAssertEqual(state.shown(inWindowWidth: 760), 300)
        XCTAssertEqual(state.shown(inWindowWidth: 600), 279, "600 - 1 - 320")

        // The window decides how much of the set width fits: 760 - 1 - 320 = 439.
        XCTAssertEqual(SidebarWidth.fitting(520, windowWidth: 760), 439)
        XCTAssertEqual(SidebarWidth.fitting(300, windowWidth: 760), 300)
        XCTAssertEqual(SidebarWidth.fitting(520, windowWidth: 1_400), 520)
        XCTAssertEqual(SidebarWidth.fitting(520, windowWidth: 400), 240, "Never below the sidebar's minimum")
        XCTAssertEqual(SidebarWidth.fitting(300, windowWidth: nil), 300)
        XCTAssertEqual(SidebarWidth.fitting(9_999, windowWidth: nil), 520)
    }

    // MARK: - Flat rows

    /// Rows under a project start where rows in Pinned start: the mark in the first 32 pt, nothing
    /// indented for the project (the Claude app's `--df-row-indent: 0`). A task started from another
    /// still sits one family indent in, its guide under the parent's mark. The projection that lists
    /// them is the one it was: the same sections, rows, families and keyboard order.
    func testRowsUnderAProjectStartWhereRowsInPinnedStartAndTheProjectionIsUnchanged() throws {
        let alpha = URL(filePath: "/tmp/sidebar-ui-qa/alpha", directoryHint: .isDirectory)
        let projects = ProjectStore(chatWorkspaceHome: URL(filePath: "/tmp/sidebar-ui-qa/home", directoryHint: .isDirectory))
        _ = projects.ensureProject(forRoot: alpha)
        let pinned = task("Pinned task", .codex, in: alpha, minutesAgo: 1, pinned: true)
        let parent = task("Parent task", .codex, in: alpha, minutesAgo: 4)
        let child = task("Child task", .codex, in: alpha, minutesAgo: 2, parent: parent)
        let plain = task("Project task", .codex, in: alpha, minutesAgo: 3)
        let groups = projects.visibleGroups(sessions: [pinned, parent, child, plain])
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false)
        XCTAssertEqual(layout.pinned.map(\.id), [.session(pinned.id)])
        XCTAssertEqual(layout.sections.map(\.group.displayName), ["alpha"])
        XCTAssertEqual(layout.sections[0].rows.map(\.id), [.session(parent.id), .session(plain.id)])
        XCTAssertEqual(layout.sections[0].rows[0].children.map(\.id), [.session(child.id)])
        XCTAssertEqual(layout.rows.map(\.id), [pinned, parent, child, plain].map { .session($0.id) })

        let size = NSSize(width: ParityTheme.sidebarWidth, height: 420)
        let view = sidebar(layout: layout, groups: groups, projects: projects, selection: .home)
            .frame(width: size.width, height: size.height, alignment: .top)
            .environment(\.colorScheme, .light)
        let capture = try WindowlessRender.hosted(view, size: size, appearance: .light)
        let bands = Self.contentBands(in: capture.bitmap, scale: capture.backingScaleFactor,
                                      from: 72, to: size.height - 46)
        // Pinned title, the pinned row, Projects title, the project's label, the parent row, the
        // child row, the plain row.
        XCTAssertEqual(bands.count, 7, "\(bands)")
        let childBand = try XCTUnwrap(bands.max { $0.minX < $1.minX })
        XCTAssertEqual(childBand.minX, SidebarMetrics.rowInset + SidebarRowLeading<EmptyView>.guideX(level: 1), accuracy: 1.5,
                       "The nested task's guide runs under its parent's mark: \(bands)")
        for band in bands where band != childBand {
            XCTAssertLessThanOrEqual(band.minX, SidebarMetrics.projectHeaderLeading + 1.5,
                                     "Nothing but the nested task is indented: \(bands)")
        }
        XCTAssertEqual(SidebarRowLeading<EmptyView>.titleLeading(), SidebarMetrics.gutterWidth)
        XCTAssertEqual(SidebarRowLeading<EmptyView>.titleLeading(nestingDepth: 1),
                       SidebarMetrics.gutterWidth + SidebarMetrics.familyIndent)
    }

    /// A horizontal stretch of the bitmap holding content, and where its leftmost content is, in
    /// points from the sidebar's left edge.
    private struct Band: Equatable, CustomStringConvertible {
        let top: CGFloat
        let bottom: CGFloat
        let minX: CGFloat
        var description: String { "\(Int(top))–\(Int(bottom)) @\(minX)" }
    }

    /// The stretches between `from` and `to` (points from the top) where something besides the
    /// background is drawn, split where a pixel row is blank.
    private static func contentBands(in bitmap: NSBitmapImageRep, scale: CGFloat, from: CGFloat, to: CGFloat) -> [Band] {
        guard let background = bitmap.colorAt(x: bitmap.pixelsWide - 2, y: Int(from * scale))?.usingColorSpace(.sRGB)
        else { return [] }
        func differs(_ x: Int, _ y: Int) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return max(abs(color.redComponent - background.redComponent),
                       abs(color.greenComponent - background.greenComponent),
                       abs(color.blueComponent - background.blueComponent)) > 0.12
        }
        var bands: [Band] = []
        var current: (top: Int, minX: Int)?
        for y in Int(from * scale)..<Int(to * scale) {
            let leftmost = (0..<bitmap.pixelsWide).first { differs($0, y) }
            if let leftmost {
                current = (current?.top ?? y, min(current?.minX ?? leftmost, leftmost))
            } else if let open = current {
                bands.append(Band(top: CGFloat(open.top) / scale, bottom: CGFloat(y) / scale,
                                  minX: CGFloat(open.minX) / scale))
                current = nil
            }
        }
        return bands
    }

    // MARK: - Renders

    func testTheSidebarRendersAtTwoWidthsWithProjectsFamiliesAndTheAccountButton() throws {
        let fixture = try Fixture(now: now)
        let directory = try WindowlessRender.directory("sidebar-ui-qa")
        for width: CGFloat in [240, 360, 520] {
            let size = NSSize(width: width + 1 + 140, height: 820)
            // The column the window lays out, at a width the person dragged to.
            let suite = testDefaultsSuite("SidebarShellTests")
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            SidebarWidth.store(width, in: defaults)
            let state = SidebarWidthState(defaults: defaults)
            let captures = try WindowlessRender.hostedInBothAppearances("sidebar-\(Int(width))", in: directory,
                                                                         size: size) { appearance in
                HStack(spacing: 0) {
                    SidebarColumn(state: state, windowWidth: nil) {
                        fixture.sidebar(accountMenu: SidebarAccountMenuContext(identity: Self.identity))
                    }
                    ParityTheme.canvas
                }
                // The window's content lies over the canvas, as in `MainWindow`.
                .background(ParityTheme.canvas)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .top)
            }
            XCTAssertTrue(captures.allSatisfy { WindowlessRender.drawsContent($0.bitmap, step: 6) })
        }

        // A staged build ready to install: the strip over the account button.
        let ready = SidebarAccountMenuContext(identity: Self.identity, update: { .ready(build: "abc1234") })
        let update = try WindowlessRender.hostedInBothAppearances("sidebar-update-240", in: directory,
                                                                   size: NSSize(width: 240 + 1 + 140, height: 820)) { appearance in
            HStack(spacing: 0) {
                fixture.sidebar(accountMenu: ready).frame(width: 240)
                ParityTheme.separator.frame(width: 1)
                ParityTheme.canvas
            }
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance.colorScheme)
            .frame(width: 240 + 1 + 140, height: 820, alignment: .top)
        }
        XCTAssertTrue(update.allSatisfy { WindowlessRender.drawsContent($0.bitmap, step: 6) })

        // What the sidebar exposes: the account button by the person's name, the projects as headings,
        // and "Restart to update" while a staged build is ready.
        let host = WindowlessRender.Host(
            fixture.sidebar(accountMenu: ready)
                .frame(width: 240, height: 820, alignment: .top),
            size: NSSize(width: 240, height: 820))
        defer { host.close() }
        host.settle()
        let elements = host.accessibilityElements()
        XCTAssertTrue(elements.contains { $0.label == L10n.format("Account menu, %@", "Alex Kim") }, "\(elements)")
        XCTAssertFalse(elements.contains { $0.label == L10n.string("Archived tasks") },
                       "Archived tasks moved into the account menu: \(elements)")
        XCTAssertTrue(elements.contains { $0.label == L10n.format("Project %@", "Website") })
        XCTAssertTrue(elements.contains { $0.label == L10n.string("Restart to update") }, "\(elements)")

        try WindowlessRender.hostedInBothAppearances("account-button", in: directory,
                                                     size: NSSize(width: 240, height: 220)) { appearance in
            VStack(spacing: 8) {
                SidebarUpdateStripLabel(line: .ready(build: "abc1234"))
                SidebarUpdateStripLabel(line: .ready(build: "abc1234"), isHovering: true)
                SidebarUpdateStripLabel(line: .waiting)
                SidebarAccountButtonLabel(identity: Self.identity)
                SidebarAccountButtonLabel(identity: Self.identity, isHovering: true)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 14)
            .environment(\.colorScheme, appearance.colorScheme)
            .frame(width: 240, height: 220, alignment: .top)
            .background(ParityTheme.sidebar)
        }
    }

    // MARK: - Fixture

    private func task(_ title: String, _ harness: HarnessKind, in folder: URL, minutesAgo: Double,
                      status: SessionStatus = .ready, unread: Bool = false, pinned: Bool = false,
                      parent: SessionRecord? = nil) -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/agent"),
                      title: title, titleOrigin: .provider, status: status,
                      updatedAt: now.addingTimeInterval(-minutesAgo * 60), hasUnreadUpdate: unread,
                      completionState: unread ? .completed : .none, isPinned: pinned, parentTaskID: parent?.id)
    }

    private func sidebar(layout: SidebarProjection.Layout, groups: [WorkspaceGroup], projects: ProjectStore,
                         selection: WindowItem) -> some View {
        TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: selection,
            searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
            projects: projects, onEditProject: { _ in }, onArchiveProjectChats: { _ in }, onRemoveProject: { _ in },
            onTogglePinned: { _ in }, onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in },
            onMarkRead: { _ in }, accountMenu: SidebarAccountMenuContext(identity: Self.identity))
            .background(ParityTheme.sidebar)
    }

    /// Several projects, families, Pinned, Chats and pull requests, for the renders.
    @MainActor
    private struct Fixture {
        let projects: ProjectStore
        let groups: [WorkspaceGroup]
        let chats: [SessionRecord]
        let layout: SidebarProjection.Layout
        let selection: WindowItem
        let disclosure: SidebarDisclosureStore
        let details: [UUID: TaskAttentionDetail]
        let pullRequests = TaskPullRequestMonitor()
        let resources = TaskResourceMonitor(table: FakeProcessTable())

        @MainActor
        init(now: Date) throws {
            let home = URL(filePath: "/tmp/sidebar-ui-qa/home", directoryHint: .isDirectory)
            let yardlet = URL(filePath: "/tmp/sidebar-ui-qa/yardlet", directoryHint: .isDirectory)
            let website = URL(filePath: "/tmp/sidebar-ui-qa/website", directoryHint: .isDirectory)
            let notes = URL(filePath: "/tmp/sidebar-ui-qa/notes", directoryHint: .isDirectory)
            projects = ProjectStore(chatWorkspaceHome: home)
            _ = projects.ensureProject(forRoot: yardlet)
            let websiteProject = projects.ensureProject(forRoot: website, name: "Website")
            _ = projects.ensureProject(forRoot: notes)
            var minutes = 0.0
            func task(_ title: String, _ harness: HarnessKind, in folder: URL, status: SessionStatus = .ready,
                      unread: Bool = false, pinned: Bool = false, parent: SessionRecord? = nil) -> SessionRecord {
                minutes += 1
                return SessionRecord(harness: harness, workspaceURL: folder,
                                     runtimeExecutableURL: URL(filePath: "/tmp/agent"), title: title,
                                     titleOrigin: .provider, status: status,
                                     updatedAt: now.addingTimeInterval(-minutes * 60), hasUnreadUpdate: unread,
                                     completionState: unread ? .completed : .none, isPinned: pinned,
                                     parentTaskID: parent?.id)
            }
            let chat = task("Summarize the meeting notes", .claudeCode,
                            in: home.appending(path: "Documents/Yardlet/2026-10-16/new-chat", directoryHint: .isDirectory))
            let pinned = task("Draft the release notes", .claudeCode, in: yardlet, pinned: true)
            let plan = task("Plan the sidebar changes", .claudeCode, in: yardlet, status: .running)
            let menuChild = task("Account menu", .claudeCode, in: yardlet, unread: true, parent: plan)
            let widthChild = task("Resizable width", .codex, in: yardlet, parent: plan)
            let grandchild = task("Check the width on a small window", .codex, in: yardlet, parent: widthChild)
            let review = task("Review the index migration", .codex, in: yardlet)
            let merged = task("Fix the footer links", .claudeCode, in: yardlet)
            let older = (1...4).map { task("Older task \($0)", $0.isMultiple(of: 2) ? .codex : .claudeCode, in: yardlet) }
            let waiting = task("Landing page copy", .claudeCode, in: website, status: .waitingForApproval)
            let idle = task("Update the pricing table", .codex, in: website)
            let sessions = [chat, pinned, plan, menuChild, widthChild, grandchild, review, merged, waiting, idle] + older

            let suite = testDefaultsSuite("SidebarShellTests")
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            disclosure = SidebarDisclosureStore(defaults: defaults)
            disclosure.collapse(SidebarProjection.disclosureKey(
                for: WorkspaceGroup(workspaceURL: website, sessions: [], project: websiteProject)))
            groups = projects.visibleGroups(sessions: sessions)
            chats = projects.chats(sessions: sessions)
            selection = .session(review.id)
            details = [waiting.id: TaskAttentionDetail(pendingRequest: .approval)]
            layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, chats: chats, splits: [],
                                              isFiltering: false, disclosure: disclosure.disclosure,
                                              selection: selection, waiting: [waiting.id])
            let url = URL(string: "https://github.com/example/yardlet/pull/2356")!
            pullRequests.setPullRequest(TaskPullRequest(number: 2356, url: url, repository: "example/yardlet",
                                                        state: .open, checks: .passing), for: review.id)
            pullRequests.setPullRequest(TaskPullRequest(number: 2301, url: url, repository: "example/yardlet",
                                                        state: .merged), for: merged.id)
        }

        @MainActor
        func sidebar(accountMenu: SidebarAccountMenuContext) -> some View {
            TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: selection,
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: projects, onEditProject: { _ in }, onArchiveProjectChats: { _ in },
                onRemoveProject: { _ in }, onTogglePinned: { _ in }, onArchive: { _ in }, onDelete: { _ in },
                onRename: { _ in }, onMarkRead: { _ in }, accountMenu: accountMenu, disclosure: disclosure)
                .environment(\.taskAttentionDetails, details)
                .environment(pullRequests)
                .environment(resources)
                .background(ParityTheme.sidebar)
        }
    }
}

@MainActor
private final class Chosen {
    var destinations: [SidebarAccountMenu.Destination] = []
}
