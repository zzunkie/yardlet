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

    func testCursorProjectsThinkingEventsBlocksAndResultUsage() throws {
        let projector = StructuredHeadlessEventProjector(flavor: .cursor)

        let delta = projector.project(
            .object([
                "type": .string("thinking"),
                "subtype": .string("delta"),
                "text": .string("Inspecting diff"),
                "session_id": .string("cursor-session")
            ]),
            hasAssistantText: false
        )
        XCTAssertEqual(delta.payloads, [.reasoningDelta("Inspecting diff")])

        let completedWithText = projector.project(
            .object([
                "type": .string("thinking"),
                "subtype": .string("completed"),
                "text": .string("Inspecting diff carefully"),
                "session_id": .string("cursor-session")
            ]),
            hasAssistantText: false
        )
        XCTAssertEqual(completedWithText.payloads, [.reasoningCompleted("Inspecting diff carefully")])

        // Empty completed thinking markers must not emit an empty completion that clears streamed text.
        let completedEmpty = projector.project(
            .object([
                "type": .string("thinking"),
                "subtype": .string("completed"),
                "session_id": .string("cursor-session")
            ]),
            hasAssistantText: false
        )
        XCTAssertEqual(completedEmpty.payloads, [])

        // Assistant frames carrying inline thinking + text blocks project both in order.
        let mixedAssistant = projector.project(
            .object([
                "type": .string("assistant"),
                "message": .object([
                    "content": .array([
                        .object(["type": .string("thinking"), "thinking": .string("Step 1")]),
                        .object(["type": .string("text"), "text": .string("Done")])
                    ])
                ])
            ]),
            hasAssistantText: false
        )
        XCTAssertEqual(mixedAssistant.payloads, [.reasoningDelta("Step 1"), .assistantDelta("Done")])

        // Result usage (camelCase and snake_case) projects into .usageUpdated before .turnCompleted.
        let camelResult = projector.project(
            .object([
                "type": .string("result"),
                "subtype": .string("success"),
                "result": .string("Done"),
                "total_cost_usd": .number(0.015),
                "usage": .object([
                    "inputTokens": .integer(400),
                    "cacheReadTokens": .integer(120),
                    "outputTokens": .integer(80),
                    "reasoningTokens": .integer(25)
                ]),
                "session_id": .string("cursor-session")
            ]),
            hasAssistantText: true
        )
        XCTAssertTrue(camelResult.isTerminal)
        XCTAssertEqual(
            camelResult.payloads,
            [
                .usageUpdated(HarnessProtocolUsage(
                    inputTokens: 400,
                    cachedInputTokens: 120,
                    outputTokens: 80,
                    reasoningTokens: 25,
                    totalCostUSD: 0.015,
                    contextWindowTokens: nil,
                    contextUsedTokens: nil,
                    extensionValues: [:]
                )),
                .turnCompleted
            ]
        )

        let snakeResult = projector.project(
            .object([
                "type": .string("result"),
                "subtype": .string("success"),
                "result": .string("Done"),
                "usage": .object([
                    "input_tokens": .integer(200),
                    "cache_read_input_tokens": .integer(50),
                    "output_tokens": .integer(40)
                ])
            ]),
            hasAssistantText: true
        )
        XCTAssertEqual(
            snakeResult.payloads,
            [
                .usageUpdated(HarnessProtocolUsage(
                    inputTokens: 200,
                    cachedInputTokens: 50,
                    outputTokens: 40,
                    reasoningTokens: nil,
                    totalCostUSD: nil,
                    contextWindowTokens: nil,
                    contextUsedTokens: nil,
                    extensionValues: [:]
                )),
                .turnCompleted
            ]
        )
    }
}
