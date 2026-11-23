import Foundation
import YardletAgentTools

/// A `show_widget` call Yardlet answered (docs/CONVERSATION_MEDIA.md, "Views from other harnesses"): the view its
/// arguments hold, which the call's row draws as its detail. Claude Code and an ACP agent record the call in their own
/// shapes; what they share is the arguments and Yardlet's answer, which has words only it has
/// (`WidgetToolCatalog.resultSignature`), so a call the Claude app's own `show_widget` answered stays a tool line.
struct ConversationWidget: Equatable, Sendable {
    var title: String
    var code: String

    /// The view of a completed call, read when its answer is Yardlet's (short, and with its words) or when an
    /// ACP harness omitted the tool output on a call whose name is Yardlet's own `show_widget` tool.
    static func of(_ activity: HarnessActivity) -> ConversationWidget? {
        if let result = activity.output {
            guard result.utf8.prefix(longestAnswer + 1).count <= longestAnswer,
                  result.contains(WidgetToolCatalog.resultSignature) else { return nil }
        } else {
            guard activity.outcome != .failed, isYardletShowWidget(activity) else { return nil }
        }
        guard case let .object(arguments)? = ConversationAgentRunProjection.arguments(in: activity.input),
              case let .string(code)? = arguments[WidgetToolCatalog.widgetCode],
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              code.utf8.count <= WidgetToolCatalog.maximumCodeLength else { return nil }
        var title = ""
        if case let .string(text)? = arguments[WidgetToolCatalog.title] { title = text }
        return ConversationWidget(
            title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(WidgetToolCatalog.maximumTitleLength)),
            code: code)
    }

    private static func isYardletShowWidget(_ activity: HarnessActivity) -> Bool {
        for raw in [activity.kind, activity.title] {
            for token in raw.split(whereSeparator: \.isWhitespace) {
                if isYardletShowWidgetToken(token) { return true }
            }
        }
        return false
    }

    /// Recognizes Yardlet's namespaced `show_widget` tool names across MCP/ACP naming conventions
    /// (`mcp__yardlet__show_widget`, `mcp_yardlet_<hex>_show_widget`, `yardlet/show_widget`,
    /// `yardlet:show_widget`, `yardlet__show_widget`, `yardlet.show_widget`, `yardlet_show_widget`)
    /// without matching bare or non-Yardlet `show_widget` tools.
    private static func isYardletShowWidgetToken(_ raw: Substring) -> Bool {
        let lower = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'()[]")).lowercased()
        guard lower.hasSuffix("show_widget"), lower.count > "show_widget".count else { return false }
        let beforeTool = lower.dropLast("show_widget".count)
        guard let separator = beforeTool.last, "/:._".contains(separator) else { return false }
        let serverPart = beforeTool.dropLast().trimmingCharacters(in: CharacterSet(charactersIn: "/:._"))
        let strippedMCP: Substring
        if serverPart.hasPrefix("mcp") {
            let afterMCP = serverPart.dropFirst(3)
            guard let first = afterMCP.first, "/:._".contains(first) else { return false }
            strippedMCP = afterMCP.drop(while: { "/:._".contains($0) })
        } else {
            strippedMCP = Substring(serverPart)
        }
        if strippedMCP == "yardlet" { return true }
        if strippedMCP.hasPrefix("yardlet_") {
            let suffix = strippedMCP.dropFirst("yardlet_".count)
            return !suffix.isEmpty && suffix.allSatisfy(\.isHexDigit)
        }
        return false
    }

    /// Longer than Yardlet's answer, however a harness wraps it.
    private static let longestAnswer = 4_096
}
