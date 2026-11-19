import Foundation
import YardletAgentTools

/// A `show_widget` call Yardlet answered (docs/CONVERSATION_MEDIA.md, "Views from other harnesses"): the view its
/// arguments hold, which the call's row draws as its detail. Claude Code and an ACP agent record the call in their own
/// shapes; what they share is the arguments and Yardlet's answer, which has words only it has
/// (`WidgetToolCatalog.resultSignature`), so a call the Claude app's own `show_widget` answered stays a tool line.
struct ConversationWidget: Equatable, Sendable {
    var title: String
    var code: String

    /// The view of a completed call, read only when its answer is Yardlet's: short, and with its words.
    static func of(_ activity: HarnessActivity) -> ConversationWidget? {
        guard let result = activity.output, result.utf8.prefix(longestAnswer + 1).count <= longestAnswer,
              result.contains(WidgetToolCatalog.resultSignature),
              case let .object(arguments)? = ConversationAgentRunProjection.arguments(in: activity.input),
              case let .string(code)? = arguments[WidgetToolCatalog.widgetCode],
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var title = ""
        if case let .string(text)? = arguments[WidgetToolCatalog.title] { title = text }
        return ConversationWidget(
            title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(WidgetToolCatalog.maximumTitleLength)),
            code: code)
    }

    /// Longer than Yardlet's answer, however a harness wraps it.
    private static let longestAnswer = 4_096
}
