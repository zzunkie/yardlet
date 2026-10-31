import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The menu bar item's menu drawn offscreen into `.build/menu-bar-qa`, light and dark. An `NSMenu`
/// draws only while it is open on screen, so the items `MenuBarMenuController` builds are drawn
/// here by `MenuPanel`, line for line in the system menu's layout (headers, title and subtitle,
/// read-only lines, indentation, submenus, separators). No status item, window or app is shown.
///
/// - `menu-*.png`: the item in the menu bar with the menu open on ten tasks across three projects
///   and a chat with the sidebar's state marks, one usage line per account (four Claude accounts and
///   Codex, whose latest check could not finish), Recent's More submenu, and "Restart to update" for a
///   staged build; beside it the menu with nothing to list and the icon on a bar of each appearance.
/// - `account-menu-*.png`: the sidebar's account menu (`SidebarAccountMenuController`) with the same
///   accounts under Usage, each with its harness and what is left under it.
/// - `settings-general-*.png`: Settings › General with "Show in menu bar" first.
/// - `settings-general-updates-*.png`: the same in a build that updates with Sparkle, which adds
///   "Automatically check for updates" last.
/// - `settings-general-lid-*.png` and `menu-lid-*.png`: "Keep tasks working with the lid closed" on
///   while macOS waits for the person to allow the helper, and the menu's first lines while the screen
///   and the lid are kept awake; `menu-lid-hot-*.png` while a critical heat lets the Mac sleep.
@MainActor
final class MenuBarRenderingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_158_000) // 2026-10-16 13:40 UTC

    func testTheMenuDrawsWithItsSectionsUsageAndEndInBothAppearances() throws {
        let directory = try WindowlessRender.directory("menu-bar-qa")
        let model = fixtureModel()
        // With a staged build ready to install: "Restart to update" before Quit.
        let controller = MenuBarMenuController(content: {
            var menu = model.menuBarMenu(now: self.now)
            menu.update = .ready(build: "abc1234")
            return menu
        }, actions: .init())
        controller.menuNeedsUpdate(controller.menu)
        let lines = MenuLine.lines(controller.menu.items)
        let empty = MenuBarMenuController(content: { .empty }, actions: .init())
        empty.rebuild()

        let kinds = model.menuBarMenu(now: now).sections.map(\.kind)
        XCTAssertEqual(kinds, [.running, .unread, .pinned, .recent])
        let more = try XCTUnwrap(controller.menu.items.last { $0.submenu != nil })
        let iconURL = WindowlessRender.repositoryRoot.appending(path: "Packaging/AppIcon-1024.png")
        let icon = try XCTUnwrap(MenuBarIcon.template(from: try XCTUnwrap(NSImage(contentsOf: iconURL))))
        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))

        let size = NSSize(width: 1080, height: MenuPanel.height(lines) + 90)
        let captures = try WindowlessRender.hostedInBothAppearances("menu", in: directory, size: size) { appearance in
            MenuBarShowcase(lines: lines, more: MenuLine.lines(more.submenu?.items ?? []),
                            moreIndex: lines.lastIndex { $0.hasSubmenu } ?? 0,
                            empty: MenuLine.lines(empty.menu.items), icon: icon)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        for capture in captures {
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
        }

        // The sidebar's account menu reads the same Usage lines.
        let account = SidebarAccountMenuController(content: SidebarAccountMenu.make(
            identity: SidebarAccountIdentity(fullName: "Jordan Park", userName: nil),
            settingsSections: SettingsSection.available(hasAccounts: true, hasConnectors: true, hasRemote: true),
            usage: model.menuBarMenu(now: now).usage)) { _ in }
        let accountLines = MenuLine.lines(account.menu.items)
        let accountSize = NSSize(width: 440, height: MenuPanel.height(accountLines) + 40)
        try WindowlessRender.hostedInBothAppearances("account-menu", in: directory, size: accountSize) { appearance in
            MenuPanel(lines: accountLines, width: 400)
                .padding(20)
                .frame(width: accountSize.width, height: accountSize.height, alignment: .topLeading)
                .background(appearance == .dark ? Color(white: 0.1) : Color(white: 0.85))
                .environment(\.colorScheme, appearance.colorScheme)
        }
    }

    func testGeneralSettingsShowsTheMenuBarSwitchFirst() throws {
        let directory = try WindowlessRender.directory("menu-bar-qa")
        let size = NSSize(width: 820, height: 620)
        try WindowlessRender.hostedInBothAppearances("settings-general", in: directory, size: size) { appearance in
            SettingsCenterView(notificationCenter: MenuBarQuietNotificationCenter())
                .environment(\.colorScheme, appearance.colorScheme)
        }
        let host = WindowlessRender.Host(SettingsCenterView(notificationCenter: MenuBarQuietNotificationCenter()),
                                         size: size)
        defer { host.close() }
        host.settle()
        let elements = host.accessibilityElements()
        let switches = elements.filter { $0.role == NSAccessibility.Role.checkBox.rawValue }
        XCTAssertEqual(switches.first?.label, L10n.string("Show Yardlet in the menu bar"), elements.description)
        XCTAssertFalse(switches.contains { $0.label == L10n.string("Automatically check for updates") },
                       "A development build has no Sparkle switch")

        // A build with Sparkle's feed and key; the updater is made but never started.
        let sparkle = try XCTUnwrap(YardletSparkle(info: ["SUFeedURL": "https://example.invalid/appcast.xml",
                                                          "SUPublicEDKey": "AAAA"]))
        XCTAssertNil(YardletSparkle(info: ["SUFeedURL": "https://example.invalid/appcast.xml"]), "No key, no updater")
        try WindowlessRender.hostedInBothAppearances("settings-general-updates", in: directory, size: size) { appearance in
            SettingsCenterView(notificationCenter: MenuBarQuietNotificationCenter())
                .environment(\.yardletSparkle, sparkle)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        let updates = WindowlessRender.Host(SettingsCenterView(notificationCenter: MenuBarQuietNotificationCenter())
            .environment(\.yardletSparkle, sparkle), size: size)
        defer { updates.close() }
        updates.settle()
        let updateSwitches = updates.accessibilityElements().filter { $0.role == NSAccessibility.Role.checkBox.rawValue }
        XCTAssertEqual(updateSwitches.last?.label, L10n.string("Automatically check for updates"))
    }

    func testTheLidSettingAndItsMenuLinesDraw() throws {
        let directory = try WindowlessRender.directory("menu-bar-qa")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("MenuBarRendering")))
        defaults.set(true, forKey: LidClosedWorkPreference.key)
        let helper = LidSleepHelper(backend: FakeLidSleepHelperBackend(status: .needsApproval))
        let size = NSSize(width: 820, height: 620)
        func settings(_ appearance: WindowlessRender.Appearance) -> some View {
            SettingsCenterView(notificationCenter: MenuBarQuietNotificationCenter(), lidHelper: helper)
                .defaultAppStorage(defaults)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        // General lists the lid row after its browser and restart settings, below the sheet's first
        // screen: each drawing is scrolled to the end of the page, as the person scrolls to the row.
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(settings(appearance), size: size, appearance: appearance)
            defer { host.close() }
            host.settle()
            let page = try XCTUnwrap(Self.scrollViews(in: host.hosting).max {
                ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
            })
            let document = try XCTUnwrap(page.documentView)
            document.scrollToVisible(NSRect(x: 0, y: document.isFlipped ? document.bounds.maxY - 1 : document.bounds.minY,
                                            width: 1, height: 1))
            host.settle()
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "settings-general-lid-\(appearance.suffix).png"))
            guard appearance == .light else { continue }
            let visible = host.accessibilityElements(visibleOnly: true).map { "\($0.label) \($0.value)" }
            for text in ["Keep tasks working with the lid closed", "Allow Yardlet in the background in System Settings",
                         "Open System Settings"] {
                XCTAssertTrue(visible.contains { $0.contains(L10n.string(text)) }, "\(text) in \(visible)")
            }
        }

        var menu = MenuBarMenu.empty
        menu.keepsScreenAwake = true
        menu.keepsAwakeWithLidClosed = true
        let controller = MenuBarMenuController(content: { menu }, actions: .init())
        controller.rebuild()
        let lines = MenuLine.lines(controller.menu.items)
        XCTAssertEqual(controller.menu.items.prefix(5).map(\.title), [L10n.string("Keeping the screen unlocked"),
            L10n.string("Turn Off"), "", L10n.string("Keeping tasks working with the lid closed"), L10n.string("Turn Off")])
        let menuSize = NSSize(width: 440, height: MenuPanel.height(lines) + 40)
        try WindowlessRender.hostedInBothAppearances("menu-lid", in: directory, size: menuSize) { appearance in
            MenuPanel(lines: lines, width: 400)
                .padding(20)
                .frame(width: menuSize.width, height: menuSize.height, alignment: .topLeading)
                .background(appearance == .dark ? Color(white: 0.1) : Color(white: 0.85))
                .environment(\.colorScheme, appearance.colorScheme)
        }

        menu = .empty
        menu.lidAwakePause = .heat
        controller.rebuild()
        XCTAssertEqual(controller.menu.items.prefix(2).map(\.title), [
            L10n.string("Not keeping the Mac awake with the lid closed: the Mac is too hot"), L10n.string("Turn Off")])
        let hotLines = MenuLine.lines(controller.menu.items)
        let hotSize = NSSize(width: 440, height: MenuPanel.height(hotLines) + 40)
        try WindowlessRender.hostedInBothAppearances("menu-lid-hot", in: directory, size: hotSize) { appearance in
            MenuPanel(lines: hotLines, width: 400)
                .padding(20)
                .frame(width: hotSize.width, height: hotSize.height, alignment: .topLeading)
                .background(appearance == .dark ? Color(white: 0.1) : Color(white: 0.85))
                .environment(\.colorScheme, appearance.colorScheme)
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    // MARK: - Fixture

    /// Ten tasks across Yardlet, Website and Docs and one chat, in every state the menu sorts by,
    /// four Claude accounts and Codex's default login with their limits, Codex's from a reading two
    /// days old whose next check failed.
    private func fixtureModel() -> AppModel {
        let yardlet = URL(filePath: "/tmp/menu-bar-qa/yardlet", directoryHint: .isDirectory)
        let website = URL(filePath: "/tmp/menu-bar-qa/website", directoryHint: .isDirectory)
        let docs = URL(filePath: "/tmp/menu-bar-qa/docs", directoryHint: .isDirectory)
        let home = URL(filePath: "/tmp/menu-bar-qa/home", directoryHint: .isDirectory)
        let chat = ChatWorkspaces.yardletRoot(home: home).appending(path: "chat-1", directoryHint: .isDirectory)
        var minutes = 0.0
        func task(_ title: String, _ folder: URL, status: SessionStatus = .ready, unread: Bool = false,
                  pinned: Bool = false, harness: HarnessKind = .claudeCode) -> SessionRecord {
            minutes += 4
            return SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/agent"),
                                 title: title, titleOrigin: .provider, status: status,
                                 updatedAt: now.addingTimeInterval(-minutes * 60), hasUnreadUpdate: unread, isPinned: pinned)
        }
        let sessions = [
            task("Build the release bundle", yardlet, status: .running),
            task("Approve the index migration", yardlet, status: .waitingForApproval),
            task("Summarize the crash reports", yardlet, status: .completed, unread: true, harness: .codex),
            task("Add a menu bar status item like the Codex app, plus an activity view shortcut", yardlet, status: .running),
            task("Fix the footer links", website, status: .running, harness: .codex),
            task("Regenerate the screenshots", website, status: .failed, unread: true),
            task("Release checklist", yardlet, pinned: true),
            task("Translate the guide", docs, pinned: true, harness: .codex),
            task("Proofread the changelog", docs),
            task("Ask about Swift concurrency", chat),
            task("Tidy the README", yardlet),
        ]
        let store = ProviderConnectionStore()
        func metric(_ id: String, _ label: String, used: Double, hours: Double) -> AccountUsageMetric {
            AccountUsageMetric(id: id, label: label, usedFraction: used, detail: "",
                               resetsAt: now.addingTimeInterval(hours * 60 * 60), evidence: .exactQuota)
        }
        func claude(used session: Double, _ weekly: Double?) -> [AccountUsageMetric] {
            [metric("claude:session:", L10n.format("%.0f hour limit", 5.0), used: session, hours: 1.2)]
                + (weekly.map { [metric("claude:weekly_all:", L10n.format("%.0f day limit", 7.0), used: $0, hours: 120)] } ?? [])
        }
        func snapshot(_ harness: HarnessKind, _ label: String, _ provider: String, _ usage: [AccountUsageMetric],
                      organization: String? = nil, hoursAgo: Double = 0) -> HarnessAccountSnapshot {
            HarnessAccountSnapshot(id: "\(harness.rawValue):\(label)", harness: harness, providerID: provider,
                                   state: .signedIn, accountLabel: label, accountOrganization: organization,
                                   accountPlan: "Max", detail: "", credentialOwner: harness.displayName,
                                   checkedAt: now.addingTimeInterval(-hoursAgo * 60 * 60), usage: usage,
                                   canLogin: false, canLogout: false)
        }
        store.publishDefaults([
            snapshot(.codex, "codex@example.test", "openai-codex", [
                metric("codex:primary", "codex · " + L10n.format("%.0f hour limit", 5.0), used: 0.18, hours: 3.5),
                metric("codex:secondary", "codex · " + L10n.format("%.0f day limit", 7.0), used: 0.42, hours: 80),
            ], hoursAgo: 48),
            snapshot(.claudeCode, "jordan@example.test", "anthropic", claude(used: 0.64, 0.31)),
        ])
        // Codex's latest check could not finish: its line keeps the two-day-old reading and says so.
        store.publishDefaults([HarnessAccountSnapshot(id: "codex", harness: .codex, providerID: nil, state: .unknown,
            accountLabel: nil, detail: "", credentialOwner: "", checkedAt: now, usage: [], canLogin: false,
            canLogout: false)])
        // Three more Claude Max accounts in Session Switch folders, as the person moves between them:
        // one in a team's organization, one read eleven hours ago.
        for (index, (label, session, weekly, organization, hoursAgo)) in [
            ("work@example.test", 0.97, 0.88, "Example Team", 0.0), ("side@example.test", 0.12, nil, nil, 11.0),
            ("spare@example.test", 0.4, 0.55, nil, 0.0),
        ].enumerated() {
            let home = URL(filePath: "/tmp/menu-bar-qa/accounts/\(index)", directoryHint: .isDirectory)
            if let connection = try? store.add(name: "Account \(index + 1)", harness: .claudeCode, home: home) {
                store.publish(snapshot(.claudeCode, label, "anthropic", claude(used: session, weekly),
                                       organization: organization, hoursAgo: hoursAgo), for: connection)
            }
        }
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: UserDefaults(suiteName: testDefaultsSuite("MenuBarRenderingTests"))!),
            connections: store,
            chatWorkspaceHome: home,
            systemNotificationCenter: MenuBarQuietNotificationCenter(),
            restoresIndexOnLaunch: false
        )
        for (folder, name) in [(yardlet, "Yardlet"), (website, "Website"), (docs, "Docs")] {
            model.projects.rename(model.projects.ensureProject(forRoot: folder).id, to: name)
        }
        return model
    }
}

// MARK: - Drawing the menu's items

/// One menu item as the system menu lays it out.
struct MenuLine: Identifiable {
    enum Kind { case separator, header, item }
    let id: Int
    let kind: Kind
    let title: String
    let subtitle: String?
    let isEnabled: Bool
    let indentation: Int
    let hasSubmenu: Bool
    let image: NSImage?

    var height: CGFloat {
        switch kind {
        case .separator: 11
        case .header: 22
        case .item: subtitle == nil ? 22 : 36
        }
    }

    @MainActor
    static func lines(_ items: [NSMenuItem]) -> [MenuLine] {
        items.enumerated().map { index, item in
            MenuLine(id: index,
                     kind: item.isSeparatorItem ? .separator : item.isSectionHeader ? .header : .item,
                     title: item.title, subtitle: item.subtitle, isEnabled: item.isEnabled,
                     indentation: item.indentationLevel, hasSubmenu: item.submenu != nil, image: item.image)
        }
    }
}

/// A menu panel: rounded, with the system menu's 13 pt titles, 11 pt subtitles and headers, and
/// dimmed read-only lines.
struct MenuPanel: View {
    let lines: [MenuLine]
    var width: CGFloat = 300
    var highlighted: Int?
    @Environment(\.colorScheme) private var colorScheme

    static let padding: CGFloat = 5
    static func height(_ lines: [MenuLine]) -> CGFloat { lines.reduce(2 * padding) { $0 + $1.height } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                row(line)
                    .frame(height: line.height)
            }
        }
        .padding(.vertical, Self.padding)
        .frame(width: width, alignment: .leading)
        .background(colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.965),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.18), radius: 12, y: 6)
    }

    @ViewBuilder
    private func row(_ line: MenuLine) -> some View {
        switch line.kind {
        case .separator:
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.horizontal, 10)
        case .header:
            Text(line.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.bottom, 3)
        case .item:
            let isHighlighted = highlighted == line.id
            HStack(spacing: 6) {
                // The image column, kept for every row once one row has an image.
                if lines.contains(where: { $0.image != nil }) {
                    Group {
                        if let image = line.image {
                            Image(nsImage: image).opacity(line.isEnabled ? 1 : 0.55)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 14, height: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.title)
                        .font(.system(size: 13))
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white)
                                         : line.isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    if let subtitle = line.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.85))
                                             : line.isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if line.hasSubmenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.leading, 14 + CGFloat(line.indentation) * 12)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(isHighlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .padding(.horizontal, 5)
        }
    }
}

/// The menu bar with Yardlet's item open, its menu and Recent's More submenu; beside them the
/// menu with nothing to list and the icon on a light and a dark bar.
private struct MenuBarShowcase: View {
    let lines: [MenuLine]
    let more: [MenuLine]
    let moreIndex: Int
    let empty: [MenuLine]
    let icon: NSImage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Spacer()
                Image(systemName: "wifi").font(.system(size: 13))
                Image(nsImage: icon)
                    .renderingMode(.template)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                Text(verbatim: "Fri 16 Oct 22:40").font(.system(size: 13))
            }
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.9))
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    MenuPanel(lines: empty, width: 220)
                    HStack(spacing: 0) {
                        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                            Image(nsImage: icon)
                                .renderingMode(.template)
                                .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                                .frame(width: 60, height: 26)
                                .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.9))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    // The 18 pt template at its 36 px, four times over, to read its shape.
                    HStack(spacing: 12) {
                        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                            Image(nsImage: icon)
                                .resizable()
                                .renderingMode(.template)
                                .interpolation(.none)
                                .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                                .frame(width: 72, height: 72)
                                .padding(8)
                                .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.9),
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(20)
                Spacer(minLength: 0)
                MenuPanel(lines: more, width: 260)
                    .padding(.top, 8 + MenuPanel.padding + lines.prefix(moreIndex).reduce(0) { $0 + $1.height } - MenuPanel.padding)
                    .padding(.trailing, -4)
                // As wide as Codex's line with its failed check, as the system menu fits its widest item.
                MenuPanel(lines: lines, width: 400, highlighted: moreIndex)
                    .padding(.top, 8)
                    .padding(.trailing, 110)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colorScheme == .dark ? Color(white: 0.24) : Color(white: 0.82))
    }
}
