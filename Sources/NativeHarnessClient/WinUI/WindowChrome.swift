import Foundation
import UWP
import WinAppSDK
import WinUI

/// A Yardlet window's frame, as Windows 11's own apps frame theirs (Settings, File Explorer): Mica behind the window,
/// the content reaching up to a title bar of Yardlet's own, which shows Yardlet's mark and the window's title at its
/// left and leaves Windows' caption buttons at its right, as tall as Windows 11's tall title bar. The Mac's window
/// likewise has no title bar apart from its content.
@MainActor
enum WindowChrome {
    static let titleBarHeight: Double = 48

    /// Makes `content`, under the title bar, the window's content, and has the theme follow its appearance. `subtitle`
    /// follows the title in the bar, dimmer, as the Mac's window subtitle follows its title.
    static func frame(_ window: Window, title: String, subtitle: TextBlock? = nil, content: FrameworkElement) {
        window.title = title
        window.extendsContentIntoTitleBar = true
        window.systemBackdrop = MicaBackdrop()
        window.appWindow.titleBar.preferredHeightOption = .tall
        let root = Grid()
        let barRow = RowDefinition()
        barRow.height = GridLength(value: titleBarHeight, gridUnitType: .pixel)
        let contentRow = RowDefinition()
        contentRow.height = GridLength(value: 1, gridUnitType: .star)
        root.rowDefinitions.append(barRow)
        root.rowDefinitions.append(contentRow)
        let bar = titleBar(title, subtitle: subtitle)
        root.children.append(bar)
        try? Grid.setRow(content, 1)
        root.children.append(content)
        window.content = root
        // Windows moves the window by this element and keeps the caption buttons' area to itself.
        try? window.setTitleBar(bar)
        WindowsTheme.follow(root)
        QAEventLog.shared.write("window chrome: mica, title bar \(title)")
    }

    private static func titleBar(_ title: String, subtitle: TextBlock?) -> Grid {
        let bar = Grid()
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 12
        row.margin = Thickness(left: 16, top: 0, right: 0, bottom: 0)
        row.verticalAlignment = .center
        if let mark = PackagedImage.bitmap(named: "yardlet", subdirectory: "AppMark") {
            let icon = ImageIcon()
            icon.source = mark
            icon.width = 16
            icon.height = 16
            icon.verticalAlignment = .center
            row.children.append(icon)
        }
        let text = TextBlock()
        text.text = title
        text.fontSize = 12
        text.verticalAlignment = .center
        text.foreground = WindowsTheme.text.brush
        row.children.append(text)
        if let subtitle {
            subtitle.fontSize = 12
            subtitle.verticalAlignment = .center
            subtitle.foreground = WindowsTheme.secondaryText.brush
            row.children.append(subtitle)
        }
        bar.children.append(row)
        return bar
    }
}
