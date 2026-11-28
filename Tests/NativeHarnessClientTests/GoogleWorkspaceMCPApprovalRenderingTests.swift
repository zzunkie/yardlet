import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
import YardletAgentTools

/// A Google form as seen through Code Mode, notifications, the phone and the task's card.
@MainActor
final class GoogleWorkspaceMCPApprovalRenderingTests: XCTestCase {
    func testReadingTheGoogleFormDoesNotSpendTheScriptsTime() async {
        let result = await CodeModeRunner.run(code: #"return callTool("send_message", {});"#, timeoutSeconds: 1) {
            tool, arguments in
            do {
                let reply = try await FormServer.client.callTool(name: tool, arguments: arguments,
                                                         accountAddress: FormServer.address, token: UUID().uuidString, responder: { _ in
                    // The script must not expire while the person reads the form beyond its one-second budget.
                    try await Task.sleep(for: .milliseconds(1_600))
                    return "ALLOW_ONCE"
                })
                return .text(reply["content"]?.arrayValue?.first?["text"]?.stringValue ?? "")
            } catch {
                return .error(error.localizedDescription)
            }
        }
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Sent"), result.text)
    }

    func testNotificationRemoteAndVisibleCardUseTheChoicesGoogleSent() async throws {
        let reply = try await FormServer.client.callTool(name: "send_message", arguments: .object([:]),
                                                 accountAddress: FormServer.address, token: UUID().uuidString, responder: { form in
            let permission = PermissionRequest(id: "approval", title: form.title, detail: form.detail,
                                               command: nil, actions: form.actions)
            try await Self.checkCard(permission)
            return "ALLOW_ONCE"
        })
        XCTAssertEqual(reply["content"]?.arrayValue?.first?["text"], .string("Sent"))
    }

    private static func checkCard(_ permission: PermissionRequest) throws {
        XCTAssertEqual(permission.title, "Send email · \(FormServer.address)")
        let detail = try XCTUnwrap(permission.detail)
        for visible in ["reports@partner.example", "Quarterly review", "quarterly-report.pdf", "external domain"] {
            XCTAssertTrue(detail.contains(visible), detail)
        }
        XCTAssertFalse(detail.contains("**"))
        let request = SessionToolApproval(id: permission.id, taskID: UUID(), request: permission).conversationRequest
        let once = try XCTUnwrap(permission.actions.first { $0.id == "ALLOW_ONCE" })
        let deny = try XCTUnwrap(permission.actions.first { $0.id == "DENY_ONCE" })
        XCTAssertEqual(NotificationApprovalProjection.allowOnce(for: permission), .providerAction(once))
        XCTAssertEqual(NotificationApprovalProjection.deny(for: permission), .providerAction(deny))
        let remote = try XCTUnwrap(RemoteApprovalPolicy.choices(for: request))
        XCTAssertEqual(Set(remote.filter { $0.standing == true }.map(\.title)),
                       ["Allow this audience", "Allow this tool"])

        let size = CGSize(width: 480, height: 420)
        let directory = try WindowlessRender.directory("approval-card-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                ConversationRequestCard(request: request, actions: ConversationActions(chooseOption: { _, _ in }))
                    .frame(width: size.width - 24)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: size.width, height: size.height)
                    .background(ParityTheme.canvas)
                    .environment(\.colorScheme, appearance.colorScheme),
                size: size, appearance: appearance)
            defer { host.close() }
            host.settle()
            let elements = host.accessibilityElements(visibleOnly: true)
            for label in ["Deny", "Allow this audience", "Allow once"] {
                XCTAssertTrue(elements.contains { $0.label == label }, "\(label): \(elements)")
            }
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "google-form-\(appearance.suffix).png"))
        }
    }
}

private struct FormServer: ConnectorHTTPTransport {
    static let address = "sender@example.com"
    static var client: GoogleWorkspaceMCPClient {
        GoogleWorkspaceMCPClient(endpoint: URL(string: "https://gmail.example.test/mcp/v1")!, transport: Self())
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let params = try XCTUnwrap(body["params"] as? [String: Any])
        let result: [String: Any]
        if let responses = params["inputResponses"] as? [String: [String: Any]] {
            let content = try XCTUnwrap(responses["approval_choice"]?["content"] as? [String: String])
            XCTAssertEqual(content["approval_choice"], "ALLOW_ONCE")
            result = ["content": [["type": "text", "text": "Sent"]]]
        } else {
            let choice: [String: Any] = [
                "type": "string", "title": "Send email",
                "enum": ["ALLOW_AUDIENCE_ALWAYS", "ALLOW_TOOL_ALWAYS", "DENY_ONCE", "ALLOW_ONCE"],
                "enumNames": ["Allow this audience", "Allow this tool", "Deny", "Allow once"]
            ]
            let form: [String: Any] = [
                "mode": "form", "message": """
                **Recipients:** reports@partner.example, finance@example.com
                **Subject:** Quarterly review and requested changes to the distribution schedule
                **Attachment:** `quarterly-report.pdf`

                The message and its attachment will be delivered to an external domain outside your organization.
                """,
                "requestedSchema": ["type": "object", "title": "Send email", "required": ["approval_choice"],
                                    "properties": ["approval_choice": choice]]
            ]
            result = ["resultType": "input_required", "requestState": "pending",
                      "inputRequests": ["approval_choice": ["method": "elicitation/create", "params": form]]]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": try XCTUnwrap(body["id"]),
            "result": result
        ])
        let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200,
                                                      httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (data, response)
    }
}
