import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The theme's accent roles and surfaces (`ThemeResolution`) come out as AppKit resolves the colors they
/// are made of, and are worked out once for each theme and appearance.
final class ThemeResolutionTests: XCTestCase {
    func testThemeBytesResolveAsSwiftUIResolvesTheirColor() {
        var environment = EnvironmentValues()
        for value in 0...255 {
            let rgb = ThemeRGB(red: UInt8(value), green: UInt8(255 - value), blue: UInt8(value * 7 % 256))
            XCTAssertEqual(rgb.resolved, rgb.color.resolve(in: environment), "\(value)")
        }
        environment.colorScheme = .dark
        let rgb = ThemeRGB(red: 0x20, green: 0x24, blue: 0x2D)
        XCTAssertEqual(rgb.resolved, rgb.color.resolve(in: environment))
    }

    /// Each role and surface equals what the colors behind it resolve to through AppKit, under the
    /// default theme, each preset and a person's own colors, in both appearances.
    func testResolutionMatchesTheColorsResolvedThroughAppKit() throws {
        var custom = MacColorTheme(preset: .ink)
        custom.light = ThemeColors(accent: ThemeRGB("#E0E0E0"), background: ThemeRGB("#F3EFE8"), text: ThemeRGB("#222222"))
        custom.dark = ThemeColors(accent: ThemeRGB("#3B82F6"), background: ThemeRGB("#181818"), text: nil)
        var accentOnly = MacColorTheme()
        accentOnly.dark.accent = ThemeRGB("#FFD60A")
        let themes = YardletAccentPreference.allCases.map { MacColorTheme(preset: $0) } + [custom, accentOnly]
        for theme in themes {
            for mode in ThemeMode.allCases {
                var environment = EnvironmentValues()
                environment.colorScheme = mode.scheme
                environment.yardletColorTheme = theme
                try XCTUnwrap(NSAppearance(named: mode == .light ? .aqua : .darkAqua)).performAsCurrentDrawingAppearance {
                    let expected = Self.appKitResolution(theme, mode: mode, in: environment)
                    let label = "\(theme.preset) \(mode)"
                    for (surface, color) in zip(ThemeSurface.allCases, expected.surfaces) {
                        XCTAssertEqual(surface.resolve(in: environment), color, "\(label) \(surface)")
                    }
                    XCTAssertEqual(ParityTheme.accent.resolve(in: environment), expected.accent, label)
                    XCTAssertEqual(ParityTheme.accentText.resolve(in: environment), expected.text, label)
                    XCTAssertEqual(ParityTheme.onAccent.resolve(in: environment), expected.onAccent, label)
                    XCTAssertEqual(ParityTheme.accentButtonFill.resolve(in: environment), expected.buttonFill, label)
                    XCTAssertEqual(ParityTheme.onAccentButton.resolve(in: environment), expected.onButton, label)
                    XCTAssertEqual(ParityTheme.innerRail.resolve(in: environment), expected.innerRail, label)
                    XCTAssertEqual(ParityTheme.userBubbleFill.resolve(in: environment), expected.userBubble, label)
                }
            }
        }
    }

    /// Repeated draws in one appearance reuse a resolution; another theme or color scheme, or a change of
    /// macOS's system colors or accessibility display options, works out a new one.
    func testRepeatedResolutionsReuseOneUntilTheThemeAppearanceOrSystemColorsChange() {
        var theme = MacColorTheme(preset: .nord)
        theme.light.accent = ThemeRGB("#123456")
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        environment.yardletColorTheme = theme
        func made(_ draw: () -> Void) -> Int {
            let before = ThemeResolution.madeCount
            draw()
            return ThemeResolution.madeCount - before
        }
        func drawAll() {
            for _ in 0..<50 {
                _ = ParityTheme.accentText.resolve(in: environment)
                _ = ParityTheme.accent.resolve(in: environment)
                _ = ThemeSurface.review.resolve(in: environment)
                _ = ParityTheme.canvas.resolve(in: environment)
            }
        }
        XCTAssertEqual(made(drawAll), 1)
        XCTAssertEqual(made(drawAll), 0)
        environment.colorScheme = .dark
        XCTAssertEqual(made(drawAll), 1)
        theme.dark.accent = ThemeRGB("#654321")
        environment.yardletColorTheme = theme
        XCTAssertEqual(made(drawAll), 1)
        // The interface font does not change a color.
        theme.font = .serif
        environment.yardletColorTheme = theme
        XCTAssertEqual(made(drawAll), 0)
        NotificationCenter.default.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        XCTAssertEqual(made(drawAll), 1)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        XCTAssertEqual(made(drawAll), 1)
    }

    /// The colors as resolved before `ThemeResolution`, each through AppKit.
    private static func appKitResolution(_ theme: MacColorTheme, mode: ThemeMode, in environment: EnvironmentValues)
        -> (surfaces: [Color.Resolved], accent: Color.Resolved, text: Color.Resolved, onAccent: Color.Resolved,
            buttonFill: Color.Resolved, onButton: Color.Resolved, innerRail: Color.Resolved, userBubble: Color.Resolved) {
        let dark = mode == .dark
        func shifted(_ base: Color.Resolved) -> Color.Resolved {
            guard let background = theme[mode].background else { return base }
            let canvas = ParityTheme.originalCanvas.resolve(in: environment)
            let chosen = background.color.resolve(in: environment)
            func shift(_ channel: Float, _ surface: Float, _ original: Float) -> Float { max(0, min(1, channel + surface - original)) }
            return Color.Resolved(red: shift(chosen.red, base.red, canvas.red), green: shift(chosen.green, base.green, canvas.green),
                                  blue: shift(chosen.blue, base.blue, canvas.blue))
        }
        let originals = [ParityTheme.originalCanvas, ParityTheme.originalSidebar, ParityTheme.originalElevated,
                         ParityTheme.originalInput, Color(nsColor: .textBackgroundColor)]
        let surfaces = originals.map { shifted($0.resolve(in: environment)) }
        let innerRail = shifted(Color(nsColor: dark ? NSColor(srgbRed: 0.078, green: 0.082, blue: 0.094, alpha: 1)
                                                    : NSColor(srgbRed: 0.973, green: 0.973, blue: 0.976, alpha: 1)).resolve(in: environment))
        let userBubble = shifted(Color(nsColor: dark ? NSColor(srgbRed: 0.137, green: 0.145, blue: 0.165, alpha: 1)
                                                     : NSColor(srgbRed: 0.949, green: 0.953, blue: 0.961, alpha: 1)).resolve(in: environment))
        func ratio(_ a: Color.Resolved, _ b: Color.Resolved) -> Float {
            let x = ThemeContrast.luminance(a), y = ThemeContrast.luminance(b)
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        if theme[mode] != ThemeColors() {
            let accent = Color(nsColor: theme.accent(in: mode)).resolve(in: environment)
            let text = surfaces.allSatisfy { ratio(accent, $0) >= 4.5 } ? accent
                : (theme[mode].text?.color ?? .primary).resolve(in: environment)
            let onAccent = (ThemeContrast.luminance(accent) > 0.179 ? Color.black : .white).resolve(in: environment)
            let button = ThemeContrast.accentButtonColors(for: accent, in: environment)
            return (surfaces, accent, text, onAccent, button.fill, button.foreground, innerRail, userBubble)
        }
        let accent = Color(nsColor: ParityTheme.accentColor(for: theme.preset)).resolve(in: environment)
        let text = Color(nsColor: ParityTheme.linkTextColor(for: theme.preset)).resolve(in: environment)
        let onAccent = Color(nsColor: ParityTheme.foregroundOnAccent(for: theme.preset)).resolve(in: environment)
        let button = ThemeContrast.accentButtonColors(for: accent, in: environment)
        return (surfaces, accent, text, onAccent, button.fill, button.foreground, innerRail, userBubble)
    }
}
