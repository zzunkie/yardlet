import Foundation

/// The decision context carried by a request. Routing and account fields stay out of the card.
struct CodexRequestContextProjection {
    struct Field: Identifiable {
        let id: String
        let titleKey: String?
        let text: String
    }

    let messages: [String]
    let fields: [Field]
    var isEmpty: Bool { messages.isEmpty && fields.isEmpty }

    /// The words a host's card shows with a request another Mac's window draws (`RemoteItem.message`), the
    /// only context the host sends.
    init(messages: [String]) {
        self.messages = messages
        fields = []
    }

    init(params: JSONValue?) {
        var messages: [String] = []
        for key in ["reason", "message"] {
            if let text = params?[key]?.stringValue,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !messages.contains(text) {
                messages.append(text)
            }
        }
        self.messages = messages

        let keys: [(String, String?)] = [
            ("command", nil), ("cwd", "Working directory"),
            ("permissions", "Permissions"), ("grantRoot", "Write access"),
            ("grant_root", "Write access"), ("changes", "Files"),
            ("tool", nil), ("arguments", "Arguments")
        ]
        fields = keys.compactMap { key, title in
            guard let value = params?[key], value != .null else { return nil }
            let text: String
            if case let .string(string) = value {
                guard !string.isEmpty else { return nil }
                text = string
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                guard let data = try? encoder.encode(value),
                      let encoded = String(data: data, encoding: .utf8) else { return nil }
                text = encoded
            }
            return Field(id: key, titleKey: title, text: text)
        }
    }
}

extension CodexServerRequestKind {
    /// The heading a request's card shows.
    var cardTitle: String {
        switch self {
        case .commandExecutionApproval: L10n.string("Command approval")
        case .fileChangeApproval: L10n.string("File change approval")
        case .permissionsApproval: L10n.string("Permissions approval")
        case .applyPatchApproval, .execCommandApproval: L10n.string("Review approval")
        case .toolUserInput: L10n.string("Question")
        case .mcpElicitation: L10n.string("Request")
        case .dynamicToolCall: L10n.string("Tool request")
        default: L10n.string("Needs approval")
        }
    }
}

extension CodexApprovalState {
    /// The heading an approval's card shows.
    static var cardTitle: String { L10n.string("Needs approval") }
}
