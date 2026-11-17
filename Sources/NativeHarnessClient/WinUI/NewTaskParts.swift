import Foundation
import UWP
import WinUI

/// The large title over New task's composer, as the Mac's (`NewTaskHeroTitle`): "What should we build?", or "…in
/// {project}?", whose project name, underlined, opens the project menu; under a title without a project, the chip that
/// chooses where the task starts (`NewTaskDestinationButton`). The window's New task and a host's New task draw it
/// alike, each with its own project menu.
@MainActor
final class NewTaskTitle {
    /// The title, and the chip under it.
    let view = StackPanel()
    private let title = StackPanel()
    private let destination = Grid()
    /// The title's words, which the window's width sizes.
    private var texts: [TextBlock] = []
    private var width: Double = 0

    init() {
        title.orientation = .horizontal
        title.horizontalAlignment = .center
        view.children.append(title)
        destination.horizontalAlignment = .center
        destination.margin = Thickness(left: 0, top: 8, right: 0, bottom: 0)
        view.children.append(destination)
    }

    /// Draws the title `kind` names, the project's name opening `menu`, and under it the chip with `chip`'s words and
    /// mark opening `menu` too, or no chip.
    func show(_ kind: NewTaskHeroTitleKind, chip: (title: String, glyph: String)?,
              menu: @MainActor () -> MenuFlyout) {
        let parts = kind.parts
        title.children.clear()
        texts = []
        if !parts.before.isEmpty { title.children.append(text(parts.before)) }
        if let project = parts.project {
            // The project's name is the project menu, underlined as the Codex app's is.
            let name = Button()
            ComposerParts.styleFlat(name, pointerOver: ComposerParts.clear, pressed: ComposerParts.clear, radius: 0)
            name.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
            let words = text(project)
            words.foreground = WindowsTheme.text.brush
            let underline = Border()
            underline.borderBrush = WindowsTheme.tertiaryText.brush
            underline.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 1.5)
            underline.child = words
            name.content = underline
            name.flyout = menu()
            try? AutomationProperties.setName(name, L10n.string("Project"))
            try? ToolTipService.setToolTip(name, L10n.string("Project"))
            title.children.append(name)
        }
        if !parts.after.isEmpty { title.children.append(text(parts.after)) }
        try? AutomationProperties.setName(title, kind.sentence)
        fit(width: width)

        destination.children.clear()
        if let chip {
            let control = ComposerParts.control(title: chip.title, glyph: chip.glyph, chevron: true,
                                                name: L10n.string("Project"))
            control.flyout = menu()
            destination.children.append(control)
            destination.visibility = .visible
        } else {
            destination.visibility = .collapsed
        }
    }

    /// 28 points where the window has room, 22 where it is narrow, as the Mac's steps down.
    func fit(width: Double) {
        self.width = width
        let size: Double = width > 0 && width < 640 ? 22 : 28
        for text in texts where text.fontSize != size { text.fontSize = size }
    }

    private func text(_ words: String) -> TextBlock {
        let text = TextBlock()
        text.text = words
        text.fontSize = 28
        text.fontWeight = UWP.FontWeight(weight: 600)
        text.foreground = WindowsTheme.text.brush
        text.textWrapping = .noWrap
        text.verticalAlignment = .bottom
        texts.append(text)
        return text
    }
}

/// New task's other pieces that the window's New task and a host's draw alike.
@MainActor
enum NewTaskParts {
    /// The harness with its mark (`NewTaskHarnessControl`), whose menu lists `choices`, `harness` checked.
    static func harnessControl(_ harness: HarnessKind?, name: String?, choices: [(kind: HarnessKind, name: String)],
                               choose: @escaping @MainActor (HarnessKind) -> Void) -> Button {
        let button = Button()
        ComposerParts.styleFlat(button)
        button.height = ComposerParts.controlHeight
        button.padding = Thickness(left: 7, top: 0, right: 7, bottom: 0)
        button.verticalAlignment = .center
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 5
        if let harness, let icon = HarnessIcon.element(for: harness) {
            icon.verticalAlignment = .center
            row.children.append(icon)
        }
        row.children.append(ComposerParts.label(name ?? L10n.string("Choose harness"), color: WindowsTheme.text))
        row.children.append(ComposerParts.glyph(ComposerParts.Glyph.chevronDown, size: 8, color: WindowsTheme.text))
        button.content = row
        try? AutomationProperties.setName(button, L10n.string("Harness"))
        try? ToolTipService.setToolTip(button, name ?? L10n.string("No available harnesses"))
        let menu = MenuFlyout()
        menu.placement = .top
        for choice in choices {
            let item = RadioMenuFlyoutItem()
            item.text = choice.name
            item.groupName = "harness"
            item.isChecked = choice.kind == harness
            if let icon = HarnessIcon.element(for: choice.kind) { item.icon = icon }
            let kind = choice.kind
            item.click.addHandler { _, _ in choose(kind) }
            menu.items.append(item)
        }
        if !choices.isEmpty { button.flyout = menu }
        return button
    }

    /// A recent task (`RecentTaskButton`): its harness's mark, its title over its place and harness, its state.
    static func recentRow(_ session: SessionRecord, place: String,
                          open: @escaping @MainActor () -> Void) -> Button {
        let button = Button()
        ComposerParts.styleFlat(button, radius: 8)
        button.horizontalAlignment = .stretch
        button.horizontalContentAlignment = .stretch
        button.padding = Thickness(left: 10, top: 6, right: 10, bottom: 6)
        button.minHeight = 48
        let row = Grid()
        row.columnSpacing = 11
        for width in [GridLength(value: 24, gridUnitType: .pixel), GridLength(value: 1, gridUnitType: .star),
                      GridLength(value: 0, gridUnitType: .auto), GridLength(value: 0, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        if let icon = HarnessIcon.element(for: session.harness) {
            icon.verticalAlignment = .center
            icon.horizontalAlignment = .center
            row.children.append(icon)
        }
        let words = StackPanel()
        words.spacing = 2
        words.verticalAlignment = .center
        words.children.append(ComposerParts.label(session.title, size: 14, color: WindowsTheme.text))
        words.children.append(ComposerParts.label("\(place) · \(session.harness.displayName)", size: 12, weight: 400))
        try? Grid.setColumn(words, 1)
        row.children.append(words)
        let state = ComposerParts.label(session.status.displayName, size: 12,
                                        color: session.status == .failed ? ComposerParts.red : WindowsTheme.secondaryText,
                                        weight: 400)
        try? Grid.setColumn(state, 2)
        row.children.append(state)
        let chevron = ComposerParts.glyph("\u{E76C}", size: 10, color: WindowsTheme.tertiaryText)
        try? Grid.setColumn(chevron, 3)
        row.children.append(chevron)
        button.content = row
        try? AutomationProperties.setName(button, session.title)
        button.click.addHandler { _, _ in open() }
        return button
    }
}
