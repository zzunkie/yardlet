import AppKit
import SwiftUI

enum YardletAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: L10n.string("System")
        case .light: L10n.string("Light")
        case .dark: L10n.string("Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum YardletInterfaceSizePreference: String, CaseIterable, Identifiable {
    case compact
    case standard
    case large

    var id: Self { self }

    var title: String {
        switch self {
        case .compact: L10n.string("Compact")
        case .standard: L10n.string("Default")
        case .large: L10n.string("Large")
        }
    }

    var scale: CGFloat {
        switch self {
        case .compact: 0.94
        case .standard: 1
        case .large: 1.08
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .compact: .medium
        case .standard: .large
        case .large: .xLarge
        }
    }
}

enum YardletPreferenceKeys {
    static let appearance = "Yardlet.appearance"
    static let interfaceSize = "Yardlet.interfaceSize"
}

private struct YardletInterfaceScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var yardletInterfaceScale: CGFloat {
        get { self[YardletInterfaceScaleKey.self] }
        set { self[YardletInterfaceScaleKey.self] = newValue }
    }
}

enum ParityTheme {
    static let proseLineSpacing: CGFloat = 5
    static let proseBlockSpacing: CGFloat = 15

    static let sidebarWidth: CGFloat = 240
    static let titleBarHeight: CGFloat = 50
    static let toolbarHeight: CGFloat = 46
    static let paneToolbarHeight: CGFloat = 40
    static let contentWidth: CGFloat = 768
    /// Claude Code's composer corner (`--cds-radius-composer`, 2026-10-15 user decision).
    static let composerCornerRadius: CGFloat = 12
    static let panelCornerRadius: CGFloat = 12
    /// Claude Code's conversation gutter (`--chat-gutter`), also the composer's.
    static let conversationInset: CGFloat = 32
    static func conversationFont(scale: CGFloat) -> Font {
        .system(size: 14 * scale)
    }

    static let accent = Color(nsColor: accentColor)
    /// `accent` for AppKit drawing, such as a message's links.
    static let accentColor = NSColor(name: "YardletAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.55, green: 0.72, blue: 0.98, alpha: 1)
            : NSColor(calibratedRed: 0.08, green: 0.23, blue: 0.42, alpha: 1)
    }
    static let signal = Color(nsColor: NSColor(name: "YardletSignal") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.82, green: 0.93, blue: 0.17, alpha: 1)
            : NSColor(calibratedRed: 0.42, green: 0.52, blue: 0.02, alpha: 1)
    })

    static let canvas = Color(nsColor: NSColor(name: "YardletCanvas") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.075, alpha: 1)
            : NSColor(calibratedWhite: 0.995, alpha: 1)
    })
    static let sidebar = Color(nsColor: NSColor(name: "YardletSidebar") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.105, alpha: 1)
            : NSColor(calibratedWhite: 0.965, alpha: 1)
    })
    static let elevated = Color(nsColor: NSColor(name: "YardletElevated") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.135, alpha: 1)
            : .white
    })
    static let input = Color(nsColor: NSColor(name: "YardletInput") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.155, alpha: 1)
            : .white
    })
    static let separator = Color.primary.opacity(0.10)
    static let strongSeparator = Color.primary.opacity(0.12)
    static let subtleFill = Color.primary.opacity(0.035)
    static let selectedFill = Color.primary.opacity(0.095)
    static let hoverFill = Color.primary.opacity(0.065)
    static let primaryActionFill = Color(nsColor: NSColor(name: "YardletPrimaryActionFill") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.88, alpha: 1)
            : NSColor(calibratedWhite: 0.20, alpha: 1)
    })
    static let primaryActionForeground = Color(nsColor: NSColor(name: "YardletPrimaryActionForeground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.12, alpha: 1)
            : .white
    })
}

enum ParityMotion {
    static func easeInOut(reduceMotion: Bool, duration: TimeInterval = 0.16) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: duration)
    }

    static func easeOut(reduceMotion: Bool, duration: TimeInterval = 0.15) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }
}

@MainActor
enum ParityInteraction {
    static var currentEventIsKeyboard: Bool {
        NSApp.currentEvent?.type == .keyDown
    }

    static var currentEventIsFocusInteraction: Bool {
        guard let type = NSApp.currentEvent?.type else { return false }
        switch type {
        case .keyDown, .keyUp, .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: return true
        default: return false
        }
    }
}

/// Stable VoiceOver traversal bands for the shared shell. Higher values are announced first;
/// keeping the bands in one place prevents a harness-specific surface from accidentally moving
/// ahead of the task identity or primary action when the shell is rearranged.
enum ParityAccessibility {
    static let titleBar = 100.0
    static let sidebarPrimary = 90.0
    static let surfacePicker = 80.0
    static let mainContent = 70.0
    static let composer = 60.0
    static let secondary = 40.0
}

struct YardletBrandMark: View {
    var size: CGFloat = 30

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ParityComposerControl: View {
    let title: String
    /// Dimmer words after the title ("High" after "Opus 5.5"), after a middle dot.
    var detail: String? = nil
    var systemName: String?
    var showsChevron = false
    var tint: Color = .secondary
    var isActive = false
    var isInteractive = true

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 5) {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 11.5 * interfaceScale, weight: .medium))
            }
            label
                .font(.system(size: 13 * interfaceScale, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: detail == nil ? 138 : 196)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(isActive ? Color.primary : tint)
        .padding(.horizontal, 7)
        // Claude Code's control (`--cds-h-control` 24 pt, `--cds-radius` 6 pt).
        .frame(height: 24 * interfaceScale)
        .background(
            isActive
                ? ParityTheme.selectedFill
                : (isInteractive && isHovering ? ParityTheme.hoverFill : .clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .animation(ParityMotion.easeOut(reduceMotion: reduceMotion, duration: 0.1), value: isHovering)
        .onHover { hovering in
            isHovering = isInteractive && hovering
        }
    }

    private var label: Text {
        guard let detail else { return Text(title) }
        return Text(title) + Text(" · \(detail)").foregroundStyle(.tertiary)
    }
}

struct ParityIconButton: View {
    let systemName: String
    let help: String
    var isProminent = false
    /// The menu bar's key for the same action, which the tooltip shows after `help` (`ShortcutHelp`).
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            if isProminent {
                // The primary action (send) is Claude Code's rounded square, in Yardlet's colors.
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ParityTheme.primaryActionForeground)
                    .frame(width: 28, height: 28)
                    .background(ParityTheme.primaryActionFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.primary)
                    .background {
                        Circle().fill(isHovering ? ParityTheme.hoverFill : .clear)
                    }
            }
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .accessibilityLabel(help)
        .help(ShortcutHelp.text(help, shortcut))
        .onHover { isHovering = $0 }
        .animation(ParityMotion.easeOut(reduceMotion: reduceMotion, duration: 0.1), value: isHovering)
    }
}

struct ParityPillLabel: View {
    let title: String
    let systemName: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(ParityTheme.subtleFill, in: Capsule())
        .overlay {
            Capsule().stroke(ParityTheme.separator)
        }
    }
}

struct ParitySectionTitle: View {
    let title: String
    var trailingAction: (() -> Void)?
    var trailingLabel = L10n.string("New task")

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailingAction {
                Button(action: trailingAction) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .help(trailingLabel)
                .accessibilityLabel(trailingLabel)
            }
        }
    }
}

/// The caret of a line that opens and folds, the same everywhere one sits beside words (status lines,
/// the turn header, the live line, a project's label, a details block): `chevron.right`, and
/// `chevron.down` when open, in one square box, set on the words' middle
/// (`centeredOnCapHeight`) when the row aligns by baseline.
struct DisclosureCaret: View {
    let isOpen: Bool
    var size: CGFloat = 8
    var weight: Font.Weight = .bold

    var body: some View {
        // Each glyph centred in the same box: `chevron.right` turned a quarter sits a little off
        // the middle its folded self keeps, as its drawing is not centred in its bounds.
        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
            .font(.system(size: size, weight: weight))
            .frame(width: size * 1.25, height: size * 1.25)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Sets the view's middle on the middle of the capitals of system text of `textSize` in a row
    /// aligned by `.firstTextBaseline`. A symbol smaller than the words, a spinner or an icon tile
    /// otherwise rests on the baseline or by its own small baseline and sits low or high.
    func centeredOnCapHeight(ofTextSize textSize: CGFloat) -> some View {
        let half = NSFont.systemFont(ofSize: textSize).capHeight / 2
        return alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + half }
    }
}

extension View {
    /// Show the pointing hand for Yardlet-owned click targets styled without native button chrome.
    func parityPointer() -> some View {
        modifier(ParityPointerModifier())
    }

    /// A prominent button in Yardlet's accent. The shell tints its controls `Color.primary`
    /// (`MainWindow`), and a `.borderedProminent` button left with that tint fills with the label
    /// color and draws its title dark too: black on black in light mode (2026-10-16, the question
    /// card's Submit). Every prominent button opts into the accent here instead.
    func parityProminentButton() -> some View {
        buttonStyle(.borderedProminent).tint(ParityTheme.accent)
    }

    func parityCard(cornerRadius: CGFloat = ParityTheme.panelCornerRadius) -> some View {
        background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(ParityTheme.separator)
            }
    }
}

extension ToggleStyle where Self == ParitySwitchToggleStyle {
    /// The switch both apps draw: Yardlet's accent when on, a faint track when off (the Claude app's
    /// `fill-accent`/`alpha-2`, Codex's `bg-chart-blue`/`bg-text/10`).
    static var paritySwitch: ParitySwitchToggleStyle { ParitySwitchToggleStyle() }
}

/// AppKit's switch takes its colour from the tint and from whether the window is key: under the
/// shell's monochrome tint it drew on and off in nearly the same gray, and gray again in a popover
/// or an inactive window (2026-10-22). This one is drawn the same in every window. The label, when
/// shown, sits before it as AppKit's does; the accessibility tree is a switch with the label.
struct ParitySwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ParitySwitch(configuration: configuration)
    }
}

private struct ParitySwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.controlSize) private var controlSize
    @Environment(\.labelsVisibility) private var labelsVisibility
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// AppKit's switch sizes: mini 26×15, small 32×18, regular 38×22.
    private var size: CGSize {
        switch controlSize {
        case .mini: CGSize(width: 26, height: 15)
        case .small: CGSize(width: 32, height: 18)
        default: CGSize(width: 38, height: 22)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if labelsVisibility != .hidden {
                configuration.label
            }
            Button {
                configuration.isOn.toggle()
            } label: {
                track
            }
            .buttonStyle(.plain)
            .parityPointer()
        }
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    private var track: some View {
        let knob = size.height - 4
        return Capsule()
            .fill(configuration.isOn ? AnyShapeStyle(ParityTheme.accent) : AnyShapeStyle(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.11)))
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    .frame(width: knob, height: knob)
                    .padding(2)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Capsule())
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.8), value: configuration.isOn)
    }
}

private struct ParityPointerModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        // Declared, not set: AppKit shows the hand through the hosting view's cursor rects when the
        // pointer enters. Setting `NSCursor` for every hover event drew the cursor image anew on
        // each pointer move, a tenth of the main thread's busy time while the pointer moved
        // (2026-10-22, installed app sampled), and gave every target a hover responder.
        content.pointerStyle(isEnabled ? .link : nil)
    }
}

private final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            window.zoom(nil)
        } else {
            window.performDrag(with: event)
        }
    }
}

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
