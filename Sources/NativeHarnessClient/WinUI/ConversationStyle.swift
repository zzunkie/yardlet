import Foundation
import UWP
import WinUI

/// What a conversation draws with beyond the theme's colors (`WindowsTheme`): the Mac's conversation measures
/// (`ConversationLayout`, `ParityTheme`), its state colors, Windows' code font, and the pieces its parts share: text in
/// the theme's tones, a disclosure caret, the Mac's plain, gray and prominent buttons, a copy button, and actions shown
/// while the pointer is over what they act on.
///
/// Sizes are the Mac's, except that none goes under 12, the smallest size of Windows' type ramp (its Caption): the
/// Mac's captions (10 to 11.5 pt) read at 12 here, and its callout (12 pt) one step above at 13, so the two still read
/// apart as they do on the Mac.
@MainActor
enum ConversationStyle {
    // MARK: Measures, as the Mac's

    /// Between turns, and between the parts of one turn (`ConversationLayout`).
    static let turnSpacing: Double = 15
    static let itemSpacing: Double = 10
    static let topPadding: Double = 24
    static let bottomPadding: Double = 28
    /// The sent bubble: at least 96 before it, at most 472 wide, 10 corners, 12 × 8 inside.
    static let sentMessageLeadingSpace: Double = 96
    static let sentBubbleMaximumWidth: Double = 472
    static let sentBubbleCornerRadius: Double = 10
    static let sentBubblePadding = Thickness(left: 12, top: 8, right: 12, bottom: 8)
    /// The space the Mac adds between a message's lines (`ParityTheme.proseLineSpacing`).
    static let proseLineSpacing: Double = 5
    /// A status line's words (`ConversationStatusLineFont`) and its row (`--cds-h-control`).
    static let statusLineSize: Double = 14
    static let statusLineHeight: Double = 24

    // MARK: Text sizes

    static let captionSize: Double = 12
    static let calloutSize: Double = 13
    static let bodySize: Double = 14
    /// Code in a block (the Mac's 12.5) and in a diff or a call's output (the Mac's 11).
    static let codeSize: Double = 13
    static let smallCodeSize: Double = 12

    /// Windows' code font, Cascadia Mono, with Consolas where a system has no Cascadia Mono.
    static func codeFont() -> FontFamily { FontFamily("Cascadia Mono, Consolas") }

    /// A line of `size` with the Mac's spacing between lines.
    static func lineHeight(_ size: Double) -> Double { (size * 1.2 + proseLineSpacing).rounded() }

    // MARK: Colors

    /// The Mac's system orange, red and green: what waits on the person, what failed, what was allowed.
    static let orange = Tint(light: .rgb(1, 0.584, 0), dark: .rgb(1, 0.624, 0.039))
    static let red = Tint(light: .rgb(1, 0.231, 0.188), dark: .rgb(1, 0.271, 0.227))
    static let green = Tint(light: .rgb(0.157, 0.804, 0.255), dark: .rgb(0.196, 0.843, 0.294))
    /// The Mac's secondary label as a tint, for what expired.
    static let gray = Tint(light: .ink(0.5), dark: .paper(0.55))
    /// The Mac's code colors (`TranscriptCodeBlock`): strings, keywords and numbers.
    static let codeString = ThemeColor(light: .rgb(0.17, 0.39, 0.22), dark: .rgb(0.65, 0.84, 0.60))
    static let codeKeyword = ThemeColor(light: .rgb(0.45, 0.21, 0.64), dark: .rgb(0.83, 0.67, 0.96))
    static let codeNumber = ThemeColor(light: .rgb(0.12, 0.34, 0.62), dark: .rgb(0.58, 0.77, 0.96))
    /// The Mac's bordered button: a gray fill, darker under the pointer and pressed.
    static let buttonFill = ThemeColor(light: .ink(0.07), dark: .paper(0.12))
    static let buttonFillOver = ThemeColor(light: .ink(0.10), dark: .paper(0.16))
    static let buttonFillPressed = ThemeColor(light: .ink(0.14), dark: .paper(0.20))
    /// The Mac's prominent button, in Yardlet's accent: white words on light, dark words on the light blue of dark.
    static let prominentForeground = ThemeColor(light: .gray(1), dark: .gray(0.1))
    static let clear = ThemeColor(light: .ink(0), dark: .paper(0))

    // MARK: Text

    enum Tone {
        case primary, secondary, tertiary
    }

    static func brush(_ tone: Tone) -> SolidColorBrush {
        switch tone {
        case .primary: WindowsTheme.text.brush
        case .secondary: WindowsTheme.secondaryText.brush
        case .tertiary: WindowsTheme.tertiaryText.brush
        }
    }

    /// Words in one of the theme's tones. Words a button holds do not take a selection, which would take its clicks.
    static func text(_ string: String, size: Double = bodySize, tone: Tone = .primary, semibold: Bool = false,
                     selectable: Bool = true, wraps: Bool = true) -> TextBlock {
        let block = TextBlock()
        block.text = string
        block.fontSize = size
        block.foreground = brush(tone)
        block.textWrapping = wraps ? .wrap : .noWrap
        if !wraps { block.textTrimming = .characterEllipsis }
        block.isTextSelectionEnabled = selectable
        if semibold { block.fontWeight = UWP.FontWeight(weight: 600) }
        return block
    }

    /// A Segoe Fluent Icons glyph, the system's own symbols.
    static func icon(_ glyph: String, size: Double = 12, brush: SolidColorBrush = WindowsTheme.secondaryText.brush) -> FontIcon {
        let icon = FontIcon()
        icon.glyph = glyph
        icon.fontSize = size
        icon.foreground = brush
        icon.verticalAlignment = .center
        return icon
    }

    /// The Mac's disclosure caret: right while folded, down while open.
    static func caret(isOpen: Bool, size: Double = 8) -> FontIcon {
        icon(isOpen ? Glyph.chevronDown : Glyph.chevronRight, size: size, brush: WindowsTheme.tertiaryText.brush)
    }

    /// A small spinner, as the Mac marks what runs.
    static func spinner(size: Double = 12) -> ProgressRing {
        let ring = ProgressRing()
        ring.isActive = true
        ring.minWidth = 0
        ring.minHeight = 0
        ring.width = size
        ring.height = size
        ring.verticalAlignment = .center
        return ring
    }

    /// A row of pieces side by side, centered on one another.
    static func row(_ children: [UIElement], spacing: Double = 6) -> StackPanel {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = spacing
        for child in children { row.children.append(child) }
        return row
    }

    static func corners(_ radius: Double) -> CornerRadius {
        CornerRadius(topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius)
    }

    // MARK: Buttons

    /// A button with no chrome of its own around `content`, such as a line that opens: Windows' subtle fill shows
    /// under the pointer and while pressed, as its own subtle buttons show it.
    static func plainButton(_ content: UIElement, name: String, action: @escaping @MainActor () -> Void) -> Button {
        let button = Button()
        button.content = content
        button.padding = Thickness(left: 2, top: 0, right: 2, bottom: 0)
        button.minWidth = 0
        button.minHeight = 0
        button.horizontalAlignment = .left
        button.horizontalContentAlignment = .left
        button.cornerRadius = corners(4)
        paint(button, prefix: "Button", fill: clear, over: WindowsTheme.hoverFill, pressed: WindowsTheme.selectedFill)
        try? AutomationProperties.setName(button, name)
        button.click.addHandler { _, _ in action() }
        return button
    }

    /// A line that opens what it holds, in the Mac's look (its words, then a caret) and with Windows' toggle, which
    /// tells assistive apps whether it is open. `toggle` is told the new state. The handlers hold no Swift object of
    /// the button's, which nothing else keeps (see `ConversationWorkLines`).
    static func disclosure(_ content: UIElement, name: String, isOpen: Bool,
                           toggle: @escaping @MainActor (Bool) -> Void) -> ToggleButton {
        let button = ToggleButton()
        button.content = content
        button.isChecked = isOpen
        button.padding = Thickness(left: 2, top: 0, right: 2, bottom: 0)
        button.minWidth = 0
        button.minHeight = 0
        button.horizontalAlignment = .left
        button.horizontalContentAlignment = .left
        button.cornerRadius = corners(4)
        for state in ["", "Checked"] {
            paint(button, prefix: "ToggleButton", state: state, fill: clear, over: WindowsTheme.hoverFill,
                  pressed: WindowsTheme.selectedFill)
        }
        try? AutomationProperties.setName(button, name)
        // Checked and unchecked come however it turns, by a click, a key or an assistive app.
        button.checked.addHandler { _, _ in toggle(true) }
        button.unchecked.addHandler { _, _ in toggle(false) }
        return button
    }

    /// The Mac's bordered button: its title on a gray fill with a subtle hairline border.
    static func grayButton(_ title: String, action: @escaping @MainActor () -> Void) -> Button {
        let button = Button()
        button.content = title
        button.cornerRadius = corners(6)
        paint(button, prefix: "Button", fill: buttonFill, over: buttonFillOver, pressed: buttonFillPressed,
              border: WindowsTheme.separator)
        try? AutomationProperties.setName(button, title)
        button.click.addHandler { _, _ in action() }
        return button
    }

    /// The Mac's prominent button, in Yardlet's accent.
    static func prominentButton(_ title: String, action: @escaping @MainActor () -> Void) -> Button {
        let button = Button()
        button.content = title
        button.cornerRadius = corners(6)
        paint(button, prefix: "Button", fill: WindowsTheme.accent, over: WindowsTheme.accent, pressed: WindowsTheme.accent,
              foreground: prominentForeground)
        try? AutomationProperties.setName(button, title)
        button.click.addHandler { _, _ in action() }
        return button
    }

    /// Gives `button` its fills by the theme resources its template reads (Windows' lightweight styling), so they
    /// hold under the pointer, pressed and disabled too, with an optional hairline border.
    private static func paint(_ button: ContentControl, prefix: String, state: String = "", fill: ThemeColor,
                              over: ThemeColor, pressed: ThemeColor, foreground: ThemeColor? = nil,
                              border: ThemeColor? = nil) {
        let resources = button.resources!
        let stroke = border ?? clear
        let states: [(String, ThemeColor)] = [("", fill), ("PointerOver", over), ("Pressed", pressed), ("Disabled", fill)]
        for (suffix, color) in states {
            _ = resources.insert(prefix + "Background" + state + suffix, color.brush)
            _ = resources.insert(prefix + "BorderBrush" + state + suffix, stroke.brush)
            if let foreground {
                _ = resources.insert(prefix + "Foreground" + state + suffix, foreground.brush)
            }
        }
        button.background = fill.brush
        let line: Double = border == nil ? 0 : 1
        button.borderBrush = stroke.brush
        button.borderThickness = Thickness(left: line, top: line, right: line, bottom: line)
        if let foreground { button.foreground = foreground.brush }
    }

    // MARK: Copy

    /// Puts `text` on the clipboard; whether it went there.
    @discardableResult
    static func copy(_ text: String) -> Bool {
        let package = DataPackage()
        guard (try? package.setText(text)) != nil else { return false }
        return (try? Clipboard.setContentWithOptions(package, ClipboardContentOptions())) == true
    }

    /// The Mac's copy button (`TranscriptCopyButton`): its mark and title in the secondary tone, reading "Copied" with
    /// a check for two seconds once it copied.
    static func copyButton(_ title: String, payload: @escaping @MainActor () -> String?) -> Button {
        let mark = icon(Glyph.copy, size: 12)
        let words = text(title, size: captionSize, tone: .secondary, selectable: false, wraps: false)
        let feedback = CopyFeedback()
        let button = plainButton(row([mark, words], spacing: 5), name: title) {
            guard let payload = payload(), copy(payload) else { return }
            mark.glyph = Glyph.check
            words.text = L10n.string("Copied")
            feedback.shown += 1
            let shown = feedback.shown
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard shown == feedback.shown else { return }
                mark.glyph = Glyph.copy
                words.text = title
            }
        }
        button.padding = Thickness(left: 2, top: 1, right: 4, bottom: 1)
        return button
    }

    /// How many times a copy button said it copied, so only the latest time's two seconds put its title back.
    private final class CopyFeedback {
        var shown = 0
    }

    /// Shows `actions` while the pointer is over `area` or the keyboard's focus is in it, as the Mac shows a message's
    /// actions (`HoverRevealedAction`). Hidden, they keep their place, so showing them moves nothing. The handlers are
    /// `area`'s, which holds `actions`: focus moving into the actions reaches `area` as it bubbles up, and a handler on
    /// the actions holding the actions would never be freed.
    static func revealOnHover(_ actions: UIElement, in area: UIElement) {
        actions.opacity = 0
        let state = HoverState()
        let update = { actions.opacity = state.isOver || state.hasFocus ? 1 : 0 }
        area.pointerEntered.addHandler { _, _ in
            state.isOver = true
            update()
        }
        area.pointerExited.addHandler { _, _ in
            state.isOver = false
            update()
        }
        area.gotFocus.addHandler { _, _ in
            state.hasFocus = true
            update()
        }
        area.lostFocus.addHandler { _, _ in
            state.hasFocus = false
            update()
        }
    }

    private final class HoverState {
        var isOver = false
        var hasFocus = false
    }

    /// The Segoe Fluent Icons the conversation uses.
    enum Glyph {
        static let chevronRight = "\u{E76C}"
        static let chevronDown = "\u{E70D}"
        static let chevronLeft = "\u{E76B}"
        static let copy = "\u{E8C8}"
        static let check = "\u{E73E}"
        static let warning = "\u{E7BA}"
        static let shield = "\u{EA18}"
        static let question = "\u{E897}"
        static let cancel = "\u{E711}"
        static let error = "\u{E783}"
        static let clock = "\u{E823}"
        static let list = "\u{E8FD}"
        static let picture = "\u{E8B9}"
        static let lightbulb = "\u{EA80}"
        static let sync = "\u{E895}"
        static let gear = "\u{E713}"
        static let message = "\u{E8BD}"
        static let circle = "\u{EA3A}"
        static let circleFill = "\u{EA3B}"
        static let edit = "\u{E70F}"
        /// Arrows drawn inward, for a conversation's context compacted (the Mac's `rectangle.compress.vertical`).
        static let compact = "\u{E73F}"
        /// A gauge at its top, for a plan limit reached (the Mac's `gauge.with.dots.needle.100percent`).
        static let gauge = "\u{EC4A}"
    }
}

/// One of the Mac's state colors, and the lighter shades of it that cards and marks are drawn with.
@MainActor
final class Tint {
    private let light: UWP.Color
    private let dark: UWP.Color
    private var shades: [Int: ThemeColor] = [:]
    /// The color itself, for words and marks.
    let solid: ThemeColor

    init(light: UWP.Color, dark: UWP.Color) {
        self.light = light
        self.dark = dark
        solid = ThemeColor(light: light, dark: dark)
    }

    /// The color at `opacity`, as the Mac's `tint.opacity(_:)`.
    func opacity(_ opacity: Double) -> ThemeColor {
        let key = Int((opacity * 1000).rounded())
        if let shade = shades[key] { return shade }
        let shade = ThemeColor(light: light.opacity(opacity), dark: dark.opacity(opacity))
        shades[key] = shade
        return shade
    }
}

private extension UWP.Color {
    func opacity(_ opacity: Double) -> UWP.Color {
        UWP.Color(a: UInt8((Double(a) * min(max(opacity, 0), 1)).rounded()), r: r, g: g, b: b)
    }
}
