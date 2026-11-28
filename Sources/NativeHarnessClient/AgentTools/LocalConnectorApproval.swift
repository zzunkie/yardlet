import Foundation
import YardletAgentTools

/// Formats approval cards for tools that run locally.
enum LocalConnectorApproval {
    static func request(toolName: String?, input: JSONValue, mailDraft: MailDraftPreview? = nil,
                        labels: ConnectorToolLabels = .shared) -> (title: String, detail: String)? {
        guard let toolName, let label = labels.label(forClaudeTool: toolName),
              let service = label.localService, service.approvalRequiredTools.contains(label.tool) else { return nil }
        // The account the call names, for a tool its service's accounts share.
        let named = label.account(named: input[ConnectorToolNaming.accountArgument]?.stringValue)
        let account = named ?? service.name
        switch service {
        case let microsoft where microsoft.isMicrosoft:
            return MicrosoftToolApproval.request(microsoft, tool: label.tool, account: named, input: input,
                                                 draft: mailDraft)
        case .imapMail where label.tool == MailAccountToolCatalog.sendDraft:
            return (L10n.format("Allow Claude to send a draft from %@?", account),
                    mailDraft.map(MailDraftApproval.draftDetail) ?? text(input, "draftId").map { L10n.format("Draft %@", $0) } ?? "")
        default: return AppleToolApproval.request(service, tool: label.tool, account: named, input: input)
        }
    }

    private static func text(_ input: JSONValue, _ key: String) -> String? {
        guard let value = input[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
