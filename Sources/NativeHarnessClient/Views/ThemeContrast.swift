import AppKit
import SwiftUI

/// The same validation runs before the Appearance page or a settings tool writes anything.
enum ThemeContrast {
    struct Failure: Equatable {
        let mode: ThemeMode
        let pair: String
        let measured: Float
        let required: Float

        var message: String {
            L10n.format("%@ · %@  %.2f:1 (minimum %.2f:1)", mode.title, pair, Double(measured), Double(required))
        }
    }

    static func luminance(_ c: Color.Resolved) -> Float {
        0.2126 * c.linearRed + 0.7152 * c.linearGreen + 0.0722 * c.linearBlue
    }

    private static func ratio(_ a: Color.Resolved, _ b: Color.Resolved) -> Float {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Composite in sRGB before linearizing for WCAG relative luminance.
    private static func over(_ foreground: Color.Resolved, _ background: Color.Resolved, opacity: Float = 1) -> Color.Resolved {
        let alpha = foreground.opacity * opacity
        return Color.Resolved(red: foreground.red * alpha + background.red * (1 - alpha),
                              green: foreground.green * alpha + background.green * (1 - alpha),
                              blue: foreground.blue * alpha + background.blue * (1 - alpha))
    }

    static func readableAccent(_ theme: MacColorTheme, in environment: EnvironmentValues) -> Color.Resolved {
        let mode = ThemeMode(environment.colorScheme)
        let accent = Color(nsColor: theme.accent(in: mode)).resolve(in: environment)
        if accentReadsAsText(accent, in: environment) { return accent }
        return (theme[mode].text?.color ?? .primary).resolve(in: environment)
    }

    private static func accentReadsAsText(_ accent: Color.Resolved, in environment: EnvironmentValues) -> Bool {
        ThemeSurface.allCases.allSatisfy { ratio(accent, $0.resolve(in: environment)) >= 4.5 }
    }

    /// TextKit keeps an adaptive color, so the system accent can change while a message is open.
    static func linkText(_ theme: MacColorTheme) -> NSColor {
        NSColor(name: nil) { appearance in
            let mode: ThemeMode = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
            var environment = EnvironmentValues()
            environment.colorScheme = mode.scheme
            environment.yardletColorTheme = theme
            let accent = theme.accent(in: mode)
            var result = accent
            appearance.performAsCurrentDrawingAppearance {
                if !accentReadsAsText(Color(nsColor: accent).resolve(in: environment), in: environment) {
                    result = theme[mode].text?.nsColor ?? .labelColor
                }
            }
            return result
        }
    }

    /// Adjusts a tinted text color toward the theme's label color only as much as needed to reach 4.5:1
    /// contrast over `background`, preserving hue across all color presets.
    static func readableTint(_ color: Color, over background: Color.Resolved,
                             in environment: EnvironmentValues, minimum: Float = 4.5) -> Color {
        let base = color.resolve(in: environment)
        if ratio(base, background) >= minimum { return color }
        let mode = ThemeMode(environment.colorScheme)
        let target = (environment.yardletColorTheme[mode].text?.color ?? .primary).resolve(in: environment)
        var low: Float = 0
        var high: Float = 1
        var best = target
        for _ in 0..<8 {
            let mid = (low + high) * 0.5
            let mixed = Color.Resolved(
                red: base.red * (1 - mid) + target.red * mid,
                green: base.green * (1 - mid) + target.green * mid,
                blue: base.blue * (1 - mid) + target.blue * mid,
                opacity: 1
            )
            if ratio(mixed, background) >= minimum {
                best = mixed
                high = mid
            } else {
                low = mid
            }
        }
        return Color(red: Double(best.red), green: Double(best.green), blue: Double(best.blue))
    }

    /// Resolves a filled accent button's background and foreground so saturated mid-luminance accents
    /// (such as macOS's default blue, luminance ~0.21) darken slightly to pair with crisp white labels
    /// at >= 4.5:1 instead of falling back to black text on bright blue, while light accents keep black text.
    static func accentButtonColors(for accent: Color.Resolved,
                                   in environment: EnvironmentValues) -> (fill: Color.Resolved, foreground: Color.Resolved) {
        let white = Color.white.resolve(in: environment)
        let black = Color.black.resolve(in: environment)
        let lum = luminance(accent)
        if lum <= 0.179 { return (accent, white) }
        if lum >= 0.30 { return (accent, black) }
        var low: Float = 0
        var high: Float = 1
        var best = black
        for _ in 0..<8 {
            let mid = (low + high) * 0.5
            let factor = 1 - mid
            let darkened = Color.Resolved(
                red: accent.red * factor,
                green: accent.green * factor,
                blue: accent.blue * factor,
                opacity: 1
            )
            if ratio(darkened, white) >= 4.5 {
                best = darkened
                high = mid
            } else {
                low = mid
            }
        }
        return (best, white)
    }

    static func failures(for theme: MacColorTheme) -> [Failure] {
        ThemeMode.allCases.flatMap { mode -> [Failure] in
            var result: [Failure] = []
            NSAppearance(named: mode == .light ? .aqua : .darkAqua)?.performAsCurrentDrawingAppearance {
                var environment = EnvironmentValues()
                environment.colorScheme = mode.scheme
                environment.yardletColorTheme = theme
                var original = environment
                original.yardletColorTheme = MacColorTheme()
                let colors = theme[mode]
                let accent = Color(nsColor: theme.accent(in: mode)).resolve(in: environment)
                let text = (colors.text?.color ?? .primary).resolve(in: environment)
                let sidebar = ThemeSurface.sidebar.resolve(in: environment)
                let surfaces = ThemeSurface.allCases.map { $0.resolve(in: environment) } + [
                    over(ParityTheme.hoverFill.resolve(in: environment), sidebar),
                    over(ParityTheme.selectedFill.resolve(in: environment), sidebar),
                    over(ParityTheme.selectedFill.resolve(in: environment), ThemeSurface.canvas.resolve(in: environment))
                ]
                func check(_ pair: String, _ actual: Float, _ floor: Float) {
                    guard actual + 0.00001 < floor else { return }
                    result.append(Failure(mode: mode, pair: pair, measured: actual, required: floor))
                }
                check(L10n.string("Text / background"), surfaces.map { ratio(over(text, $0), $0) }.min()!, 4.5)
                check(L10n.string("Accent / background"), surfaces.map { ratio(accent, $0) }.min()!, 3)
                let canvas = ThemeSurface.canvas.resolve(in: environment)
                let nativeCanvas = ThemeSurface.canvas.resolve(in: original)
                for (label, color) in [(L10n.string("Waiting line / background"), Color.orange),
                                       (L10n.string("Error / background"), Color.red)] {
                    let signal = color.resolve(in: environment)
                    check(label, ratio(signal, canvas), min(3, ratio(signal, nativeCanvas)))
                }
                for (label, color) in [(L10n.string("Diff addition / background"), Color.green),
                                       (L10n.string("Diff removal / background"), Color.red)] {
                    let signal = color.resolve(in: environment)
                    func rows(_ env: EnvironmentValues, accent: Color.Resolved) -> [Color.Resolved] {
                        let review = ThemeSurface.review.resolve(in: env)
                        let card = over(ParityTheme.subtleFill.resolve(in: env), ThemeSurface.canvas.resolve(in: env))
                        return [
                            over(signal, review, opacity: Float(DiffFileContent.lineTintOpacity)),
                            over(signal, over(accent, review, opacity: Float(DiffFileContent.selectionOpacity)),
                                 opacity: Float(DiffFileContent.lineTintOpacity)),
                            over(signal, card, opacity: Float(CodexDiffPreviewLines.lineTintOpacity))
                        ]
                    }
                    let nativeAccent = Color(nsColor: ParityTheme.accentColor(for: theme.preset)).resolve(in: original)
                    // Each row is compared with the same row on its default background.
                    let comparisons = zip(rows(environment, accent: accent), rows(original, accent: nativeAccent)).map {
                        (actual: ratio(signal, $0.0), floor: min(3, ratio(signal, $0.1)))
                    }
                    if let worst = comparisons.min(by: { $0.actual / $0.floor < $1.actual / $1.floor }) {
                        check(label, worst.actual, worst.floor)
                    }
                }
            }
            return result
        }
    }
}
