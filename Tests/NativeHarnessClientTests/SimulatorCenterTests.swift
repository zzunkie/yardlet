import Foundation
@testable import NativeHarnessClient
import XCTest
import YardletAgentTools

@MainActor
final class SimulatorCenterTests: XCTestCase {
    private let phoneA = "0A000000-0000-4000-8000-00000000000A"
    private let phoneB = "0B000000-0000-4000-8000-00000000000B"
    private let phoneC = "0C000000-0000-4000-8000-00000000000C"
    private let phoneD = "0D000000-0000-4000-8000-00000000000D"

    func testReadsSimctlListsAndPicksAFullXcode() throws {
        let listing = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.watchOS-12-0": [
            {"udid": "1E000000-0000-4000-8000-000000000001", "name": "Test Watch", "state": "Shutdown", "isAvailable": true}],
          "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
            {"udid": "26000000-0000-4000-8000-000000000001", "name": "Older Phone", "state": "Shutdown", "isAvailable": true},
            {"udid": "26000000-0000-4000-8000-000000000002", "name": "Broken Phone", "state": "Shutdown", "isAvailable": false}],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
            {"udid": "27000000-0000-4000-8000-000000000002", "name": "Test Pad", "state": "Shutdown", "isAvailable": true},
            {"udid": "27000000-0000-4000-8000-000000000001", "name": "Test Phone", "state": "Booted", "isAvailable": true},
            {"udid": "27000000-0000-4000-8000-000000000003", "name": "Starting Phone", "state": "Booting"}]
        }}
        """
        let devices = try SimctlList.devices(from: Data(listing.utf8))
        XCTAssertEqual(devices.map(\.name), ["Test Pad", "Test Phone", "Starting Phone", "Older Phone"])
        XCTAssertEqual(devices.map(\.state), [.off, .on, .booting, .off])
        XCTAssertEqual(devices[1].osName, "iOS 27.2")
        XCTAssertEqual(devices[1].identity, .iOSSimulator(udid: "27000000-0000-4000-8000-000000000001"))
        // Those on first, then by runtime, newest first, each runtime's in simctl's order; then Android.
        let emulator = SimulatorDevice(identity: .androidEmulator(avd: "Test_AVD"), name: "Test AVD", state: .off,
                                       osName: "Android 16", osVersion: "16")
        XCTAssertEqual(SimulatorDeviceOrder.sorted([emulator, devices[3]] + devices.prefix(3)).map(\.name),
                       ["Test Phone", "Starting Phone", "Test Pad", "Older Phone", "Test AVD"])

        let runtimes = try SimctlList.runtimes(from: Data("""
            {"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2", "name": "iOS 27.2",
                           "version": "27.2", "platform": "iOS", "isAvailable": true}]}
            """.utf8))
        XCTAssertEqual(runtimes.map(\.isIOS), [true])

        let job = """
        {
        \t"Label" = "com.apple.CoreSimulator.SimDevice.27000000-0000-4000-8000-000000000001";
        \t"LastExitStatus" = 0;
        \t"PID" = 4321;
        };
        """
        XCTAssertEqual(SimctlList.launchdJobProcessID(job), 4321)
        XCTAssertNil(SimctlList.launchdJobProcessID(job.replacingOccurrences(of: "\t\"PID\" = 4321;\n", with: "")))

        // The Command Line Tools have no simulators: the newest Xcode in the folder runs them.
        let applications = FileManager.default.temporaryDirectory
            .appending(path: "simulator-xcodes-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: applications) }
        for (name, version) in [("Xcode.app", "27.2"), ("Xcode-beta.app", "28.0"), ("Xcode-old.app", "26.4")] {
            let developer = applications.appending(path: "\(name)/Contents/Developer", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: developer.appending(path: "usr/bin"), withIntermediateDirectories: true)
            let simctl = developer.appending(path: "usr/bin/simctl")
            try Data("#!/bin/sh\n".utf8).write(to: simctl)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path(percentEncoded: false))
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
                .write(to: developer.deletingLastPathComponent().appending(path: "version.plist"))
        }
        let installs = XcodeLocator.installs(in: applications)
        XCTAssertEqual(XcodeLocator.choose(selected: "/Library/Developer/CommandLineTools", installs: installs)?.version, "28.0")
        let selected = applications.appending(path: "Xcode.app/Contents/Developer").path(percentEncoded: false)
        XCTAssertEqual(XcodeLocator.choose(selected: selected, installs: installs)?.version, "27.2")
        XCTAssertNil(XcodeLocator.choose(selected: nil, installs: []))
    }

    func testOneTaskClaimsADeviceWhileOthersViewItOrTakeIt() async throws {
        let backend = FakeSimulatorBackend([(phoneA, .on), (phoneB, .on), (phoneC, .off)])
        let repository = InMemoryTaskWorkspaceRepository()
        let workspaces = TaskWorkspaceStore(repository: repository)
        let (first, second) = (UUID(), UUID())
        let center = SimulatorCenter(backends: [backend], attachments: TaskWorkspaceSimulatorAttachments(
            workspaces: workspaces, taskIDs: { [first, second] }))
        await center.setEnabled(true)
        let a = SimulatorDeviceIdentity.iOSSimulator(udid: phoneA)

        guard case let .attached(attached) = await center.attach("Phone A", to: first, by: .agent) else {
            return XCTFail("The free device was not attached")
        }
        XCTAssertTrue(attached.isClaimed)
        XCTAssertFalse(attached.startedNow)

        // Another task's agent is refused, with the device that is on and free; a person may still view it.
        let refused = await center.attach(phoneA, to: second, by: .agent)
        XCTAssertEqual(refused, .refused(SimulatorRefusal(reason: .claimedByAnotherTask(first),
                                                          freeRunningDevices: [backend.device(phoneB)])))
        guard case let .attached(viewing) = await center.attach(phoneA, to: second, by: .person) else {
            return XCTFail("A person could not view the claimed device")
        }
        XCTAssertFalse(viewing.isClaimed)
        XCTAssertEqual(viewing.claimingTask, first)
        XCTAssertEqual(center.entries(for: second).first { $0.device.identity == a }?.claimingTask, first)
        // Its tab's device menu offers to take the input, naming the task that has it; a device Yardlet did not
        // start is not Yardlet's to shut down.
        let titles = [first: "Build the app"]
        XCTAssertEqual(SimulatorDeviceMenu.make(for: second, in: center, taskTitle: { titles[$0] }).items,
                       [.useInThisTask(heldBy: "Build the app"), .disconnect])
        XCTAssertEqual(SimulatorDeviceMenu.make(for: first, in: center, taskTitle: { titles[$0] }).items, [.disconnect])

        // "Use in this task" moves the claim; choosing another device lets go of the first.
        XCTAssertEqual(center.claim(for: second), first)
        XCTAssertEqual(center.claims[a], second)
        _ = await center.attach(phoneB, to: second, by: .person)
        XCTAssertNil(center.claims[a])
        XCTAssertEqual(center.claims[.iOSSimulator(udid: phoneB)], second)

        // The attachment is kept in the task's workspace and outlives a restart; its claim does not.
        workspaces.persistNow()
        XCTAssertEqual(repository.snapshots[first]?.simulator, a)
        let restartedWorkspaces = TaskWorkspaceStore(repository: repository)
        let restarted = SimulatorCenter(backends: [backend], attachments: TaskWorkspaceSimulatorAttachments(
            workspaces: restartedWorkspaces, taskIDs: { [first, second] }))
        await restarted.setEnabled(true)
        XCTAssertEqual(restarted.attachment(of: first), a)
        XCTAssertNil(restarted.claims[a])
        guard case let .attached(again) = await restarted.prepareAttachedDevice(for: first) else {
            return XCTFail("The attached device was not claimed again")
        }
        XCTAssertTrue(again.isClaimed)

        center.detach(second)
        XCTAssertNil(center.attachment(of: second))
        XCTAssertNil(center.claims[.iOSSimulator(udid: phoneB)])
        // Archiving or deleting the task removes its workspace, attachment and all.
        center.claim(for: first)
        workspaces.remove(for: first)
        center.taskRemoved(first)
        XCTAssertNil(center.claims[a])
        XCTAssertNil(workspaces.simulatorAttachment(of: first))
    }

    func testAnAgentStartsAtMostTwoDevicesAndAPersonIsNotLimited() async throws {
        let backend = FakeSimulatorBackend([(phoneA, .off), (phoneB, .off), (phoneC, .off), (phoneD, .on)])
        let record = InMemorySimulatorBootRecord()
        let center = SimulatorCenter(backends: [backend], record: record)
        await center.setEnabled(true)
        let (first, second, third) = (UUID(), UUID(), UUID())

        guard case let .attached(started) = await center.attach(phoneA, to: first, by: .agent) else {
            return XCTFail("The device did not start")
        }
        XCTAssertTrue(started.startedNow)
        XCTAssertEqual(started.device.state, .on)
        _ = await center.attach(phoneB, to: second, by: .agent)
        XCTAssertEqual(Set(record.load().map(\.device.value)), [phoneA, phoneB])

        // A device that is already on is not a start; a third start is refused, offering the free one.
        let refused = await center.attach(phoneC, to: third, by: .agent)
        XCTAssertEqual(refused, .refused(SimulatorRefusal(reason: .startLimit(2),
                                                          freeRunningDevices: [backend.device(phoneD)])))
        guard case .attached = await center.attach(phoneC, to: third, by: .person) else {
            return XCTFail("A person was held to the agent's limit")
        }
        XCTAssertEqual(record.load().count, 3)
        XCTAssertEqual(backend.boots, [phoneA, phoneB, phoneC])
        // A device Yardlet started can be shut down from its tab, which says Yardlet shuts it down once unused.
        XCTAssertEqual(SimulatorDeviceMenu.make(for: third, in: center, taskTitle: { _ in nil }).items,
                       [.disconnect, .shutDown, .startedByYardletNote])
        XCTAssertEqual(SimulatorDeviceMenu.make(for: UUID(), in: center, taskTitle: { _ in nil }).items, [])
    }

    func testYardletStopsOnlyItsOwnBootOnceTheDeviceIsUnused() async throws {
        let backend = FakeSimulatorBackend([(phoneA, .off), (phoneB, .off), (phoneC, .off), (phoneD, .off)])
        let clock = ManualSimulatorClock()
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "simulator-record-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SimulatorBootRecordFile(url: folder.appending(path: "Simulator/started-devices.json"))
        let center = SimulatorCenter(backends: [backend], record: file, clock: clock)
        var running: Set<UUID> = []
        center.isTurnRunning = { running.contains($0) }
        await center.setEnabled(true)
        let (working, leaving, watching, other) = (UUID(), UUID(), UUID(), UUID())

        // While its task's turn runs, a device stays on; thirty minutes after the turn, it stops.
        running.insert(working)
        _ = await center.attach(phoneA, to: working, by: .agent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))
        clock.advance(by: 2 * 3600)
        XCTAssertNil(center.stopDeadline(for: .iOSSimulator(udid: phoneA)))
        running.remove(working)
        center.taskStatusChanged(working)

        // Ten minutes after the last task lets it go; never while a panel shows it.
        _ = await center.attach(phoneB, to: leaving, by: .agent)
        center.detach(leaving)
        _ = await center.attach(phoneC, to: watching, by: .person)
        center.panelAppeared(for: watching)

        clock.advance(by: 10 * 60)
        await center.stopIdleDevices()
        XCTAssertEqual(backend.shutDowns, [phoneB])
        clock.advance(by: 20 * 60 - 1)
        await center.stopIdleDevices()
        XCTAssertEqual(backend.shutDowns, [phoneB])
        clock.advance(by: 1)
        await center.stopIdleDevices()
        XCTAssertEqual(backend.shutDowns, [phoneB, phoneA])
        XCTAssertEqual(center.state(of: .iOSSimulator(udid: phoneA)), .off)

        // A device started again elsewhere runs another boot, which is not Yardlet's to stop.
        _ = await center.attach(phoneD, to: other, by: .agent)
        backend.restartElsewhere(phoneD)
        center.detach(other)
        clock.advance(by: 10 * 60)
        await center.stopIdleDevices()
        XCTAssertEqual(backend.shutDowns, [phoneB, phoneA])
        XCTAssertNil(center.startedByYardlet[.iOSSimulator(udid: phoneD)])

        center.panelDisappeared(for: watching)
        await center.stopForQuit()
        XCTAssertEqual(backend.shutDowns, [phoneB, phoneA, phoneC])
        XCTAssertTrue(center.startedByYardlet.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)),
                       "The record is left behind with no device in it")
    }

    func testAtStartItStopsWhatAnEarlierYardletLeftRunningThatNoTaskAttaches() async throws {
        let backend = FakeSimulatorBackend([(phoneA, .on), (phoneB, .on), (phoneC, .on), (phoneD, .off)])
        let boot = { [backend] (udid: String) in backend.bootIdentity(udid)! }
        let entries = [
            SimulatorBootRecordEntry(device: .iOSSimulator(udid: phoneA), boot: boot(phoneA), bootedAt: .distantPast),
            SimulatorBootRecordEntry(device: .iOSSimulator(udid: phoneB), boot: boot(phoneB), bootedAt: .distantPast),
            SimulatorBootRecordEntry(device: .iOSSimulator(udid: phoneC),
                                     boot: SimulatorBootIdentity(processID: 7, processStartMicroseconds: 7),
                                     bootedAt: .distantPast),
            SimulatorBootRecordEntry(device: .iOSSimulator(udid: phoneD),
                                     boot: SimulatorBootIdentity(processID: 8, processStartMicroseconds: 8),
                                     bootedAt: .distantPast)
        ]
        let record = InMemorySimulatorBootRecord(entries)
        let attachments = InMemorySimulatorAttachments()
        let task = UUID()
        attachments.attachments[task] = .iOSSimulator(udid: phoneB)
        let center = SimulatorCenter(backends: [backend], record: record, attachments: attachments)

        await center.setEnabled(true)
        XCTAssertEqual(backend.shutDowns, [phoneA])
        XCTAssertEqual(record.load().map(\.device.value), [phoneB])
        XCTAssertEqual(center.state(of: .iOSSimulator(udid: phoneC)), .on)

        // Turning the feature off stops the rest, attached or not.
        await center.setEnabled(false)
        XCTAssertEqual(backend.shutDowns, [phoneA, phoneB])
        XCTAssertTrue(record.load().isEmpty)
    }

    // MARK: - Agent tools

    /// The agents' simulator tools (docs/SIMULATOR.md, "Agent tools") act only on the device their task attached, once
    /// the person allowed it; positions are on the screen, in the units of the screenshots, and durations, counts and
    /// text stay within their limits before anything reaches the device.
    func testTheAgentsToolsActOnlyOnTheAttachedDeviceThePersonAllowed() async throws {
        let backend = FakeSimulatorBackend([(phoneA, .on), (phoneB, .off)])
        let center = SimulatorCenter(backends: [backend])
        await center.setEnabled(true)
        let suite = "SimulatorToolTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let driver = RecordingSimulatorDriver(screen: SimulatorToolScreen(width: 402, height: 874))
        let tools = SimulatorAgentTools(center: { center }, approvals: SimulatorApprovals(defaults: defaults),
                                        drivers: [.iOS: driver])
        tools.sleep = { _ in }
        var asked: [String] = []
        var allows = true
        tools.askPerson = { device, _ in
            asked.append(device.name)
            return allows
        }
        let (first, second) = (UUID(), UUID())
        func run(_ tool: String, _ arguments: [String: ToolJSON] = [:], in task: UUID? = nil) async -> AgentToolResult {
            await tools.run(tool: tool, arguments: .object(arguments), task: task ?? first)
        }

        // Without an attached device a tool names the devices and simulator_attach, and nothing reaches one.
        let unattached = await run(SimulatorToolCatalog.tap, ["x": .integer(10), "y": .integer(10)])
        XCTAssertEqual(unattached.failure?.kind, .notFound)
        XCTAssertTrue(unattached.text.contains("simulator_attach") && unattached.text.contains(phoneA), unattached.text)

        // The person is asked once for a simulator, and the approval holds for every task.
        let attached = await run(SimulatorToolCatalog.attach, ["device": .string("Phone A")])
        XCTAssertFalse(attached.isError, attached.text)
        XCTAssertTrue(attached.text.contains("Its id is \(phoneA)") && attached.text.contains("402×874 points"),
                      attached.text)
        XCTAssertTrue(attached.text.contains("started outside Yardlet"), attached.text)
        XCTAssertEqual(asked, ["Phone A"])
        let claimed = await run(SimulatorToolCatalog.attach, ["device": .string(phoneA)], in: second)
        XCTAssertEqual(claimed.failure?.kind, .refused, "Another task's agent uses it")
        XCTAssertEqual(asked, ["Phone A"], "No card for a device the attach would refuse")
        _ = await run(SimulatorToolCatalog.detach)
        let reused = await run(SimulatorToolCatalog.attach, ["device": .string(phoneA)], in: second)
        XCTAssertFalse(reused.isError, reused.text)
        XCTAssertEqual(asked, ["Phone A"], "A simulator's approval holds for every task")

        // Positions are points of the screenshot, sent as fractions of the screen; off the screen is refused.
        let shot = await run(SimulatorToolCatalog.screenshot, in: second)
        XCTAssertTrue(shot.text.contains("402×874 points"), shot.text)
        _ = await run(SimulatorToolCatalog.tap, ["x": .integer(201), "y": .number(437)], in: second)
        _ = await run(SimulatorToolCatalog.swipe, ["x": .integer(0), "y": .integer(0), "x2": .integer(402),
                                                   "y2": .integer(874), "duration": .number(0.032)], in: second)
        XCTAssertEqual(driver.events, [
            .touch(.down, 0.5, 0.5), .touch(.up, 0.5, 0.5),
            .touch(.down, 0, 0), .touch(.move, 0.5, 0.5), .touch(.move, 1, 1), .touch(.up, 1, 1)
        ])
        driver.events = []
        let off = await run(SimulatorToolCatalog.tap, ["x": .integer(403), "y": .integer(10)], in: second)
        XCTAssertEqual(off.failure?.kind, .invalidArguments)
        XCTAssertEqual(off.failure?.details["width"], .integer(402))
        for (tool, arguments) in [
            (SimulatorToolCatalog.tap, ["x": ToolJSON.integer(1), "y": .integer(1), "duration": .integer(11)]),
            (SimulatorToolCatalog.type, ["text": .string(String(repeating: "a", count: 1_001))]),
            (SimulatorToolCatalog.type, ["text": .string("안녕"), "method": .string("keys")]),
            (SimulatorToolCatalog.press, ["button": .string("home"), "count": .integer(51)]),
            (SimulatorToolCatalog.press, ["button": .string("home"), "key": .string("return")]),
            (SimulatorToolCatalog.press, ["button": .string("back")])
        ] {
            let refused = await run(tool, arguments, in: second)
            XCTAssertEqual(refused.failure?.kind, .invalidArguments, "\(tool) \(arguments): \(refused.text)")
        }
        XCTAssertEqual(driver.events, [], "Nothing out of bounds reached the device")

        // Text pastes by default, in any language; keys type ASCII on the hardware keyboard.
        _ = await run(SimulatorToolCatalog.type, ["text": .string("안녕하세요 Hello")], in: second)
        _ = await run(SimulatorToolCatalog.type, ["text": .string("Hello"), "method": .string("keys")], in: second)
        _ = await run(SimulatorToolCatalog.press, ["button": .string("home"), "count": .integer(2)], in: second)
        _ = await run(SimulatorToolCatalog.press, ["key": .string("select_all")], in: second)
        XCTAssertEqual(driver.events, [.paste("안녕하세요 Hello"), .keys("Hello"), .button(.home), .button(.home),
                                       .key(.selectAll)])

        // A person's recent input on the device is said, and does not stop the agent's.
        tools.lastPersonInput = { _ in Date().addingTimeInterval(-3) }
        let mixed = await run(SimulatorToolCatalog.tap, ["x": .integer(1), "y": .integer(1)], in: second)
        XCTAssertTrue(mixed.text.contains("The person is using Phone A"), mixed.text)
        tools.lastPersonInput = { _ in nil }

        // Taken back, the approval is asked again; declined, nothing reaches the device.
        tools.approvals.revoke(.iOSSimulator(udid: phoneA))
        allows = false
        driver.events = []
        let declined = await run(SimulatorToolCatalog.tap, ["x": .integer(1), "y": .integer(1)], in: second)
        XCTAssertEqual(declined.failure?.kind, .refused)
        XCTAssertEqual(declined.failure?.retry, AgentToolFailure.Retry.no)
        XCTAssertEqual(driver.events, [])
    }

    /// A simulator's or an emulator's approval holds for every task and is kept in the preferences the Simulator switch
    /// clears; a real device's holds for its task only and is never written down.
    func testARealDevicesApprovalHoldsForItsTaskOnly() throws {
        let suite = "SimulatorApprovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let approvals = SimulatorApprovals(defaults: defaults)
        let (first, second) = (UUID(), UUID())
        let phone = SimulatorDeviceIdentity.androidDevice(serialNumber: "R5CR10ABCDE")
        let emulator = SimulatorDeviceIdentity.androidEmulator(avd: "Pixel:9")
        approvals.approve(phone, for: first)
        approvals.approve(emulator, for: first)
        XCTAssertTrue(approvals.isApproved(phone, for: first))
        XCTAssertFalse(approvals.isApproved(phone, for: second))
        XCTAssertTrue(approvals.isApproved(emulator, for: second))
        let restarted = SimulatorApprovals(defaults: defaults)
        XCTAssertTrue(restarted.isApproved(emulator, for: second), "An AVD name with a colon reads back")
        XCTAssertFalse(restarted.isApproved(phone, for: first), "A real device's approval is not kept")
        XCTAssertEqual(defaults.stringArray(forKey: SimulatorApprovals.key), ["androidEmulator:Pixel:9"])
        approvals.removeAll()
        XCTAssertFalse(approvals.isApproved(phone, for: first))
        XCTAssertNil(defaults.object(forKey: SimulatorApprovals.key), "Turned off, nothing is left behind")
    }

    /// A task lists the simulator tools when the Simulator switch was on as it started and a platform's devices can be
    /// used; they are not in the list `yardlet-mcp` falls back to without the app.
    func testTheSimulatorToolsAreListedWhileTheSwitchAndAPlatformAllowThem() async throws {
        let broker = AgentToolBroker(
            environment: AgentToolBroker.Environment(
                executableURL: URL(filePath: "/bin/sh"), endpoint: "/tmp/Yardlet-tools-test/tools.sock",
                privateDirectory: URL(filePath: "/tmp/Yardlet-tools-test"), isEnabled: { true }),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in BrowserAgentPage(cdp: ScriptedCDP()) }))
        let handler = FakeSimulatorToolHandler()
        broker.simulators = handler
        func listed(_ task: UUID, _ token: String) async -> [String] {
            await broker.list(AgentToolCall(token: token, session: task.uuidString, tool: "", arguments: .object([:]),
                                            method: AgentToolCall.listMethod))?.tools.compactMap { $0["name"]?.stringValue }
                .filter { $0.hasPrefix("simulator_") } ?? []
        }
        let on = UUID()
        let onToken = try XCTUnwrap(broker.agentToolServer(for: on, workspaceRoots: [])?.environment[AgentToolEnvironment.token])
        let names = await listed(on, onToken)
        XCTAssertEqual(names, SimulatorToolCatalog.tools.map(\.name))
        XCTAssertEqual(names.count, 8)
        handler.simulatorPlatformIsUsable = false
        let unusable = await listed(on, onToken)
        XCTAssertEqual(unusable, [], "No platform's devices can be used")
        handler.simulatorPlatformIsUsable = true

        handler.simulatorSwitchIsOn = false
        let off = UUID()
        let offToken = try XCTUnwrap(broker.agentToolServer(for: off, workspaceRoots: [])?.environment[AgentToolEnvironment.token])
        let offNames = await listed(off, offToken)
        XCTAssertEqual(offNames, [], "Off as the task started")
        let refused = await broker.handle(AgentToolCall(token: offToken, session: off.uuidString,
                                                        tool: SimulatorToolCatalog.list, arguments: .object([:])))
        XCTAssertEqual(refused.failure?.kind, .refused)
        let stillOn = await listed(on, onToken)
        XCTAssertEqual(stillOn.count, 8, "A task keeps what the switch was as it started")
        let missing = await broker.handle(AgentToolCall(token: onToken, session: on.uuidString,
                                                        tool: SimulatorToolCatalog.tap, arguments: .object(["x": .integer(1)])))
        XCTAssertEqual(missing.failure?.kind, .invalidArguments, "Checked against the listed schema first")
        XCTAssertEqual(handler.calls, [])
        XCTAssertFalse(AgentToolCatalog.builtInTools.contains { $0.name.hasPrefix("simulator_") })
    }
}

/// Simulators that start and stop at once, each boot with a process of its own.
private final class FakeSimulatorBackend: SimulatorBackend, @unchecked Sendable {
    let platform = SimulatorPlatform.iOS
    private let lock = NSLock()
    private let order: [String]
    private var states: [String: SimulatorDeviceState]
    private var running: [String: SimulatorBootIdentity] = [:]
    private var nextProcess: Int32 = 100
    private var startedUDIDs: [String] = []
    private var stoppedUDIDs: [String] = []

    init(_ devices: [(String, SimulatorDeviceState)]) {
        order = devices.map(\.0)
        states = Dictionary(uniqueKeysWithValues: devices)
        for (udid, state) in devices where state == .on { running[udid] = newBoot() }
    }

    var boots: [String] { lock.withLock { startedUDIDs } }
    var shutDowns: [String] { lock.withLock { stoppedUDIDs } }

    func device(_ udid: String) -> SimulatorDevice {
        lock.withLock {
            SimulatorDevice(identity: .iOSSimulator(udid: udid), name: "Phone \(udid.prefix(2).suffix(1))",
                            state: states[udid] ?? .off, osName: "iOS 27.2", osVersion: "27.2")
        }
    }

    func bootIdentity(_ udid: String) -> SimulatorBootIdentity? { lock.withLock { running[udid] } }

    func restartElsewhere(_ udid: String) { lock.withLock { running[udid] = newBoot() } }

    func check() async -> SimulatorPlatformCheck {
        SimulatorPlatformCheck(availability: .available,
                               toolchain: SimulatorToolchain(directory: "/Test/Xcode.app/Contents/Developer", version: "27.2"))
    }

    func devices(with toolchain: SimulatorToolchain) async throws -> [SimulatorDevice] { order.map(device) }

    func boot(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorBootStart {
        lock.withLock {
            let udid = device.identity.value
            guard states[udid] != .on else { return .alreadyOn }
            states[udid] = .on
            running[udid] = newBoot()
            startedUDIDs.append(udid)
            return .started
        }
    }

    func waitUntilReady(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {}

    func shutDown(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {
        lock.withLock {
            states[device.identity.value] = .off
            running[device.identity.value] = nil
            stoppedUDIDs.append(device.identity.value)
        }
    }

    func bootIdentity(of device: SimulatorDeviceIdentity, with toolchain: SimulatorToolchain) async
        -> SimulatorBootIdentity? {
        bootIdentity(device.value)
    }

    /// Called with the lock held, or from init.
    private func newBoot() -> SimulatorBootIdentity {
        defer { nextProcess += 1 }
        return SimulatorBootIdentity(processID: nextProcess, processStartMicroseconds: Int64(nextProcess) * 1_000)
    }
}

/// A clock moved by hand; its waits end only when cancelled.
private final class ManualSimulatorClock: SimulatorClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }

    func sleep(until deadline: Date) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

/// Records what the tools send a device, on a screen of a set size.
@MainActor
private final class RecordingSimulatorDriver: SimulatorDeviceDriving {
    enum Event: Equatable {
        case touch(SimulatorToolTouchPhase, Double, Double)
        case button(SimulatorToolButton)
        case key(SimulatorToolKey)
        case paste(String)
        case keys(String)
    }

    let buttons: [SimulatorToolButton] = [.home, .lock, .volumeUp, .volumeDown, .action]
    let screen: SimulatorToolScreen
    var events: [Event] = []

    init(screen: SimulatorToolScreen) {
        self.screen = screen
    }

    func prepare(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorToolScreen {
        screen
    }

    func screenshot(of device: SimulatorDevice, format: SimulatorToolImageFormat) async throws -> SimulatorToolImage {
        SimulatorToolImage(data: Data([0x89, 0x50]), format: format, width: screen.width, height: screen.height)
    }

    func touch(_ phase: SimulatorToolTouchPhase, at point: SimulatorScreenFraction, on device: SimulatorDevice) throws {
        events.append(.touch(phase, point.x, point.y))
    }

    func press(_ button: SimulatorToolButton, on device: SimulatorDevice) async throws { events.append(.button(button)) }

    func press(_ key: SimulatorToolKey, on device: SimulatorDevice) async throws { events.append(.key(key)) }

    func paste(_ text: String, on device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {
        events.append(.paste(text))
    }

    func typeKeys(_ text: String, on device: SimulatorDevice) async throws { events.append(.keys(text)) }

    func release(_ device: SimulatorDevice) {}
}

@MainActor
private final class FakeSimulatorToolHandler: SimulatorToolHandling {
    var simulatorSwitchIsOn = true
    var simulatorPlatformIsUsable = true
    var calls: [String] = []

    func callSimulatorTool(named name: String, arguments: ToolJSON, callerID: UUID) async -> AgentToolResult {
        calls.append(name)
        return .text("ran")
    }
}
