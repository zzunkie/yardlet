import Foundation

enum TaskSurface: String, CaseIterable, Identifiable {
    case chat, diff, terminal, browser

    var id: Self { self }

    var displayName: String {
        switch self {
        case .chat: L10n.string("Chat")
        case .diff: L10n.string("Changes")
        case .terminal: L10n.string("Terminal")
        case .browser: L10n.string("Browser")
        }
    }

    var symbolName: String {
        switch self {
        case .chat: "text.bubble"
        case .diff: "plusminus"
        case .terminal: "terminal"
        case .browser: "safari"
        }
    }
}
