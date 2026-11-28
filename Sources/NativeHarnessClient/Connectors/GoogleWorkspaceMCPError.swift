import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import YardletAgentTools

enum GoogleWorkspaceMCPError: LocalizedError, Equatable {
    case agentClient, scope, expired, capability, unattended, unsupported, denied, roundLimit
    case serviceDisabled(project: String?)
    case quota(retryAfter: String?)

    var errorDescription: String? {
        switch self {
        case .agentClient:
            L10n.string("Connect a dedicated Google Agentic OAuth client using Personal Mode or a new AI-powered agent client.")
        case .scope:
            L10n.string("Reconnect this account in Settings › Connectors › Google and grant the permissions this tool needs.")
        case .expired:
            L10n.string("The Google approval request expired. Run the tool again to open a fresh approval card.")
        case .capability:
            L10n.string("Google requires form elicitation for this tool. Check that your client supports Google approval cards.")
        case .unattended:
            L10n.string("Run this tool in an interactive task to approve it once or grant a 90-day ALLOW_*_ALWAYS permission, then retry.")
        case .unsupported:
            L10n.string("Yardlet cannot display this Google approval form. The request was canceled.")
        case .denied:
            L10n.string("Google approval was canceled.")
        case .roundLimit:
            L10n.string("Google requested too many approval rounds. Run the tool again.")
        case .serviceDisabled(let project):
            L10n.string("Enable the Workspace MCP service and its underlying API in Google Cloud, or use Personal Mode.")
                + (project.map { " https://console.cloud.google.com/apis/library?project=\($0)" } ?? "")
        case .quota(let retryAfter):
            L10n.string("Google's MCP quota was reached. Gmail search has a daily free quota of 500 searches per project. Separate Personal Mode projects give each account its own quota.")
                + (retryAfter.map { " " + L10n.format("Retry after %@.", $0) } ?? "")
        }
    }

    static func isInvalidState(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("state") && (text.contains("expired") || text.contains("invalid") || text.contains("stale"))
    }

    static func http(_ response: HTTPURLResponse, data: Data, continuing: Bool) -> any Error {
        switch response.statusCode {
        case 400 where continuing: return Self.expired
        case 403:
            // Never include a tool schema in an error or inspect its tool descriptions as diagnostics.
            let envelope = try? JSONDecoder().decode(ToolJSON.self, from: data)
            let schemaDump = envelope?["result"]?["tools"] != nil
            let error = envelope?["error"]
            let message = error?["message"]?.stringValue
                ?? (envelope == nil ? MCPHTTPClient.excerpt(data) : "")
            let details = error?["details"]?.arrayValue ?? []
            if schemaDump || details.contains(where: { $0["reason"] == .string("SERVICE_DISABLED") })
                || message.contains("SERVICE_DISABLED") || message.contains("has not been used in project") {
                let consumer = details.compactMap { $0["metadata"]?["consumer"]?.stringValue }.first ?? ""
                let project = (consumer + " " + message).range(
                    of: #"(?i)(?:projects/|project\s+)[0-9]+"#, options: .regularExpression)
                let number = project.map { String((consumer + " " + message)[$0].filter(\.isNumber)) }
                return Self.serviceDisabled(project: number)
            }
            if message.localizedCaseInsensitiveContains("insufficient authentication scopes")
                || details.contains(where: { $0["reason"] == .string("ACCESS_TOKEN_SCOPE_INSUFFICIENT") }) {
                return Self.scope
            }
            return MCPHTTPError.http(status: 403, body: String(message.prefix(400)))
        case 429:
            let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, let seconds = Int(value), seconds >= 0 {
                return Self.quota(retryAfter: L10n.format("%ld seconds", seconds))
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return Self.quota(retryAfter: value.flatMap { formatter.date(from: $0) == nil ? nil : $0 })
        default:
            return MCPHTTPError.http(status: response.statusCode, body: "")
        }
    }
}
