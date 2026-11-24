import Foundation
import IOKit.ps
import YardletLidSleep

/// The power source as last read, for main-thread code that asks often (`RunningWorkActivity`, the remote's
/// "on power"). Reading IOKit's power sources is a call to another process that can take a quarter of a second,
/// so it is read off the main thread: once when first asked, and again whenever IOKit says a power source
/// changed (its percentage too). The heat is `ProcessInfo`'s, read when asked. Until the first read arrives it
/// answers "on power", and the read then tells the listeners.
@MainActor final class PowerSourceWatch {
    static let shared = PowerSourceWatch()

    private var latest = PowerConditions()
    private var started = false
    private var listeners: [@MainActor () -> Void] = []
    private var reading = false
    private var readAgain = false

    /// The power source as last read and the heat now; starts watching on first use.
    func current() -> PowerConditions {
        start()
        var conditions = latest
        conditions.thermalState = ProcessInfo.processInfo.thermalState
        return conditions
    }

    /// Runs `handler` on the main thread after a read that changed the power source.
    func onChange(_ handler: @escaping @MainActor () -> Void) {
        listeners.append(handler)
    }

    private func start() {
        guard !started else { return }
        started = true
        // Added to the main run loop for the app's life, so its callback runs on the main thread.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { PowerSourceWatch.shared.read() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        read()
    }

    private func read() {
        guard !reading else { readAgain = true; return }
        reading = true
        DispatchQueue.global(qos: .utility).async {
            let reading = PowerConditions.current()
            Task { @MainActor in PowerSourceWatch.shared.store(reading) }
        }
    }

    private func store(_ new: PowerConditions) {
        reading = false
        let changed = new.onBattery != latest.onBattery || new.batteryPercent != latest.batteryPercent
        latest.onBattery = new.onBattery
        latest.batteryPercent = new.batteryPercent
        if readAgain {
            readAgain = false
            read()
        }
        if changed { listeners.forEach { $0() } }
    }
}
