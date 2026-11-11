import XCTest
import YardletLidSleep

/// The lid helper's rules with the system setting and its record in memory: the helper never touches
/// the Mac's power settings in a test (docs/SLEEP_PREVENTION.md).
final class LidSleepGuardTests: XCTestCase {
    private final class Setting: SleepDisabledSetting {
        var isOn = false
        var refuses = false
        var changes: [Bool] = []
        func set(_ on: Bool) -> Bool {
            guard !refuses else { return false }
            isOn = on
            changes.append(on)
            return true
        }
    }

    private final class Record: SleepDisabledRecord {
        var exists = false
        var refusesWrite = false
        func write() -> Bool {
            guard !refusesWrite else { return false }
            exists = true
            return true
        }
        func remove() { exists = false }
    }

    /// Start, work starting and ending on two connections, a connection ending, the battery, the
    /// heat, a refusal, and stopping: the setting is on only while a client wants it and the battery
    /// and the heat allow, and goes back whichever way the work ends.
    func testTheSettingIsOnOnlyWhileAClientWantsItAndGoesBackHoweverItEnds() {
        let setting = Setting()
        let record = Record()
        var power = PowerConditions(onBattery: true, batteryPercent: 80)
        let lid = LidSleepGuard(setting: setting, record: record, conditions: { power })

        // An earlier run was killed while holding: its record is there, and starting turns the setting off.
        setting.isOn = true
        record.exists = true
        lid.start()
        XCTAssertFalse(setting.isOn)
        XCTAssertFalse(record.exists)
        XCTAssertTrue(lid.isIdle)

        XCTAssertTrue(lid.set(1, keepsAwake: true))
        XCTAssertTrue(setting.isOn)
        XCTAssertTrue(record.exists, "Written with the setting, so a killed helper leaves it behind")
        XCTAssertTrue(lid.set(2, keepsAwake: true))
        XCTAssertTrue(lid.set(1, keepsAwake: false), "Another client still wants it")
        lid.disconnect(2)
        XCTAssertFalse(setting.isOn, "Yardlet quit or crashed: back at once")
        XCTAssertFalse(record.exists)

        lid.set(1, keepsAwake: true)
        power.batteryPercent = 19
        lid.powerChanged()
        XCTAssertFalse(setting.isOn, "A battery under 20% lets the Mac sleep")
        XCTAssertFalse(lid.isHolding)
        XCTAssertTrue(lid.wantsPowerChecks, "and keeps checking")
        power = PowerConditions(onBattery: false, batteryPercent: 19)
        lid.powerChanged()
        XCTAssertTrue(setting.isOn, "On power again")
        power.thermalState = .serious
        lid.powerChanged()
        XCTAssertTrue(setting.isOn, "Hot: Yardlet says so and the work goes on")
        power.thermalState = .critical
        lid.powerChanged()
        XCTAssertFalse(setting.isOn, "Critical: the Mac may sleep to cool down, even if Yardlet stopped answering")
        XCTAssertTrue(lid.wantsPowerChecks)
        power.thermalState = .serious
        lid.powerChanged()
        XCTAssertTrue(setting.isOn, "Out of critical")

        lid.stop()
        XCTAssertFalse(setting.isOn, "Unregistered or shutting down")
        XCTAssertFalse(record.exists)
        XCTAssertFalse(lid.wantsPowerChecks)
        XCTAssertEqual(setting.changes, [false, true, false, true, false, true, false, true, false])

        setting.refuses = true
        XCTAssertFalse(lid.set(3, keepsAwake: true), "macOS refused the setting: the reply says so")
        XCTAssertFalse(record.exists)
        setting.refuses = false
        record.refusesWrite = true
        XCTAssertFalse(lid.set(4, keepsAwake: true), "No record, so nothing would put it back: it stays off")
        XCTAssertFalse(setting.isOn)
    }

    /// A client's "working" lapses when it is not said again within the lease, as from a Yardlet
    /// whose connection stays open but that stopped running.
    func testAWorkingThatIsNotSaidAgainLapses() {
        let setting = Setting()
        let record = Record()
        var now = Date(timeIntervalSince1970: 0)
        let lid = LidSleepGuard(setting: setting, record: record, conditions: { PowerConditions() }, now: { now })
        XCTAssertTrue(lid.set(1, keepsAwake: true))
        now += LidSleepGuard.lease - 1
        lid.powerChanged()
        XCTAssertTrue(setting.isOn)
        lid.set(1, keepsAwake: true)
        now += LidSleepGuard.lease - 1
        lid.powerChanged()
        XCTAssertTrue(setting.isOn, "Said again in time")
        now += 2
        lid.powerChanged()
        XCTAssertFalse(setting.isOn, "Not said again within the lease")
        XCTAssertFalse(record.exists)
        XCTAssertFalse(lid.wantsPowerChecks)
        XCTAssertTrue(lid.set(1, keepsAwake: true), "Said again later: held again")
    }

    /// A setting someone else turned on (`pmset`, Amphetamine) is used while tasks work and left on.
    func testASettingSomeoneElseTurnedOnIsLeftAsItWas() {
        let setting = Setting()
        let record = Record()
        setting.isOn = true
        let lid = LidSleepGuard(setting: setting, record: record, conditions: { PowerConditions() })
        lid.start()
        XCTAssertTrue(setting.isOn, "No record: not Yardlet's to turn off")
        XCTAssertTrue(lid.set(1, keepsAwake: true))
        XCTAssertFalse(record.exists)
        lid.disconnect(1)
        XCTAssertTrue(setting.isOn)
        XCTAssertTrue(setting.changes.isEmpty)
    }
}
