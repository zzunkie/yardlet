#if DEBUG
import AppKit
import Foundation
import YardletSimulatorHostProtocol

/// QA for the Simulator tab in the running app (docs/SIMULATOR.md), run by scripts/simulator-qa/run-panel-check.sh with
/// `--ui-fixture=conversation --ui-fixture-simulator-check=<folder>` against a throwaway simulator it boots
/// (`YARDLET_SIMULATOR_QA_DEVICE`). The app follows Settings › General › Simulator as it does at launch; the
/// launcher offers Simulator after Browser; the tab lists the devices; the device picked shows live through the
/// bundle's simulator host, and a click on Settings opens it; turning the switch off closes the tab, takes Simulator
/// out of the launcher and lets the device go. Captures `{launcher,list,live,settings,off}-{light,dark}.png` and
/// writes `result.json`; the device is never started or stopped here.
@MainActor
final class SimulatorPanelQA {
    private typealias Navigation = TaskSurfaceNavigationProjection
    private static var started = false
    private let output: URL
    private let session: UUID
    private let model: AppModel
    private var checks: [JSONValue] = []

    static func startIfRequested(session: UUID) {
        guard !started, let output = BrowserHostQAFixture.argument("ui-fixture-simulator-check").map({ URL(filePath: $0) })
        else { return }
        started = true
        Task { @MainActor in
            // The task shows before the launch hands the fixtures the app.
            for _ in 0..<300 where BrowserHostQAFixture.model == nil { try? await Task.sleep(for: .milliseconds(100)) }
            guard let model = BrowserHostQAFixture.model else { return }
            await SimulatorPanelQA(output: output, session: session, model: model).run()
        }
    }

    private init(output: URL, session: UUID, model: AppModel) {
        self.output = output
        self.session = session
        self.model = model
    }

    private func run() async {
        defer { finish() }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let value = ProcessInfo.processInfo.environment["YARDLET_SIMULATOR_QA_DEVICE"],
              let device = UUID(uuidString: value) else {
            return check("setup: the throwaway device is named", false, "no YARDLET_SIMULATOR_QA_DEVICE")
        }
        // The window shows the fixture's conversation; the side panel opens beside it.
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) else {
            return check("setup: the window opens", false, "no window")
        }
        var frame = window.frame
        frame.size = NSSize(width: 1400, height: 900)
        window.setFrame(frame, display: true)
        let workspace = model.taskWorkspaces.state(for: session)

        // The fixture's model has no platform: it gets the Mac's iOS simulators and screens as `AppModel.live()` hands
        // them in, with the devices it starts kept in memory. The switch is on by default, and the app follows it as
        // at launch: the center checks this Mac's Xcode.
        model.simulators = SimulatorCenter(backends: [MacIOSSimulatorBackend()])
        AppModel.wireSimulatorScreens(to: model)
        // Settings' switch is in Yardlet's defaults, which the panel reads too; the fixture's model keeps its own.
        model.startSimulators(defaults: .yardlet)
        let center = model.simulators
        let checked = await waitUntil(.seconds(60)) { center.isEnabled && center.checks[.iOS] != nil }
        check("switch: on by default, the center checks the Mac's Xcode", checked && SimulatorPreference.isOn(in: .yardlet),
              "\(String(describing: center.checks[.iOS]))")

        workspace.setPanels(Navigation.showing(Navigation.launcherID, in: workspace.panels))
        try? await Task.sleep(for: .seconds(1))
        await capture(window, "launcher")

        workspace.setPanels(Navigation.showing(Navigation.simulatorID, in: workspace.panels))
        let listed = await waitUntil(.seconds(30)) { center.device(.iOSSimulator(udid: device.uuidString)) != nil }
        check("list: the throwaway device is listed", listed, "\(center.devices.count) devices")
        await capture(window, "list")

        // The device picked shows live, through the bundle's helper.
        let identity = SimulatorDeviceIdentity.iOSSimulator(udid: device.uuidString)
        let attached = await center.attach(identity, to: session, by: .person)
        check("attach: the device the person picked is attached and claimed",
              { if case let .attached(attachment) = attached { return attachment.isClaimed && !attachment.isStartedByYardlet }
                return false }(), "\(attached)")
        let live = await waitUntil(.seconds(30)) { self.screenView(in: window)?.frameDisplay.current != nil }
        check("live: the bundle's helper sends frames into the panel", live,
              "\(String(describing: MacSimulatorScreens.shared.link(of: device)))")
        check("tab: the task keeps the device it attached", workspace.simulator == identity, "")
        MacSimulatorScreens.shared.press(.home, on: device)
        try? await Task.sleep(for: .seconds(2))
        await capture(window, "live")

        if let view = screenView(in: window) {
            let before = view.frameDisplay.current?.frame.sequence ?? 0
            let rect = view.screenRect
            let point = view.convert(NSPoint(x: rect.minX + 0.843 * rect.width, y: rect.minY + 0.492 * rect.height), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                  clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
                }
            }
            let moved = await waitUntil(.seconds(10)) { (view.frameDisplay.current?.frame.sequence ?? 0) > before + 10 }
            check("input: a click on Settings reaches the device", moved && center.lastPersonInput(on: identity) != nil, "")
            try? await Task.sleep(for: .seconds(3))
            await capture(window, "settings")
            MacSimulatorScreens.shared.press(.home, on: device)
        }

        // Turned off: the tab closes, the launcher leaves Simulator out, and the helper lets the device go.
        UserDefaults.yardlet.set(false, forKey: SimulatorPreference.key)
        let closed = await waitUntil(.seconds(20)) {
            !workspace.panels.trailingTabs.contains(Navigation.simulatorID) && !center.isEnabled
                && MacSimulatorScreens.shared.link(of: device) == nil
        }
        check("switch off: the tab closes, the center stops, the screen is let go", closed,
              "tabs \(workspace.panels.trailingTabs), enabled \(center.isEnabled)")
        workspace.setPanels(Navigation.showing(Navigation.launcherID, in: workspace.panels))
        try? await Task.sleep(for: .seconds(1))
        await capture(window, "off")
        UserDefaults.yardlet.removeObject(forKey: SimulatorPreference.key)
    }

    private func screenView(in window: NSWindow) -> SimulatorScreenView? {
        func find(_ view: NSView) -> SimulatorScreenView? {
            if let screen = view as? SimulatorScreenView { return screen }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    private func capture(_ window: NSWindow, _ name: String) async {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .seconds(1))
            guard let content = window.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: output.appending(path: "\(name)-\(suffix).png"))
        }
        NSApp.appearance = nil
    }

    private func waitUntil(_ timeout: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        checks.append(.object(["check": .string("simulator-panel: " + name), "ok": .bool(ok),
                               "detail": .string(String(detail.prefix(800)))]))
    }

    private func finish() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(JSONValue.object(["checks": .array(checks)])).write(to: output.appending(path: "result.json"),
                                                                                  options: .atomic)
        try? "done".write(to: output.appending(path: "finished"), atomically: true, encoding: .utf8)
    }
}
#endif
