import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

@MainActor
final class RemoteRailTests: XCTestCase {
    func testRailWireKeepsOldRequestsAndExplicitlyReleasesTheWatch() throws {
        for request in [RemoteRequest.taskRail(taskID: "task"), .taskRail(taskID: "task", watching: false),
                        .railAction(taskID: "task", action: "confirmMerge", targetID: "merge:SQUASH|abc", confirmed: true)] {
            let envelope = RemoteRequestEnvelope(id: "rail", request: request)
            XCTAssertEqual(try RemoteRequestEnvelope.decode(envelope.encoded()).get(), envelope)
            XCTAssertNil(request.requiredPermission)
        }
        let old = try RemoteRequestEnvelope.decode(Data(#"{"id":"old","type":"taskRail","taskId":"task"}"#.utf8)).get()
        XCTAssertEqual(old.request, .taskRail(taskID: "task", watching: true))
        let response = try JSONDecoder().decode(RemoteResponse.self, from: Data(#"{"re":"old","ok":true}"#.utf8))
        XCTAssertNil(response.taskRail)
        XCTAssertNil(response.rail)
    }

    func testRailTextDoesNotCarryEnvironmentValuesOrUnrelatedPaths() {
        let text = AppModelRemoteBridge.safeRailText(
            "MODE=private API_KEY='sensitive' tool /outside/private/file.txt /task/root/output.txt https://example.test/page",
            roots: [URL(filePath: "/task/root")])
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains("sensitive"))
        XCTAssertFalse(text.contains("/outside/"))
        XCTAssertTrue(text.contains("/task/root/output.txt"))
        XCTAssertTrue(text.contains("https://example.test/page"))
    }

    func testRailActionsRejectForeignTargetsAndUnconfirmedWrites() async throws {
        let session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/rail-contract"),
                                    runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Rail")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteRailTests")))
        let model = AppModel(store: SessionStore(sessions: [session], repository: InMemorySessionRepository(sessions: [session])),
                             runtimeSelections: RuntimeSelectionStore(defaults: defaults), restoresIndexOnLaunch: false)
        defer { Task { await model.shutdown() } }
        let bridge = AppModelRemoteBridge(model: model)
        let id = session.id.uuidString
        for action in ["stopAgent", "stopChild", "stopBackground"] {
            let error = await bridge.railAction(taskID: id, action: action, targetID: UUID().uuidString, confirmed: true)
            XCTAssertEqual(error?.code, .notFound)
        }
        for action in ["confirmMerge", "setAutoFix", "stopAllTerminals"] {
            let error = await bridge.railAction(taskID: id, action: action, targetID: "true", confirmed: false)
            XCTAssertEqual(error?.code, .notAllowed)
        }
        let unknown = await bridge.railAction(taskID: id, action: "invented", targetID: nil, confirmed: true)
        XCTAssertEqual(unknown?.code, .unsupportedCommand)
        let staleMerge = await bridge.railAction(taskID: id, action: "confirmMerge", targetID: "merge:SQUASH|stale", confirmed: true)
        XCTAssertEqual(staleMerge?.code, .notAllowed)
        let draft = await bridge.railDraft(taskID: id, confirmed: false)
        if case let .failure(error) = draft { XCTAssertEqual(error.code, .notAllowed) }
        else { XCTFail("A fix draft must follow confirmation") }
    }
}
