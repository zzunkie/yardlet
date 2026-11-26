import Foundation

/// `show_widget`, which draws an HTML view in the conversation for the person, as the Claude app's tool of the same
/// name and arguments does and as a Codex model's inline visualizations are drawn (docs/CONVERSATION_MEDIA.md,
/// "Views from other harnesses"). Yardlet offers it to the harnesses other than Codex, which has its own skill. The
/// call changes nothing and stores nothing: the conversation draws the view from the call's arguments, which the
/// harness keeps in its own history, and Yardlet's answer.
package enum WidgetToolCatalog {
    package static let showWidget = "show_widget"
    package static let title = "title"
    package static let widgetCode = "widget_code"

    /// As much HTML as a view may hold, as a Codex visualization file may.
    package static let maximumCodeLength = 1_048_576
    package static let maximumTitleLength = 200

    /// Words only Yardlet's answer has, so the call the Claude app's own `show_widget` answered, in a conversation
    /// imported from it, stays a tool line.
    package static let resultSignature = "Shown to the person in Yardlet's conversation"

    package static let result = "\(resultSignature), drawn from this call's widget_code. They see it and you do not, "
        + "so say in words what matters."

    package static func definition(named name: String) -> AgentToolDefinition? {
        name == showWidget ? tool : nil
    }

    package static let tool = AgentToolDefinition(
        name: showWidget,
        title: "Show a view",
        description: """
            Draw an interactive HTML view in the conversation for the person: a chart, a diagram, a mockup or a small \
            tool, when seeing it beats reading it. widget_code is an HTML fragment (no <html>, <head> or <body>) \
            with its styles and scripts inline; scripts, styles and fonts may also come from cdnjs.cloudflare.com, \
            cdn.jsdelivr.net, unpkg.com or esm.sh. Nothing else is fetched. The view follows light and dark mode \
            through prefers-color-scheme. Yardlet already styles plain elements to match the app and offers --y-* \
            CSS variables (--y-text, --y-text-secondary, --y-surface, --y-border, --y-accent, --y-success, \
            --y-warning, --y-danger) and the classes y-card, y-grid, y-kpi and y-badge. Prefer Markdown for text \
            and tables.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                title: .object([
                    "type": .string("string"),
                    "description": .string("A few words naming the view.")
                ]),
                widgetCode: .object([
                    "type": .string("string"),
                    "description": .string("The HTML fragment, under 1 MB.")
                ])
            ]),
            "required": .array([.string(title), .string(widgetCode)]),
            "additionalProperties": .bool(false)
        ]),
        readOnly: true,
        openWorld: false
    )
}
