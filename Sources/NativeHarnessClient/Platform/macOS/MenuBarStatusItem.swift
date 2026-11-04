import AppKit
import SwiftUI

/// The menu bar item's menu, after the Codex app's macOS status item (`StatusItemController`, an
/// `NSStatusItem` whose `NSMenu` is filled by `menuNeedsUpdate`): nothing is read until the menu
/// opens, and then the tasks, attention and account readings are read once (`MenuBarMenu`).
///
/// Running, Unread, Pinned and Recent each list three tasks (the sidebar's state mark, the title,
/// then the project or "Chats" under it) and the rest under More; Usage lists one plain line per
/// account with its harness's mark. Then New task, Open Yardlet and Quit Yardlet, as the Codex menu
/// ends with New Chat, Open and Quit; a staged build ready to install adds "Restart to update" before
/// Quit (`MenuBarMenu.UpdateLine`).
@MainActor
final class MenuBarMenuController: NSObject, NSMenuDelegate {
    struct Actions {
        var openTask: @MainActor (UUID) -> Void = { _ in }
        var openRemoteTask: @MainActor (RemoteTaskReveal) -> Void = { _ in }
        var newTask: @MainActor () -> Void = {}
        var openApp: @MainActor () -> Void = {}
        var quit: @MainActor () -> Void = {}
        /// "Restart to update": Yardlet › Install Update….
        var installUpdate: @MainActor () -> Void = {}

        /// What the items do in the app: a task opens as a notification click opens it.
        static func routing(to model: AppModel) -> Actions {
            Actions(
                openTask: { [weak model] id in Task { await model?.openTaskFromMenuBar(id) } },
                openRemoteTask: { [weak model] remote in Task { await model?.openRemoteTaskFromMenuBar(remote) } },
                newTask: { [weak model] in model?.showNewTaskFromMenuBar() },
                openApp: { [weak model] in model?.bringForwardFromMenuBar() },
                // As Quit in the app menu: from the run loop, so quitting can wait for the tasks to stop.
                quit: { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) }
            )
        }
    }

    let menu = NSMenu(title: YardletProduct.name)
    private let content: () -> MenuBarMenu
    private let actions: Actions
    /// Checks the accounts the Usage lines show (`AppModel.checkUsageAccounts`).
    private let checkUsage: @MainActor () async -> Void
    private var isOpen = false
    /// How many times the menu has been built; only opening it builds it.
    private(set) var buildCount = 0

    init(content: @escaping () -> MenuBarMenu, actions: Actions,
         checkUsage: @escaping @MainActor () async -> Void = {}) {
        self.content = content
        self.actions = actions
        self.checkUsage = checkUsage
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuild()
        // As an account list checks its rows when it appears; the open menu takes the answers.
        Task { [weak self, checkUsage] in
            await checkUsage()
            guard let self, self.isOpen else { return }
            self.menu.update(to: self.items(for: self.content()))
        }
    }

    func menuWillOpen(_ menu: NSMenu) { if menu === self.menu { isOpen = true } }
    func menuDidClose(_ menu: NSMenu) { if menu === self.menu { isOpen = false } }

    /// Reads the menu's contents and lays its items out.
    func rebuild() {
        buildCount += 1
        menu.items = items(for: content())
    }

    func items(for contents: MenuBarMenu) -> [NSMenuItem] {
        var groups: [[NSMenuItem]] = contents.sections.map { section in
            [NSMenuItem.sectionHeader(title: section.kind.title)]
                + section.rows.map(taskItem)
                + (section.more.isEmpty ? [] : [moreItem(section.more)])
        }
        if !contents.usage.isEmpty || contents.usageToday != nil {
            groups.append([NSMenuItem.sectionHeader(title: L10n.string("Usage"))]
                          + (contents.usageToday.map { [plainItem($0)] } ?? []) + contents.usage.map { account in
                let item = plainItem(account.line)
                if !account.detail.isEmpty { item.subtitle = account.detail }
                item.image = MenuBarItemMarks.harness(account.harness)
                item.toolTip = account.help
                return item
            })
        }
        if contents.keepsAwakeWithLidClosed || contents.lidAwakePause != nil {
            let state = switch contents.lidAwakePause {
            case .battery: "Not keeping the Mac awake with the lid closed: battery under 20%"
            case .heat: "Not keeping the Mac awake with the lid closed: the Mac is too hot"
            case nil: "Keeping tasks working with the lid closed"
            }
            groups.insert([plainItem(L10n.string(state)),
                           actionItem(L10n.string("Turn Off"), #selector(chooseLetLidSleep(_:)))], at: 0)
        }
        if contents.keepsScreenAwake || contents.screenAwakePausedForBattery {
            let state = contents.keepsScreenAwake ? "Keeping the screen unlocked" : "Not keeping the screen unlocked: battery under 20%"
            groups.insert([plainItem(L10n.string(state)),
                           actionItem(L10n.string("Turn Off"), #selector(chooseLetScreenLock(_:)))], at: 0)
        }
        var items = groups.enumerated().flatMap { index, group in index == 0 ? group : [.separator()] + group }
        if !items.isEmpty { items.append(.separator()) }
        items.append(actionItem(L10n.string("New task"), #selector(chooseNewTask(_:))))
        items.append(.separator())
        items.append(actionItem(L10n.format("Open %@", YardletProduct.name), #selector(chooseOpenApp(_:))))
        items.append(.separator())
        if let update = contents.update {
            let item = update == .waiting ? plainItem(update.title) : actionItem(update.title, #selector(chooseInstallUpdate(_:)))
            item.toolTip = update.help
            items.append(item)
        }
        items.append(actionItem(L10n.format("Quit %@", YardletProduct.name), #selector(chooseQuit(_:))))
        return items
    }

    /// A task: its title, its project under it, and the sidebar's state mark before it (an empty mark
    /// for a task with no state, so the titles line up). The item's accessibility description is
    /// AppKit's own ("title, project") with the state after it.
    private func taskItem(_ row: MenuBarMenu.TaskRow) -> NSMenuItem {
        let item = actionItem(row.title, #selector(chooseTask(_:)))
        item.representedObject = row.remoteTask ?? (row.sessionID as Any)
        if !row.subtitle.isEmpty { item.subtitle = row.subtitle }
        item.image = MenuBarItemMarks.status(row.status)
        if let status = row.status {
            item.setAccessibilityLabel([row.title, row.subtitle, status.accessibilityName]
                .filter { !$0.isEmpty }.joined(separator: ", "))
        }
        return item
    }

    private func moreItem(_ rows: [MenuBarMenu.TaskRow]) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.string("More"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: L10n.string("More"))
        submenu.autoenablesItems = false
        submenu.items = rows.map(taskItem)
        item.submenu = submenu
        return item
    }

    /// A line to read, not to choose: an account and its limits (Codex `enabled: false`).
    private func plainItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func chooseTask(_ sender: NSMenuItem) {
        if let remote = sender.representedObject as? RemoteTaskReveal {
            actions.openRemoteTask(remote)
        } else if let id = sender.representedObject as? UUID {
            actions.openTask(id)
        }
    }

    @objc func chooseNewTask(_ sender: NSMenuItem) { actions.newTask() }
    @objc func chooseOpenApp(_ sender: NSMenuItem) { actions.openApp() }
    @objc func chooseQuit(_ sender: NSMenuItem) { actions.quit() }
    @objc func chooseInstallUpdate(_ sender: NSMenuItem) { actions.installUpdate() }
    @objc func chooseLetScreenLock(_ sender: NSMenuItem) { UserDefaults.yardlet.set(false, forKey: KeepScreenAwakePreference.key) }
    @objc func chooseLetLidSleep(_ sender: NSMenuItem) { UserDefaults.yardlet.set(false, forKey: LidClosedWorkPreference.key) }
}

/// Yardlet's item in the menu bar, shown while Settings › General › "Show in menu bar" is on
/// (`MenuBarPreference`), as the Codex app keeps its status item unless `macMenuBarEnabled` is off.
/// The icon is Yardlet's mark as a template image and shows no state, as the Codex item shows
/// none for its threads.
@MainActor
final class MenuBarStatusItem {
    let controller: MenuBarMenuController
    private let defaults: UserDefaults
    private var item: NSStatusItem?
    private var preferenceObserver: NSObjectProtocol?

    init(controller: MenuBarMenuController, defaults: UserDefaults = .yardlet) {
        self.controller = controller
        self.defaults = defaults
        // Delivered on the writing thread and passed on to the main thread without waiting for it.
        // An observer on the main queue holds a writer on another thread until the main thread runs
        // it, and a main thread that waits for that writer — as it waits for the transcript
        // snapshot queue — then never does (the 2026-10-22 hang).
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.update() }
        }
        update()
    }

    /// `update` is the staged build's line, read as the menu opens, and `installUpdate` what it does.
    static func live(model: AppModel, update: @escaping @MainActor () -> MenuBarMenu.UpdateLine? = { nil },
                     installUpdate: @escaping @MainActor () -> Void = {}) -> MenuBarStatusItem {
        var actions = MenuBarMenuController.Actions.routing(to: model)
        actions.installUpdate = installUpdate
        return MenuBarStatusItem(controller: MenuBarMenuController(
            content: { [weak model] in
                var menu = model?.menuBarMenu() ?? .empty
                menu.update = update()
                return menu
            },
            actions: actions,
            checkUsage: { [weak model] in await model?.checkUsageAccounts() }
        ))
    }

    /// Shows or removes the item as the setting says.
    func update() {
        if MenuBarPreference.isShown(in: defaults) {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = MenuBarIcon.image()
            item.button?.toolTip = YardletProduct.name
            item.button?.setAccessibilityLabel(YardletProduct.name)
            item.menu = controller.menu
            self.item = item
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }
}

extension NSMenu {
    /// Shows `newItems` in a menu that may be open. When they line up with the shown items (the
    /// same titles, separators in the same places), each shown item keeps its place and takes the
    /// new subtitle, image, help and state, so nothing moves under the pointer and an open submenu
    /// stays open; any other change replaces the items.
    func update(to newItems: [NSMenuItem]) {
        guard newItems.count == items.count, zip(items, newItems).allSatisfy({
            $0.isSeparatorItem == $1.isSeparatorItem && $0.title == $1.title
        }) else {
            items = newItems
            return
        }
        for (shown, new) in zip(items, newItems) where !shown.isSeparatorItem {
            shown.subtitle = new.subtitle
            shown.image = new.image
            shown.toolTip = new.toolTip
            shown.isEnabled = new.isEnabled
            shown.representedObject = new.representedObject
            shown.setAccessibilityLabel(new.accessibilityLabel())
        }
    }
}

/// The small images before menu rows: a task's sidebar state mark and an account's harness mark.
/// They keep their colours (not template images), as the sidebar draws them.
enum MenuBarItemMarks {
    static let size = NSSize(width: 14, height: 14)

    /// The sidebar's mark for a task's state (`SidebarTaskStatusView`): a 6 pt dot, green for an
    /// approval, orange for a question, gray while working, the accent for an unread result; an orange
    /// globe while a browser tab waits on the person; the red
    /// warning for a failed turn and the orange gauge for a plan limit. Nothing for no state. The
    /// state's name is the image's accessibility description.
    static func status(_ status: SidebarTaskStatus?) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            switch status {
            case .awaitingApproval?: dot(.systemGreen, in: rect)
            case .needsInput?: dot(.systemOrange, in: rect)
            case .waitingInBrowser?: symbol("globe", .systemOrange, weight: .semibold, in: rect)
            case .running?: dot(.secondaryLabelColor, in: rect)
            case .reconnecting?: symbol("network.slash", .secondaryLabelColor, weight: .medium, in: rect)
            case .unread?: dot(NSColor(ParityTheme.accent), in: rect)
            case .failed?: symbol("exclamationmark.triangle", .systemRed, weight: .semibold, in: rect)
            case .usageLimit?: symbol("gauge.with.dots.needle.100percent", .systemOrange, weight: .medium, in: rect)
            case nil: break
            }
            return true
        }
        image.accessibilityDescription = status?.accessibilityName
        return image
    }

    /// The harness's mark as the sidebar draws it (`HarnessLogoCatalog.image`), 14 pt.
    @MainActor
    static func harness(_ harness: HarnessKind) -> NSImage? {
        guard let image = HarnessLogoCatalog.image(for: harness)?.copy() as? NSImage else { return nil }
        image.size = size
        image.accessibilityDescription = harness.displayName
        return image
    }

    private static func dot(_ color: NSColor, in rect: NSRect) {
        let diameter: CGFloat = 6
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                                    width: diameter, height: diameter)).fill()
    }

    private static func symbol(_ name: String, _ color: NSColor, weight: NSFont.Weight, in rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                               width: size.width, height: size.height))
    }
}

/// Yardlet's mark for the menu bar: the light glyph of the app icon as an 18 pt template image, as
/// the Codex app's status item shows its mark (`chatgptTemplate.png`, 18 × 18).
@MainActor
enum MenuBarIcon {
    static let pointSize: CGFloat = 18

    static func image() -> NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url), let template = template(from: icon) {
            return template
        }
        // A build run outside its app bundle has no app icon.
        let symbol = NSImage(systemSymbolName: "steeringwheel", accessibilityDescription: YardletProduct.name)
            ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
        symbol.isTemplate = true
        return symbol
    }

    /// The icon's light mark (its glyph and dot, drawn light on the dark plate) cut out and made
    /// a template image `pointSize` points square with a point of margin; nil when the icon has no
    /// light mark.
    static func template(from icon: NSImage, pointSize: CGFloat = pointSize) -> NSImage? {
        let sampleSide = 256
        guard let sample = Pixels(icon, side: sampleSide, iconRect: CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide))
        else { return nil }
        // The mark's bounds, in the sample's drawing coordinates (origin bottom left).
        var minX = sampleSide, minY = sampleSide, maxX = -1, maxY = -1
        for row in 0..<sampleSide {
            for x in 0..<sampleSide where sample.lightness(x: x, row: row) > 0.6 {
                let y = sampleSide - 1 - row
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let markSide = CGFloat(max(maxX - minX, maxY - minY) + 1)
        let center = CGPoint(x: CGFloat(minX + maxX + 1) / 2, y: CGFloat(minY + maxY + 1) / 2)

        let side = Int(pointSize * 2)
        let margin: CGFloat = 2
        let scale = (CGFloat(side) - 2 * margin) / markSide
        let iconRect = CGRect(
            x: CGFloat(side) / 2 - center.x * scale, y: CGFloat(side) / 2 - center.y * scale,
            width: CGFloat(sampleSide) * scale, height: CGFloat(sampleSide) * scale)
        guard let drawn = Pixels(icon, side: side, iconRect: iconRect) else { return nil }
        var mask = [UInt8](repeating: 0, count: side * side * 4)
        for row in 0..<side {
            for x in 0..<side {
                let lightness = drawn.lightness(x: x, row: row)
                let coverage = min(max((lightness - 0.3) / 0.35, 0), 1)
                mask[(row * side + x) * 4 + 3] = UInt8((coverage * Double(drawn.alpha(x: x, row: row))).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(mask) as CFData),
              let cgImage = CGImage(
                width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: pointSize, height: pointSize))
        image.isTemplate = true
        image.accessibilityDescription = YardletProduct.name
        return image
    }

    /// The icon drawn into an RGBA bitmap `side` pixels square, at `iconRect`.
    private struct Pixels {
        let side: Int
        let bytes: [UInt8]

        init?(_ icon: NSImage, side: Int, iconRect: CGRect) {
            var bytes = [UInt8](repeating: 0, count: side * side * 4)
            let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.interpolationQuality = .high
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                icon.draw(in: iconRect, from: .zero, operation: .copy, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                return true
            }
            guard drew else { return nil }
            self.side = side
            self.bytes = bytes
        }

        func alpha(x: Int, row: Int) -> UInt8 { bytes[(row * side + x) * 4 + 3] }

        /// How light the pixel's own colour is, 0 to 1, whatever its coverage.
        func lightness(x: Int, row: Int) -> Double {
            let index = (row * side + x) * 4
            let alpha = Double(bytes[index + 3])
            guard alpha > 0 else { return 0 }
            let red = Double(bytes[index]) / alpha, green = Double(bytes[index + 1]) / alpha
            let blue = Double(bytes[index + 2]) / alpha
            return 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
    }
}
