import SwiftUI

enum PlatformAppearanceSettings {
    static func accent(in defaults: UserDefaults) -> YardletAccentPreference {
        MacColorTheme.current(in: defaults).preset
    }

    @MainActor static let all: [YardletSetting] = {
        let preset = YardletSetting.accent
        let colorPreset = YardletSetting(id: preset.id, section: .appearance, title: preset.title, values: preset.values,
            storage: .app(read: { MacColorTheme.current(in: $0.defaults).selectedPreset?.rawValue ?? "custom" },
                          write: { context, raw in
                guard let preset = YardletAccentPreference(rawValue: raw) else { return L10n.string("Unknown color preset") }
                var theme = MacColorTheme.current(in: context.defaults)
                theme.usePreset(preset)
                return save(theme, in: context.defaults)
            }), keywords: preset.keywords)
        let colors = ThemeMode.allCases.flatMap { mode in
            ThemeField.allCases.map { field in
                YardletSetting(id: "\(mode.rawValue)_\(field.rawValue)_color", section: .appearance,
                    title: L10n.format("%@ · %@", mode.title, field.title),
                    detail: L10n.string("An sRGB color in #RRGGBB format, or default."), values: .color,
                    storage: .app(read: { MacColorTheme.current(in: $0.defaults)[overrides: mode][keyPath: field.key]?.hex ?? "default" },
                        write: { context, raw in
                            guard raw == "default" || ThemeRGB(raw) != nil else { return L10n.string("Use #RRGGBB or default.") }
                            var theme = MacColorTheme.current(in: context.defaults)
                            theme[overrides: mode][keyPath: field.key] = ThemeRGB(raw)
                            return save(theme, in: context.defaults)
                        }), keywords: "theme color, custom color")
            }
        }
        let font = YardletSetting(id: "ui_font", section: .appearance, title: L10n.string("Interface font"),
            values: .choices(InterfaceFont.allCases.map { .init(value: $0.rawValue, title: $0.title) }),
            storage: .app(read: { MacColorTheme.current(in: $0.defaults).font.rawValue }, write: { context, raw in
                guard let font = InterfaceFont(rawValue: raw) else { return L10n.string("Unknown font") }
                var theme = MacColorTheme.current(in: context.defaults)
                theme.font = font
                return save(theme, in: context.defaults)
            }), keywords: "font, typeface, serif")
        return [.theme, colorPreset, .interfaceSize, font, .codeFontSize] + colors
    }()

    static func save(_ theme: MacColorTheme, in defaults: UserDefaults) -> String? {
        let failures = ThemeContrast.failures(for: theme)
        guard failures.isEmpty else { return failures.map(\.message).joined(separator: "\n") }
        theme.persist(in: defaults)
        return nil
    }
}
