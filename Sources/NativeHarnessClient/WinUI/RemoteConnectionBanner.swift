import Foundation
import Observation
import UWP
import WinUI

/// One line above a host's task while the host cannot be reached, closed its connection or removed this computer, as
/// the Mac's host window draws it (`RemoteConnectionBanner`): why, in orange, and Try Again, or once the host removed
/// this computer, Remove, which forgets the host here. What was last read stays below it; sending waits for the
/// connection.
@MainActor
final class RemoteConnectionBanner {
    let view = Border()
    private let model: RemoteHostModel
    private let directory: RemoteHostDirectory
    private let log: QAEventLog
    private let mark = FontIcon()
    private let words = TextBlock()
    private var action = Button()
    private var removes = false
    private var shown: String?

    init(model: RemoteHostModel, directory: RemoteHostDirectory, log: QAEventLog) {
        self.model = model
        self.directory = directory
        self.log = log
        let row = Grid()
        row.columnSpacing = 10
        for width in [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star),
                      GridLength(value: 0, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        mark.fontSize = 14
        mark.foreground = ComposerParts.orange.brush
        mark.verticalAlignment = .center
        row.children.append(mark)
        words.fontSize = ConversationStyle.calloutSize
        words.foreground = WindowsTheme.text.brush
        words.textWrapping = .wrap
        words.isTextSelectionEnabled = true
        words.verticalAlignment = .center
        try? Grid.setColumn(words, 1)
        row.children.append(words)
        action = ConversationStyle.grayButton(L10n.string("Try Again")) { [weak self] in self?.act() }
        action.fontSize = 12
        action.padding = Thickness(left: 10, top: 3, right: 10, bottom: 4)
        action.verticalAlignment = .center
        try? Grid.setColumn(action, 2)
        row.children.append(action)
        view.child = row
        view.padding = Thickness(left: 16, top: 9, right: 16, bottom: 9)
        view.background = ConversationStyle.orange.opacity(0.08).brush
        view.borderBrush = WindowsTheme.separator.brush
        view.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 1)
        view.visibility = .collapsed
        follow()
    }

    private func follow() {
        let (connection, reason) = withObservationTracking {
            (model.connection, model.closingReason)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        let text = Self.text(connection, reason: reason, host: model.name)
        guard text != shown else { return }
        shown = text
        view.visibility = text == nil ? .collapsed : .visible
        guard let text else { return }
        removes = connection == .removed
        words.text = text
        mark.glyph = removes ? ConversationStyle.Glyph.error : ConversationStyle.Glyph.warning
        action.content = removes ? L10n.string("Remove") : L10n.string("Try Again")
        try? AutomationProperties.setName(action, removes ? L10n.format("Remove %@", model.name) : L10n.string("Try Again"))
        log.write("remote banner: \(text)")
    }

    /// Why the host is not there, in the Mac's words; nil while it is, or while connecting.
    private static func text(_ connection: RemoteHostModel.Connection, reason: String?, host: String) -> String? {
        switch connection {
        case .unreachable:
            switch reason {
            case "disabled": return L10n.format("%@ turned off remote connections.", host)
            case "quitting": return L10n.format("Yardlet on %@ quit.", host)
            default: return L10n.format("Can't reach %@. It may be off or asleep.", host)
            }
        case .removed:
            return L10n.format("%@ removed this computer. To connect again, pair with a new link from its Settings › Remote.",
                               host)
        case .connecting, .connected, .stopped:
            return nil
        }
    }

    private func act() {
        if removes {
            log.write("remote forget: \(model.name)")
            let directory = directory, id = model.id
            Task { await directory.forget(id) }
        } else {
            model.reconnectNow()
        }
    }
}
