import Foundation
import XCTest
@testable import NativeHarnessClient

final class StructuredHeadlessProtocolTests: XCTestCase {
    func testCursorProjectsSessionTextToolAndResult() throws {
        let projector = StructuredHeadlessEventProjector(flavor: .cursor)
        let initEvent: JSONValue = .object([
            "type": .string("system"),
            "subtype": .string("init"),
            "session_id": .string("cursor-session")
        ])
        XCTAssertEqual(
            projector.project(initEvent, hasAssistantText: false).providerSessionID,
            "cursor-session"
        )

        let assistant: JSONValue = .object([
            "type": .string("assistant"),
            "message": .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("hello")
                ])])
            ])
        ])
        XCTAssertEqual(
            projector.project(assistant, hasAssistantText: false).payloads,
            [.assistantDelta("hello")]
        )

        let result: JSONValue = .object([
            "type": .string("result"),
            "subtype": .string("success"),
            "result": .string("hello"),
            "session_id": .string("cursor-session")
        ])
        let projection = projector.project(result, hasAssistantText: true)
        XCTAssertTrue(projection.isTerminal)
        XCTAssertEqual(projection.payloads, [.turnCompleted])
    }

    func testCursorErrorResultEndsTheTurnWithoutCompletingIt() throws {
        let projector = StructuredHeadlessEventProjector(flavor: .cursor)
        let projection = projector.project(
            .object([
                "type": .string("result"),
                "subtype": .string("error"),
                "is_error": .bool(true),
                "result": .string("Cursor failed"),
                "session_id": .string("cursor-session")
            ]),
            hasAssistantText: false
        )
        XCTAssertTrue(projection.isTerminal)
        XCTAssertEqual(projection.payloads, [.error(message: "Cursor failed", recoverable: true)])
    }

    func testCursorToolCallStartsAnActivityInProgress() throws {
        let projector = StructuredHeadlessEventProjector(flavor: .cursor)
        let started = projector.project(
            .object([
                "type": .string("tool_call"),
                "call_id": .string("cursor-call"),
                "subtype": .string("started"),
                "tool_call": .object(["ShellToolCall": .object(["command": .string("pwd")])])
            ]),
            hasAssistantText: false
        )
        guard case let .activityStarted(activity) = started.payloads.first else {
            return XCTFail("Cursor must still start in-progress tool cards, got \(started.payloads)")
        }
        XCTAssertEqual(activity.id, "cursor-call")
        XCTAssertEqual(activity.kind, "ShellToolCall")
        XCTAssertTrue(activity.detail?.contains("pwd") == true)
    }
}
