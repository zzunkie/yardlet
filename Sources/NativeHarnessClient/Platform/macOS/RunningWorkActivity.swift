import AppKit
import Foundation
import IOKit
import Observation
import YardletLidSleep

/// Settings › General › "Keep the screen unlocked while tasks work". Off by default: a Mac left alone
/// stays unlocked while it is on (docs/REMOTE_V2_DESIGN.md §6.5).
enum KeepScreenAwakePreference {
    static let key = "Yardlet.keepScreenAwakeWhileWorking"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// Keeps the Mac from idle-sleeping while a task is working, as the Codex app does; the display may
/// still sleep. A task waiting for the person's approval is not working, so it does not count,
/// unless a paired phone can answer it (`AppModel.keepsMacAwake`). For that time, two settings go
/// further, each off by default:
///
/// - "Keep the screen unlocked while tasks work": the display stays on too, so the screen does not
///   lock and a harness's computer use keeps working while the person is away.
/// - "Keep tasks working with the lid closed": Yardlet's lid helper keeps the Mac awake with its lid
///   closed (`LidSleepHelper`). A Mac that gets hot (serious) with its lid closed says so once and
///   keeps working, as letting it sleep without a word stops the work (2026-10-26); at a critical heat
///   it lets the Mac sleep until it cools down, which the person is told once and the menu bar menu
///   says (2026-10-27).
///
/// Neither holds on a battery under 20%, which the person is told once and the menu bar menu says.
/// The assertions end with the work or the process, and the lid helper lets go when Yardlet's
/// connection to it ends.
@MainActor final class RunningWorkActivity {
    private var token: NSObjectProtocol?
    private var displayToken: NSObjectProtocol?
    private weak var followed: AppModel?
    private var working = false
    private var observers: [NSObjectProtocol] = []
    private var powerCheck: Timer?
    private let defaults: UserDefaults
    private let conditions: @MainActor () -> PowerConditions
    /// The app sets it before following its model; nil in tests and fixtures, which then never
    /// register or remove the helper.
    var lidHelper: LidSleepHelper? {
        didSet { lidHelper?.keepingAwakeChanged = { [weak self] in self?.showLidState() } }
    }
    private let lidIsClosed: @MainActor () -> Bool
    /// The lid setting as last read; nil until the first read, which only tidies up after an
    /// earlier run, never opens System Settings.
    private var lidPreferenceWasOn: Bool?
    /// The person was told the Mac is hot with its lid closed; again only after it cooled down.
    private var toldHot = false
    /// Posts a notification (title, body, identifier); the followed model's notification center
    /// unless a test puts its own in place.
    var notify: (@MainActor (String, String, String) -> Void)?

    init(defaults: UserDefaults = .yardlet,
         conditions: @escaping @MainActor () -> PowerConditions = PowerConditions.current,
         lidHelper: LidSleepHelper? = nil,
         lidIsClosed: @escaping @MainActor () -> Bool = Clamshell.isClosed) {
        self.defaults = defaults
        self.conditions = conditions
        self.lidIsClosed = lidIsClosed
        self.lidHelper = lidHelper
        // Observers do not run for a value set in the initializer.
        lidHelper?.keepingAwakeChanged = { [weak self] in self?.showLidState() }
    }

    var isHolding: Bool { token != nil }
    /// The display is kept on now.
    var isHoldingDisplay: Bool { displayToken != nil }
    /// The setting wants the display on, but a battery under 20% lets the screen lock.
    private(set) var isPausedForBattery = false
    /// The lid setting wants the Mac awake, but the battery or the heat lets it sleep with the lid closed.
    private(set) var lidPause: LidAwakePause?

    /// Follows `model.keepsMacAwake` from now on. It is observed here rather than in a view: the
    /// value reads every task's record, and the scene observing it re-evaluated the window's root
    /// whenever any task's record changed.
    func follow(_ model: AppModel) {
        guard followed !== model else { return }
        followed = model
        let center = NotificationCenter.default
        observers = [
            // Delivered on the writing thread and passed on without holding it, as `MenuBarStatusItem`
            // does: a main-queue observer holds a writer on another thread until the main thread runs
            // it, and a main thread waiting for that writer then never does.
            center.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.refresh() }
            },
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            // The person may have allowed the helper in System Settings.
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lidHelper?.refreshStatus { self?.refresh() }
                    self?.refresh()
                }
            }
        ]
        track()
    }

    func update(isWorking: Bool) {
        working = isWorking
        if isWorking, token == nil {
            token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                reason: "A Yardlet task is running")
        } else if !isWorking, let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
        refresh()
    }

    /// Holds or lets go of the display and the lid as the work, the settings, the battery and the
    /// heat say.
    func refresh() {
        let conditions = conditions()
        let allowed = conditions.allowsKeepingAwake
        let wanted = working && KeepScreenAwakePreference.isOn(in: defaults)
        let holds = wanted && allowed
        let paused = wanted && !allowed
        let lidWanted = refreshLidHelper()
        let lidPause: LidAwakePause? = !lidWanted ? nil
            : conditions.isCriticallyHot ? .heat
            : !allowed ? .battery
            : nil
        lidHelper?.keepAwake(lidWanted && lidPause == nil)
        if let lidPause, lidPause != self.lidPause {
            switch lidPause {
            case .battery:
                post(L10n.string("Closing the lid puts the Mac to sleep now"),
                     L10n.string("The battery is under 20%. Yardlet keeps tasks working with the lid closed again on power."),
                     "yardlet.lidAwakePausedForBattery")
            case .heat:
                post(L10n.string("The Mac is too hot, so closing the lid puts it to sleep"),
                     L10n.string("Yardlet keeps tasks working with the lid closed again once the Mac cools down."),
                     "yardlet.lidAwakePausedForHeat")
                // Back from critical while still hot needs no second notice.
                toldHot = true
            }
        }
        // The lid's notice already says the battery is low when both let go at once.
        if paused, !isPausedForBattery, !(lidPause == .battery && self.lidPause != .battery) {
            post(L10n.string("The screen can lock now"),
                 L10n.string("The battery is under 20%. Yardlet keeps the screen unlocked again on power."),
                 "yardlet.screenAwakePausedForBattery")
        }
        isPausedForBattery = paused
        self.lidPause = lidPause
        followed?.screenAwakePausedForBattery = paused
        followed?.lidAwakePause = lidPause
        if holds, displayToken == nil {
            displayToken = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled],
                reason: "A Yardlet task is running and the screen stays unlocked")
        } else if !holds, let displayToken {
            ProcessInfo.processInfo.endActivity(displayToken)
            self.displayToken = nil
        }
        followed?.keepsScreenAwake = displayToken != nil
        showLidState()
        // While either is wanted, the battery (and the lid, for the heat) is read again every minute.
        if wanted || lidWanted, powerCheck == nil {
            powerCheck = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkAgain() }
            }
        } else if !wanted, !lidWanted {
            powerCheck?.invalidate()
            powerCheck = nil
        }
    }

    /// What the helper last answered, for the menu bar menu, and the heat while it keeps a closed
    /// Mac awake.
    private func showLidState() {
        let keepsLidAwake = lidHelper?.isKeepingAwake == true
        followed?.keepsAwakeWithLidClosed = keepsLidAwake
        let hot = conditions().thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if keepsLidAwake, hot, !toldHot, lidIsClosed() {
            toldHot = true
            post(L10n.string("The Mac is hot with its lid closed"),
                 L10n.string("Tasks keep working. Open the lid or move the Mac somewhere cooler."),
                 "yardlet.lidAwakeHot")
        } else if !hot {
            toldHot = false
        }
    }

    /// The minute's check: the battery and the heat, and the helper's "working", said again.
    func checkAgain() {
        if lidHelper?.status == .needsApproval { lidHelper?.refreshStatus { [weak self] in self?.refresh() } }
        lidHelper?.renew()
        refresh()
    }

    /// Registers or removes the lid helper as the setting changes, and says whether the lid should
    /// be kept awake now (before the battery).
    private func refreshLidHelper() -> Bool {
        guard let lidHelper else { return false }
        let isOn = LidClosedWorkPreference.isOn(in: defaults)
        if isOn != lidPreferenceWasOn {
            let firstRead = lidPreferenceWasOn == nil
            lidPreferenceWasOn = isOn
            if isOn {
                lidHelper.turnOn(opensSettings: !firstRead)
            } else if !firstRead || lidHelper.status == .ready || lidHelper.status == .needsApproval {
                // Turned off now, or off since a run that ended before it removed the helper.
                lidHelper.turnOff()
            }
        }
        return working && isOn && lidHelper.status == .ready
    }

    private func post(_ title: String, _ body: String, _ identifier: String) {
        if let notify { return notify(title, body, identifier) }
        guard let model = followed else { return }
        Task { await model.systemNotificationCenter.post(title: title, body: body, identifier: identifier) }
    }

    private func track() {
        guard let model = followed else { return }
        let working = withObservationTracking { model.keepsMacAwake } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        update(isWorking: working)
    }
}

/// Whether the built-in display's lid is closed (IOKit's power root domain; reads only).
enum Clamshell {
    @MainActor static func isClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
    }
}
