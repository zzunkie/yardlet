import AppKit
import os
import SwiftUI

/// What the color theme's accent roles and surfaces resolve to in one appearance. `AccentStyle` and
/// `ThemeSurface` draw from it on every redraw of every view that takes the accent or a surface, so it is
/// worked out once for each theme, color scheme and contrast, and kept until macOS changes its system
/// colors (as the accent color set in System Settings) or its accessibility display options.
struct ThemeResolution {
    /// In `ThemeSurface.allCases` order.
    let surfaces: [Color.Resolved]
    let accent: Color.Resolved
    /// The accent, or the theme's text color when the accent is too pale to read as text on every surface.
    let accentText: Color.Resolved
    let onAccent: Color.Resolved
    let accentButtonFill: Color.Resolved
    let onAccentButton: Color.Resolved

    subscript(surface: ThemeSurface) -> Color.Resolved {
        surfaces[ThemeSurface.allCases.firstIndex(of: surface)!]
    }

    init(in environment: EnvironmentValues) {
        let mode = ThemeMode(environment.colorScheme)
        let theme = environment.yardletColorTheme
        surfaces = ThemeSurface.allCases.map { $0.resolveUncached(in: environment) }
        if theme[mode] != ThemeColors() {
            // A person's accent is a fixed color; a preset's and the system's adapt through AppKit.
            let accent = theme[overrides: mode].accent?.resolved
                ?? Color(nsColor: theme.accent(in: mode)).resolve(in: environment)
            self.accent = accent
            accentText = ThemeContrast.accentReadsAsText(accent, over: surfaces) ? accent
                : theme[mode].text?.resolved ?? Color.primary.resolve(in: environment)
            onAccent = (ThemeContrast.luminance(accent) > 0.179 ? Color.black : .white).resolve(in: environment)
            (accentButtonFill, onAccentButton) = ThemeContrast.accentButtonColors(for: accent, in: environment)
        } else {
            let accent = Color(nsColor: ParityTheme.accentColor(for: theme.preset)).resolve(in: environment)
            self.accent = accent
            accentText = Color(nsColor: ParityTheme.linkTextColor(for: theme.preset)).resolve(in: environment)
            onAccent = Color(nsColor: ParityTheme.foregroundOnAccent(for: theme.preset)).resolve(in: environment)
            (accentButtonFill, onAccentButton) = ThemeContrast.accentButtonColors(for: accent, in: environment)
        }
    }

    /// The resolution for `environment`, worked out on first use.
    static func current(in environment: EnvironmentValues) -> ThemeResolution {
        _ = observing
        var theme = environment.yardletColorTheme
        theme.font = .system
        let key = Key(theme: theme, scheme: environment.colorScheme, contrast: environment.colorSchemeContrast)
        let (generation, kept) = cache.withLock { ($0.generation, $0.entries[key]) }
        if let kept { return kept }
        let made = ThemeResolution(in: environment)
        cache.withLock { cache in
            // A resolution begun before the system colors changed is not kept.
            guard cache.generation == generation else { return }
            if cache.entries.count >= capacity { cache.entries.removeAll() }
            cache.entries[key] = made
            cache.made += 1
        }
        return made
    }

    /// Forgets every resolution: the next one reads AppKit's colors again.
    static func invalidate() {
        cache.withLock { cache in
            cache.generation &+= 1
            cache.entries.removeAll()
        }
    }

    /// How many resolutions were worked out and kept, for tests.
    static var madeCount: Int { cache.withLock(\.made) }

    private struct Key: Hashable {
        let theme: MacColorTheme
        let scheme: ColorScheme
        let contrast: ColorSchemeContrast
    }

    private struct Cache {
        var generation: UInt64 = 0
        var entries: [Key: ThemeResolution] = [:]
        var made = 0
    }

    /// A person switches among a few themes and two appearances.
    private static let capacity = 16
    private static let cache = OSAllocatedUnfairLock(initialState: Cache())

    /// The system accent and the system colors behind the review surface and the label color change with
    /// System Settings while the app runs.
    private static let observing: Void = {
        NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: nil) { _ in invalidate() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: nil) { _ in
                invalidate()
            }
    }()
}
