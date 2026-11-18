import Foundation
@testable import NativeHarnessClient
import XCTest

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
