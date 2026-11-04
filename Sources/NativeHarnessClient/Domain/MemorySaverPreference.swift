import Foundation

/// Whether Yardlet's memory saver is on (Settings › General "Memory saver"): idle tasks' browser tabs are discarded
/// (`BrowserMemorySaver`) and their harness processes end until the next message (`HarnessMemorySaver`). On unless the
/// person turned it off; turning it off brings the discarded tabs back and ends nothing more. The level, Chrome's
/// Moderate, Balanced or Maximum, sets how soon tabs go; Balanced unless the person chose another.
enum MemorySaverPreference {
    static let key = "YardletMemorySaver"
    static let levelKey = "YardletMemorySaverLevel"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func level(in defaults: UserDefaults = .yardlet) -> BrowserMemorySaver.Level {
        defaults.string(forKey: levelKey).flatMap(BrowserMemorySaver.Level.init(rawValue:)) ?? .balanced
    }
}
