import SwiftUI

enum PlatformAppearanceSettings {
    static func accent(in defaults: UserDefaults) -> YardletAccentPreference {
        MacColorTheme.current(in: defaults).preset
    }

    @MainActor static let all: [YardletSetting] = {
        let preset = YardletSetting.accent
        let paired = YardletSetting(id: preset.id, section: .appearance, title: preset.title, values: preset.values,
            storage: .app(read: { MacColorTheme.current(in: $0.defaults).preset.rawValue }, write: { context, raw in
                guard let preset = YardletAccentPreference(rawValue: raw) else { return L10n.string("Unknown accent") }
                var theme = MacColorTheme.current(in: context.defaults)
                theme.usePreset(preset)
                return save(theme, in: context.defaults)
            }))
        let colors = ThemeMode.allCases.flatMap { mode in
            ThemeField.allCases.map { field in
                YardletSetting(id: "\(mode.rawValue)_\(field.rawValue)_color", section: .appearance,
                    title: L10n.format("%@ · %@", mode.title, field.title),
                    detail: L10n.string("An sRGB color in #RRGGBB format, or default."), values: .color,
                    storage: .app(read: { MacColorTheme.current(in: $0.defaults)[mode][keyPath: field.key]?.hex ?? "default" },
                        write: { context, raw in
                            guard raw == "default" || ThemeRGB(raw) != nil else { return L10n.string("Use #RRGGBB or default.") }
                            var theme = MacColorTheme.current(in: context.defaults)
                            theme[mode][keyPath: field.key] = ThemeRGB(raw)
                            return save(theme, in: context.defaults)
                        }))
            }
        }
        let font = YardletSetting(id: "ui_font", section: .appearance, title: L10n.string("Interface font"),
            values: .choices(InterfaceFont.allCases.map { .init(value: $0.rawValue, title: $0.title) }),
            storage: .app(read: { MacColorTheme.current(in: $0.defaults).font.rawValue }, write: { context, raw in
                guard let font = InterfaceFont(rawValue: raw) else { return L10n.string("Unknown font") }
                var theme = MacColorTheme.current(in: context.defaults)
                theme.font = font
                return save(theme, in: context.defaults)
            }))
        return [.theme, paired, .interfaceSize, font, .codeFontSize] + colors
    }()

    static func save(_ theme: MacColorTheme, in defaults: UserDefaults) -> String? {
        let failures = ThemeContrast.failures(for: theme)
        guard failures.isEmpty else { return failures.map(\.message).joined(separator: "\n") }
        theme.persist(in: defaults)
        return nil
    }
}
