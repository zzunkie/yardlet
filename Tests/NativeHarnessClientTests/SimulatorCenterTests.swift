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

    func testOneTaskClaimsARealDeviceWhileOthersViewItOrTakeIt() async throws {
        let backend = FakeSimulatorBackend([(phoneB, .on), (phoneC, .off)])
        let repository = InMemoryTaskWorkspaceRepository()
        let workspaces = TaskWorkspaceStore(repository: repository)
        let (first, second) = (UUID(), UUID())
        let center = SimulatorCenter(backends: [backend, ConnectedPhoneBackend()],
                                     attachments: TaskWorkspaceSimulatorAttachments(
            workspaces: workspaces, taskIDs: { [first, second] }))
        await center.setEnabled(true)
        let a = ConnectedPhoneBackend.phone.identity
        let phoneA = a.value

        guard case let .attached(attached) = await center.attach("Test Phone", to: first, by: .agent) else {
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
        XCTAssertEqual(repository.snapshots[first]?.simulators?[SimulatorCenter.testTab], a)
        let restartedWorkspaces = TaskWorkspaceStore(repository: repository)
        let restarted = SimulatorCenter(backends: [backend, ConnectedPhoneBackend()],
                                        attachments: TaskWorkspaceSimulatorAttachments(
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
        XCTAssertEqual(workspaces.simulatorAttachments(of: first), [:])
    }

    /// A simulator another task uses is never shared: a second task, its agent or the person, gets a copy of it,
    /// one for the task however many of its tabs ask, which no other task lists and which is deleted with the last
    /// tab that attaches it, when Yardlet quits and, after a Yardlet that ended without deleting it, at the next start.
    func testASimulatorAnotherTaskUsesOpensAsTheTasksOwnCopy() async throws {
        let backend = FakeSimulatorBackend([(phoneA, .on), (phoneB, .off)])
        let repository = InMemoryTaskWorkspaceRepository()
        let workspaces = TaskWorkspaceStore(repository: repository)
        let record = InMemorySimulatorBootRecord()
        let (first, second, third) = (UUID(), UUID(), UUID())
        let center = SimulatorCenter(backends: [backend], record: record, attachments: TaskWorkspaceSimulatorAttachments(
            workspaces: workspaces, taskIDs: { [first, second, third] }))
        await center.setEnabled(true)
        let a = SimulatorDeviceIdentity.iOSSimulator(udid: phoneA)
        let (agentTab, personTab) = (UUID(), UUID())

        guard case .attached = await center.attach(a, to: first, by: .agent) else { return XCTFail("A was not attached") }
        guard case let .attached(copied) = await center.attach("Phone A", to: second, tab: agentTab, by: .agent) else {
            return XCTFail("The second task got no copy")
        }
        let copy = copied.device.identity
        XCTAssertNotEqual(copy, a)
        XCTAssertEqual(copied.copyOf, a)
        XCTAssertEqual(copied.device.name, "Phone A (Yardlet)")
        XCTAssertTrue(copied.isClaimed && copied.startedNow && copied.isStartedByYardlet)
        XCTAssertEqual(center.claims, [a: first, copy: second])
        XCTAssertEqual(backend.boots, [copy.value])
        XCTAssertEqual(record.loadCopies().map(\.device), [copy])
        // The person picking the original in another tab of the same task gets the same copy.
        guard case let .attached(again) = await center.attach(a, to: second, tab: personTab, by: .person) else {
            return XCTFail("The person's tab got no copy")
        }
        XCTAssertEqual(again.device.identity, copy)
        XCTAssertEqual(backend.copiesMade.count, 1)
        XCTAssertEqual(center.tab(attaching: a, in: second, preferring: [personTab]), personTab)
        // The copy is the second task's own: no other task lists it, and its name names the original.
        XCTAssertFalse(center.entries(for: third).contains { $0.device.identity == copy })
        XCTAssertEqual(center.entries(for: second).first { $0.device.identity == copy }?.copyOf, a)
        XCTAssertEqual(center.devices(named: "Phone A").map(\.identity), [a])
        XCTAssertEqual(SimulatorDeviceMenu.make(for: second, tab: personTab, in: center, taskTitle: { _ in nil }).items,
                       [.disconnect, .shutDown, .startedByYardletNote])
        // A third task's agent gets a copy too, within the limit on what Yardlet starts for agents.
        guard case .attached = await center.attach(a, to: third, by: .agent) else { return XCTFail("No third copy") }
        let refused = await center.attach(a, to: UUID(), by: .agent)
        XCTAssertEqual(refused, .refused(SimulatorRefusal(reason: .startLimit(SimulatorCenter.agentStartLimit),
                                                          freeRunningDevices: [])))

        // Closing one of its tabs keeps the copy; closing the last deletes it, stopped first.
        center.detach(second, tab: agentTab)
        XCTAssertTrue(backend.copiesDeleted.isEmpty)
        center.detach(second, tab: personTab)
        try await waitUntil { backend.copiesDeleted == [copy.value] }
        XCTAssertNil(center.copies[copy])
        XCTAssertNil(center.claims[copy])
        XCTAssertFalse(backend.listed.contains(copy.value))
        XCTAssertNil(center.startedByYardlet[copy])

        // Quitting deletes the copies, and their tabs attach the originals again.
        guard case let .attached(second2) = await center.attach(a, to: second, tab: agentTab, by: .agent) else {
            return XCTFail("No new copy")
        }
        await center.stopForQuit()
        XCTAssertTrue(backend.copiesDeleted.contains(second2.device.identity.value))
        XCTAssertEqual(center.copies, [:])
        XCTAssertEqual(record.loadCopies(), [])
        XCTAssertEqual(workspaces.simulatorAttachments(of: second), [agentTab: a])
        XCTAssertEqual(workspaces.simulatorAttachments(of: third)[SimulatorCenter.testTab], a)

        // A Yardlet that ended without deleting its copy deletes it at its next start, its tab on the original, and
        // keeps the record of the other device it started, which a task still attaches.
        let toolchain = SimulatorToolchain(directory: "/x")
        let orphan = try await backend.makeCopy(of: backend.device(phoneA), with: toolchain)
        _ = try await backend.boot(orphan, with: toolchain)
        let b = SimulatorDeviceIdentity.iOSSimulator(udid: phoneB)
        _ = try await backend.boot(backend.device(phoneB), with: toolchain)
        workspaces.state(for: second).simulators[agentTab] = orphan.identity
        workspaces.state(for: first).simulators[UUID()] = b
        let earlier = InMemorySimulatorBootRecord(
            [SimulatorBootRecordEntry(device: b, boot: try XCTUnwrap(backend.bootIdentity(phoneB)), bootedAt: Date()),
             SimulatorBootRecordEntry(device: orphan.identity, boot: try XCTUnwrap(backend.bootIdentity(orphan.identity.value)),
                                      bootedAt: Date())],
            copies: [SimulatorCopyRecordEntry(device: orphan.identity, source: a, madeAt: Date())])
        let restarted = SimulatorCenter(
            backends: [backend], record: earlier,
            attachments: TaskWorkspaceSimulatorAttachments(workspaces: workspaces, taskIDs: { [first, second, third] }))
        await restarted.setEnabled(true)
        XCTAssertTrue(backend.copiesDeleted.contains(orphan.identity.value))
        XCTAssertEqual(restarted.attachment(of: second, tab: agentTab), a)
        XCTAssertEqual(restarted.copies, [:])
        XCTAssertEqual(Array(restarted.startedByYardlet.keys), [b])
        XCTAssertEqual(earlier.load().map(\.device), [b])
        XCTAssertEqual(earlier.loadCopies(), [])
    }

    /// A task attaches a device in each of its Simulator tabs and claims each; a tab that closes lets go of its own
    /// device only, and of the claim once no other tab of the task attaches it.
    func testATaskClaimsADeviceInEachSimulatorTabAndAClosedTabLetsGoOfItsOwn() async throws {
        let backend = FakeSimulatorBackend([(phoneA, .on), (phoneB, .on), (phoneC, .on)])
        let repository = InMemoryTaskWorkspaceRepository()
        let workspaces = TaskWorkspaceStore(repository: repository)
        let task = UUID()
        let center = SimulatorCenter(backends: [backend], attachments: TaskWorkspaceSimulatorAttachments(
            workspaces: workspaces, taskIDs: { [task] }))
        await center.setEnabled(true)
        let tools = SimulatorAgentTools(center: { center }, approvals: SimulatorApprovals(defaults: .vaultTests()))
        workspaces.onSimulatorTabsClose = { task, tabs in tabs.forEach { tools.tabClosed($0, of: task) } }
        let (a, b) = (SimulatorDeviceIdentity.iOSSimulator(udid: phoneA), SimulatorDeviceIdentity.iOSSimulator(udid: phoneB))
        let (phoneTab, otherTab, sameTab) = (UUID(), UUID(), UUID())
        let workspace = workspaces.state(for: task)
        for tab in [phoneTab, otherTab, sameTab] {
            workspace.setPanels(TaskSurfaceNavigationProjection.showing(TaskSurfaceNavigationProjection.simulatorTabID(tab),
                                                                        in: workspace.panels))
        }

        for (identity, tab) in [(a, phoneTab), (b, otherTab)] {
            guard case let .attached(attached) = await center.attach(identity, to: task, tab: tab, by: .agent) else {
                return XCTFail("\(identity) was not attached")
            }
            XCTAssertTrue(attached.isClaimed)
        }
        // The person shows the same device in a third tab: watching it twice claims nothing more.
        _ = await center.attach(a, to: task, tab: sameTab, by: .person)
        XCTAssertEqual(center.claims, [a: task, b: task])
        XCTAssertEqual(center.attachedDevices(of: task), [a, b])
        XCTAssertEqual(workspace.simulators, [phoneTab: a, otherTab: b, sameTab: a])
        XCTAssertEqual(center.entries(for: task, tab: otherTab).filter(\.isAttachedHere).map(\.device.identity), [b])
        XCTAssertEqual(Set(center.entries(for: task).filter(\.isAttachedHere).map(\.device.identity)), [a, b])

        // Shown is counted by tab: only the device of the tab on screen is shown.
        center.panelAppeared(for: task, tab: otherTab)
        XCTAssertEqual(center.entries(for: task).filter(\.isShown).map(\.device.identity), [b])
        center.panelDisappeared(for: task, tab: otherTab)

        // Closing a tab whose device another tab of the task still shows keeps the claim; closing the last lets go.
        workspace.setPanels(TaskSurfaceNavigationProjection.closingTrailingTab(
            TaskSurfaceNavigationProjection.simulatorTabID(phoneTab), in: workspace.panels))
        XCTAssertEqual(center.claims, [a: task, b: task])
        XCTAssertEqual(workspace.simulators, [otherTab: b, sameTab: a])
        workspace.setPanels(TaskSurfaceNavigationProjection.closingTrailingTab(
            TaskSurfaceNavigationProjection.simulatorTabID(sameTab), in: workspace.panels))
        XCTAssertEqual(center.claims, [b: task], "The other tab's device stays claimed")
        XCTAssertEqual(center.attachedDevices(of: task), [b])

        // The attachments are saved by tab and outlive a restart.
        workspaces.persistNow()
        XCTAssertEqual(repository.snapshots[task]?.simulators, [otherTab: b])
        XCTAssertNil(repository.snapshots[task]?.simulator)
        let restartedWorkspaces = TaskWorkspaceStore(repository: repository)
        let restarted = SimulatorCenter(backends: [backend], attachments: TaskWorkspaceSimulatorAttachments(
            workspaces: restartedWorkspaces, taskIDs: { [task] }))
        await restarted.setEnabled(true)
        XCTAssertEqual(restarted.attachments(of: task), [otherTab: b])

        // Removing the task lets go of every device it attached.
        _ = await center.attach(a, to: task, tab: UUID(), by: .agent)
        center.taskRemoved(task)
        XCTAssertEqual(center.claims, [:])
    }

    /// A workspace saved while a task had one Simulator tab keeps that tab, where it was, and the device attached in
    /// it, under one key that every reading of the snapshot gives, so the simulator center reading the saved snapshot
    /// and the window loading it agree.
    func testASnapshotWithOneSimulatorTabKeepsItsTabAndDevice() async throws {
        let a = SimulatorDeviceIdentity.iOSSimulator(udid: phoneA)
        let legacy = TaskWorkspaceSnapshot(
            panels: .init(trailingSurfaceID: "simulator", trailingTabs: ["diff", "simulator"],
                          recentTrailingTabs: ["simulator", "diff"]),
            panelsRevision: TaskWorkspaceSnapshot.browserTabsPanelsRevision, simulator: a)
        // As an earlier Yardlet wrote it: no `simulators`.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json["simulators"] = nil
        let decoded = try JSONDecoder().decode(TaskWorkspaceSnapshot.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        let repository = InMemoryTaskWorkspaceRepository()
        let task = UUID()
        repository.snapshots[task] = decoded
        let workspaces = TaskWorkspaceStore(repository: repository)
        let key = TaskWorkspaceSnapshot.legacySimulatorTabKey
        let id = TaskSurfaceNavigationProjection.simulatorTabID(key)

        let center = SimulatorCenter(backends: [FakeSimulatorBackend([(phoneA, .on)])],
                                     attachments: TaskWorkspaceSimulatorAttachments(workspaces: workspaces,
                                                                                    taskIDs: { [task] }))
        await center.setEnabled(true)
        XCTAssertEqual(center.attachments(of: task), [key: a], "Read without loading the task's workspace")
        let workspace = workspaces.state(for: task)
        XCTAssertEqual(workspace.panels.trailingTabs, ["diff", id])
        XCTAssertEqual(workspace.panels.trailingSurfaceID, id)
        XCTAssertEqual(workspace.simulators, [key: a])
        workspaces.persistNow()
        XCTAssertEqual(repository.snapshots[task]?.simulators, [key: a])
        XCTAssertNil(repository.snapshots[task]?.simulator)
        XCTAssertEqual(repository.snapshots[task]?.panels.trailingTabs, ["diff", id])

        // A device whose one Simulator tab was closed stayed attached then; closing a tab lets go of its device now,
        // so it is let go rather than kept in a tab no strip shows.
        let closed = TaskWorkspaceSnapshot(panels: .init(trailingSurfaceID: "diff", trailingTabs: ["diff"],
                                                         recentTrailingTabs: ["diff"]),
                                           panelsRevision: TaskWorkspaceSnapshot.browserTabsPanelsRevision, simulator: a)
        let closedTask = UUID()
        repository.snapshots[closedTask] = closed
        XCTAssertNil(closed.migrated.simulators)
        XCTAssertNil(closed.migrated.simulator)
        XCTAssertEqual(center.attachments(of: closedTask), [:])
        XCTAssertEqual(workspaces.state(for: closedTask).panels.trailingTabs, ["diff"])
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
        attachments.attachments[task] = [SimulatorCenter.testTab: .iOSSimulator(udid: phoneB)]
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
        // Each task's one Simulator tab, which an attach takes while it is empty.
        tools.panelTabs = { _ in [SimulatorCenter.testTab] }
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
        // Another task's agent gets a copy of its own, asked about as the original the person allowed.
        let copied = await run(SimulatorToolCatalog.attach, ["device": .string(phoneA)], in: second)
        XCTAssertFalse(copied.isError, copied.text)
        XCTAssertTrue(copied.text.contains("separate copy of it") && !copied.text.contains("Its id is \(phoneA)"),
                      copied.text)
        XCTAssertEqual(asked, ["Phone A"])
        let listed = await run(SimulatorToolCatalog.list, in: second)
        XCTAssertTrue(listed.text.contains(#""copyOf":"Phone A""#), listed.text)
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

        // A snapshot reads the elements through what says nothing, scrubbed, with references for those on the screen;
        // a tap by reference taps the element's middle.
        driver.tree = SimulatorUITree(elements: [SimulatorUIElement(
            role: "AXApplication", label: "Settings", frame: SimulatorUIRect(x: 0, y: 0, width: 402, height: 874),
            children: [SimulatorUIElement(role: "AXGroup", frame: SimulatorUIRect(x: 0, y: 0, width: 402, height: 874), children: [
                SimulatorUIElement(role: "AXButton", label: "General", identifier: "com.apple.settings.general",
                                   frame: SimulatorUIRect(x: 16, y: 380, width: 370, height: 52)),
                SimulatorUIElement(role: "AXStaticText", label: "ghp_" + String(repeating: "a", count: 36),
                                   frame: SimulatorUIRect(x: 16, y: 900, width: 370, height: 52))
            ])])])
        driver.events = []
        let snapshot = await run(SimulatorToolCatalog.snapshot, in: second)
        XCTAssertTrue(snapshot.text.contains("- application \"Settings\" [ref=@e1]\n  - button \"General\" "
            + "[id=com.apple.settings.general] [ref=@e2]\n  - static text"), snapshot.text)
        XCTAssertTrue(snapshot.text.contains("[off screen]") && !snapshot.text.contains("ghp_aaaa"), snapshot.text)
        let byReference = await run(SimulatorToolCatalog.tap, ["ref": .string("@e2")], in: second)
        XCTAssertTrue(byReference.text.contains("button “General”"), byReference.text)
        XCTAssertEqual(driver.events, [.touch(.down, 201.0 / 402, 406.0 / 874), .touch(.up, 201.0 / 402, 406.0 / 874)])
        let unknown = await run(SimulatorToolCatalog.tap, ["ref": .string("@e9")], in: second)
        XCTAssertEqual(unknown.failure?.kind, .notFound)
        let both = await run(SimulatorToolCatalog.tap, ["ref": .string("@e2"), "x": .integer(1), "y": .integer(1)],
                             in: second)
        XCTAssertEqual(both.failure?.kind, .invalidArguments)

        // A handoff waits for the person's answer in the tab's bar, as browser_handoff does: unanswered, the device
        // stays handed over and a call waits again; a message from the person, or the turn's end, ends the wait.
        tools.handoffPollInterval = .milliseconds(5)
        driver.events = []
        var started: [String] = []
        var settled: [String] = []
        tools.handoffStarted = { _, _, handoff in started.append(handoff.reason) }
        tools.handoffs.onSettled = { settled.append($0) }
        let handedOver = Task { await run(SimulatorToolCatalog.handoff, ["reason": .string("Sign in")], in: second) }
        try await waitUntil { tools.handoffs.waiting(for: second) != nil }
        let signIn = try XCTUnwrap(tools.handoffs.waiting(for: second))
        XCTAssertEqual(signIn.device, .iOSSimulator(udid: phoneA))
        tools.handoffs.answer(.done, for: second)
        let done = await handedOver.value
        XCTAssertTrue(done.text.contains("said they are done on Phone A"), done.text)
        XCTAssertNil(tools.handoffs.handoff(for: second))
        XCTAssertEqual(settled, [signIn.notice])
        let unanswered = await run(SimulatorToolCatalog.handoff, ["reason": .string("Pay"), "timeout": .integer(0)],
                                   in: second)
        XCTAssertTrue(unanswered.text.contains("has not answered") && unanswered.text.contains("waits again"),
                      unanswered.text)
        let pay = try XCTUnwrap(tools.handoffs.waiting(for: second))
        let again = Task { await run(SimulatorToolCatalog.handoff, ["reason": .string("Pay with the test card")], in: second) }
        try await waitUntil { tools.handoffs.waiting(for: second)?.reason == "Pay with the test card" }
        XCTAssertEqual(started, ["Sign in", "Pay"], "Calling again waits on the same handoff")
        tools.handoffs.answer(.personSentMessage, for: second)
        let message = await again.value
        XCTAssertTrue(message.text.contains("sent you a message"), message.text)
        _ = await run(SimulatorToolCatalog.handoff, ["reason": .string("Approve"), "timeout": .integer(0)], in: second)
        tools.taskTurnEnded(second)
        XCTAssertNil(tools.handoffs.waiting(for: second), "The bar goes with the turn")
        XCTAssertEqual(settled.count, 3)
        XCTAssertEqual(settled[1], pay.notice)
        for arguments in [["reason": ToolJSON.string(" ")], ["reason": .string("Sign in"), "timeout": .integer(-1)]] {
            let refused = await run(SimulatorToolCatalog.handoff, arguments, in: second)
            XCTAssertEqual(refused.failure?.kind, .invalidArguments, refused.text)
        }
        XCTAssertEqual(driver.events, [], "A handoff sends the device nothing")

        // The device menu takes the approval back; asked again, declined, nothing reaches the device.
        XCTAssertTrue(SimulatorDeviceMenu.make(for: second, in: center, taskTitle: { _ in nil }, approvals: tools.approvals)
            .items.contains(.revokeAgentAccess))
        tools.approvals.revoke(.iOSSimulator(udid: phoneA))
        XCTAssertFalse(SimulatorDeviceMenu.make(for: second, in: center, taskTitle: { _ in nil }, approvals: tools.approvals)
            .items.contains(.revokeAgentAccess))
        allows = false
        driver.events = []
        let declined = await run(SimulatorToolCatalog.tap, ["x": .integer(1), "y": .integer(1)], in: second)
        XCTAssertEqual(declined.failure?.kind, .refused)
        XCTAssertEqual(declined.failure?.retry, AgentToolFailure.Retry.no)
        XCTAssertEqual(driver.events, [])
    }

    /// A task's agent attaches a device in a Simulator tab of its own without taking another's: into the tab that has
    /// it, else an empty one, else a new one. A tool acts on the device its `device` names, or without one on the
    /// task's only device or that of its Simulator tab used last.
    func testTheToolsActOnTheDeviceTheCallNamesAmongTheTasksDevices() async throws {
        let center = SimulatorCenter(backends: [FakeSimulatorBackend([(phoneA, .on), (phoneB, .on), (phoneC, .on)])])
        await center.setEnabled(true)
        let tools = SimulatorAgentTools(center: { center }, approvals: SimulatorApprovals(defaults: .vaultTests()),
                                        drivers: [.iOS: RecordingSimulatorDriver(screen: SimulatorToolScreen(width: 402,
                                                                                                             height: 874))])
        tools.sleep = { _ in }
        tools.askPerson = { _, _ in true }
        // The task's Simulator tabs, the one used last first, as its panel keeps them.
        let empty = UUID()
        var tabs = [empty]
        tools.panelTabs = { _ in tabs }
        tools.showPanel = { _, tab in
            tabs.removeAll { $0 == tab }
            tabs.insert(tab, at: 0)
            return .shown
        }
        let task = UUID()
        func run(_ tool: String, _ arguments: [String: ToolJSON] = [:]) async -> AgentToolResult {
            await tools.run(tool: tool, arguments: .object(arguments), task: task)
        }
        let (a, b) = (SimulatorDeviceIdentity.iOSSimulator(udid: phoneA), SimulatorDeviceIdentity.iOSSimulator(udid: phoneB))

        let first = await run(SimulatorToolCatalog.attach, ["device": .string("Phone A")])
        XCTAssertFalse(first.isError, first.text)
        XCTAssertEqual(center.attachment(of: task, tab: empty), a, "Into the empty Simulator tab")
        let second = await run(SimulatorToolCatalog.attach, ["device": .string("Phone B")])
        XCTAssertFalse(second.isError, second.text)
        XCTAssertTrue(second.text.contains("also has Phone A"), second.text)
        XCTAssertEqual(tabs.count, 2, "A new tab, beside the one with Phone A")
        XCTAssertEqual(center.attachment(of: task, tab: empty), a, "Phone A keeps its tab")
        XCTAssertEqual(center.claims, [a: task, b: task])

        // Without device: the device of the tab used last; with one, that device, by name or id.
        let latest = await run(SimulatorToolCatalog.tap, ["x": .integer(10), "y": .integer(10)])
        XCTAssertTrue(latest.text.contains("on Phone B"), latest.text)
        _ = await run(SimulatorToolCatalog.attach, ["device": .string(phoneA)])
        XCTAssertEqual(tabs.count, 2, "Attaching an attached device reuses its tab")
        let shown = await run(SimulatorToolCatalog.tap, ["x": .integer(10), "y": .integer(10)])
        XCTAssertTrue(shown.text.contains("on Phone A"), shown.text)
        let named = await run(SimulatorToolCatalog.tap, ["x": .integer(10), "y": .integer(10),
                                                         "device": .string("phone b")])
        XCTAssertTrue(named.text.contains("on Phone B"), named.text)
        let byID = await run(SimulatorToolCatalog.press, ["button": .string("home"), "device": .string(phoneB)])
        XCTAssertTrue(byID.text.contains("on Phone B"), byID.text)
        let unattached = await run(SimulatorToolCatalog.screenshot, ["device": .string("Phone C")])
        XCTAssertEqual(unattached.failure?.kind, .notFound)
        XCTAssertTrue(unattached.text.contains("Phone A") && unattached.text.contains("simulator_attach"), unattached.text)
        let wrongType = await run(SimulatorToolCatalog.screenshot, ["device": .integer(3)])
        XCTAssertEqual(wrongType.failure?.kind, .invalidArguments)

        // Detaching one keeps the other, which the tools then act on without device.
        let detached = await run(SimulatorToolCatalog.detach, ["device": .string("Phone A")])
        XCTAssertTrue(detached.text.contains("Let go of Phone A") && detached.text.contains("still has Phone B"),
                      detached.text)
        XCTAssertEqual(center.attachedDevices(of: task), [b])
        XCTAssertEqual(center.claims, [b: task])
        let only = await run(SimulatorToolCatalog.tap, ["x": .integer(10), "y": .integer(10)])
        XCTAssertTrue(only.text.contains("on Phone B"), only.text)

        // With two attached, a handoff hands over the device it names and waits on it alone.
        _ = await run(SimulatorToolCatalog.attach, ["device": .string(phoneA)])
        let handedOver = await run(SimulatorToolCatalog.handoff, ["reason": .string("Sign in"), "timeout": .integer(0),
                                                                   "device": .string("Phone B")])
        XCTAssertTrue(handedOver.text.contains("Phone B stays handed to them"), handedOver.text)
        XCTAssertEqual(tools.handoffs.handoff(for: task)?.device, b)
    }

    /// A name two attached devices share names neither; a start that fails in a tab no panel showed leaves nothing
    /// attached or claimed.
    func testAnAmbiguousNameIsRefusedAndAFailedStartLeavesNoHiddenTab() async throws {
        let backend = FakeSimulatorBackend([(phoneA, .on), (phoneB, .on), (phoneC, .off)])
        backend.names = [phoneA: "iPhone 17", phoneB: "iPhone 17"]
        let center = SimulatorCenter(backends: [backend])
        await center.setEnabled(true)
        let tools = SimulatorAgentTools(center: { center }, approvals: SimulatorApprovals(defaults: .vaultTests()),
                                        drivers: [.iOS: RecordingSimulatorDriver(screen: SimulatorToolScreen(width: 402,
                                                                                                             height: 874))])
        tools.sleep = { _ in }
        tools.askPerson = { _, _ in true }
        let task = UUID()
        func run(_ tool: String, _ arguments: [String: ToolJSON]) async -> AgentToolResult {
            await tools.run(tool: tool, arguments: .object(arguments), task: task)
        }
        _ = await run(SimulatorToolCatalog.attach, ["device": .string(phoneA)])
        _ = await run(SimulatorToolCatalog.attach, ["device": .string(phoneB)])
        let ambiguous = await run(SimulatorToolCatalog.screenshot, ["device": .string("iPhone 17")])
        XCTAssertEqual(ambiguous.failure?.kind, .invalidArguments)
        XCTAssertTrue(ambiguous.text.contains(phoneA) && ambiguous.text.contains(phoneB), ambiguous.text)

        backend.failsBoot = true
        let failed = await run(SimulatorToolCatalog.attach, ["device": .string(phoneC)])
        XCTAssertEqual(failed.failure?.kind, .unreachable)
        XCTAssertTrue(failed.text.contains("was not attached"), failed.text)
        XCTAssertEqual(Set(center.attachedDevices(of: task)),
                       [.iOSSimulator(udid: phoneA), .iOSSimulator(udid: phoneB)])
        XCTAssertNil(center.claims[.iOSSimulator(udid: phoneC)])
    }

    /// The tools drive a real Android device as they do an emulator, once the person allowed it in the task asking:
    /// another task asks again, and a declined card leaves the device untouched.
    func testTheToolsAskForARealDeviceInEachTask() async throws {
        let center = SimulatorCenter(backends: [ConnectedPhoneBackend()])
        await center.setEnabled(true)
        let suite = "SimulatorToolTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let driver = RecordingSimulatorDriver(screen: SimulatorToolScreen(width: 411, height: 914))
        let tools = SimulatorAgentTools(center: { center }, approvals: SimulatorApprovals(defaults: defaults),
                                        drivers: [.android: driver])
        tools.sleep = { _ in }
        var asked = 0
        var allows = true
        tools.askPerson = { _, _ in
            asked += 1
            return allows
        }
        let (first, second) = (UUID(), UUID())
        func run(_ tool: String, _ arguments: [String: ToolJSON] = [:], in task: UUID) async -> AgentToolResult {
            await tools.run(tool: tool, arguments: .object(arguments), task: task)
        }
        let list = await run(SimulatorToolCatalog.list, in: first)
        XCTAssertTrue(list.text.contains(#""realDevice":true"#), list.text)
        let attached = await run(SimulatorToolCatalog.attach, ["device": .string("R3CT00TEST")], in: first)
        XCTAssertTrue(attached.text.contains("real Android device"), attached.text)
        _ = await run(SimulatorToolCatalog.tap, ["x": .integer(205), "y": .integer(457)], in: first)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(driver.events.count, 2)
        _ = await run(SimulatorToolCatalog.detach, in: first)
        allows = false
        let declined = await run(SimulatorToolCatalog.attach, ["device": .string("R3CT00TEST")], in: second)
        XCTAssertEqual(declined.failure?.kind, .refused, declined.text)
        XCTAssertEqual(asked, 2, "A real device's approval holds in its own task only")
        XCTAssertEqual(driver.events.count, 2)
    }

    /// A simulator's or an emulator's approval holds for every task and is kept in the preferences the Simulator switch
    /// clears; a real device's holds for its task only and is never written down.
    func testARealDevicesApprovalHoldsForItsTaskOnly() throws {
        let suite = "SimulatorApprovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let approvals = SimulatorApprovals(defaults: defaults)
        let (first, second) = (UUID(), UUID())
        let phone = SimulatorDeviceIdentity.androidDevice(serialNumber: "0A1B2C3D4E5F")
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
        XCTAssertEqual(names.count, 10)
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
        XCTAssertEqual(stillOn.count, 10, "A task keeps what the switch was as it started")
        let missing = await broker.handle(AgentToolCall(token: onToken, session: on.uuidString,
                                                        tool: SimulatorToolCatalog.swipe, arguments: .object(["x": .integer(1)])))
        XCTAssertEqual(missing.failure?.kind, .invalidArguments, "Checked against the listed schema first")
        XCTAssertEqual(handler.calls, [])
        XCTAssertFalse(AgentToolCatalog.builtInTools.contains { $0.name.hasPrefix("simulator_") })
    }
}

/// A phone over USB, on and never turned on or off.
private struct ConnectedPhoneBackend: SimulatorBackend {
    static let phone = SimulatorDevice(identity: .androidDevice(serialNumber: "R3CT00TEST"), name: "Test Phone",
                                       state: .on, osName: "Android 14", osVersion: "34", adbSerial: "R3CT00TEST")
    let platform = SimulatorPlatform.android

    func check() async -> SimulatorPlatformCheck {
        SimulatorPlatformCheck(availability: .available, toolchain: SimulatorToolchain(directory: "/srv/sdk"))
    }

    func devices(with toolchain: SimulatorToolchain) async throws -> [SimulatorDevice] { [Self.phone] }
    func boot(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorBootStart {
        throw SimulatorCommandError(message: "a real device was started")
    }
    func waitUntilReady(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {}
    func shutDown(_ device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws {
        throw SimulatorCommandError(message: "a real device was stopped")
    }
    func bootIdentity(of device: SimulatorDeviceIdentity, with toolchain: SimulatorToolchain) async
        -> SimulatorBootIdentity? { nil }
}

/// Simulators that start and stop at once, each boot with a process of its own.
private final class FakeSimulatorBackend: SimulatorBackend, @unchecked Sendable {
    let platform = SimulatorPlatform.iOS
    private let lock = NSLock()
    private var order: [String]
    private var states: [String: SimulatorDeviceState]
    private var copiedUDIDs: [String] = []
    private var deletedUDIDs: [String] = []
    private var running: [String: SimulatorBootIdentity] = [:]
    private var nextProcess: Int32 = 100
    private var startedUDIDs: [String] = []
    private var stoppedUDIDs: [String] = []
    /// A start that fails, as `simctl boot` can.
    var failsBoot = false
    /// Names other than "Phone" and the UDID's letter, by UDID.
    var names: [String: String] = [:]

    init(_ devices: [(String, SimulatorDeviceState)]) {
        order = devices.map(\.0)
        states = Dictionary(uniqueKeysWithValues: devices)
        for (udid, state) in devices where state == .on { running[udid] = newBoot() }
    }

    var boots: [String] { lock.withLock { startedUDIDs } }
    var copiesMade: [String] { lock.withLock { copiedUDIDs } }
    var copiesDeleted: [String] { lock.withLock { deletedUDIDs } }
    var listed: [String] { lock.withLock { order } }
    var shutDowns: [String] { lock.withLock { stoppedUDIDs } }

    func device(_ udid: String) -> SimulatorDevice {
        lock.withLock {
            SimulatorDevice(identity: .iOSSimulator(udid: udid), name: names[udid] ?? "Phone \(udid.prefix(2).suffix(1))",
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
        if failsBoot { throw SimulatorCommandError(message: "Unable to boot device") }
        return lock.withLock {
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

    /// A new simulator, off, named after the original.
    func makeCopy(of device: SimulatorDevice, with toolchain: SimulatorToolchain) async throws -> SimulatorDevice {
        let udid = UUID().uuidString
        lock.withLock {
            order.append(udid)
            states[udid] = .off
            names[udid] = "\(device.name) (Yardlet)"
            copiedUDIDs.append(udid)
        }
        return self.device(udid)
    }

    func deleteCopy(_ device: SimulatorDeviceIdentity, with toolchain: SimulatorToolchain) async throws {
        lock.withLock {
            let udid = device.value
            if states[udid] == .on { stoppedUDIDs.append(udid) }
            order.removeAll { $0 == udid }
            states[udid] = nil
            running[udid] = nil
            deletedUDIDs.append(udid)
        }
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
    /// What `simulator_snapshot` reads.
    var tree = SimulatorUITree(elements: [])

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

    func snapshot(of device: SimulatorDevice) async throws -> SimulatorUITree { tree }

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

/// The tests written while a task had one Simulator tab: each task's one tab is `testTab`.
extension SimulatorCenter {
    static let testTab = UUID(uuidString: "7E57AB00-0000-4000-8000-000000000001")!

    func attach(_ query: String, to task: UUID, by requester: SimulatorRequester) async -> SimulatorAttachResult {
        await attach(query, to: task, tab: Self.testTab, by: requester)
    }

    func attach(_ identity: SimulatorDeviceIdentity, to task: UUID,
                by requester: SimulatorRequester) async -> SimulatorAttachResult {
        await attach(identity, to: task, tab: Self.testTab, by: requester)
    }

    func attachment(of task: UUID) -> SimulatorDeviceIdentity? { attachment(of: task, tab: Self.testTab) }

    func detach(_ task: UUID) { detach(task, tab: Self.testTab) }

    @discardableResult
    func claim(for task: UUID) -> UUID? { claim(for: task, tab: Self.testTab) }

    func panelAppeared(for task: UUID) { panelAppeared(for: task, tab: Self.testTab) }

    func panelDisappeared(for task: UUID) { panelDisappeared(for: task, tab: Self.testTab) }

    func prepareAttachedDevice(for task: UUID) async -> SimulatorAttachResult {
        guard let identity = attachment(of: task) else { return await prepareAttachedDevice(.iOSSimulator(udid: ""), for: task) }
        return await prepareAttachedDevice(identity, for: task)
    }
}

extension SimulatorDeviceMenu {
    @MainActor
    static func make(for task: UUID, in center: SimulatorCenter, taskTitle: (UUID) -> String?,
                     approvals: SimulatorApprovals? = nil) -> Self {
        make(for: task, tab: SimulatorCenter.testTab, in: center, taskTitle: taskTitle, approvals: approvals)
    }
}
