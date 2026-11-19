import Foundation

enum PlatformAppearanceSettings {
    @MainActor static var all: [YardletSetting] { [.theme, .interfaceSize, .codeFontSize] }

    static func accent(in defaults: UserDefaults) -> YardletAccentPreference {
        defaults.string(forKey: YardletPreferenceKeys.accent).flatMap(YardletAccentPreference.init(rawValue:)) ?? .system
    }
}
