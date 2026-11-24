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
/// allows, and add the Simulator tab beside the tab the person uses; their handoff shows the Simulator tab with its bar,
/// which the fixture captures and, by the handoff's reason, leaves to time out or answers with I'm done or Decline;
/// turning the switch off closes the tab, takes Simulator out of the launcher, lets the device go and removes the
/// approval. Captures `{launcher,list,live,settings,approval,handoff,tools,off}-{light,dark}.png` and writes
/// `result.json`; the device is never
/// started or stopped here.
///
/// With `YARDLET_SIMULATOR_QA_ANDROID_AVD` instead, run by scripts/simulator-qa/run-android-panel-check.sh against a
/// throwaway emulator it started, the same for Android: the emulator listed beside the iOS simulators, its live
/// screen through the bundle's scrcpy server with Back, Home and Recents in the tab's header, Recents and a swipe
/// through the tab, the screen turned to landscape, the agent's tools as above (drive-tools.py with `android`), whose
/// paste leaves the device's clipboard as it was, and, with the switch off, the tab closed and the stream and the
/// server on the device ended. Captures
/// `android-{list,live,recents,drawer,turned,approval,handoff,tools,off}-{light,dark}.png`.
/// With `YARDLET_SIMULATOR_QA_ANDROID_CONNECTED` as well, the address the script connected the same emulator at
/// (`adb connect 127.0.0.1:<port>`), it is then checked as a real device is: listed by the serial number it reports,
/// live and driven through the tab, never started or stopped by Yardlet, and used by the agents' tools after the real
/// device's card in the task (`android-connected-{list,live,recents,approval}-{light,dark}.png`). adb commands go only
/// to emulators and that address, so a person's own phone on this Mac is neither sent one nor listed.
///
/// With `YARDLET_SIMULATOR_QA_ANDROID_INSTALL`, run by scripts/simulator-qa/run-android-install-check.sh, the tab's
/// Install for Android for real into a QA home (`runAndroidInstall`). With `YARDLET_SIMULATOR_QA_ANDROID_DEVICE`, run by
/// scripts/simulator-qa/run-android-device-check.sh, a real phone on USB by its adb serial (`runAndroidDevice`): only
/// Settings is opened on it, and adb commands go to it and to emulators alone.
@MainActor
final class SimulatorPanelQA {
    private typealias Navigation = TaskSurfaceNavigationProjection
    /// The Simulator tab the fixture opens, by its key.
    private static let simulatorTab = UUID(uuidString: "51A0C0DE-0000-4000-8000-000000000001")!
    private static var simulatorTabID: String { Navigation.simulatorTabID(simulatorTab) }
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
        if let root = ProcessInfo.processInfo.environment["YARDLET_SIMULATOR_QA_ANDROID_INSTALL"] {
            return await runAndroidInstall(root: URL(filePath: root, directoryHint: .isDirectory))
        }
        if let serial = ProcessInfo.processInfo.environment["YARDLET_SIMULATOR_QA_ANDROID_DEVICE"] {
            return await runAndroidDevice(serial: serial)
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

        workspace.setPanels(Navigation.showing(Self.simulatorTabID, in: workspace.panels))
        let listed = await waitUntil(.seconds(30)) { center.device(.iOSSimulator(udid: device.uuidString)) != nil }
        check("list: the throwaway device is listed", listed, "\(center.devices.count) devices")
        await capture(window, "list")

        // The device picked shows live, through the bundle's helper.
        let identity = SimulatorDeviceIdentity.iOSSimulator(udid: device.uuidString)
        let attached = await center.attach(identity, to: session, tab: Self.simulatorTab, by: .person)
        check("attach: the device the person picked is attached and claimed",
              { if case let .attached(attachment) = attached { return attachment.isClaimed && !attachment.isStartedByYardlet }
                return false }(), "\(attached)")
        let live = await waitUntil(.seconds(30)) { self.screenView(in: window)?.frameDisplay.current != nil }
        check("live: the bundle's helper sends frames into the panel", live,
              "\(String(describing: MacSimulatorScreens.shared.link(of: identity)))")
        check("tab: the task keeps the device it attached", workspace.simulators[Self.simulatorTab] == identity, "")
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

        // A second Simulator tab, as Simulator in the + menu opens one: it lists the devices while the first keeps its
        // device; closing it returns to the first, its device live and still claimed.
        let second = Navigation.simulatorTabID(UUID())
        workspace.setPanels(Navigation.showing(second, in: workspace.panels))
        let listing = await waitUntil(.seconds(10)) { self.screenView(in: window) == nil }
        try? await Task.sleep(for: .seconds(1))
        await capture(window, "second-tab")
        check("tabs: a second Simulator tab lists the devices, the first keeps its device",
              listing && workspace.panels.trailingTabs.filter { Navigation.simulatorKey(inTab: $0) != nil }.count == 2
                  && workspace.simulators[Self.simulatorTab] == identity, "\(workspace.panels.trailingTabs)")
        workspace.setPanels(Navigation.closingTrailingTab(second, in: workspace.panels))
        let back = await waitUntil(.seconds(15)) { self.screenView(in: window)?.frameDisplay.current != nil }
        check("tabs: closing the second tab returns to the first, its device live and claimed",
              back && workspace.panels.trailingSurfaceID == Self.simulatorTabID && center.claims[identity] == session,
              "\(workspace.panels)")

        await checkAgentTools(identity, window: window, workspace: workspace)

        // Turned off: every Simulator tab closes, the launcher leaves Simulator out, and the helper lets the device go.
        UserDefaults.yardlet.set(false, forKey: SimulatorPreference.key)
        let closed = await waitUntil(.seconds(20)) {
            !workspace.panels.trailingTabs.contains { Navigation.simulatorKey(inTab: $0) != nil } && !center.isEnabled
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
        model.simulators.detach(session, tab: Self.simulatorTab)
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
        // The panel before the first handoff, which shows the Simulator tab, and the handoffs' answers by the fixture.
        var placement = workspace.panels
        var handoffShown: Bool?
        var answers: [SimulatorHandoff.Answer] = []
        let handoffs = model.simulatorTools.handoffs
        let deadline = ContinuousClock.now + .seconds(300)
        while !FileManager.default.fileExists(atPath: done), ContinuousClock.now < deadline {
            if let approval = model.sessionTools.approvals(for: session).first {
                cards += 1
                try? await Task.sleep(for: .seconds(1))
                await capture(window, prefix + "approval")
                model.sessionTools.answer(approval.id, allow: true)
            }
            if let handoff = handoffs.waiting(for: session) {
                if handoffShown == nil {
                    handoffShown = workspace.panels.trailingSurfaceID == Self.simulatorTabID
                    try? await Task.sleep(for: .seconds(1))
                    await capture(window, prefix + "handoff")
                }
                let answer: SimulatorHandoff.Answer? = handoff.reason.hasPrefix("QA: press I'm done") ? .done
                    : handoff.reason.hasPrefix("QA: press Decline") ? .declined : nil
                if let answer, handoffs.answer(answer, for: session) { answers.append(answer) }
            } else if handoffShown == nil {
                placement = workspace.panels
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        check("tools: the script's calls ended", FileManager.default.fileExists(atPath: done), "")
        check("tools: the device's first use asked the person once", cards == 1, "\(cards) cards")
        check("tools: a simulator's approval holds for every task",
              model.simulatorTools.approvals.isApproved(identity, for: UUID()), "")
        check("tools: the Simulator tab joined beside the tab the person uses",
              placement.trailingTabs.contains(Self.simulatorTabID) && placement.trailingSurfaceID == "files",
              "\(placement)")
        check("tools: a handoff shows the Simulator tab with its bar", handoffShown == true,
              "\(String(describing: handoffShown))")
        check("tools: the fixture answered the handoffs as the person, I'm done then Decline", answers == [.done, .declined],
              "\(answers)")
        check("tools: no handoff waits once the calls ended", handoffs.handoff(for: session) == nil, "")
        workspace.setPanels(Navigation.showing(Self.simulatorTabID, in: workspace.panels))
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
        workspace.setPanels(Navigation.showing(Self.simulatorTabID, in: workspace.panels))
        let listed = await waitUntil(.seconds(30)) { center.device(identity)?.state == .on }
        check("list: the throwaway emulator is listed, running", listed,
              "\(center.devices.map { "\($0.name) \($0.state)" })")
        await capture(window, "android-list")

        let attached = await center.attach(identity, to: session, tab: Self.simulatorTab, by: .person)
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
                !workspace.panels.trailingTabs.contains(Self.simulatorTabID) && !center.isEnabled
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

        let attached = await center.attach(identity, to: session, tab: Self.simulatorTab, by: .person)
        check("connected: the person attaches it; Yardlet did not start it and offers no Shut Down",
              { if case let .attached(attachment) = attached { return attachment.isClaimed && !attachment.isStartedByYardlet }
                return false }()
                && !SimulatorDeviceMenu.make(for: session, tab: Self.simulatorTab, in: center, taskTitle: { _ in nil }).items.contains(.shutDown),
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

        // The agents' tools: listed as a real device; the first use in this task asks on the real device's card, which
        // says what it can reach; allowed, a screenshot is its screen in dp, Recents reaches it and a snapshot reads its
        // elements. The approval holds in this task only.
        let tools = model.simulatorTools
        tools.drivers[.android] = MacAndroidEmulatorDriver(screens: MacSimulatorScreens.shared)
        let list = await tools.run(tool: SimulatorToolCatalog.list, arguments: .object([:]), task: session)
        let attaching = Task { @MainActor in
            await tools.run(tool: SimulatorToolCatalog.attach, arguments: .object(["device": .string(address)]),
                            task: session)
        }
        var card: PermissionRequest?
        for _ in 0..<150 where card == nil {
            if let approval = model.sessionTools.approvals(for: session).first {
                card = approval.request
                try? await Task.sleep(for: .seconds(1))
                await capture(window, "android-connected-approval")
                model.sessionTools.answer(approval.id, allow: true)
            } else {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        let attach = await attaching.value
        let warned = (card?.detail ?? "").contains(L10n.string("Pictures and text from its screen are sent to the model's provider."))
        check("connected: the agents' tools list it as a real device and ask for it on its card in this task",
              list.text.contains(#""realDevice":true"#) && list.text.contains(address) && warned && !attach.isError
                  && attach.text.contains("real Android device")
                  && !model.simulatorTools.approvals.isApproved(identity, for: UUID()),
              "\(list.text) | \(String(describing: card)) | \(attach.text)")
        let shot = await tools.run(tool: SimulatorToolCatalog.screenshot, arguments: .object(["format": .string("png")]),
                                   task: session)
        let pressedAt = view.frameDisplay.current?.frame.sequence ?? 0
        let press = await tools.run(tool: SimulatorToolCatalog.press, arguments: .object(["button": .string("recents")]),
                                    task: session)
        let moved = await waitUntil(.seconds(10)) { (view.frameDisplay.current?.frame.sequence ?? 0) > pressedAt + 5 }
        check("connected: allowed, the tools take its screenshot in dp and press Recents on it",
              !shot.isError && shot.text.contains("dp") && !press.isError && moved, "\(shot.text) | \(press.text)")
        // A snapshot reads it through UI Automator as an emulator's is, with references to tap.
        screens.pressNavigation(.home, on: identity)
        try? await Task.sleep(for: .seconds(2))
        let snapshot = await tools.run(tool: SimulatorToolCatalog.snapshot, arguments: .object([:]), task: session)
        check("connected: a snapshot reads its elements with references",
              !snapshot.isError && snapshot.text.contains("dp") && snapshot.text.contains("[ref=@e1]"),
              String(snapshot.text.prefix(600)))
        screens.pressNavigation(.home, on: identity)
    }

    /// A real phone on USB, awake and unlocked: listed by the serial number it reports, never started or stopped, shown
    /// live with Settings open, which a swipe through the tab scrolls; the agents' tools after its card take its
    /// screenshot in dp, swipe Settings and read its elements. Home then leaves Settings, so the phone's own timeout turns
    /// its screen off, and with the switch off the server on the phone ends and leaves no file. Nothing else on the
    /// phone is opened, changed or installed, and its screen's text is not written down: Settings shows the person's
    /// account. Captures `device-settings-{light,dark}.png`.
    private func runAndroidDevice(serial: String) async {
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) else {
            return check("setup: the window opens", false, "no window")
        }
        var frame = window.frame
        frame.size = NSSize(width: 1400, height: 900)
        window.setFrame(frame, display: true)
        let workspace = model.taskWorkspaces.state(for: session)
        let screens = MacSimulatorScreens.shared
        model.simulators = SimulatorCenter(backends: [AndroidEmulatorBackend(runner: QADeviceCommands(connected: [serial]))])
        AppModel.wireSimulatorScreens(to: model)
        model.startSimulators(defaults: .yardlet)
        let center = model.simulators
        let available = await waitUntil(.seconds(60)) { center.checks[.android]?.availability == .available }
        guard available, let sdk = center.toolchain(for: .android) else {
            return check("device: the center finds the Android SDK", false, "\(String(describing: center.checks[.android]))")
        }
        let adb = AndroidSDK(toolchain: sdk).adb
        workspace.setPanels(Navigation.showing(Self.simulatorTabID, in: workspace.panels))
        var device: SimulatorDevice?
        for _ in 0..<30 where device == nil {
            await center.refreshDevices()
            device = center.devices.first { $0.identity.kind == .androidDevice && $0.adbSerial == serial }
            if device == nil { try? await Task.sleep(for: .seconds(1)) }
        }
        let realDevices = center.devices.filter { $0.identity.kind == .androidDevice }
        check("device: listed as a real device by the serial number it reports, and the only one",
              device != nil && realDevices.count == 1, "\(realDevices.map { "\($0.osName) \($0.adbSerial ?? "")" })")
        guard let device else { return }
        let identity = device.identity

        // Settings first, so the tab shows nothing else of the phone's.
        await adbCommand(adb, serial, ["shell", "am start -W -a android.settings.SETTINGS"])
        let attached = await center.attach(identity, to: session, tab: Self.simulatorTab, by: .person)
        check("device: the person attaches it; Yardlet did not start it and offers no Shut Down",
              { if case let .attached(attachment) = attached { return attachment.isClaimed && !attachment.isStartedByYardlet }
                return false }()
                && !SimulatorDeviceMenu.make(for: session, tab: Self.simulatorTab, in: center, taskTitle: { _ in nil }).items.contains(.shutDown),
              "\(attached)")
        let live = await waitUntil(.seconds(30)) {
            if case .attached = screens.link(of: identity) { return self.screenView(in: window)?.frameDisplay.current != nil }
            return false
        }
        let first = screenView(in: window)?.frameDisplay.current?.frame
        check("device: its stream is decoded into the panel, the phone's portrait screen",
              live && (first?.pixelHeight ?? 0) > (first?.pixelWidth ?? 0), "\(String(describing: screens.link(of: identity)))")
        guard live, let view = screenView(in: window) else { return }
        try? await Task.sleep(for: .seconds(2))
        var before = view.frameDisplay.current?.frame.sequence ?? 0
        drag(view, in: window, from: CGPoint(x: 0.5, y: 0.75), to: CGPoint(x: 0.5, y: 0.35))
        let scrolled = await waitUntil(.seconds(10)) { (view.frameDisplay.current?.frame.sequence ?? 0) > before + 5 }
        check("device: a swipe through the tab scrolls Settings", scrolled && center.lastPersonInput(on: identity) != nil, "")
        try? await Task.sleep(for: .seconds(2))
        await capture(window, "device-settings")

        // The agents' tools on it, after its card in this task.
        let tools = model.simulatorTools
        tools.drivers[.android] = MacAndroidEmulatorDriver(screens: screens)
        let list = await tools.run(tool: SimulatorToolCatalog.list, arguments: .object([:]), task: session)
        let attaching = Task { @MainActor in
            await tools.run(tool: SimulatorToolCatalog.attach, arguments: .object(["device": .string(serial)]), task: session)
        }
        var card: PermissionRequest?
        for _ in 0..<150 where card == nil {
            if let approval = model.sessionTools.approvals(for: session).first {
                card = approval.request
                model.sessionTools.answer(approval.id, allow: true)
            } else {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        let attach = await attaching.value
        let warned = (card?.detail ?? "").contains(L10n.string("Pictures and text from its screen are sent to the model's provider."))
        check("device: the agents' tools list it as a real device and ask for it on its card",
              list.text.contains(#""realDevice":true"#) && list.text.contains(serial) && warned && !attach.isError,
              "card \(card != nil), warned \(warned), attach error \(attach.isError)")
        let shot = await tools.run(tool: SimulatorToolCatalog.screenshot, arguments: .object(["format": .string("jpeg")]),
                                   task: session)
        var swiped = false
        if case let .attached(screen) = screens.link(of: identity), screen.scale > 0 {
            let width = Double(screen.pixelWidth) / screen.scale
            let height = Double(screen.pixelHeight) / screen.scale
            before = view.frameDisplay.current?.frame.sequence ?? 0
            let swipe = await tools.run(tool: SimulatorToolCatalog.swipe, arguments: .object([
                "x": .number(width / 2), "y": .number(height * 0.7), "x2": .number(width / 2), "y2": .number(height * 0.4)
            ]), task: session)
            let moved = await waitUntil(.seconds(10)) { (view.frameDisplay.current?.frame.sequence ?? 0) > before + 5 }
            swiped = !swipe.isError && moved
        }
        let snapshot = await tools.run(tool: SimulatorToolCatalog.snapshot, arguments: .object([:]), task: session)
        check("device: allowed, the tools take its screenshot in dp, swipe Settings and read its elements",
              !shot.isError && shot.text.contains("dp") && swiped && !snapshot.isError && snapshot.text.contains("[ref=@e1]"),
              "screenshot error \(shot.isError), swiped \(swiped), snapshot error \(snapshot.isError)")
        screens.releaseForTools(identity)

        // Home leaves Settings; turned off, the tab closes and the server on the phone ends, leaving no file.
        screens.pressNavigation(.home, on: identity)
        try? await Task.sleep(for: .seconds(1))
        UserDefaults.yardlet.set(false, forKey: SimulatorPreference.key)
        let closed = await waitUntil(.seconds(20)) {
            !workspace.panels.trailingTabs.contains(Self.simulatorTabID) && !center.isEnabled && screens.link(of: identity) == nil
        }
        var serverEnded = false
        for _ in 0..<100 where !serverEnded {
            serverEnded = !(await adbCommand(adb, serial, ["shell", "ps -A -o ARGS"])).contains("com.genymobile.scrcpy.Server")
            if !serverEnded { try? await Task.sleep(for: .milliseconds(100)) }
        }
        let left = (await adbCommand(adb, serial, ["shell", "ls /data/local/tmp"])).split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("yardlet-scrcpy-") }
        check("device: switched off, the tab closes, the server on the phone ends and leaves no file",
              closed && serverEnded && left.isEmpty, "closed \(closed), server ended \(serverEnded), left \(left)")
        UserDefaults.yardlet.removeObject(forKey: SimulatorPreference.key)
    }

    /// The Simulator tab's Install for Android, for real, into the QA home: everything the install writes must be in
    /// `root`, or nothing starts. The offer from Google's lists, the download with its progress, the packages checked
    /// and unpacked, the licenses' acceptance as sdkmanager writes it, the AVD made, listed and started without a
    /// window, its live screen; then the script checks the SDK with Google's own tools (`sdk-ready`, `sdk-checked`), and
    /// turning the switch off asks to remove what Yardlet installed, removes that and leaves an AVD of the person's.
    private func runAndroidInstall(root: URL) async {
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) else {
            return check("setup: the window opens", false, "no window")
        }
        var frame = window.frame
        frame.size = NSSize(width: 1400, height: 900)
        window.setFrame(frame, display: true)
        let workspace = model.taskWorkspaces.state(for: session)
        var notes: [String: JSONValue] = [:]
        defer {
            try? JSONEncoder().encode(JSONValue.object(notes)).write(to: output.appending(path: "install.json"))
        }

        // Where the SDK and the AVDs would go: every place must be in the QA folder.
        await LoginShellPath.ready()
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let places = AndroidSDKLocator.candidates(environment: environment, loginShellPath: LoginShellPath.value, home: home)
            + [AndroidSDKLocator.avdHome(environment: environment, home: home), home]
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let outside = places.filter { !$0.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false).hasPrefix(base) }
        check("install: the SDK and AVD folders are all in the QA folder", outside.isEmpty,
              "\(places.map(\.nativePath))")
        guard outside.isEmpty else { return }
        let sdk = home.appending(path: "Library/Android/sdk", directoryHint: .isDirectory)
        let avds = AndroidSDKLocator.avdHome(environment: environment, home: home)

        // As `AppModel.live()` hands them in, with adb commands only to emulators: a phone on this Mac is never asked.
        model.simulators = SimulatorCenter(backends: [AndroidEmulatorBackend(runner: QADeviceCommands(connected: []))])
        AppModel.wireSimulatorScreens(to: model)
        AppModel.wireSimulatorInstalls(to: model)
        var question: SimulatorRemovalQuestion?
        let emulator = QAEmulatorProcess()
        var runningWhenAsked = false
        model.askToRemoveSimulatorInstalls = { items in
            question = SimulatorRemovalQuestion(items: items)
            runningWhenAsked = emulator.isRunning
            return true
        }
        UserDefaults.yardlet.removeObject(forKey: SimulatorPreference.key)
        model.startSimulators(defaults: .yardlet)
        let center = model.simulators
        let installs = model.simulatorInstalls
        workspace.setPanels(Navigation.showing(Self.simulatorTabID, in: workspace.panels))
        let missing = await waitUntil(.seconds(60)) { center.checks[.android]?.availability == .sdkMissing }
        check("install: the tab finds no Android SDK", missing, "\(String(describing: center.checks[.android]))")
        guard missing, let check = center.checks[.android] else { return }
        await capture(window, "install-missing")

        // Install: Google's lists name the download and its licenses.
        installs.prepare(.android, check: check, openURL: { _ in })
        let offered = await waitUntil(.seconds(120)) {
            if case .offered = installs.state(of: .android) { return true }
            if case .failed = installs.state(of: .android) { return true }
            return false
        }
        guard offered, case let .offered(offer) = installs.state(of: .android),
              case let .download(_, bytes, licenses) = offer else {
            return self.check("install: the offer reads Google's lists", false, "\(installs.state(of: .android))")
        }
        notes["offerBytes"] = .number(Double(bytes ?? 0))
        notes["licenses"] = .array(licenses.map { .string($0.id) })
        self.check("install: the offer reads Google's lists", (bytes ?? 0) > 1_000_000_000 && !licenses.isEmpty,
                   "\(bytes ?? 0) bytes, \(licenses.map(\.id))")
        await capture(window, "install-offer")

        // Download: the progress moves forward, then the packages unpack.
        let started = ContinuousClock.now
        installs.confirm(.android, check: check)
        var fractions: [Double] = []
        var unpacking: Duration?
        var captured = false
        let deadline = ContinuousClock.now + .seconds(3600)
        while ContinuousClock.now < deadline {
            let state = installs.state(of: .android)
            guard case let .installing(_, progress) = state else { break }
            if let fraction = progress.fraction, fraction != fractions.last { fractions.append(fraction) }
            if progress.stage == .installing, unpacking == nil { unpacking = started.duration(to: .now) }
            if !captured, (progress.fraction ?? 0) > 0.3 {
                captured = true
                await capture(window, "install-progress")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let took = started.duration(to: .now)
        notes["installSeconds"] = .number(took / .seconds(1))
        notes["progressSteps"] = .number(Double(fractions.count))
        let failed: String? = if case let .failed(message) = installs.state(of: .android) { message } else { nil }
        self.check("install: the download reports its progress, rising, and the install ends",
                   failed == nil && fractions.count > 10 && fractions == fractions.sorted() && (fractions.last ?? 0) > 0.95,
                   "\(failed ?? "") \(fractions.count) steps, last \(fractions.last ?? 0), \(took)")
        guard failed == nil else { return }

        // What is there: the programs, the image, the licenses as sdkmanager writes them, the AVD.
        let files = FileManager.default
        let image = (try? files.contentsOfDirectory(atPath: sdk.appending(path: "system-images").nativePath)) ?? []
        let accepted = ["android-sdk-license", "android-sdk-arm-dbt-license"].map {
            (try? String(contentsOf: sdk.appending(path: "licenses/\($0)"), encoding: .utf8)) ?? ""
        }
        // The hashes Android Studio and sdkmanager write for the same texts.
        let known = accepted[0].contains("24333f8a63b6825ea9c5514f83c2829b004d1fee")
            && accepted[1].contains("859f317696f67ef3d7f30a50a5560e7834b43903")
        self.check("install: adb, the emulator and a system image are in the SDK, with the licenses sdkmanager reads",
                   files.isExecutableFile(atPath: AndroidSDK(root: sdk).adb.nativePath)
                       && files.isExecutableFile(atPath: AndroidSDK(root: sdk).emulator.nativePath) && !image.isEmpty && known,
                   "\(image) \(accepted)")
        notes["sdkKilobytes"] = .number(Double(await Self.kilobytes(sdk)))
        let identity = SimulatorDeviceIdentity.androidEmulator(avd: AndroidSDKInstaller.avdName)
        let listed = await waitUntil(.seconds(60)) {
            center.checks[.android]?.availability == .available && center.device(identity) != nil
        }
        self.check("install: the tab finds the SDK and lists the AVD it made", listed,
                   "\(String(describing: center.checks[.android])) \(center.devices.map(\.name))")
        guard listed else { return }
        await capture(window, "install-list")

        // The AVD starts without a window and shows live in the tab.
        let booting = ContinuousClock.now
        let attached = await center.attach(identity, to: session, tab: Self.simulatorTab, by: .person)
        let on = center.state(of: identity) == .on
        notes["bootSeconds"] = .number(booting.duration(to: .now) / .seconds(1))
        self.check("install: the AVD boots (sys.boot_completed), started by Yardlet",
                   on && { if case let .attached(attachment) = attached { return attachment.startedNow }
                           return false }(), "\(attached)")
        let live = await waitUntil(.seconds(60)) { self.screenView(in: window)?.frameDisplay.current != nil }
        self.check("install: its screen is live in the tab", live,
                   "\(String(describing: MacSimulatorScreens.shared.link(of: identity)))")
        try? await Task.sleep(for: .seconds(3))
        await capture(window, "install-live")
        notes["avdKilobytes"] = .number(Double(await Self.kilobytes(avds)))
        emulator.processID = center.startedByYardlet[identity]?.boot.processID

        // Google's own tools read the SDK while it is there.
        try? "ready".write(to: output.appending(path: "sdk-ready"), atomically: true, encoding: .utf8)
        _ = await waitUntil(.seconds(600)) { FileManager.default.fileExists(atPath: self.output.appending(path: "sdk-checked").nativePath) }

        // An AVD of the person's beside it, which removing must leave.
        let person = avds.appending(path: "Person_Phone.avd", directoryHint: .isDirectory)
        try? files.createDirectory(at: person, withIntermediateDirectories: true)
        try? "avd.ini.displayname=Person Phone\n".write(to: person.appending(path: "config.ini"), atomically: true, encoding: .utf8)
        try? "path=\(person.nativePath)\n".write(to: avds.appending(path: "Person_Phone.ini"), atomically: true, encoding: .utf8)

        // Turned off: the emulator Yardlet started stops, then the question lists what Yardlet installed, which goes.
        UserDefaults.yardlet.set(false, forKey: SimulatorPreference.key)
        let removed = await waitUntil(.seconds(300)) {
            !files.fileExists(atPath: sdk.nativePath) && !files.fileExists(atPath: avds.appending(path: "Yardlet_Phone.ini").nativePath)
        }
        let stopped = await waitUntil(.seconds(120)) { emulator.processID != nil && !emulator.isRunning }
        // Anything the emulator wrote as it stopped would show here.
        try? await Task.sleep(for: .seconds(10))
        let leftovers = [sdk, avds.appending(path: "Yardlet_Phone.avd")].filter { files.fileExists(atPath: $0.nativePath) }
        let message = question?.message ?? ""
        self.check("install: turning the switch off stops the emulator and asks to remove only what Yardlet installed",
                   stopped && !runningWhenAsked
                       && question?.title == L10n.string("Remove what Yardlet installed for simulators?")
                       && message.contains("Yardlet_Phone") && !message.contains("Person_Phone"),
                   "stopped \(stopped), running when asked \(runningWhenAsked) | \(question?.title ?? "no question") | \(message)")
        self.check("install: removing leaves nothing Yardlet installed, and the person's AVD",
                   removed && leftovers.isEmpty && files.fileExists(atPath: avds.appending(path: "Person_Phone.ini").nativePath)
                       && files.fileExists(atPath: person.nativePath),
                   "leftovers \(leftovers.map(\.nativePath))")
        UserDefaults.yardlet.removeObject(forKey: SimulatorPreference.key)
    }

    /// The disk space a folder takes, in kilobytes, as `du` counts it.
    private static func kilobytes(_ folder: URL) async -> Int {
        let result = await CLIProcess.run(CLICommand(executable: URL(filePath: "/usr/bin/du"),
                                                     arguments: ["-sk", folder.nativePath], timeout: .seconds(120)))
        return Int(result.stdout.split(separator: "\t").first ?? "") ?? 0
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

/// The emulator the install check started, which the removal question looks at as it is asked.
private final class QAEmulatorProcess: @unchecked Sendable {
    var processID: Int32?
    var isRunning: Bool { processID.map { kill($0, 0) == 0 } ?? false }
}
#endif
