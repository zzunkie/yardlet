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
    /// which it says; a hot Mac keeps it (REMOTE_V2_DESIGN.md §6.5).
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
}

@MainActor final class FakeLidSleepHelperBackend: LidSleepHelperBackend {
    var answered: (@MainActor (Bool) -> Void)?
    var current: LidSleepHelper.Status
    var calls: [String] = []
    var sent: [Bool] = []

    init(status: LidSleepHelper.Status) { current = status }

    func status() -> LidSleepHelper.Status { current }
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
