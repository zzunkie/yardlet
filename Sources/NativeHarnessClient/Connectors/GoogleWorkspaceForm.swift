import Foundation
import Markdown
import YardletAgentTools

/// The outer request ID and the property name inside its schema can differ.
struct GoogleWorkspaceForm {
    let field: String
    let card: GoogleWorkspaceMCPClient.Card

    init?(input: ToolJSON, account: String) {
        guard input["method"] == nil || input["method"] == .string("elicitation/create"),
              let params = input["params"], params["mode"] == .string("form"),
              let message = params["message"]?.stringValue, !message.isEmpty,
              let schema = params["requestedSchema"], schema["type"] == .string("object"),
              let properties = schema["properties"]?.objectValue, properties.count == 1,
              let (field, property) = properties.first, !field.isEmpty,
              schema["required"] == nil || schema["required"] == .array([.string(field)]),
              property["type"] == nil || property["type"] == .string("string"),
              let title = property["title"]?.stringValue ?? schema["title"]?.stringValue, !title.isEmpty else { return nil }

        let choices: [(ToolJSON?, ToolJSON?)]
        if let options = property["oneOf"]?.arrayValue {
            choices = options.map { ($0["const"], $0["title"]) }
        } else if let codes = property["enum"]?.arrayValue {
            let labels = property["enumNames"]?.arrayValue ?? codes
            guard labels.count == codes.count else { return nil }
            choices = Array(zip(codes, labels))
        } else {
            return nil
        }

        var actions: [PermissionRequestAction] = []
        for (value, text) in choices {
            guard let id = value?.stringValue, let label = text?.stringValue, !label.isEmpty,
                  !actions.contains(where: { $0.id == id }) else { return nil }
            let kind: String
            switch id {
            case "ALLOW_ONCE": kind = "allow_once"
            case "DENY_ONCE": kind = "reject_once"
            case "ALLOW_TOOL_ALWAYS", "ALLOW_AUDIENCE_ALWAYS", "ALLOW_RESOURCE_ALWAYS", "ALLOW_OWNER_ALWAYS":
                kind = "allow_always"
            default: return nil
            }
            actions.append(.init(id: id, label: label, decision: id == "DENY_ONCE" ? .deny : .allow, kind: kind))
        }
        guard !actions.isEmpty else { return nil }
        self.field = field
        card = .init(title: "\(title) · \(account)", detail: Self.text(Document(parsing: message)), actions: actions)
    }

    private static func text(_ node: any Markup) -> String {
        if let link = node as? Markdown.Link, let target = link.destination {
            let label = link.plainText
            return label == target || "mailto:\(label)" == target ? label : "\(label) (\(target))"
        }
        if node is SoftBreak || node is LineBreak { return "\n" }
        if let code = node as? InlineCode { return code.code }
        if let code = node as? CodeBlock { return code.code }
        if let html = node as? HTMLBlock { return html.rawHTML }
        if node.childCount == 0 { return (node as? any PlainTextConvertibleMarkup)?.plainText ?? "" }
        let separator = node is Table.Row || node is Table.Head ? " | " : (node is any InlineContainer ? "" : "\n")
        return node.children.map(text).joined(separator: separator)
    }
}
