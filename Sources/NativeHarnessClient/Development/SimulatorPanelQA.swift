#if DEBUG
import AppKit
import Foundation
import YardletAgentTools
import YardletSimulatorHostProtocol

/// QA for the Simulator tab in the running app (docs/SIMULATOR.md), run by scripts/simulator-qa/run-panel-check.sh with
/// `--ui-fixture=conversation --ui-fixture-simulator-check=<folder>` against a throwaway simulator it boots
/// (`YARDLET_SIMULATOR_QA_DEVICE`). The app follows Settings › General › Simulator as it does at launch; the
/// launcher offers Simulator after Browser; the tab lists the devices; the device picked shows live through the
/// bundle's simulator host, and a click on Settings opens it; the agent's simulator tools, called through the bundle's
/// `yardlet-mcp` by the script (drive-tools.py), ask the person once on the task's card, which the fixture captures and
/// allows, and add the Simulator tab beside the tab the person uses; turning the switch off closes the tab, takes
/// Simulator out of the launcher, lets the device go and removes the approval. Captures
/// `{launcher,list,live,settings,approval,tools,off}-{light,dark}.png` and writes `result.json`; the device is never
/// started or stopped here.
///
/// With `YARDLET_SIMULATOR_QA_ANDROID_AVD` instead, run by scripts/simulator-qa/run-android-panel-check.sh against a
/// throwaway emulator it started, the same for Android: the emulator listed beside the iOS simulators, its live
/// screen through the bundle's scrcpy server with Back, Home and Recents in the tab's header, Recents and a swipe
/// through the tab, the screen turned to landscape, the agent's tools as above (drive-tools.py with `android`), whose
/// paste leaves the device's clipboard as it was, and, with the switch off, the tab closed and the stream and the
/// server on the device ended. Captures `android-{list,live,recents,drawer,turned,approval,tools,off}-{light,dark}.png`.
/// With `YARDLET_SIMULATOR_QA_ANDROID_CONNECTED` as well, the address the script connected the same emulator at
/// (`adb connect 127.0.0.1:<port>`), it is then checked as a real device is: listed by the serial number it reports,
/// live and driven through the tab, never started or stopped by Yardlet, and left alone by the agents' tools
/// (`android-connected-{live,recents}-{light,dark}.png`). adb commands go only to emulators and that address, so a
/// person's own phone on this Mac is neither sent one nor listed.
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
        if let avd = ProcessInfo.processInfo.environment["YARDLET_SIMULATOR_QA_ANDROID_AVD"] {
            return await runAndroid(avd: avd)
        }
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
              "\(String(describing: MacSimulatorScreens.shared.link(of: identity)))")
        check("tab: the task keeps the device it attached", workspace.simulator == identity, "")
        MacSimulatorScreens.shared.press(.home, on: identity)
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
            MacSimulatorScreens.shared.press(.home, on: identity)
        }

        await checkAgentTools(identity, window: window, workspace: workspace)

        // Turned off: the tab closes, the launcher leaves Simulator out, and the helper lets the device go.
        UserDefaults.yardlet.set(false, forKey: SimulatorPreference.key)
        let closed = await waitUntil(.seconds(20)) {
            !workspace.panels.trailingTabs.contains(Navigation.simulatorID) && !center.isEnabled
                && MacSimulatorScreens.shared.link(of: identity) == nil
        }
        check("switch off: the tab closes, the center stops, the screen is let go", closed,
              "tabs \(workspace.panels.trailingTabs), enabled \(center.isEnabled)")
        check("switch off: the person's approval of the device goes with it",
              !model.simulatorTools.approvals.isApprovedAnywhere(identity), "")
        workspace.setPanels(Navigation.showing(Navigation.launcherID, in: workspace.panels))
        try? await Task.sleep(for: .seconds(1))
        await capture(window, "off")
        UserDefaults.yardlet.removeObject(forKey: SimulatorPreference.key)
    }

    /// The agent's tools as a harness calls them: the fixture hands the script the task's `yardlet-mcp` launch
    /// (`tools-launch.json`, then `tools-ready`), and the script's calls run until it writes `tools-done`. Meanwhile
    /// the first use of the device waits on the task's card, which the fixture captures and allows.
    private func checkAgentTools(_ identity: SimulatorDeviceIdentity, window: NSWindow, workspace: TaskWorkspaceState,
                                 captures prefix: String = "") async {
        model.simulatorTools.drivers[.iOS] = MacIOSSimulatorDriver(screens: MacSimulatorScreens.shared)
        model.simulatorTools.drivers[.android] = MacAndroidEmulatorDriver(screens: MacSimulatorScreens.shared)
        model.simulators.detach(session)
        // The person is using another tab: the agent's attach adds the Simulator tab beside it.
        workspace.setPanels(Navigation.showing("files", in: workspace.panels))
        let broker = MacAgentToolService.shared.broker
        // The script's yardlet-mcp runs under no harness of this task, which the endpoint otherwise refuses.
        let processCheck = broker.callerProcessCheck
        broker.callerProcessCheck = nil
        defer { broker.callerProcessCheck = processCheck }
        guard let launch = broker.agentToolServer(for: session, workspaceRoots: []) else {
            return check("tools: the task gets the tool server", false, "no launch")
        }
        let document: JSONValue = .object(["command": .string(launch.command),
                                           "env": .object(launch.environment.mapValues { .string($0) })])
        let launchFile = output.appending(path: "tools-launch.json")
        guard let data = try? JSONEncoder().encode(document),
              FileManager.default.createFile(atPath: launchFile.path(percentEncoded: false), contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            return check("tools: the launch is handed to the script", false, "")
        }
        try? "ready".write(to: output.appending(path: "tools-ready"), atomically: true, encoding: .utf8)
        let done = output.appending(path: "tools-done").path(percentEncoded: false)
        var cards = 0
        let deadline = ContinuousClock.now + .seconds(300)
        while !FileManager.default.fileExists(atPath: done), ContinuousClock.now < deadline {
            if let approval = model.sessionTools.approvals(for: session).first {
                cards += 1
                try? await Task.sleep(for: .seconds(1))
                await capture(window, prefix + "approval")
                model.sessionTools.answer(approval.id, allow: true)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        check("tools: the script's calls ended", FileManager.default.fileExists(atPath: done), "")
        check("tools: the device's first use asked the person once", cards == 1, "\(cards) cards")
        check("tools: a simulator's approval holds for every task",
              model.simulatorTools.approvals.isApproved(identity, for: UUID()), "")
        check("tools: the Simulator tab joined beside the tab the person uses",
              workspace.panels.trailingTabs.contains(Navigation.simulatorID) && workspace.panels.trailingSurfaceID == "files",
              "\(workspace.panels)")
        workspace.setPanels(Navigation.showing(Navigation.simulatorID, in: workspace.panels))
        try? await Task.sleep(for: .seconds(2))
        await capture(window, prefix + "tools")
    }

    /// The Android tools' paste puts back what the emulator's clipboard held: the fixture puts its own text there
    /// before the script's calls and reads it after them, through the stream the tools use.
    private func checkAndroidAgentTools(_ identity: SimulatorDeviceIdentity, serial: String, sdk: SimulatorToolchain,
                                        window: NSWindow, workspace: TaskWorkspaceState) async {
        let screens = MacSimulatorScreens.shared
        let target = MacSimulatorScreens.Target(device: identity, adbSerial: serial, toolchain: sdk)
        let marker = "Yardlet QA clipboard \(UUID().uuidString.prefix(8))"
        do {
            _ = try await screens.attachForTools(target)
            guard let (client, stream) = screens.androidStream(of: identity) else { throw SimulatorDriveError(message: "no stream") }
            try await client.setClipboard(marker, paste: false, on: stream)
            let read = try await client.clipboard(of: stream)
            check("clipboard: the emulator's clipboard reads back through the stream", read == marker, read ?? "nil")
        } catch {
            check("clipboard: the emulator's clipboard reads back through the stream", false, "\(error)")
        }
        screens.releaseForTools(identity)

        await checkAgentTools(identity, window: window, workspace: workspace, captures: "android-")

        do {
            _ = try await screens.attachForTools(target)
            guard let (client, stream) = screens.androidStream(of: identity) else { throw SimulatorDriveError(message: "no stream") }
            let after = try await client.clipboard(of: stream)
            check("tools: the paste puts back what the emulator's clipboard held", after == marker, after ?? "nil")
        } catch {
            check("tools: the paste puts back what the emulator's clipboard held", false, "\(error)")
        }
        screens.releaseForTools(identity)
    }

    private func runAndroid(avd: String) async {
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) else {
            return check("setup: the window opens", false, "no window")
        }
        var frame = window.frame
        frame.size = NSSize(width: 1400, height: 900)
        window.setFrame(frame, display: true)
        let workspace = model.taskWorkspaces.state(for: session)
        let screens = MacSimulatorScreens.shared

        // As `AppModel.live()` hands them in: the Mac's iOS simulators and Android emulators.
        let connected = ProcessInfo.processInfo.environment["YARDLET_SIMULATOR_QA_ANDROID_CONNECTED"]
        model.simulators = SimulatorCenter(backends: [
            MacIOSSimulatorBackend(),
            AndroidEmulatorBackend(runner: QADeviceCommands(connected: Set([connected].compactMap(\.self))))
        ])
        AppModel.wireSimulatorScreens(to: model)
        model.startSimulators(defaults: .yardlet)
        let center = model.simulators
        let checked = await waitUntil(.seconds(60)) { center.isEnabled && center.checks[.android] != nil }
        check("switch: the center finds the Android SDK", checked && center.checks[.android]?.availability == .available,
              "\(String(describing: center.checks[.android]))")

        let identity = SimulatorDeviceIdentity.androidEmulator(avd: avd)
        workspace.setPanels(Navigation.showing(Navigation.simulatorID, in: workspace.panels))
        let listed = await waitUntil(.seconds(30)) { center.device(identity)?.state == .on }
        check("list: the throwaway emulator is listed, running", listed,
              "\(center.devices.map { "\($0.name) \($0.state)" })")
        await capture(window, "android-list")

        let attached = await center.attach(identity, to: session, by: .person)
        check("attach: the emulator the person picked is attached and claimed, not started by Yardlet",
              { if case let .attached(attachment) = attached { return attachment.isClaimed && !attachment.isStartedByYardlet }
                return false }(), "\(attached)")
        let live = await waitUntil(.seconds(30)) { self.screenView(in: window)?.frameDisplay.current != nil }
        check("live: the emulator's stream is decoded into the panel", live,
              "\(String(describing: screens.link(of: identity)))")
        guard live, let view = screenView(in: window) else { return }
        let first = view.frameDisplay.current?.frame
        check("live: the stream's frames are the device's portrait screen",
              (first?.pixelHeight ?? 0) > (first?.pixelWidth ?? 0), "\(String(describing: first))")
        screens.pressNavigation(.home, on: identity)
        try? await Task.sleep(for: .seconds(2))
        await capture(window, "android-live")

        // Recents from the header's button path, then Home; a swipe up through the tab opens the app drawer.
        var before = view.frameDisplay.current?.frame.sequence ?? 0
        screens.pressNavigation(.recents, on: identity)
        let recents = await waitUntil(.seconds(10)) { (view.frameDisplay.current?.frame.sequence ?? 0) > before + 5 }
        check("input: Recents reaches the device", recents, "")
        try? await Task.sleep(for: .seconds(1))
        await capture(window, "android-recents")
        screens.pressNavigation(.home, on: identity)
        try? await Task.sleep(for: .seconds(2))
        before = view.frameDisplay.current?.frame.sequence ?? 0
        drag(view, in: window, from: CGPoint(x: 0.5, y: 0.85), to: CGPoint(x: 0.5, y: 0.3))
        let swiped = await waitUntil(.seconds(10)) { (view.frameDisplay.current?.frame.sequence ?? 0) > before + 5 }
        check("input: a swipe through the tab reaches the device", swiped && center.lastPersonInput(on: identity) != nil, "")
        try? await Task.sleep(for: .seconds(1))
        await capture(window, "android-drawer")
        screens.pressNavigation(.home, on: identity)

        // Turned with an app that turns: the tab takes the landscape screen, and the stream its frames.
        if let serial = center.device(identity)?.adbSerial, let sdk = center.toolchain(for: .android) {
            let adb = AndroidSDK(toolchain: sdk).adb
            await adbCommand(adb, serial, ["shell", "settings put system accelerometer_rotation 1; am start -W -a android.settings.SETTINGS"])
            await adbCommand(adb, serial, ["emu", "rotate"])
            let turned = await waitUntil(.seconds(20)) {
                guard case let .attached(screen) = screens.link(of: identity), let frame = view.frameDisplay.current?.frame
                else { return false }
                return screen.pixelWidth > screen.pixelHeight && frame.pixelWidth > frame.pixelHeight
            }
            let rect = view.screenRect
            check("rotation: the tab and the stream turn to landscape", turned && rect.width > rect.height, "\(rect)")
            try? await Task.sleep(for: .seconds(2))
            await capture(window, "android-turned")
            for _ in 0..<3 { await adbCommand(adb, serial, ["emu", "rotate"]) }
            _ = await waitUntil(.seconds(20)) { (view.frameDisplay.current?.frame).map { $0.pixelHeight > $0.pixelWidth } ?? false }
            screens.pressNavigation(.home, on: identity)
            try? await Task.sleep(for: .seconds(1))
            if let connected { await runConnected(connected, adb: adb, window: window) }

            await checkAndroidAgentTools(identity, serial: serial, sdk: sdk, window: window, workspace: workspace)

            // Turned off: the tab closes, the screen is let go, and the server on the device ends with the stream.
            UserDefaults.yardlet.set(false, forKey: SimulatorPreference.key)
            let closed = await waitUntil(.seconds(20)) {
                !workspace.panels.trailingTabs.contains(Navigation.simulatorID) && !center.isEnabled
                    && screens.link(of: identity) == nil
            }
            var serverEnded = false
            for _ in 0..<100 where !serverEnded {
                serverEnded = !(await adbCommand(adb, serial, ["shell", "ps -A -o ARGS"]))
                    .contains("com.genymobile.scrcpy.Server")
                if !serverEnded { try? await Task.sleep(for: .milliseconds(100)) }
            }
            check("switch off: the tab closes, the screen is let go, the server on the device ends", closed && serverEnded,
                  "tabs \(workspace.panels.trailingTabs), enabled \(center.isEnabled), server ended \(serverEnded)")
        } else {
            check("rotation: the emulator's serial and SDK are known", false, "")
        }
        workspace.setPanels(Navigation.showing(Navigation.launcherID, in: workspace.panels))
        try? await Task.sleep(for: .seconds(1))
        await capture(window, "android-off")
        UserDefaults.yardlet.removeObject(forKey: SimulatorPreference.key)
    }

    /// The throwaway emulator again, at the address the script connected it, as a real device.
    private func runConnected(_ address: String, adb: URL, window: NSWindow) async {
        let center = model.simulators
        let screens = MacSimulatorScreens.shared
        let serialNumber = (await adbCommand(adb, address, ["shell", "getprop ro.serialno"]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = SimulatorDeviceIdentity.androidDevice(serialNumber: serialNumber)
        var listed = false
        for _ in 0..<30 where !listed {
            await center.refreshDevices()
            listed = center.device(identity)?.adbSerial == address
            if !listed { try? await Task.sleep(for: .seconds(1)) }
        }
        let realDevices = center.devices.filter { $0.identity.kind == .androidDevice }
        check("connected: listed as a real device by the serial number it reports, and the only one",
              listed && !serialNumber.isEmpty && realDevices.map(\.adbSerial) == [address],
              "\(serialNumber) \(realDevices.map { "\($0.name) \($0.adbSerial ?? "")" })")
        guard listed else { return }
        await capture(window, "android-connected-list")

        let attached = await center.attach(identity, to: session, by: .person)
        check("connected: the person attaches it; Yardlet did not start it and offers no Shut Down",
              { if case let .attached(attachment) = attached { return attachment.isClaimed && !attachment.isStartedByYardlet }
                return false }()
                && !SimulatorDeviceMenu.make(for: session, in: center, taskTitle: { _ in nil }).items.contains(.shutDown),
              "\(attached)")
        let live = await waitUntil(.seconds(30)) {
            if case .attached = screens.link(of: identity) { return self.screenView(in: window)?.frameDisplay.current != nil }
            return false
        }
        check("connected: its stream is decoded into the panel", live, "\(String(describing: screens.link(of: identity)))")
        guard live, let view = screenView(in: window) else { return }
        screens.pressNavigation(.home, on: identity)
        try? await Task.sleep(for: .seconds(2))
        await capture(window, "android-connected-live")
        let before = view.frameDisplay.current?.frame.sequence ?? 0
        screens.pressNavigation(.recents, on: identity)
        let recents = await waitUntil(.seconds(10)) { (view.frameDisplay.current?.frame.sequence ?? 0) > before + 5 }
        check("connected: Recents reaches it", recents, "")
        try? await Task.sleep(for: .seconds(1))
        await capture(window, "android-connected-recents")
        screens.pressNavigation(.home, on: identity)

        // The agents' tools do not use real devices yet: not listed to them, an attach refused, nothing acted on.
        let tools = model.simulatorTools
        let list = await tools.run(tool: SimulatorToolCatalog.list, arguments: .object([:]), task: session)
        let attach = await tools.run(tool: SimulatorToolCatalog.attach, arguments: .object(["device": .string(address)]),
                                     task: session)
        let tap = await tools.run(tool: SimulatorToolCatalog.tap, arguments: .object(["x": .integer(1), "y": .integer(1)]),
                                  task: session)
        check("connected: the agents' tools leave it to the person",
              !list.text.contains(address) && attach.failure?.kind == .refused && tap.failure?.kind == .refused
                  && model.sessionTools.approvals(for: session).isEmpty,
              "\(list.text) | \(attach.text) | \(tap.text)")
    }

    /// A finger dragged through the screen view over a quarter of a second, between points given as fractions of the
    /// screen.
    private func drag(_ view: SimulatorScreenView, in window: NSWindow, from start: CGPoint, to end: CGPoint) {
        let rect = view.screenRect
        func event(_ type: NSEvent.EventType, _ fraction: CGPoint) -> NSEvent? {
            let point = view.convert(NSPoint(x: rect.minX + fraction.x * rect.width, y: rect.minY + fraction.y * rect.height),
                                     to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                      pressure: type == .leftMouseUp ? 0 : 1)
        }
        if let down = event(.leftMouseDown, start) { view.mouseDown(with: down) }
        for step in 1...15 {
            let fraction = CGFloat(step) / 15
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            if let moved = event(.leftMouseDragged, point) { view.mouseDragged(with: moved) }
        }
        if let up = event(.leftMouseUp, end) { view.mouseUp(with: up) }
    }

    @discardableResult
    private func adbCommand(_ adb: URL, _ serial: String, _ arguments: [String]) async -> String {
        await CLIProcess.run(CLICommand(executable: adb, arguments: ["-s", serial] + arguments, timeout: .seconds(30))).stdout
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
/// The QA app's adb commands: to emulators, and to the one real device the check connected; any other real device on
/// this Mac, a person's own phone, is never sent one, so it is not listed either.
private struct QADeviceCommands: CLICommandRunning {
    let connected: Set<String>

    func run(_ command: CLICommand) async -> CLICommandResult {
        if let flag = command.arguments.firstIndex(of: "-s"), flag + 1 < command.arguments.count {
            let serial = command.arguments[flag + 1]
            guard serial.hasPrefix("emulator-") || connected.contains(serial) else {
                return CLICommandResult(exitCode: 1, stdout: "", stderr: "not a device of this check")
            }
        }
        return await LiveCLICommandRunner().run(command)
    }
}
#endif
