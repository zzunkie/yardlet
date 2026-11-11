import Foundation

/// macOS's system-wide "SleepDisabled" power setting, the one `pmset -a disablesleep` sets: while it
/// is on the Mac does not sleep at all, with the lid closed or not. It is kept in
/// /Library/Preferences/com.apple.PowerManagement.plist, so it outlives the process that set it and a
/// restart. Only root can change it.
public protocol SleepDisabledSetting: AnyObject {
    var isOn: Bool { get }
    /// False when macOS refused the change.
    func set(_ on: Bool) -> Bool
}

/// The helper's note that it turned the setting on itself. It is written before the setting changes
/// and removed after the setting is off again, so a helper that ended without turning the setting
/// off (killed, a power cut) finds the note on its next start, and a setting someone else turned on
/// (`pmset`, Amphetamine) is never turned off by Yardlet.
public protocol SleepDisabledRecord: AnyObject {
    var exists: Bool { get }
    /// False when the note could not be written; the setting then stays off, as nothing would put
    /// it back.
    func write() -> Bool
    func remove()
}

/// What Yardlet's lid helper does (docs/SLEEP_PREVENTION.md): the Mac stays awake
/// with its lid closed only while a connected Yardlet says its tasks are working and the battery and
/// the heat allow it, and the setting goes back as soon as either stops, the connection ends or the
/// helper starts or stops. The helper applies the battery and heat rule itself too, so a Yardlet that
/// stopped answering cannot keep a closed Mac awake on an empty battery or at a critical heat; and a
/// client's "working" lasts `lease` unless the client says it again, so a Yardlet whose connection
/// stays open but that stopped running cannot keep it awake either.
public final class LidSleepGuard {
    public typealias Client = Int

    /// How long a client's "working" holds without being said again. Yardlet says it every minute;
    /// the margin covers timers a busy or backgrounded app fires late.
    public static let lease: TimeInterval = 10 * 60

    private let setting: SleepDisabledSetting
    private let record: SleepDisabledRecord
    private let conditions: () -> PowerConditions
    private let now: () -> Date
    /// The clients that said their tasks are working, with when they last said it.
    private var keepingAwake: [Client: Date] = [:]

    /// The setting is on while a client wants it: turned on by this helper, or already on.
    public private(set) var isHolding = false

    public init(setting: SleepDisabledSetting, record: SleepDisabledRecord,
                conditions: @escaping () -> PowerConditions, now: @escaping () -> Date = Date.init) {
        self.setting = setting
        self.record = record
        self.conditions = conditions
        self.now = now
    }

    /// When the helper starts, before any connection: turns off a setting an earlier run left on.
    public func start() { reconcile() }

    /// A client's tasks started working or still are (said again), or stopped. Returns whether the
    /// Mac now stays awake with the lid closed.
    @discardableResult
    public func set(_ client: Client, keepsAwake: Bool) -> Bool {
        keepingAwake[client] = keepsAwake ? now() : nil
        reconcile()
        return isHolding
    }

    /// A client's connection ended: Yardlet quit, crashed or was killed, or let go.
    public func disconnect(_ client: Client) {
        keepingAwake[client] = nil
        reconcile()
    }

    /// The power source or the heat changed, or a periodic check while a client wants the Mac awake.
    public func powerChanged() { reconcile() }

    /// The helper is stopping (unregistered, or the Mac shuts down).
    public func stop() {
        keepingAwake.removeAll()
        reconcile()
    }

    /// The power and the clients' leases are worth checking again later: a client wants the Mac awake.
    public var wantsPowerChecks: Bool { !keepingAwake.isEmpty }

    /// Nothing to hold and nothing to put back: the helper may exit.
    public var isIdle: Bool { keepingAwake.isEmpty && !record.exists }

    private func reconcile() {
        let now = now()
        keepingAwake = keepingAwake.filter { now.timeIntervalSince($0.value) < Self.lease }
        if !keepingAwake.isEmpty, conditions().allowsKeepingLidClosedAwake {
            if setting.isOn {
                isHolding = true
                return
            }
            guard record.write() else {
                isHolding = false
                return
            }
            isHolding = setting.set(true)
            if !isHolding { record.remove() }
            return
        }
        isHolding = false
        guard record.exists else { return }
        if setting.isOn { _ = setting.set(false) }
        // A refusal keeps the record, so the next change or start tries again.
        if !setting.isOn { record.remove() }
    }
}
