import Foundation

/// Settings › General › Simulator: the side panel's Simulator tab and what runs for it. On by default, and offered
/// on the Mac only, the one app with a simulator panel; it shows whether or not Xcode is installed, and the tab says
/// what is missing. Turned off, the launcher and the + menu leave Simulator out, open Simulator tabs close, the
/// simulator host ends and the devices Yardlet started stop (`SimulatorCenter.setEnabled(_:)`).
enum SimulatorPreference {
    static let key = "YardletSimulator"

#if os(macOS)
    static let isOffered = true
#else
    static let isOffered = false
#endif

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        isOffered && (defaults.object(forKey: key) as? Bool ?? true)
    }
}

/// The symbol of a Simulator tab and of a device: its platform's device, an iPhone while none is attached.
enum SimulatorTabSymbol {
    static func name(for platform: SimulatorPlatform?) -> String {
        switch platform {
        case .android: "smartphone"
        case .iOS, nil: "iphone"
        }
    }
}
