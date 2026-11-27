import AppKit
import SwiftUI

extension ThemeRGB {
    init(_ resolved: Color.Resolved) {
        func byte(_ component: Float) -> UInt8 { UInt8((max(0, min(1, component)) * 255).rounded()) }
        self.init(red: byte(resolved.red), green: byte(resolved.green), blue: byte(resolved.blue))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(value >> 16) / 255, green: CGFloat(value >> 8 & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    var color: Color { Color(nsColor: nsColor) }
    /// `color` resolved, from its sRGB bytes without going through AppKit: the same components.
    var resolved: Color.Resolved {
        Color.Resolved(red: Float(CGFloat(value >> 16) / 255), green: Float(CGFloat(value >> 8 & 255) / 255),
                       blue: Float(CGFloat(value & 255) / 255))
    }
}

enum ThemeMode: String, CaseIterable {
    case light, dark
    var title: String { self == .dark ? L10n.string("Dark") : L10n.string("Light") }
    var scheme: ColorScheme { self == .dark ? .dark : .light }
    init(_ scheme: ColorScheme) { self = scheme == .dark ? .dark : .light }
}

enum ThemeField: String, CaseIterable {
    case accent, background, text
    var title: String {
        switch self {
        case .accent: L10n.string("Accent")
        case .background: L10n.string("Background")
        case .text: L10n.string("Text color")
        }
    }
    var key: WritableKeyPath<ThemeColors, ThemeRGB?> {
        switch self {
        case .accent: \.accent
        case .background: \.background
        case .text: \.text
        }
    }
}

struct ThemeColors: Hashable, Codable {
    var accent: ThemeRGB?
    var background: ThemeRGB?
    var text: ThemeRGB?
}

extension YardletAccentPreference {
    /// The accent bridges to AppKit as an adaptive NSColor. Empty fields use native surface and label colors.
    private static let colors: [Self: (light: ThemeColors, dark: ThemeColors)] = {
        func swatch(_ accent: String, _ background: String? = nil, _ text: String? = nil) -> ThemeColors {
            ThemeColors(accent: ThemeRGB(accent), background: background.flatMap(ThemeRGB.init),
                        text: text.flatMap(ThemeRGB.init))
        }
        return [
            .ink: (swatch("#143B6B"), swatch("#8CB8FA")),
            .grove: (swatch("#14664A"), swatch("#7AD1AD")),
            .iris: (swatch("#5C45AB"), swatch("#B8A6FA")),
            .nord: (swatch("#5E81AC", "#FEFEFE", "#2E3440"), swatch("#88C0D0", "#20242D", "#ECEFF4")),
            .catppuccin: (swatch("#8839EF", "#FEFEFE", "#4C4F69"), swatch("#CBA6F7", "#1E1E2E", "#CDD6F4")),
            .ember: (swatch("#943F20", "#FFFFFE", "#3B2823"), swatch("#F3AB82", "#211714", "#F7E7DA")),
            .tidepool: (swatch("#006C68", "#FEFFFF", "#193537"), swatch("#75D7CB", "#102326", "#D5F3EE")),
        ]
    }()

    static let completePresets = allCases.filter { $0.colors(in: .light).background != nil }
    static let accentOnlyPresets = allCases.filter { $0 != .system && $0.colors(in: .light).background == nil }

    func colors(in mode: ThemeMode) -> ThemeColors {
        let pair = Self.colors[self]
        return (mode == .light ? pair?.light : pair?.dark) ?? ThemeColors()
    }
}

enum InterfaceFont: String, CaseIterable, Codable {
    case system, serif, rounded
    var title: String {
        switch self {
        case .system: L10n.string("System")
        case .serif: L10n.string("Serif")
        case .rounded: L10n.string("Rounded")
        }
    }
    var design: Font.Design? {
        switch self { case .system: nil; case .serif: .serif; case .rounded: .rounded }
    }
    func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard self != .system, let descriptor = base.fontDescriptor.withDesign(self == .serif ? .serif : .rounded)
        else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

struct MacColorTheme: Hashable, Codable {
    static let key = "YardletColorTheme"
    var preset = YardletAccentPreference.system
    var light = ThemeColors()
    var dark = ThemeColors()
    var font = InterfaceFont.system

    subscript(overrides mode: ThemeMode) -> ThemeColors {
        get { mode == .light ? light : dark }
        set { if mode == .light { light = newValue } else { dark = newValue } }
    }

    /// The accent stays adaptive until an override replaces it. Surface and text colors inherit from the preset.
    subscript(mode: ThemeMode) -> ThemeColors {
        var colors = self[overrides: mode]
        let base = preset.colors(in: mode)
        colors.background = colors.background ?? base.background
        colors.text = colors.text ?? base.text
        return colors
    }

    var selectedPreset: YardletAccentPreference? {
        light == ThemeColors() && dark == ThemeColors() ? preset : nil
    }

    static func read(_ data: Data?, legacy: YardletAccentPreference) -> Self {
        if let data, let theme = try? JSONDecoder().decode(Self.self, from: data) { return theme }
        return Self(preset: legacy)
    }

    static func current(in defaults: UserDefaults = .yardlet) -> Self {
        let legacy = defaults.string(forKey: YardletPreferenceKeys.accent).flatMap(YardletAccentPreference.init(rawValue:)) ?? .system
        return read(defaults.data(forKey: key), legacy: legacy)
    }

    func persist(in defaults: UserDefaults) {
        // The old key belongs to a build with only paired presets. Removing it before the last
        // override disappears keeps a reset from bringing that old preset back on relaunch.
        if self == Self() {
            defaults.removeObject(forKey: YardletPreferenceKeys.accent)
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
            defaults.removeObject(forKey: YardletPreferenceKeys.accent)
        }
    }

    mutating func usePreset(_ newValue: YardletAccentPreference) {
        preset = newValue
        light = ThemeColors()
        dark = ThemeColors()
    }

    func accent(in mode: ThemeMode) -> NSColor {
        self[overrides: mode].accent?.nsColor ?? ParityTheme.accentColor(for: preset)
    }
}

extension EnvironmentValues {
    @Entry var yardletColorTheme = MacColorTheme()
}

enum ThemeSurface: Hashable, CaseIterable, ShapeStyle {
    case canvas, sidebar, elevated, input, review

    /// The native surface in `mode`: a fixed sRGB color, except the review surface, the system's text background.
    func native(in mode: ThemeMode) -> NSColor {
        switch (self, mode) {
        case (.canvas, .dark): NSColor(srgbRed: 0.098, green: 0.100, blue: 0.108, alpha: 1) // #191A1B
        case (.canvas, .light): NSColor(srgbRed: 0.988, green: 0.988, blue: 0.990, alpha: 1) // #FCFCFC
        case (.sidebar, .dark): NSColor(srgbRed: 0.125, green: 0.129, blue: 0.141, alpha: 1) // #202124
        case (.sidebar, .light): NSColor(srgbRed: 0.957, green: 0.961, blue: 0.969, alpha: 1) // #F4F5F7
        case (.elevated, .dark): NSColor(srgbRed: 0.153, green: 0.157, blue: 0.173, alpha: 1) // #27282C
        case (.input, .dark): NSColor(srgbRed: 0.173, green: 0.176, blue: 0.192, alpha: 1) // #2C2D31
        case (.elevated, .light), (.input, .light): .white
        case (.review, _): .textBackgroundColor
        }
    }

    var original: Color {
        switch self {
        case .canvas: ParityTheme.originalCanvas
        case .sidebar: ParityTheme.originalSidebar
        case .elevated: ParityTheme.originalElevated
        case .input: ParityTheme.originalInput
        case .review: Color(nsColor: .textBackgroundColor)
        }
    }

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        ThemeResolution.current(in: environment)[self]
    }

    /// `resolve(in:)` worked out anew: only the review surface goes through AppKit.
    func resolveUncached(in environment: EnvironmentValues) -> Color.Resolved {
        let mode = ThemeMode(environment.colorScheme)
        let base = self == .review ? original.resolve(in: environment) : Self.fixed[mode]![self]!
        guard let background = environment.yardletColorTheme[mode].background else { return base }
        return Self.shifted(base, onto: background, in: mode)
    }

    /// `surface`, a native surface in `mode`, on the theme's `background` instead of the native canvas: the
    /// brightness steps between the native surfaces, including the raised composer, are kept.
    static func shifted(_ surface: Color.Resolved, onto background: ThemeRGB, in mode: ThemeMode) -> Color.Resolved {
        let canvas = fixed[mode]![.canvas]!
        let chosen = background.resolved
        func shifted(_ channel: Float, _ surface: Float, _ original: Float) -> Float {
            max(0, min(1, channel + surface - original))
        }
        return Color.Resolved(red: shifted(chosen.red, surface.red, canvas.red),
                              green: shifted(chosen.green, surface.green, canvas.green),
                              blue: shifted(chosen.blue, surface.blue, canvas.blue))
    }

    /// A fixed color as SwiftUI resolves it, which does not depend on the environment.
    static func resolvedFixed(_ color: NSColor) -> Color.Resolved {
        Color(nsColor: color).resolve(in: EnvironmentValues())
    }

    /// The native surfaces other than review, resolved once for each mode as their adaptive colors resolve,
    /// which can differ from the fixed color they pick in the last bit.
    private static let fixed: [ThemeMode: [ThemeSurface: Color.Resolved]] = Dictionary(
        uniqueKeysWithValues: ThemeMode.allCases.map { mode in
            var environment = EnvironmentValues()
            environment.colorScheme = mode.scheme
            return (mode, Dictionary(uniqueKeysWithValues: allCases.filter { $0 != .review }.map {
                ($0, $0.original.resolve(in: environment))
            }))
        })
}

/// A window, task hosting or reply hosting reapplies the same inherited text design and color.
struct MacThemeContent: ViewModifier {
    let theme: MacColorTheme
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .foregroundColor(theme[ThemeMode(scheme)].text?.color)
            .fontDesign(theme.font.design)
            .environment(\.yardletColorTheme, theme)
    }
}
