import AppKit
@testable import NativeHarnessClient

/// Small, dependency-free WCAG contrast helper used by the native token tests.
/// It deliberately audits only fixed semantic tokens; dynamic system text colors and
/// provider-owned surfaces still belong to the host/runtime acceptance matrix.
enum ParityContrast {
    static let textContrastFloor = 4.5

    static let lightAccent = NSColor(calibratedRed: 0.08, green: 0.23, blue: 0.42, alpha: 1)
    static let darkAccent = NSColor(calibratedRed: 0.55, green: 0.72, blue: 0.98, alpha: 1)
    static let lightCanvas = NSColor(calibratedWhite: 0.995, alpha: 1)
    static let darkCanvas = NSColor(calibratedWhite: 0.075, alpha: 1)

    static func ratio(foreground: NSColor, background: NSColor) -> Double {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func passesTextContrast(foreground: NSColor, background: NSColor) -> Bool {
        ratio(foreground: foreground, background: background) >= textContrastFloor
    }

    private static func relativeLuminance(_ color: NSColor) -> Double {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let channels = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
            .map { channel -> Double in
                let value = Double(channel)
                return value <= 0.03928
                    ? value / 12.92
                    : pow((value + 0.055) / 1.055, 2.4)
            }
        return (0.2126 * channels[0]) + (0.7152 * channels[1]) + (0.0722 * channels[2])
    }
}
