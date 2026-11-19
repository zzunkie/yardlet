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

    subscript(mode: ThemeMode) -> ThemeColors {
        get { mode == .light ? light : dark }
        set { if mode == .light { light = newValue } else { dark = newValue } }
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
        }
    }

    mutating func usePreset(_ newValue: YardletAccentPreference) {
        preset = newValue
        light.accent = nil
        dark.accent = nil
    }

    func accent(in mode: ThemeMode) -> NSColor {
        self[mode].accent?.nsColor ?? ParityTheme.accentColor(for: preset)
    }
}

extension EnvironmentValues {
    @Entry var yardletColorTheme = MacColorTheme()
}

enum ThemeSurface: Hashable, CaseIterable, ShapeStyle {
    case canvas, sidebar, elevated, input, review
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
        let base = original.resolve(in: environment)
        guard let background = environment.yardletColorTheme[ThemeMode(environment.colorScheme)].background else { return base }
        let canvas = ParityTheme.originalCanvas.resolve(in: environment)
        let chosen = background.color.resolve(in: environment)
        // Keep the brightness steps between the native surfaces, including the raised composer.
        func shifted(_ channel: Float, _ surface: Float, _ original: Float) -> Float {
            max(0, min(1, channel + surface - original))
        }
        return Color.Resolved(red: shifted(chosen.red, base.red, canvas.red),
                              green: shifted(chosen.green, base.green, canvas.green),
                              blue: shifted(chosen.blue, base.blue, canvas.blue))
    }
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
