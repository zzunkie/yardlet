import AppKit
import SwiftUI

extension YardletAppearancePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension YardletInterfaceSizePreference {
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

extension Font {
    /// `style` at the interface size and zoom (`yardletInterfaceScale`). macOS draws a text style at one size whatever
    /// `dynamicTypeSize` says, so a view that scales its text takes the style's own font at its size times `scale`,
    /// which draws as the style does, with its weight and line height; at 1 it is the style itself.
    static func yardlet(_ style: Font.TextStyle, scale: CGFloat) -> Font {
        guard scale != 1 else { return .system(style) }
        let font = NSFont.preferredFont(forTextStyle: style.appKitStyle)
        return Font(font.withSize(font.pointSize * scale))
    }
}

/// The type roles of Yardlet's chrome (docs/DESIGN_SYSTEM.md, "Tokens"), in points at the standard interface size.
/// A role says what the words are, not how big they happen to be: an 8 pt disclosure glyph is an icon, not a caption.
/// Code keeps the code font (`yardletCodeFont`) and native controls keep their system size.
enum ParityType: CaseIterable {
    /// A secondary line, metadata, a hint: 12 pt.
    case caption
    /// A control's label, a row's title, a card's own words: 13 pt.
    case control
    /// Reading text, as the conversation's prose and a question's headline: 14 pt.
    case body
    /// A page's or a section's heading: 18 pt semibold.
    case section
    /// A surface's title: 24 pt semibold.
    case title

    var size: CGFloat {
        switch self {
        case .caption: 12
        case .control: 13
        case .body: 14
        case .section: 18
        case .title: 24
        }
    }

    var weight: Font.Weight {
        switch self {
        case .caption, .control, .body: .regular
        case .section, .title: .semibold
        }
    }
}

extension Font {
    /// `type` at `scale`, in its own weight or in `weight`. A view that follows the interface size and View › Zoom
    /// passes `yardletInterfaceScale`, which already holds the zoom, so the size is scaled once; one that keeps its
    /// size, as Settings does, passes 1.
    static func parity(_ type: ParityType, weight: Font.Weight? = nil, scale: CGFloat) -> Font {
        .system(size: type.size * scale, weight: weight ?? type.weight)
    }
}

/// The spacing scale (docs/DESIGN_SYSTEM.md, "Tokens"): the paddings and gaps of chrome, in points, not scaled by the
/// interface size. A 1 pt rule and a 2 pt optical adjustment are not on it; neither is a window's or a component's
/// own geometry (`ParityTheme`).
enum ParitySpace {
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
    static let s48: CGFloat = 48
}

/// The corner radii (docs/DESIGN_SYSTEM.md, "Tokens"). Circles and capsules are shapes, not radii, and a native
/// menu keeps the system's corners.
enum ParityRadius {
    /// A small control: a chip, a field, a key.
    static let control: CGFloat = 6
    /// A row, an option, an attachment, a code or preview box.
    static let row: CGFloat = 8
    /// A panel, a popover, a sheet.
    static let surface: CGFloat = 12
    /// The composer container: 14 pt outer with 8 pt inner padding nests 6 pt inner controls (`14 - 8 = 6`).
    static let composer: CGFloat = 14
}

private extension Font.TextStyle {
    var appKitStyle: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
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

extension EnvironmentValues {
    var yardletAccent: YardletAccentPreference {
        get { yardletColorTheme.preset }
        set { yardletColorTheme.preset = newValue }
    }
}

private struct AccentStyle: ShapeStyle, Hashable {
    enum Role { case accent, text, onAccent, buttonFill, onButtonFill }
    var role: Role = .accent

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let mode = ThemeMode(environment.colorScheme)
        let theme = environment.yardletColorTheme
        if theme[mode] != ThemeColors() {
            let accent = Color(nsColor: theme.accent(in: mode)).resolve(in: environment)
            switch role {
            case .accent: return accent
            case .text:
                return ThemeContrast.readableAccent(theme, in: environment)
            case .onAccent:
                return (ThemeContrast.luminance(accent) > 0.179 ? Color.black : .white).resolve(in: environment)
            case .buttonFill:
                return ThemeContrast.accentButtonColors(for: accent, in: environment).fill
            case .onButtonFill:
                return ThemeContrast.accentButtonColors(for: accent, in: environment).foreground
            }
        }
        switch role {
        case .accent:
            return Color(nsColor: ParityTheme.accentColor(for: environment.yardletAccent)).resolve(in: environment)
        case .text:
            return Color(nsColor: ParityTheme.linkTextColor(for: environment.yardletAccent)).resolve(in: environment)
        case .onAccent:
            return Color(nsColor: ParityTheme.foregroundOnAccent(for: environment.yardletAccent)).resolve(in: environment)
        case .buttonFill:
            let accent = Color(nsColor: ParityTheme.accentColor(for: environment.yardletAccent)).resolve(in: environment)
            return ThemeContrast.accentButtonColors(for: accent, in: environment).fill
        case .onButtonFill:
            let accent = Color(nsColor: ParityTheme.accentColor(for: environment.yardletAccent)).resolve(in: environment)
            return ThemeContrast.accentButtonColors(for: accent, in: environment).foreground
        }
    }
}

/// Each color stays adaptive, including the system accent when the person changes it in macOS.
private struct AccentPalette {
    let accent: NSColor
    let text: NSColor
    let onAccent: NSColor

    init(_ accent: NSColor) {
        self.accent = accent
        text = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var environment = EnvironmentValues()
            environment.colorScheme = dark ? .dark : .light
            // Sidebar in light mode and input in dark mode bound the plain surfaces.
            let surface = dark ? ParityTheme.input : ParityTheme.sidebar
            var readable = false
            appearance.performAsCurrentDrawingAppearance {
                let foreground = Self.luminance(Color(nsColor: accent).resolve(in: environment))
                let background = Self.luminance(surface.resolve(in: environment))
                readable = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05) >= 4.5
            }
            return readable ? accent : .labelColor
        }
        onAccent = NSColor(name: nil) { appearance in
            var black = false
            appearance.performAsCurrentDrawingAppearance {
                var environment = EnvironmentValues()
                environment.colorScheme = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
                black = Self.luminance(Color(nsColor: accent).resolve(in: environment)) > 0.179
            }
            return black ? .black : .white
        }
    }

    private static func luminance(_ color: Color.Resolved) -> Float {
        0.2126 * color.linearRed + 0.7152 * color.linearGreen + 0.0722 * color.linearBlue
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
    /// Composer corner radius (`ParityRadius.composer`, 14 pt) nesting 6 pt controls inside 8 pt padding.
    static let composerCornerRadius = ParityRadius.composer
    static let panelCornerRadius = ParityRadius.surface
    /// Claude Code's conversation gutter (`--chat-gutter`), also the composer's.
    static let conversationInset = ParitySpace.s32
    static func conversationFont(scale: CGFloat) -> Font {
        .parity(.body, scale: scale)
    }

    static let accent = Color(AccentStyle())
    /// Link text keeps the label color when this accent is too pale for text.
    static let accentText = Color(AccentStyle(role: .text))
    static let onAccent = Color(AccentStyle(role: .onAccent))
    static let accentButtonFill = Color(AccentStyle(role: .buttonFill))
    static let onAccentButton = Color(AccentStyle(role: .onButtonFill))

    /// AppKit and SwiftUI take their accent from the same adaptive color.
    static func accentColor(for preference: YardletAccentPreference) -> NSColor {
        palette(for: preference).accent
    }

    static func linkTextColor(for preference: YardletAccentPreference) -> NSColor {
        palette(for: preference).text
    }

    fileprivate static func foregroundOnAccent(for preference: YardletAccentPreference) -> NSColor {
        palette(for: preference).onAccent
    }

    private static let system = AccentPalette(.controlAccentColor)

    private static let palettes: [YardletAccentPreference: AccentPalette] = {
        var palettes: [YardletAccentPreference: AccentPalette] = [:]
        for preset in YardletAccentPreference.allCases {
            guard let light = preset.colors(in: .light).accent?.nsColor,
                  let dark = preset.colors(in: .dark).accent?.nsColor else { continue }
            palettes[preset] = AccentPalette(NSColor(name: "YardletAccent" + preset.rawValue.capitalized) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
        }
        return palettes
    }()

    private static func palette(for preference: YardletAccentPreference) -> AccentPalette {
        palettes[preference] ?? system
    }

    static let signal = Color(nsColor: NSColor(name: "YardletSignal") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.82, green: 0.93, blue: 0.17, alpha: 1)
            : NSColor(calibratedRed: 0.42, green: 0.52, blue: 0.02, alpha: 1)
    })

    static let canvas = Color(ThemeSurface.canvas)
    static let originalCanvas = Color(nsColor: NSColor(name: "YardletCanvas") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.098, green: 0.102, blue: 0.118, alpha: 1) // #191A1E
            : NSColor(srgbRed: 0.980, green: 0.980, blue: 0.984, alpha: 1) // #FAFAFB
    })
    static let sidebar = Color(ThemeSurface.sidebar)
    static let originalSidebar = Color(nsColor: NSColor(name: "YardletSidebar") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.125, green: 0.133, blue: 0.157, alpha: 1) // #202228
            : NSColor(srgbRed: 0.953, green: 0.957, blue: 0.965, alpha: 1) // #F3F4F6
    })
    static let elevated = Color(ThemeSurface.elevated)
    static let originalElevated = Color(nsColor: NSColor(name: "YardletElevated") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.149, green: 0.157, blue: 0.188, alpha: 1) // #262830
            : .white
    })
    static let input = Color(ThemeSurface.input)
    static let originalInput = Color(nsColor: NSColor(name: "YardletInput") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.169, green: 0.180, blue: 0.216, alpha: 1) // #2B2E37
            : .white
    })
    static let separator = Color.primary.opacity(0.09)
    static let strongSeparator = Color.primary.opacity(0.16)
    static let darkTopHighlight = Color.white.opacity(0.08)
    static let subtleFill = Color.primary.opacity(0.035)
    static let selectedFill = Color.primary.opacity(0.095)
    static let hoverFill = Color.primary.opacity(0.065)
    /// The shade a waiting request's panel lays over the elevated surface (`ConversationRequestPanel`), so the
    /// panel stands apart from the canvas and the composer in both appearances.
    static let requestPanelFill = Color.primary.opacity(0.045)
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

struct ParityComposerControl: View {
    let title: String
    /// Dimmer words after the title ("High" after "Opus 5.5"), after a middle dot. A row too narrow
    /// for both drops them before it shortens the title, as the Codex app's composer drops the
    /// reasoning effort after the model; what is left then shortens, as both apps' labels do.
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
            ViewThatFits(in: .horizontal) {
                ParityLabelWidth(limit: detail == nil ? 138 : 196) { styled(label) }
                if detail != nil {
                    // Shortened from its end, as both apps shorten a model's name.
                    ParityLabelWidth(limit: 138) { styled(Text(title), truncation: .tail) }
                }
            }
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
            in: RoundedRectangle(cornerRadius: ParityRadius.control)
        )
        .contentShape(RoundedRectangle(cornerRadius: ParityRadius.control))
        .animation(ParityMotion.easeOut(reduceMotion: reduceMotion, duration: 0.1), value: isHovering)
        .onHover { hovering in
            isHovering = isInteractive && hovering
        }
    }

    private var label: Text {
        guard let detail else { return Text(title) }
        return Text(title) + Text(" · \(detail)").foregroundStyle(.tertiary)
    }

    private func styled(_ text: Text, truncation: Text.TruncationMode = .middle) -> some View {
        text
            .font(.parity(.control, weight: .medium, scale: interfaceScale))
            .lineLimit(1)
            .truncationMode(truncation)
    }
}

/// A control's words, no wider than `limit` and no wider than they are. `frame(maxWidth:)` would
/// grow to whatever it is offered up to the limit, spreading a short title away from its icon and
/// chevron in a row that offers more, such as the session rail's Settings card.
private struct ParityLabelWidth: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let label = subviews.first else { return .zero }
        let width = min(label.sizeThatFits(.unspecified).width, limit, proposal.width ?? .infinity)
        let size = label.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: max(width, size.width), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: ProposedViewSize(bounds.size))
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
    /// A borderless button draws its label as given, so a disabled one dims here: send on an empty
    /// draft, Back with no history.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            if isProminent {
                // Primary send action uses the active theme accent when enabled and dims quietly when empty.
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isEnabled ? AnyShapeStyle(ParityTheme.onAccentButton) : AnyShapeStyle(.tertiary))
                    .frame(width: 28, height: 28)
                    .background(
                        isEnabled ? AnyShapeStyle(ParityTheme.accentButtonFill) : AnyShapeStyle(ParityTheme.subtleFill),
                        in: RoundedRectangle(cornerRadius: ParityRadius.control, style: .continuous)
                    )
                    .opacity(isEnabled && isHovering ? 0.9 : 1)
                    .contentShape(RoundedRectangle(cornerRadius: ParityRadius.control, style: .continuous))
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .background {
                        Circle().fill(isHovering && isEnabled ? ParityTheme.hoverFill : .clear)
                    }
                    // The whole circle takes the click, not only the symbol's strokes.
                    .contentShape(Circle())
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

struct ParitySectionTitle: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let title: String
    var trailingAction: (() -> Void)?
    var trailingLabel = L10n.string("New task")

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.yardlet(.caption, scale: interfaceScale).weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailingAction {
                Button(action: trailingAction) {
                    Image(systemName: "plus")
                        .font(.yardlet(.caption, scale: interfaceScale).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
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

    /// A link keeps the native button behavior and follows the same accent as prose links.
    func parityLinkButton() -> some View {
        buttonStyle(.link).tint(ParityTheme.accentText)
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
    var onPress: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    /// A press with its own meaning counts in a window that is not active yet, as a button's does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onPress != nil }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onPress?()
        if event.clickCount == 2 {
            window.zoom(nil)
        } else {
            window.performDrag(with: event)
        }
    }
}

struct WindowDragRegion: NSViewRepresentable {
    /// What a press does besides moving the window: the region takes the press from the views around it.
    var onPress: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = WindowDragNSView()
        view.onPress = onPress
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowDragNSView)?.onPress = onPress
    }
}

/// Crisp elevated surface treatment: dual-layer soft shadow in light mode and a 1 pt top-edge specular
/// highlight in dark mode, with stronger hairline contrast when macOS Increase Contrast is enabled.
private struct ParitySurfaceElevation: ViewModifier {
    let cornerRadius: CGFloat
    var isFocused: Bool = false
    var accentBorder: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .overlay {
                if colorScheme == .dark, !accentBorder {
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [ParityTheme.darkTopHighlight, .clear],
                                startPoint: .top,
                                endPoint: UnitPoint(x: 0.5, y: 0.22)
                            ),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                shape
                    .strokeBorder(borderColor, lineWidth: contrast == .increased ? 1.25 : 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: colorScheme == .light ? .black.opacity(0.035) : .clear, radius: 1, y: 1)
            .shadow(color: colorScheme == .light ? .black.opacity(isFocused ? 0.075 : 0.05) : .clear, radius: 10, y: 4)
    }

    private var borderColor: Color {
        if accentBorder { return ParityTheme.accent }
        if contrast == .increased { return Color.primary.opacity(isFocused ? 0.42 : 0.28) }
        return isFocused ? ParityTheme.strongSeparator : ParityTheme.separator
    }
}

extension View {
    func parityElevatedSurface(cornerRadius: CGFloat = ParityRadius.surface,
                               isFocused: Bool = false, accentBorder: Bool = false) -> some View {
        modifier(ParitySurfaceElevation(cornerRadius: cornerRadius, isFocused: isFocused, accentBorder: accentBorder))
    }
}

/// Non-status 6-hue project dot palette (indigo, teal, purple, plum, slate, bronze), excluding status
/// green, orange, red, and pure running blue so project markers never collide with task status indicators.
enum ParityProjectPalette {
    static let lightHexes = ["#5B5FC7", "#0F8B8D", "#7C4DFF", "#A44A7B", "#52657A", "#9A6B3F"]
    static let darkHexes  = ["#818CF8", "#2DD4BF", "#A78BFA", "#E879A8", "#94A3B8", "#D4A373"]

    static func index(for name: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(lightHexes.count))
    }

    static func color(for name: String) -> Color {
        let idx = index(for: name)
        return Color(nsColor: NSColor(name: "YardletProjectHue\(idx)") { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? darkHexes[idx] : lightHexes[idx]
            return ThemeRGB(hex)?.nsColor ?? .secondaryLabelColor
        })
    }
}
