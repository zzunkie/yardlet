import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

@MainActor
final class RemoteConnectorSetupClientTests: XCTestCase {
    private func response(_ state: RemoteConnectorSetupState) -> RemoteResponse {
        var response = RemoteResponse(re: state.operationID)
        response.connectorSetup = state
        return response
    }

    func testTheClientListensAndOpensItsBrowserThenReturnsOnlyTheCallback() async throws {
        let userAgent = FakeUserAgent(answers: false)
        userAgent.loopback.deliver(URL(string: "http://127.0.0.1/callback?code=code-1&state=request-state")!)
        let listen = RemoteConnectorSetupStep(id: UUID().uuidString, kind: .listen, port: 47823, state: "request-state")
        let confirm = RemoteConnectorSetupStep(id: UUID().uuidString, kind: .confirm,
            connector: "Example", serverHost: "mcp.example.test", signInHost: "auth.example.test")
        let open = RemoteConnectorSetupStep(id: UUID().uuidString, kind: .open,
            url: "https://auth.example.test/authorize?state=request-state")
        let callback = RemoteConnectorSetupStep(id: UUID().uuidString, kind: .callback)
        let steps = [listen, confirm, open, callback]
        var index = 0
        var answers: [RemoteConnectorSetupReply] = []
        var refreshed = false
        let client = RemoteConnectorSetupClient(host: "Studio", userAgent: userAgent, request: { request in
            if request.action == .answer {
                answers.append(try! XCTUnwrap(request.reply))
                index += 1
            }
            return self.response(.init(operationID: request.operationID,
                connectorID: "00000000-0000-4000-8000-000000000001",
                status: index == steps.count ? .connected : .working,
                step: index < steps.count ? steps[index] : nil))
        }, finished: { refreshed = true })

        client.start(draft: .init(presetID: "linear"))
        try await waitUntil { !client.isRunning }
        XCTAssertEqual(client.state?.status, .connected)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(userAgent.loopbackPorts, [47823])
        XCTAssertEqual(userAgent.opened.map(\.absoluteString), [open.url!])
        XCTAssertEqual(userAgent.confirmations.first?.serverHost, "mcp.example.test")
        XCTAssertEqual(answers.map(\.stepID), steps.map(\.id))
        XCTAssertEqual(answers[0].value, FakeUserAgent.redirect.absoluteString)
        XCTAssertEqual(answers[1].accepted, true)
        XCTAssertEqual(answers[2].accepted, true)
        XCTAssertTrue(answers[3].value?.contains("code=code-1&state=request-state") == true)
        XCTAssertEqual(URL(string: answers[3].value!)?.port, FakeUserAgent.redirect.port)
    }

    func testARepeatedStepDoesNotOpenTheBrowserTwice() async throws {
        let agent = FakeUserAgent()
        let step = RemoteConnectorSetupStep(id: UUID().uuidString, kind: .open,
            url: "https://github.com/login/device", deviceCode: "ABCD-EFGH")
        var requests: [RemoteConnectorSetupRequest.Action] = []
        let client = RemoteConnectorSetupClient(host: "Studio", userAgent: agent, request: { request in
            requests.append(request.action)
            return self.response(.init(operationID: request.operationID,
                status: request.action == .poll ? .connected : .working,
                step: request.action == .poll ? nil : step))
        })
        client.start(draft: .init(presetID: "github"))
        try await waitUntil { !client.isRunning }
        XCTAssertEqual(requests, [.start, .answer, .poll])
        XCTAssertEqual(agent.opened.count, 1)
        XCTAssertEqual(client.deviceCode, "ABCD-EFGH")
    }

    func testLosingSettingsPermissionCancelsWhileWaitingForTheBrowser() async throws {
        let agent = FakeUserAgent(answers: false)
        let listen = RemoteConnectorSetupStep(id: UUID().uuidString, kind: .listen, state: "state")
        let callback = RemoteConnectorSetupStep(id: UUID().uuidString, kind: .callback)
        var allowed = true
        var cancellations = 0
        var callbackAnswers = 0
        let client = RemoteConnectorSetupClient(host: "Studio", userAgent: agent,
            available: { allowed }, request: { request in
                if request.action == .cancel { cancellations += 1 }
                if request.reply?.stepID == callback.id { callbackAnswers += 1 }
                return self.response(.init(operationID: request.operationID,
                    status: request.action == .cancel ? .cancelled : .working,
                    step: request.action == .start ? listen : callback))
            })
        client.start(draft: .init(presetID: "linear"))
        try await waitUntil { client.state?.step?.kind == .callback }
        allowed = false
        try await waitUntil { !client.isRunning }
        XCTAssertEqual(client.state?.status, .cancelled)
        XCTAssertGreaterThan(cancellations, 0)
        XCTAssertEqual(callbackAnswers, 0)
        XCTAssertNotNil(client.error)
    }

    func testAHostCannotOpenAFileOrAnApplicationAsASignInPage() async throws {
        for address in ["file:///etc/passwd", "yardlet://settings", "https://user:secret@example.test/signin", "http://example.test/signin"] {
            let agent = FakeUserAgent()
            var cancelled = false
            let client = RemoteConnectorSetupClient(host: "Studio", userAgent: agent, request: { request in
                cancelled = cancelled || request.action == .cancel
                return self.response(.init(operationID: request.operationID, step: .init(
                    id: UUID().uuidString, kind: .open, url: address)))
            })
            client.start(draft: .init(presetID: "linear"))
            try await waitUntil { !client.isRunning }
            XCTAssertTrue(agent.opened.isEmpty)
            XCTAssertTrue(cancelled)
            XCTAssertNotNil(client.error)
        }
    }

    func testFailedCreationCanRetryWithCorrectedCredentialsOnTheSameConnector() async throws {
        let connectorID = UUID().uuidString
        var starts: [RemoteConnectorSetupRequest] = []
        let client = RemoteConnectorSetupClient(host: "Studio", userAgent: FakeUserAgent(), request: { request in
            starts.append(request)
            return self.response(.init(operationID: request.operationID, connectorID: connectorID,
                status: starts.count == 1 ? .failed : .connected, message: starts.count == 1 ? "Token refused" : nil))
        })
        client.start(draft: .init(name: "Example", serverURL: "https://example.test/mcp", token: "incorrect"))
        try await waitUntil { !client.isRunning }
        XCTAssertEqual(client.state?.connectorID, connectorID)
        client.start(draft: .init(token: "corrected", tokenHeader: "X-API-Key"), connectorID: client.state?.connectorID)
        try await waitUntil { !client.isRunning }
        XCTAssertEqual(client.state?.status, .connected)
        XCTAssertEqual(starts.count, 2)
        XCTAssertNil(starts[0].connectorID)
        XCTAssertEqual(starts[1].connectorID, connectorID)
        XCTAssertEqual(starts[1].draft?.token, "corrected")
        XCTAssertEqual(starts[1].draft?.tokenHeader, "X-API-Key")
        XCTAssertNil(starts[1].draft?.serverURL)
        XCTAssertNil(starts[1].draft?.presetID)
    }

    func testARefusedStepCancelsTheHostBeforeAllowingRetry() async throws {
        let connectorID = UUID().uuidString
        let step = RemoteConnectorSetupStep(id: UUID().uuidString, kind: .open, url: "https://example.test/signin")
        var actions: [RemoteConnectorSetupRequest.Action] = []
        let client = RemoteConnectorSetupClient(host: "Studio", userAgent: FakeUserAgent(), request: { request in
            actions.append(request.action)
            if request.action == .answer { return .failure(request.operationID, RemoteError(.badRequest)) }
            return self.response(.init(operationID: request.operationID, connectorID: connectorID,
                status: request.action == .cancel ? .cancelled : .working,
                step: request.action == .start ? step : nil))
        })
        client.start(draft: .init(presetID: "linear"))
        try await waitUntil { !client.isRunning }
        XCTAssertEqual(actions, [.start, .answer, .cancel])
        XCTAssertEqual(client.state?.status, .cancelled)
        XCTAssertNotNil(client.error)
    }
}
