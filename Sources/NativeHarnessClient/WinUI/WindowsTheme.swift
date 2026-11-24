import Foundation
import UWP
import WinUI

/// The Mac's colors and measures (`ParityTheme`, Views/ParityDesignSystem.swift) for the Windows app's screens, in
/// light and dark. Each color is one brush that every screen shares: when Windows switches between light and dark, the
/// window's root tells the theme (`follow(_:)`), each brush takes its color for the new appearance, and whatever was
/// drawn with it changes with it. What Windows has its own way of drawing stays Windows': the window's backdrop
/// (Mica), its caption buttons, its font (Segoe UI Variable) and the keyboard focus. These are the colors drawn over it.
@MainActor
enum WindowsTheme {
    // MARK: Measures, as the Mac's

    static let sidebarWidth: Double = 240
    /// The widest the conversation and the composer grow, centered in a wider window.
    static let contentWidth: Double = 768
    /// The conversation's and the composer's gutter.
    static let conversationInset: Double = 32
    static let composerCornerRadius: Double = 14
    static let panelCornerRadius: Double = 12
    static let bodyFontSize: Double = 14
    /// The space between a message's paragraphs, lists and code blocks.
    static let proseBlockSpacing: Double = 15

    // MARK: Colors, as the Mac's

    /// Text, as the Mac's primary label.
    static let text = ThemeColor(light: .ink(0.85), dark: .paper(0.85))
    /// Text that explains or qualifies, as the Mac's secondary label.
    static let secondaryText = ThemeColor(light: .ink(0.50), dark: .paper(0.55))
    /// Text that recedes further, such as times, as the Mac's tertiary label.
    static let tertiaryText = ThemeColor(light: .ink(0.26), dark: .paper(0.25))
    static let separator = ThemeColor(light: .ink(0.095), dark: .paper(0.105))
    static let strongSeparator = ThemeColor(light: .ink(0.16), dark: .paper(0.18))
    static let subtleFill = ThemeColor(light: .ink(0.035), dark: .paper(0.035))
    /// The chosen row's fill.
    static let selectedFill = ThemeColor(light: .ink(0.095), dark: .paper(0.095))
    /// The fill of a row or button under the pointer.
    static let hoverFill = ThemeColor(light: .ink(0.062), dark: .paper(0.062))
    /// Raised surfaces such as cards.
    static let elevated = ThemeColor(light: .gray(1), dark: .rgb(0.153, 0.157, 0.173))
    /// The composer's field.
    static let input = ThemeColor(light: .gray(1), dark: .rgb(0.173, 0.176, 0.192))
    /// A waiting request's panel: the elevated surface shaded slightly darker in light and lighter in dark, so the
    /// docked panel stands apart from the canvas and the composer in both appearances.
    static let requestPanelFill = ThemeColor(light: .rgb(0.955, 0.955, 0.957), dark: .rgb(0.191, 0.195, 0.210))
    /// Crisp tinted surface for sent user message bubbles.
    static let userBubbleFill = ThemeColor(light: .rgb(0.949, 0.953, 0.961), dark: .rgb(0.137, 0.145, 0.165))
    /// A primary action such as Send: dark on light, light on dark.
    static let primaryActionFill = ThemeColor(light: .gray(0.20), dark: .gray(0.88))
    static let primaryActionForeground = ThemeColor(light: .gray(1), dark: .gray(0.12))
    /// Yardlet's softened slate-blue accent, for links and what the Mac draws in its accent.
    static let accent = ThemeColor(light: .rgb(0.16, 0.36, 0.62), dark: .rgb(0.47, 0.65, 0.89))
    /// Softened accent border for a focused composer card.
    static let composerFocusBorder = ThemeColor(light: .rgba(0.16, 0.36, 0.62, 0.32),
                                                dark: .rgba(0.47, 0.65, 0.89, 0.38))

    // MARK: Following Windows' appearance

    fileprivate static var colors: [ThemeColor] = []
    /// Whether the brushes hold their dark colors.
    private(set) static var isDark = false

    /// Gives the brushes the colors of `root`'s appearance now and whenever it changes, as Windows switches between
    /// light and dark or the person changes it in Settings.
    static func follow(_ root: FrameworkElement) {
        root.actualThemeChanged.addHandler { sender, _ in
            guard let sender else { return }
            WindowsTheme.apply(dark: sender.actualTheme == .dark)
        }
        // An element reads its appearance for certain once it is in the window.
        // The root as the event passes it: the Swift wrapper here is gone once the window holds the root.
        root.loaded.addHandler { sender, _ in
            guard let root = sender as? FrameworkElement else { return }
            WindowsTheme.apply(dark: root.actualTheme == .dark)
        }
        apply(dark: root.actualTheme == .dark)
    }

    private static func apply(dark: Bool) {
        isDark = dark
        for color in colors { color.apply(dark: dark) }
        QAEventLog.shared.write("theme: \(dark ? "dark" : "light")")
    }
}

/// One of the theme's colors: a brush whose color is the light or the dark one, as the window's appearance is.
@MainActor
final class ThemeColor {
    let brush: SolidColorBrush
    private let light: UWP.Color
    private let dark: UWP.Color

    init(light: UWP.Color, dark: UWP.Color) {
        self.light = light
        self.dark = dark
        // A color is made when a screen first asks for it, which may be after the window took its appearance.
        brush = SolidColorBrush(WindowsTheme.isDark ? dark : light)
        WindowsTheme.colors.append(self)
    }

    /// The color for the appearance now, for what takes a color rather than a brush, such as the title bar's buttons.
    var color: UWP.Color { WindowsTheme.isDark ? dark : light }

    fileprivate func apply(dark isDark: Bool) {
        brush.color = isDark ? dark : light
    }
}

extension UWP.Color {
    /// Black at `alpha`: the Mac's `Color.primary.opacity(alpha)` on a light window.
    static func ink(_ alpha: Double) -> UWP.Color { UWP.Color(a: byte(alpha), r: 0, g: 0, b: 0) }
    /// White at `alpha`: the Mac's `Color.primary.opacity(alpha)` on a dark window.
    static func paper(_ alpha: Double) -> UWP.Color { UWP.Color(a: byte(alpha), r: 255, g: 255, b: 255) }
    /// An opaque gray, as the Mac's `NSColor(calibratedWhite:)`.
    static func gray(_ white: Double) -> UWP.Color {
        UWP.Color(a: 255, r: byte(white), g: byte(white), b: byte(white))
    }
    static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> UWP.Color {
        UWP.Color(a: 255, r: byte(red), g: byte(green), b: byte(blue))
    }
    static func rgba(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) -> UWP.Color {
        UWP.Color(a: byte(alpha), r: byte(red), g: byte(green), b: byte(blue))
    }

    private static func byte(_ value: Double) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
}
