import XCTest
import YardletLidSleep
@testable import NativeHarnessClient

@MainActor final class RunningWorkActivityTests: XCTestCase {
    func testTheSleepAssertionFollowsWhetherATaskIsWorking() {
        let activity = RunningWorkActivity()
        XCTAssertFalse(activity.isHolding)
        activity.update(isWorking: true)
        activity.update(isWorking: true)
        XCTAssertTrue(activity.isHolding, "Repeated updates keep one assertion")
        activity.update(isWorking: false)
        XCTAssertFalse(activity.isHolding)
        activity.update(isWorking: false)
        XCTAssertFalse(activity.isHolding)
    }

    /// The display is held only while tasks work with the setting on, and lets go on a low battery,
    /// which it says; a hot Mac keeps it (docs/SLEEP_PREVENTION.md).
    func testTheScreenStaysOnOnlyWhileWorkingWithTheSettingOnAndPowerToSpare() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RunningWorkActivity")))
        var conditions = PowerConditions(onBattery: true, batteryPercent: 80)
        let activity = RunningWorkActivity(defaults: defaults, conditions: { conditions })
        activity.update(isWorking: true)
        XCTAssertTrue(activity.isHolding)
        XCTAssertFalse(activity.isHoldingDisplay, "Off by default")
        defaults.set(true, forKey: KeepScreenAwakePreference.key)
        activity.refresh()
        XCTAssertTrue(activity.isHoldingDisplay)
        conditions.batteryPercent = 19
        activity.refresh()
        XCTAssertFalse(activity.isHoldingDisplay, "A battery under 20% lets the screen lock")
        XCTAssertTrue(activity.isPausedForBattery, "and says so")
        conditions = PowerConditions(onBattery: false, batteryPercent: 5)
        activity.refresh()
        XCTAssertTrue(activity.isHoldingDisplay, "On power a low charge does not matter")
        XCTAssertFalse(activity.isPausedForBattery)
        activity.update(isWorking: false)
        XCTAssertFalse(activity.isHoldingDisplay)
        XCTAssertFalse(activity.isHolding)
    }

    /// "Keep tasks working with the lid closed" with the helper's registration and connection faked:
    /// a helper left registered is removed, turning it on asks macOS once, nothing is asked before
    /// macOS allows it, and the lid is kept awake only while tasks work on enough power. A hot Mac with
    /// its lid closed says so once and keeps working; a critical heat or a low battery lets it sleep and
    /// says so once, until it cools down or is on power; turning the setting off ends the connection
    /// and removes the helper (§13.78).
    func testTheLidStaysAwakeOnlyWhileWorkingWithTheHelperAllowedAndSaysWhenItCannot() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RunningWorkActivity")))
        var conditions = PowerConditions(onBattery: true, batteryPercent: 80)
        var lidClosed = false
        let backend = FakeLidSleepHelperBackend(status: .ready)
        let helper = LidSleepHelper(backend: backend)
        let activity = RunningWorkActivity(defaults: defaults, conditions: { conditions }, lidHelper: helper,
                                           lidIsClosed: { lidClosed })
        var notices: [String] = []
        activity.notify = { _, _, identifier in notices.append(identifier) }

        activity.update(isWorking: true)
        XCTAssertEqual(backend.calls, ["disconnect", "unregister"], "Off, so a helper an earlier run left registered goes")
        try await waitUntil { helper.status == .off }

        defaults.set(true, forKey: LidClosedWorkPreference.key)
        activity.refresh()
        XCTAssertEqual(backend.calls.suffix(2), ["register", "openSystemSettings"])
        XCTAssertEqual(helper.status, .needsApproval)
        XCTAssertTrue(backend.sent.isEmpty, "Nothing is asked before macOS allows the helper")

        backend.current = .ready
        activity.checkAgain()
        // The status is read off the main thread, and the lid kept awake once it says allowed.
        try await waitUntil { backend.sent == [true] }
        XCTAssertTrue(helper.isKeepingAwake)
        XCTAssertTrue(activity.isHolding, "The idle-sleep assertion stays as before")
        activity.checkAgain()
        XCTAssertEqual(backend.sent, [true, true], "Said again every minute, within the helper's lease")

        conditions.thermalState = .serious
        activity.refresh()
        XCTAssertTrue(notices.isEmpty, "Hot with the lid open: the Mac can be used to cool it")
        lidClosed = true
        activity.refresh()
        activity.refresh()
        XCTAssertEqual(notices, ["yardlet.lidAwakeHot"], "Once")
        XCTAssertTrue(helper.isKeepingAwake, "and it keeps working")

        conditions.thermalState = .critical
        activity.refresh()
        activity.refresh()
        XCTAssertEqual(backend.sent, [true, true, false], "Critical: the Mac may sleep to cool down")
        XCTAssertFalse(helper.isKeepingAwake)
        XCTAssertEqual(activity.lidPause, .heat)
        XCTAssertEqual(notices, ["yardlet.lidAwakeHot", "yardlet.lidAwakePausedForHeat"], "and it says so once")
        conditions.thermalState = .serious
        activity.refresh()
        XCTAssertEqual(backend.sent, [true, true, false, true], "Out of critical: kept awake again")
        XCTAssertNil(activity.lidPause)
        XCTAssertEqual(notices.count, 2, "Still hot, which it already said")
        conditions.thermalState = .nominal

        conditions.batteryPercent = 19
        activity.refresh()
        activity.refresh()
        XCTAssertEqual(backend.sent, [true, true, false, true, false])
        XCTAssertFalse(helper.isKeepingAwake)
        XCTAssertEqual(activity.lidPause, .battery)
        XCTAssertEqual(notices.last, "yardlet.lidAwakePausedForBattery")
        XCTAssertEqual(notices.count, 3)
        conditions = PowerConditions(onBattery: false, batteryPercent: 19)
        activity.refresh()
        XCTAssertEqual(backend.sent.last, true, "On power again")
        XCTAssertNil(activity.lidPause)

        activity.update(isWorking: false)
        XCTAssertEqual(backend.sent.last, false, "The work ended")
        activity.update(isWorking: true)
        XCTAssertTrue(helper.isKeepingAwake)
        defaults.set(false, forKey: LidClosedWorkPreference.key)
        activity.refresh()
        XCTAssertEqual(backend.calls.suffix(2), ["disconnect", "unregister"])
        try await waitUntil { helper.status == .off }
        XCTAssertFalse(helper.isKeepingAwake)
    }

    func testDeferredInitialStatusAvoidsSyncReadAtLaunchAndReconcilesWhenLoaded() async throws {
        // Case 1: preference ON and helper already ready -> zero sync `status()` calls on init or turnOn,
        // and keeps Mac awake once async `readStatus()` resolves.
        let defaultsOn = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("LidDeferredOn")))
        defaultsOn.set(true, forKey: LidClosedWorkPreference.key)
        let backendOn = FakeLidSleepHelperBackend(status: .ready, deferReadStatus: true)
        let helperOn = LidSleepHelper(backend: backendOn, readsStatusOnInit: true)
        XCTAssertEqual(backendOn.syncStatusReads, 0, "Deferred launch init must not call sync status()")
        XCTAssertFalse(helperOn.hasLoadedStatus)

        let activityOn = RunningWorkActivity(
            defaults: defaultsOn,
            conditions: { PowerConditions(onBattery: false, batteryPercent: 100) },
            lidHelper: helperOn,
            lidIsClosed: { false }
        )
        activityOn.update(isWorking: true)
        try await waitUntil { backendOn.hasPendingRead }
        XCTAssertTrue(backendOn.calls.isEmpty, "Waits for initial status before registering or unregistering")
        XCTAssertTrue(backendOn.sent.isEmpty)

        backendOn.completeReadStatus()
        try await waitUntil { helperOn.hasLoadedStatus && backendOn.sent == [true] }
        XCTAssertEqual(backendOn.syncStatusReads, 0, "Already-ready helper needs no sync status() read")
        XCTAssertTrue(helperOn.isKeepingAwake)

        // Case 2: preference OFF while an earlier run left helper ready -> unregisters once async status loads.
        let defaultsOff = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("LidDeferredOff")))
        let backendOff = FakeLidSleepHelperBackend(status: .ready, deferReadStatus: true)
        let helperOff = LidSleepHelper(backend: backendOff, readsStatusOnInit: true)
        let activityOff = RunningWorkActivity(
            defaults: defaultsOff,
            conditions: { PowerConditions(onBattery: false, batteryPercent: 100) },
            lidHelper: helperOff,
            lidIsClosed: { false }
        )
        activityOff.update(isWorking: true)
        try await waitUntil { backendOff.hasPendingRead }
        XCTAssertTrue(backendOff.calls.isEmpty)

        backendOff.completeReadStatus()
        try await waitUntil { backendOff.calls == ["disconnect", "unregister"] }
        try await waitUntil { helperOff.status == .off }
        XCTAssertEqual(backendOff.syncStatusReads, 0)

        // Case 3: desktop Mac calling turnOff() before initial read completes (without retaining helper)
        // still unregisters an active helper once async readStatus() completes.
        let backendDesktop = FakeLidSleepHelperBackend(status: .ready, deferReadStatus: true)
        do {
            let helperDesktop = LidSleepHelper(backend: backendDesktop, readsStatusOnInit: true)
            helperDesktop.turnOff()
        }
        try await waitUntil { backendDesktop.hasPendingRead }
        backendDesktop.completeReadStatus()
        try await waitUntil { backendDesktop.calls == ["disconnect", "unregister"] }
        XCTAssertEqual(backendDesktop.syncStatusReads, 0)

        // Case 4: user toggles setting ON before initial status finishes -> still opens System Settings.
        let defaultsToggled = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("LidDeferredToggle")))
        let backendToggled = FakeLidSleepHelperBackend(status: .off, deferReadStatus: true)
        let helperToggled = LidSleepHelper(backend: backendToggled, readsStatusOnInit: true)
        let activityToggled = RunningWorkActivity(
            defaults: defaultsToggled,
            conditions: { PowerConditions(onBattery: false, batteryPercent: 100) },
            lidHelper: helperToggled,
            lidIsClosed: { false }
        )
        activityToggled.update(isWorking: true)
        defaultsToggled.set(true, forKey: LidClosedWorkPreference.key)
        activityToggled.refresh()
        try await waitUntil { backendToggled.hasPendingRead }
        backendToggled.completeReadStatus()
        try await waitUntil { backendToggled.calls.suffix(2) == ["register", "openSystemSettings"] }
    }
}

@MainActor final class FakeLidSleepHelperBackend: LidSleepHelperBackend {
    var answered: (@MainActor (Bool) -> Void)?
    var current: LidSleepHelper.Status
    var calls: [String] = []
    var sent: [Bool] = []
    var syncStatusReads = 0
    private var deferReadStatus: Bool
    private var readContinuations: [CheckedContinuation<LidSleepHelper.Status, Never>] = []
    var hasPendingRead: Bool { !readContinuations.isEmpty }

    init(status: LidSleepHelper.Status, deferReadStatus: Bool = false) {
        current = status
        self.deferReadStatus = deferReadStatus
    }

    func status() -> LidSleepHelper.Status {
        syncStatusReads += 1
        return current
    }

    func readStatus() async -> LidSleepHelper.Status {
        if deferReadStatus {
            return await withCheckedContinuation { continuation in
                readContinuations.append(continuation)
            }
        }
        return current
    }

    func completeReadStatus() {
        deferReadStatus = false
        let pending = readContinuations
        readContinuations = []
        for continuation in pending {
            continuation.resume(returning: current)
        }
    }
    func register() {
        calls.append("register")
        current = .needsApproval
    }
    func unregister(done: @escaping @MainActor () -> Void) {
        calls.append("unregister")
        current = .off
        done()
    }
    func openSystemSettings() { calls.append("openSystemSettings") }
    func send(keepsAwake: Bool) {
        sent.append(keepsAwake)
        answered?(keepsAwake)
    }
    func disconnect() { calls.append("disconnect") }
}
