import Foundation
import UWP
import WinUI

/// The composer's pieces as the Mac draws them, for the task's composer and New task's alike: the card
/// (`ComposerEditor`: rounded, filled as an input, a hairline that strengthens while the text has focus), the bottom
/// row's controls (`ParityComposerControl`: words with no frame, filled under the pointer), Send as a dark rounded
/// square (`ParityIconButton`), Stop as a red circle in its place, and the context ring. Windows' own controls draw
/// them, restyled through the resources their templates read (lightweight styling); their symbols are Segoe Fluent
/// Icons, as Windows' own apps draw theirs.
@MainActor
enum ComposerParts {
    static let clear = SolidColorBrush(UWP.Color(a: 0, r: 0, g: 0, b: 0))
    /// The Mac's system orange and red, for an elevated permission, a notice and Stop.
    static let orange = ThemeColor(light: .rgb(1.00, 0.58, 0.00), dark: .rgb(1.00, 0.62, 0.04))
    static let red = ThemeColor(light: .rgb(1.00, 0.23, 0.19), dark: .rgb(1.00, 0.27, 0.23))
    static let white = ThemeColor(light: .gray(1), dark: .gray(1))
    /// The context ring's track, as the Claude app's strong border.
    static let ringTrack = ThemeColor(light: .ink(0.22), dark: .paper(0.22))

    /// Segoe Fluent Icons' code points for the Mac's symbols.
    enum Glyph {
        static let plus = "\u{E710}"
        static let arrowUp = "\u{E74A}"
        static let arrowDown = "\u{E74B}"
        static let stop = "\u{E71A}"
        static let chevronDown = "\u{E70D}"
        static let shield = "\u{EA18}"
        static let warning = "\u{E7BA}"
        static let queue = "\u{E8FD}"
        static let steer = "\u{E72A}"
        static let clock = "\u{E823}"
        static let delivered = "\u{E930}"
        static let failed = "\u{E783}"
        static let retry = "\u{E72C}"
        static let edit = "\u{E70F}"
        static let remove = "\u{E711}"
        static let fromTask = "\u{E8BD}"
        static let plan = "\u{E9D5}"
        static let pause = "\u{E769}"
        static let play = "\u{E768}"
        static let attach = "\u{E723}"
        static let file = "\u{E8A5}"
        static let folder = "\u{E8B7}"
        static let image = "\u{EB9F}"
    }

    /// The bottom row's controls are this tall, as Claude Code's (`--cds-h-control`).
    static let controlHeight: Double = 24
    /// Send, Stop, + and the queue's button.
    static let buttonSize: Double = 28

    static func corners(_ radius: Double) -> CornerRadius {
        CornerRadius(topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius)
    }

    static func glyph(_ code: String, size: Double = 12, color: ThemeColor = WindowsTheme.secondaryText) -> FontIcon {
        let icon = FontIcon()
        icon.glyph = code
        icon.fontSize = size
        icon.foreground = color.brush
        icon.verticalAlignment = .center
        return icon
    }

    static func label(_ words: String, size: Double = 13, color: ThemeColor = WindowsTheme.secondaryText,
                      weight: UInt16 = 500) -> TextBlock {
        let block = TextBlock()
        block.text = words
        block.fontSize = size
        block.fontWeight = UWP.FontWeight(weight: weight)
        block.foreground = color.brush
        block.textWrapping = .noWrap
        block.textTrimming = .characterEllipsis
        block.maxLines = 1
        block.verticalAlignment = .center
        return block
    }

    /// A button with no frame of its own: `rest` fills it, the Mac's hover fill under the pointer, the chosen fill
    /// while pressed. Windows' button draws its states from these resources.
    static func styleFlat(_ button: Button, rest: SolidColorBrush? = nil, pointerOver: SolidColorBrush? = nil,
                          pressed: SolidColorBrush? = nil, radius: Double = 6) {
        let resources = button.resources
        func set(_ key: String, _ value: Any) { _ = resources?.insert(key, value) }
        let rest = rest ?? clear
        set("ButtonBackground", rest)
        set("ButtonBackgroundPointerOver", pointerOver ?? WindowsTheme.hoverFill.brush)
        set("ButtonBackgroundPressed", pressed ?? WindowsTheme.selectedFill.brush)
        set("ButtonBackgroundDisabled", rest)
        for state in ["", "PointerOver", "Pressed", "Disabled"] { set("ButtonBorderBrush\(state)", clear) }
        button.background = rest
        button.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        button.cornerRadius = corners(radius)
        button.minWidth = 0
        button.minHeight = 0
    }

    struct ControlLabel {
        let title: TextBlock
        let detail: TextBlock?
        var titleLimit: Double { detail == nil ? 138 : 196 }
    }

    /// One of the bottom row's controls (`ParityComposerControl`): an optional symbol, the words, dimmer words after
    /// a middle dot, a chevron where it opens a menu; 24 high, its corners 6, filled under the pointer.
    static func control(title: String, detail: String? = nil, glyph code: String? = nil, chevron: Bool = false,
                        tint: ThemeColor = WindowsTheme.secondaryText, name: String? = nil,
                        onLabel: ((ControlLabel) -> Void)? = nil) -> Button {
        let button = Button()
        styleFlat(button)
        button.height = controlHeight
        button.padding = Thickness(left: 7, top: 0, right: 7, bottom: 0)
        button.verticalAlignment = .center
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 5
        if let code { row.children.append(glyph(code, size: 11.5, color: tint)) }
        let words = label(title, color: tint)
        let dim = detail.map { label("· \($0)", color: WindowsTheme.tertiaryText) }
        let controlLabel = ControlLabel(title: words, detail: dim)
        words.maxWidth = controlLabel.titleLimit
        row.children.append(words)
        if let dim {
            dim.maxWidth = 120
            row.children.append(dim)
        }
        onLabel?(controlLabel)
        if chevron { row.children.append(glyph(Glyph.chevronDown, size: 8, color: tint)) }
        button.content = row
        // UI Automation names the control by what it is, and reads its value from its words.
        try? AutomationProperties.setName(button, name ?? title)
        return button
    }

    /// A round or rounded button of the row: Send, Stop, + and the queue's button.
    static func iconButton(_ code: String, name: String, size: Double = 12, foreground: ThemeColor,
                           fill: ThemeColor?, radius: Double) -> Button {
        let button = Button()
        styleFlat(button, rest: fill?.brush, pointerOver: fill == nil ? nil : fill?.brush,
                  pressed: fill == nil ? nil : fill?.brush, radius: radius)
        button.width = buttonSize
        button.height = buttonSize
        button.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        button.verticalAlignment = .center
        button.content = glyph(code, size: size, color: foreground)
        try? AutomationProperties.setName(button, name)
        try? ToolTipService.setToolTip(button, name)
        return button
    }

    /// Send, the Mac's primary action: a dark rounded square with an arrow, dimmed while there is nothing to send.
    static func sendButton(name: String) -> Button {
        let button = iconButton(Glyph.arrowUp, name: name, size: 13, foreground: WindowsTheme.primaryActionForeground,
                                fill: WindowsTheme.primaryActionFill, radius: 6)
        setEnabled(button, false)
        return button
    }

    /// Stop, in Send's place and size while the turn runs: a red circle with a square.
    static func stopButton(name: String) -> Button {
        iconButton(Glyph.stop, name: name, size: 10, foreground: white, fill: red, radius: buttonSize / 2)
    }

    /// On or off, dimmed as the Mac dims a prominent button it turned off.
    static func setEnabled(_ button: Button, _ enabled: Bool) {
        guard button.isEnabled != enabled || button.opacity != (enabled ? 1 : 0.4) else { return }
        button.isEnabled = enabled
        button.opacity = enabled ? 1 : 0.4
    }

    /// The context ring (`ComposerContextRing`): the window's share in its severity's color over a track, 12 wide in a
    /// 24-wide button whose tooltip names the numbers and whose flyout says them, as the Mac's popover does.
    static func contextRing(_ summary: ComposerContextSummary, compact: (title: String, isAvailable: Bool,
                                                                         reason: String, run: () -> Void)?) -> Button {
        let button = Button()
        styleFlat(button, radius: 12)
        button.width = 24
        button.height = 24
        button.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        button.verticalAlignment = .center
        let ring = ProgressRing()
        ring.isIndeterminate = false
        ring.minimum = 0
        ring.maximum = 100
        ring.value = (summary.fraction ?? 0) * 100
        ring.minWidth = 0
        ring.minHeight = 0
        ring.width = 14
        ring.height = 14
        ring.background = ringTrack.brush
        ring.foreground = severityColor(summary.severity).brush
        button.content = ring
        try? AutomationProperties.setName(button, L10n.string("Context window"))
        try? ToolTipService.setToolTip(button, summary.help)

        let details = StackPanel()
        details.spacing = 6
        details.minWidth = 220
        details.maxWidth = 300
        let heading = label(L10n.string("Context window"), size: 13, color: WindowsTheme.text, weight: 600)
        details.children.append(heading)
        let numbers = label(summary.summaryText ?? L10n.string("Unavailable"), size: 12)
        numbers.textWrapping = .wrap
        numbers.maxLines = 0
        details.children.append(numbers)
        for row in summary.legend {
            let line = label("\(row.name)  \(row.tokensText) · \(row.shareText)", size: 12,
                             color: WindowsTheme.tertiaryText, weight: 400)
            details.children.append(line)
        }
        if let hint = summary.autoCompactHint {
            details.children.append(label(hint, size: 12, color: WindowsTheme.tertiaryText, weight: 400))
        }
        let flyout = Flyout()
        if let compact {
            let action = Button()
            action.content = compact.title
            action.isEnabled = compact.isAvailable
            try? AutomationProperties.setName(action, compact.title)
            if !compact.isAvailable { try? ToolTipService.setToolTip(action, compact.reason) }
            // The flyout as its events pass it, held only while it is open: the Swift wrapper made here is gone once
            // the button holds the flyout, so a weak reference to it would be nil when the action is clicked.
            var shown: Flyout?
            flyout.opened.addHandler { sender, _ in shown = sender as? Flyout }
            flyout.closed.addHandler { _, _ in shown = nil }
            action.click.addHandler { _, _ in
                try? shown?.hide()
                compact.run()
            }
            details.children.append(action)
        }
        flyout.content = details
        button.flyout = flyout
        return button
    }

    static func severityColor(_ severity: ComposerContextSummary.Severity) -> ThemeColor {
        switch severity {
        case .normal: WindowsTheme.secondaryText
        case .warning: orange
        case .critical: red
        }
    }

    /// A menu item with a symbol, as Windows' menus draw one.
    static func menuItem(_ title: String, glyph code: String? = nil, keys: String? = nil,
                         action: @escaping @MainActor () -> Void) -> MenuFlyoutItem {
        let item = MenuFlyoutItem()
        item.text = title
        if let code {
            let icon = FontIcon()
            icon.glyph = code
            item.icon = icon
        }
        if let keys { item.keyboardAcceleratorTextOverride = keys }
        item.click.addHandler { _, _ in action() }
        return item
    }
}

/// The Mac's composer card (`ComposerEditor`): rounded 14, filled as an input, a hairline around it that strengthens
/// while the text has focus. Top to bottom: what waits above the text (the queue), what the message carries, the text,
/// a notice in orange, and the bottom row, its controls at the start and its actions at the end. The task's composer
/// and New task's compose theirs into it; the field is Windows' own text box, its frame and fill left to the card.
@MainActor
final class ComposerCard {
    let view = Border()
    let field = TextBox()
    /// Above the text: the queued messages.
    let top = StackPanel()
    /// Between them and the text: what the message carries (`ComposerAttachments`).
    let attachments = Border()
    /// The leading controls, after +.
    let leading = StackPanel()
    /// The trailing controls, before Send.
    let trailing = StackPanel()
    /// Over the bottom row: what the composer needs said before it can send, such as a sign-in.
    let extras = StackPanel()
    private let notice = TextBlock()
    private let grid = Grid()
    private let bottom = Grid()
    private var modelLabel: ComposerParts.ControlLabel?

    @MainActor struct Metrics {
        var text: Thickness
        var minTextHeight: Double
        var maxTextHeight: Double
        var fontSize: Double
        var wrapsControls = false

        /// Below a conversation (`ComposerEditorMetrics.task`).
        static let task = Metrics(text: Thickness(left: 15, top: 12, right: 15, bottom: 6), minTextHeight: 40,
                                  maxTextHeight: ComposerKeys.maximumHeight, fontSize: WindowsTheme.bodyFontSize,
                                  wrapsControls: true)
        /// New task's (`ComposerEditorMetrics.newTask`).
        static let newTask = Metrics(text: Thickness(left: 16, top: 16, right: 16, bottom: 12), minTextHeight: 44,
                                     maxTextHeight: 250, fontSize: WindowsTheme.bodyFontSize + 1)
    }

    init(metrics: Metrics) {
        view.cornerRadius = ComposerParts.corners(WindowsTheme.composerCornerRadius)
        view.background = WindowsTheme.input.brush
        view.borderBrush = WindowsTheme.separator.brush
        view.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)

        for _ in 0..<6 {
            let row = RowDefinition()
            row.height = GridLength(value: 0, gridUnitType: .auto)
            grid.rowDefinitions.append(row)
        }
        top.spacing = 4
        top.margin = Thickness(left: 10, top: 8, right: 10, bottom: 0)
        top.visibility = .collapsed
        grid.children.append(top)

        // The Mac's chip row: 14 in from the card's sides, below the queue.
        attachments.margin = Thickness(left: 14, top: 10, right: 14, bottom: 0)
        try? Grid.setRow(attachments, 1)
        grid.children.append(attachments)

        styleField(metrics)
        try? Grid.setRow(field, 2)
        grid.children.append(field)

        notice.textWrapping = .wrap
        notice.isTextSelectionEnabled = true
        notice.fontSize = 12
        notice.foreground = ComposerParts.orange.brush
        notice.margin = Thickness(left: metrics.text.left, top: 0, right: metrics.text.right, bottom: 8)
        notice.visibility = .collapsed
        try? Grid.setRow(notice, 3)
        grid.children.append(notice)

        // Each of its rows keeps its own space below it, so an empty one takes none.
        extras.margin = Thickness(left: metrics.text.left, top: 0, right: metrics.text.right, bottom: 0)
        try? Grid.setRow(extras, 4)
        grid.children.append(extras)

        bottom.margin = Thickness(left: 10, top: 0, right: 9, bottom: 9)
        bottom.columnSpacing = 7
        for width in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 0, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            bottom.columnDefinitions.append(column)
        }
        if metrics.wrapsControls {
            for _ in 0..<2 {
                let row = RowDefinition()
                row.height = GridLength(value: 0, gridUnitType: .auto)
                bottom.rowDefinitions.append(row)
            }
            trailing.horizontalAlignment = .right
            view.sizeChanged.addHandler { [weak self] _, change in
                guard let change, change.newSize.width != change.previousSize.width else { return }
                self?.fitFooter()
            }
        }
        leading.orientation = .horizontal
        leading.spacing = 4
        leading.verticalAlignment = .center
        bottom.children.append(leading)
        trailing.orientation = .horizontal
        trailing.spacing = 7
        trailing.verticalAlignment = .center
        try? Grid.setColumn(trailing, 1)
        bottom.children.append(trailing)
        try? Grid.setRow(bottom, 5)
        grid.children.append(bottom)
        view.child = grid

        field.gotFocus.addHandler { [weak self] _, _ in self?.view.borderBrush = WindowsTheme.composerFocusBorder.brush }
        field.lostFocus.addHandler { [weak self] _, _ in self?.view.borderBrush = WindowsTheme.separator.brush }
    }

    /// The queued actions can change without the card resizing, for example on a running turn.
    func fitTaskControls(modelLabel: ComposerParts.ControlLabel?) {
        self.modelLabel = modelLabel
        fitFooter()
    }

    private func fitFooter() {
        let width = view.actualWidth - view.borderThickness.left - view.borderThickness.right
            - bottom.margin.left - bottom.margin.right
        guard width > 0 else { return }

        func idealWidth(_ element: UIElement) -> Double {
            try? element.measure(.init(width: .infinity, height: .infinity))
            return Double(element.desiredSize.width)
        }
        // Measure the full labels first, including after widening a previously narrow window.
        if let modelLabel {
            modelLabel.title.maxWidth = modelLabel.titleLimit
            modelLabel.detail?.visibility = .visible
        }
        let fullTrailing = idealWidth(trailing)
        let wraps = idealWidth(leading) + bottom.columnSpacing + fullTrailing > width
        try? Grid.setColumnSpan(leading, wraps ? 2 : 1)
        try? Grid.setRow(trailing, wraps ? 1 : 0)
        try? Grid.setColumn(trailing, wraps ? 0 : 1)
        try? Grid.setColumnSpan(trailing, wraps ? 2 : 1)
        trailing.margin = Thickness(left: 0, top: wraps ? 6 : 0, right: 0, bottom: 0)

        // On its own row the model drops the effort before shortening the name. The context ring,
        // queue and Send or Stop retain their natural sizes.
        guard fullTrailing > width, let modelLabel else { return }
        modelLabel.detail?.visibility = .collapsed
        let overflow = max(0, idealWidth(trailing) - width)
        modelLabel.title.maxWidth = max(0, idealWidth(modelLabel.title) - overflow)
    }

    /// The text box without a frame or fill of its own in any state; the card draws them.
    private func styleField(_ metrics: Metrics) {
        let resources = field.resources
        func set(_ key: String, _ value: Any) { _ = resources?.insert(key, value) }
        for state in ["", "PointerOver", "Focused", "Disabled"] {
            set("TextControlBackground\(state)", ComposerParts.clear)
            set("TextControlBorderBrush\(state)", ComposerParts.clear)
            set("TextControlForeground\(state)", WindowsTheme.text.brush)
            set("TextControlPlaceholderForeground\(state)", WindowsTheme.secondaryText.brush)
        }
        field.background = ComposerParts.clear
        field.borderBrush = ComposerParts.clear
        field.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        field.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        field.margin = metrics.text
        field.minHeight = metrics.minTextHeight
        field.fontSize = metrics.fontSize
        field.foreground = WindowsTheme.text.brush
        field.placeholderForeground = WindowsTheme.secondaryText.brush
        field.isSpellCheckEnabled = false
    }

    /// The notice under the text: why a message stayed, in orange as the Mac's composer says it.
    func showNotice(_ text: String?) {
        let text = text ?? ""
        notice.text = text
        notice.visibility = text.isEmpty ? .collapsed : .visible
    }

    /// The card at most as wide as the conversation, centered, with the Mac's gutter around it.
    func placed(top: Double = 6, bottom: Double = 16) -> FrameworkElement {
        // Stretched up to its widest, XAML centers what is left over.
        view.maxWidth = WindowsTheme.contentWidth
        view.horizontalAlignment = .stretch
        let frame = Grid()
        frame.padding = Thickness(left: 24, top: top, right: 24, bottom: bottom)
        frame.children.append(view)
        return frame
    }
}
